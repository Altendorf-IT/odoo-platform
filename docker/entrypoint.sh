#!/usr/bin/env bash
# Render odoo.conf from env -> wait for postgres -> auto (install)/upgrade our
# own modules -> exec the server. Runs as the unprivileged `odoo` user.
set -euo pipefail

# --- Defaults (every value overridable via env / .env) -----------------------
: "${DB_HOST:=db}"
: "${DB_PORT:=5432}"
: "${DB_USER:=odoo}"
: "${DB_PASSWORD:=odoo}"
: "${DB_NAME:=False}"
: "${DB_MAXCONN:=64}"
: "${LIST_DB:=False}"
# Empty/unset -> derive from DB_NAME. If DB_NAME=False (multi-db), default to
# .* — but with 2+ dbs that breaks emailed signup/reset links (a fresh session
# only gets a db when EXACTLY ONE matches). Multi-db deployments must set
# DBFILTER explicitly, normally (?i)^%d\$ (subdomain == db name, any case) —
# see DEPLOY.md "Host -> database routing".
if [ -z "${DBFILTER:-}" ]; then
    if [ "$DB_NAME" = "False" ]; then
        DBFILTER=".*"
        echo "[entrypoint] WARNING: DB_NAME=False and no DBFILTER -> '.*'." \
             "Fine with a single db; with several, db-less requests (emailed" \
             "signup/reset links) 404. Set DBFILTER=(?i)^%d\$ (see DEPLOY.md)." >&2
    else
        DBFILTER="^${DB_NAME}\$"
    fi
fi

: "${ADMIN_PASSWD:=admin}"
: "${DATA_DIR:=/var/lib/odoo}"

: "${HTTP_PORT:=8069}"
: "${GEVENT_PORT:=8072}"
: "${PROXY_MODE:=True}"
: "${WORKERS:=2}"
: "${MAX_CRON_THREADS:=1}"

: "${LIMIT_MEMORY_SOFT:=2147483648}"
: "${LIMIT_MEMORY_HARD:=8589934592}"
: "${LIMIT_REQUEST:=1073741824}"
: "${LIMIT_TIME_CPU:=3600}"
: "${LIMIT_TIME_REAL:=7200}"
# Wall-clock cap for CRON jobs, separate from the HTTP one above. Odoo's own
# default (-1) means "reuse limit_time_real", which is sized for a web request
# and is far too tight for a nightly job: a backup or a big recompute that runs
# past it is killed mid-transaction, the work is rolled back, and ir_cron.nextcall
# is never advanced — so the job stays permanently overdue and every cron behind
# it starves. Set a generous value (e.g. 1800) or 0 for no limit.
: "${LIMIT_TIME_REAL_CRON:=-1}"

: "${LOG_LEVEL:=info}"

# Core addons + our first-party modules + the cherry-picked third-party ones.
# Only src/custom_addons and third_party_addons/_selected are ever on the path.
# NEVER add the src root or third_party_addons/_vendor here (see repo README).
: "${ADDONS_PATH:=/usr/lib/python3/dist-packages/odoo/addons,/opt/extra-addons/custom_addons,/opt/extra-addons/third_party_addons/_selected}"

# Layout guard: only custom_addons + third_party_addons belong under the addons
# root. A module dropped anywhere else under src/ is NOT on addons_path and will
# silently not load — warn loudly so it is caught at boot.
for _e in /opt/extra-addons/*/; do
    _n="$(basename "$_e")"
    case "$_n" in
        custom_addons|third_party_addons) ;;
        *) echo "[entrypoint] WARNING: /opt/extra-addons/$_n is not custom_addons/ or third_party_addons/ — NOT on addons_path, will not load" >&2 ;;
    esac
done

: "${ODOO_RC:=/var/lib/odoo/odoo.conf}"

# ADDONS_SKIP_UNPORTED=1: load only modules whose manifest version belongs to
# this image's Odoo series (19.0.x). For rehearsal/port stacks while some
# modules are still on the previous series: an unported module on the path
# breaks every registry load (Odoo prefixes its 18.0 version and tries to load
# it), while one that is left OFF the path keeps its database rows untouched
# in state 'to upgrade' until its port lands. Never set this in production —
# a module skipped there silently stops working.
: "${ADDONS_SKIP_UNPORTED:=}"
if [ "$ADDONS_SKIP_UNPORTED" = "1" ]; then
    _ported_dir=/tmp/ported-addons
    ADDONS_PATH="$(python3 - "$ADDONS_PATH" "$_ported_dir" <<'PYEOF'
import ast, os, shutil, sys
from odoo import release
paths, dest = sys.argv[1].split(","), sys.argv[2]
shutil.rmtree(dest, ignore_errors=True)
os.makedirs(dest)
keep = []
for path in paths:
    if path.rstrip("/").endswith("odoo/addons"):   # core: always ported
        keep.append(path)
        continue
    for name in sorted(os.listdir(path)):
        manifest = os.path.join(path, name, "__manifest__.py")
        if not os.path.isfile(manifest):
            continue
        version = str(ast.literal_eval(open(manifest).read()).get("version", ""))
        if version.startswith(release.serie + "."):
            os.symlink(os.path.realpath(os.path.join(path, name)), os.path.join(dest, name))
        else:
            print(f"[entrypoint] ADDONS_SKIP_UNPORTED: skipping {name} ({version or 'no version'})",
                  file=sys.stderr)
print(",".join(keep + [dest]))
PYEOF
)"
    echo "[entrypoint] ADDONS_SKIP_UNPORTED: addons_path=$ADDONS_PATH"
fi

# Product-specific: no platform default — set UPGRADE_MODULES in the product's .env.
: "${UPGRADE_MODULES:=}"
: "${INSTALL_MODULES:=}"
# Comma-separated list of databases to run -i/-u on. Empty or "False" = skip.
# Missing dbs are skipped with a warning (never auto-created).
# To init a fresh db from scratch, use INIT_DB=<name> (one-shot, then clear).
: "${UPGRADE_DB:=}"
: "${INIT_DB:=}"

# Products may require modules in Git, without changing deployment secrets.
# One technical module name per line; comments and blank lines are allowed.
if [ -f /opt/extra-addons/custom_addons/required-modules.txt ]; then
    while IFS= read -r _module || [ -n "$_module" ]; do
        _module="${_module%%#*}"
        _module="$(echo "$_module" | xargs)"
        case "$_module" in
            "") continue ;;
            *[!a-zA-Z0-9_]*)
                echo "[entrypoint] invalid required module name: $_module" >&2
                exit 1 ;;
        esac
        case ",${INSTALL_MODULES}," in
            *,"$_module",*) ;;
            *) INSTALL_MODULES="${INSTALL_MODULES:+${INSTALL_MODULES},}${_module}" ;;
        esac
    done < /opt/extra-addons/custom_addons/required-modules.txt
fi

# Keep UI edits to Languages (date format, separators, week start) across
# upgrades. Odoo ships those defaults in base/data/res.lang.csv, a plain data
# file with no noupdate flag, so every `-u base` — and `-u all` includes base —
# re-imports it and overwrites whatever was set in Settings > Languages. See
# the LANG_NOUPDATE block below. Set LANG_NOUPDATE=0 to track upstream instead.
: "${LANG_NOUPDATE:=1}"

# Debugger (debugpy). DEBUG=1 -> run Odoo under debugpy on DEBUGPY_PORT.
# DEBUGPY_WAIT=1 -> block until the IDE attaches.
: "${DEBUG:=0}"
: "${DEBUGPY_PORT:=5678}"
: "${DEBUGPY_WAIT:=}"

# Secrets at rest (OCA data_encryption). ENCRYPTION_KEY never lands in the
# database: it is rendered into odoo.conf at boot, so a DB dump alone cannot
# decrypt anything stored through the encrypted.data model.
# RUNNING_ENV names the key set, letting prod/staging hold different secrets.
: "${RUNNING_ENV:=}"
: "${ENCRYPTION_KEY:=}"

export DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME DB_MAXCONN DBFILTER LIST_DB \
       ADMIN_PASSWD DATA_DIR HTTP_PORT GEVENT_PORT PROXY_MODE WORKERS \
       MAX_CRON_THREADS LIMIT_MEMORY_SOFT LIMIT_MEMORY_HARD LIMIT_REQUEST \
       LIMIT_TIME_CPU LIMIT_TIME_REAL LIMIT_TIME_REAL_CRON LOG_LEVEL ADDONS_PATH

# --- Render config -----------------------------------------------------------
envsubst < /etc/odoo/odoo.conf.template > "$ODOO_RC"
# odoo.conf holds db_password, admin_passwd and (below) the encryption key.
chmod 600 "$ODOO_RC"
echo "[entrypoint] rendered $ODOO_RC"

# --- Secrets at rest ---------------------------------------------------------
# Appended rather than templated: the key NAME is dynamic (encryption_key_<env>)
# and we must not emit a half-configured entry when the key is unset.
if [ -n "$RUNNING_ENV" ]; then
    # RUNNING_ENV names an environment (prod, staging) and is NOT a secret: it
    # is written to odoo.conf in cleartext and copied into
    # encrypted.data.environment, i.e. into the database. Pasting key material
    # here is an easy and expensive mix-up — it leaks the secret into the very
    # dump encryption exists to protect, and leaves encryption silently off
    # because encryption_key_<that blob> is never defined. Refuse it early.
    if [ ${#RUNNING_ENV} -gt 32 ] ||
       [ -n "$(printf '%s' "$RUNNING_ENV" | tr -d 'a-zA-Z0-9_-')" ]; then
        echo "[entrypoint] ERROR: RUNNING_ENV must be a short environment name" >&2
        echo "[entrypoint]        (letters, digits, _ or -, max 32 chars), e.g." >&2
        echo "[entrypoint]        RUNNING_ENV=prod. It is not the secret — the" >&2
        echo "[entrypoint]        Fernet key belongs in ENCRYPTION_KEY." >&2
        echo "[entrypoint]        Got ${#RUNNING_ENV} chars. If you pasted a key" >&2
        echo "[entrypoint]        here, treat it as leaked and generate a new one." >&2
        exit 1
    fi
    printf '\nrunning_env = %s\n' "$RUNNING_ENV" >> "$ODOO_RC"
fi
if [ -n "$ENCRYPTION_KEY" ]; then
    if [ -z "$RUNNING_ENV" ]; then
        echo "[entrypoint] ERROR: ENCRYPTION_KEY is set but RUNNING_ENV is empty." >&2
        echo "[entrypoint]        data_encryption keys are per-environment; set" >&2
        echo "[entrypoint]        RUNNING_ENV (e.g. prod) in your .env." >&2
        exit 1
    fi
    # data_encryption feeds this straight to Fernet(), which only fails when the
    # first secret is stored — deep inside a migration, long after boot. Check it
    # here so a bad key fails loudly at the point it was configured.
    if python3 -c "import cryptography" 2>/dev/null; then
        if ! python3 -c "
import os, sys
from cryptography.fernet import Fernet
try:
    Fernet(os.environ['ENCRYPTION_KEY'].encode())
except Exception as exc:
    sys.stderr.write(str(exc) + '\n')
    sys.exit(1)
" 2>/dev/null; then
            echo "[entrypoint] ERROR: ENCRYPTION_KEY is not a valid Fernet key." >&2
            echo "[entrypoint]        It must be 32 bytes, url-safe base64 (44" >&2
            echo "[entrypoint]        chars) — a passphrase will not work. Make one:" >&2
            echo "[entrypoint]          python3 -c \"from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())\"" >&2
            exit 1
        fi
    fi
    printf 'encryption_key_%s = %s\n' "$RUNNING_ENV" "$ENCRYPTION_KEY" >> "$ODOO_RC"
    echo "[entrypoint] data encryption enabled (running_env=$RUNNING_ENV)"
elif [ -n "$RUNNING_ENV" ]; then
    echo "[entrypoint] running_env=$RUNNING_ENV (no ENCRYPTION_KEY — secrets stay in cleartext)"
fi

# --- Wait for postgres -------------------------------------------------------
echo "[entrypoint] waiting for postgres at ${DB_HOST}:${DB_PORT} ..."
until (echo > "/dev/tcp/${DB_HOST}/${DB_PORT}") 2>/dev/null; do
    sleep 1
done
echo "[entrypoint] postgres is up"

# --- Auto install / upgrade --------------------------------------------------
: "${ODOO_ADMIN_PASSWORD:=admin}"

db_exists() {
    PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" postgres 2>/dev/null | grep -q 1
}

# pin_lang_records <db> — flip noupdate on the res.lang external ids so a module
# upgrade stops reverting them.
#
# WHY: Odoo's language defaults live in odoo/addons/base/data/res.lang.csv,
# listed in base's `data` (not `demo`, and CSV files carry no noupdate flag), so
# they are imported with noupdate=False. On every `-u base` — and `-u all`
# includes base, as does UPGRADE_MODULES=auto on its first pass and after a
# base image bump — the CSV is replayed and base.lang_en's date_format goes
# back to %m/%d/%Y, silently undoing Settings > Translations > Languages.
# Nothing in the UI hints at this, which is why it reads as a random redeploy
# gremlin.
#
# THE FIX: models._load_records() skips a row when its external id is already
# marked noupdate (`if not (update and d_noupdate)`), so setting noupdate on the
# ir_model_data rows makes the re-import a no-op for res.lang and ONLY res.lang.
# Every other module's data keeps updating normally.
#
# Plain SQL on purpose: no registry load, so this cannot fail on a schema that
# the upgrade below has not applied yet.
# It is also idempotent — the WHERE clause matches nothing once pinned.
#
# TRADE-OFF: genuine upstream corrections to language data stop landing too.
# That is the point, and it is the standard Odoo answer for customised core
# data. Set LANG_NOUPDATE=0 to opt out and take upstream's values instead.
pin_lang_records() {
    local _n
    # Wrapped in a CTE so the statement is a SELECT and -tA yields exactly one
    # number: a bare `UPDATE ... RETURNING` also prints psql's "UPDATE n" tag.
    _n="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -tAc "WITH pinned AS (
                  UPDATE ir_model_data SET noupdate = true
                   WHERE model = 'res.lang' AND noupdate = false
               RETURNING 1
              ) SELECT count(*) FROM pinned" "$1" 2>/dev/null || true)"
    if [ "${_n:-0}" -gt 0 ]; then
        echo "[entrypoint] LANG_NOUPDATE: pinned ${_n} res.lang record(s) in '$1' —" \
             "Settings > Languages now survives upgrades"
    fi
}

# INIT_DB: one-shot fresh database creation (set once, then clear).
if [ -n "$INIT_DB" ] && [ "$INIT_DB" != "False" ]; then
    IFS=',' read -ra _init_dbs <<< "$INIT_DB"
    for _db in "${_init_dbs[@]}"; do
        _db="$(echo "$_db" | xargs)"  # trim whitespace
        [ -z "$_db" ] && continue
        if db_exists "$_db"; then
            echo "[entrypoint] INIT_DB: '$_db' already exists — skipping"
        else
            echo "[entrypoint] INIT_DB: creating '$_db' with base + modules"
            install_list="base"
            # 'auto'/'all' are upgrade *modes*, not module names — splicing them
            # into -i yields a dummy Odoo silently ignores, so a fresh db would
            # come up with base only. Name real modules in INSTALL_MODULES.
            case "${UPGRADE_MODULES}" in
                auto|all|"") ;;
                *)     install_list="${install_list},${UPGRADE_MODULES}" ;;
            esac
            [ -n "${INSTALL_MODULES}" ] && install_list="${install_list},${INSTALL_MODULES}"
            odoo -c "$ODOO_RC" -d "$_db" -i "$install_list" --stop-after-init
            # Library mode, not `odoo shell`: the shell reads res.users (and
            # with it every stored res.partner column) before it runs the
            # piped-in script. The password goes through the environment rather
            # than argv so it does not show up in `ps`.
            ODOO_ADMIN_PASSWORD="$ODOO_ADMIN_PASSWORD" \
                python3 - "$ODOO_RC" "$_db" <<'PYEOF'
import os
import sys
import threading

import odoo
from odoo.modules.registry import Registry

conf, db = sys.argv[1], sys.argv[2]
odoo.tools.config.parse_config(["-c", conf], setup_logging=True)
threading.current_thread().dbname = db
with Registry(db).cursor() as cr:
    env = odoo.api.Environment(cr, odoo.SUPERUSER_ID, {})
    admin = env["res.users"].browse(2)
    admin.password = os.environ["ODOO_ADMIN_PASSWORD"]
    cr.commit()
    print(f"[entrypoint] admin password set for {admin.login}")
PYEOF
        fi
    done
fi

# LANG_NOUPDATE: pin the language records BEFORE the upgrade below, so the very
# boot that would have reverted the date format is already protected. Covers the
# INIT_DB dbs too — base is installed by then, so the external ids exist.
if [ "$LANG_NOUPDATE" != "0" ] && [ "$LANG_NOUPDATE" != "False" ]; then
    for _db in $(echo "${INIT_DB},${UPGRADE_DB}" | tr ',' ' '); do
        # `[ a ] || [ b ] && continue` would abort the boot under `set -e` on the
        # pass where neither holds — the compound exits 1. Use a case instead.
        case "$_db" in ""|False) continue ;; esac
        db_exists "$_db" || continue
        pin_lang_records "$_db"
    done
fi

# OPENUPGRADE=1: migrate every UPGRADE_DB database from the previous Odoo
# series ONCE, before the normal upgrade logic below. Needs an image built with
# OPENUPGRADE=1 (/opt/openupgrade). Per database, in this order:
#   1. OpenUpgrade `-u all`: core migration scripts + the framework loaded
#      server-wide. The framework turns view validation errors into warnings
#      ("Can't render custom view"), so exit 0 here does NOT mean the views work.
#   2. Plain `-u all` without OpenUpgrade on the path: the reload that surfaces
#      the view/data errors step 1 swallowed.
#   3. `-i INSTALL_MODULES`: `-u` never installs a dependency that is new in the
#      19 version of a module (pdf_xml_attachment for account_invoice_import,
#      muk_web_group/muk_web_refresh for muk_web_theme); such a module is
#      silently skipped and stays 'to upgrade' until its new deps are installed.
#   4. Mark the database migrated (ir.config_parameter platform.openupgrade_done
#      = series), so a restart with OPENUPGRADE=1 still set skips all of this.
# Any failing step aborts the boot (set -e) WITHOUT the mark, so the next boot
# retries the whole sequence. Restore a neutralized copy first — never run this
# against the only copy of production.
: "${OPENUPGRADE:=}"
OPENUPGRADE_DIR=/opt/openupgrade
if [ "$OPENUPGRADE" = "1" ] && [ -n "$UPGRADE_DB" ] && [ "$UPGRADE_DB" != "False" ]; then
    if [ ! -d "$OPENUPGRADE_DIR/openupgrade_framework" ]; then
        echo "[entrypoint] ERROR: OPENUPGRADE=1 but $OPENUPGRADE_DIR is missing —" >&2
        echo "[entrypoint]        build the image with the build arg OPENUPGRADE=1." >&2
        exit 1
    fi
    _serie="$(python3 -c 'from odoo import release; print(release.serie)')"
    IFS=',' read -ra _ou_dbs <<< "$UPGRADE_DB"
    for _db in "${_ou_dbs[@]}"; do
        _db="$(echo "$_db" | xargs)"
        [ -z "$_db" ] && continue
        db_exists "$_db" || continue
        _done="$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -tAc \
            "SELECT value FROM ir_config_parameter WHERE key='platform.openupgrade_done'" "$_db")"
        if [ "$_done" = "$_serie" ]; then
            echo "[entrypoint] OPENUPGRADE: '$_db' already migrated to $_serie — skipping"
            continue
        fi
        echo "[entrypoint] ===== OPENUPGRADE $_db -> $_serie: step 1/4 OpenUpgrade -u all ====="
        odoo -c "$ODOO_RC" -d "$_db" \
            --addons-path="$OPENUPGRADE_DIR,$ADDONS_PATH" \
            --upgrade-path="$OPENUPGRADE_DIR/openupgrade_scripts/scripts" \
            --load=base,web,openupgrade_framework \
            -u all --stop-after-init
        echo "[entrypoint] ===== OPENUPGRADE $_db: step 2/4 plain -u all (surfaces view errors) ====="
        odoo -c "$ODOO_RC" -d "$_db" -u all --stop-after-init
        if [ -n "$INSTALL_MODULES" ]; then
            echo "[entrypoint] ===== OPENUPGRADE $_db: step 3/4 -i $INSTALL_MODULES ====="
            odoo -c "$ODOO_RC" -d "$_db" -i "$INSTALL_MODULES" --stop-after-init
        else
            echo "[entrypoint] ===== OPENUPGRADE $_db: step 3/4 skipped (INSTALL_MODULES empty) ====="
        fi
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -qc \
            "DELETE FROM ir_config_parameter WHERE key='platform.openupgrade_done';
             INSERT INTO ir_config_parameter (key, value, create_date, write_date)
             VALUES ('platform.openupgrade_done', '$_serie', now(), now())" "$_db"
        echo "[entrypoint] ===== OPENUPGRADE $_db: step 4/4 marked migrated ($_serie) ====="
    done
fi

# UPGRADE_DB: upgrade existing databases. Missing dbs are skipped.
if [ -n "$UPGRADE_DB" ] && [ "$UPGRADE_DB" != "False" ]; then
    IFS=',' read -ra _upgrade_dbs <<< "$UPGRADE_DB"
    for _db in "${_upgrade_dbs[@]}"; do
        _db="$(echo "$_db" | xargs)"
        [ -z "$_db" ] && continue
        if ! db_exists "$_db"; then
            echo "[entrypoint] UPGRADE_DB: '$_db' not found — skipping (use INIT_DB to create)"
            continue
        fi
        if [ -n "${INSTALL_MODULES}" ]; then
            echo "[entrypoint] odoo -i ${INSTALL_MODULES} (db=${_db})"
            odoo -c "$ODOO_RC" -d "$_db" -i "${INSTALL_MODULES}" --stop-after-init
        fi
        if [ "${UPGRADE_MODULES}" = "auto" ]; then
            # Checksum-based: click-odoo-update hashes every installed addon dir
            # and upgrades ONLY the ones whose files changed. The hashes live in
            # ir.config_parameter under the key OCA module_auto_update used, so
            # a database that ran that addon carries straight over.
            #
            # It finds the changed set with plain SQL, then runs the same
            # registry load as `odoo -u <those>` — nothing reads through the
            # ORM before the schema is synced. When nothing changed it upgrades
            # nothing, so restarts cost seconds.
            #
            # NOTE: the first run on a db with no saved hashes upgrades
            # everything — by design, it errs toward safety. Later runs are cheap.
            #
            # There is no `-u all` fallback. An upgrade that fails for the
            # changed modules fails the same way under `-u all`, only minutes
            # later. Hashes are saved ONLY after success, so a failure is
            # retried on the next boot, and `set -e` aborts this one rather
            # than serving a half-upgraded database.
            echo "[entrypoint] checksum upgrade (db=${_db})"
            click-odoo-update -c "$ODOO_RC" -d "$_db"
        elif [ -n "${UPGRADE_MODULES}" ]; then
            echo "[entrypoint] odoo -u ${UPGRADE_MODULES} (db=${_db})"
            odoo -c "$ODOO_RC" -d "$_db" -u "${UPGRADE_MODULES}" --stop-after-init
        fi
    done
fi

# --- Serve -------------------------------------------------------------------
echo "[entrypoint] starting odoo"
if [ "${DEBUG}" = "1" ]; then
    wait_flag=""
    [ -n "${DEBUGPY_WAIT}" ] && wait_flag="--wait-for-client"
    echo "[entrypoint] debugpy listening on 0.0.0.0:${DEBUGPY_PORT} ${wait_flag}"
    exec python3 -m debugpy --listen "0.0.0.0:${DEBUGPY_PORT}" ${wait_flag} \
        "$(command -v odoo)" -c "$ODOO_RC" "$@"
fi
exec odoo -c "$ODOO_RC" "$@"

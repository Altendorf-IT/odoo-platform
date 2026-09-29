#!/usr/bin/env bash
# Rehearse the major-version upgrade (OpenUpgrade) on a production backup.
#
#   platform/scripts/rehearse-upgrade.sh <backup.zip>
#
# Run from the PRODUCT repo root of the new-series checkout, with a .env that
# points at its own stack (COMPOSE_PROJECT_NAME, image, fresh ENCRYPTION_KEY —
# never production's). The stack always runs with the rehearsal overlay
# (platform/docker-compose.rehearsal.yml): db + odoo on an internal network,
# no internet egress.
#
# <backup.zip> is an Odoo zip backup (dump.sql + filestore/ + manifest.json).
# Steps:
#   a. restore it as database $REHEARSE_DB (dropped first) + its filestore
#   b. NEUTRALIZE before any Odoo process touches it: $NEUTRALIZE_SQL (abort
#      when its VERIFY block reports anything live), then `odoo neutralize`;
#      admin (id 2) gets the throwaway password $REHEARSE_ADMIN_PASSWORD
#   c. migrate exactly like a production cutover would: one container run of
#      the platform entrypoint with OPENUPGRADE=1 (OpenUpgrade -u all, plain
#      -u all, -i $REHEARSE_INSTALL_MODULES, mark done)
#   d. probe every module not yet ported (manifest version not <series>.x):
#      plain -u of just that module on a throwaway copy, first errors listed
#   e. report module states vs manifest.json and the log lines of interest,
#      re-run the neutralization VERIFY, start the stack for manual testing
#
# Idempotent: re-running (e.g. with a newer zip) replaces the rehearsal DB.
#
# Env (defaults in brackets; also read from .env):
#   REHEARSE_DB [rehearse]  NEUTRALIZE_SQL [tools/neutralize_db.sql]
#   REHEARSE_INSTALL_MODULES []  REHEARSE_ADMIN_PASSWORD [rehearse-admin]
#   PROBE_UNPORTED [1]  REHEARSAL_PORT [8169]
set -euo pipefail

ZIP="${1:?usage: rehearse-upgrade.sh <backup.zip>}"
[ -f "$ZIP" ] || { echo "ERROR: $ZIP not found" >&2; exit 1; }
[ -f .env ] && [ -f platform/docker-compose.rehearsal.yml ] || {
    echo "ERROR: run from the product repo root (needs .env + platform/)" >&2; exit 1; }

# Value of KEY from .env (first match, inline comment stripped), else $2.
envval() {
    local v
    v="$(grep -E "^$1=" .env | head -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//' || true)"
    echo "${v:-$2}"
}
REHEARSE_DB="${REHEARSE_DB:-$(envval REHEARSE_DB rehearse)}"
NEUTRALIZE_SQL="${NEUTRALIZE_SQL:-$(envval NEUTRALIZE_SQL tools/neutralize_db.sql)}"
INSTALL="${REHEARSE_INSTALL_MODULES-$(envval REHEARSE_INSTALL_MODULES "")}"
ADMIN_PW="${REHEARSE_ADMIN_PASSWORD:-$(envval REHEARSE_ADMIN_PASSWORD rehearse-admin)}"
PROBE_UNPORTED="${PROBE_UNPORTED:-1}"
PORT="$(envval REHEARSAL_PORT 8169)"
DB_USER="$(envval DB_USER odoo)"
[ -f "$NEUTRALIZE_SQL" ] || { echo "ERROR: $NEUTRALIZE_SQL not found" >&2; exit 1; }

DC=(docker compose -f docker-compose.yml -f platform/docker-compose.rehearsal.yml)
PSQL=("${DC[@]}" exec -T db psql -U "$DB_USER" -X -q -v ON_ERROR_STOP=1)
# One-off odoo container: internal network only, no dependency start-up.
RUN=("${DC[@]}" run --rm --no-deps -T)
DBARGS='--db_host "$DB_HOST" --db_port "$DB_PORT" --db_user "$DB_USER" --db_password "$DB_PASSWORD" --data-dir /var/lib/odoo'

OUT="$(pwd)/.local/rehearsal/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
say() { printf '\n\033[1m[rehearse] %s\033[0m\n' "$*"; }

# Parse the VERIFY output of the neutralization script; fail on anything live.
verify_neutral() {
    python3 - "$1" <<'PYEOF'
import sys
rows = [l.rstrip("\n").split("|") for l in open(sys.argv[1]) if "|" in l]
must_zero = {"active crons", "mail servers with real host", "fetchmail servers",
             "mail_mail outgoing/exception", "active online bank providers",
             "EB connections with session", "EB connections with application_id",
             "EB private keys in encrypted_data", "active backup configs",
             "active llm providers", "llm providers with api_key",
             "non-disabled payment providers", "users with password (not id 2)"}
bad, seen = [], set()
for r in rows:
    if len(r) == 2:
        name, value = r
        seen.add(name)
        print(f"  {name:40} {value}")
        if name in must_zero and value not in ("0", ""):
            bad.append(f"{name} = {value}")
        if name == "mail servers (expect 1 dummy)" and value != "1":
            bad.append(f"{name} = {value}")
        if name == "database.uuid" and not value.startswith("NEUTRALIZED-"):
            bad.append("database.uuid not neutralized")
        if name == "database.is_neutralized" and value != "True":
            bad.append("database.is_neutralized != True")
    elif len(r) == 3:
        bad.append(f"secret left in {r[0]}.{r[1]} ({r[2]} rows)")
missing = must_zero - seen
if missing:
    bad.append(f"VERIFY rows missing: {sorted(missing)}")
if bad:
    print("NEUTRALIZATION NOT VERIFIED:\n  " + "\n  ".join(bad))
    sys.exit(1)
print("  -> neutralization verified")
PYEOF
}
neutralize_sql() {
    "${PSQL[@]}" -At -F'|' -d "$REHEARSE_DB" --single-transaction < "$NEUTRALIZE_SQL" > "$OUT/neutralize-$1.out"
    verify_neutral "$OUT/neutralize-$1.out"
}

# --- a. restore ---------------------------------------------------------------
say "a. restore $ZIP -> database '$REHEARSE_DB'"
"${DC[@]}" up -d --wait db
"${DC[@]}" stop odoo gateway >/dev/null 2>&1 || true
unzip -q "$ZIP" -d "$WORK"
[ -f "$WORK/dump.sql" ] || { echo "ERROR: no dump.sql in $ZIP" >&2; exit 1; }
"${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS \"$REHEARSE_DB\" WITH (FORCE)" \
                        -c "CREATE DATABASE \"$REHEARSE_DB\" OWNER \"$DB_USER\""
# A dump from a newer pg_dump may carry settings this server lacks
# (transaction_timeout): harmless, so no ON_ERROR_STOP for the restore.
"${DC[@]}" exec -T db psql -U "$DB_USER" -X -q -d "$REHEARSE_DB" < "$WORK/dump.sql" \
    > "$OUT/restore.log" 2>&1 || true
grep -v transaction_timeout "$OUT/restore.log" | grep -i error | head -5 || true
installed=$("${PSQL[@]}" -At -d "$REHEARSE_DB" -c "SELECT count(*) FROM ir_module_module WHERE state='installed'")
echo "  restored: $installed installed modules"

# --- b. neutralize (before ANY Odoo process) ----------------------------------
say "b. neutralize: $NEUTRALIZE_SQL"
neutralize_sql restore
hash=$("${RUN[@]}" --entrypoint python3 odoo -c \
    "import sys; from passlib.context import CryptContext; print(CryptContext(['pbkdf2_sha512']).hash(sys.argv[1]))" "$ADMIN_PW" \
    | tail -n 1)  # pull_policy: build -> `run` may print build output first
case "$hash" in '$pbkdf2-sha512$'*) ;; *) echo "ERROR: no password hash: $hash" >&2; exit 1 ;; esac
"${PSQL[@]}" -d "$REHEARSE_DB" -c "UPDATE res_users SET password = '$hash' WHERE id = 2"
"${PSQL[@]}" -d "$REHEARSE_DB" -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='res_users' AND column_name='totp_secret') THEN UPDATE res_users SET totp_secret = NULL; END IF; END \$\$"
echo "  filestore -> odoo-data volume"
"${RUN[@]}" --user root -v "$WORK/filestore:/src:ro" --entrypoint sh odoo -c \
    "rm -rf '/var/lib/odoo/filestore/$REHEARSE_DB' && mkdir -p /var/lib/odoo/filestore \
     && cp -a /src '/var/lib/odoo/filestore/$REHEARSE_DB' && chown -R odoo: /var/lib/odoo"
echo "  odoo neutralize (native, per-module data/neutralize.sql)"
"${RUN[@]}" --entrypoint bash odoo -c "odoo neutralize $DBARGS -d '$REHEARSE_DB' \
    --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/opt/extra-addons/custom_addons,/opt/extra-addons/third_party_addons/_selected" \
    > "$OUT/neutralize-native.log" 2>&1
tail -1 "$OUT/neutralize-native.log"

# --- c. migrate: the entrypoint's OPENUPGRADE sequence ------------------------
say "c. OPENUPGRADE sequence (entrypoint, one container run) — log: $OUT/upgrade.log"
start=$(date +%s)
set +e
"${RUN[@]}" -e OPENUPGRADE=1 -e UPGRADE_DB="$REHEARSE_DB" -e UPGRADE_MODULES= \
    -e INSTALL_MODULES="$INSTALL" -e INIT_DB= odoo --stop-after-init > "$OUT/upgrade.log" 2>&1
rc=$?
set -e
echo "  exit $rc after $(( $(date +%s) - start ))s"
grep -E '\[entrypoint\] (=====|ADDONS_SKIP_UNPORTED: skipping)' "$OUT/upgrade.log" | sed 's/^/  /'

# --- d. probe unported modules ------------------------------------------------
if [ "$PROBE_UNPORTED" = "1" ]; then
    say "d. probe unported modules (plain -u on a throwaway copy each)"
    "${RUN[@]}" --entrypoint python3 odoo - > "$WORK/unported.txt" <<'PYEOF'
import ast, os
from odoo import release
roots = ["/opt/extra-addons/custom_addons", "/opt/extra-addons/third_party_addons/_selected"]
mods = {}
for r in roots:
    for n in sorted(os.listdir(r)):
        f = os.path.join(r, n, "__manifest__.py")
        if os.path.isfile(f):
            m = ast.literal_eval(open(f).read())
            mods[n] = (os.path.realpath(os.path.join(r, n)), m)
unported = {n for n, (_, m) in mods.items() if not str(m.get("version", "")).startswith(release.serie + ".")}
ported = [mods[n][0] for n in sorted(set(mods) - unported)]
for n in sorted(unported):
    seen, todo = set(), [n]
    while todo:          # the module + its unported dependencies, transitively
        x = todo.pop()
        if x in seen or x not in unported:
            continue
        seen.add(x)
        todo += mods[x][1].get("depends", [])
    # addons for this probe: every ported module (linked) + this one and its
    # unported deps (copied, version bumped to this series so Odoo loads them)
    print("UNPORTED", n, " ".join(ported), "--", " ".join(mods[x][0] for x in sorted(seen)))
PYEOF
    : > "$OUT/probe.txt"
    # fd 3: `docker compose exec/run` inside the loop would swallow stdin.
    # grep: `run` may print build output first (pull_policy: build).
    while read -r _ mod paths <&3; do
        state=$("${PSQL[@]}" -At -d "$REHEARSE_DB" -c "SELECT state FROM ir_module_module WHERE name='$mod'")
        if [ "$state" != "to upgrade" ] && [ "$state" != "installed" ]; then
            printf '%-48s not installed in the backup (%s) — skipped\n' "$mod" "${state:-absent}" | tee -a "$OUT/probe.txt"
            continue
        fi
        "${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS probe WITH (FORCE)" \
                                 -c "CREATE DATABASE probe TEMPLATE \"$REHEARSE_DB\""
        "${RUN[@]}" -e LINKED="${paths% -- *}" -e COPIED="${paths#* -- }" -e MOD="$mod" \
            -e DBARGS="$DBARGS" --entrypoint bash odoo -s > "$OUT/probe-$mod.log" 2>&1 <<'SH' || true
set -e
mkdir -p /tmp/probe
ln -s $LINKED /tmp/probe/
cp -rL $COPIED /tmp/probe/
serie=$(python3 -c 'from odoo import release; print(release.serie)')
for d in $COPIED; do
    sed -i -E "s/([\"']version[\"'][[:space:]]*:[[:space:]]*[\"'])[0-9]+\.0\./\1$serie./" \
        "/tmp/probe/$(basename "$d")/__manifest__.py"
done
eval "exec odoo $DBARGS -d probe --addons-path=/usr/lib/python3/dist-packages/odoo/addons,/tmp/probe \
    -u $MOD --stop-after-init"
SH
        first=$(grep -v 'inconsistent states' "$OUT/probe-$mod.log" \
            | grep -m1 -E ' (ERROR|CRITICAL) |^[A-Za-z]*(Error|Exception): ' \
            | sed -E 's/^[0-9-]+ [0-9:,]+ [0-9]+ //' | cut -c1-300 || true)
        last=$(grep -E '^[A-Za-z.]*(Error|Exception|ParseError)[:(]' "$OUT/probe-$mod.log" | tail -1 | cut -c1-300 || true)
        # A missing dependency skips the module without any ERROR line.
        skipped=$(grep -m1 -E "module $mod: .*skipped" "$OUT/probe-$mod.log" | sed -E 's/.*module_graph: //' || true)
        printf '%-48s %s\n%-48s %s\n' "$mod" "${first:-${skipped:-OK (no ERROR)}}" "" "${last}" | tee -a "$OUT/probe.txt"
    done 3< <(grep '^UNPORTED ' "$WORK/unported.txt")
    "${PSQL[@]}" -d postgres -c "DROP DATABASE IF EXISTS probe WITH (FORCE)"
fi

# --- e. report + serve --------------------------------------------------------
say "e. module states vs manifest.json"
"${PSQL[@]}" -At -F'|' -d "$REHEARSE_DB" \
    -c "SELECT name, state, coalesce(latest_version,'') FROM ir_module_module WHERE state NOT IN ('uninstalled', 'uninstallable')" \
    > "$WORK/states.txt"
python3 - "$WORK/manifest.json" "$WORK/states.txt" <<'PYEOF' | tee "$OUT/modules.txt"
import json, sys
before = json.load(open(sys.argv[1])).get("modules", {})
now = {l.split("|")[0]: l.rstrip("\n").split("|")[1:] for l in open(sys.argv[2]) if "|" in l}
groups = {}
for name in sorted(set(before) | set(now)):
    state, version = now.get(name, ["uninstalled/removed", ""])
    tag = "new in 19" if name not in before else state
    groups.setdefault(tag, []).append(f"{name} ({before.get(name, '-')} -> {version or '-'})")
for tag in sorted(groups):
    print(f"\n{tag}: {len(groups[tag])}")
    for line in groups[tag]:
        print(f"  {line}")
PYEOF
say "log lines of interest ($OUT/upgrade.log)"
grep -E ' (ERROR|CRITICAL) |Traceback|ParseError|some depends are not loaded|not installable, skipped|inconsistent states|Can.t render custom view|Invalid view|asset|Missing model' \
    "$OUT/upgrade.log" | sed -E 's/^[0-9-]+ [0-9:,]+ [0-9]+ //' | cut -c1-220 | sort | uniq -c | sort -rn | head -40 || true

say "re-verify neutralization on the migrated database"
neutralize_sql migrated

say "start the stack"
"${DC[@]}" up -d odoo gateway
cat <<EOF

[rehearse] upgrade exit code: $rc   (artifacts: $OUT)
[rehearse] URL:   http://localhost:$PORT/web/login?db=$REHEARSE_DB
[rehearse] login: $("${PSQL[@]}" -At -d "$REHEARSE_DB" -c "SELECT login FROM res_users WHERE id=2") / $ADMIN_PW
EOF
exit "$rc"

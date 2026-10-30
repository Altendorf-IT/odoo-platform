#!/usr/bin/env bash
# UPGRADE_MODULES=auto against a throwaway Postgres, with a small probe addon:
#   1. a new version that adds a stored field to res.company upgrades on boot
#      (no "column ... does not exist", no full -u all),
#   2. a boot with no change upgrades nothing,
#   3. a broken upgrade stops the boot (Odoo does not start).
# It runs the entrypoint of THIS checkout inside IMAGE, so IMAGE must be built
# from this platform/Dockerfile (it needs click-odoo-update).
#   IMAGE=<product image> platform/scripts/test-auto-upgrade.sh
# PFX names the containers and the network (default autoupg). All are removed
# at the end.
set -euo pipefail

IMAGE=${IMAGE:?set IMAGE to a product image built from platform/Dockerfile}
PFX=${PFX:-autoupg}
HERE=$(cd "$(dirname "$0")/.." && pwd)
DB=probe
TMP=$(mktemp -d)
cleanup() {
    docker rm -f -v "$PFX-pg" > /dev/null 2>&1 || true
    docker network rm "$PFX-net" > /dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

docker network create "$PFX-net" > /dev/null
docker run -d --name "$PFX-pg" --network "$PFX-net" -e POSTGRES_USER=odoo \
    -e POSTGRES_PASSWORD=odoo --tmpfs /var/lib/postgresql/data postgres:16 > /dev/null
for _ in $(seq 60); do docker exec "$PFX-pg" pg_isready -q -U odoo 2> /dev/null && break; sleep 1; done
sleep 2   # postgres restarts once after its first init
psql_() { docker exec "$PFX-pg" psql -U odoo -d "$DB" -Atc "$1"; }

# probe <version> <extra python line> [<data file>]: write the probe addon.
ADDON=$TMP/platform_upgrade_probe
touch "$TMP/required-modules.txt"
probe() {
    local data=""
    [ -z "${3:-}" ] || data="\"$3\""
    mkdir -p "$ADDON"
    echo "from . import models" > "$ADDON/__init__.py"
    cat > "$ADDON/__manifest__.py" <<EOF
{"name": "Platform upgrade probe", "version": "$1", "depends": ["base"],
 "license": "LGPL-3", "data": [$data]}
EOF
    cat > "$ADDON/models.py" <<EOF
from odoo import fields, models


class ResCompany(models.Model):
    _inherit = "res.company"

    upgrade_probe_a = fields.Char()
    $2
EOF
}

# boot <log> <env...>: one container start that stops after the entrypoint.
boot() {
    local log=$1; shift
    local envs=()
    for e in "$@"; do envs+=(-e "$e"); done
    local mounts=()
    if [ -f "$TMP/required-modules.txt" ]; then
        mounts+=(-v "$TMP/required-modules.txt:/opt/extra-addons/custom_addons/required-modules.txt:ro")
    fi
    docker run --rm --network "$PFX-net" -e DB_HOST="$PFX-pg" -e DB_NAME="$DB" \
        -e WORKERS=0 -e MAX_CRON_THREADS=0 -e UPGRADE_MODULES=auto "${envs[@]}" \
        -v "$ADDON:/opt/extra-addons/custom_addons/platform_upgrade_probe:ro" \
        "${mounts[@]}" \
        -v "$HERE/docker/entrypoint.sh:/tmp/entrypoint.sh:ro" \
        --entrypoint /bin/bash "$IMAGE" /tmp/entrypoint.sh --stop-after-init > "$log" 2>&1
}

echo "--- 0. existing database installs a repo-required probe on first auto boot"
probe 1.0.0 ""
boot "$TMP/init.log" INIT_DB="$DB" INSTALL_MODULES=base || fail "INIT_DB boot: see log"
printf '# Required by this product\n\nplatform_upgrade_probe\nplatform_upgrade_probe' > "$TMP/required-modules.txt"
boot "$TMP/first.log" UPGRADE_DB="$DB" INSTALL_MODULES=base || { tail -30 "$TMP/first.log"; fail "first auto boot exited non-zero"; }
grep -Fq 'odoo -i base,platform_upgrade_probe (db=probe)' "$TMP/first.log" || fail "required list did not merge and deduplicate"
[ "$(psql_ "SELECT state FROM ir_module_module WHERE name = 'platform_upgrade_probe'")" = installed ] \
    || fail "repo-required probe was not installed"
# An absent product file must retain the existing upgrade behavior.
rm "$TMP/required-modules.txt"
ok "repo-required module installed without an Apps refresh; environment install list preserved"

echo "--- 1. probe v2 adds a stored field to res.company"
probe 1.0.1 "upgrade_probe_b = fields.Char()"
boot "$TMP/v2.log" UPGRADE_DB="$DB" || { tail -30 "$TMP/v2.log"; fail "v2 boot exited non-zero"; }
grep "hash changed" "$TMP/v2.log" | sed 's/^.*INFO/log:/' || true
! grep -q "does not exist" "$TMP/v2.log" || fail "log has 'does not exist'"
! grep -q "\-u all" "$TMP/v2.log" || fail "log mentions -u all"
grep -q "hash changed: platform_upgrade_probe\. *$" "$TMP/v2.log" || fail "not only the probe was upgraded"
[ "$(psql_ "SELECT count(*) FROM information_schema.columns
    WHERE table_name = 'res_company' AND column_name = 'upgrade_probe_b'")" = 1 ] \
    || fail "column res_company.upgrade_probe_b is missing"
[ "$(psql_ "SELECT latest_version FROM ir_module_module WHERE name = 'platform_upgrade_probe'")" \
    = "$(psql_ "SELECT split_part(latest_version, '.', 1) || '.' || split_part(latest_version, '.', 2)
        FROM ir_module_module WHERE name = 'base'").1.0.1" ] || fail "probe version is not 1.0.1"
ok "only the changed module upgraded, new res.company column made, no error"

echo "--- 2. boot with no change"
boot "$TMP/same.log" UPGRADE_DB="$DB" || fail "no-change boot exited non-zero"
grep -q "No module needs updating" "$TMP/same.log" || fail "no-change boot upgraded something"
ok "no-change boot upgrades nothing"

echo "--- 3. probe v3 has a broken view"
probe 1.0.2 "upgrade_probe_b = fields.Char()" broken.xml
cat > "$ADDON/broken.xml" <<'EOF'
<odoo><record id="broken_view" model="ir.ui.view"><field name="model">res.company</field>
<field name="inherit_id" ref="base.view_company_form"/><field name="arch" type="xml">
<field name="no_such_field" position="after"><field name="upgrade_probe_b"/></field>
</field></record></odoo>
EOF
if boot "$TMP/v3.log" UPGRADE_DB="$DB"; then fail "boot with a broken upgrade exited 0"; fi
! grep -q "\[entrypoint\] starting odoo" "$TMP/v3.log" || fail "Odoo started after a failed upgrade"
! grep -q "\-u all" "$TMP/v3.log" || fail "log mentions -u all"
ok "broken upgrade: exit code not 0, Odoo not started, no -u all"
echo "ALL PASS"

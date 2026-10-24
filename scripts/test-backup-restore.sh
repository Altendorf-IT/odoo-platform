#!/usr/bin/env bash
# Full backup -> retention -> failure alert -> restore cycle against throwaway
# containers (Postgres, SFTP server, ping receiver). Needs only Docker. The
# source is a real Odoo database (base), made with ODOO_IMAGE, and the
# decrypted zip is also restored by Odoo's own restore_db() (the code behind
# the Restore button of the database manager).
#   platform/scripts/test-backup-restore.sh
#   ODOO_IMAGE=<product image> platform/scripts/test-backup-restore.sh
# PFX names the containers and the network (default bkptest). All are removed
# at the end. The age key pair and the SFTP password exist only in a temp dir.
set -euo pipefail

PFX=${PFX:-bkptest}
ODOO_IMAGE=${ODOO_IMAGE:-odoo:19.0}
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMG=$PFX-image
SRC=${PFX//-/_}_src DST=${PFX//-/_}_dst ODB=${PFX//-/_}_odoo
TMP=$(mktemp -d)
cleanup() {
    docker rm -f -v "$PFX-pg" "$PFX-sftp" "$PFX-ping" "$PFX-idle" > /dev/null 2>&1 || true
    docker network rm "$PFX-net" > /dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT
ok() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

docker build -q -t "$IMG" "$HERE/backup" > /dev/null
docker network create "$PFX-net" > /dev/null
SFTP_PW=$(openssl rand -hex 12)
docker run -d --name "$PFX-pg" --network "$PFX-net" -e POSTGRES_USER=odoo \
    -e POSTGRES_PASSWORD=odoo --tmpfs /var/lib/postgresql/data postgres:16 > /dev/null
docker run -d --name "$PFX-sftp" --network "$PFX-net" -e SFTP_PW="$SFTP_PW" alpine:3.20 sh -c '
    apk add --no-cache openssh-server > /dev/null && ssh-keygen -A > /dev/null &&
    adduser -D bkp && echo "bkp:$SFTP_PW" | chpasswd 2> /dev/null &&
    mkdir /home/bkp/odoo && chown bkp /home/bkp/odoo && exec /usr/sbin/sshd -D -e' > /dev/null
# Ping receiver: answers 200 and prints each request line to its log.
docker run -d --name "$PFX-ping" --network "$PFX-net" alpine:3.20 sh -c '
    while true; do printf "HTTP/1.0 200 OK\r\n\r\n" | nc -l -p 8080 | head -1; done' > /dev/null
for _ in $(seq 60); do
    docker exec "$PFX-pg" pg_isready -q -U odoo 2> /dev/null &&
        docker exec "$PFX-sftp" test -f /run/sshd.pid 2> /dev/null && break
    sleep 1
done
sleep 2   # postgres restarts once after its first init

docker run --rm --entrypoint age-keygen "$IMG" > "$TMP/age-key.txt" 2> /dev/null
RECIPIENT=$(grep -o 'age1[a-z0-9]*' "$TMP/age-key.txt" | head -1)
HOST_KEY="$PFX-sftp $(docker exec "$PFX-sftp" cut -d' ' -f1,2 /etc/ssh/ssh_host_ed25519_key.pub)"

# Source data: an Odoo database with base (its filestore in $TMP/fs), one
# extra table with 1000 rows and 3 extra filestore files.
psql_() { docker exec "$PFX-pg" psql -U odoo -v ON_ERROR_STOP=1 -At "$@"; }
# odoo_ <args...>: Odoo of ODOO_IMAGE against the test Postgres, data dir /data.
odoo_() {
    docker run --rm --network "$PFX-net" -v "$TMP/odata:/data" "$@"
}
ODOO_DB_ARGS="--db_host=$PFX-pg --db_user=odoo --db_password=odoo --data-dir=/data"
mkdir -p "$TMP/fs" "$TMP/fs2" "$TMP/odata/filestore" "$TMP/zip"
chmod 777 "$TMP/fs" "$TMP/odata" "$TMP/odata/filestore" "$TMP/zip"
odoo_ -v "$TMP/fs:/data/filestore" --entrypoint odoo "$ODOO_IMAGE" $ODOO_DB_ARGS \
    -d "$SRC" -i base --stop-after-init > "$TMP/odoo-init.log" 2>&1 \
    || { tail -20 "$TMP/odoo-init.log"; fail "Odoo could not make the source database"; }
psql_ -d "$SRC" -c "CREATE TABLE t AS SELECT g AS id, md5(g::text) AS v FROM generate_series(1, 1000) g" > /dev/null
mkdir -p "$TMP/fs/$SRC/ab" "$TMP/fs/$SRC/cd"
for f in ab/ab01 ab/ab02 cd/cd01; do head -c 4096 /dev/urandom > "$TMP/fs/$SRC/$f"; done
table_sum() { psql_ -d "$1" -c "SELECT count(*) || ' rows ' || md5(string_agg(id || v, ',' ORDER BY id)) FROM t"; }
files_sum() { (cd "$1" && find . -type f | sort | xargs shasum -a 256); }

# Remote files: 60 days old (must go: an old 3-file set and a zip), 10 days
# old (must stay), unfinished uploads 2 days old (must go) and 2 hours old
# (must stay), and a file of another database (must stay).
ago() { docker exec "$PFX-sftp" sh -c "date -u -d \"@\$((\$(date +%s) - $1))\" +%Y%m%dT%H%M%SZ"; }
old=$(ago $((60 * 86400))) mid=$(ago $((10 * 86400))) part_old=$(ago $((2 * 86400))) part_new=$(ago 7200)
docker exec -u bkp "$PFX-sftp" sh -c "cd /home/bkp/odoo && touch ${SRC}_$old.dump.age \
    ${SRC}_$old.filestore.tar.gz.age ${SRC}_$old.sha256 ${SRC}_$old.zip.age ${SRC}_$mid.zip.age \
    ${SRC}_$part_old.zip.age.part ${SRC}_$part_new.zip.age.part other_$old.zip.age"

run() {  # run <filestore dir> <BACKUP_DBS> <command...>
    local fs=$1 dbs=$2; shift 2
    docker run --rm --network "$PFX-net" -v "$fs:/var/lib/odoo/filestore" \
        -v "${KEY_OVERRIDE:-$TMP/age-key.txt}:/age-key.txt:ro" \
        -e PGHOST="$PFX-pg" -e PGUSER=odoo -e PGPASSWORD=odoo -e BACKUP_DBS="$dbs" \
        -e BACKUP_KEEP_DAYS=50 -e BACKUP_AGE_RECIPIENT="$RECIPIENT" \
        -e BACKUP_SFTP_HOST="$PFX-sftp" -e BACKUP_SFTP_USER=bkp -e BACKUP_SFTP_PASSWORD="$SFTP_PW" \
        -e BACKUP_SFTP_DIR=odoo -e BACKUP_SFTP_HOST_KEY="$HOST_KEY" \
        -e BACKUP_PING_URL="http://$PFX-ping:8080/ping/test" "$IMG" "$@"
}
remote() { docker exec "$PFX-sftp" ls /home/bkp/odoo; }
pings() { docker logs "$PFX-ping" 2>&1 | grep -c "GET /ping/test$1 " || true; }

echo "--- 0. not set up"
docker run -d --name "$PFX-idle" "$IMG" > /dev/null
sleep 3
[ "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$PFX-idle")" = "true 0" ] \
    || fail "no BACKUP_DBS: container is not running"
[ "$(docker logs "$PFX-idle" 2>&1)" = "backup: off, BACKUP_DBS is not set" ] || fail "no BACKUP_DBS: wrong log"
t0=$(date +%s); docker stop "$PFX-idle" > /dev/null; t1=$(date +%s)
[ "$(docker inspect -f '{{.State.ExitCode}}' "$PFX-idle")" = 0 ] && [ $((t1 - t0)) -lt 5 ] \
    || fail "no BACKUP_DBS: docker stop is slow or exit code not 0"
ok "no BACKUP_DBS: logs one line, idles (no exit, no restart), stops at once with 0"
if out=$(docker run --rm -e BACKUP_DBS=x "$IMG" 2>&1); then fail "incomplete setup exited 0"; fi
[ "$out" = "backup: ERROR: BACKUP_AGE_RECIPIENT is not set" ] || fail "incomplete setup: wrong log: $out"
ok "BACKUP_DBS set, other variable missing: stops with 'backup: ERROR: BACKUP_AGE_RECIPIENT is not set'"

echo "--- 1. backup + retention"
run "$TMP/fs" "$SRC" backup
remote | sed 's/^/remote: /'
new=$(remote | grep "^${SRC}_" | grep -v -e "^${SRC}_$mid" -e "^${SRC}_$part_new" || true)
[ "$(echo "$new" | wc -w | tr -d " ")" = 1 ] && expr "$new" : "${SRC}_[0-9]\{8\}T[0-9]\{6\}Z\.zip\.age$" > /dev/null \
    || fail "expected exactly one new file <db>_<stamp>.zip.age, got: $new"
[ "$(remote | grep -c -e "^${SRC}_$old" -e "^${SRC}_$part_old")" = 0 ] \
    || fail "60-day-old files or the 2-day-old .part still there"
remote | grep -q "^${SRC}_$mid.zip.age$" || fail "10-day-old file was deleted"
remote | grep -q "^${SRC}_$part_new.zip.age.part$" || fail "2-hour-old .part was deleted"
remote | grep -q "^other_$old.zip.age$" || fail "file of another database was deleted"
ok "1 file uploaded ($new, no .part, no .sha256); 60-day-old files (old 3-file set and zip)" \
    "and 2-day-old .part deleted; 10-day-old file, 2-hour-old .part, other database kept"
[ "$(docker exec "$PFX-sftp" head -c 21 "/home/bkp/odoo/$new")" = "age-encryption.org/v1" ] || fail "backup is not age-encrypted"
ok "remote file starts with the age header (not readable without the private key)"
[ "$(pings /start)" = 1 ] && [ "$(pings "")" = 1 ] && [ "$(pings /fail)" = 0 ] || fail "pings after success: wrong"
ok "ping: 1 start, 1 success, 0 fail"

echo "--- 2. failure: database does not exist"
before=$(remote | wc -l)
if run "$TMP/fs" "${SRC}_missing" backup; then fail "backup of a missing database exited 0"; fi
[ "$(pings /fail)" = 1 ] || fail "no /fail ping"
[ "$(remote | wc -l)" = "$before" ] || fail "a failed run changed the remote directory"
ok "exit code not 0, /fail ping sent, remote files unchanged"

echo "--- 3. zip-only: decrypt to an Odoo backup zip, restore it with Odoo's restore_db()"
run "$TMP/fs2" "" restore "$SRC" latest --zip-only > "$TMP/zip/backup.zip"
docker run --rm -v "$TMP/zip:/zip:ro" --entrypoint unzip "$IMG" -Z1 /zip/backup.zip > "$TMP/zip.list"
head -2 "$TMP/zip.list" | sed 's/^/zip: /'; echo "zip: ... $(wc -l < "$TMP/zip.list" | tr -d " ") entries"
[ "$(head -2 "$TMP/zip.list" | tr '\n' ' ')" = "dump.sql manifest.json " ] \
    && [ "$(grep -c '^filestore/' "$TMP/zip.list")" = "$(cd "$TMP/fs/$SRC" && find . -type f | wc -l | tr -d ' ')" ] \
    && ! grep -v -e '^dump.sql$' -e '^manifest.json$' -e '^filestore/[^/].*[^/]$' "$TMP/zip.list" \
    || fail "zip is not dump.sql + manifest.json + filestore/<every file>"
docker run --rm -v "$TMP/zip:/zip:ro" --entrypoint unzip "$IMG" -p /zip/backup.zip manifest.json > "$TMP/manifest.json"
python3 - "$TMP/manifest.json" "$SRC" <<'PYEOF' || fail "manifest.json is not like Odoo's"
import json, sys
m = json.load(open(sys.argv[1]))
assert set(m) == {"odoo_dump", "db_name", "version", "version_info", "major_version", "pg_version", "modules"}, m.keys()
assert m["odoo_dump"] == "1" and m["db_name"] == sys.argv[2], m
assert m["version"] == m["major_version"] and m["version_info"][:2] == [int(x) for x in m["version"].split(".")], m
assert m["pg_version"] == "16.0" and m["modules"]["base"].startswith(m["version"] + "."), m
print("manifest: version %s, pg %s, %d modules" % (m["version"], m["pg_version"], len(m["modules"])))
PYEOF
odoo_ -v "$TMP/zip:/zip:ro" --entrypoint python3 "$ODOO_IMAGE" -c "
import odoo, odoo.service.db
odoo.tools.config.parse_config('$ODOO_DB_ARGS'.split(), setup_logging=True)
odoo.service.db.restore_db('$ODB', '/zip/backup.zip')
" > "$TMP/odoo-restore.log" 2>&1 || { tail -20 "$TMP/odoo-restore.log"; fail "Odoo's restore_db() failed"; }
a=$(table_sum "$SRC") b=$(table_sum "$ODB")
echo "source table:        $a"; echo "Odoo-restored table: $b"
[ "$a" = "$b" ] || fail "table differs after Odoo's restore"
files_sum "$TMP/fs/$SRC" > "$TMP/a.sum"; files_sum "$TMP/odata/filestore/$ODB" > "$TMP/o.sum"
[ -s "$TMP/a.sum" ] && diff "$TMP/a.sum" "$TMP/o.sum" > /dev/null || fail "filestore differs after Odoo's restore"
echo "filestore: $(wc -l < "$TMP/a.sum" | tr -d ' ') files, same SHA-256 sums"
[ "$(psql_ -d "$ODB" -c "SELECT count(*) FROM ir_module_module WHERE state = 'installed'")" \
    = "$(psql_ -d "$SRC" -c "SELECT count(*) FROM ir_module_module WHERE state = 'installed'")" ] \
    || fail "installed modules differ"
ok "Odoo's restore_db() accepts the zip; table, filestore and modules equal to the source"

echo "--- 4. restore"
KEY_OVERRIDE=$TMP/wrong-key.txt
docker run --rm --entrypoint age-keygen "$IMG" > "$KEY_OVERRIDE" 2> /dev/null
if run "$TMP/fs2" "" restore "$SRC" latest "$DST"; then fail "restore with a wrong key exited 0"; fi
[ -z "$(psql_ -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$DST'")" ] || fail "wrong key left a database"
ok "wrong private key: restore stops, no database made"
KEY_OVERRIDE=
run "$TMP/fs2" "" restore "$SRC" latest "$DST"
a=$(table_sum "$SRC") b=$(table_sum "$DST")
echo "source table:   $a"; echo "restored table: $b"
[ "$a" = "$b" ] || fail "table differs"
files_sum "$TMP/fs/$SRC" > "$TMP/a.sum"; files_sum "$TMP/fs2/$DST" > "$TMP/b.sum"
[ -s "$TMP/a.sum" ] && diff "$TMP/a.sum" "$TMP/b.sum" > /dev/null || fail "filestore differs"
echo "filestore: $(wc -l < "$TMP/a.sum" | tr -d ' ') files, same SHA-256 sums"
ok "restored database and filestore are equal to the source"
if run "$TMP/fs2" "" restore "$SRC" latest "$DST"; then fail "second restore overwrote $DST"; fi
ok "restore refuses an existing target"
echo "ALL PASS"

#!/usr/bin/env bash
# Full backup -> retention -> failure alert -> restore cycle against throwaway
# containers (Postgres, SFTP server, ping receiver). Needs only Docker.
#   platform/scripts/test-backup-restore.sh
# PFX names the containers and the network (default bkptest). All are removed
# at the end. The age key pair and the SFTP password exist only in a temp dir.
set -euo pipefail

PFX=${PFX:-bkptest}
HERE=$(cd "$(dirname "$0")/.." && pwd)
IMG=$PFX-image
SRC=${PFX//-/_}_src DST=${PFX//-/_}_dst
TMP=$(mktemp -d)
cleanup() {
    docker rm -f -v "$PFX-pg" "$PFX-sftp" "$PFX-ping" > /dev/null 2>&1 || true
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

# Source data: one table with 1000 rows and a fake filestore with 3 files.
psql_() { docker exec "$PFX-pg" psql -U odoo -v ON_ERROR_STOP=1 -At "$@"; }
psql_ -d postgres -c "CREATE DATABASE $SRC" > /dev/null
psql_ -d "$SRC" -c "CREATE TABLE t AS SELECT g AS id, md5(g::text) AS v FROM generate_series(1, 1000) g" > /dev/null
mkdir -p "$TMP/fs/$SRC/ab" "$TMP/fs/$SRC/cd" "$TMP/fs2"
for f in ab/ab01 ab/ab02 cd/cd01; do head -c 4096 /dev/urandom > "$TMP/fs/$SRC/$f"; done
table_sum() { psql_ -d "$1" -c "SELECT count(*) || ' rows ' || md5(string_agg(id || v, ',' ORDER BY id)) FROM t"; }
files_sum() { (cd "$1" && find . -type f | sort | xargs shasum -a 256); }

# Remote files from 60 days ago (must go) and from 10 days ago (must stay).
old=$(docker exec "$PFX-sftp" sh -c 'date -u -d "@$(($(date +%s) - 60 * 86400))" +%Y%m%dT%H%M%SZ')
mid=$(docker exec "$PFX-sftp" sh -c 'date -u -d "@$(($(date +%s) - 10 * 86400))" +%Y%m%dT%H%M%SZ')
docker exec -u bkp "$PFX-sftp" sh -c "cd /home/bkp/odoo && touch ${SRC}_$old.dump.age \
    ${SRC}_$old.filestore.tar.gz.age ${SRC}_$old.sha256 ${SRC}_$mid.sha256 other_$old.sha256"

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

echo "--- 1. backup + retention"
run "$TMP/fs" "$SRC" backup
remote | sed 's/^/remote: /'
[ "$(remote | grep -c "^${SRC}_" )" = 4 ] || fail "expected 3 new files + 1 kept file"
[ "$(remote | grep -c "^${SRC}_$old")" = 0 ] || fail "60-day-old files still there"
remote | grep -q "^${SRC}_$mid.sha256" || fail "10-day-old file was deleted"
remote | grep -q "^other_$old.sha256" || fail "file of another database was deleted"
ok "3 files uploaded, 60-day-old set deleted, 10-day-old file and other database kept"
new=$(remote | grep "^${SRC}_.*dump.age" | tail -1)
[ "$(docker exec "$PFX-sftp" head -c 21 "/home/bkp/odoo/$new")" = "age-encryption.org/v1" ] || fail "dump is not age-encrypted"
ok "remote dump starts with the age header (not readable without the private key)"
[ "$(pings /start)" = 1 ] && [ "$(pings "")" = 1 ] && [ "$(pings /fail)" = 0 ] || fail "pings after success: wrong"
ok "ping: 1 start, 1 success, 0 fail"

echo "--- 2. failure: database does not exist"
before=$(remote | wc -l)
if run "$TMP/fs" "${SRC}_missing" backup; then fail "backup of a missing database exited 0"; fi
[ "$(pings /fail)" = 1 ] || fail "no /fail ping"
[ "$(remote | wc -l)" = "$before" ] || fail "a failed run changed the remote directory"
ok "exit code not 0, /fail ping sent, remote files unchanged"

echo "--- 3. restore"
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
sed 's/^/source file:   /' "$TMP/a.sum"; sed 's/^/restored file: /' "$TMP/b.sum"
[ -s "$TMP/a.sum" ] && diff "$TMP/a.sum" "$TMP/b.sum" > /dev/null || fail "filestore differs"
ok "restored database and filestore are equal to the source"
if run "$TMP/fs2" "" restore "$SRC" latest "$DST"; then fail "second restore overwrote $DST"; fi
ok "restore refuses an existing target"
echo "ALL PASS"

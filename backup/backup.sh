#!/bin/sh
# One backup run: for each database in BACKUP_DBS, pg_dump (custom format) and
# the filestore go through `age` (public key only) to the SFTP target. Then the
# remote files older than BACKUP_KEEP_DAYS are deleted. See DEPLOY.md.
set -euo pipefail
. /usr/local/bin/lib.sh

# Tell the monitor (a healthchecks.io-style ping URL) about start/success/fail.
notify() {
    [ -n "${BACKUP_PING_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 --retry-connrefused -o /dev/null "$BACKUP_PING_URL$1" \
        || echo "backup: WARNING: ping $1 failed" >&2
}

STEP=configuration
WORK=
finish() {
    status=$?
    [ -z "$WORK" ] || rm -rf "$WORK"
    if [ "$status" -ne 0 ]; then
        echo "backup: FAILED at step: $STEP (exit $status)" >&2
        notify /fail
    fi
}
trap finish EXIT

notify /start
require BACKUP_DBS BACKUP_AGE_RECIPIENT BACKUP_SFTP_HOST BACKUP_SFTP_USER \
    BACKUP_SFTP_DIR BACKUP_SFTP_HOST_KEY PGHOST PGUSER PGPASSWORD
KEEP_DAYS=${BACKUP_KEEP_DAYS:-50}
[ "$KEEP_DAYS" -ge 1 ] || die "BACKUP_KEEP_DAYS must be 1 or more"

WORK=$(mktemp -d)
stamp=$(date -u +%Y%m%dT%H%M%SZ)

for db in $BACKUP_DBS; do
    base=${db}_$stamp
    # Database first, filestore second: every attachment that the dump names
    # is then in the archive, because Odoo only adds filestore files.
    STEP="pg_dump $db"
    pg_dump -Fc --no-owner "$db" | age -r "$BACKUP_AGE_RECIPIENT" -o "$WORK/$base.dump.age"
    STEP="filestore $db"
    [ -d "$FILESTORE/$db" ] || die "no filestore directory $FILESTORE/$db"
    tar -czf - -C "$FILESTORE" "$db" \
        | age -r "$BACKUP_AGE_RECIPIENT" -o "$WORK/$base.filestore.tar.gz.age"
    # The .sha256 file goes last. A backup without it is not complete.
    STEP="upload $db"
    (cd "$WORK" && sha256sum "$base.dump.age" "$base.filestore.tar.gz.age" > "$base.sha256")
    sftp_batch <<BATCH
put $WORK/$base.dump.age $BACKUP_SFTP_DIR/$base.dump.age
put $WORK/$base.filestore.tar.gz.age $BACKUP_SFTP_DIR/$base.filestore.tar.gz.age
put $WORK/$base.sha256 $BACKUP_SFTP_DIR/$base.sha256
BATCH
    echo "backup: uploaded $base ($(du -ch "$WORK/$base".* | tail -1 | cut -f1))"
    rm -f "$WORK/$base".*
done

# Retention runs only when every upload worked.
cutoff=$(date -u -d "@$(($(date -u +%s) - KEEP_DAYS * 86400))" +%Y%m%dT%H%M%SZ)
for db in $BACKUP_DBS; do
    STEP="retention $db"
    for file in $(remote_files "$db"); do
        file_stamp=${file#"${db}_"}
        file_stamp=${file_stamp%%.*}
        if expr "$file_stamp" \< "$cutoff" > /dev/null; then
            echo "rm $BACKUP_SFTP_DIR/$file"
            echo "backup: deleted $file (older than $KEEP_DAYS days)" >&2
        fi
    done | sftp_batch > /dev/null
done

notify ""
echo "backup: OK $stamp"

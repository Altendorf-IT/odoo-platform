#!/bin/sh
# One backup run: for each database in BACKUP_DBS, make one Odoo backup zip
# (dump.sql, filestore/, manifest.json: the format of Odoo's own "Backup" in
# the database manager), encrypt it with `age` (public key only) and upload it
# to the SFTP target as <db>_<UTC stamp>.zip.age. Then the remote files older
# than BACKUP_KEEP_DAYS are deleted. See DEPLOY.md.
set -euo pipefail
. /usr/local/bin/lib.sh

# Tell the monitor (a healthchecks.io-style ping URL) about start/success/fail.
notify() {
    [ -n "${BACKUP_PING_URL:-}" ] || return 0
    curl -fsS -m 10 --retry 3 --retry-connrefused -o /dev/null "$BACKUP_PING_URL$1" \
        || echo "backup: WARNING: ping $1 failed" >&2
}

# manifest.json as Odoo's dump_db_manifest() writes it. The sidecar has no
# Odoo, so the version comes from the installed `base` module: the series
# (19.0), not the build stamp of the image (19.0-20261015). Odoo's restore
# does not read the manifest.
manifest() {
    psql -X -At -v ON_ERROR_STOP=1 -d "$1" -c "
        SELECT jsonb_pretty(jsonb_build_object(
            'odoo_dump', '1',
            'db_name', current_database(),
            'version', v.serie,
            'version_info', jsonb_build_array(v.major, v.minor, 0, 'final', 0, ''),
            'major_version', v.serie,
            'pg_version', current_setting('server_version_num')::int / 10000
                || '.' || current_setting('server_version_num')::int / 100 % 100,
            'modules', (SELECT jsonb_object_agg(name, latest_version)
                          FROM ir_module_module WHERE state = 'installed')))
          FROM (SELECT split_part(latest_version, '.', 1)
                       || '.' || split_part(latest_version, '.', 2) AS serie,
                       split_part(latest_version, '.', 1)::int AS major,
                       split_part(latest_version, '.', 2)::int AS minor
                  FROM ir_module_module WHERE name = 'base') v"
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
    name=${db}_$stamp.zip.age
    STEP="dump $db"
    [ -d "$FILESTORE/$db" ] || die "no filestore directory $FILESTORE/$db"
    mkdir "$WORK/$db"
    manifest "$db" > "$WORK/$db/manifest.json"
    # Database first, filestore second: every attachment that the dump names
    # is then in the zip, because Odoo only adds filestore files.
    pg_dump --no-owner --file="$WORK/$db/dump.sql" "$db"
    # The link puts the filestore at filestore/ in the zip without a copy;
    # zip follows it. -D: file entries only, as Odoo's zip has.
    ln -s "$FILESTORE/$db" "$WORK/$db/filestore"
    STEP="zip $db"
    (cd "$WORK/$db" && zip -q -r -D "$WORK/$db.zip" dump.sql manifest.json filestore)
    rm -rf "$WORK/$db"
    STEP="encrypt $db"
    age -r "$BACKUP_AGE_RECIPIENT" -o "$WORK/$name" "$WORK/$db.zip"
    rm -f "$WORK/$db.zip"
    # age authenticates the file, so a damaged or cut file does not decrypt.
    # The .part name keeps a half-uploaded file from looking like a backup.
    STEP="upload $db"
    sftp_batch <<BATCH
put $WORK/$name $BACKUP_SFTP_DIR/$name.part
rename $BACKUP_SFTP_DIR/$name.part $BACKUP_SFTP_DIR/$name
BATCH
    echo "backup: uploaded $name ($(du -h "$WORK/$name" | cut -f1))"
    rm -f "$WORK/$name"
done

# Retention runs only when every upload worked. It deletes every file of these
# databases that is older than KEEP_DAYS (also the 3-file sets made before the
# zip format), and .part files left by a failed upload after one day.
cutoff=$(date -u -d "@$(($(date -u +%s) - KEEP_DAYS * 86400))" +%Y%m%dT%H%M%SZ)
part_cutoff=$(date -u -d "@$(($(date -u +%s) - 86400))" +%Y%m%dT%H%M%SZ)
for db in $BACKUP_DBS; do
    STEP="retention $db"
    for file in $(remote_files "$db"); do
        file_stamp=${file#"${db}_"}
        file_stamp=${file_stamp%%.*}
        case $file in
            *.part) limit=$part_cutoff reason="unfinished upload older than 1 day" ;;
            *) limit=$cutoff reason="older than $KEEP_DAYS days" ;;
        esac
        if expr "$file_stamp" \< "$limit" > /dev/null; then
            echo "rm $BACKUP_SFTP_DIR/$file"
            echo "backup: deleted $file ($reason)" >&2
        fi
    done | sftp_batch > /dev/null
done

notify ""
echo "backup: OK $stamp"

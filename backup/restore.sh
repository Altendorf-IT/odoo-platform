#!/bin/sh
# Restore one backup into a NEW database:
#   restore.sh <source_db> <stamp|latest> <target_db>
# Or only decrypt it to an Odoo backup zip on stdout, for the Restore button
# of the Odoo database manager (no database is touched):
#   restore.sh <source_db> <stamp|latest> --zip-only > <file>.zip
# Needs the private age key at BACKUP_AGE_IDENTITY_FILE (default /age-key.txt).
# It never overwrites: it stops if <target_db> or its filestore exists.
set -euo pipefail
. /usr/local/bin/lib.sh

[ $# -eq 3 ] || die "usage: restore <source_db> <stamp|latest> <target_db|--zip-only>"
src=$1 stamp=$2 target=$3
key=${BACKUP_AGE_IDENTITY_FILE:-/age-key.txt}
require BACKUP_SFTP_HOST BACKUP_SFTP_USER BACKUP_SFTP_DIR BACKUP_SFTP_HOST_KEY
[ -r "$key" ] || die "no private age key at $key"
if [ "$target" = --zip-only ]; then
    [ ! -t 1 ] || die "--zip-only writes the zip to stdout: add '> <file>.zip' (and -T to docker compose run)"
else
    require PGHOST PGUSER PGPASSWORD
    [ ! -e "$FILESTORE/$target" ] || die "filestore $FILESTORE/$target exists"
    if psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$target'" | grep -q 1; then
        die "database $target exists"
    fi
fi

if [ "$stamp" = latest ]; then
    stamp=$(remote_files "$src" | { grep '\.zip\.age$' || true; } | tail -1 | sed "s/^${src}_//; s/\..*//")
    [ -n "$stamp" ] || die "no backup of $src on the target"
fi
name=${src}_$stamp.zip.age

WORK=$(mktemp -d)
trap 'rm -rf "$WORK" "$FILESTORE/.restore.$$"' EXIT
echo "get $BACKUP_SFTP_DIR/$name $WORK/" | sftp_batch > /dev/null

# Decrypt first, to a file: a wrong key or a damaged file stops here, before
# a database exists and before a byte goes to stdout.
age -d -i "$key" -o "$WORK/backup.zip" "$WORK/$name"
rm -f "$WORK/$name"

if [ "$target" = --zip-only ]; then
    cat "$WORK/backup.zip"
    echo "restore: OK $name -> Odoo backup zip on stdout" >&2
    echo "restore: a copy of production must be neutralized: tick 'Neutralize' in the database manager." >&2
    exit 0
fi

mkdir -p "$FILESTORE/.restore.$$"
if [ "$(unzip -Z1 "$WORK/backup.zip" | grep -c '^filestore/' || true)" != 0 ]; then
    unzip -q "$WORK/backup.zip" 'filestore/*' -d "$FILESTORE/.restore.$$"
else
    mkdir "$FILESTORE/.restore.$$/filestore"
fi
# As Odoo's restore_db(): an empty UTF8 database with C collation, then psql.
createdb -T template0 -E UTF8 --lc-collate=C "$target"
unzip -p "$WORK/backup.zip" dump.sql \
    | psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$target" > /dev/null
mv "$FILESTORE/.restore.$$/filestore" "$FILESTORE/$target"

echo "restore: OK $name -> database $target, filestore $FILESTORE/$target"
echo "restore: the backup does NOT hold the environment (ENCRYPTION_KEY, RUNNING_ENV, ...)."
echo "restore: a copy of production must be neutralized before Odoo starts on it."

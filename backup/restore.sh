#!/bin/sh
# Restore one backup into a NEW database:
#   restore.sh <source_db> <stamp|latest> <target_db>
# Needs the private age key at BACKUP_AGE_IDENTITY_FILE (default /age-key.txt).
# It never overwrites: it stops if <target_db> or its filestore exists.
set -euo pipefail
. /usr/local/bin/lib.sh

[ $# -eq 3 ] || die "usage: restore <source_db> <stamp|latest> <target_db>"
src=$1 stamp=$2 target=$3
key=${BACKUP_AGE_IDENTITY_FILE:-/age-key.txt}
require BACKUP_SFTP_HOST BACKUP_SFTP_USER BACKUP_SFTP_DIR BACKUP_SFTP_HOST_KEY \
    PGHOST PGUSER PGPASSWORD
[ -r "$key" ] || die "no private age key at $key"
[ ! -e "$FILESTORE/$target" ] || die "filestore $FILESTORE/$target exists"
if psql -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$target'" | grep -q 1; then
    die "database $target exists"
fi

if [ "$stamp" = latest ]; then
    stamp=$(remote_files "$src" | grep '\.sha256$' | tail -1 | sed "s/^${src}_//; s/\..*//")
    [ -n "$stamp" ] || die "no complete backup of $src on the target"
fi
base=${src}_$stamp

WORK=$(mktemp -d)
trap 'rm -rf "$WORK" "$FILESTORE/.restore.$$"' EXIT
sftp_batch <<BATCH
get $BACKUP_SFTP_DIR/$base.sha256 $WORK/
get $BACKUP_SFTP_DIR/$base.dump.age $WORK/
get $BACKUP_SFTP_DIR/$base.filestore.tar.gz.age $WORK/
BATCH
(cd "$WORK" && sha256sum -c "$base.sha256")

# Decrypt the filestore first: a wrong key stops here, before a database exists.
mkdir -p "$FILESTORE/.restore.$$"
age -d -i "$key" "$WORK/$base.filestore.tar.gz.age" | tar -xzf - -C "$FILESTORE/.restore.$$"
createdb -T template0 -E UTF8 --lc-collate=C "$target"
age -d -i "$key" "$WORK/$base.dump.age" | pg_restore --no-owner --exit-on-error -d "$target"
mv "$FILESTORE/.restore.$$/$src" "$FILESTORE/$target"

echo "restore: OK $base -> database $target, filestore $FILESTORE/$target"
echo "restore: the backup does NOT hold the environment (ENCRYPTION_KEY, RUNNING_ENV, ...)."
echo "restore: a copy of production must be neutralized before Odoo starts on it."

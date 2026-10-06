# Shared helpers for backup.sh and restore.sh. Sourced, not executed.

FILESTORE=${BACKUP_FILESTORE_ROOT:-/var/lib/odoo/filestore}

die() { echo "backup: ERROR: $*" >&2; exit 1; }

require() {
    for name in "$@"; do
        eval "[ -n \"\${$name:-}\" ]" || die "$name is not set"
    done
}

# Run the sftp batch commands given on stdin. A failed command stops the batch.
# With BACKUP_SFTP_PASSWORD: password login. Without: the SSH key in /root/.ssh.
# -oBatchMode=no must come before -b, because -b turns password login off.
sftp_batch() {
    printf '%s\n' "$BACKUP_SFTP_HOST_KEY" > /tmp/known_hosts
    set -- -q -P "${BACKUP_SFTP_PORT:-22}" -o UserKnownHostsFile=/tmp/known_hosts \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=30
    if [ -n "${BACKUP_SFTP_PASSWORD:-}" ]; then
        SSHPASS=$BACKUP_SFTP_PASSWORD sshpass -e sftp "$@" -o PubkeyAuthentication=no \
            -o BatchMode=no -b - "$BACKUP_SFTP_USER@$BACKUP_SFTP_HOST"
    else
        sftp "$@" -b - "$BACKUP_SFTP_USER@$BACKUP_SFTP_HOST"
    fi
}

# Print the remote file names of one database, one per line, oldest first.
# A name is <db>_<UTC stamp>.<suffix>, stamp = YYYYMMDDTHHMMSSZ.
remote_files() {
    echo "ls -1 $BACKUP_SFTP_DIR" | sftp_batch \
        | grep -o "$1_[0-9]\{8\}T[0-9]\{6\}Z\.[a-z0-9.]*" | sort || true
}

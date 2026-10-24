#!/bin/sh
# cron (default): run backup.sh on BACKUP_SCHEDULE.  backup: run it once now.
# restore <source_db> <stamp|latest> <target_db|--zip-only>: see restore.sh.
set -eu
case "${1:-cron}" in
    cron)
        # No BACKUP_DBS = backup not set up (local dev, demos, rehearsals):
        # idle instead of a restart loop. The service starts with every stack.
        if [ -z "${BACKUP_DBS:-}" ]; then
            echo "backup: off, BACKUP_DBS is not set"
            trap 'exit 0' TERM INT    # PID 1: stop at once on docker stop
            while :; do sleep 86400 & wait $!; done
        fi
        # Set up but not complete: stop at start. A container that restarts
        # in a loop is easier to see than a backup that never runs.
        . /usr/local/bin/lib.sh
        require BACKUP_DBS BACKUP_AGE_RECIPIENT BACKUP_SFTP_HOST BACKUP_SFTP_USER \
            BACKUP_SFTP_DIR BACKUP_SFTP_HOST_KEY
        [ -n "${BACKUP_PING_URL:-}" ] \
            || echo "backup: WARNING: BACKUP_PING_URL is not set, nobody hears about a failed backup" >&2
        # crond drops job output, so send it to the container log (PID 1).
        echo "${BACKUP_SCHEDULE:-30 2 * * *} /usr/local/bin/backup.sh > /proc/1/fd/1 2>&1" \
            > /etc/crontabs/root
        echo "backup: schedule '${BACKUP_SCHEDULE:-30 2 * * *}' (UTC), databases: $BACKUP_DBS"
        exec crond -f -l 8
        ;;
    backup) exec /usr/local/bin/backup.sh ;;
    restore) shift; exec /usr/local/bin/restore.sh "$@" ;;
    *) exec "$@" ;;
esac

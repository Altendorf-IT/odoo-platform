# Nightly backup sidecar: pg_dump + filestore -> age -> SFTP. See DEPLOY.md.
# postgresql16-client must not be older than the `db` service (postgres:16).
FROM alpine:3.20
RUN apk add --no-cache postgresql16-client age openssh-client sshpass curl
COPY lib.sh backup.sh restore.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron"]

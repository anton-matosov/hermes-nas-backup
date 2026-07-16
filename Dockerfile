FROM alpine:3.22

ARG BACKUP_UID=1000
ARG BACKUP_GID=1000

RUN apk add --no-cache \
      bash \
      ca-certificates \
      openssh-client \
      restic \
      util-linux \
    && addgroup -g "${BACKUP_GID}" backup \
    && adduser -D -H -u "${BACKUP_UID}" -G backup backup

COPY --chmod=0755 backup.sh /usr/local/bin/hermes-nas-backup

USER backup
WORKDIR /repository

ENV RESTIC_REPOSITORY=/repository \
    RESTIC_PASSWORD_FILE=/run/secrets/restic_password \
    SSH_KEY_FILE=/run/secrets/hermes_ssh_key \
    SSH_KNOWN_HOSTS_FILE=/run/secrets/known_hosts \
    RESTIC_HOST=hermes-server \
    RESTIC_TAG=hermes \
    MODE=backup

ENTRYPOINT ["/usr/local/bin/hermes-nas-backup"]

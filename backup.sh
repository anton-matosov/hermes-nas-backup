#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_file() {
  [[ -r "$1" ]] || fail "Required file is not readable: $1"
}

: "${RESTIC_REPOSITORY:=/repository}"
: "${RESTIC_PASSWORD_FILE:=/run/secrets/restic_password}"
: "${SSH_KEY_FILE:=/run/secrets/hermes_ssh_key}"
: "${SSH_KNOWN_HOSTS_FILE:=/run/secrets/known_hosts}"
: "${SSH_PORT:=22}"
: "${SSH_CONNECT_TIMEOUT:=20}"
: "${RESTIC_HOST:=hermes-server}"
: "${RESTIC_TAG:=hermes}"
: "${MODE:=backup}"

export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

require_file "$RESTIC_PASSWORD_FILE"
command -v restic >/dev/null || fail "restic is not installed"

# Prevent overlapping Synology Task Scheduler runs. The lock belongs beside the
# repository rather than inside Restic's own data structures.
if [[ "$RESTIC_REPOSITORY" == /* ]]; then
  mkdir -p "$RESTIC_REPOSITORY"
  exec 9>"$RESTIC_REPOSITORY/.hermes-backup-run.lock"
  flock -n 9 || fail "Another Hermes backup container is already running"
fi

case "$MODE" in
  init)
    log "Initializing Restic repository: $RESTIC_REPOSITORY"
    restic init
    exit 0
    ;;
  snapshots)
    exec restic snapshots --host "$RESTIC_HOST" --tag "$RESTIC_TAG"
    ;;
  check)
    : "${CHECK_READ_DATA_SUBSET:=5%}"
    log "Checking Restic repository (read-data-subset=$CHECK_READ_DATA_SUBSET)"
    exec restic check --read-data-subset="$CHECK_READ_DATA_SUBSET"
    ;;
  prune)
    log "Pruning unreferenced repository data"
    exec restic prune
    ;;
  backup)
    ;;
  *)
    fail "Unknown MODE '$MODE' (use init, backup, snapshots, check, or prune)"
    ;;
esac

: "${HERMES_SSH_TARGET:?Set HERMES_SSH_TARGET, for example anton@192.168.1.20}"
require_file "$SSH_KEY_FILE"
require_file "$SSH_KNOWN_HOSTS_FILE"
command -v ssh >/dev/null || fail "ssh is not installed"

runtime_dir="$(mktemp -d /tmp/hermes-backup.XXXXXX)"
cleanup() {
  rm -rf "$runtime_dir"
}
trap cleanup EXIT INT TERM

# OpenSSH rejects private keys with permissive modes. Copying the read-only
# bind mount to tmpfs also keeps the key out of the image and repository.
runtime_key="$runtime_dir/id_backup"
cp "$SSH_KEY_FILE" "$runtime_key"
chmod 600 "$runtime_key"

ssh_args=(
  -T
  -p "$SSH_PORT"
  -i "$runtime_key"
  -o BatchMode=yes
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS_FILE"
  "$HERMES_SSH_TARGET"
)

archive_name="hermes-$(date -u +'%Y-%m-%dT%H%M%SZ').zip"
log "Starting streamed Hermes backup from $HERMES_SSH_TARGET"

# --stdin-from-command is deliberate: unlike a shell pipe, Restic observes the
# SSH exit code and creates no snapshot if the exporter fails.
restic backup \
  --stdin-from-command \
  --stdin-filename "$archive_name" \
  --host "$RESTIC_HOST" \
  --tag "$RESTIC_TAG" \
  -- ssh "${ssh_args[@]}"

log "Backup snapshot completed"

if [[ "${FORGET_AFTER_BACKUP:-true}" == "true" ]]; then
  keep_args=(
    --host "$RESTIC_HOST"
    --tag "$RESTIC_TAG"
    --keep-daily "${KEEP_DAILY:-7}"
    --keep-weekly "${KEEP_WEEKLY:-5}"
    --keep-monthly "${KEEP_MONTHLY:-12}"
  )
  if [[ "${PRUNE_AFTER_BACKUP:-false}" == "true" ]]; then
    keep_args+=(--prune)
  fi
  log "Applying snapshot retention policy"
  restic forget "${keep_args[@]}"
fi

log "Hermes backup run finished successfully"

#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

COMPOSE=/usr/local/bin/docker-compose
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="$project_dir/.env"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

prompt() {
  local name="$1" message="$2" default="${3:-}" value
  if [[ -n "${!name:-}" ]]; then
    return
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$message [$default]: " value
    printf -v "$name" '%s' "${value:-$default}"
  else
    read -r -p "$message: " value
    [[ -n "$value" ]] || fail "$name is required"
    printf -v "$name" '%s' "$value"
  fi
}

[[ -x "$COMPOSE" ]] || fail "$COMPOSE was not found. Install the Synology Container Manager/Docker package first."
command -v sudo >/dev/null 2>&1 || fail "sudo is required"
command -v git >/dev/null 2>&1 || fail "git was not found. Install the Synology Git Server package and reconnect over SSH."
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen was not found. Install the Synology Git Server package and reconnect over SSH."
command -v base64 >/dev/null 2>&1 || fail "base64 is required"

if [[ -f "$env_file" ]]; then
  # shellcheck disable=SC1090
  source "$env_file"
fi

NAS_UID="${NAS_UID:-$(id -u)}"
NAS_GID="${NAS_GID:-$(id -g)}"
prompt HERMES_SSH_TARGET "Hermes SSH target (user@host)"
prompt SSH_PORT "Hermes SSH port" "22"
prompt RESTIC_REPOSITORY_PATH "Restic repository path" "/volume1/Backups/restic-hermes"
prompt NAS_SOURCE_IP "NAS IP as seen by the Hermes server"

hermes_host="${HERMES_SSH_TARGET##*@}"
hermes_user="${HERMES_SSH_TARGET%@*}"
prompt HERMES_EXPORTER_PATH "Exporter path on Hermes server" "/home/$hermes_user/.local/bin/hermes-backup-stream"
secrets_dir="$project_dir/secrets"
SSH_PRIVATE_KEY_PATH="$secrets_dir/hermes_ed25519"
SSH_KNOWN_HOSTS_PATH="$secrets_dir/known_hosts"
RESTIC_PASSWORD_PATH="$secrets_dir/restic_password"

sudo mkdir -p "$secrets_dir" "$RESTIC_REPOSITORY_PATH"
sudo chown "$NAS_UID:$NAS_GID" "$secrets_dir" "$RESTIC_REPOSITORY_PATH"
chmod 700 "$secrets_dir" "$RESTIC_REPOSITORY_PATH"

cat > "$env_file" <<EOF
NAS_UID=$NAS_UID
NAS_GID=$NAS_GID

HERMES_SSH_TARGET=$HERMES_SSH_TARGET
SSH_PORT=$SSH_PORT
RESTIC_HOST=${RESTIC_HOST:-hermes-server}
RESTIC_TAG=${RESTIC_TAG:-hermes}

RESTIC_REPOSITORY_PATH=$RESTIC_REPOSITORY_PATH
SSH_PRIVATE_KEY_PATH=$SSH_PRIVATE_KEY_PATH
SSH_KNOWN_HOSTS_PATH=$SSH_KNOWN_HOSTS_PATH
RESTIC_PASSWORD_PATH=$RESTIC_PASSWORD_PATH

FORGET_AFTER_BACKUP=${FORGET_AFTER_BACKUP:-true}
PRUNE_AFTER_BACKUP=${PRUNE_AFTER_BACKUP:-false}
KEEP_DAILY=${KEEP_DAILY:-7}
KEEP_WEEKLY=${KEEP_WEEKLY:-5}
KEEP_MONTHLY=${KEEP_MONTHLY:-12}
EOF
chmod 600 "$env_file"

if [[ ! -f "$SSH_PRIVATE_KEY_PATH" ]]; then
  ssh-keygen -q -t ed25519 -f "$SSH_PRIVATE_KEY_PATH" -N '' -C synology-hermes-backup
fi
chmod 600 "$SSH_PRIVATE_KEY_PATH"

if [[ ! -s "$RESTIC_PASSWORD_PATH" ]]; then
  head -c 48 /dev/urandom | base64 > "$RESTIC_PASSWORD_PATH"
fi
chmod 600 "$RESTIC_PASSWORD_PATH"
touch "$SSH_KNOWN_HOSTS_PATH"
chmod 600 "$SSH_KNOWN_HOSTS_PATH"

cd "$project_dir"
sudo "$COMPOSE" build

host_key_tmp="$(mktemp "$secrets_dir/known_hosts.XXXXXX")"
cleanup() { rm -f "$host_key_tmp"; }
trap cleanup EXIT
sudo "$COMPOSE" run --rm --no-deps --entrypoint ssh-keyscan hermes-backup \
  -H -p "$SSH_PORT" -t ed25519 "$hermes_host" > "$host_key_tmp"
[[ -s "$host_key_tmp" ]] || fail "No Ed25519 host key received from $hermes_host:$SSH_PORT"

printf '\nCandidate Hermes SSH host key fingerprint:\n'
ssh-keygen -lf "$host_key_tmp"
printf 'Compare it with this command run directly on the Hermes server:\n'
printf '  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub\n\n'
read -r -p 'Do the fingerprints match? [y/N] ' answer
[[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] ||
  fail "Host key was not accepted"
mv "$host_key_tmp" "$SSH_KNOWN_HOSTS_PATH"
trap - EXIT

printf '\nAppend this restricted line to ~/.ssh/authorized_keys on the Hermes server:\n\n'
printf 'from="%s",restrict,command="%s" %s\n' \
  "$NAS_SOURCE_IP" "$HERMES_EXPORTER_PATH" "$(cat "$SSH_PRIVATE_KEY_PATH.pub")"
read -r -p 'Press Enter after the key is installed on the Hermes server... ' _

if [[ -f "$RESTIC_REPOSITORY_PATH/config" ]]; then
  printf '\nRestic repository is already initialized; leaving it unchanged.\n'
elif sudo MODE=init "$COMPOSE" run --rm hermes-backup; then
  :
else
  fail "Restic initialization failed"
fi
printf '\nSetup complete. Run a test backup with:\n  sudo %s run --rm hermes-backup\n' "$COMPOSE"

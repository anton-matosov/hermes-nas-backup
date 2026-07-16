#!/usr/bin/env bash
set -Eeuo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/bin" "$tmp/repository"
printf 'test-private-key\n' > "$tmp/key"
printf 'test-password\n' > "$tmp/password"
printf 'host ssh-ed25519 test\n' > "$tmp/known_hosts"

cat > "$tmp/bin/ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
if [[ "${MOCK_SSH_FAIL:-false}" == "true" ]]; then
  exit 42
fi
printf 'fake zip stream'
MOCK_SSH

cat > "$tmp/bin/restic" <<'MOCK_RESTIC'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_RESTIC_LOG"
if [[ "$1" == "backup" ]]; then
  while (($#)); do
    if [[ "$1" == "--" ]]; then
      shift
      if "$@" >/dev/null; then
        printf 'snapshot test1234 saved\n'
        exit 0
      fi
      printf 'source command failed; snapshot cancelled\n' >&2
      exit 1
    fi
    shift
  done
  exit 2
fi
exit 0
MOCK_RESTIC
chmod 755 "$tmp/bin/ssh" "$tmp/bin/restic"

export PATH="$tmp/bin:$PATH"
export MOCK_RESTIC_LOG="$tmp/restic.log"
export RESTIC_REPOSITORY="$tmp/repository"
export RESTIC_PASSWORD_FILE="$tmp/password"
export SSH_KEY_FILE="$tmp/key"
export SSH_KNOWN_HOSTS_FILE="$tmp/known_hosts"
export HERMES_SSH_TARGET="anton@host"
export FORGET_AFTER_BACKUP=true

"$project_dir/backup.sh"
grep -q '^backup .*--stdin-from-command' "$MOCK_RESTIC_LOG"
grep -q '^forget .*--keep-daily 7 .*--keep-weekly 5 .*--keep-monthly 12' "$MOCK_RESTIC_LOG"

: > "$MOCK_RESTIC_LOG"
export MOCK_SSH_FAIL=true
if "$project_dir/backup.sh"; then
  printf 'expected failed SSH source command to fail backup\n' >&2
  exit 1
fi
grep -q '^backup .*--stdin-from-command' "$MOCK_RESTIC_LOG"
if grep -q '^forget ' "$MOCK_RESTIC_LOG"; then
  printf 'retention ran after a failed backup\n' >&2
  exit 1
fi

printf 'backup entrypoint tests: OK\n'

# Hermes backup pulled by Synology

This is a one-shot, hardened container. Synology Task Scheduler starts it; the
container connects to the Ubuntu host with a forced-command SSH key, streams a
SQLite-consistent `hermes backup` archive directly into Restic, applies
retention, and exits.

No NAS or Restic credentials are stored on the Hermes server. No plaintext
backup is written to a NAS volume. The private key and Restic password are
read-only bind mounts and are not included in the image.

## Layout

- `Dockerfile` — Alpine, Restic, and OpenSSH client; runs as a non-root user.
- `backup.sh` — backup/init/check/prune entrypoint.
- `docker-compose.yaml` — read-only container, tmpfs, dropped capabilities, and mounts.
- `server/hermes-backup-stream` — forced command installed on Ubuntu.

## 1. Ubuntu/Hermes server

The included exporter must be installed as:

```bash
install -m 0755 server/hermes-backup-stream \
  /home/anton/.local/bin/hermes-backup-stream
```

Generate the SSH key **on the NAS**, then add its public key to
`/home/anton/.ssh/authorized_keys` on Ubuntu. Prefer restricting it to the NAS
IP as well:

```text
from="NAS_IP",restrict,command="/home/anton/.local/bin/hermes-backup-stream" ssh-ed25519 AAAA... synology-hermes-backup
```

This key cannot request a shell, PTY, forwarding, or any other command.

## 2. Synology files and secrets

Copy this directory to, for example:

```text
/volume1/docker/hermes-backup
```

Create a secret directory and repository directory. Replace UID/GID with the
account that owns the repository (`id YOUR_DSM_USER` over NAS SSH):

```bash
mkdir -p /volume1/docker/hermes-backup/secrets
mkdir -p /volume1/Backups/restic-hermes
chown NAS_UID:NAS_GID /volume1/Backups/restic-hermes
chmod 700 /volume1/docker/hermes-backup/secrets
chmod 700 /volume1/Backups/restic-hermes
```

In the `chown` command, replace `NAS_UID:NAS_GID` with the numeric values that
will also be placed in `.env` (for example, `1026:100`). Synology shared-folder
ACLs must also grant that DSM account read, write, and directory traversal.

Generate a dedicated SSH key on the NAS:

```bash
ssh-keygen -t ed25519 \
  -f /volume1/docker/hermes-backup/secrets/hermes_ed25519 \
  -N '' -C synology-hermes-backup
chmod 600 /volume1/docker/hermes-backup/secrets/hermes_ed25519
```

Only the `.pub` file is copied to Ubuntu. The private key stays on the NAS.

Create and separately preserve a strong Restic password:

```bash
umask 077
openssl rand -base64 48 \
  > /volume1/docker/hermes-backup/secrets/restic_password
```

Record the Ubuntu SSH host key. Do not blindly trust the result: compare its
fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` run directly
on Ubuntu.

```bash
ssh-keyscan -H -t ed25519 HERMES_SERVER_IP \
  > /volume1/docker/hermes-backup/secrets/known_hosts
chmod 600 /volume1/docker/hermes-backup/secrets/known_hosts
```

Copy `.env.example` to `.env`, replace the IP and paths, and set `NAS_UID` and
`NAS_GID` to the repository owner's numeric IDs:

```bash
cp .env.example .env
chmod 600 .env
```

The mounted secret files must be readable by that UID. The container copies
the SSH key into private tmpfs and forces mode `0600` before invoking OpenSSH.

## 3. Build and initialize

From the project directory on the NAS:

```bash
sudo /usr/local/bin/docker-compose build
sudo MODE=init /usr/local/bin/docker-compose run --rm hermes-backup
```

Older DSM installations may use `docker-compose` instead of `/usr/local/bin/docker-compose`.
Initialization is run only once.

If an older image reports `chdir to cwd ("/repository") ... permission denied`,
rebuild it after this change. That failure occurs before the backup script can
run. The rebuilt image starts in `/` and reports the container's effective UID
and GID if the repository mount is still inaccessible. Verify that those IDs
match the repository ownership with:

```bash
grep '^NAS_\(UID\|GID\)=' .env
sudo stat -c '%u:%g %a %n' /volume1/Backups/restic-hermes
```

Test one real backup:

```bash
/usr/local/bin/docker-compose run --rm hermes-backup
MODE=snapshots /usr/local/bin/docker-compose run --rm hermes-backup
```

Restic's `--stdin-from-command` mode checks the SSH command's exit status. If
SSH or the Ubuntu exporter fails, Restic cancels the backup and creates no
snapshot.

## 4. Synology Task Scheduler

Create a scheduled **User-defined script** that runs daily. Use an absolute
Compose path because Task Scheduler has a minimal working environment:

```bash
cd /volume1/docker/hermes-backup && \
  /usr/local/bin/docker-compose run --rm hermes-backup
```

If DSM exposes Compose as a separate executable, use:

```bash
cd /volume1/docker/hermes-backup && \
  /usr/local/bin/docker-compose run --rm hermes-backup
```

The entrypoint uses an advisory lock in the repository and refuses overlapping
runs. Default retention is 7 daily, 5 weekly, and 12 monthly snapshots.
`forget` runs after each successful backup; expensive pruning is disabled in
daily runs.

Create a weekly pruning task:

```bash
cd /volume1/docker/hermes-backup && \
  MODE=prune /usr/local/bin/docker-compose run --rm hermes-backup
```

Create a weekly 5% repository check:

```bash
cd /volume1/docker/hermes-backup && \
  MODE=check /usr/local/bin/docker-compose run --rm hermes-backup
```

For an occasional complete data check, override the subset:

```bash
MODE=check CHECK_READ_DATA_SUBSET=100% \
  /usr/local/bin/docker-compose run --rm hermes-backup
```

## Operations

List snapshots:

```bash
MODE=snapshots /usr/local/bin/docker-compose run --rm hermes-backup
```

The container supports these modes through `MODE`:

- `init` — initialize a new mounted repository.
- `backup` — stream and retain Hermes snapshots.
- `snapshots` — list Hermes snapshots.
- `check` — repository check; defaults to a 5% data subset.
- `prune` — reclaim data no retained snapshot references.

Keep an offline copy of the Restic password. Losing it makes every snapshot
unrecoverable. For 3-2-1 coverage, replicate the encrypted Restic repository
from Synology to a second NAS or off-site target.

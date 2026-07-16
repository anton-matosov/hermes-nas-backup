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
- `setup-nas.sh` — interactive, idempotent NAS bootstrap.
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

## 2. Synology prerequisites and automated setup

Install **Container Manager** (called **Docker** on older DSM releases) and
**Git Server** from Synology Package Center. Git Server supplies the command-line
Git/OpenSSH tools used during setup. Enable SSH access, reconnect, and clone or
copy this repository to, for example:

```text
/volume1/docker/hermes-backup
```

Run the setup as the DSM account that will own the backup. It checks the
packages, creates `.env`, directories, key and password, builds the image,
records and verifies the SSH host key, and initializes Restic:

```bash
cd /volume1/docker/hermes-backup
./setup-nas.sh
```

Before its first privileged operation, the script explains why administrator
access is needed and asks `sudo` to authenticate with your DSM password.

The script prints the complete IP-restricted `authorized_keys` line and pauses
while you install it on the Hermes server. It is safe to rerun: saved `.env`
answers are shown as prompt defaults, and existing keys, passwords, and
initialized Restic repositories are retained.

DSM does not ship `ssh-keyscan`. The setup script deliberately runs the version
inside the built container, shows its fingerprint, and requires confirmation
against the fingerprint displayed directly on the Hermes server. It never
blindly accepts a network-provided host key. Only the public client key is
copied to Ubuntu; the private key stays on the NAS. Preserve a separate offline
copy of `secrets/restic_password`.

If an older image reports `chdir to cwd ("/repository") ... permission denied`,
rebuild it after this change. That failure occurs before the backup script can
run. The rebuilt image starts in `/` and reports the container's effective UID
and GID if the repository mount is still inaccessible. Verify that those IDs
match the repository ownership with:

```bash
grep '^NAS_\(UID\|GID\)=' .env
sudo stat -c '%u:%g %a %n' /volume1/Backups/restic-hermes
```

## 3. Test

All Compose commands use the Synology absolute path and `sudo`:

```bash
sudo /usr/local/bin/docker-compose run --rm hermes-backup
sudo MODE=snapshots /usr/local/bin/docker-compose run --rm hermes-backup
```

Restic's `--stdin-from-command` mode checks the SSH command's exit status. If
SSH or the Ubuntu exporter fails, Restic cancels the backup and creates no
snapshot.

Every run stores the combined stream as `hermes-and-mempalace.tar`. The stable
path lets Restic reuse the correct parent snapshot. Retention groups by host and
tag, so it also covers older snapshots whose paths contained timestamps.

Restic stages multiple approximately 16 MiB pack files in `/tmp` before saving
them to the repository. The container therefore provides a 128 MiB tmpfs by
default; `TMPFS_SIZE` in `.env` can raise it on larger repositories. Setting it
near a single pack size can stop input progress when concurrent pack workers
fill tmpfs.

### SSH rejects the backup key

`Permission denied (publickey,password)` means the Hermes SSH server rejected
the key before it could run the exporter. Confirm that the public key installed
for the target user is the one generated on the NAS:

```bash
# NAS
ssh-keygen -lf secrets/hermes_ed25519.pub

# Hermes server, logged in as the target user
ssh-keygen -lf ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

The fingerprints must match, and both `.ssh` and `authorized_keys` must be owned
by the target user. If they match, inspect the server-side reason immediately
after another attempt:

```bash
sudo journalctl -u ssh -n 50 --no-pager
```

Pay particular attention to an ownership/mode warning or a rejected `from=`
address. The IP in the generated `from="NAS_SOURCE_IP"` restriction must be the
source address the Hermes server actually sees. Correct `NAS_SOURCE_IP` in
`.env`, rerun setup, and replace the old `authorized_keys` line rather than
adding a second copy.

## 4. Synology Task Scheduler

Create a scheduled **User-defined script** that runs daily. Use an absolute
Compose path because Task Scheduler has a minimal working environment:

```bash
cd /volume1/docker/hermes-backup && \
  sudo /usr/local/bin/docker-compose run --rm hermes-backup
```

The entrypoint uses an advisory lock in the repository and refuses overlapping
runs. Default retention is 7 daily, 5 weekly, and 12 monthly snapshots.
`forget` runs after each successful backup; expensive pruning is disabled in
daily runs.

Create a weekly pruning task:

```bash
cd /volume1/docker/hermes-backup && \
  sudo MODE=prune /usr/local/bin/docker-compose run --rm hermes-backup
```

Create a weekly 5% repository check:

```bash
cd /volume1/docker/hermes-backup && \
  sudo MODE=check /usr/local/bin/docker-compose run --rm hermes-backup
```

For an occasional complete data check, override the subset:

```bash
sudo MODE=check CHECK_READ_DATA_SUBSET=100% \
  /usr/local/bin/docker-compose run --rm hermes-backup
```

## Operations

List snapshots:

```bash
sudo MODE=snapshots /usr/local/bin/docker-compose run --rm hermes-backup
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

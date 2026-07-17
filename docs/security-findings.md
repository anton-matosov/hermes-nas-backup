# Security findings

Date: 2026-07-16

Status: Findings remain valid; the target design is superseded by the
[hostile-source backup architecture specification](hostile-source-backup-spec.md).
That specification adds the critical assumption that Hermes is an
Internet-connected AI agent and must be treated as a potentially hostile
source. Recommendations below that place both pull orchestration and repository
decryption on the NAS are fallback mitigations, not the preferred architecture.

## Scope

This document assesses how the Hermes backup system stores and uses its SSH
private key and Restic repository password on a Synology NAS. It covers the
repository's current controls, the relevant Synology and container security
boundaries, risks to backup availability, and a recommended target design.

The review covered:

- `setup-nas.sh`
- `docker-compose.yaml`
- `Dockerfile`
- `backup.sh`
- `server/hermes-backup-stream`
- `README.md`
- Synology DSM encrypted shared folders, encrypted volumes, Key Manager, KMIP,
  permissions, immutable snapshots, and account hardening
- Restic password handling and append-only repository guidance
- Docker Compose and Docker Swarm secret behavior
- OpenSSH `authorized_keys` restrictions

No secret values were read or recorded during this review.

## Executive summary

The current implementation already has useful defense-in-depth controls. The
credentials are excluded from Git and the image, mounted read-only, consumed as
files instead of environment-variable values, and copied only to tmpfs when the
SSH client needs a key with suitable permissions. The container runs as a
non-root user with a read-only root filesystem, all capabilities dropped, and
`no-new-privileges`. SSH host-key verification is strict, and the client key is
restricted on the server by source address, a forced command, and OpenSSH's
`restrict` option. The generated Restic password has ample entropy.

The most important weakness is not the absence of a passphrase on the
automation key. Synology Task Scheduler is instructed to execute Compose as
root from a project directory controlled by the setup user. An attacker who can
modify `docker-compose.yaml`, `.env`, an invoked script, or the build context can
turn the next scheduled root execution into arbitrary host access. Protecting
the deployment files from modification is therefore the first priority.

The plaintext credential files are also exposed to removed disks, theft of an
unencrypted NAS, unintended NAS-wide backup or synchronization, inherited DSM
ACLs, DSM administrators, and live root compromise. Synology encryption can
protect secrets at rest, but a mounted encrypted folder or volume is readable
by live DSM root. A fully unattended system necessarily provides some
machine-accessible path to its credentials. Local encryption cannot establish a
security boundary against a compromised machine that is actively performing
the backup.

The recommended balanced design is:

1. Install a fixed copy of the application into a root-owned, non-user-writable
   deployment directory. Do not run scheduled root jobs from an ordinary Git
   working tree.
2. Store the private key and Restic password in a dedicated encrypted Synology
   shared folder with tightly restricted DSM ACLs and no file-service exposure.
3. Run the container under a dedicated, non-interactive backup identity that
   alone can read the credential files and write the Restic repository.
4. Store the Restic repository separately from its password and protect it with
   immutable snapshots plus an off-site or second-system copy.
5. Keep independent offline recovery copies of the Restic password and all
   Synology encryption recovery material.

## Threat model

The design should distinguish the following attackers and failures because no
single credential-storage technique handles all of them.

| Threat | Current protection | Remaining risk | Recommended control |
| --- | --- | --- | --- |
| Accidental Git commit | `.env` and `secrets/` are ignored | Copies, renamed files, or other tools may still capture them | Store secrets outside the working tree and scan commits |
| Secret included in image | Secrets are runtime bind mounts | A malicious or modified build can read host-mounted secrets when run | Root-own deployment inputs and review/pin the installed image |
| Other ordinary DSM user | POSIX modes are `0700`/`0600` | Synology ACLs may add or inherit access; the current owner is an interactive user | Dedicated identity, dedicated share, explicit DSM ACL review |
| Compromised setup user's account | Container is non-root | Root Task Scheduler later executes user-controlled Compose and scripts | Root-owned installed deployment; no scheduled execution from working tree |
| Removed disks | Restic data is encrypted | The password and SSH private key are plaintext on the same unencrypted storage | Encrypted secret share or encrypted volume; key material kept separately |
| Powered-off NAS theft | File modes and Restic encryption | Local plaintext secrets can be recovered; locally auto-unlocked encryption may reduce separation | External Key Manager store, manual unlock, or remote KMIP |
| Powered-on NAS theft | File modes and disk encryption | Mounted files are readable by live root | Rapid revocation, remote KMIP, network isolation, immutable/off-site copies |
| Live DSM root compromise | Container hardening limits the container | Host root controls mounts, files, Docker, processes, and repository | Cannot be solved locally; use external trust and off-site immutability |
| Compromised backup container | Read-only filesystem, dropped capabilities, non-root UID | The running backup must receive both credentials and can potentially exfiltrate them | Trusted root-owned image/code, restricted egress, short runtime, rotation capability |
| Compromised Hermes server | Forced-command key limits NAS-to-server access | The source can send malicious or corrupt data and can modify a user-owned exporter | Dedicated source account, protected exporter, integrity checks, historical snapshots |
| Ransomware or destructive NAS administrator | Restic encrypts content | The local client has delete access and runs retention/pruning | Immutable snapshots and remote append-only/off-site storage |
| Lost credential or encryption key | README calls for an offline password copy | Loss can make all backups or an encrypted Synology volume unrecoverable | Two independent recovery copies and tested restore procedures |

## Existing controls that should be retained

### Credentials are not committed or baked into the image

`.gitignore` excludes `.env` and the `secrets/` directory. The Compose
configuration provides the SSH key, known-hosts file, and Restic password as
read-only runtime bind mounts. The Dockerfile does not copy those values into an
image layer.

### Secret values are not placed in environment variables

The container receives paths such as `RESTIC_PASSWORD_FILE` and `SSH_KEY_FILE`,
not the secret values themselves. This avoids common leakage through process
environments, diagnostic output, and generated Compose configuration.

Restic officially supports `RESTIC_PASSWORD_FILE` and
`RESTIC_PASSWORD_COMMAND` for automated operation. A password file is a valid
automation mechanism when the host file and the process that consumes it are
appropriately protected.

### Runtime container hardening is good

The container:

- runs as a non-root UID/GID;
- has a read-only root filesystem;
- drops all Linux capabilities;
- enables `no-new-privileges`;
- uses a `tmpfs` with `noexec`, `nosuid`, and `nodev`;
- copies the SSH key into that tmpfs only for the duration of a run; and
- exits after the one-shot operation.

These controls limit accidental persistence and many container-level attacks.
They do not protect against hostile Compose configuration or a compromised
Docker/DSM administrator.

### SSH authentication is substantially constrained

The documented `authorized_keys` entry uses:

```text
from="NAS_IP",restrict,command="/absolute/path/hermes-backup-stream" ssh-ed25519 ...
```

OpenSSH's `restrict` option disables port, agent, and X11 forwarding, PTY
allocation, and execution of `~/.ssh/rc`. The forced command prevents this key
from selecting an arbitrary shell command. The `from=` condition further limits
where the key can be accepted.

The client also uses `BatchMode=yes`, `IdentitiesOnly=yes`, and
`StrictHostKeyChecking=yes`, with an explicitly verified known-hosts file.

### Restic password generation is strong

`setup-nas.sh` reads 48 bytes from `/dev/urandom` and base64-encodes them. This
provides approximately 384 bits of random input, far more than is needed to
resist password guessing. The weakness is storage location and access, not
password entropy.

### Backup streaming and failure handling are sound

The source archive is streamed directly into Restic, so no plaintext archive is
written to a NAS volume. `--stdin-from-command` lets Restic observe SSH/exporter
failure and cancel the snapshot. Retention is only attempted after a successful
backup.

## Findings

### Critical: root runs a deployment controlled by an interactive user

The setup script creates `.env` under the cloned project and makes the project
user the owner of the adjacent secrets directory. The README then directs a
root Task Scheduler job to change into that project and execute Compose.

This creates a delayed privilege-escalation path. An attacker who can write the
project can, for example:

- replace or edit `docker-compose.yaml`;
- point a bind mount at another host path;
- replace `backup.sh` before rebuilding;
- alter `.env` paths and runtime settings;
- change the Dockerfile or image entrypoint; or
- arrange for a future setup/build invocation to execute hostile code.

Because Compose itself is launched as root, container hardening cannot repair
this trust-boundary error.

#### Recommendation

Create a root-owned installed deployment, for example:

```text
/volume1/hermes-backup-app/
```

The Task Scheduler command should invoke one fixed root-owned wrapper from this
location. The wrapper, Compose file, `.env`, scripts, and relevant parent
directories must not be writable by the development/setup user or ordinary DSM
accounts. Updating the deployment should be a separate explicit privileged
operation that copies reviewed files from the working tree.

The `.env` file does not currently contain secret values, but it still controls
security-sensitive mount paths and execution, so it must be treated as trusted
deployment configuration.

### High: plaintext credentials reside on unencrypted NAS storage

The SSH private key and Restic password are stored as regular files under the
project's `secrets/` directory. Mode `0600` is useful against ordinary local
accounts, but it does not protect against offline disk access, unencrypted NAS
theft, live root, or accidental capture by a separate NAS backup job.

#### Recommendation

Move only the confidential files to a dedicated encrypted shared folder. Do
not expose that share through SMB, NFS, FTP, WebDAV, Synology Drive, indexing,
or unrelated backup/synchronization jobs. Give normal users and groups no
access in DSM and verify both Synology ACLs and POSIX ownership/modes.

Keep the repository in a separate shared folder. The Restic repository is
already encrypted; putting the password beside it weakens the value of that
encryption in a disk-theft scenario.

### High: Synology ACLs are not explicitly controlled

DSM normally uses Windows ACLs, including inherited entries, in addition to the
Unix modes visible through `chmod`. The setup script applies `chmod`, but it
does not create a dedicated shared folder or inspect and constrain DSM ACLs.

#### Recommendation

Create the secret location through DSM as its own shared folder and explicitly
configure its permissions. Do not assume `chmod 700` alone describes every DSM
access path. Review:

- local users;
- local groups;
- system internal users;
- inherited ACL entries;
- application permissions;
- advanced shared-folder permissions; and
- file services and indexing.

DSM administrators and root remain privileged and are not a boundary this
configuration can eliminate.

### High: the local repository remains destructible

The backup container has read/write/delete access to the local repository.
Daily operation may run `forget`, and the maintenance mode runs `prune`. A
compromised NAS, administrator, scheduler configuration, or backup container can
therefore destroy backup history even if the content remains confidential.

#### Recommendation

On supported Btrfs models, schedule immutable snapshots of the repository
shared folder, ideally after successful backups, with at least the Synology
recommended 7-to-14-day protection period. Immutable snapshots cannot be
deleted during that protection window.

Also maintain another copy outside the NAS. For stronger ransomware isolation,
send backups to a remote Restic REST server in append-only mode and perform
`forget`/`prune` from a separate, better-protected administrative identity.
Restic explicitly recommends separating append-only backup access from
full-access maintenance.

Snapshots on the same volume are not a substitute for an off-site copy or a
second failure domain.

### Medium: the container receives both long-lived credentials

During a backup, the container can read the Restic password and SSH private key.
This is necessary for the current workflow. A malicious image or modified
script could send them elsewhere while it runs.

#### Recommendation

- Keep the installed image and all execution inputs root-owned.
- Do not automatically rebuild from an untrusted or user-writable working tree.
- Restrict NAS/container network egress to the Hermes SSH endpoint and required
  infrastructure where practical.
- Keep the container short-lived and preserve the existing read-only/tmpfs
  controls.
- Treat Docker access as root-equivalent.

### Medium: the SSH key grants access to the complete exported dataset

The SSH restrictions prevent an interactive shell, but possession of the key
still grants the ability to invoke the forced exporter and receive the entire
backup stream when the source restriction is satisfied. The data is plaintext
in transit inside the SSH connection before Restic encrypts it on the NAS.

#### Recommendation

Use a separate key for every source and a dedicated source-side account such as
`hermes-backup-export`. Give it no unrelated application or interactive access.
Retain the forced command, `restrict`, and `from=` controls. Restrict the
exporter and its parent directories from modification by unrelated accounts
where practical.

Rotate the SSH key by installing and testing a new restricted public key before
removing the old one.

### Medium: the exporter executes from a normal user's home directory

The forced command currently points into `/home/anton/.local/bin`. This makes
the exporter part of the normal user's writable environment. A compromise of
that account or its home can change what future backups contain.

This does not let the restricted backup key choose a different command, but it
does weaken confidence that the forced command is the reviewed exporter.

#### Recommendation

Prefer a root-owned exporter path such as `/usr/local/libexec/` or a dedicated
account with tightly controlled ownership. The exporter can still run with the
minimum privileges required to read and consistently snapshot Hermes and
MemPalace data.

### Medium: no passphrase on the SSH key is an explicit availability/security tradeoff

An unattended task cannot answer an SSH key passphrase prompt. Encrypting the
key while storing its passphrase next to it merely creates two locally readable
secrets instead of one.

#### Recommendation

For fully unattended operation, retain a separate unencrypted Ed25519 key with
the strong server-side restrictions above. Protect it through storage
encryption, ownership, ACLs, and capability restriction.

For the strongest protection at the cost of unattended recovery after reboot,
use a passphrase-protected key loaded manually into an agent or use a manually
mounted secret share. Hardware-backed keys that require user presence are
usually incompatible with an unattended scheduled backup.

### Medium: credentials need a defined rotation and incident procedure

The current documentation does not specify normal rotation or response to a
suspected leak.

#### Recommendation

- SSH key compromise: install a new restricted key, verify it, remove the old
  `authorized_keys` entry, and replace the NAS private key.
- Restic password exposure without evidence of repository decryption: add and
  test a new Restic key, remove the old key, and update the protected password
  file.
- Suspected compromise of decrypted repository access: create a new repository
  with new key material and migrate/copy verified snapshots. Merely changing a
  password does not make data already decrypted by an attacker secret again.
- NAS theft: revoke the SSH public key immediately and, when remote KMIP is in
  use, remove the stolen NAS's KMIP client certificate.
- Preserve logs and verify repository integrity and restored content after any
  incident.

### Medium: recovery keys are as important as operational secrets

Losing the Restic password makes the repository unrecoverable. Losing the
Synology encrypted-folder key or encrypted-volume recovery key can similarly
make the secret store unavailable.

#### Recommendation

Keep at least two independent recovery copies outside the NAS. Appropriate
locations include a well-protected password manager, an offline encrypted
device, or a sealed paper/physical recovery record. Do not store the only
recovery copy in another folder on the same NAS or in a synchronization path
that shares the same failure domain.

Test the recovery procedure periodically, including a full Restic restore to an
isolated destination.

### Low: `known_hosts` is classified as a secret

The SSH known-hosts file is not confidential, but its integrity is essential.
An attacker who can replace it and redirect the SSH target can undermine server
authentication.

#### Recommendation

Move `known_hosts` into root-owned application configuration rather than the
encrypted secrets folder. Keep it non-writable by the runtime identity and
continue verifying fingerprints out of band during setup and rotation.

## Synology encryption options

### Option A: manually mounted encrypted shared folder

Create a dedicated encrypted shared folder and do not enable mount-on-boot.
After every NAS reboot, an administrator manually imports or enters its key
before scheduled backups can run.

Advantages:

- Creates a real human-controlled unlock boundary.
- Strong protection for a powered-off NAS and removed drives.
- No unattended local key path is available at boot.

Tradeoffs:

- Backups fail after reboot until the folder is mounted.
- The mounted folder is still readable by live root.
- Requires reliable operational monitoring.

This is the strongest single-NAS option when human intervention after reboot is
acceptable.

### Option B: encrypted shared folder with Synology Key Manager

Synology Key Manager can store encrypted-shared-folder keys in a system
partition or external device. Only the machine-key cipher supports automatic
mounting on boot. Synology recommends an external device as the key-store
location and supports ejecting that device after boot.

Advantages:

- Maintains unattended operation.
- Protects removed data disks.
- An external key store that is removed after boot improves separation for a
  subsequently powered-off or moved NAS.

Tradeoffs:

- Automatic unlock necessarily makes keys available to the NAS.
- A running, already-mounted system remains readable by root.
- Theft scenarios depend on whether the key-store device is still present and
  whether the NAS is running.

This is the recommended balance for a single NAS.

### Option C: DSM 7.2+ encrypted volume with local Key Vault

Supported models can create an encrypted volume using Synology's Encryption Key
Vault. The volume automatically unlocks when its vault is available. Volume
encryption protects all data on that volume, not just the two application
secrets, and is irreversible for the created volume.

Advantages:

- Broad at-rest protection using LUKS/dm-crypt.
- Protects shared folders, package data, and other contents on the encrypted
  volume.

Tradeoffs:

- Model and DSM-version dependent.
- More operational scope and possible performance cost than a small encrypted
  shared folder.
- A local available vault does not protect against live root.

### Option D: DSM 7.2+ encrypted volume with remote KMIP

On compatible Synology systems, the Encryption Key Vault can live on another
Synology NAS over KMIP. The encrypted-volume NAS automatically unlocks only
when the remote key server is available. Synology documents removal of the
client certificate on the key server as a way to prevent a lost NAS from
retrieving its key.

Advantages:

- Separates volume encryption keys from the encrypted NAS.
- Covers loss of the full NAS better than a local vault.
- Allows remote revocation of a lost client's access.

Tradeoffs:

- Requires a second compatible Synology NAS, certificates, monitoring, and
  recovery planning.
- Failure or certificate expiry can prevent automatic unlock.
- A client that is already running with the volume unlocked remains exposed to
  live root.
- KMIP unlocks the filesystem; it is not an application secret manager that
  supplies the Restic password directly.

This is the strongest native Synology option for unattended at-rest protection.

## Why several tempting approaches do not solve the problem

### Encrypting a secret with another local secret

An encrypted private key plus a passphrase file beside it has the same effective
host boundary as the original private key. The same applies to encrypting the
Restic password with a locally stored decryption key.

Encryption helps only when the unlocking authority is separated through human
input, different hardware, a remote service, or a more restricted credential.

### Switching to ordinary Docker Compose `secrets`

Compose secret syntax is clearer about intent and grants per-service access,
but a file-backed Compose secret is still implemented as a host bind mount. It
does not encrypt the source file at rest and does not protect it from host root.
The current read-only file mounts already provide the relevant runtime behavior.

Docker Swarm secrets are different: Swarm stores them in an encrypted Raft log
and mounts decrypted values from memory into authorized services. Even then, a
live Swarm manager/host and the authorized running service remain trusted. The
operational complexity and Synology supportability must be weighed against the
limited benefit for this one-node system.

### Moving the password into an environment variable

This is worse than the current file-based design. Environment variables can be
included in diagnostic output, inherited by child processes, and exposed by
process and container inspection. Continue using Restic's password-file or
password-command interface.

### Using an external password manager without solving bootstrap authentication

Restic can call a command to obtain its password, so Vault or another external
secret service can be integrated. However, a completely unattended client must
still authenticate to that service. A permanent unrestricted API token stored
on the same NAS simply replaces the Restic password with another valuable
secret.

An external manager materially improves the design only when its client
credential is scoped, revocable, short-lived, hardware-bound, manually
unlocked, or otherwise less useful to an attacker than the secret it retrieves.

## Recommended target layout

```text
/volume1/hermes-backup-app/              root-owned installed deployment
  run-backup                             fixed Task Scheduler entrypoint
  docker-compose.yaml                    root-owned, not user-writable
  backup.env                             root-owned trusted configuration
  known_hosts                            root-owned integrity-sensitive config

/volume1/hermes-backup-secrets/          dedicated encrypted shared folder
  hermes_ed25519                         backup UID, mode 0400 or 0600
  restic_password                        backup UID, mode 0400 or 0600

/volume1/Backups/restic-hermes/          separate repository shared folder
  ...                                    backup UID has required read/write access

/volume1/development/hermes-nas-backup/  optional ordinary Git working tree
  ...                                    never executed by a scheduled root task
```

The exact volume and share names can differ, but the trust boundaries should
not.

The dedicated backup identity should:

- have a stable UID/GID shared with the container;
- have no interactive DSM, SSH, or file-service login;
- be denied unrelated DSM applications and shares;
- read only its private key and Restic password;
- write only the Restic repository and necessary runtime locations; and
- not own or be able to modify installed scripts or Compose configuration.

Task Scheduler may still need to invoke Docker as root. Docker access is
effectively root-equivalent, so the safer boundary is a root-owned fixed
deployment rather than granting Docker access to an ordinary user.

## Implementation priorities

### Priority 1: remove the root execution trust failure

1. Add an explicit privileged installation/update step.
2. Install reviewed application files into a root-owned directory.
3. Install a fixed root-owned scheduler wrapper.
4. Make the scheduler call only that wrapper with an absolute path.
5. Reject an installed deployment if a relevant file or parent directory is
   writable by the backup identity or ordinary users.

### Priority 2: separate and encrypt credentials

1. Create a dedicated encrypted shared folder.
2. Choose manual unlock, external Key Manager storage, or remote KMIP according
   to the required availability/security balance.
3. Move the two confidential credentials outside the project.
4. Move `known_hosts` to root-owned application configuration.
5. Review DSM ACLs and exclude the share from normal file services and unrelated
   backup jobs.
6. Rotate the credentials after migration because their past exposure cannot be
   proven from repository state.

### Priority 3: establish a dedicated runtime identity

1. Create or reserve a non-interactive backup UID/GID.
2. Run the image with that identity.
3. Give it only the repository and credential access required for backup.
4. Remove reliance on the interactive setup user's UID/GID.

### Priority 4: protect backup availability

1. Enable immutable Btrfs snapshots where supported.
2. Schedule snapshots after successful backup runs.
3. Add an off-site or second-NAS encrypted copy.
4. Consider append-only remote Restic storage with separate maintenance access.
5. Test complete restores and recovery-key procedures regularly.

### Priority 5: harden the surrounding systems

On DSM:

- disable the default `admin` account;
- enforce MFA for administrators;
- enable Auto Block and Account Protection;
- limit DSM, SSH, and other service exposure with the DSM and network firewalls;
- install security updates promptly;
- run Security Advisor regularly;
- alert on failed scheduled tasks and suspicious logins; and
- treat all members of the administrators group as capable of accessing a
  mounted secret store.

On the Hermes server:

- use a dedicated export account and key;
- retain `from=`, `restrict`, and a forced absolute command;
- make the exporter code integrity-protected;
- restrict inbound SSH to the NAS where practical; and
- monitor use of the backup key.

## Information needed before implementation

The implementation should detect or confirm:

- Synology model;
- DSM version;
- filesystem type of the intended repository and secret locations;
- encrypted shared-folder support;
- encrypted-volume and remote-KMIP support;
- immutable snapshot support;
- whether a second Synology NAS is available;
- whether a removable USB key store is acceptable;
- whether manual unlock after reboot is acceptable; and
- what off-site repository or replication target is available.

These choices determine whether the final profile is manual/high-security,
single-NAS unattended, or remote-vault unattended.

## Primary references

- [Synology: Manage Encrypted Shared Folders](https://kb.synology.com/en-au/DSM/help/DSM/AdminCenter/file_share_key_manager)
- [Synology: Create and manage an encrypted volume](https://kb.synology.com/en-global/DSM/help/DSM/StorageManager/volume_create_volume)
- [Synology: Set up a remote KMIP key server](https://kb.synology.com/en-us/DSM/tutorial/How_do_I_set_up_KMIP_server)
- [Synology Volume Encryption white paper](https://kb.synology.com/en-eu/WP/Synology_Volume_Encryption_White_Paper/3)
- [Synology: Assign Shared Folder Permissions](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_share_privilege?version=6)
- [Synology: Manage Advanced Shared Folder Permissions](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_share_privilege_asp?version=7)
- [Synology: Snapshot Replication and immutable snapshots](https://kb.synology.com/en-us/DSM/help/SnapshotReplication/snapshots?version=7)
- [Synology NAS security guidance](https://kb.synology.com/en-us/DSM/tutorial/How_to_add_extra_security_to_your_Synology_NAS)
- [Docker: Manage secrets securely in Compose](https://docs.docker.com/compose/how-tos/use-secrets/)
- [Docker: Compose trust model](https://docs.docker.com/compose/trust-model/)
- [Docker: Swarm secrets](https://docs.docker.com/engine/swarm/secrets/)
- [Restic: Preparing a new repository and supplying passwords](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
- [Restic: Scripting environment and password commands](https://restic.readthedocs.io/en/stable/075_scripting.html)
- [Restic: Append-only repositories and maintenance separation](https://restic.readthedocs.io/en/stable/060_forget.html)
- [OpenSSH: `authorized_keys` restrictions](https://man.openbsd.org/OpenBSD-current/man8/sshd.8)

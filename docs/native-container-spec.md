# Native Synology container deployment specification

Status: Proposed

Date: 2026-07-16

Related assessment: [Security findings](security-findings.md)

## 1. Purpose

This specification defines a replacement for building and running the Hermes
backup image from a Git checkout and Compose project on the Synology NAS.

The replacement builds a release image in GitHub Actions, publishes it to the
GitHub Container Registry (GHCR), and creates fixed one-shot containers directly
in Synology's Docker Engine. DSM Task Scheduler starts those existing containers
by name. No Git checkout, Dockerfile, build context, Compose file, or application
script is required on the NAS.

The design preserves the existing streamed, encrypted Restic backup workflow and
the container hardening that can be expressed through native Docker options.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** in
this document describe implementation requirements.

## 2. Goals

The implementation MUST:

1. Eliminate scheduled root execution of files controlled by an interactive DSM
   user or a mutable Git working tree.
2. Build, test, scan, identify, and publish the container outside the NAS.
3. Deploy an immutable image selected by digest, not an automatically moving
   tag.
4. Keep the Restic password and SSH private key out of the image, registry,
   container environment, Docker command line, GitHub Actions logs, and Docker
   metadata.
5. Store confidential runtime credentials as individual read-only file mounts
   from a dedicated encrypted Synology location.
6. Run the backup process as a fixed, unprivileged UID/GID.
7. Preserve a read-only container root filesystem, tmpfs runtime storage,
   dropped capabilities, and `no-new-privileges`.
8. Create separate containers for daily backup, repository checking, and
   pruning so maintenance containers do not receive the SSH private key.
9. Preserve non-overlapping execution and propagate failures to DSM monitoring.
10. Support deliberate image upgrades, credential rotation, rollback, and
    disaster recovery.

The implementation SHOULD:

1. Avoid storing a GHCR credential on the NAS by publishing a public image.
2. Support both `linux/amd64` and `linux/arm64` when required by supported NAS
   models.
3. Generate image provenance and an SBOM.
4. Protect the local repository with immutable Btrfs snapshots and maintain a
   second copy outside the NAS.

## 3. Non-goals

This design does not:

- protect mounted secrets from a live DSM root or Docker administrator;
- turn Docker environment variables into a secret store;
- make a local read/write Restic repository append-only;
- replace immutable snapshots or an off-site backup copy;
- automatically deploy every newly published image;
- automatically rotate the SSH key, Restic password, or Synology encryption
  recovery material;
- require Docker Swarm, Kubernetes, or a third-party orchestrator; or
- require a long-running scheduler inside the backup container.

## 4. Security boundaries

The design uses these trust boundaries:

| Component | Trusted for |
| --- | --- |
| Protected GitHub repository and release workflow | Source review and release authorization |
| GitHub Actions | Building and attesting the published image |
| GHCR | Distributing image content identified by digest |
| DSM administrators and Docker Engine | Container configuration, mounts, and execution |
| Encrypted Synology secret share | Protecting credentials while storage is locked or offline |
| Fixed container image | Backup implementation and bundled tools |
| Hermes SSH forced command | Limiting what possession of the SSH key authorizes |
| Restic encryption | Backup confidentiality when its password remains secret |
| Immutable/off-site storage | Recovery from destructive NAS compromise |

Publishing a prebuilt image removes the working tree and Compose project from
the root execution path. It does not reduce the authority of DSM root, Docker,
or a running container that has been granted its credential mounts.

## 5. Target architecture

```text
GitHub repository
    |
    | protected release/tag
    v
GitHub Actions
    |-- test and lint
    |-- build for required platforms
    |-- vulnerability scan
    |-- generate SBOM and provenance
    `-- push immutable image
          |
          v
        GHCR
          |
          | pull and verify digest
          v
Synology Container Manager / Docker Engine
    |-- hermes-backup-daily   (repository + password + SSH key + known_hosts)
    |-- hermes-backup-check   (repository + password)
    `-- hermes-backup-prune   (repository + password)
          |
          v
Encrypted local Restic repository
    |-- immutable Btrfs snapshots
    `-- second NAS or off-site copy
```

## 6. Image publication

### 6.1 Registry and visibility

The canonical image name SHOULD be:

```text
ghcr.io/OWNER/hermes-nas-backup
```

The GHCR package SHOULD be public because the image contains no private data.
Public visibility allows the NAS to pull anonymously and avoids adding a
long-lived GitHub registry credential to the NAS.

If policy requires a private image:

- the NAS MUST use a dedicated classic GitHub personal access token with only
  `read:packages`;
- the token MUST NOT have `repo`, `write:packages`, or `delete:packages`;
- the token MUST be treated as another NAS secret and rotated independently;
- registry authentication MUST use password standard input, not a command-line
  argument; and
- the operator MUST determine how DSM stores registry credentials before
  accepting the residual risk.

### 6.2 Release identifiers

Every release MUST publish at least:

```text
ghcr.io/OWNER/hermes-nas-backup:vX.Y.Z
ghcr.io/OWNER/hermes-nas-backup:sha-GIT_COMMIT
ghcr.io/OWNER/hermes-nas-backup@sha256:IMAGE_DIGEST
```

The digest is the deployment identity. Tags are discovery and human-facing
version labels only.

The deployment process MUST NOT automatically follow `latest`. The workflow MAY
publish `latest` for convenience, but NAS deployment documentation and commands
MUST use a digest.

### 6.3 Workflow triggers and permissions

Publishing MUST occur only from an explicitly authorized release event, such as
a protected semantic-version tag or an approved GitHub release.

The publishing job MUST declare minimum permissions:

```yaml
permissions:
  contents: read
  packages: write
  attestations: write
  id-token: write
```

The workflow MUST use the repository-scoped `GITHUB_TOKEN` to publish. It MUST
NOT use a personal access token for normal image publication.

All third-party and GitHub Actions MUST be pinned to full commit SHAs. Mutable
major-version tags alone are insufficient for the release workflow.

### 6.4 Required pipeline stages

The release pipeline MUST complete these stages before publishing a deployable
image:

1. Check out the exact release commit.
2. Run the repository test suite.
3. Run ShellCheck against shell scripts.
4. Build the requested platform image or multi-platform manifest.
5. Run a vulnerability scan and fail according to the documented severity
   policy.
6. Generate an SBOM.
7. Push version and commit tags.
8. Capture the pushed manifest digest.
9. Generate a GitHub artifact attestation for the pushed digest.
10. Publish release notes containing the source commit, image digest, supported
    platforms, configuration-schema version, and known migration requirements.

The pipeline SHOULD also run a smoke test against the final image rather than
only testing files in the checkout.

### 6.5 Supply-chain requirements

The Dockerfile base image MUST be pinned by digest. Automated dependency tooling
SHOULD propose reviewed digest updates regularly.

The image MUST include OCI labels for at least:

- source repository;
- source revision;
- semantic version;
- build creation time; and
- license, when applicable.

No GitHub token, build credential, repository secret, SSH key, Restic password,
or private test material may be copied into an image layer or included in build
arguments or persistent build environment variables.

## 7. Image runtime contract

### 7.1 Fixed runtime identity

The published image MUST use this fixed identity unless a future specification
revision changes it:

```text
UID: 65532
GID: 65532
```

The Dockerfile MUST create or select that identity and end with an equivalent of:

```dockerfile
USER 65532:65532
```

The entrypoint MUST NOT start as root in order to implement a `PUID`/`PGID`
ownership rewrite. Container creation SHOULD additionally set
`--user 65532:65532` as defense in depth.

NAS installation MUST verify that UID and GID 65532 are not assigned to an
unrelated local principal before changing file ownership.

### 7.2 Filesystem contract

The image MUST operate with a read-only root filesystem.

The only writable paths available to a normal run MUST be:

- `/repository`, backed by the Restic repository bind mount; and
- `/tmp`, backed by an ephemeral tmpfs.

The image MUST NOT declare a persistent anonymous volume for `/tmp`.

The image MUST contain the empty mount-point parent directories
`/run/secrets` and `/run/config`. They MUST be owned by root and not writable by
UID/GID 65532. This avoids relying on the container runtime to synthesize paths
under a read-only root filesystem.

The default runtime paths are:

```text
RESTIC_REPOSITORY=/repository
RESTIC_PASSWORD_FILE=/run/secrets/restic_password
RESTIC_CACHE_DIR=/tmp/restic-cache
SSH_KEY_FILE=/run/secrets/hermes_ssh_key
SSH_KNOWN_HOSTS_FILE=/run/config/known_hosts
```

These defaults SHOULD be embedded in the image. Normal NAS configuration SHOULD
not override them.

### 7.3 Entrypoint and modes

The image entrypoint MUST remain a one-shot process that exits after completing
the requested operation.

Supported modes are:

| Mode | Purpose | Required mounts |
| --- | --- | --- |
| `init` | Initialize an empty Restic repository | Repository RW, password RO |
| `backup` | Stream a Hermes backup and apply configured retention | Repository RW, password RO, SSH key RO, known_hosts RO |
| `snapshots` | List matching snapshots | Repository RW, password RO |
| `check` | Check repository metadata and configured data subset | Repository RW, password RO |
| `prune` | Remove unreferenced repository data | Repository RW, password RO |

Modes that do not use SSH MUST NOT be given the SSH private key mount.

The entrypoint MUST:

- preserve `set -Eeuo pipefail` behavior;
- use arrays or equivalent safe argument construction;
- never log secret values;
- refuse unreadable required files;
- preserve strict SSH host-key checking;
- preserve Restic `--stdin-from-command` failure propagation;
- retain the repository lock preventing overlapping operations;
- clean temporary runtime files on normal exit and signals; and
- return nonzero for every failed backup, check, prune, initialization, or
  source command.

### 7.4 Container privileges

All production containers MUST be created with the equivalent of:

```text
--read-only
--cap-drop ALL
--security-opt no-new-privileges=true
--restart no
--user 65532:65532
```

They MUST NOT use:

- `--privileged`;
- the host PID or IPC namespace;
- a Docker socket mount;
- host devices;
- added Linux capabilities;
- a published TCP/UDP port; or
- host networking unless a documented compatibility test proves bridge
  networking cannot meet the requirement and a security review accepts the
  change.

The `/tmp` mount MUST be an ephemeral tmpfs with an initial target configuration
equivalent to:

```text
rw,noexec,nosuid,nodev,size=128m,mode=0700,uid=65532,gid=65532
```

The size MUST be configurable during container creation because Restic may need
more space for concurrent pack staging on larger repositories.

No web portal is required. Auto-restart MUST be disabled for these successful
one-shot containers.

## 8. Configuration and secrets

### 8.1 Environment variables

Only non-confidential configuration may be stored in Docker environment
metadata.

Approved environment variables are:

```text
HERMES_SSH_TARGET
SSH_PORT
RESTIC_HOST
RESTIC_TAG
MODE
FORGET_AFTER_BACKUP
PRUNE_AFTER_BACKUP
KEEP_DAILY
KEEP_WEEKLY
KEEP_MONTHLY
CHECK_READ_DATA_SUBSET
SSH_CONNECT_TIMEOUT
```

The following MUST NOT be environment-variable values:

- the Restic password;
- the SSH private key or its passphrase;
- a GHCR token;
- a Synology encrypted-share key;
- a Synology volume recovery key; or
- credentials for an external secret manager.

Environment variable names ending in `_FILE` contain paths, not secrets, and
MAY use the image defaults.

### 8.2 Secret storage

The NAS MUST provide a dedicated encrypted shared folder for application
credentials. An illustrative location is:

```text
/volume1/hermes-backup-secrets
```

The actual location is installation-specific.

The share MUST:

- have explicit DSM ACLs denying unrelated users and groups;
- not be exposed through SMB, NFS, FTP, WebDAV, Synology Drive, media indexing,
  or search indexing;
- not be included in an unrelated synchronization job;
- be excluded from backups that would copy plaintext mounted contents unless
  that backup has a separately reviewed encryption and recovery design; and
- use either manual unlock, an external Key Manager store, or remote KMIP
  according to the chosen availability profile.

Recommended runtime paths and modes are:

```text
/volume1/hermes-backup-secrets/runtime/           0500  65532:65532
/volume1/hermes-backup-secrets/runtime/id_ed25519 0400  65532:65532
/volume1/hermes-backup-secrets/runtime/restic     0400  65532:65532
```

File names are not a security boundary and MAY differ.

The SSH public key MAY be stored outside the encrypted share. The private key
MUST be unique to this backup source and MUST have an independently removable,
restricted `authorized_keys` entry.

### 8.3 Integrity-sensitive configuration

`known_hosts` is not confidential but is integrity-sensitive. It SHOULD be
stored outside the secret share in a root-owned configuration location, for
example:

```text
/volume1/hermes-backup-config/known_hosts
```

The file MUST be readable by UID 65532 and not writable by that UID. An
illustrative ownership and mode are:

```text
root:root 0444
```

The host key fingerprint MUST be verified out of band before installation and
whenever it changes.

### 8.4 Repository storage

The repository MUST be a separate shared folder from the credentials, for
example:

```text
/volume1/Backups/restic-hermes
```

UID/GID 65532 MUST have the read, write, and traversal access Restic requires.
Unrelated users and services SHOULD have no access.

The repository SHOULD reside on Btrfs where the NAS supports it. Immutable
snapshots SHOULD protect it for at least 7 to 14 days, subject to model support
and capacity planning. A second encrypted copy MUST exist outside the NAS before
the system is considered the sole reliable backup of the source data.

### 8.5 Recovery copies

At least two independent recovery copies of the following MUST exist outside
the NAS:

- current Restic password;
- Synology encrypted shared-folder key, when used;
- encrypted-volume recovery key, when used; and
- remote-KMIP recovery information and certificate procedures, when used.

Recovery copies MUST NOT share the same single failure domain as the NAS.

## 9. Synology container topology

### 9.1 Daily container

Container name:

```text
hermes-backup-daily
```

Environment:

```text
MODE=backup
HERMES_SSH_TARGET=user@host
SSH_PORT=22
RESTIC_HOST=hermes-server
RESTIC_TAG=hermes
FORGET_AFTER_BACKUP=true
PRUNE_AFTER_BACKUP=false
KEEP_DAILY=7
KEEP_WEEKLY=5
KEEP_MONTHLY=12
```

Mounts:

| Host | Container | Access |
| --- | --- | --- |
| Restic repository | `/repository` | Read/write |
| Restic password file | `/run/secrets/restic_password` | Read-only |
| SSH private key | `/run/secrets/hermes_ssh_key` | Read-only |
| Verified known_hosts | `/run/config/known_hosts` | Read-only |

### 9.2 Check container

Container name:

```text
hermes-backup-check
```

Environment:

```text
MODE=check
RESTIC_HOST=hermes-server
RESTIC_TAG=hermes
CHECK_READ_DATA_SUBSET=5%
```

Mounts:

| Host | Container | Access |
| --- | --- | --- |
| Restic repository | `/repository` | Read/write |
| Restic password file | `/run/secrets/restic_password` | Read-only |

The check container MUST NOT receive the SSH private key or known-hosts mount.

### 9.3 Prune container

Container name:

```text
hermes-backup-prune
```

Environment:

```text
MODE=prune
RESTIC_HOST=hermes-server
RESTIC_TAG=hermes
```

Mounts:

| Host | Container | Access |
| --- | --- | --- |
| Restic repository | `/repository` | Read/write |
| Restic password file | `/run/secrets/restic_password` | Read-only |

The prune container MUST NOT receive the SSH private key or known-hosts mount.

### 9.4 Administrative modes

`init` and `snapshots` SHOULD use temporary manually created containers or
dedicated stopped containers that receive only their required mounts.

Repository initialization MUST NOT overwrite or reinitialize a repository whose
`config` already exists.

## 10. Container creation

### 10.1 Preferred method

Production containers SHOULD be created once with native `docker create`
commands and then managed and observed through Synology Container Manager.

This method is preferred over the single-container UI because the documented UI
does not expose every required hardening setting, particularly read-only root,
tmpfs, and `no-new-privileges`.

Container creation is an explicit privileged deployment operation. The creation
command MAY be entered interactively or generated on a trusted workstation, but
it MUST NOT be stored in a normal user's writable scheduled script on the NAS.

### 10.2 Daily creation template

The implementation documentation MUST provide a command equivalent to this
template, with placeholders resolved and the image specified by digest:

```bash
docker create \
  --name hermes-backup-daily \
  --user 65532:65532 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=128m,mode=0700,uid=65532,gid=65532 \
  --cap-drop ALL \
  --security-opt no-new-privileges=true \
  --restart no \
  --network bridge \
  --mount type=bind,src=REPOSITORY_PATH,dst=/repository \
  --mount type=bind,src=PASSWORD_PATH,dst=/run/secrets/restic_password,readonly \
  --mount type=bind,src=SSH_KEY_PATH,dst=/run/secrets/hermes_ssh_key,readonly \
  --mount type=bind,src=KNOWN_HOSTS_PATH,dst=/run/config/known_hosts,readonly \
  --env MODE=backup \
  --env HERMES_SSH_TARGET=USER_AT_HOST \
  --env SSH_PORT=22 \
  --env RESTIC_HOST=hermes-server \
  --env RESTIC_TAG=hermes \
  --env FORGET_AFTER_BACKUP=true \
  --env PRUNE_AFTER_BACKUP=false \
  --env KEEP_DAILY=7 \
  --env KEEP_WEEKLY=5 \
  --env KEEP_MONTHLY=12 \
  IMAGE_REFERENCE_AT_DIGEST
```

The final implementation MAY add resource and log limits after testing. It MUST
NOT weaken the required security options.

Equivalent templates MUST be provided for `check` and `prune`, omitting their
unneeded mounts and environment variables.

### 10.3 Pure UI fallback

Creating the container entirely through Container Manager's UI MAY be documented
as a compatibility fallback. It is not the preferred security profile unless
the DSM version exposes and verifies all required runtime settings.

If the UI cannot configure read-only root, tmpfs, capability dropping, and
`no-new-privileges`, the fallback MUST explicitly document the lost controls.
Secrets still MUST be file mounts and MUST NOT be converted to environment
variables.

## 11. Scheduling

### 11.1 Task model

DSM Task Scheduler MUST start existing containers by their fixed names. It MUST
NOT run Compose, build an image, pull an unreviewed tag, or evaluate files from a
user-writable project directory.

The intended command shape is:

```bash
ABSOLUTE_DOCKER_PATH start --attach hermes-backup-daily
```

Equivalent weekly tasks start `hermes-backup-check` and
`hermes-backup-prune`.

The deployment procedure MUST discover and record the actual Docker CLI path on
the target DSM version. It MUST use that absolute path in Task Scheduler.

### 11.2 Exit status and notifications

Before production scheduling, an acceptance test MUST demonstrate that:

1. a successful container exit is reported as task success;
2. a deliberately failed container exit is reported as task failure;
3. stdout/stderr or Docker logs contain actionable diagnostics; and
4. DSM sends the configured abnormal-task notification.

If `docker start --attach` on the installed DSM/Docker version does not
propagate the container's exit status, the scheduled command MUST also wait for
the container and explicitly return its recorded exit code. Any such command
must remain stored inside DSM Task Scheduler or another root-controlled location,
not an interactive user's share.

### 11.3 Schedule separation

Recommended initial scheduling is:

- daily backup during a quiet window;
- weekly repository check outside the backup window;
- weekly prune outside both other windows; and
- immutable Synology snapshot after the normal backup completion window.

The shared repository lock remains mandatory. A concurrent task MUST fail safely
rather than operate on the repository simultaneously.

The containers MUST remain stopped between runs. A long-running cron process
inside the image is out of scope for the preferred design.

## 12. Installation procedure

The delivered implementation guide MUST perform or direct these steps:

1. Confirm NAS model, DSM version, CPU architecture, Btrfs support, immutable
   snapshot support, and encrypted-storage options.
2. Install and update Synology Container Manager.
3. Confirm UID/GID 65532 are available for this application.
4. Create the dedicated encrypted secrets share and choose its unlock profile.
5. Create the root-controlled configuration location for `known_hosts`.
6. Create or select the separate Restic repository share.
7. Apply and verify DSM ACLs plus numeric POSIX ownership and modes.
8. Generate or import the Restic password and SSH key without printing private
   values.
9. Verify the Hermes SSH host key out of band and install `known_hosts`.
10. Install the restricted SSH public-key entry on the Hermes server.
11. Pull the public image or authenticate with a least-privilege read-only token
    if private distribution is mandatory.
12. Verify image provenance and digest.
13. Create the daily, check, and prune containers from that digest.
14. Initialize the repository only if it is new.
15. Run a manual backup, list snapshots, perform a check, and restore test data.
16. Create DSM scheduled tasks and validate success/failure notification.
17. Enable immutable repository snapshots and the second-copy workflow.
18. Record the deployed image digest, credential creation dates, recovery-copy
    locations, and operational owner.

## 13. Updates and rollback

### 13.1 Image update

Image deployment MUST be deliberate. The NAS MUST NOT automatically replace a
running or stopped container merely because a tag changed.

An update procedure MUST:

1. disable or pause the related scheduled tasks;
2. pull the new image by digest;
3. verify its attestation, source repository, source revision, and digest;
4. create candidate containers with new temporary names and the reviewed
   settings;
5. run at least `snapshots` and an appropriate check or test backup;
6. preserve the old stopped containers and image during a rollback window;
7. replace or rename containers so scheduled tasks again reference the fixed
   production names;
8. re-enable scheduling; and
9. record the new deployed digest.

Changing image versions MUST NOT require copying or re-encoding the secret
values.

### 13.2 Rollback

Rollback MUST be possible by disabling schedules, restoring the prior container
names or recreating them from the recorded prior digest, running a validation,
and re-enabling schedules.

Repository format compatibility MUST be reviewed before deploying a Restic
version that could write an incompatible format. A code rollback cannot undo a
repository-format migration.

### 13.3 Credential rotation

Credential rotation MUST be independent of image deployment.

SSH rotation procedure:

1. create a new key in the encrypted share;
2. add its restricted public-key entry on the Hermes server;
3. create or update a candidate daily container to mount the new key;
4. test a complete backup;
5. remove the old `authorized_keys` entry; and
6. securely retire the old private key and update recovery records.

Restic rotation procedure:

1. create a new strong password;
2. add and test a new Restic key;
3. update the mounted password file atomically;
4. test snapshots, check, and restore access;
5. remove the old Restic key when appropriate; and
6. update offline recovery copies.

Suspected access to decrypted repository contents requires migration to a new
repository and new key material; password rotation alone cannot retract data
already obtained by an attacker.

## 14. Monitoring and operations

DSM MUST notify operators when any scheduled container exits abnormally.

Operators MUST be able to determine:

- last start and finish time;
- deployed image digest;
- container exit code;
- last successful Restic snapshot ID;
- current repository check status;
- last prune result;
- immutable snapshot status; and
- second-copy status.

Logs MUST NOT contain:

- the Restic password;
- private-key content;
- registry tokens;
- Synology recovery keys; or
- complete environment or container inspection output sent to untrusted
  destinations.

Container logs SHOULD have a bounded retention policy. Backup completion and
failure logs SHOULD use UTC timestamps.

The restore procedure MUST be tested periodically. A repository check alone is
not a substitute for restoring and validating representative Hermes and
MemPalace content.

## 15. Migration from the Compose deployment

Migration MUST avoid a period in which both old and new scheduled jobs can
write the repository concurrently.

Recommended sequence:

1. Publish and verify the first GHCR release.
2. Disable the existing Compose-based DSM tasks.
3. Record the current Restic repository and credential recovery state.
4. Create the encrypted secret share and root-controlled `known_hosts` location.
5. Rotate or securely move the Restic password and SSH key.
6. Apply UID/GID 65532 ownership and verify DSM ACLs.
7. Pull and verify the release image by digest.
8. Create the new containers.
9. Confirm the existing repository is recognized and is not reinitialized.
10. Run snapshots, check, backup, and representative restore tests.
11. Create and validate the new scheduled tasks.
12. Enable immutable snapshots and confirm the second-copy process.
13. Observe at least one successful scheduled cycle.
14. Remove the old scheduled tasks.
15. Remove the NAS Git checkout, Compose project, build cache, and obsolete
    secrets only after rollback and recovery requirements are satisfied.

The old SSH public key MUST be removed from the Hermes server if migration
rotates the key.

## 16. Verification and acceptance criteria

The implementation is accepted only when all applicable checks pass.

### 16.1 CI and image

- [ ] Tests and lint pass before image publication.
- [ ] Required platform image exists.
- [ ] Image is referenced by digest in deployment records.
- [ ] Base image is pinned by digest.
- [ ] Release workflow actions are pinned to full SHAs.
- [ ] Workflow uses minimum `GITHUB_TOKEN` permissions.
- [ ] Vulnerability policy passes.
- [ ] SBOM is available.
- [ ] Artifact attestation verifies against the expected source repository and
      commit.
- [ ] Inspecting image history finds no secret or build credential.

### 16.2 NAS deployment

- [ ] No Git checkout, Dockerfile, Compose file, or application script is used by
      a scheduled task.
- [ ] Public GHCR pulls require no NAS registry credential, or the approved
      private-registry exception is documented.
- [ ] Production containers use UID/GID 65532.
- [ ] Production containers are not privileged.
- [ ] Effective capabilities are empty.
- [ ] `no-new-privileges` is active.
- [ ] The root filesystem rejects writes.
- [ ] `/tmp` is tmpfs with the specified restrictive options.
- [ ] No ports are published.
- [ ] No Docker socket or host device is mounted.
- [ ] Auto-restart is disabled.
- [ ] Containers remain stopped between scheduled runs.

### 16.3 Secrets and configuration

- [ ] `docker inspect` contains no secret value.
- [ ] Restic password and SSH key are individual read-only file mounts.
- [ ] Check and prune containers have no SSH key mount.
- [ ] Secret files are owned by UID/GID 65532 and use mode `0400`.
- [ ] Secret share DSM ACLs deny unrelated access.
- [ ] Secret share is encrypted and its unlock policy is documented.
- [ ] `known_hosts` is readable but not writable by UID 65532.
- [ ] SSH host fingerprint was verified out of band.
- [ ] Restricted SSH public-key options were tested.
- [ ] Two independent offline recovery copies exist.

### 16.4 Backup behavior

- [ ] A successful manual backup creates a Restic snapshot.
- [ ] SSH/exporter failure creates no snapshot and returns nonzero.
- [ ] Retention runs only after successful backup.
- [ ] Overlapping operations are rejected by the repository lock.
- [ ] Check mode succeeds with the configured subset.
- [ ] Prune mode runs only in its maintenance window.
- [ ] A representative restore succeeds and its contents validate.
- [ ] DSM reports container failure as scheduled-task failure.
- [ ] Failure notification reaches the operator.
- [ ] Immutable snapshots protect the repository where supported.
- [ ] A second copy exists outside the NAS.

## 17. Required documentation deliverables

Implementation is incomplete until the repository contains:

1. A GitHub Actions publishing workflow.
2. A public image contract listing all supported environment variables and
   mounts.
3. Release and digest verification instructions.
4. Native `docker create` templates for daily, check, prune, init, and snapshot
   modes.
5. Synology encrypted-share, ACL, UID/GID, and Task Scheduler instructions.
6. Upgrade, rollback, credential-rotation, and incident-response procedures.
7. Restore-test instructions.
8. A migration guide from the existing Compose deployment.

## 18. Open deployment decisions

The following must be resolved from the target NAS before implementation is
finalized:

- exact Synology model and CPU architecture;
- DSM and Container Manager versions;
- absolute Docker CLI path;
- whether UID/GID 65532 are unused and supported by the relevant DSM ACL path;
- Btrfs and immutable snapshot support;
- encrypted shared-folder versus encrypted-volume support;
- manual unlock, external Key Manager, or remote-KMIP profile;
- required `/tmp` size based on observed Restic workload;
- public versus policy-mandated private GHCR visibility;
- desired off-site or second-NAS target; and
- acceptable maintenance and rollback windows.

These are deployment parameters. They do not change the prohibition on passing
secret values through container environment variables.

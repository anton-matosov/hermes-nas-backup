# Hostile-source Hermes backup architecture specification

Status: Rejected

Date: 2026-07-16

Related assessment: [Security findings](security-findings.md)

Supersedes: [Native Synology container deployment specification](native-container-spec.md)

## 1. Purpose

This specification defines the target backup architecture for Hermes when the
source is an Internet-connected AI agent and therefore cannot be trusted with
backup credentials, backup policy, backup scheduling, or network access to
backup storage.

The design uses an independent trusted backup gateway to pull an
application-consistent export from Hermes, encrypt it, and write the same export
to two protected repositories. The Synology NAS is a storage service, not the
backup client. When Hermes is deployed as a virtual machine on a hypervisor that
supports image backup, a hypervisor-controlled image backup is also required.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** in
this document describe implementation requirements.

## 2. Foundational assumption

Hermes MUST be treated as a hostile tenant, not merely as a server that might
eventually be compromised.

The design MUST assume Hermes can:

- execute attacker-influenced code;
- make arbitrary outbound Internet connections;
- modify its application data before a backup;
- modify files owned by its runtime identity;
- return malicious, inconsistent, incomplete, or unbounded backup output;
- detect and interfere with in-guest backup activity;
- stop responding or deliberately fail a backup; and
- retain information it can read during normal operation.

Hermes MUST NOT be given:

- a Restic or other repository encryption password;
- a repository transport credential;
- a credential capable of deleting, pruning, or expiring backups;
- a credential for the NAS, backup gateway, hypervisor, or off-site service;
- access to a backup scheduler or monitoring success signal; or
- a network route to repository or management endpoints.

No backup architecture can force a hostile source to produce truthful future
data. The system protects previously captured recovery points, detects missing
or anomalous future backups, and provides an independent machine-level recovery
path. It does not prove that data supplied after source compromise is honest.

## 3. Goals

The implementation MUST:

1. Keep all repository credentials and encryption keys outside Hermes.
2. Prevent Hermes from initiating network connections to backup components.
3. Schedule and initiate backups from a system outside Hermes and the NAS.
4. Preserve the application-consistent Hermes and MemPalace export.
5. Treat all source output as hostile, opaque, and potentially unbounded.
6. Encrypt backup content before it reaches either storage provider.
7. Give the normal backup path no ability to overwrite or delete existing
   local recovery points.
8. Maintain a second encrypted copy in an independent off-site failure domain
   with append-only or immutable protection.
9. Separate routine backup credentials from maintenance credentials.
10. Detect backup failure without trusting a signal emitted by Hermes.
11. Test restoration in an isolated environment that treats restored content
    as hostile.
12. Support credential rotation, incident response, rollback, and migration
    from the current NAS-pull implementation.

The implementation SHOULD:

1. Run Hermes in an isolated virtual machine.
2. Add an image-level backup controlled by the hypervisor.
3. Use Secure Boot, full-disk encryption, and TPM-bound credentials on the
   backup gateway where supported.
4. Randomize the application-backup start time within a documented window.
5. Use independent encryption keys for the local and off-site repositories.
6. Preserve at least 30 days of immutable off-site recovery points.

## 4. Non-goals

This design does not:

- make new data trustworthy after Hermes has been compromised;
- prevent Hermes from destroying or exfiltrating data it can already read;
- protect backup secrets from live root compromise of the backup gateway;
- make a same-NAS snapshot an off-site backup;
- allow unattended pruning from the normal backup identity;
- require the gateway to interpret or extract the source TAR stream;
- rely on a backup success message sent by Hermes; or
- make repository checks a substitute for full restore tests.

## 5. Security boundaries

| Component | Trust and authority |
| --- | --- |
| Hermes | Hostile data producer; no backup authority |
| Hypervisor | Trusted to isolate Hermes and capture machine state outside the guest |
| Backup gateway | Trusted to schedule pulls, hold routine secrets, bound hostile output, and encrypt data |
| Synology NAS | Untrusted for confidentiality; trusted only for local storage availability within its snapshot window |
| Local repository service | Accepts authenticated append-only Restic traffic; has no repository decryption key |
| Off-site provider | Untrusted for confidentiality; trusted to enforce contracted immutability or append-only behavior |
| Maintenance workstation | Highly trusted, normally offline or isolated; temporarily holds deletion authority |
| Monitoring service | Trusted to report observed backup outcomes; has no repository decryption or deletion authority |
| Recovery operator | Trusted to authorize and inspect restores before restored content reaches production |

Compromise of the backup gateway is the most serious technical compromise in
the baseline design because the gateway can pull current Hermes data and decrypt
repository history. The gateway MUST therefore have a smaller attack surface
and stricter network policy than both Hermes and the NAS.

## 6. Target architecture

### 6.1 Baseline application-backup architecture

```text
                         constrained SSH pull
Hermes AI agent  <--------------------------------  Dedicated backup gateway
no backup secrets                                  scheduler, keys, bounded spool
                                                               |
                                      same export, independent encrypted writes
                                               +---------------+---------------+
                                               |                               |
                                               v                               v
                                  Synology rest-server              Off-site repository
                                  append-only                       immutable or append-only
                                  no repository decrypt key         no repository decrypt key
                                  immutable Btrfs snapshots         independent failure domain

       Isolated maintenance workstation ---> retention, checks, and restore
       External monitoring service --------> observes gateway/storage results
```

The gateway MUST pull one export into a bounded spool and MUST back up those
exact bytes to both repositories. It MUST NOT request two independent exports
for the two targets because a hostile source could return different content.

### 6.2 Preferred hypervisor profile

When Hermes runs in a virtual machine on a hypervisor that supports image
backup, the implementation MUST add:

```text
Hermes VM
   |
   | disk state captured outside guest control
   v
Trusted hypervisor ----> dedicated backup server ----> off-site copy
```

The preferred open-source implementation is Proxmox VE with a dedicated
Proxmox Backup Server. The Hermes guest MUST NOT possess the backup API token or
encryption key. The backup token MUST have backup permission without prune or
administrative permission.

Image-level backup does not replace the application export. A hostile or busy
guest can leave an image only crash-consistent, while the application exporter
can provide semantic consistency when it behaves correctly. The two recovery
paths address different failures.

### 6.3 Constrained fallback

If a separate gateway cannot be deployed, the current NAS-initiated pull MAY be
retained temporarily after applying the security findings. This fallback is not
compliant with the target architecture because live DSM root can obtain both
source-read capability and the repository decryption key.

Repository credentials MUST NOT be moved onto Hermes as a fallback.

## 7. Network policy

Network policy MUST default to deny and implement at least this matrix:

| Source | Destination | Permitted service | Requirement |
| --- | --- | --- | --- |
| Backup gateway | Hermes | SSH on configured port | Required |
| Backup gateway | Synology repository endpoint | HTTPS | Required |
| Backup gateway | Off-site repository endpoint | Provider-specific TLS/SSH | Required |
| Backup gateway | Monitoring endpoint | HTTPS or approved protocol | Required |
| Backup gateway | DNS, NTP, update mirrors | Approved infrastructure only | Optional and allowlisted |
| Maintenance workstation | Administrative repository endpoint | TLS/SSH during maintenance window | Conditional |
| Hypervisor | Dedicated backup server | Product-specific backup network | Conditional |
| Hermes | Any backup or management component | None | Explicitly denied |
| NAS | Hermes | None | Explicitly denied in target design |
| Public Internet | Gateway, NAS, hypervisor, or backup server management | None | Explicitly denied |

Hermes MAY retain its required Internet access on a separate application
network. That network MUST have no route to the backup, storage, or management
networks. DNS names alone are not a security boundary.

The Hermes guest MUST NOT be able to reach the hypervisor management address,
backup server, NAS repository endpoint, gateway, monitoring control plane, or
off-site repository endpoint.

## 8. Hermes source contract

### 8.1 Dedicated identity and forced command

The source MUST normally expose exactly one SSH public key entry for the backup
gateway. A second entry MAY coexist temporarily during the tested rotation
procedure in section 17.1.
It MUST use an equivalent of:

```text
from="GATEWAY_IP",restrict,command="/usr/local/libexec/hermes-backup/export" ssh-ed25519 ...
```

The entry MUST:

- be unique to this source;
- restrict the accepted source address;
- use `restrict`;
- force one absolute command;
- ignore or reject `SSH_ORIGINAL_COMMAND`;
- prohibit shell, PTY, forwarding, agent forwarding, X11, and user RC files;
  and
- be independently revocable.

The account SHOULD have no password and no unrelated interactive or application
access.

### 8.2 Exporter integrity

The forced-command executable and every executable helper it invokes MUST:

- reside outside a normal user's writable home directories;
- be owned by root;
- not be writable by the Hermes runtime identity;
- use absolute paths;
- not load executable code or dependencies from user-writable locations;
- treat application-owned configuration and data as untrusted inputs;
  and
- be installed from an identified, reviewed release artifact.

The current paths under `/home/anton/.local/bin` do not meet this requirement.

The exporter MAY run with the Hermes application identity when required to read
data. Root ownership of the exporter protects the protocol implementation; it
does not make application-owned data trustworthy.

### 8.3 Stream protocol

On success, stdout MUST contain only one uncompressed TAR stream. Status and
diagnostic output MUST go to stderr.

The stream MUST contain:

```text
RESTORE.txt
hermes/hermes.zip
mempalace/
```

The exporter MUST:

1. use the supported Hermes backup interface;
2. hold the MemPalace writer lock for the MemPalace snapshot;
3. use SQLite's online backup API for `chroma.sqlite3`;
4. verify the copied SQLite database with `PRAGMA integrity_check`;
5. omit transient lock, WAL, and shared-memory files as currently documented;
6. fail nonzero if required data is absent or inconsistent;
7. clean its temporary data on normal exit and signals; and
8. emit no secret value.

No source-provided checksum, signature, status string, or manifest may be
treated as proof that hostile source data is truthful.

## 9. Backup gateway

### 9.1 Isolation

The gateway MUST be a separate operating-system instance from Hermes and the
NAS. It MUST NOT be administered by Hermes or run inside a runtime Hermes can
control.

A dedicated physical device is preferred. A VM is acceptable only when its
hypervisor is outside Hermes's trust boundary and Hermes cannot access the
management plane.

The gateway MUST NOT run general user workloads, AI agents, web browsing, email,
or unrelated Internet-facing services.

### 9.2 Deployment integrity

Gateway executables, service units, configuration, and parent directories MUST
be root-owned and not writable by the runtime identity.

Deployable binaries or images MUST be selected by immutable version and digest.
The implementation SHOULD publish an SBOM and provenance. Automatic updates
MAY download candidates, but activation MUST follow a reviewed rollout and
rollback procedure.

### 9.3 Runtime identity and sandbox

The scheduled backup MUST run under a dedicated, non-interactive identity. It
MUST receive only the filesystem and network access required for the backup.

A systemd implementation SHOULD use applicable controls such as:

- `NoNewPrivileges=yes`;
- `PrivateTmp=yes`;
- a restrictive `ProtectSystem` setting;
- explicit `ReadWritePaths` for spool and state;
- `ProtectHome=read-only` or stricter;
- a closed capability bounding set;
- memory, process, and runtime limits; and
- systemd credentials for secret delivery.

The final sandbox MUST be tested against required SSH, spool, Restic, DNS, and
certificate operations rather than copied blindly from this list.

### 9.4 Secrets

The gateway holds:

- one source-specific SSH private key;
- one local repository password;
- one off-site repository password;
- one local repository authentication credential;
- one off-site repository authentication credential; and
- integrity-sensitive TLS CA or SSH host-key material.

The two repositories MUST use independent encryption passwords and independent
transport credentials.

Secret values MUST NOT appear in environment variables, command-line
arguments, logs, images, Git, monitoring payloads, or crash reports. Programs
SHOULD consume credentials from file descriptors, systemd credentials, or
root-only files.

At-rest gateway credentials SHOULD be protected by full-disk encryption and,
where operationally acceptable, TPM-bound systemd credentials. These controls
do not protect against live gateway root.

At least two independent offline recovery copies of each repository recovery
secret MUST exist outside Hermes, the gateway, and the NAS.

### 9.5 Bounded spool

The gateway MUST receive one source export into a private spool before writing
either repository.

The spool MUST:

- reside on an encrypted filesystem or size-appropriate tmpfs;
- be accessible only to the backup runtime identity and root;
- have a configured maximum byte size;
- have a configured maximum runtime;
- fail the backup if the source exceeds either limit;
- never parse, list, decompress, or extract the source TAR;
- survive long enough to attempt both independent repository writes; and
- be unlinked after both attempts or after a terminal failure; and
- rely on the encrypted spool filesystem, rather than overwrite-based deletion,
  to protect residual storage blocks.

The receiver MUST distinguish a complete source exit from truncation at the
size limit. Silently accepting the first `MAX_BYTES` of an oversized source is
not compliant.

After a successful pull, the gateway MUST generate its own manifest containing
at least:

- schema version;
- UTC pull start and finish times;
- source identifier;
- byte length;
- SHA-256 digest of the exact TAR bytes;
- exporter exit status;
- verified SSH host-key fingerprint; and
- gateway release identifier.

The TAR and gateway manifest MUST be backed up together to both repositories.
The two repository snapshots MUST refer to the same TAR digest.

### 9.6 Backup behavior

The scheduled gateway identity MUST be able to create snapshots but MUST NOT be
able to forget, prune, overwrite, or delete existing local repository objects.

For each scheduled run, the gateway MUST:

1. acquire a non-blocking run lock;
2. verify required credentials and trusted host material are readable;
3. pull one bounded export from Hermes;
4. require a zero SSH/exporter exit status;
5. require a nonempty export within the configured size range;
6. generate the gateway manifest;
7. back up the TAR and manifest to the local append-only repository;
8. independently back up the same TAR and manifest to the off-site target;
9. record the snapshot identifier and result of each target;
10. report partial success as an alert and overall nonzero result;
11. remove the spool; and
12. release the run lock.

Failure of one repository MUST NOT prevent an attempt to write the other after
a valid source export has been captured.

The backup MUST NOT run retention or pruning after snapshot creation.

## 10. Synology storage service

### 10.1 Role

The NAS MUST act only as an encrypted-object storage service for the target
architecture. It MUST NOT receive:

- the Hermes SSH private key;
- either Restic repository password;
- the off-site credential;
- a source export in plaintext outside the encrypted Restic protocol; or
- routine backup deletion authority.

### 10.2 Rest server

The local repository SHOULD use the official Restic REST server with equivalent
settings to:

```text
--append-only
--private-repos
--tls
--tls-min-ver 1.3
--max-size DEPLOYMENT_QUOTA
```

Authentication MUST use a high-entropy source-specific credential stored as a
supported password verifier. Authentication MUST NOT be disabled.

The service MUST:

- be reachable only from the backup gateway and approved maintenance network;
- use a certificate validated by the gateway;
- run as a dedicated non-root identity;
- use a read-only container root filesystem when containerized;
- drop all capabilities not proven necessary;
- enable `no-new-privileges`;
- pin its image by digest;
- mount only its repository, authentication, TLS, and bounded runtime paths;
  and
- write access logs that contain no credential or repository password.

The repository share MUST NOT be exposed through SMB, NFS, FTP, WebDAV,
Synology Drive, media indexing, or normal user shares.

### 10.3 Local immutability

Where supported, the repository MUST reside on Btrfs and use immutable
Synology snapshots. The initial minimum protection window is 14 days. A longer
window SHOULD be selected from measured capacity and incident-detection time.

Local immutable snapshots are defense in depth. The system is not compliant
until a protected off-site copy exists.

### 10.4 Maintenance access

The routine REST endpoint MUST remain append-only.

Any delete-capable maintenance endpoint MUST:

- use a different authentication credential;
- be disabled by default;
- be unreachable from Hermes and the gateway routine identity;
- be enabled only during an approved maintenance window;
- be restricted to the maintenance workstation network address;
- not run concurrently with backup ingestion; and
- be disabled and verified closed when maintenance finishes.

The repository password remains on the maintenance workstation; it MUST NOT be
persisted on the NAS for maintenance.

## 11. Off-site repository

The off-site target MUST:

- be in a different physical and administrative failure domain from Hermes,
  the gateway, and the NAS;
- receive client-side encrypted backup content;
- have no repository decryption password;
- enforce append-only writes or provider-controlled immutable snapshots;
- retain protected recovery points longer than the expected compromise
  detection interval;
- support export or recovery without proprietary decryption software; and
- provide monitoring or an API sufficient to verify recent writes and
  protection status.

The initial minimum immutable window is 30 days. The target SHOULD retain daily
recovery points for 90 days and monthly recovery points for at least one year,
subject to confirmed recovery requirements and capacity.

Acceptable implementation classes include:

- a managed Restic or Borg service with append-only access and client-held
  encryption keys;
- a snapshot-enabled rsync.net account whose ZFS snapshots are immutable to
  the client credential;
- a second independently administered Restic REST server with immutable
  underlying storage; or
- a second Proxmox Backup Server for the hypervisor profile.

A plain writable SFTP, SMB, NFS, or object-store repository without independent
immutability does not satisfy this requirement.

## 12. Hypervisor-level backup

When the preferred hypervisor profile is implemented:

1. Hermes MUST run as a guest without access to the management or backup
   networks.
2. Backup scheduling MUST occur outside the guest.
3. Backup credentials and client-side encryption keys MUST remain outside the
   guest.
4. The normal hypervisor backup token MUST be able to create backups but MUST
   NOT have prune or datastore administration permission.
5. The backup server MUST perform scheduled verification.
6. An off-site synchronization or backup-copy job MUST protect the image
   backups in another failure domain.
7. A restored VM MUST first boot in an isolated network with no Internet,
   production, backup, or management access.
8. Recovery operators MUST inspect the restored system before authorizing
   production connectivity.

Guest-agent quiescing MAY improve consistency but MUST NOT be treated as a
security boundary because a hostile guest can interfere with it.

## 13. Retention and pruning

Routine backup identities MUST NOT possess deletion authority.

Retention and pruning MUST run only from the isolated maintenance workstation
through a temporary full-access path. The operator MUST inspect repository
activity and backup anomalies before enabling deletion.

Restic repositories receiving append-only writes MUST use time-window retention
options rather than only count-based options. An initial policy is:

```text
keep all snapshots within 14 days
keep daily snapshots within 90 days
keep weekly snapshots within 1 year
keep monthly snapshots within 5 years
```

The exact policy is a deployment decision, but it MUST use applicable
`--keep-within*` options and MUST preserve at least one known-good recovery point
older than the maximum credible detection delay.

Every destructive maintenance run MUST:

1. confirm the normal ingest job is stopped;
2. confirm current immutable snapshots or off-site recovery points exist;
3. run `forget --dry-run` first;
4. review unexpected source times, sizes, tags, and snapshot density;
5. run a repository check appropriate to repository size and risk;
6. record the approved deletion plan;
7. run retention and pruning;
8. verify repository health afterward; and
9. close the maintenance endpoint and confirm routine append-only behavior.

## 14. Monitoring

Monitoring MUST be controlled outside Hermes. Hermes MUST NOT be able to submit
or overwrite the authoritative backup success status.

Operators MUST be alerted for:

- source connection or exporter failure;
- export timeout or size-limit violation;
- export size outside the configured baseline;
- a changed SSH host key;
- local repository failure;
- off-site repository failure;
- different TAR digests between repository snapshots;
- failure to clean the spool;
- overlapping backup attempts;
- repository quota pressure;
- missing or expired immutable protection;
- repository check failure;
- missed schedule; and
- restore-test failure.

Operators MUST be able to determine:

- last attempted and last successful pull time;
- gateway version and configuration version;
- source exporter exit status;
- source byte count and gateway-computed SHA-256;
- snapshot identifier for each repository;
- last successful write observed at each storage target;
- immutable protection horizon;
- last check and prune result; and
- last successful application and image restore test.

Logs MUST use UTC timestamps and MUST NOT contain secret values, complete
process environments, private keys, or authorization headers.

## 15. Restore security

Every restore MUST treat repository contents as hostile because Hermes supplied
the original bytes.

Application restores MUST:

1. restore into a disposable, isolated environment;
2. use an unprivileged identity;
3. have no network access during extraction and initial inspection;
4. prohibit device creation and privilege restoration;
5. reject absolute paths and path traversal;
6. handle symlinks without allowing writes outside the restore root;
7. avoid preserving source ownership, setuid, setgid, capabilities, or unsafe
   extended attributes;
8. inspect the TAR and embedded Hermes ZIP before invoking application import;
9. run malware and policy scans appropriate to the environment;
10. validate SQLite integrity and representative Hermes/MemPalace behavior; and
11. require explicit operator approval before any recovered data reaches
    production.

VM image restores MUST initially boot on an isolated recovery network. A
restored Hermes instance MUST NOT receive production credentials or Internet
access until inspected and approved.

At least monthly, automation MUST restore and validate a non-sensitive canary.
At least quarterly, operators MUST perform a representative isolated
application restore from each repository. At least annually, operators MUST
exercise the complete disaster-recovery procedure, including offline recovery
secrets and off-site-only recovery.

## 16. Availability objectives

Unless superseded by an approved deployment-specific recovery plan, the initial
objectives are:

| Objective | Initial target |
| --- | --- |
| Application backup RPO | 24 hours |
| VM image backup RPO, when implemented | 24 hours |
| Detection of a missed backup | 36 hours |
| Local application restore initiation | 4 hours after declared incident |
| Off-site-only restore initiation | 8 hours after declared incident |
| Local immutable window | At least 14 days |
| Off-site immutable window | At least 30 days |

These are service objectives, not guarantees. The deployment owner MUST confirm
that they are adequate for Hermes and MemPalace.

## 17. Credential rotation and incidents

### 17.1 Hermes pull key

Rotation MUST:

1. create a new gateway key;
2. install a second restricted public-key entry on Hermes;
3. verify the source host key independently;
4. complete a bounded test export and backup;
5. remove the old public-key entry; and
6. securely retire the old private key.

### 17.2 Repository encryption key

Normal password rotation MUST add and test a new repository key before removing
the old key. If a decrypted repository master key may have been exposed, the
repository MUST be replaced or copied into a new repository with new master key
material. Changing only the password does not revoke a leaked master key.

### 17.3 Suspected Hermes compromise

Operators MUST:

- preserve pre-compromise immutable recovery points;
- suspend destructive maintenance;
- distrust all backups created after the earliest credible compromise time;
- isolate Hermes from backup and management networks;
- rotate the Hermes pull key after rebuilding or remediating the source;
- restore first into isolation; and
- compare application-level and image-level recovery points where available.

Hermes compromise alone does not require rotating repository credentials because
Hermes never receives them. Rotate them if evidence indicates the gateway or
maintenance workstation was also exposed.

### 17.4 Suspected gateway compromise

Operators MUST assume source confidentiality and all repository encryption keys
are compromised. They MUST revoke transport credentials, disable ingest, rotate
the Hermes pull key, preserve immutable storage, create new repositories with
new master keys, rebuild the gateway from trusted media, and resume only after
an isolated restore and integrity review.

### 17.5 NAS compromise

Operators MUST assume the local repository can be destroyed or corrupted but
not decrypted unless the gateway or maintenance workstation was also
compromised. They MUST preserve off-site recovery, revoke NAS transport
credentials, rebuild the storage service, and repopulate it from a verified
source or off-site repository.

## 18. Migration from the current implementation

Migration MUST avoid a gap in verified protection.

Recommended sequence:

1. Keep the current NAS-pull backup operational.
2. Provision and harden the independent gateway.
3. Provision a new append-only local repository service with no decryption key.
4. Provision the immutable off-site repository.
5. Install the root-owned source exporter and helper outside the user home.
6. Generate new gateway-to-Hermes and repository transport credentials.
7. Initialize independent local and off-site repositories with independent
   encryption keys.
8. Run a bounded pull and write the same spool to both targets.
9. Perform isolated restores from both new repositories.
10. If possible, virtualize Hermes and add the hypervisor-level backup path.
11. Observe at least two successful scheduled cycles and one missed-backup
    alert test.
12. Disable the old DSM backup, check, and prune tasks.
13. Revoke the old NAS-to-Hermes SSH key.
14. Remove the Restic password and Hermes private key from the NAS after the
    rollback window.
15. Make the old repository read-only and retain it according to the approved
    migration policy.
16. Remove the NAS Git checkout, Compose deployment, obsolete containers, and
    obsolete secret files only after recovery requirements are satisfied.

The old repository MUST NOT be reinitialized or destructively migrated. New
repositories are preferred because the old master key and historical exposure
cannot be withdrawn by a password change.

## 19. Verification and acceptance criteria

The target architecture is accepted only when all applicable checks pass.

### 19.1 Trust boundaries

- [ ] Hermes contains no repository password or transport credential.
- [ ] Hermes cannot route to the gateway, NAS repository endpoint, off-site
      endpoint, hypervisor management, or backup server.
- [ ] The NAS contains no repository decryption password or Hermes private key.
- [ ] The gateway is a separate operating-system trust domain from Hermes and
      the NAS.
- [ ] The normal gateway identity cannot delete or prune local snapshots.
- [ ] Maintenance credentials are absent from the routine gateway service.

### 19.2 Source behavior

- [ ] SSH accepts only the gateway key from the gateway address.
- [ ] Shell, PTY, forwarding, user RC, and arbitrary commands are rejected.
- [ ] Exporter and helpers are root-owned and outside user-writable paths.
- [ ] Exporter diagnostics never contaminate stdout.
- [ ] Exporter or SSH failure creates no snapshot.
- [ ] MemPalace backup uses its writer lock and verifies SQLite integrity.

### 19.3 Hostile-output handling

- [ ] The gateway never extracts or parses source TAR content during backup.
- [ ] Empty source output fails.
- [ ] Nonzero exporter exit fails.
- [ ] Timeout fails without creating a successful snapshot.
- [ ] Oversized output fails rather than being silently truncated.
- [ ] Spool permissions and encryption meet this specification.
- [ ] Both repositories receive the same gateway-computed TAR digest.
- [ ] A deliberately malformed TAR is stored safely and rejected or contained
      by the isolated restore procedure.

### 19.4 Storage

- [ ] Local repository authentication is enabled and TLS is verified.
- [ ] The normal local endpoint rejects overwrite and delete operations.
- [ ] The repository is not exposed by general NAS file services.
- [ ] Local immutable snapshots meet the approved protection window.
- [ ] The off-site copy is in an independent failure domain.
- [ ] Off-site immutability survives compromise of the routine client
      credential, according to a tested or contractually verified procedure.
- [ ] Repository quota exhaustion generates an alert before backup failure.

### 19.5 Operations and recovery

- [ ] A failed local write still attempts the off-site write.
- [ ] A failed off-site write reports partial success as failure requiring
      action.
- [ ] Missing-backup monitoring does not depend on a Hermes signal.
- [ ] Retention uses approved `--keep-within*` rules from the maintenance
      workstation.
- [ ] Destructive maintenance requires a reviewed dry run.
- [ ] Application restore succeeds from each repository in isolation.
- [ ] A restored VM boots in isolation when the hypervisor profile is present.
- [ ] Offline recovery copies of both repository secrets have been tested.
- [ ] Incident runbooks cover Hermes, gateway, NAS, and maintenance-workstation
      compromise separately.

## 20. Required implementation deliverables

Implementation is incomplete until the repository contains:

1. A root-owned Hermes exporter installation package or script.
2. A versioned exporter stream contract.
3. A gateway service and timer definition.
4. A bounded spool receiver with tests for timeout, truncation, and oversize.
5. Gateway manifest schema and validation tooling.
6. Local and off-site Restic backup configuration with independent secrets.
7. A pinned and hardened Synology rest-server deployment.
8. Network firewall and routing instructions for every component.
9. External monitoring configuration and alert tests.
10. Maintenance, retention, pruning, and endpoint-opening procedures.
11. Safe application and VM restore procedures.
12. Credential rotation and incident-response runbooks.
13. Migration and rollback instructions from the current Compose deployment.
14. Automated tests covering the acceptance criteria that can be tested in CI.

## 21. Open deployment decisions

The following must be resolved before implementation is production-ready:

- whether Hermes will be virtualized and on which hypervisor;
- whether Proxmox Backup Server or a commercial image-backup product will be
  used;
- gateway hardware or hypervisor placement;
- gateway operating system and update mechanism;
- expected and maximum export size;
- maximum export runtime and bandwidth;
- encrypted disk versus tmpfs spool sizing;
- source backup account and exact data-read permissions;
- local NAS model, DSM version, Btrfs, and immutable snapshot support;
- local repository quota;
- off-site provider and contractual immutability behavior;
- repository retention periods and capacity model;
- monitoring destination and on-call owner;
- final application and image RPO/RTO objectives; and
- acceptable maintenance, migration, and rollback windows.

These choices may strengthen the design but MUST NOT change the prohibition on
placing repository credentials, deletion authority, or backup control on
Hermes.

## 22. Primary references

- [Restic append-only security and retention](https://restic.readthedocs.io/en/stable/060_forget.html#security-considerations-in-append-only-mode)
- [Restic REST server](https://github.com/restic/rest-server)
- [Restic repository and password handling](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html)
- [OpenSSH authorized-key restrictions](https://man.openbsd.org/sshd.8)
- [Proxmox Backup Server features](https://www.proxmox.com/en/products/proxmox-backup-server/features)
- [Proxmox Backup Server permissions](https://pbs.proxmox.com/docs/user-management.html)
- [Synology immutable snapshots](https://kb.synology.com/en-us/DSM/help/SnapshotReplication/snapshots?version=7)
- [Borg append-only mode](https://borgbackup.readthedocs.io/en/stable/usage/notes.html#append-only-mode-forbid-compaction)
- [BorgBase documentation](https://docs.borgbase.com/)
- [rsync.net immutable snapshots](https://www.rsync.net/products/ransomware.html)

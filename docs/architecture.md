# Architecture

This project is a portable, single-host recovery design for n8n. Its boundaries are intentionally narrow: Docker Compose runs three services, Bash implements four operator workflows, and relative directories hold application state.

## Runtime request and monitoring paths

```text
                         public request
                               |
                               v
                       Nginx :80/:443
                               |
                         backend network
                               |
                               v
                           n8n :5678
                               ^
                               |
                     internal readiness check
                               |
Uptime Kuma :3001 <------------+
   ^
   |
127.0.0.1 only
```

Compose assigns project-scoped container and network names. Nothing depends on a container IP or a globally fixed name. Nginx reaches `n8n:5678` through Docker DNS and uses Docker's embedded resolver so a recreated n8n container can receive a different address. n8n uses `N8N_WEBHOOK_URL`, `N8N_EDITOR_BASE_URL`, and one trusted proxy hop; port 5678 is exposed only to the Compose network.

Nginx is the only public application entry point. The official image's template entrypoint renders `nginx/conf.d/n8n.conf.template`. TLS mode redirects port 80 to 443. Skip-TLS mode activates an HTTP-only server block. Upgrade and `X-Forwarded-*` headers are preserved.

Kuma's UI publishes as `127.0.0.1:${KUMA_PORT}:3001`. Operators normally use SSH forwarding. The Docker socket is not mounted.

## State ownership

```text
./n8n/data  -> /home/node/.n8n
./n8n/files -> /files
./kuma/data -> /app/data
./backups   -> host-only verified and safety archives
```

These relative bind mounts are the unit of portability. A checkout can be copied to another path or machine without editing hard-coded application-state paths. The only normal absolute host mount is external certificate material such as `/etc/letsencrypt`.

Bootstrap pulls the selected images and derives numeric owners from their expected data paths rather than hard-coding a node UID/GID. Privilege escalation is limited to `chown` when the current user cannot perform it.

Both n8n and Kuma use SQLite in this design. Their data directories require local filesystems with reliable POSIX locking. NFS-like storage is not assumed safe.

## INIT

`install.sh` is the human interface. Its modules gather and validate only applicable settings:

```text
installer/core.sh   hostname, timezone, images, retention, .env
installer/tls.sh    provider choice, helper delegation, certificate checks
installer/rsync.sh  SSH target and non-destructive connectivity test
installer/ceph.sh   S3 target, protected credentials, bucket test
installer/cron.sh   explicit schedules and flock-protected cron installation
```

The installer checks prerequisites but never installs packages. It gathers choices, displays a complete plan, and requires the literal `INSTALL` before changing state. Provider modules run only when selected. Cron has an additional installation confirmation.

`bootstrap.sh` is non-interactive. It validates `.env`, Docker and Compose, renders the Compose model, checks TLS files when enabled, creates relative directories, pulls images, derives ownership, starts services, waits for `/healthz/readiness`, tests the rendered Nginx configuration, and prints status.

Certificate API behavior is not implemented here. ArvanCloud and Cloudflare choices clone the designated helper repository into a temporary directory and preserve its interactive secret prompt. Existing-certificate mode consumes a caller-selected Certbot root. Nginx mounts certificate material read-only.

## BACKUP

Backup is a small state machine:

```text
inspect running services
          |
          v
stop only running SQLite writers
          |
          v
tar n8n/data + n8n/files + kuma/data into .partial
          |
          v
restore prior running state (also attempted by traps)
          |
          v
verify tar paths and extract temporary copy
          |
          v
n8n integrity + workflow/credential reads
Kuma integrity when kuma.db exists
          |
          v
manifest + SHA256SUMS -> immediate checksum verification
          |
          v
create VERIFIED -> atomic rename to timestamped directory
```

`VERIFIED` is a commit marker. Its absence means the directory is not a valid restore or upload source. Retention examines only completed timestamped directories and never removes the current backup, failed partial directories, or pre-restore safety copies.

Stopping writers makes the archive consistent without coupling the project to online SQLite backup details or Kuma's private schema. The tradeoff is short downtime. The n8n table names are checked because workflow and credential readability are explicit recovery requirements; Kuma validation deliberately uses only SQLite integrity and no private table names.

The manifest records source host/time, configured n8n and Kuma images, locally available image IDs/digests, integrity results, and workflow/credential counts. The default moving tags (`n8n:latest` and `uptime-kuma:2`) make the resolved image ID/digest especially important; a digest may still be unavailable when Docker has no repository digest for the selected image.

## Off-site boundary

Local backups share the production disk's failure domain. Two optional uploaders move only verified backup sets:

- rsync transfers into a unique remote partial directory, validates hashes on the remote host, and renames the directory atomically. It does not merge with an existing target, use `--delete`, or enforce remote retention.
- Ceph/S3 uses a pinned official AWS CLI container and a read-only mounted AWS-compatible credentials file. Archive, manifest, and hashes upload first; `VERIFIED` uploads last. It never deletes objects or buckets.

Remote lifecycle, immutability, encryption, replication, capacity, and credential rotation belong to the remote system. Operators must monitor and test that boundary.

## RECOVER

Both restore modes accept only a verified backup, allowlist checksum paths, reject unsafe or unexpected tar members, extract into a temporary directory, verify SQLite, and compare counts and integrity results with the manifest. A plan and explicit confirmation precede target changes.

After confirmation, affected services stop and a checksummed `pre-restore-*` safety archive captures current n8n and Kuma state before files are replaced. The safety copy remains until an operator deliberately removes it.

### Production / DR

Production mode restores n8n and Kuma, derives target ownership from the configured images, starts both services, and waits for n8n readiness. A differing source and target image reference is visible in the plan because database migrations and downgrade compatibility require operator judgment.

### Clone / test

Clone mode verifies the exact presence of `workflow_entity.active` before making any database change. It fails on an unknown schema rather than guessing, sets active workflows to inactive in staging, verifies zero remain active, and only then restores n8n.

Kuma restore is opt-in for clones. Kuma remains stopped even when its state is copied because production monitors and notification integrations could generate alerts. The operator must review that state and start Kuma explicitly.

Workflow deactivation reduces accidental schedules and trigger activity, but it is not a complete isolation boundary. Test clones may still warrant separate credentials, DNS, firewall rules, and outbound network controls.

## Doctor / preflight

`doctor.sh` is read-only. It reports prerequisites, daemon reachability, environment completeness, Compose rendering, TLS files/expiry, persistent-directory existence and apparent writability, disk capacity, port listeners, service status, and latest verified-backup age. Warnings produce exit 1; failed readiness checks produce exit 2.

Permission tests use metadata (`-w`) and do not create probe files. Port and Docker checks inspect current state without starting or changing services.

## Failure domains and limits

The bundled Uptime Kuma instance runs on the same Docker host as n8n. It can distinguish an internal n8n/database readiness failure from many Nginx/TLS/public-path failures, but it shares the same host failure domain. Host power loss, host networking loss, Docker failure, disk failure, or complete machine loss can take out n8n and its monitor together. Real host-level availability monitoring must run outside this host.

The design is not high availability and does not provide zero-downtime backup. It does not manage the host firewall, operating system, Docker installation, DNS/CDN, external certificates, object-store policy, or remote retention. Recovery confidence comes from protected off-site copies and repeated restore drills, not from the existence of a tar file alone.

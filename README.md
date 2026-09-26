# n8n self-hosted stack

> Backups are promises. Restores are proof.

This repository is a small, single-host n8n stack with three operational jobs:

- **INIT** — configure and start a new host through an interactive installer and a non-interactive bootstrap engine.
- **BACKUP** — stop SQLite writers briefly, archive all persistent state, verify it, and mark it complete.
- **RECOVER** — restore production or build a safer test clone on another machine.

`doctor.sh` is a fourth, read-only preflight and diagnostic utility. The project intentionally uses Docker Compose, Bash, SQLite, tar, SHA256, rsync, and S3-compatible APIs. It is not a deployment framework.

## Quick start

```bash
git clone https://github.com/mOhmd-r/n8n-selfhosted-stack.git
cd n8n-selfhosted-stack
chmod +x install.sh
./install.sh
```

`install.sh` asks for the full n8n hostname, timezone, n8n image, local backup count, TLS mode, optional off-site target, and optional cron schedule. It shows the complete plan and requires `INSTALL` before writing anything. It never installs system packages.

The core prerequisites are Bash, Docker Engine with the Compose plugin, `tar`, `sha256sum`, `sqlite3`, and `realpath`. rsync mode also needs `rsync`, `ssh`, and `ssh-keygen`.

For automation, prepare `.env` and certificate material first, then run the non-interactive engine:

```bash
./bootstrap.sh
```

## Stack

```text
Internet
   |
   v
Nginx :80/:443  ---- Docker DNS ---->  n8n :5678
                                              ^
                                              |
localhost:${KUMA_PORT:-3001} -> Uptime Kuma --+
```

- Nginx is the only public application entry point. It terminates TLS, supplies forwarded headers and WebSocket upgrade headers, and re-resolves `n8n` through Docker's embedded DNS.
- n8n does not publish port 5678. Its readiness check is `http://n8n:5678/healthz/readiness` inside the Compose network.
- Uptime Kuma v2 binds its UI to loopback only and shares the internal network with n8n.
- No fixed container or network names are used. Compose namespaces resources, so separate checkouts can coexist when their host ports do not conflict.
- The Docker socket is intentionally **not** mounted into Kuma.

Application state uses only relative bind mounts:

```text
./n8n/data    n8n database, configuration, and encryption material
./n8n/files   files made available to workflows
./kuma/data   Uptime Kuma database and state
./backups     local backup sets
```

Do not put these directories on a filesystem without reliable POSIX locking. SQLite-backed data, especially Kuma's data directory, should remain on local storage.

## TLS boundary

Certificate issuance is deliberately outside this repository. The installer offers:

1. Existing certificate — asks for the Certbot root and name below `live/`.
2. Skip — starts Nginx in plain HTTP mode bound only to `127.0.0.1` for initial setup.

Provision certificates separately with a reviewed tool such as [ArvanCloud-Certbot](https://github.com/mOhmd-r/ArvanCloud-Certbot), [Cloudflare-Certbot](https://github.com/mOhmd-r/Cloudflare-Certbot), or your normal ACME process. This installer never clones or executes remote helper code. It validates that the certificate and key resolve inside the selected Certbot `live/` or `archive/` tree, are valid, and have matching public keys. With TLS enabled, bootstrap requires:

```text
${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}/fullchain.pem
${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}/privkey.pem
```

The Certbot root is mounted read-only in Nginx. Certificate renewal remains the operator's responsibility. Nginx must be reloaded after a successful renewal so it reads the new certificate. From the repository directory, use a reviewed Certbot deploy hook that runs:

```bash
docker compose exec -T nginx nginx -s reload
```

Do not expose the no-TLS mode through a public reverse proxy or port-forward. Enable TLS first, then set the generated public bind configuration through the installer.

## Backup

Run:

```bash
./backup.sh
```

The script detects whether n8n and Kuma are running, stops only those running services, archives all three persistent paths, and restores only the prior running state. Exit and signal traps attempt to recover service state after interruption. This causes a short, intentional outage in exchange for a simple consistent SQLite copy.

Every candidate backup is built under a hidden partial directory. Before it becomes usable, the script:

- verifies tar readability and expected paths;
- requires n8n `database.sqlite`;
- runs `PRAGMA integrity_check` against n8n and Kuma when `kuma.db` exists;
- reads and counts n8n workflow and credential tables;
- records timestamp, hostname, configured images, available image IDs/digests, integrity results, and counts in `manifest.txt`;
- generates and immediately checks `SHA256SUMS`.

Only then does it create `VERIFIED` and atomically rename the directory. Restore and upload scripts refuse directories without `VERIFIED`, `manifest.txt`, `SHA256SUMS`, and valid hashes. Local retention keeps only the newest `BACKUP_RETENTION_COUNT` verified timestamped backups (default: 3); failed partial backups and pre-restore safety copies are not deleted automatically.

Backups contain credentials, n8n encryption material, workflow data, and possibly sensitive files. Treat them as secrets.

## Off-site copies

Off-site setup is optional and only runs when selected in `install.sh`.

### rsync / SSH

The installer records non-secret connection settings in ignored `.env.rsync`, references an existing SSH key and `known_hosts` file without copying them, requires a pre-pinned host key with strict checking, tests SSH without changing remote state, and asks before creating a missing remote directory. Password and keyboard-interactive authentication, agent forwarding, and SSH forwarding are disabled. `.env`, `.env.rsync`, and `.env.ceph` are sourced as trusted shell configuration; never copy them from an untrusted source and keep them owner-only.

```bash
./push-backup-rsync.sh latest
./push-backup-rsync.sh backups/20260904T031500Z-1234
```

The uploader validates the local backup, transfers to a new remote `.partial-*` directory, verifies hashes remotely, then renames it to the final name. It never uses `--delete` and does not apply remote retention.

### Ceph RGW / S3-compatible storage

The installer requires an HTTPS endpoint, keeps endpoint/bucket settings in ignored `.env.ceph`, and writes credentials to `.secrets/aws/credentials` with directory mode 700 and file mode 600. Bucket access is tested; a missing bucket is created only after a separate confirmation.

```bash
./push-backup-ceph.sh latest
```

The uploader uses an explicit-version official AWS CLI container, mounts the credentials file read-only, and publishes `VERIFIED` last. A registry tag is not immutable; pin the configured image by digest when that guarantee is required. The uploader never deletes remote objects. SHA256 detects accidental corruption but does not authenticate a backup against an attacker who can rewrite the data and hashes. Enforce restricted credentials, encryption at rest, versioning or object lock, and independent retention in the object store.

## Recovery

Always configure the target checkout and make its images available before restoring. The restore process verifies the marker, checksum allowlist, tar paths, SQLite integrity, and manifest counts before showing its plan.

### Production / disaster recovery

```bash
./restore.sh --mode production backups/20260904T031500Z-1234
```

After explicit confirmation, the script copies verified content into same-filesystem staging directories, stops affected services, and creates a checksummed `backups/pre-restore-*` safety archive. It then swaps complete directory trees by rename, derives ownership, starts services, and waits for n8n readiness. A failure after the swap stops the restored services, rolls the previous trees back, and returns only previously running services to service. Safety archives are never removed automatically.

### Clone / test

```bash
./restore.sh --mode clone backups/20260904T031500Z-1234
./restore.sh --mode clone --with-kuma backups/20260904T031500Z-1234
```

Clone mode first verifies that `workflow_entity.active` exists. It refuses an unknown schema rather than guessing, then sets active workflows to inactive in the staged database and verifies the result. This reduces the risk of copied schedules and triggers running on the clone.

Kuma data is optional in clone mode and Kuma is never started automatically. A copied Kuma database may include production monitors and notification integrations capable of sending alerts. Review it before explicitly starting the service. Disabling n8n workflows is an important guardrail, not a complete network sandbox; use egress controls and test credentials when the clone's risk warrants them.

`--yes` is available for already-reviewed, explicitly selected non-interactive restores.

## Uptime Kuma setup and limits

Open the loopback-only UI through SSH:

```bash
ssh -L 3001:127.0.0.1:3001 user@server
```

Then browse to `http://127.0.0.1:3001` and create monitors manually. Do not edit `kuma.db` or depend on Kuma's private schema.

- **Internal readiness:** `http://n8n:5678/healthz/readiness`
- **Public path:** `https://automation.example.com/healthz/readiness` (use the configured hostname and scheme)

If internal readiness is down, investigate n8n or its database. If internal readiness is up while the public monitor is down, investigate Nginx, TLS, DNS/CDN, firewall, or the external network path.

The bundled Uptime Kuma instance runs on the same Docker host as n8n. It is useful for monitoring n8n service readiness and the HTTP path, but it shares the same host failure domain. If the host loses power, networking, Docker, or the entire machine fails, the bundled Kuma instance cannot alert you. For real host-level availability monitoring, run Uptime Kuma or another monitoring system outside this host.

Exposing the bundled Kuma UI publicly is a separate design decision and is intentionally not implemented here.

## Doctor and scheduling

`doctor.sh` changes nothing. It checks tools, daemon access, `.env`, required variables, Compose rendering, TLS files and expiry, port listeners, directory existence/writability, disk space, running services, and latest verified-backup age.

```bash
./doctor.sh
```

Exit codes are `0` for ready, `1` for ready with warnings, and `2` for failed checks.

Cron is never installed unless selected and confirmed. [cron/n8n-backup.example](cron/n8n-backup.example) is only a template; local backup is enabled in the example and both off-site jobs are commented. Generated jobs use `flock` so runs do not overlap.

## Scope and failure model

This is a recoverable single-node design, not high availability or zero downtime.

- SQLite backup requires briefly stopping its writers.
- Nginx, n8n, and bundled Kuma share one Docker host.
- Local backups share the host's disk failure domain; configure and test an off-site copy.
- TLS issuance and renewal are external responsibilities.
- The scripts verify structure, hashes, and SQLite consistency, but only a rehearsed restore proves the broader recovery procedure.
- Default application images use explicit major/minor/patch release tags, and bootstrap rejects moving names such as `latest`, `stable`, `nightly`, and `edge`. Tags can still be moved by a registry; use `@sha256:` digests when immutable image identity is required. Before changing an image, take and verify a backup, review release notes, test the upgrade and restore path, and commit the planned change.
- The stack does not configure host firewalls, Docker installation, OS patching, DNS, CDN behavior, email, object-store policies, or external monitoring.

See [docs/architecture.md](docs/architecture.md) for the design and trust boundaries.

## Repository layout

```text
.
├── install.sh                    interactive human interface
├── bootstrap.sh                  non-interactive deployment engine
├── doctor.sh                     read-only diagnostics
├── backup.sh                     verified local backup
├── restore.sh                    production and clone recovery
├── push-backup-rsync.sh          atomic SSH/rsync upload
├── push-backup-ceph.sh           S3-compatible upload
├── installer/                    small installer modules
├── cron/n8n-backup.example       inactive schedule template
├── examples/                     off-site config examples
├── n8n/{data,files}/             relative n8n state
├── kuma/data/                    relative Kuma state
├── nginx/conf.d/                 Nginx template
├── backups/                      local backup sets
└── docs/architecture.md
```

#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# shellcheck source=/dev/null
# shellcheck disable=SC1091
source installer/core.sh

for accepted in \
    n8nio/n8n:2.40.5 \
    nginx:1.28.0-alpine \
    "registry.example/app@sha256:$(printf 'a%.0s' {1..64})"; do
    validate_pinned_image "$accepted" || {
        printf 'Expected pinned image to pass: %s\n' "$accepted" >&2
        exit 1
    }
done

for rejected in n8nio/n8n:latest n8nio/n8n:2.0-latest louislam/uptime-kuma:2 nginx:stable untagged; do
    if validate_pinned_image "$rejected"; then
        printf 'Expected moving or untagged image to fail: %s\n' "$rejected" >&2
        exit 1
    fi
done

rg -q 'BACKUP_RETENTION_COUNT=3' .env.example
rg -q '\$\{NGINX_BIND_IP\}:80:80' docker-compose.yaml
if rg -q 'BACKUP_RETENTION_DAYS' backup.sh installer .env.example; then
    printf 'Legacy day-based local retention is still active.\n' >&2
    exit 1
fi

if rg -n 'git clone|curl.+\|.+(sh|bash)|wget.+\|.+(sh|bash)' install.sh installer bootstrap.sh; then
    printf 'Installer path must not fetch and execute remote helpers.\n' >&2
    exit 1
fi

rg -q 'StrictHostKeyChecking=yes' installer/rsync.sh push-backup-rsync.sh
rg -q 'UserKnownHostsFile=' installer/rsync.sh push-backup-rsync.sh
rg -q '\^https://' installer/ceph.sh push-backup-ceph.sh

printf 'Static policy tests passed.\n'

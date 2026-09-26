#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

for module in core tls rsync ceph cron; do
    # shellcheck source=/dev/null
    source "${PROJECT_DIR}/installer/${module}.sh"
done

[[ -t 0 ]] || fail "install.sh is interactive and requires a terminal. Use bootstrap.sh for non-interactive deployment."

missing=()
for command_name in docker tar sha256sum sqlite3 realpath; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
done
(( ${#missing[@]} == 0 )) || fail "Missing prerequisites: ${missing[*]}. Install them explicitly, then retry."
docker info >/dev/null 2>&1 || fail "Docker is installed but its daemon is not reachable by this user."
docker compose version >/dev/null 2>&1 || fail "The Docker Compose plugin is required."

core_prompt
tls_prompt

cat <<'EOF'

Off-site backup:
  1) None
  2) rsync / SSH
  3) Ceph / S3
EOF
while :; do
    read -r -p "Selection [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        1) OFFSITE_PROVIDER="none"; break ;;
        2) OFFSITE_PROVIDER="rsync"; for tool in rsync ssh ssh-keygen stat; do command -v "$tool" >/dev/null 2>&1 || fail "${tool} is required."; done; rsync_prompt; break ;;
        3) OFFSITE_PROVIDER="ceph"; ceph_prompt; break ;;
        *) warn "Choose 1, 2, or 3." ;;
    esac
done

cat <<'EOF'

Scheduler:
  1) None
  2) Cron
EOF
while :; do
    read -r -p "Selection [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
        1) SCHEDULER="none"; break ;;
        2) SCHEDULER="cron"; command -v flock >/dev/null 2>&1 || fail "flock is required for Cron."; cron_prompt; break ;;
        *) warn "Choose 1 or 2." ;;
    esac
done

echo
echo "Installation plan"
echo "  Project            : ${PROJECT_DIR}"
echo "  Public URL         : ${PUBLIC_SCHEME}://${N8N_HOST}/"
echo "  Timezone           : ${TIMEZONE}"
echo "  n8n image          : ${N8N_IMAGE}"
echo "  Kuma image         : ${KUMA_IMAGE}"
echo "  Kuma UI            : 127.0.0.1:${KUMA_PORT}"
echo "  Local backups      : keep newest ${BACKUP_RETENTION_COUNT}"
echo "  TLS provider       : ${TLS_PROVIDER}"
if [[ "$TLS_ENABLED" == "true" ]]; then
    echo "  Certificate        : ${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}"
fi
echo "  Off-site provider  : ${OFFSITE_PROVIDER}"
echo "  Scheduler          : ${SCHEDULER}"
if [[ "$OFFSITE_PROVIDER" == "rsync" ]]; then
    echo "  rsync destination  : ${RSYNC_USER}@${RSYNC_HOST}:${RSYNC_PATH} (SSH port ${RSYNC_PORT})"
    echo "  SSH key reference  : ${RSYNC_SSH_KEY}"
    echo "  Pinned host keys   : ${RSYNC_KNOWN_HOSTS_FILE}"
elif [[ "$OFFSITE_PROVIDER" == "ceph" ]]; then
    echo "  S3 destination     : s3://${CEPH_S3_BUCKET}/${CEPH_S3_PREFIX}/"
    echo "  S3 endpoint/region : ${CEPH_S3_ENDPOINT} / ${AWS_DEFAULT_REGION}"
fi
if [[ "$SCHEDULER" == "cron" ]]; then
    echo "  Local backup time  : ${LOCAL_BACKUP_TIME}"
    [[ -z "$OFFSITE_BACKUP_TIME" ]] || echo "  Off-site time      : ${OFFSITE_BACKUP_TIME}"
fi
if [[ -f .env ]]; then
    echo "  Existing .env      : will be replaced"
fi
echo
read -r -p "Type INSTALL to apply this plan: " approval
[[ "$approval" == "INSTALL" ]] || { log "Installation cancelled; nothing was changed."; exit 0; }

core_write_env
tls_configure
case "$OFFSITE_PROVIDER" in
    rsync) rsync_configure ;;
    ceph) ceph_configure ;;
esac

"${PROJECT_DIR}/bootstrap.sh"

if [[ "$SCHEDULER" == "cron" ]]; then
    cron_install
fi

ok "Installation finished. Run ./doctor.sh for a read-only diagnostic report."

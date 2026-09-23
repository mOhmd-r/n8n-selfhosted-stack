#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yaml"
cd "$PROJECT_DIR"

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

validate_pinned_image() {
    local image="$1" tag

    [[ "$image" =~ ^[A-Za-z0-9._/:@-]+$ ]] || return 1
    [[ "$image" =~ @sha256:[A-Fa-f0-9]{64}$ ]] && return 0
    tag="${image##*:}"
    [[ "$tag" != "$image" && "$tag" != *"/"* ]] || return 1
    [[ "$tag" =~ [0-9]+\.[0-9]+ && "$tag" != "latest" ]]
}

[[ -f .env ]] || fail ".env is missing. Run ./install.sh, or copy .env.example to .env and review it."
# shellcheck source=/dev/null
set -a; source .env; set +a

required=(N8N_HOST TIMEZONE N8N_IMAGE KUMA_IMAGE NGINX_IMAGE KUMA_PORT TLS_ENABLED LETSENCRYPT_PATH TLS_CERT_NAME TLS_VOLUME_SOURCE PUBLIC_SCHEME NGINX_TLS_PREFIX NGINX_HTTP_PREFIX BACKUP_RETENTION_DAYS)
for variable in "${required[@]}"; do
    [[ -n "${!variable+x}" ]] || fail "Required .env variable is missing: ${variable}"
done
[[ "$TLS_ENABLED" == "true" || "$TLS_ENABLED" == "false" ]] || fail "TLS_ENABLED must be true or false."
[[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || fail "BACKUP_RETENTION_DAYS must be a non-negative integer."
[[ "$KUMA_PORT" =~ ^[0-9]+$ ]] && (( KUMA_PORT >= 1 && KUMA_PORT <= 65535 )) || fail "KUMA_PORT is invalid."
for image_variable in N8N_IMAGE KUMA_IMAGE NGINX_IMAGE; do
    validate_pinned_image "${!image_variable}" ||
        fail "${image_variable} must use an explicit version tag or sha256 digest; moving tags are rejected."
done
if [[ "$TLS_ENABLED" == "true" ]]; then
    [[ "$PUBLIC_SCHEME" == "https" && -z "$NGINX_TLS_PREFIX" && "$NGINX_HTTP_PREFIX" == "#" ]] \
        || fail "TLS-related .env selectors are inconsistent. Re-run install.sh or compare .env.example."
else
    [[ "$PUBLIC_SCHEME" == "http" && "$NGINX_TLS_PREFIX" == "#" && -z "$NGINX_HTTP_PREFIX" ]] \
        || fail "HTTP-related .env selectors are inconsistent. Re-run install.sh or compare .env.example."
fi

command -v docker >/dev/null 2>&1 || fail "Docker is not installed. Install it explicitly, then retry."
command -v realpath >/dev/null 2>&1 || fail "realpath is required. Install it explicitly, then retry."
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable by this user."
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is not available."
ok "Docker Engine and Compose are available."

log "Validating Compose configuration."
docker compose -f "$COMPOSE_FILE" config --quiet
ok "Compose configuration is valid."

if [[ "$TLS_ENABLED" == "true" ]]; then
    CERT_DIR="${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}"
    can_read_file() {
        local path="$1" resolved root
        if [[ -r "$path" ]]; then
            resolved="$(realpath -e "$path")" || return 1
            root="$(realpath -e "$LETSENCRYPT_PATH")" || return 1
        elif command -v sudo >/dev/null 2>&1; then
            resolved="$(sudo -n realpath -e "$path")" || return 1
            root="$(sudo -n realpath -e "$LETSENCRYPT_PATH")" || return 1
        else
            return 1
        fi
        case "$resolved" in
            "${root}/live/${TLS_CERT_NAME}/"*|"${root}/archive/${TLS_CERT_NAME}/"*) ;;
            *) return 1 ;;
        esac
        [[ -f "$path" && -r "$path" ]] && return 0
        command -v sudo >/dev/null 2>&1 && sudo -n test -f "$path" && sudo -n test -r "$path"
    }
    can_read_file "${CERT_DIR}/fullchain.pem" || fail "TLS certificate is unreadable or resolves outside the selected Certbot tree: ${CERT_DIR}/fullchain.pem"
    can_read_file "${CERT_DIR}/privkey.pem" || fail "TLS private key is unreadable or resolves outside the selected Certbot tree: ${CERT_DIR}/privkey.pem"
    ok "TLS certificate files are readable."
else
    log "TLS is disabled; Nginx will serve plain HTTP."
fi

log "Creating relative persistent directories."
mkdir -p n8n/data n8n/files kuma/data backups

log "Pulling configured images."
docker compose -f "$COMPOSE_FILE" pull

image_owner() {
    local image="$1" path="$2" fallback_user="${3:-}"
    docker run --rm --entrypoint sh "$image" -c \
        "if [ -e '$path' ]; then stat -c '%u:%g' '$path'; elif [ -n '$fallback_user' ]; then printf '%s:%s\\n' \"\$(id -u '$fallback_user')\" \"\$(id -g '$fallback_user')\"; else id -u | tr '\\n' ':'; id -g; fi" \
        | tail -n 1
}

set_owner() {
    local owner="$1"; shift
    [[ "$owner" =~ ^[0-9]+:[0-9]+$ ]] || fail "Could not derive container ownership."
    if [[ $(id -u) -eq 0 ]]; then
        chown -R "$owner" "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n chown -R "$owner" "$@" \
            || fail "Non-interactive chown needs cached sudo credentials. Run 'sudo -v' first, or run this operation as root."
    else
        fail "Setting runtime directory ownership requires root or sudo."
    fi
}

log "Deriving runtime ownership from the selected images."
N8N_OWNER="$(image_owner "$N8N_IMAGE" /home/node/.n8n node)"
KUMA_OWNER="$(image_owner "$KUMA_IMAGE" /app/data)"
set_owner "$N8N_OWNER" n8n/data n8n/files
set_owner "$KUMA_OWNER" kuma/data
ok "Runtime ownership set from image metadata (n8n ${N8N_OWNER}; Kuma ${KUMA_OWNER})."

log "Starting the stack."
docker compose -f "$COMPOSE_FILE" up -d

log "Waiting for n8n readiness."
ready=false
for _ in $(seq 1 90); do
    n8n_id="$(docker compose -f "$COMPOSE_FILE" ps -q n8n)"
    if [[ -n "$n8n_id" ]]; then
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$n8n_id" 2>/dev/null || true)"
        if [[ "$health" == "healthy" ]]; then
            ready=true
            break
        fi
        [[ "$health" != "unhealthy" ]] || fail "n8n became unhealthy. Inspect: docker compose logs n8n"
    fi
    sleep 2
done
[[ "$ready" == "true" ]] || fail "n8n did not become ready within 180 seconds."
ok "n8n readiness endpoint is healthy."

log "Validating the rendered Nginx configuration."
docker compose -f "$COMPOSE_FILE" exec -T nginx nginx -t
ok "Nginx configuration is valid."

echo
docker compose -f "$COMPOSE_FILE" ps
echo
echo "STACK READY"
echo "n8n: ${PUBLIC_SCHEME}://${N8N_HOST}/"
echo "Kuma: http://127.0.0.1:${KUMA_PORT}/ (loopback only)"

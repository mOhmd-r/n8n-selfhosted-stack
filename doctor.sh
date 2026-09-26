#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yaml"
cd "$PROJECT_DIR"

failures=0
warnings=0

line() { printf '%-30s %s\n' "$1" "$2"; }
pass() { line "$1" "OK${2:+ - $2}"; }
warn() { line "$1" "WARN${2:+ - $2}"; warnings=$((warnings + 1)); }
fail() { line "$1" "FAIL${2:+ - $2}"; failures=$((failures + 1)); }

validate_pinned_image() {
    local image="$1" tag

    [[ "$image" =~ ^[A-Za-z0-9._/:@-]+$ ]] || return 1
    [[ "$image" =~ @sha256:[A-Fa-f0-9]{64}$ ]] && return 0
    tag="${image##*:}"
    [[ "$tag" != "$image" && "$tag" != *"/"* ]] || return 1
    [[ "$tag" =~ [0-9]+\.[0-9]+ && "$tag" != "latest" ]]
}

if command -v docker >/dev/null 2>&1; then
    pass "Docker Engine"
else
    fail "Docker Engine" "command not found"
fi

daemon_ok=false
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    daemon_ok=true
    pass "Docker daemon"
else
    fail "Docker daemon" "not reachable"
fi

compose_ok=false
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    compose_ok=true
    pass "Docker Compose"
else
    fail "Docker Compose" "plugin unavailable"
fi

env_ok=false
if [[ -f .env ]]; then
    # shellcheck source=/dev/null
    if set -a && source .env && set +a; then
        env_ok=true
        pass ".env"
        env_mode="$(stat -c %a .env 2>/dev/null || printf 'unknown')"
        if [[ "$env_mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$env_mode & 077) == 0 )); then
            pass ".env permissions" "$env_mode"
        else
            fail ".env permissions" "expected no group/other access; got ${env_mode}"
        fi
    else
        set +a
        fail ".env" "could not be parsed"
    fi
else
    fail ".env" "missing"
fi

if [[ "$env_ok" == "true" ]]; then
    missing=()
    for variable in N8N_HOST TIMEZONE N8N_IMAGE KUMA_IMAGE NGINX_IMAGE KUMA_PORT TLS_ENABLED LETSENCRYPT_PATH TLS_CERT_NAME TLS_VOLUME_SOURCE PUBLIC_SCHEME NGINX_TLS_PREFIX NGINX_HTTP_PREFIX NGINX_BIND_IP BACKUP_RETENTION_COUNT; do
        [[ -n "${!variable+x}" ]] || missing+=("$variable")
    done
    if (( ${#missing[@]} == 0 )); then
        pass "Required variables"
    else
        fail "Required variables" "missing: ${missing[*]}"
    fi

    for image_variable in N8N_IMAGE KUMA_IMAGE NGINX_IMAGE; do
        if [[ -n "${!image_variable:-}" ]] && validate_pinned_image "${!image_variable}"; then
            pass "$image_variable" "${!image_variable}"
        else
            fail "$image_variable" "use an explicit version tag or sha256 digest"
        fi
    done
fi

if [[ "$compose_ok" == "true" && "$env_ok" == "true" ]]; then
    if docker compose -f "$COMPOSE_FILE" config --quiet >/dev/null 2>&1; then
        pass "Compose configuration"
    else
        fail "Compose configuration" "docker compose config failed"
    fi
else
    fail "Compose configuration" "prerequisites unavailable"
fi

if [[ "$env_ok" == "true" ]]; then
    if [[ "${TLS_ENABLED:-}" == "true" ]]; then
        cert_dir="${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}"
        if [[ -r "${cert_dir}/fullchain.pem" && -r "${cert_dir}/privkey.pem" ]]; then
            pass "TLS certificate"
            if command -v openssl >/dev/null 2>&1; then
                if openssl x509 -checkend 0 -noout -in "${cert_dir}/fullchain.pem" >/dev/null 2>&1; then
                    expiry="$(openssl x509 -enddate -noout -in "${cert_dir}/fullchain.pem" 2>/dev/null | cut -d= -f2-)"
                    if openssl x509 -checkend 2592000 -noout -in "${cert_dir}/fullchain.pem" >/dev/null 2>&1; then
                        pass "TLS expiry" "$expiry"
                    else
                        warn "TLS expiry" "within 30 days: $expiry"
                    fi
                else
                    fail "TLS expiry" "certificate is expired or unreadable"
                fi
            else
                warn "TLS expiry" "openssl unavailable"
            fi
        else
            fail "TLS certificate" "fullchain.pem or privkey.pem missing/unreadable"
        fi
    elif [[ "${TLS_ENABLED:-}" == "false" ]]; then
        warn "TLS certificate" "TLS is disabled"
    else
        fail "TLS certificate" "TLS_ENABLED is invalid"
    fi
fi

for entry in "n8n data:n8n/data" "n8n files:n8n/files" "Kuma data:kuma/data" "Backup directory:backups"; do
    label="${entry%%:*}"
    path="${entry#*:}"
    if [[ ! -d "$path" ]]; then
        fail "$label" "directory missing"
    elif [[ -w "$path" ]]; then
        pass "$label" "exists and is writable"
    else
        fail "$label" "not writable by current user"
    fi
done

disk_kb="$(df -Pk "$PROJECT_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ "$disk_kb" =~ ^[0-9]+$ ]]; then
    disk_gb=$((disk_kb / 1024 / 1024))
    if (( disk_kb < 1048576 )); then
        warn "Disk free" "${disk_gb} GB"
    else
        pass "Disk free" "${disk_gb} GB"
    fi
else
    warn "Disk free" "could not determine"
fi

latest=""
if [[ -d backups ]]; then
    while IFS= read -r candidate; do
        [[ -f "${candidate}/VERIFIED" ]] && latest="$candidate"
    done < <(find backups -mindepth 1 -maxdepth 1 -type d -name '20*T*Z*' -print 2>/dev/null | sort)
fi
if [[ -n "$latest" ]]; then
    modified="$(stat -c %Y "$latest" 2>/dev/null || printf '0')"
    now="$(date +%s)"
    age_hours=$(((now - modified) / 3600))
    pass "Latest verified backup" "${age_hours}h ago ($(basename "$latest"))"
else
    warn "Latest verified backup" "none found"
fi

nginx_running=false
if [[ "$daemon_ok" == "true" && "$compose_ok" == "true" && "$env_ok" == "true" ]]; then
    running_services="$(docker compose -f "$COMPOSE_FILE" ps --services --status running 2>/dev/null || true)"
    if [[ -n "$running_services" ]]; then
        if grep -qx nginx <<< "$running_services"; then
            nginx_running=true
        fi
        pass "Stack status" "running: $(tr '\n' ' ' <<< "$running_services")"
    else
        warn "Stack status" "no services running"
    fi
else
    warn "Stack status" "not inspected"
fi

if command -v ss >/dev/null 2>&1; then
    listeners="$(ss -H -ltn 2>/dev/null | awk '$4 ~ /(^|:)(80|443)$/ {print $4}' | sort -u | tr '\n' ' ')"
    if [[ -z "$listeners" ]]; then
        pass "Ports 80/443" "available"
    elif [[ "$nginx_running" == "true" ]]; then
        pass "Ports 80/443" "listeners present while stack is running"
    else
        warn "Ports 80/443" "listeners present: ${listeners}"
    fi
else
    warn "Ports 80/443" "ss unavailable"
fi

echo
if (( failures > 0 )); then
    echo "RESULT: NOT READY (${failures} failure(s), ${warnings} warning(s))"
    exit 2
elif (( warnings > 0 )); then
    echo "RESULT: READY WITH WARNINGS (${warnings})"
    exit 1
else
    echo "RESULT: READY"
    exit 0
fi

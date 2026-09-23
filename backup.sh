#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yaml"
BACKUP_ROOT="${PROJECT_DIR}/backups"
cd "$PROJECT_DIR"

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

[[ -f .env ]] || fail ".env is missing."
# shellcheck source=/dev/null
set -a
# shellcheck disable=SC1091
source .env
set +a
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"
[[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] || fail "BACKUP_RETENTION_DAYS must be a non-negative integer."
[[ -n "${N8N_IMAGE:-}" && -n "${KUMA_IMAGE:-}" ]] || fail ".env lacks N8N_IMAGE or KUMA_IMAGE."

for command_name in docker tar sha256sum sqlite3; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: ${command_name}"
done
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable."
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is unavailable."
[[ -f "$COMPOSE_FILE" ]] || fail "docker-compose.yaml is missing."
for directory in n8n/data n8n/files kuma/data backups; do
    [[ -d "$directory" ]] || fail "Persistent directory is missing: ${directory}"
done

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_name="${timestamp}-$$"
partial_dir="${BACKUP_ROOT}/.${backup_name}.partial"
final_dir="${BACKUP_ROOT}/${backup_name}"
archive="${partial_dir}/stack-data.tar.gz"
verify_dir=""
backup_complete=false
stopped_services=()

mkdir -m 700 "$partial_dir"

service_is_running() {
    local service="$1" container_id
    container_id="$(docker compose -f "$COMPOSE_FILE" ps -q "$service" 2>/dev/null || true)"
    [[ -n "$container_id" ]] \
        && [[ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" == "true" ]]
}

restart_stopped_services() {
    if (( ${#stopped_services[@]} > 0 )); then
        log "Restarting services stopped for the backup: ${stopped_services[*]}"
        if docker compose -f "$COMPOSE_FILE" start "${stopped_services[@]}"; then
            stopped_services=()
        else
            printf '[ERROR] Could not restart every service stopped for backup. Manual action is required.\n' >&2
            return 1
        fi
    fi
}

cleanup() {
    local status=$?
    if [[ -n "$verify_dir" && -d "$verify_dir" ]]; then
        rm -rf -- "$verify_dir"
    fi
    restart_stopped_services || status=1
    if [[ "$backup_complete" != "true" && -d "$partial_dir" ]]; then
        printf '[WARN] Incomplete backup retained for inspection (no VERIFIED marker): %s\n' "$partial_dir" >&2
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for service in n8n uptime-kuma; do
    if service_is_running "$service"; then
        stopped_services+=("$service")
    fi
done

if (( ${#stopped_services[@]} > 0 )); then
    log "Stopping only services that are currently running: ${stopped_services[*]}"
    docker compose -f "$COMPOSE_FILE" stop "${stopped_services[@]}"
fi

log "Archiving n8n and Uptime Kuma persistent state."
tar -czf "$archive" -C "$PROJECT_DIR" n8n/data n8n/files kuma/data

# Restore availability before performing checks against the immutable archive.
restart_stopped_services

log "Checking archive structure and readability."
archive_list="${partial_dir}/archive.list"
tar -tzf "$archive" > "$archive_list"
while IFS= read -r entry; do
    [[ "$entry" != /* ]] || fail "Archive contains an absolute path: ${entry}"
    case "/${entry}/" in
        */../*) fail "Archive contains a parent-directory path: ${entry}" ;;
    esac
done < "$archive_list"
grep -Eq '^n8n/data(/|$)' "$archive_list" || fail "Archive is missing n8n/data."
grep -Eq '^n8n/files(/|$)' "$archive_list" || fail "Archive is missing n8n/files."
grep -Eq '^kuma/data(/|$)' "$archive_list" || fail "Archive is missing kuma/data."
rm -f -- "$archive_list"

verify_dir="$(mktemp -d)"
tar -xzf "$archive" -C "$verify_dir"
n8n_db="${verify_dir}/n8n/data/database.sqlite"
kuma_db="${verify_dir}/kuma/data/kuma.db"
[[ -f "$n8n_db" ]] || fail "n8n database.sqlite is not present in the backup."

log "Running n8n SQLite integrity and table-read checks."
n8n_integrity="$(sqlite3 -readonly "$n8n_db" 'PRAGMA integrity_check;')"
[[ "$n8n_integrity" == "ok" ]] || fail "n8n SQLite integrity check failed: ${n8n_integrity}"
workflow_count="$(sqlite3 -readonly "$n8n_db" 'SELECT COUNT(*) FROM workflow_entity;')" \
    || fail "n8n workflow_entity table is not readable."
credential_count="$(sqlite3 -readonly "$n8n_db" 'SELECT COUNT(*) FROM credentials_entity;')" \
    || fail "n8n credentials_entity table is not readable."
[[ "$workflow_count" =~ ^[0-9]+$ && "$credential_count" =~ ^[0-9]+$ ]] \
    || fail "n8n table counts are not numeric."

if [[ -f "$kuma_db" ]]; then
    log "Running Uptime Kuma SQLite integrity check."
    kuma_integrity="$(sqlite3 -readonly "$kuma_db" 'PRAGMA integrity_check;')"
    [[ "$kuma_integrity" == "ok" ]] || fail "Kuma SQLite integrity check failed: ${kuma_integrity}"
else
    kuma_integrity="not_present"
fi

image_id() {
    docker image inspect --format '{{.Id}}' "$1" 2>/dev/null || printf 'unavailable'
}
image_digest() {
    docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}unavailable{{end}}' "$1" 2>/dev/null || printf 'unavailable'
}

cat > "${partial_dir}/manifest.txt" <<EOF
format_version=1
timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
hostname=$(hostname)
n8n_image=${N8N_IMAGE:-unknown}
n8n_image_id=$(image_id "${N8N_IMAGE:-}")
n8n_image_digest=$(image_digest "${N8N_IMAGE:-}")
kuma_image=${KUMA_IMAGE:-unknown}
kuma_image_id=$(image_id "${KUMA_IMAGE:-}")
kuma_image_digest=$(image_digest "${KUMA_IMAGE:-}")
n8n_sqlite_integrity=${n8n_integrity}
kuma_sqlite_integrity=${kuma_integrity}
workflow_count=${workflow_count}
credential_count=${credential_count}
EOF

log "Generating and immediately verifying SHA256 checksums."
(
    cd "$partial_dir"
    sha256sum stack-data.tar.gz manifest.txt > SHA256SUMS
    sha256sum --strict -c SHA256SUMS
)

# A backup becomes eligible for restore/upload only at this point.
touch "${partial_dir}/VERIFIED"
mv "$partial_dir" "$final_dir"
backup_complete=true
ok "Verified backup created: ${final_dir}"

log "Applying retention only to old, completed backup directories."
while IFS= read -r candidate; do
    [[ "$candidate" != "$final_dir" && -f "${candidate}/VERIFIED" ]] || continue
    case "$candidate" in
        "${BACKUP_ROOT}"/20*T*Z-*)
            log "Removing expired verified backup: $(basename "$candidate")"
            rm -rf -- "$candidate"
            ;;
    esac
done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z-*' -mtime "+${BACKUP_RETENTION_DAYS}" -print)

printf 'BACKUP_PATH=%s\n' "$final_dir"

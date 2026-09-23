#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yaml"
cd "$PROJECT_DIR"

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  ./restore.sh --mode production BACKUP_DIRECTORY
  ./restore.sh --mode clone [--with-kuma] BACKUP_DIRECTORY

Options:
  --mode production  Disaster-recovery restore; starts n8n and Kuma.
  --mode clone       Disables active workflows; leaves Kuma stopped.
  --with-kuma        Restore Kuma data in clone mode, but do not start it.
  --yes              Accept the displayed plan non-interactively.
EOF
}

mode=""
backup_arg=""
assume_yes=false
with_kuma=false
with_kuma_set=false
while (( $# > 0 )); do
    case "$1" in
        --mode)
            (( $# >= 2 )) || fail "--mode requires production or clone."
            mode="$2"
            shift 2
            ;;
        --with-kuma) with_kuma=true; with_kuma_set=true; shift ;;
        --yes) assume_yes=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) fail "Unknown option: $1" ;;
        *)
            [[ -z "$backup_arg" ]] || fail "Only one backup directory may be supplied."
            backup_arg="$1"
            shift
            ;;
    esac
done

if [[ -z "$mode" ]]; then
    [[ -t 0 ]] || fail "Select --mode production or --mode clone."
    echo "Restore mode:"
    echo "  1) production / DR"
    echo "  2) clone / test"
    read -r -p "Selection: " selection
    case "$selection" in
        1) mode="production" ;;
        2) mode="clone" ;;
        *) fail "Invalid restore mode." ;;
    esac
fi
[[ "$mode" == "production" || "$mode" == "clone" ]] || fail "Mode must be production or clone."

if [[ -z "$backup_arg" ]]; then
    [[ -t 0 ]] || fail "A backup directory is required."
    read -r -p "Backup directory: " backup_arg
fi

if [[ "$mode" == "production" ]]; then
    with_kuma=true
elif [[ "$with_kuma_set" == "false" && -t 0 ]]; then
    read -r -p "Restore Kuma data? Its production integrations will remain stopped [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] && with_kuma=true
fi

for command_name in docker tar sha256sum sqlite3 realpath; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: ${command_name}"
done
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable."
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is unavailable."
[[ -f .env ]] || fail ".env is missing. Configure the target stack before restoring."
# shellcheck source=/dev/null
# shellcheck disable=SC1091
set -a; source .env; set +a
[[ -n "${N8N_IMAGE:-}" && -n "${KUMA_IMAGE:-}" ]] || fail ".env lacks N8N_IMAGE or KUMA_IMAGE."

backup_dir="$(realpath -e "$backup_arg")" || fail "Backup directory does not exist: ${backup_arg}"
[[ -d "$backup_dir" ]] || fail "Backup path is not a directory: ${backup_dir}"
archive="${backup_dir}/stack-data.tar.gz"
manifest="${backup_dir}/manifest.txt"
checksums="${backup_dir}/SHA256SUMS"
[[ -f "${backup_dir}/VERIFIED" ]] || fail "Backup has no VERIFIED marker and cannot be restored."
[[ -f "$archive" && -f "$manifest" && -f "$checksums" ]] || fail "Backup is missing archive, manifest, or checksums."

mapfile -t checksum_names < <(awk 'NF >= 2 {sub(/^\*/, "", $2); print $2}' "$checksums")
(( ${#checksum_names[@]} == 2 )) || fail "SHA256SUMS must contain exactly the archive and manifest."
seen_archive=false
seen_manifest=false
for checksum_name in "${checksum_names[@]}"; do
    case "$checksum_name" in
        stack-data.tar.gz) seen_archive=true ;;
        manifest.txt) seen_manifest=true ;;
        *) fail "SHA256SUMS contains an unexpected path: ${checksum_name}" ;;
    esac
done
[[ "$seen_archive" == "true" && "$seen_manifest" == "true" ]] || fail "SHA256SUMS is incomplete."

log "Verifying backup checksums."
(cd "$backup_dir" && sha256sum --strict -c SHA256SUMS)

restore_tmp="$(mktemp -d)"
restore_complete=false
stopped_services=()
safety_dir=""
stage_dirs=()
swapped_targets=()
swapped_old_dirs=()

safe_remove_restore_tree() {
    local path="$1"
    case "$path" in
        "${PROJECT_DIR}/n8n/.data.restore-stage."*|"${PROJECT_DIR}/n8n/.files.restore-stage."*|\
        "${PROJECT_DIR}/kuma/.data.restore-stage."*|"${PROJECT_DIR}/n8n/.data.pre-restore."*|\
        "${PROJECT_DIR}/n8n/.files.pre-restore."*|"${PROJECT_DIR}/kuma/.data.pre-restore."*)
            rm -rf -- "$path"
            ;;
        *) warn "Refusing to remove unexpected restore path: ${path}"; return 1 ;;
    esac
}

cleanup() {
    local status=$? index target old_dir stage
    rm -rf -- "$restore_tmp"
    if [[ "$restore_complete" != "true" && ${#swapped_targets[@]} -gt 0 ]]; then
        warn "Restore failed after state was swapped; rolling back the previous trees."
        docker compose -f "$COMPOSE_FILE" stop n8n uptime-kuma >/dev/null 2>&1 || true
        for (( index=${#swapped_targets[@]}-1; index>=0; index-- )); do
            target="${swapped_targets[$index]}"
            old_dir="${swapped_old_dirs[$index]}"
            if [[ -d "$old_dir" && ! -L "$old_dir" ]]; then
                case "$target" in
                    "${PROJECT_DIR}/n8n/data"|"${PROJECT_DIR}/n8n/files"|"${PROJECT_DIR}/kuma/data")
                        rm -rf -- "$target"
                        mv -- "$old_dir" "$target" || warn "Rollback failed for ${target}. Safety copy: ${safety_dir}"
                        ;;
                esac
            fi
        done
    fi
    for stage in "${stage_dirs[@]}"; do
        if [[ -e "$stage" ]]; then
            safe_remove_restore_tree "$stage" || true
        fi
    done
    if [[ "$restore_complete" != "true" && ${#stopped_services[@]} -gt 0 ]]; then
        warn "Attempting to return services to their prior running state."
        docker compose -f "$COMPOSE_FILE" start "${stopped_services[@]}" >/dev/null 2>&1 || \
            warn "Automatic service restart failed. Use the safety copy and inspect the stack manually."
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

archive_list="${restore_tmp}/archive.list"
tar -tzf "$archive" > "$archive_list"
while IFS= read -r entry; do
    [[ "$entry" != /* ]] || fail "Archive contains an absolute path: ${entry}"
    case "/${entry}/" in
        */../*) fail "Archive contains a parent-directory path: ${entry}" ;;
    esac
    case "$entry" in
        n8n/data|n8n/data/*|n8n/files|n8n/files/*|kuma/data|kuma/data/*) ;;
        *) fail "Archive contains an unexpected path: ${entry}" ;;
    esac
done < "$archive_list"
for expected in n8n/data n8n/files kuma/data; do
    grep -Eq "^${expected}(/|$)" "$archive_list" || fail "Archive is missing ${expected}."
done

log "Extracting the verified archive into a temporary workspace."
tar -xzf "$archive" -C "$restore_tmp"
n8n_db="${restore_tmp}/n8n/data/database.sqlite"
kuma_db="${restore_tmp}/kuma/data/kuma.db"

unexpected_node="$(find "${restore_tmp}/n8n" "${restore_tmp}/kuma" ! -type f ! -type d ! -type l -print -quit)"
[[ -z "$unexpected_node" ]] || fail "Backup contains an unsupported filesystem object: ${unexpected_node#"${restore_tmp}"/}"
while IFS= read -r link; do
    resolved_link="$(realpath -m "$link")"
    case "$resolved_link" in
        "${restore_tmp}/"*) ;;
        *) fail "Backup contains a symlink escaping the staging area: ${link#"${restore_tmp}"/}" ;;
    esac
done < <(find "${restore_tmp}/n8n" "${restore_tmp}/kuma" -type l -print)
[[ -f "$n8n_db" && ! -L "$n8n_db" ]] || fail "Backup has no regular n8n database.sqlite."
[[ ! -e "$kuma_db" || ( -f "$kuma_db" && ! -L "$kuma_db" ) ]] || fail "Kuma database is not a regular file."

verify_n8n() {
    local database="$1"
    n8n_integrity="$(sqlite3 -readonly "$database" 'PRAGMA integrity_check;')"
    [[ "$n8n_integrity" == "ok" ]] || fail "n8n SQLite integrity failed: ${n8n_integrity}"
    workflow_count="$(sqlite3 -readonly "$database" 'SELECT COUNT(*) FROM workflow_entity;')" \
        || fail "workflow_entity is unreadable."
    credential_count="$(sqlite3 -readonly "$database" 'SELECT COUNT(*) FROM credentials_entity;')" \
        || fail "credentials_entity is unreadable."
    [[ "$workflow_count" =~ ^[0-9]+$ && "$credential_count" =~ ^[0-9]+$ ]] \
        || fail "n8n table counts are invalid."
}

verify_n8n "$n8n_db"
if [[ -f "$kuma_db" ]]; then
    kuma_integrity="$(sqlite3 -readonly "$kuma_db" 'PRAGMA integrity_check;')"
    [[ "$kuma_integrity" == "ok" ]] || fail "Kuma SQLite integrity failed: ${kuma_integrity}"
else
    kuma_integrity="not_present"
fi

manifest_value() { awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$manifest"; }
[[ "$(manifest_value n8n_sqlite_integrity)" == "$n8n_integrity" ]] || fail "n8n integrity result differs from the manifest."
[[ "$(manifest_value kuma_sqlite_integrity)" == "$kuma_integrity" ]] || fail "Kuma integrity result differs from the manifest."
[[ "$(manifest_value workflow_count)" == "$workflow_count" ]] || fail "Workflow count differs from the manifest."
[[ "$(manifest_value credential_count)" == "$credential_count" ]] || fail "Credential count differs from the manifest."
backup_n8n_image="$(manifest_value n8n_image)"
backup_kuma_image="$(manifest_value kuma_image)"

disabled_count=0
if [[ "$mode" == "clone" ]]; then
    table_exists="$(sqlite3 -readonly "$n8n_db" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='workflow_entity';")"
    active_column_count="$(sqlite3 -readonly "$n8n_db" "SELECT COUNT(*) FROM pragma_table_info('workflow_entity') WHERE name='active';")"
    [[ "$table_exists" == "1" && "$active_column_count" == "1" ]] \
        || fail "Cannot safely identify workflow_entity.active; clone restore aborted without guessing the schema."
    disabled_count="$(sqlite3 -readonly "$n8n_db" 'SELECT COUNT(*) FROM workflow_entity WHERE COALESCE(active, 0) != 0;')"
    sqlite3 "$n8n_db" <<'SQL'
BEGIN IMMEDIATE;
UPDATE workflow_entity SET active = 0 WHERE COALESCE(active, 0) != 0;
COMMIT;
SQL
    remaining_active="$(sqlite3 -readonly "$n8n_db" 'SELECT COUNT(*) FROM workflow_entity WHERE COALESCE(active, 0) != 0;')"
    [[ "$remaining_active" == "0" ]] || fail "Active workflows remain after clone safety update."
    verify_n8n "$n8n_db"
fi

echo
echo "Restore plan"
echo "  Mode               : ${mode}"
echo "  Backup             : ${backup_dir}"
echo "  Backup n8n image   : ${backup_n8n_image:-unknown}"
echo "  Target n8n image   : ${N8N_IMAGE}"
echo "  Workflows          : ${workflow_count}"
echo "  Credentials        : ${credential_count}"
echo "  n8n SQLite         : ${n8n_integrity}"
echo "  Kuma SQLite        : ${kuma_integrity}"
echo "  Restore Kuma data  : ${with_kuma}"
if [[ "$mode" == "clone" ]]; then
    echo "  Workflows disabled : ${disabled_count}"
    echo "  Start Kuma         : no"
else
    echo "  Start Kuma         : yes"
fi
if [[ -n "$backup_n8n_image" && "$backup_n8n_image" != "$N8N_IMAGE" ]]; then
    warn "Backup and target n8n image references differ. Review compatibility before continuing."
fi
if [[ "$with_kuma" == "true" && -n "$backup_kuma_image" && "$backup_kuma_image" != "$KUMA_IMAGE" ]]; then
    warn "Backup and target Kuma image references differ. Review compatibility before continuing."
fi
echo

if [[ "$assume_yes" != "true" ]]; then
    [[ -t 0 ]] || fail "Confirmation requires a terminal, or pass --yes after reviewing the plan."
    if [[ "$mode" == "production" ]]; then
        read -r -p "Type RESTORE PRODUCTION to continue: " confirmation
        [[ "$confirmation" == "RESTORE PRODUCTION" ]] || { log "Restore cancelled."; exit 0; }
    else
        read -r -p "Type RESTORE CLONE to continue: " confirmation
        [[ "$confirmation" == "RESTORE CLONE" ]] || { log "Restore cancelled."; exit 0; }
    fi
fi

mkdir -p n8n/data n8n/files kuma/data backups

prepare_stage() {
    local source="$1" target="$2" parent base stage
    parent="$(dirname "$target")"
    base="$(basename "$target")"
    stage="$(mktemp -d "${parent}/.${base}.restore-stage.XXXXXX")"
    stage_dirs+=("$stage")
    cp -a "${source}/." "$stage/"
}

log "Copying verified state into same-filesystem staging directories."
prepare_stage "${restore_tmp}/n8n/data" "${PROJECT_DIR}/n8n/data"
prepare_stage "${restore_tmp}/n8n/files" "${PROJECT_DIR}/n8n/files"
if [[ "$with_kuma" == "true" ]]; then
    prepare_stage "${restore_tmp}/kuma/data" "${PROJECT_DIR}/kuma/data"
fi

service_is_running() {
    local service="$1" container_id
    container_id="$(docker compose -f "$COMPOSE_FILE" ps -q "$service" 2>/dev/null || true)"
    [[ -n "$container_id" ]] \
        && [[ "$(docker inspect --format '{{.State.Running}}' "$container_id" 2>/dev/null || true)" == "true" ]]
}
for service in n8n uptime-kuma; do
    if service_is_running "$service"; then
        stopped_services+=("$service")
    fi
done
if (( ${#stopped_services[@]} > 0 )); then
    log "Stopping affected services: ${stopped_services[*]}"
    docker compose -f "$COMPOSE_FILE" stop "${stopped_services[@]}"
fi

safety_dir="${PROJECT_DIR}/backups/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -m 700 "$safety_dir"
log "Creating a stopped-state safety archive: ${safety_dir}"
tar -czf "${safety_dir}/current-state.tar.gz" -C "$PROJECT_DIR" n8n/data n8n/files kuma/data
(
    cd "$safety_dir"
    sha256sum current-state.tar.gz > SHA256SUMS
    sha256sum --strict -c SHA256SUMS
    touch SAFETY_COPY
)

swap_tree() {
    local stage="$1" target="$2" parent base old_dir
    case "$target" in
        "${PROJECT_DIR}/n8n/data"|"${PROJECT_DIR}/n8n/files"|"${PROJECT_DIR}/kuma/data") ;;
        *) fail "Refusing to replace unexpected target: ${target}" ;;
    esac
    [[ ! -L "$target" ]] || fail "Refusing to replace a symlinked target directory: ${target}"
    parent="$(dirname "$target")"
    base="$(basename "$target")"
    old_dir="${parent}/.${base}.pre-restore.$$"
    [[ ! -e "$old_dir" ]] || fail "Restore rollback path already exists: ${old_dir}"
    mv -- "$target" "$old_dir"
    swapped_targets+=("$target")
    swapped_old_dirs+=("$old_dir")
    mv -- "$stage" "$target" || fail "Atomic state swap failed for ${target}."
}

log "Atomically swapping n8n state from the verified staging area."
swap_tree "${stage_dirs[0]}" "${PROJECT_DIR}/n8n/data"
swap_tree "${stage_dirs[1]}" "${PROJECT_DIR}/n8n/files"
if [[ "$with_kuma" == "true" ]]; then
    log "Atomically swapping Kuma state from the verified staging area."
    swap_tree "${stage_dirs[2]}" "${PROJECT_DIR}/kuma/data"
fi

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
        sudo chown -R "$owner" "$@"
    else
        fail "Fixing restored ownership requires root or sudo."
    fi
}

set_owner "$(image_owner "$N8N_IMAGE" /home/node/.n8n node)" n8n/data n8n/files
if [[ "$with_kuma" == "true" ]]; then
    set_owner "$(image_owner "$KUMA_IMAGE" /app/data)" kuma/data
fi

log "Starting restored n8n."
docker compose -f "$COMPOSE_FILE" up -d n8n
if [[ "$mode" == "production" ]]; then
    log "Starting restored Uptime Kuma."
    docker compose -f "$COMPOSE_FILE" up -d uptime-kuma
else
    docker compose -f "$COMPOSE_FILE" stop uptime-kuma >/dev/null 2>&1 || true
fi

log "Waiting for n8n readiness."
ready=false
for _ in $(seq 1 90); do
    container_id="$(docker compose -f "$COMPOSE_FILE" ps -q n8n)"
    if [[ -n "$container_id" ]]; then
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id" 2>/dev/null || true)"
        [[ "$health" != "unhealthy" ]] || fail "Restored n8n is unhealthy. Safety copy: ${safety_dir}"
        if [[ "$health" == "healthy" ]]; then
            ready=true
            break
        fi
    fi
    sleep 2
done
[[ "$ready" == "true" ]] || fail "Restored n8n did not become ready. Safety copy: ${safety_dir}"

for old_dir in "${swapped_old_dirs[@]}"; do
    safe_remove_restore_tree "$old_dir"
done
restore_complete=true
swapped_targets=()
swapped_old_dirs=()
stage_dirs=()
stopped_services=()
ok "Restore health validation passed. Safety copy retained: ${safety_dir}"
echo
if [[ "$mode" == "clone" ]]; then
    echo "CLONE RESTORED - AUTOMATIONS DISABLED"
    echo "Uptime Kuma remains stopped because restored monitors may contain production notifications."
    echo "Review it before explicitly running: docker compose up -d uptime-kuma"
else
    echo "RESTORE VERIFIED"
fi

#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="${PROJECT_DIR}/backups"
cd "$PROJECT_DIR"

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

for command_name in ssh ssh-keygen rsync sha256sum realpath stat; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: ${command_name}"
done
[[ -f .env.rsync ]] || fail ".env.rsync is missing. Configure rsync through install.sh."
# shellcheck source=/dev/null
set -a; source .env.rsync; set +a

for variable in RSYNC_HOST RSYNC_PORT RSYNC_USER RSYNC_PATH RSYNC_SSH_KEY RSYNC_KNOWN_HOSTS_FILE; do
    [[ -n "${!variable:-}" ]] || fail "Missing rsync setting: ${variable}"
done
[[ "$RSYNC_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || fail "RSYNC_HOST is invalid."
[[ "$RSYNC_PORT" =~ ^[0-9]+$ ]] && (( RSYNC_PORT >= 1 && RSYNC_PORT <= 65535 )) || fail "RSYNC_PORT is invalid."
[[ "$RSYNC_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || fail "RSYNC_USER is invalid."
[[ "$RSYNC_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$RSYNC_PATH" != *..* ]] || fail "RSYNC_PATH is unsafe."
[[ "$RSYNC_SSH_KEY" == /* && -r "$RSYNC_SSH_KEY" ]] || fail "RSYNC_SSH_KEY is not a readable absolute path."
[[ -f "$RSYNC_SSH_KEY" && ! -L "$RSYNC_SSH_KEY" ]] || fail "RSYNC_SSH_KEY must be a regular, non-symlink file."
[[ "$RSYNC_KNOWN_HOSTS_FILE" == /* && -f "$RSYNC_KNOWN_HOSTS_FILE" && ! -L "$RSYNC_KNOWN_HOSTS_FILE" ]] \
    || fail "RSYNC_KNOWN_HOSTS_FILE must be an absolute path to a regular, non-symlink file."
[[ "$(stat -c '%u' "$RSYNC_SSH_KEY")" == "$(id -u)" || "$(stat -c '%u' "$RSYNC_SSH_KEY")" == "0" ]] \
    || fail "RSYNC_SSH_KEY must be owned by the current user or root."
[[ "$(stat -c '%u' "$RSYNC_KNOWN_HOSTS_FILE")" == "$(id -u)" || "$(stat -c '%u' "$RSYNC_KNOWN_HOSTS_FILE")" == "0" ]] \
    || fail "known_hosts must be owned by the current user or root."
(( (8#$(stat -c '%a' "$RSYNC_SSH_KEY") & 8#077) == 0 )) || fail "RSYNC_SSH_KEY permissions are too broad."
(( (8#$(stat -c '%a' "$RSYNC_KNOWN_HOSTS_FILE") & 8#022) == 0 )) || fail "known_hosts must not be group- or world-writable."
host_lookup="$RSYNC_HOST"
[[ "$RSYNC_PORT" == "22" ]] || host_lookup="[${RSYNC_HOST}]:${RSYNC_PORT}"
ssh-keygen -F "$host_lookup" -f "$RSYNC_KNOWN_HOSTS_FILE" >/dev/null \
    || fail "No pinned host key exists for ${host_lookup}."

select_backup() {
    local requested="${1:-latest}" candidate=""
    if [[ "$requested" == "latest" ]]; then
        while IFS= read -r directory; do
            [[ -f "${directory}/VERIFIED" ]] && candidate="$directory"
        done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*T*Z-*' -print | sort)
        [[ -n "$candidate" ]] || fail "No verified local backup exists."
    else
        candidate="$(realpath -e "$requested")" || fail "Backup not found: ${requested}"
    fi
    printf '%s' "$candidate"
}

backup_dir="$(select_backup "${1:-latest}")"
[[ -d "$backup_dir" ]] || fail "Backup is not a directory."
for file in VERIFIED SHA256SUMS manifest.txt stack-data.tar.gz; do
    [[ -f "${backup_dir}/${file}" ]] || fail "Backup is incomplete: missing ${file}"
done
mapfile -t checksum_names < <(awk 'NF >= 2 {sub(/^\*/, "", $2); print $2}' "${backup_dir}/SHA256SUMS")
(( ${#checksum_names[@]} == 2 )) || fail "Unexpected SHA256SUMS contents."
seen_archive=false
seen_manifest=false
for name in "${checksum_names[@]}"; do
    case "$name" in
        stack-data.tar.gz) seen_archive=true ;;
        manifest.txt) seen_manifest=true ;;
        *) fail "Unsafe checksum path: ${name}" ;;
    esac
done
[[ "$seen_archive" == "true" && "$seen_manifest" == "true" ]] || fail "SHA256SUMS is incomplete."
(cd "$backup_dir" && sha256sum --strict -c SHA256SUMS)

backup_name="$(basename "$backup_dir")"
[[ "$backup_name" == 20*T*Z-* ]] || fail "Backup directory name is not a completed timestamped backup."
remote_base="${RSYNC_PATH%/}"
remote_final="${remote_base}/${backup_name}"
remote_partial="${remote_final}.partial-$$"
ssh_args=(-i "$RSYNC_SSH_KEY" -p "$RSYNC_PORT"
    -o BatchMode=yes -o IdentitiesOnly=yes
    -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$RSYNC_KNOWN_HOSTS_FILE"
    -o GlobalKnownHostsFile=/dev/null -o ForwardAgent=no -o ClearAllForwardings=yes)

ssh "${ssh_args[@]}" "${RSYNC_USER}@${RSYNC_HOST}" "test -d '${remote_base}'" \
    || fail "Remote base directory does not exist. Re-run install.sh to configure it explicitly."
ssh "${ssh_args[@]}" "${RSYNC_USER}@${RSYNC_HOST}" "test ! -e '${remote_final}' && test ! -e '${remote_partial}'" \
    || fail "Remote final or partial directory already exists; refusing to merge or overwrite it."

printf -v rsync_rsh 'ssh -i %q -p %q -o BatchMode=yes -o IdentitiesOnly=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%q -o GlobalKnownHostsFile=/dev/null -o ForwardAgent=no -o ClearAllForwardings=yes' \
    "$RSYNC_SSH_KEY" "$RSYNC_PORT" "$RSYNC_KNOWN_HOSTS_FILE"
log "Uploading $(basename "$backup_dir") to a remote partial directory."
rsync -az --partial --checksum -e "$rsync_rsh" "$backup_dir/" \
    "${RSYNC_USER}@${RSYNC_HOST}:${remote_partial}/"

log "Verifying the remote copy before the atomic rename."
ssh "${ssh_args[@]}" "${RSYNC_USER}@${RSYNC_HOST}" \
    "cd '${remote_partial}' && test -f VERIFIED && test -f manifest.txt && sha256sum --strict -c SHA256SUMS && test ! -e '${remote_final}' && mv -- '${remote_partial}' '${remote_final}'"

ok "Verified backup published atomically at ${RSYNC_USER}@${RSYNC_HOST}:${remote_final}"

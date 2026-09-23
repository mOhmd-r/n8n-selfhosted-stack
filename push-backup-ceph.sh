#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="${PROJECT_DIR}/backups"
cd "$PROJECT_DIR"

log() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

for command_name in docker sha256sum realpath stat; do
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: ${command_name}"
done
docker info >/dev/null 2>&1 || fail "Docker daemon is not reachable."
[[ -f .env.ceph ]] || fail ".env.ceph is missing. Configure Ceph/S3 through install.sh."
# shellcheck source=/dev/null
# shellcheck disable=SC1091
set -a; source .env.ceph; set +a

for variable in CEPH_S3_ENDPOINT CEPH_S3_BUCKET CEPH_S3_PREFIX AWS_DEFAULT_REGION AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE AWS_CLI_IMAGE; do
    [[ -n "${!variable:-}" ]] || fail "Missing Ceph/S3 setting: ${variable}"
done
[[ "$CEPH_S3_ENDPOINT" =~ ^https://[^[:space:]]+$ ]] || fail "CEPH_S3_ENDPOINT must use HTTPS."
[[ "$CEPH_S3_BUCKET" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{1,61}[A-Za-z0-9]$ ]] || fail "CEPH_S3_BUCKET is invalid."
[[ "$CEPH_S3_PREFIX" =~ ^[A-Za-z0-9._/-]+$ && "$CEPH_S3_PREFIX" != /* && "$CEPH_S3_PREFIX" != *..* ]] || fail "CEPH_S3_PREFIX is unsafe."
[[ "$AWS_CLI_IMAGE" =~ ^[A-Za-z0-9._/:@-]+$ ]] || fail "AWS_CLI_IMAGE is invalid."
[[ "$AWS_DEFAULT_REGION" =~ ^[A-Za-z0-9-]+$ ]] || fail "AWS_DEFAULT_REGION is invalid."
[[ "$AWS_PROFILE" =~ ^[A-Za-z0-9_-]+$ ]] || fail "AWS_PROFILE is invalid."

if [[ "$AWS_SHARED_CREDENTIALS_FILE" == /* ]]; then
    credentials_file="$AWS_SHARED_CREDENTIALS_FILE"
else
    credentials_file="${PROJECT_DIR}/${AWS_SHARED_CREDENTIALS_FILE}"
fi
credentials_file="$(realpath -e "$credentials_file")" || fail "AWS credentials file does not exist."
[[ -f "$credentials_file" && -r "$credentials_file" ]] || fail "AWS credentials file is not readable."
credentials_mode="$(stat -c %a "$credentials_file")"
(( (8#$credentials_mode & 077) == 0 )) || fail "AWS credentials file must not be accessible to group or other users."

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
destination="s3://${CEPH_S3_BUCKET}/${CEPH_S3_PREFIX%/}/${backup_name}"

aws_cli() {
    docker run --rm \
        -e AWS_PROFILE="$AWS_PROFILE" \
        -e AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
        -e AWS_EC2_METADATA_DISABLED=true \
        -e AWS_PAGER= \
        -v "${credentials_file}:/root/.aws/credentials:ro" \
        -v "${backup_dir}:/backup:ro" \
        "$AWS_CLI_IMAGE" \
        --endpoint-url "$CEPH_S3_ENDPOINT" \
        "$@"
}

log "Uploading archive, manifest, and checksums to ${destination}/"
for file in stack-data.tar.gz manifest.txt SHA256SUMS; do
    aws_cli s3 cp "/backup/${file}" "${destination}/${file}" --only-show-errors
done

# Publish the completion marker last. No remote retention or deletion occurs here.
log "Publishing VERIFIED last."
aws_cli s3 cp /backup/VERIFIED "${destination}/VERIFIED" --only-show-errors
ok "Verified backup uploaded to ${destination}/"

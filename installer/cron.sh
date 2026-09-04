#!/usr/bin/env bash

validate_hhmm() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

cron_prompt() {
    while :; do
        LOCAL_BACKUP_TIME="$(prompt_with_default "Local backup time (HH:MM)" "03:15")"
        validate_hhmm "$LOCAL_BACKUP_TIME" && break
        warn "Use 24-hour HH:MM format."
    done

    OFFSITE_BACKUP_TIME=""
    if [[ "$OFFSITE_PROVIDER" != "none" ]]; then
        while :; do
            OFFSITE_BACKUP_TIME="$(prompt_with_default "Off-site upload time (HH:MM)" "03:45")"
            validate_hhmm "$OFFSITE_BACKUP_TIME" && break
            warn "Use 24-hour HH:MM format."
        done
    fi
}

cron_line() {
    local when="$1" script="$2" lock="$3" log_file="$4"
    local hour="${when%:*}" minute="${when#*:}"
    printf '%s %s * * * %s cd %q && flock -n %q ./%s >> %q 2>&1\n' \
        "$((10#$minute))" "$((10#$hour))" "$CRON_USER" "$PROJECT_DIR" "$lock" "$script" "$log_file"
}

cron_install() {
    local cron_tmp cron_id cron_target

    [[ "$PROJECT_DIR" != *%* && "$PROJECT_DIR" != *$'\n'* ]] \
        || fail "Cron installation does not support a project path containing '%' or a newline."
    confirm "Install the displayed schedule under /etc/cron.d now?" \
        || { warn "Cron installation skipped."; return 0; }

    command -v flock >/dev/null 2>&1 || fail "flock is required for scheduled jobs."
    CRON_USER="$(id -un)"
    cron_id="$(printf '%s' "$PROJECT_DIR" | sha256sum | cut -c1-12)"
    cron_target="/etc/cron.d/n8n-stack-${cron_id}"
    cron_tmp="$(mktemp)"

    {
        printf 'SHELL=/bin/bash\n'
        printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n\n'
        cron_line "$LOCAL_BACKUP_TIME" "backup.sh" "${PROJECT_DIR}/backups/.backup.lock" "${PROJECT_DIR}/backups/backup.log"
        if [[ "$OFFSITE_PROVIDER" == "rsync" ]]; then
            cron_line "$OFFSITE_BACKUP_TIME" "push-backup-rsync.sh latest" "${PROJECT_DIR}/backups/.rsync.lock" "${PROJECT_DIR}/backups/rsync.log"
        elif [[ "$OFFSITE_PROVIDER" == "ceph" ]]; then
            cron_line "$OFFSITE_BACKUP_TIME" "push-backup-ceph.sh latest" "${PROJECT_DIR}/backups/.ceph.lock" "${PROJECT_DIR}/backups/ceph.log"
        fi
    } > "$cron_tmp"

    if [[ $(id -u) -eq 0 ]]; then
        install -m 644 "$cron_tmp" "$cron_target"
    elif command -v sudo >/dev/null 2>&1; then
        sudo install -m 644 "$cron_tmp" "$cron_target"
    else
        rm -f -- "$cron_tmp"
        fail "Installing /etc/cron.d requires root or sudo."
    fi
    rm -f -- "$cron_tmp"
    ok "Installed ${cron_target}."
}

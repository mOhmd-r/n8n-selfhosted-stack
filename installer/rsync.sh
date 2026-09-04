#!/usr/bin/env bash

rsync_prompt() {
    read -r -p "Remote host: " RSYNC_HOST
    read -r -p "SSH port [22]: " RSYNC_PORT
    RSYNC_PORT="${RSYNC_PORT:-22}"
    read -r -p "Remote user: " RSYNC_USER
    read -r -p "Remote backup path: " RSYNC_PATH
    read -r -p "SSH private key path: " RSYNC_SSH_KEY

    [[ "$RSYNC_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Remote host contains unsupported characters."
    [[ "$RSYNC_PORT" =~ ^[0-9]+$ ]] && (( RSYNC_PORT >= 1 && RSYNC_PORT <= 65535 )) \
        || fail "SSH port must be between 1 and 65535."
    [[ "$RSYNC_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || fail "Remote user is invalid."
    [[ "$RSYNC_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$RSYNC_PATH" != *..* ]] \
        || fail "Remote path must be an absolute path without spaces or '..'."
    [[ "$RSYNC_SSH_KEY" == /* && "$RSYNC_SSH_KEY" != *$'\n'* && -r "$RSYNC_SSH_KEY" ]] \
        || fail "SSH private key must be an absolute path to a readable file."
}

rsync_configure() {
    local -a ssh_args
    local config_tmp
    ssh_args=(-i "$RSYNC_SSH_KEY" -p "$RSYNC_PORT" -o BatchMode=yes -o IdentitiesOnly=yes)

    log "Testing non-destructive SSH connectivity."
    ssh "${ssh_args[@]}" "${RSYNC_USER}@${RSYNC_HOST}" true \
        || fail "SSH connectivity test failed."

    if ! ssh "${ssh_args[@]}" "${RSYNC_USER}@${RSYNC_HOST}" "test -d '${RSYNC_PATH}'"; then
        if confirm "Remote directory does not exist. Create ${RSYNC_PATH}?"; then
            ssh "${ssh_args[@]}" "${RSYNC_USER}@${RSYNC_HOST}" "mkdir -p -- '${RSYNC_PATH}'" \
                || fail "Could not create the remote directory."
        else
            fail "Remote directory is required for rsync backups."
        fi
    fi

    config_tmp="$(mktemp "${PROJECT_DIR}/.env.rsync.tmp.XXXXXX")"
    {
        printf 'RSYNC_HOST=%q\n' "$RSYNC_HOST"
        printf 'RSYNC_PORT=%q\n' "$RSYNC_PORT"
        printf 'RSYNC_USER=%q\n' "$RSYNC_USER"
        printf 'RSYNC_PATH=%q\n' "$RSYNC_PATH"
        printf 'RSYNC_SSH_KEY=%q\n' "$RSYNC_SSH_KEY"
    } > "$config_tmp"
    chmod 600 "$config_tmp"
    mv -f "$config_tmp" "${PROJECT_DIR}/.env.rsync"
    ok "rsync configuration passed its connectivity check."
}

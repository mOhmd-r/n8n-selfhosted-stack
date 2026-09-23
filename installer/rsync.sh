#!/usr/bin/env bash

rsync_prompt() {
    read -r -p "Remote host: " RSYNC_HOST
    read -r -p "SSH port [22]: " RSYNC_PORT
    RSYNC_PORT="${RSYNC_PORT:-22}"
    read -r -p "Remote user: " RSYNC_USER
    read -r -p "Remote backup path: " RSYNC_PATH
    read -r -p "SSH private key path: " RSYNC_SSH_KEY
    read -r -p "Pinned known_hosts file [${HOME}/.ssh/known_hosts]: " RSYNC_KNOWN_HOSTS_FILE
    RSYNC_KNOWN_HOSTS_FILE="${RSYNC_KNOWN_HOSTS_FILE:-${HOME}/.ssh/known_hosts}"

    [[ "$RSYNC_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Remote host contains unsupported characters."
    [[ "$RSYNC_PORT" =~ ^[0-9]+$ ]] && (( RSYNC_PORT >= 1 && RSYNC_PORT <= 65535 )) \
        || fail "SSH port must be between 1 and 65535."
    [[ "$RSYNC_USER" =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || fail "Remote user is invalid."
    [[ "$RSYNC_PATH" =~ ^/[A-Za-z0-9._/-]+$ && "$RSYNC_PATH" != *..* ]] \
        || fail "Remote path must be an absolute path without spaces or '..'."
    [[ "$RSYNC_SSH_KEY" == /* && "$RSYNC_SSH_KEY" != *$'\n'* && -r "$RSYNC_SSH_KEY" ]] \
        || fail "SSH private key must be an absolute path to a readable file."
    [[ -f "$RSYNC_SSH_KEY" && ! -L "$RSYNC_SSH_KEY" ]] || fail "SSH private key must be a regular, non-symlink file."
    [[ "$RSYNC_KNOWN_HOSTS_FILE" == /* && -f "$RSYNC_KNOWN_HOSTS_FILE" && ! -L "$RSYNC_KNOWN_HOSTS_FILE" ]] \
        || fail "known_hosts must be an absolute path to a regular, non-symlink file."
    [[ "$(stat -c '%u' "$RSYNC_SSH_KEY")" == "$(id -u)" || "$(stat -c '%u' "$RSYNC_SSH_KEY")" == "0" ]] \
        || fail "SSH private key must be owned by the current user or root."
    [[ "$(stat -c '%u' "$RSYNC_KNOWN_HOSTS_FILE")" == "$(id -u)" || "$(stat -c '%u' "$RSYNC_KNOWN_HOSTS_FILE")" == "0" ]] \
        || fail "known_hosts must be owned by the current user or root."
    (( (8#$(stat -c '%a' "$RSYNC_SSH_KEY") & 8#077) == 0 )) || fail "SSH private key must not be accessible by group or others."
    (( (8#$(stat -c '%a' "$RSYNC_KNOWN_HOSTS_FILE") & 8#022) == 0 )) || fail "known_hosts must not be group- or world-writable."

    local host_lookup="$RSYNC_HOST"
    [[ "$RSYNC_PORT" == "22" ]] || host_lookup="[${RSYNC_HOST}]:${RSYNC_PORT}"
    ssh-keygen -F "$host_lookup" -f "$RSYNC_KNOWN_HOSTS_FILE" >/dev/null \
        || fail "known_hosts has no pinned key for ${host_lookup}. Verify and add the server key before continuing."
}

rsync_configure() {
    local -a ssh_args
    local config_tmp
    ssh_args=(-i "$RSYNC_SSH_KEY" -p "$RSYNC_PORT"
        -o BatchMode=yes -o IdentitiesOnly=yes
        -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$RSYNC_KNOWN_HOSTS_FILE"
        -o GlobalKnownHostsFile=/dev/null -o ForwardAgent=no -o ClearAllForwardings=yes)

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
        printf 'RSYNC_KNOWN_HOSTS_FILE=%q\n' "$RSYNC_KNOWN_HOSTS_FILE"
    } > "$config_tmp"
    chmod 600 "$config_tmp"
    mv -f "$config_tmp" "${PROJECT_DIR}/.env.rsync"
    ok "rsync configuration passed its connectivity check."
}

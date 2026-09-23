#!/usr/bin/env bash

validate_cert_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$1" != *..* ]]
}

tls_prompt() {
    local choice

    cat <<'EOF'

TLS mode:
  1) Use an existing certificate
  2) Skip TLS setup for now

Certificate issuance is intentionally outside this repository. Provision and
test the certificate first, then select option 1.
EOF

    while :; do
        read -r -p "Selection [1]: " choice
        choice="${choice:-1}"
        case "$choice" in
            1) TLS_PROVIDER="existing"; break ;;
            2) TLS_PROVIDER="skip"; break ;;
            *) warn "Choose 1 or 2." ;;
        esac
    done

    if [[ "$TLS_PROVIDER" == "existing" ]]; then
        LETSENCRYPT_PATH="$(prompt_with_default "Certbot root path" "/etc/letsencrypt")"
        while [[ ! "$LETSENCRYPT_PATH" =~ ^/[A-Za-z0-9._/-]+$ || "$LETSENCRYPT_PATH" == *..* ]]; do
            warn "Use an absolute Certbot root path without spaces or '..'."
            LETSENCRYPT_PATH="$(prompt_with_default "Certbot root path" "/etc/letsencrypt")"
        done
        [[ -d "$LETSENCRYPT_PATH" && ! -L "$LETSENCRYPT_PATH" ]] ||
            fail "Certbot root must be an existing, non-symlink directory."

        TLS_CERT_NAME="$(prompt_with_default "Certificate name under live/" "$N8N_HOST")"
        while ! validate_cert_name "$TLS_CERT_NAME"; do
            warn "Certificate name may contain letters, digits, dots, underscores, and hyphens."
            TLS_CERT_NAME="$(prompt_with_default "Certificate name under live/" "$N8N_HOST")"
        done

        TLS_ENABLED="true"
        TLS_VOLUME_SOURCE="$LETSENCRYPT_PATH"
        PUBLIC_SCHEME="https"
        NGINX_TLS_PREFIX=""
        NGINX_HTTP_PREFIX="#"
    else
        LETSENCRYPT_PATH="/etc/letsencrypt"
        TLS_CERT_NAME="$N8N_HOST"
        TLS_ENABLED="false"
        TLS_VOLUME_SOURCE="./nginx"
        PUBLIC_SCHEME="http"
        NGINX_TLS_PREFIX="#"
        NGINX_HTTP_PREFIX=""
    fi
}

cert_path_is_safe() {
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
        "${root}/live/${TLS_CERT_NAME}/"*|"${root}/archive/${TLS_CERT_NAME}/"*) return 0 ;;
        *) return 1 ;;
    esac
}

can_read_file() {
    local path="$1"
    cert_path_is_safe "$path" || return 1
    [[ -f "$path" && -r "$path" ]] && return 0
    command -v sudo >/dev/null 2>&1 &&
        sudo -n test -f "$path" &&
        sudo -n test -r "$path"
}

tls_validate_certificate() {
    local cert_dir="${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}"
    local cert_pubkey key_pubkey
    local -a privilege=()
    can_read_file "${cert_dir}/fullchain.pem" ||
        fail "Certificate is missing, unreadable, or resolves outside the selected Certbot tree: ${cert_dir}/fullchain.pem"
    can_read_file "${cert_dir}/privkey.pem" ||
        fail "Private key is missing, unreadable, or resolves outside the selected Certbot tree: ${cert_dir}/privkey.pem"

    if command -v openssl >/dev/null 2>&1; then
        [[ -r "${cert_dir}/privkey.pem" ]] || privilege=(sudo -n)
        "${privilege[@]}" openssl x509 -checkend 0 -noout -in "${cert_dir}/fullchain.pem" >/dev/null 2>&1 ||
            fail "Certificate is expired or invalid: ${cert_dir}/fullchain.pem"
        "${privilege[@]}" openssl pkey -in "${cert_dir}/privkey.pem" -noout -check >/dev/null 2>&1 ||
            fail "Private key is invalid: ${cert_dir}/privkey.pem"
        cert_pubkey="$("${privilege[@]}" openssl x509 -in "${cert_dir}/fullchain.pem" -pubkey -noout |
            openssl pkey -pubin -outform DER 2>/dev/null |
            sha256sum)"
        key_pubkey="$("${privilege[@]}" openssl pkey -in "${cert_dir}/privkey.pem" -pubout -outform DER 2>/dev/null |
            sha256sum)"
        [[ "${cert_pubkey%% *}" == "${key_pubkey%% *}" ]] ||
            fail "Certificate and private key do not match."
    else
        warn "openssl is unavailable; certificate/key validity and matching were not checked."
    fi
    ok "Existing certificate material passed validation."
}

tls_configure() {
    case "$TLS_PROVIDER" in
        existing)
            log "Using pre-provisioned certificate material."
            if [[ $(id -u) -ne 0 && ! -r "${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}/privkey.pem" ]]; then
                command -v sudo >/dev/null 2>&1 ||
                    fail "Certificate validation requires root access and sudo is unavailable."
                sudo -v
            fi
            tls_validate_certificate
            ;;
        skip)
            warn "TLS is disabled. Nginx will serve HTTP until .env is updated with valid certificate settings."
            ;;
        *)
            fail "Unknown TLS provider state: ${TLS_PROVIDER:-unset}"
            ;;
    esac
}

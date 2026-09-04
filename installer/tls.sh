#!/usr/bin/env bash

ARVAN_CERTBOT_URL="https://github.com/mOhmd-r/ArvanCloud-Certbot.git"
CLOUDFLARE_CERTBOT_URL="https://github.com/mOhmd-r/Cloudflare-Certbot.git"

validate_cert_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

tls_prompt() {
    local choice

    cat <<'EOF'

TLS provider:
  1) ArvanCloud
  2) Cloudflare
  3) Existing certificate
  4) Skip TLS setup for now
EOF

    while :; do
        read -r -p "Selection [3]: " choice
        choice="${choice:-3}"
        case "$choice" in
            1) TLS_PROVIDER="arvancloud"; break ;;
            2) TLS_PROVIDER="cloudflare"; break ;;
            3) TLS_PROVIDER="existing"; break ;;
            4) TLS_PROVIDER="skip"; break ;;
            *) warn "Choose 1, 2, 3, or 4." ;;
        esac
    done

    if [[ "$TLS_PROVIDER" == "existing" ]]; then
        LETSENCRYPT_PATH="$(prompt_with_default "Certbot root path" "/etc/letsencrypt")"
        while [[ ! "$LETSENCRYPT_PATH" =~ ^/[A-Za-z0-9._/-]+$ || "$LETSENCRYPT_PATH" == *..* ]]; do
            warn "Use an absolute Certbot root path without spaces or '..'."
            LETSENCRYPT_PATH="$(prompt_with_default "Certbot root path" "/etc/letsencrypt")"
        done
        TLS_CERT_NAME="$(prompt_with_default "Certificate name under live/" "$N8N_HOST")"
        while ! validate_cert_name "$TLS_CERT_NAME"; do
            warn "Certificate name may contain letters, digits, dots, underscores, and hyphens."
            TLS_CERT_NAME="$(prompt_with_default "Certificate name under live/" "$N8N_HOST")"
        done
    else
        LETSENCRYPT_PATH="/etc/letsencrypt"
        TLS_CERT_NAME="$N8N_HOST"
    fi

    if [[ "$TLS_PROVIDER" == "arvancloud" ]]; then
        for command_name in git curl jq dig certbot; do
            command -v "$command_name" >/dev/null 2>&1 \
                || fail "ArvanCloud helper prerequisite is missing: ${command_name}"
        done
    elif [[ "$TLS_PROVIDER" == "cloudflare" ]]; then
        for command_name in git sudo apt python3 stty; do
            command -v "$command_name" >/dev/null 2>&1 \
                || fail "Cloudflare helper prerequisite is missing: ${command_name}"
        done
    fi

    if [[ "$TLS_PROVIDER" == "skip" ]]; then
        TLS_ENABLED="false"
        TLS_VOLUME_SOURCE="./nginx"
        PUBLIC_SCHEME="http"
        NGINX_TLS_PREFIX="#"
        NGINX_HTTP_PREFIX=""
    else
        TLS_ENABLED="true"
        TLS_VOLUME_SOURCE="$LETSENCRYPT_PATH"
        PUBLIC_SCHEME="https"
        NGINX_TLS_PREFIX=""
        NGINX_HTTP_PREFIX="#"
    fi
}

tls_validate_certificate() {
    local cert_dir="${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}"
    can_read_file "${cert_dir}/fullchain.pem" || fail "Certificate not readable: ${cert_dir}/fullchain.pem"
    can_read_file "${cert_dir}/privkey.pem" || fail "Private key not readable: ${cert_dir}/privkey.pem"
    ok "Certificate files are readable."
}

can_read_file() {
    local path="$1"
    [[ -f "$path" && -r "$path" ]] && return 0
    command -v sudo >/dev/null 2>&1 && sudo -n test -f "$path" && sudo -n test -r "$path"
}

tls_run_helper() {
    local provider="$1" helper_url helper_script helper_dir rc=0
    local -a privilege=()

    command -v git >/dev/null 2>&1 || fail "git is required for delegated certificate setup."
    helper_dir="$(mktemp -d)"
    if [[ $(id -u) -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || fail "The certificate helper requires root access; sudo is unavailable."
        privilege=(sudo)
    fi

    case "$provider" in
        arvancloud)
            helper_url="$ARVAN_CERTBOT_URL"
            helper_script="certbot-arvan.sh"
            ;;
        cloudflare)
            helper_url="$CLOUDFLARE_CERTBOT_URL"
            helper_script="certbot-cloudflare.sh"
            ;;
        *) fail "Unknown TLS helper: $provider" ;;
    esac

    log "Cloning the selected certificate helper into a temporary directory."
    git clone --depth 1 "$helper_url" "${helper_dir}/helper" || rc=$?
    if (( rc == 0 )); then
        chmod +x "${helper_dir}/helper/${helper_script}"
        if [[ "$provider" == "arvancloud" ]]; then
            (cd "${helper_dir}/helper" && "${privilege[@]}" "./${helper_script}" "$N8N_HOST") || rc=$?
        else
            log "The Cloudflare helper will ask for the domain again; input is hidden to protect its token prompt."
            (
                trap 'stty echo' EXIT
                trap 'exit 130' INT
                trap 'exit 143' TERM
                stty -echo
                cd "${helper_dir}/helper"
                "${privilege[@]}" "./${helper_script}"
            ) || rc=$?
            printf '\n'
        fi
    fi

    if ! rm -rf -- "$helper_dir" 2>/dev/null; then
        "${privilege[@]}" rm -rf -- "$helper_dir"
    fi
    (( rc == 0 )) || fail "External certificate helper failed with status ${rc}."
}

tls_configure() {
    case "$TLS_PROVIDER" in
        arvancloud|cloudflare) tls_run_helper "$TLS_PROVIDER" ;;
        existing)
            log "Using existing certificate material."
            if [[ $(id -u) -ne 0 && ! -r "${LETSENCRYPT_PATH}/live/${TLS_CERT_NAME}/privkey.pem" ]]; then
                command -v sudo >/dev/null 2>&1 || fail "Certificate validation requires root access and sudo is unavailable."
                sudo -v
            fi
            ;;
        skip)
            warn "TLS is disabled. Nginx will serve HTTP until .env is updated with valid certificate settings."
            return 0
            ;;
    esac
    tls_validate_certificate
}

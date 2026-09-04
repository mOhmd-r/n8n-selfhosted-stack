#!/usr/bin/env bash

DEFAULT_AWS_CLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.27.41"

ceph_prompt() {
    read -r -p "S3 endpoint (https://...): " CEPH_S3_ENDPOINT
    read -r -p "Bucket: " CEPH_S3_BUCKET
    read -r -p "Object prefix [n8n]: " CEPH_S3_PREFIX
    CEPH_S3_PREFIX="${CEPH_S3_PREFIX:-n8n}"
    read -r -p "Region [us-east-1]: " AWS_DEFAULT_REGION
    AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
    read -r -p "Access key: " AWS_ACCESS_KEY_ID
    read -r -s -p "Secret key: " AWS_SECRET_ACCESS_KEY
    printf '\n'

    [[ "$CEPH_S3_ENDPOINT" =~ ^https?://[^[:space:]]+$ ]] || fail "Endpoint must be an HTTP(S) URL."
    [[ "$CEPH_S3_BUCKET" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{1,61}[A-Za-z0-9]$ ]] || fail "Bucket name is invalid."
    [[ "$CEPH_S3_PREFIX" =~ ^[A-Za-z0-9._/-]+$ && "$CEPH_S3_PREFIX" != /* && "$CEPH_S3_PREFIX" != *..* ]] \
        || fail "Prefix must be a relative object prefix without spaces or '..'."
    [[ "$AWS_DEFAULT_REGION" =~ ^[A-Za-z0-9-]+$ ]] || fail "Region is invalid."
    [[ -n "$AWS_ACCESS_KEY_ID" && -n "$AWS_SECRET_ACCESS_KEY" ]] || fail "Both S3 credentials are required."
    AWS_CLI_IMAGE="$DEFAULT_AWS_CLI_IMAGE"
}

ceph_aws() {
    docker run --rm \
        -e AWS_PROFILE=ceph \
        -e AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
        -e AWS_EC2_METADATA_DISABLED=true \
        -e AWS_PAGER= \
        -v "${PROJECT_DIR}/.secrets/aws/credentials:/root/.aws/credentials:ro" \
        "$AWS_CLI_IMAGE" \
        --endpoint-url "$CEPH_S3_ENDPOINT" \
        "$@"
}

ceph_configure() {
    local config_tmp credentials_tmp error_file

    install -d -m 700 "${PROJECT_DIR}/.secrets/aws"
    credentials_tmp="$(mktemp "${PROJECT_DIR}/.secrets/aws/credentials.tmp.XXXXXX")"
    {
        printf '[ceph]\n'
        printf 'aws_access_key_id = %s\n' "$AWS_ACCESS_KEY_ID"
        printf 'aws_secret_access_key = %s\n' "$AWS_SECRET_ACCESS_KEY"
    } > "$credentials_tmp"
    chmod 600 "$credentials_tmp"
    mv -f "$credentials_tmp" "${PROJECT_DIR}/.secrets/aws/credentials"
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

    log "Pulling the pinned official AWS CLI image."
    docker pull "$AWS_CLI_IMAGE"

    error_file="$(mktemp)"
    if ceph_aws s3api head-bucket --bucket "$CEPH_S3_BUCKET" 2>"$error_file"; then
        ok "Bucket access test passed."
    elif grep -Eqi '404|NoSuchBucket|Not Found' "$error_file"; then
        if confirm "Bucket ${CEPH_S3_BUCKET} does not appear to exist. Create it?"; then
            ceph_aws s3api create-bucket --bucket "$CEPH_S3_BUCKET"
            ceph_aws s3api head-bucket --bucket "$CEPH_S3_BUCKET" \
                || fail "Bucket creation completed but the access check still failed."
        else
            rm -f -- "$error_file"
            fail "Ceph/S3 setup requires an accessible bucket."
        fi
    else
        warn "Bucket access failed; the endpoint, credentials, or policy may be incorrect."
        sed -n '1,12p' "$error_file" >&2
        rm -f -- "$error_file"
        fail "Ceph/S3 access test failed."
    fi
    rm -f -- "$error_file"

    config_tmp="$(mktemp "${PROJECT_DIR}/.env.ceph.tmp.XXXXXX")"
    {
        printf 'CEPH_S3_ENDPOINT=%q\n' "$CEPH_S3_ENDPOINT"
        printf 'CEPH_S3_BUCKET=%q\n' "$CEPH_S3_BUCKET"
        printf 'CEPH_S3_PREFIX=%q\n' "$CEPH_S3_PREFIX"
        printf 'AWS_DEFAULT_REGION=%q\n' "$AWS_DEFAULT_REGION"
        printf 'AWS_PROFILE=ceph\n'
        printf 'AWS_SHARED_CREDENTIALS_FILE=.secrets/aws/credentials\n'
        printf 'AWS_CLI_IMAGE=%q\n' "$AWS_CLI_IMAGE"
    } > "$config_tmp"
    chmod 600 "$config_tmp"
    mv -f "$config_tmp" "${PROJECT_DIR}/.env.ceph"
    ok "Ceph/S3 configuration passed its bucket check."
}

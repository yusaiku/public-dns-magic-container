#!/bin/bash
# Sync config, certificates and acme.sh state with a Bunny Storage zone.
set -euo pipefail

CERT_PATH="/etc/nginx/ssl/fullchain.cer"
KEY_PATH="/etc/nginx/ssl/privkey.pem"
UNBOUND_CONF="/etc/unbound/unbound.conf"
NGINX_TEMPLATE="/etc/nginx/nginx.conf.template"
NGINX_CONF="/etc/nginx/nginx.conf"
ACME_HOME="/root/.acme.sh"
LOCK_REL="locks/acme.lock"
ISSUE_REL="locks/issue-attempt"
LOCK_TTL=600
ISSUE_RETRY=43200

UNBOUND_RELOAD=0
NGINX_RELOAD=0
CERT_RELOAD=0
LOCK_HELD=0
UPLOAD_CERTS=0
STORAGE_BASE=""
STORAGE_ZONE=""
STORAGE_PASSWORD=""
STORAGE_PREFIX=""

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

load_env() {
    if [[ -f /etc/dns-magic.env ]]; then
        # shellcheck disable=SC1091
        source /etc/dns-magic.env
    fi
}

first_set() {
    local name
    for name in "$@"; do
        if [[ -n "${!name:-}" ]]; then
            printf '%s' "${!name}"
            return 0
        fi
    done
    return 1
}

storage_names() {
    compgen -e | grep -E '^(BUNNY_STORAGE_|BUNNYNET_MC_)' | sort | tr '\n' ' ' || true
}

resolve_storage() {
    local region="" host="" endpoint="" schemehost=""

    STORAGE_ZONE="$(first_set \
        BUNNY_STORAGE_ZONE BUNNY_STORAGE_ZONE_NAME \
        BUNNY_STORAGE_USERNAME BUNNY_STORAGE_FTP_USERNAME \
        STORAGE_ZONE || true)"
    STORAGE_PASSWORD="$(first_set \
        BUNNY_STORAGE_PASSWORD BUNNY_STORAGE_ACCESS_KEY \
        BUNNY_STORAGE_SECRET BUNNY_STORAGE_FTP_PASSWORD \
        STORAGE_ACCESS_KEY || true)"
    STORAGE_PREFIX="${BUNNY_STORAGE_PREFIX:-}"
    STORAGE_PREFIX="${STORAGE_PREFIX#/}"
    STORAGE_PREFIX="${STORAGE_PREFIX%/}"

    if [[ -z "$STORAGE_ZONE" || -z "$STORAGE_PASSWORD" ]]; then
        log "Connect Storage did not provide a zone name and password."
        log "Expected BUNNY_STORAGE_ZONE and BUNNY_STORAGE_PASSWORD, plus BUNNY_STORAGE_REGION or BUNNY_STORAGE_HOSTNAME."
        log "Storage variables present: $(storage_names)"
        exit 1
    fi

    endpoint="$(first_set BUNNY_STORAGE_ENDPOINT || true)"
    host="$(first_set BUNNY_STORAGE_HOSTNAME BUNNY_STORAGE_HOST BUNNY_STORAGE_FTP_HOST STORAGE_HOSTNAME || true)"
    region="$(first_set BUNNY_STORAGE_REGION STORAGE_REGION || true)"
    region="$(printf '%s' "$region" | tr '[:upper:]' '[:lower:]')"

    if [[ -n "$endpoint" ]]; then
        if [[ "$endpoint" =~ ^(https?://[^/]+) ]]; then
            schemehost="${BASH_REMATCH[1]}"
        else
            log "BUNNY_STORAGE_ENDPOINT must start with http:// or https://"
            exit 1
        fi
    elif [[ -n "$host" ]]; then
        host="${host#https://}"
        host="${host#http://}"
        host="${host%%/*}"
        schemehost="https://${host}"
    else
        case "$region" in
            ""|de|falkenstein|fsn|fsn1) host="storage.bunnycdn.com" ;;
            *.*) host="$region" ;;
            *) host="${region}.storage.bunnycdn.com" ;;
        esac
        schemehost="https://${host}"
    fi

    STORAGE_BASE="${schemehost}/${STORAGE_ZONE}"
    if [[ -n "${BUNNY_STORAGE_CDN_URL:-}" ]]; then
        log "BUNNY_STORAGE_CDN_URL is set. Do not attach a pull zone to this storage zone, or the certificate key is readable through the CDN."
    fi
    log "Storage zone ${STORAGE_ZONE} via ${schemehost}"
}

object_url() {
    local rel="${1#/}"
    local base="$STORAGE_BASE"
    if [[ -n "$STORAGE_PREFIX" ]]; then
        base="${base}/${STORAGE_PREFIX}"
    fi
    if [[ -z "$rel" ]]; then
        printf '%s/\n' "$base"
    else
        printf '%s/%s\n' "$base" "$rel"
    fi
}

curl_code() {
    local method="$1" outfile="$2" url="$3" upload="${4:-}"
    local code
    local -a args=(
        -sS --retry 3 --retry-delay 2 --retry-connrefused
        --connect-timeout 15 --max-time 120
        -o "$outfile" -w '%{http_code}'
        -X "$method"
        -H "AccessKey: ${STORAGE_PASSWORD}"
    )
    if [[ -n "$upload" ]]; then
        args+=(--upload-file "$upload" -H "Content-Type: application/octet-stream")
    fi
    code="$(curl "${args[@]}" "$url" || true)"
    [[ -n "$code" ]] || code="000"
    printf '%s' "$code"
}

storage_download() {
    local rel="$1" dest="$2" code
    mkdir -p "$(dirname "$dest")"
    code="$(curl_code GET "${dest}.part" "$(object_url "$rel")")"
    if [[ "$code" == "200" ]]; then
        mv "${dest}.part" "$dest"
        return 0
    fi
    rm -f "${dest}.part"
    if [[ "$code" == "404" ]]; then
        return 2
    fi
    log "download ${rel} failed: HTTP ${code}"
    return 1
}

storage_upload() {
    local src="$1" rel="$2" code body
    body="$(mktemp)"
    code="$(curl_code PUT "$body" "$(object_url "$rel")" "$src")"
    if [[ "$code" != "201" && "$code" != "200" ]]; then
        log "upload ${rel} failed: HTTP ${code} $(head -c 200 "$body" 2>/dev/null || true)"
        rm -f "$body"
        return 1
    fi
    rm -f "$body"
}

storage_delete() {
    local rel="$1" code
    code="$(curl_code DELETE /dev/null "$(object_url "$rel")")"
    [[ "$code" == "200" || "$code" == "404" || "$code" == "204" ]]
}

storage_list() {
    local rel="${1%/}" url body code
    body="$(mktemp)"
    if [[ -n "$rel" ]]; then
        url="$(object_url "${rel}/")"
    else
        url="$(object_url "")"
    fi
    code="$(curl_code GET "$body" "$url")"
    if [[ "$code" == "404" ]]; then
        rm -f "$body"
        return 2
    fi
    if [[ "$code" != "200" ]]; then
        log "list ${rel:-/} failed: HTTP ${code} $(head -c 200 "$body" 2>/dev/null || true)"
        rm -f "$body"
        return 1
    fi
    if ! jq -e 'type == "array"' "$body" >/dev/null; then
        log "list ${rel:-/} did not return a file index"
        rm -f "$body"
        return 1
    fi
    jq -c '.[]' "$body"
    rm -f "$body"
}

sha256_file() {
    sha256sum "$1" | awk '{print toupper($1)}'
}

release_lock() {
    if [[ "$LOCK_HELD" == "1" ]]; then
        storage_delete "$LOCK_REL" || true
        LOCK_HELD=0
    fi
}

acquire_lock() {
    local now payload got epoch token current
    now="$(date +%s)"
    token="${BUNNYNET_MC_PODID:-local}-$$-${RANDOM}"
    payload="${token}:${now}"
    got="$(mktemp)"
    if storage_download "$LOCK_REL" "$got"; then
        current="$(tr -d '[:space:]' <"$got")"
        epoch="${current##*:}"
        if [[ "$epoch" =~ ^[0-9]+$ ]] && (( now - epoch < LOCK_TTL )); then
            rm -f "$got"
            return 1
        fi
    fi
    rm -f "$got"
    printf '%s' "$payload" > /tmp/acme.lock.payload
    storage_upload /tmp/acme.lock.payload "$LOCK_REL"
    sleep 1
    got="$(mktemp)"
    if ! storage_download "$LOCK_REL" "$got"; then
        rm -f "$got"
        return 1
    fi
    current="$(tr -d '[:space:]' <"$got")"
    rm -f "$got"
    if [[ "$current" == "$payload" ]]; then
        LOCK_HELD=1
        return 0
    fi
    return 1
}

make_self_signed() {
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 2 -newkey rsa:2048 \
        -keyout "$KEY_PATH" -out "$CERT_PATH" \
        -subj "/CN=${DOMAIN}" >/dev/null 2>&1
    chmod 600 "$KEY_PATH"
    UPLOAD_CERTS=1
    log "created a short-lived self-signed certificate for ${DOMAIN}"
}

cert_is_letsencrypt() {
    local issuer
    [[ -s "$CERT_PATH" ]] || return 1
    issuer="$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null || true)"
    [[ "$issuer" == *"Let's Encrypt"* ]]
}

ensure_local_cert() {
    local tmpc tmpk rc_c=0 rc_k=0
    tmpc="$(mktemp)"
    tmpk="$(mktemp)"
    storage_download "certs/fullchain.cer" "$tmpc" || rc_c=$?
    storage_download "certs/privkey.pem" "$tmpk" || rc_k=$?
    if [[ "$rc_c" -eq 0 && "$rc_k" -eq 0 ]]; then
        if ! cmp -s "$tmpc" "$CERT_PATH" 2>/dev/null || ! cmp -s "$tmpk" "$KEY_PATH" 2>/dev/null; then
            mkdir -p /etc/nginx/ssl
            cp "$tmpc" "$CERT_PATH"
            cp "$tmpk" "$KEY_PATH"
            chmod 600 "$KEY_PATH"
            NGINX_RELOAD=1
            CERT_RELOAD=1
            log "installed certificates from storage"
        fi
        rm -f "$tmpc" "$tmpk"
        return 0
    fi
    rm -f "$tmpc" "$tmpk"
    if [[ "$rc_c" -eq 1 || "$rc_k" -eq 1 ]]; then
        if [[ -s "$CERT_PATH" && -s "$KEY_PATH" ]]; then
            log "keeping the local certificate because the storage download failed"
            return 0
        fi
        log "certificate download failed"
        return 1
    fi
    if [[ ! -s "$CERT_PATH" || ! -s "$KEY_PATH" ]]; then
        make_self_signed
    fi
    return 0
}

acme_excluded() {
    local rel="$1"
    [[ "$rel" == "acme.sh" || "$rel" == acme.sh.* || "$rel" == "http.header" || "$rel" == *.log ]] && return 0
    [[ "$rel" == dnsapi/* || "$rel" == deploy/* || "$rel" == notify/* ]] && return 0
    return 1
}

declare -gA REMOTE_SUMS=()

clear_sums() {
    unset REMOTE_SUMS
    declare -gA REMOTE_SUMS=()
}

index_remote() {
    local prefix="$1" item name isdir sum child list rc=0
    list="$(mktemp)"
    if ! storage_list "$prefix" >"$list"; then
        rc=$?
        rm -f "$list"
        [[ "$rc" -eq 2 ]] && return 0
        return 1
    fi
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        name="$(jq -r '.ObjectName' <<<"$item")"
        isdir="$(jq -r '.IsDirectory' <<<"$item")"
        if [[ "$isdir" == "true" || "$isdir" == "True" || "$isdir" == "1" ]]; then
            child="${prefix}${name}"
            index_remote "${child}/" || return 1
        else
            sum="$(jq -r '.Checksum // ""' <<<"$item" | tr '[:lower:]' '[:upper:]')"
            REMOTE_SUMS["${prefix}${name}"]="$sum"
        fi
    done <"$list"
    rm -f "$list"
}

pull_acme() {
    local key dest rel sum
    clear_sums
    if ! index_remote "acme/"; then
        log "could not read acme/ from storage"
        return 1
    fi
    if [[ ! -v 'REMOTE_SUMS[acme/account.conf]' ]]; then
        return 0
    fi
    for key in "${!REMOTE_SUMS[@]}"; do
        rel="${key#acme/}"
        acme_excluded "$rel" && continue
        dest="${ACME_HOME}/${rel}"
        if [[ -f "$dest" ]]; then
            sum="$(sha256_file "$dest")"
            [[ "$sum" == "${REMOTE_SUMS[$key]}" && -n "${REMOTE_SUMS[$key]}" ]] && continue
        fi
        storage_download "$key" "$dest"
    done
    chmod 700 "$ACME_HOME" || true
    log "restored acme.sh state from storage"
}

push_acme() {
    local file rel key sum
    clear_sums
    if ! index_remote "acme/"; then
        log "not uploading acme.sh state because the zone listing failed"
        return 1
    fi
    while IFS= read -r -d '' file; do
        rel="${file#${ACME_HOME}/}"
        acme_excluded "$rel" && continue
        key="acme/${rel}"
        sum="$(sha256_file "$file")"
        if [[ "${REMOTE_SUMS[$key]:-}" == "$sum" ]]; then
            continue
        fi
        storage_upload "$file" "$key"
    done < <(find "$ACME_HOME" -type f -print0)
}

push_certs() {
    local sum
    [[ "$UPLOAD_CERTS" == "1" ]] || return 0
    [[ -s "$CERT_PATH" && -s "$KEY_PATH" ]] || return 0
    clear_sums
    if ! index_remote "certs/"; then
        log "not uploading certificates because the zone listing failed"
        return 1
    fi
    sum="$(sha256_file "$CERT_PATH")"
    if [[ "${REMOTE_SUMS[certs/fullchain.cer]:-}" != "$sum" ]]; then
        storage_upload "$CERT_PATH" "certs/fullchain.cer"
        log "uploaded certs/fullchain.cer"
    fi
    sum="$(sha256_file "$KEY_PATH")"
    if [[ "${REMOTE_SUMS[certs/privkey.pem]:-}" != "$sum" ]]; then
        storage_upload "$KEY_PATH" "certs/privkey.pem"
        log "uploaded certs/privkey.pem"
    fi
}

install_issued_cert() {
    local acme_dir="${ACME_HOME}/${DOMAIN}_ecc"
    if [[ -s "${acme_dir}/fullchain.cer" && -s "${acme_dir}/${DOMAIN}.key" ]]; then
        if ! cmp -s "${acme_dir}/fullchain.cer" "$CERT_PATH" 2>/dev/null \
            || ! cmp -s "${acme_dir}/${DOMAIN}.key" "$KEY_PATH" 2>/dev/null; then
            cp "${acme_dir}/fullchain.cer" "$CERT_PATH"
            cp "${acme_dir}/${DOMAIN}.key" "$KEY_PATH"
            chmod 600 "$KEY_PATH"
            NGINX_RELOAD=1
            CERT_RELOAD=1
            UPLOAD_CERTS=1
            log "installed the issued certificate for ${DOMAIN}"
        fi
        return 0
    fi
    return 1
}

issue_allowed() {
    local now last got
    if cert_is_letsencrypt; then
        return 0
    fi
    got="$(mktemp)"
    last=0
    if storage_download "$ISSUE_REL" "$got"; then
        last="$(tr -d '[:space:]' <"$got")"
    fi
    rm -f "$got"
    now="$(date +%s)"
    if [[ "$last" =~ ^[0-9]+$ ]] && (( now - last < ISSUE_RETRY )); then
        log "Let's Encrypt retry waits until 12 hours after the last failed attempt"
        return 1
    fi
    return 0
}

mark_issue_attempt() {
    local now
    now="$(date +%s)"
    printf '%s' "$now" > /tmp/issue-attempt
    storage_upload /tmp/issue-attempt "$ISSUE_REL" || true
}

run_acme() {
    local acme="${ACME_HOME}/acme.sh"
    export BUNNY_API_KEY
    if [[ "${DNS_MAGIC_SKIP_ACME:-}" == "1" ]]; then
        log "DNS_MAGIC_SKIP_ACME=1, skipping Let's Encrypt"
        if [[ ! -s "$CERT_PATH" || ! -s "$KEY_PATH" ]]; then
            make_self_signed
        fi
        return 0
    fi
    if [[ ! -s "${ACME_HOME}/account.conf" ]]; then
        if ! "$acme" --register-account -m "$EMAIL" --server letsencrypt --home "$ACME_HOME"; then
            log "Let's Encrypt account registration failed"
            make_self_signed
            return 0
        fi
    fi
    if cert_is_letsencrypt; then
        "$acme" --cron --home "$ACME_HOME" || log "certificate renewal check failed"
    elif issue_allowed; then
        mark_issue_attempt
        if "$acme" --issue --dns dns_bunny -d "$DOMAIN" --keylength ec-256 \
            --server letsencrypt --home "$ACME_HOME"; then
            log "Let's Encrypt issued a certificate for ${DOMAIN}"
        else
            log "Let's Encrypt failed for ${DOMAIN}"
            if [[ ! -s "$CERT_PATH" || ! -s "$KEY_PATH" ]]; then
                make_self_signed
            fi
        fi
    elif [[ ! -s "$CERT_PATH" || ! -s "$KEY_PATH" ]]; then
        make_self_signed
    fi
    install_issued_cert || true
    if ! cert_is_letsencrypt && [[ ! -s "$CERT_PATH" ]]; then
        make_self_signed
    fi
}

render_nginx_from() {
    local template="$1" out="$2"
    envsubst '$DOMAIN' <"$template" >"$out"
}

render_info_page() {
    local rendered="/var/www/dns-magic/index.html"
    local tmp
    mkdir -p /var/www/dns-magic
    # The entrypoint uses umask 077 for the env file. Nginx workers run as
    # www-data and must be able to read this page.
    chmod 755 /var/www /var/www/dns-magic
    tmp="$(mktemp)"
    envsubst '$DOMAIN' < /opt/dns-magic/index.html.template >"$tmp"
    if ! cmp -s "$tmp" "$rendered"; then
        mv "$tmp" "$rendered"
        log "rendered the info page for ${DOMAIN}"
    else
        rm -f "$tmp"
    fi
    chmod 644 "$rendered"
}

nginx_ok() {
    local conf="$1"
    nginx -t -c "$conf" >/tmp/nginx-test.out 2>&1
}

sync_unbound() {
    local tmp rc=0
    tmp="$(mktemp)"
    storage_download "config/unbound.conf" "$tmp" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        if unbound-checkconf "$tmp" >/tmp/unbound-check.out 2>&1; then
            if ! cmp -s "$tmp" "$UNBOUND_CONF"; then
                cp "$tmp" "$UNBOUND_CONF"
                UNBOUND_RELOAD=1
                log "updated unbound.conf from storage"
            fi
        else
            log "rejected config/unbound.conf, keeping the current file"
            cat /tmp/unbound-check.out >&2 || true
        fi
    elif [[ "$rc" -eq 2 ]]; then
        storage_upload "$UNBOUND_CONF" "config/unbound.conf"
        log "uploaded default config/unbound.conf"
    else
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

sync_nginx_template() {
    local tmp rendered rc=0
    tmp="$(mktemp)"
    rendered="$(mktemp)"
    storage_download "config/nginx.conf.template" "$tmp" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        render_nginx_from "$tmp" "$rendered"
        if nginx_ok "$rendered"; then
            if ! cmp -s "$tmp" "$NGINX_TEMPLATE"; then
                cp "$tmp" "$NGINX_TEMPLATE"
                log "updated nginx.conf.template from storage"
            fi
            if ! cmp -s "$rendered" "$NGINX_CONF" 2>/dev/null; then
                cp "$rendered" "$NGINX_CONF"
                NGINX_RELOAD=1
            fi
        else
            log "rejected config/nginx.conf.template, keeping the current file"
            cat /tmp/nginx-test.out >&2 || true
            if [[ ! -s "$NGINX_CONF" ]]; then
                render_nginx_from "$NGINX_TEMPLATE" "$NGINX_CONF"
            fi
        fi
    elif [[ "$rc" -eq 2 ]]; then
        storage_upload "$NGINX_TEMPLATE" "config/nginx.conf.template"
        render_nginx_from "$NGINX_TEMPLATE" "$NGINX_CONF"
        log "uploaded default config/nginx.conf.template"
    else
        rm -f "$tmp" "$rendered"
        return 1
    fi
    rm -f "$tmp" "$rendered"
}

restore_default_if_broken() {
    if ! unbound-checkconf "$UNBOUND_CONF" >/dev/null 2>&1; then
        cp /opt/dns-magic/unbound.conf "$UNBOUND_CONF"
        log "restored the image unbound.conf because the local file is invalid"
    fi
    if [[ ! -s "$NGINX_TEMPLATE" ]]; then
        cp /opt/dns-magic/nginx.conf.template "$NGINX_TEMPLATE"
    fi
}

reload_services() {
    [[ -S /var/run/supervisor.sock ]] || return 0
    if [[ "$CERT_RELOAD" == "1" ]]; then
        supervisorctl restart unbound || log "unbound restart failed"
        log "restarted unbound to load the certificate"
    elif [[ "$UNBOUND_RELOAD" == "1" ]]; then
        supervisorctl signal HUP unbound || log "unbound reload failed"
        log "reloaded unbound"
    fi
    if [[ "$NGINX_RELOAD" == "1" ]]; then
        if nginx -t >/dev/null 2>&1; then
            nginx -s reload || log "nginx reload failed"
            log "reloaded nginx"
        else
            log "nginx -t failed, left the running server in place"
        fi
    fi
}

renew_under_lock() {
    local tries="${1:-1}" i
    for ((i = 1; i <= tries; i++)); do
        if acquire_lock; then
            if ! pull_acme; then
                log "skipping certificate publication because acme.sh state could not be read"
                release_lock
                return 0
            fi
            if ! ensure_local_cert; then
                log "skipping certificate publication because certificates could not be read"
                release_lock
                return 0
            fi
            run_acme
            push_certs
            push_acme
            release_lock
            return 0
        fi
        if ((i < tries)); then
            log "certificate lock is busy, retry ${i}/${tries}"
            sleep 10
        fi
    done
    log "another instance holds the certificate lock"
    ensure_local_cert || true
}

probe_storage() {
    local body code
    body="$(mktemp)"
    code="$(curl_code GET "$body" "$(object_url "")")"
    rm -f "$body"
    case "$code" in
        200|404) return 0 ;;
    esac
    log "storage connection failed: HTTP ${code}. Check the zone name, password and region."
    log "Storage variables present: $(storage_names)"
    exit 1
}

sync_all() {
    local lock_tries="$1"
    probe_storage
    render_info_page
    restore_default_if_broken
    ensure_local_cert || true
    sync_unbound
    sync_nginx_template
    renew_under_lock "$lock_tries"
    if [[ ! -s "$NGINX_CONF" ]]; then
        render_nginx_from "$NGINX_TEMPLATE" "$NGINX_CONF"
    fi
    if ! nginx_ok "$NGINX_CONF"; then
        log "rendered nginx.conf failed nginx -t, restoring the image template"
        cat /tmp/nginx-test.out >&2 || true
        cp /opt/dns-magic/nginx.conf.template "$NGINX_TEMPLATE"
        render_nginx_from "$NGINX_TEMPLATE" "$NGINX_CONF"
        nginx_ok "$NGINX_CONF"
    fi
}

main() {
    local mode="${1:-}"
    exec 9>/var/lock/dns-magic-sync.lock
    if ! flock -n 9; then
        log "storage sync is already running"
        exit 0
    fi
    trap release_lock EXIT
    load_env
    : "${DOMAIN:?DOMAIN is required}"
    : "${EMAIL:?EMAIL is required}"
    resolve_storage
    case "$mode" in
        bootstrap) sync_all 6 ;;
        cron) sync_all 1 ;;
        *)
            printf 'usage: sync-storage.sh bootstrap|cron\n' >&2
            exit 1
            ;;
    esac
    if [[ "$mode" == "cron" ]]; then
        reload_services
    fi
}

main "$@"

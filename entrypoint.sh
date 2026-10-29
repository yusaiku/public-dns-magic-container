#!/bin/bash
set -euo pipefail

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

: "${DOMAIN:?DOMAIN is required}"
: "${EMAIL:?EMAIL is required}"
: "${BUNNY_API_KEY:?BUNNY_API_KEY is required}"

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
    log "DOMAIN must be the DNS name of this resolver"
    exit 1
fi

if [[ ! "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
    log "EMAIL must be usable for Let's Encrypt"
    exit 1
fi

write_env_file() {
    local name
    umask 077
    : > /etc/dns-magic.env
    for name in \
        DOMAIN EMAIL BUNNY_API_KEY DNS_MAGIC_SKIP_ACME BUNNYNET_MC_PODID \
        BUNNY_STORAGE_ZONE BUNNY_STORAGE_ZONE_NAME BUNNY_STORAGE_USERNAME BUNNY_STORAGE_FTP_USERNAME \
        BUNNY_STORAGE_PASSWORD BUNNY_STORAGE_ACCESS_KEY BUNNY_STORAGE_SECRET BUNNY_STORAGE_FTP_PASSWORD \
        BUNNY_STORAGE_REGION BUNNY_STORAGE_HOSTNAME BUNNY_STORAGE_HOST BUNNY_STORAGE_FTP_HOST \
        BUNNY_STORAGE_ENDPOINT BUNNY_STORAGE_PREFIX BUNNY_STORAGE_CDN_URL \
        STORAGE_ZONE STORAGE_ACCESS_KEY STORAGE_REGION STORAGE_HOSTNAME
    do
        if [[ -n "${!name+x}" ]]; then
            export "$name"
            declare -p "$name" >> /etc/dns-magic.env
        fi
    done
    chmod 600 /etc/dns-magic.env
}

/usr/local/bin/upgrade-packages.sh || log "package upgrade stopped early, continuing with the installed versions"
write_env_file
log "DNS resolver for ${DOMAIN}"
/usr/local/bin/sync-storage.sh bootstrap
log "Starting unbound, haproxy, nginx and the storage sync"
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf

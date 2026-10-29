#!/bin/bash
# On every container start, move Debian packages and acme.sh to the versions
# currently published. A mirror or download failure must not stop the resolver.
set -euo pipefail

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

if [[ "${DNS_MAGIC_SKIP_UPGRADE:-}" == "1" ]]; then
    log "DNS_MAGIC_SKIP_UPGRADE=1, keeping the image package versions"
    exit 0
fi

snapshot() {
    dpkg-query -W -f '${Package}\t${Version}\n' | sort
}

log_tail() {
    local prefix="$1" file="$2"
    tail -n 5 "$file" | while IFS= read -r line; do
        log "${prefix}: ${line}"
    done
}

refresh_trust_anchor() {
    local backup="/var/lib/unbound/root.key.bak"
    if [[ -f /usr/share/dns/root.hints ]]; then
        cp /usr/share/dns/root.hints /etc/unbound/root.hints
    fi
    if [[ ! -f /usr/share/dns/root.key ]]; then
        log "dns-root-data has no root.key, keeping the current trust anchor"
        return 0
    fi
    if [[ -s /var/lib/unbound/root.key ]]; then
        cp -a /var/lib/unbound/root.key "$backup"
    fi
    cp /usr/share/dns/root.key /var/lib/unbound/root.key
    if timeout 60 unbound-anchor -a /var/lib/unbound/root.key; then
        rm -f "$backup"
        log "refreshed root hints and the DNSSEC trust anchor"
        return 0
    fi
    if [[ -s "$backup" ]]; then
        mv "$backup" /var/lib/unbound/root.key
    fi
    log "unbound-anchor failed, keeping the previous trust anchor"
}

upgrade_acme() {
    local acme="/root/.acme.sh/acme.sh" out had_account=0
    [[ -x "$acme" ]] || return 0
    [[ -s /root/.acme.sh/account.conf ]] && had_account=1
    out="$(mktemp)"
    if timeout 120 "$acme" --upgrade --home /root/.acme.sh >"$out" 2>&1; then
        log "acme.sh upgrade finished"
    else
        log "acme.sh upgrade failed, keeping the installed copy"
        log_tail "acme.sh" "$out"
    fi
    rm -f "$out"
    # Upgrade runs before the storage sync restores the real account.
    if [[ "$had_account" == "0" ]]; then
        rm -f /root/.acme.sh/account.conf
    fi
    crontab -r 2>/dev/null || true
}

before="$(mktemp)"
after="$(mktemp)"
aptlog="$(mktemp)"
snapshot >"$before"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
    -o Acquire::Retries=3
)

log "checking Debian for newer unbound, nginx and the other image packages"
if ! timeout 180 apt-get update -y "${APT_OPTS[@]}" >"$aptlog" 2>&1; then
    log "apt-get update failed, keeping the image package versions"
    log_tail "apt" "$aptlog"
    rm -f "$before" "$after" "$aptlog"
    exit 0
fi

if ! timeout 300 apt-get upgrade -y --with-new-pkgs --no-install-recommends "${APT_OPTS[@]}" >"$aptlog" 2>&1; then
    log "apt-get upgrade failed, continuing with the packages that are installed"
    log_tail "apt" "$aptlog"
fi
rm -f "$aptlog"

snapshot >"$after"
changed=0
declare -A OLD=()
while IFS=$'\t' read -r pkg ver; do
    [[ -n "$pkg" ]] || continue
    OLD["$pkg"]="$ver"
done <"$before"
while IFS=$'\t' read -r pkg ver; do
    [[ -n "$pkg" ]] || continue
    if [[ "${OLD[$pkg]:-}" != "$ver" ]]; then
        log "updated ${pkg} ${OLD[$pkg]:-not installed} -> ${ver}"
        changed=1
    fi
done <"$after"
if [[ "$changed" == "0" ]]; then
    log "unbound, nginx and the other image packages are already current"
fi
log "unbound $(dpkg-query -W -f '${Version}' unbound), nginx $(dpkg-query -W -f '${Version}' nginx)"

apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f "$before" "$after"

refresh_trust_anchor
upgrade_acme

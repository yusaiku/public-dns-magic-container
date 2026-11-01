#!/bin/bash
# Download the DB-IP Country Lite database. A failure leaves DNS running.
# The database is not part of the image. Attribution belongs on the dashboard.
set -euo pipefail

dest=/var/lib/dns-magic/geo/country.mmdb
mkdir -p /var/lib/dns-magic/geo

if [[ -s "$dest" ]]; then
    now="$(date +%s)"
    mtime="$(stat -c %Y "$dest")"
    if (( now - mtime < 25 * 86400 )); then
        exit 0
    fi
fi

fetch_month() {
    local month="$1" tmp new
    tmp="$(mktemp)"
    new="$(mktemp)"
    if ! curl -fsSL --max-time 60 -o "$tmp" "https://download.db-ip.com/free/dbip-country-lite-${month}.mmdb.gz"; then
        rm -f "$tmp" "$new"
        return 1
    fi
    if ! gzip -t "$tmp" || ! gzip -dc "$tmp" >"$new"; then
        rm -f "$tmp" "$new"
        return 1
    fi
    rm -f "$tmp"
    local size
    size="$(wc -c <"$new")"
    if (( size < 100000 )) || ! tail -c 512 "$new" | grep -a -q 'MaxMind.com'; then
        rm -f "$new"
        return 1
    fi
    chmod 644 "$new"
    mv "$new" "$dest"
}

month="$(date -u +%Y-%m)"
if fetch_month "$month"; then
    printf '%s\n' "country database refreshed"
    exit 0
fi
prev="$(date -u -d "${month}-01 -1 month" +%Y-%m)"
if fetch_month "$prev"; then
    printf '%s\n' "country database refreshed"
    exit 0
fi
if [[ -s "$dest" ]]; then
    exit 0
fi
printf '%s\n' "country database unavailable" >&2
exit 1

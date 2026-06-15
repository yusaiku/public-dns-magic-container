#!/bin/bash
set -e

DOMAIN=${DOMAIN:?DOMAIN is required}
EMAIL=${EMAIL:?EMAIL is required}
BUNNY_API_KEY=${BUNNY_API_KEY:?BUNNY_API_KEY is required}

echo "==> Starting DNS Magic Container for domain: $DOMAIN"

# ============================================
# 1. Alten kaputten acme.sh Account löschen
# ============================================
echo "==> Cleaning old/broken acme.sh account data..."
rm -rf /root/.acme.sh/account.conf \
       /root/.acme.sh/ca \
       /root/.acme.sh/*.key 2>/dev/null || true

# ============================================
# 2. Versuche Let's Encrypt Zertifikat
# ============================================
echo "==> Trying to issue/renew Let's Encrypt certificate..."
export BUNNY_API_KEY

/root/.acme.sh/acme.sh --register-account -m "$EMAIL" || true

/root/.acme.sh/acme.sh --issue \
    --dns dns_bunny \
    -d "$DOMAIN" \
    --server letsencrypt \
    --force || echo "Warning: Let's Encrypt issuance failed (rate limit or other error)"

# ============================================
# 3. Fallback: Selbstsigniertes Zertifikat
# ============================================
CERT_PATH="/etc/nginx/ssl/fullchain.cer"
KEY_PATH="/etc/nginx/ssl/privkey.pem"

if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    echo "==> No certificate found. Generating self-signed certificate as fallback..."
    mkdir -p /etc/nginx/ssl

    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$KEY_PATH" \
        -out "$CERT_PATH" \
        -subj "/CN=${DOMAIN}"

    echo "==> Self-signed certificate created."
fi

# ============================================
# 4. Konfigurationen generieren
# ============================================
echo "==> Generating configurations..."
envsubst '$DOMAIN' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# Unbound Config wird direkt verwendet (kein envsubst nötig)

# ============================================
# 5. Dienste starten
# ============================================
echo "==> Starting services..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

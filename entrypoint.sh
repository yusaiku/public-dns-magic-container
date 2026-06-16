#!/bin/bash
set -e

DOMAIN=${DOMAIN:?DOMAIN is required}
EMAIL=${EMAIL:?EMAIL is required}
BUNNY_API_KEY=${BUNNY_API_KEY:?BUNNY_API_KEY is required}

echo "==> Starting DNS Magic Container for domain: $DOMAIN"

# 1. Alten acme.sh Müll löschen
rm -rf /root/.acme.sh/account.conf /root/.acme.sh/ca /root/.acme.sh/*.key 2>/dev/null || true

# 2. Let's Encrypt Zertifikat holen / erneuern
echo "==> Trying to issue/renew Let's Encrypt certificate..."
export BUNNY_API_KEY

/root/.acme.sh/acme.sh --register-account -m "$EMAIL" || true

/root/.acme.sh/acme.sh --issue \
    --dns dns_bunny \
    -d "$DOMAIN" \
    --server letsencrypt || echo "Warning: Let's Encrypt failed"

# 3. Zertifikat nach /etc/nginx/ssl kopieren (falls vorhanden)
CERT_PATH="/etc/nginx/ssl/fullchain.cer"
KEY_PATH="/etc/nginx/ssl/privkey.pem"
ACME_DIR="/root/.acme.sh/${DOMAIN}_ecc"

if [ -f "$ACME_DIR/fullchain.cer" ] && [ -f "$ACME_DIR/${DOMAIN}.key" ]; then
    echo "==> Using Let's Encrypt certificate"
    mkdir -p /etc/nginx/ssl
    cp "$ACME_DIR/fullchain.cer" "$CERT_PATH"
    cp "$ACME_DIR/${DOMAIN}.key" "$KEY_PATH"
else
    echo "==> No Let's Encrypt certificate found. Creating self-signed fallback..."
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=${DOMAIN}"
fi

# 4. Nginx Konfiguration generieren
echo "==> Generating configurations..."
envsubst '$DOMAIN' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# 5. Dienste starten
echo "==> Starting services..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf

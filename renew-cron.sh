#!/bin/bash
# Automatic certificate renewal (runs daily via cron)

DOMAIN=${DOMAIN:?DOMAIN is required}
BUNNY_API_KEY=${BUNNY_API_KEY:?BUNNY_API_KEY is required}

echo "[$(date)] Starting certificate renewal for $DOMAIN..."

export BUNNY_API_KEY

# Renew (acme.sh does nothing if not needed)
/root/.acme.sh/acme.sh --renew -d "$DOMAIN" --force || true

# Re-install certs and reload Nginx
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
    --key-file       /etc/nginx/ssl/privkey.pem \
    --fullchain-file /etc/nginx/ssl/fullchain.cer \
    --reloadcmd      "nginx -s reload || true"

echo "[$(date)] Renewal completed."
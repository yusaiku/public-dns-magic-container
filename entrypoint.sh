#!/bin/bash
set -e

# Required environment variables (set these in Bunny.net or docker-compose)
DOMAIN=${DOMAIN:?DOMAIN environment variable is required}
EMAIL=${EMAIL:?EMAIL environment variable is required}
BUNNY_API_KEY=${BUNNY_API_KEY:?BUNNY_API_KEY environment variable is required}

echo "==> [$(date)] Starting DNS Magic Container for domain: $DOMAIN"

# 1. Ensure acme.sh account exists
if [ ! -f /root/.acme.sh/account.conf ]; then
    echo "==> Registering acme.sh account..."
    /root/.acme.sh/acme.sh --register-account -m "$EMAIL"
fi

# 2. Issue or renew certificate using Bunny DNS challenge
CERT_PATH="/etc/nginx/ssl/fullchain.cer"
if [ ! -f "$CERT_PATH" ] || [ "$(find "$CERT_PATH" -mtime +60)" ]; then
    echo "==> Issuing/Renewing Let's Encrypt certificate for $DOMAIN via Bunny DNS..."
    export BUNNY_API_KEY
    /root/.acme.sh/acme.sh --issue --dns dns_bunny -d "$DOMAIN" --server letsencrypt --force || true
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file       /etc/nginx/ssl/privkey.pem \
        --fullchain-file /etc/nginx/ssl/fullchain.cer \
        --reloadcmd      "nginx -s reload || true"
fi

# 3. Generate configs from templates using environment variables
echo "==> Generating Nginx and Knot configurations..."
envsubst < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
envsubst < /etc/knot-resolver/knot-config.yaml.template > /etc/knot-resolver/config.yaml

# 4. Start services with Supervisor
echo "==> Starting services..."
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
#!/bin/bash

echo "[$(date)] Starting certificate renewal check..."

# acme.sh Renewal ausführen
/root/.acme.sh/acme.sh --cron --home /root/.acme.sh

DOMAIN="dns.x1.to"
ACME_DIR="/root/.acme.sh/${DOMAIN}_ecc"
CERT_PATH="/etc/nginx/ssl/fullchain.cer"
KEY_PATH="/etc/nginx/ssl/privkey.pem"

# Wenn ein neues Zertifikat vorhanden ist → kopieren und Nginx neu laden
if [ -f "$ACME_DIR/fullchain.cer" ] && [ -f "$ACME_DIR/${DOMAIN}.key" ]; then
    echo "[$(date)] Copying renewed certificate..."
    cp "$ACME_DIR/fullchain.cer" "$CERT_PATH"
    cp "$ACME_DIR/${DOMAIN}.key" "$KEY_PATH"

    echo "[$(date)] Reloading Nginx..."
    nginx -s reload

    echo "[$(date)] Certificate renewal completed."
else
    echo "[$(date)] No new certificate to copy."
fi

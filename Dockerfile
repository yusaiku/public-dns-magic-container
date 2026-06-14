FROM debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    knot-resolver \
    nginx \
    supervisor \
    curl \
    ca-certificates \
    cron \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

# acme.sh installieren
RUN curl https://get.acme.sh | sh -s email=placeholder@example.com

# Verzeichnisse anlegen
RUN mkdir -p /etc/nginx/ssl /var/lib/knot-resolver /root/.acme.sh /etc/acme

# Templates und Skripte kopieren
COPY nginx.conf.template /etc/nginx/
COPY knot-config.yaml.template /etc/knot-resolver/
COPY entrypoint.sh /entrypoint.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY renew-cron.sh /usr/local/bin/renew-cron.sh

RUN chmod +x /entrypoint.sh /usr/local/bin/renew-cron.sh

# Cron für automatische Erneuerung (täglich)
RUN echo "0 3 * * * root /usr/local/bin/renew-cron.sh >> /var/log/acme-renew.log 2>&1" > /etc/cron.d/acme-renew && \
    chmod 0644 /etc/cron.d/acme-renew

EXPOSE 80 443 853 8453

ENTRYPOINT ["/entrypoint.sh"]
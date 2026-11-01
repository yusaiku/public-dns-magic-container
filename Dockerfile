FROM debian:13-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        unbound \
        unbound-anchor \
        dns-root-data \
        nginx \
        haproxy \
        supervisor \
        curl \
        ca-certificates \
        cron \
        gettext-base \
        openssl \
        jq \
        gawk \
    && rm -rf /var/lib/apt/lists/*

# The install-time account is removed. Each deployment registers its own.
# crontab -r is the only step that may fail (no crontab yet). A failed download must fail the build.
RUN curl -fsSL https://get.acme.sh -o /tmp/acme-install.sh \
    && sh /tmp/acme-install.sh email=placeholder@example.com \
    && rm -f /tmp/acme-install.sh \
    && test -x /root/.acme.sh/acme.sh \
    && rm -rf /root/.acme.sh/account.conf /root/.acme.sh/ca /root/.acme.sh/*.key \
    && { crontab -r || true; }

RUN mkdir -p /etc/nginx/ssl /etc/unbound /var/lib/unbound /var/lib/dns-magic /var/log/nginx /var/www/dns-magic /opt/dns-magic \
    && cp /usr/share/dns/root.hints /etc/unbound/root.hints \
    && cp /usr/share/dns/root.key /var/lib/unbound/root.key \
    && unbound-anchor -a /var/lib/unbound/root.key

COPY unbound.conf /opt/dns-magic/unbound.conf
COPY nginx.conf.template /opt/dns-magic/nginx.conf.template
COPY index.html.template /opt/dns-magic/index.html.template
COPY doh.mobileconfig.template dot.mobileconfig.template /opt/dns-magic/
COPY unbound.conf /etc/unbound/unbound.conf
COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY haproxy.cfg /etc/haproxy/haproxy.cfg
COPY entrypoint.sh /entrypoint.sh
COPY upgrade-packages.sh /usr/local/bin/upgrade-packages.sh
COPY sync-storage.sh /usr/local/bin/sync-storage.sh
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY dns-magic-sync /etc/cron.d/dns-magic-sync
COPY dns-magic-stats.sh /usr/local/bin/dns-magic-stats.sh
COPY dns-magic-stats.cron /etc/cron.d/dns-magic-stats
COPY no-fastopen.c /tmp/no-fastopen.c

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev \
    && gcc -shared -fPIC -O2 -o /usr/local/lib/no-fastopen.so /tmp/no-fastopen.c -ldl \
    && rm -f /tmp/no-fastopen.c \
    && apt-get purge -y gcc libc6-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

RUN chmod 755 /entrypoint.sh /usr/local/bin/upgrade-packages.sh /usr/local/bin/sync-storage.sh /usr/local/bin/dns-magic-stats.sh \
    && chmod 644 /etc/cron.d/dns-magic-sync /etc/cron.d/dns-magic-stats \
    && openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/privkey.pem \
        -out /etc/nginx/ssl/fullchain.cer \
        -subj "/CN=localhost" \
    && unbound-checkconf /etc/unbound/unbound.conf \
    && DOMAIN=build.invalid envsubst '$DOMAIN' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf \
    && nginx -t \
    && haproxy -c -f /etc/haproxy/haproxy.cfg \
    && bash -n /usr/local/bin/dns-magic-stats.sh \
    && bash -n /usr/local/bin/sync-storage.sh \
    && command -v gawk >/dev/null \
    && DOMAIN=build.invalid envsubst '$DOMAIN' < /opt/dns-magic/index.html.template > /var/www/dns-magic/index.html \
    && DOMAIN=build.invalid envsubst '$DOMAIN' < /opt/dns-magic/doh.mobileconfig.template > /var/www/dns-magic/doh.mobileconfig \
    && DOMAIN=build.invalid envsubst '$DOMAIN' < /opt/dns-magic/dot.mobileconfig.template > /var/www/dns-magic/dot.mobileconfig \
    && grep -q 'https://build.invalid/dns-query' /var/www/dns-magic/index.html \
    && grep -q 'https://build.invalid/dns-query' /var/www/dns-magic/doh.mobileconfig \
    && grep -q '>build.invalid<' /var/www/dns-magic/dot.mobileconfig \
    && rm -f /etc/nginx/nginx.conf /etc/nginx/ssl/privkey.pem /etc/nginx/ssl/fullchain.cer \
        /var/www/dns-magic/index.html /var/www/dns-magic/doh.mobileconfig /var/www/dns-magic/dot.mobileconfig

LABEL org.opencontainers.image.source="https://github.com/yusaiku/public-dns-magic-container" \
      org.opencontainers.image.description="Public DoH and DoT resolver for bunny.net Magic Containers"

EXPOSE 443 853 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=300s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]

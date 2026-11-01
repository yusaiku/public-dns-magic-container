#!/bin/bash
# Grafana on loopback, behind nginx at /stats/.
# The admin password is created on this machine. It is not part of the image.
set -euo pipefail
umask 077

: "${DOMAIN:?DOMAIN is required}"

passfile=/var/lib/dns-magic/grafana-admin
mkdir -p /var/lib/grafana/plugins /var/log/grafana /var/lib/dns-magic \
    /opt/dns-magic/grafana/provisioning/plugins \
    /opt/dns-magic/grafana/provisioning/alerting
if [[ ! -s "$passfile" ]]; then
    openssl rand -hex 24 >"$passfile"
    chmod 600 "$passfile"
fi

export GF_SECURITY_ADMIN_USER=admin
export GF_SECURITY_ADMIN_PASSWORD
GF_SECURITY_ADMIN_PASSWORD="$(<"$passfile")"
export GF_SECURITY_DISABLE_GRAVATAR=true
export GF_SECURITY_X_XSS_PROTECTION=false
export GF_SECURITY_COOKIE_SECURE=true
export GF_SECURITY_COOKIE_SAMESITE=strict

export GF_USERS_ALLOW_SIGN_UP=false
export GF_USERS_DEFAULT_THEME=dark

export GF_AUTH_DISABLE_LOGIN_FORM=true
export GF_AUTH_DISABLE_SIGNOUT_MENU=true
export GF_AUTH_ANONYMOUS_ENABLED=true
export GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
export GF_AUTH_ANONYMOUS_HIDE_VERSION=true

export GF_ANALYTICS_REPORTING_ENABLED=false
export GF_ANALYTICS_CHECK_FOR_UPDATES=false
export GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false
export GF_ANALYTICS_FEEDBACK_LINKS_ENABLED=false

export GF_SNAPSHOTS_EXTERNAL_ENABLED=false
export GF_EXPLORE_ENABLED=false
export GF_UNIFIED_ALERTING_ENABLED=false
export GF_ALERTING_ENABLED=false
export GF_PLUGINS_PLUGIN_ADMIN_ENABLED=false
export GF_NEWS_NEWS_FEED_ENABLED=false
export GF_METRICS_ENABLED=false
export GF_LIVE_MAX_CONNECTIONS=0

export GF_LOG_MODE=console
export GF_LOG_LEVEL=warn
export GF_SERVER_ROUTER_LOGGING=false

export GF_SERVER_PROTOCOL=http
export GF_SERVER_HTTP_ADDR=127.0.0.1
export GF_SERVER_HTTP_PORT=3000
export GF_SERVER_DOMAIN="$DOMAIN"
export GF_SERVER_ROOT_URL="https://${DOMAIN}/stats/"
export GF_SERVER_SERVE_FROM_SUB_PATH=true
export GF_SERVER_ENABLE_GZIP=true
export GF_SERVER_ENFORCE_DOMAIN=false

export GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/opt/dns-magic/grafana/dashboards/doh-dot.json
export GF_DASHBOARDS_MIN_REFRESH_INTERVAL=30s
export GF_PATHS_DATA=/var/lib/grafana
export GF_PATHS_LOGS=/var/log/grafana
export GF_PATHS_PLUGINS=/var/lib/grafana/plugins
export GF_PATHS_PROVISIONING=/opt/dns-magic/grafana/provisioning
export GF_DATABASE_TYPE=sqlite3
export GF_DATABASE_PATH=/var/lib/grafana/grafana.db

exec grafana-server \
    --homepath=/usr/share/grafana \
    --config=/etc/grafana/grafana.ini \
    cfg:default.paths.data=/var/lib/grafana \
    cfg:default.paths.logs=/var/log/grafana \
    cfg:default.paths.plugins=/var/lib/grafana/plugins \
    cfg:default.paths.provisioning=/opt/dns-magic/grafana/provisioning

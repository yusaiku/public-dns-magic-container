#!/bin/bash
# Prometheus on loopback. It scrapes only the public DNS counters.
set -euo pipefail
umask 077
mkdir -p /var/lib/dns-magic/prometheus
exec prometheus \
    --config.file=/opt/dns-magic/prometheus.yml \
    --storage.tsdb.path=/var/lib/dns-magic/prometheus \
    --storage.tsdb.retention.time=24h \
    --web.listen-address=127.0.0.1:9090 \
    --log.level=warn

# DNS Magic Container

Ein vollständiges und wartbares Docker-Setup für einen öffentlichen DNS-Resolver (DoH + DoT) auf **Bunny.net Magic Containers**.

## Features

- **Unbound** als rekursiver DNS-Resolver (direkt zu den Root-Servern)
- **Nginx** als Reverse Proxy und TLS-Terminator für DoH (Port 443) und DoT (Port 853)
- Automatische **Let's Encrypt** Zertifikate über Bunny DNS-Challenge
- Fallback auf selbstsignierte Zertifikate bei Rate Limits
- Stabiler Betrieb durch **Supervisor**
- Einfach erweiterbar mit Monitoring (Prometheus + Grafana)
- Optimiert für Bunny.net Magic Containers

## Voraussetzungen

- Docker
- Ein Bunny.net Account mit Magic Containers
- Eine Domain, die du für den Resolver nutzen möchtest

## Environment Variables

| Variable          | Beschreibung                              | Erforderlich |
|-------------------|-------------------------------------------|--------------|
| `DOMAIN`          | Deine Domain (z. B. `dns.example.com`)    | Ja           |
| `EMAIL`           | E-Mail-Adresse für Let's Encrypt          | Ja           |
| `BUNNY_API_KEY`   | Bunny.net DNS API Key                     | Ja           |

## Schnellstart

### 1. Image bauen und pushen

```bash
docker build -t ghcr.io/dein-username/dns-magic:latest .
docker push ghcr.io/dein-username/dns-magic:latest

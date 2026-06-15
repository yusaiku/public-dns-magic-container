# DNS Magic Container for Bunny.net

Ein vollständiges und einfach einsetzbares Docker-Setup für einen **öffentlichen DNS-Resolver** (DoH + DoT) auf **Bunny.net Magic Containers**.

## Features

- **Unbound** als rekursiver DNS-Resolver (direkt zu den Root-Servern)
- **Nginx** als Reverse Proxy + TLS-Terminator für DoH und DoT
- Automatische **Let's Encrypt** Zertifikate via Bunny DNS-Challenge
- Fallback auf selbstsignierte Zertifikate bei Rate Limits
- Stabiler Betrieb durch Supervisor
- Einfach erweiterbar mit Monitoring (Prometheus + Grafana)

## Environment Variables

| Variable          | Beschreibung                              | Erforderlich |
|-------------------|-------------------------------------------|--------------|
| `DOMAIN`          | Deine Domain (z. B. `dns.example.com`)    | Ja           |
| `EMAIL`           | E-Mail-Adresse für Let's Encrypt          | Ja           |
| `BUNNY_API_KEY`   | Bunny.net DNS API Key                     | Ja           |

## Volumes (empfohlen)

| Volume Name      | Mount Path           | Beschreibung                              | Empfehlung     |
|------------------|----------------------|-------------------------------------------|----------------|
| `certs`          | `/etc/nginx/ssl`     | Speichert die SSL-Zertifikate             | **Pflicht**    |
| `unbound-data`   | `/etc/unbound`       | Persistenter Cache von Unbound (optional) | Optional       |

## Ports / Endpoints (in Bunny)

| Port | Protokoll | Verwendung          | Empfehlung      |
|------|-----------|---------------------|-----------------|
| 443  | TCP       | DoH + Web           | Öffnen          |
| 853  | TCP       | DoT                 | Öffnen          |

> **Hinweis:** Port 53 wird bewusst nicht öffentlich exposed (Schutz vor Missbrauch).

## Deployment auf Bunny.net Magic Containers

### 1. Image bauen und pushen

```bash
docker build -t ghcr.io/dein-username/dns-magic:latest .
docker push ghcr.io/dein-username/dns-magic:latest

2. Container in Bunny erstellen

Gehe zu Magic Containers → Add App

Klicke auf Add Container

Wähle dieses Image aus dem GitHub Container Registry


Test von dein PC aus für DoT:
Bash: dig @deine-domain.com +tls google.com

Test von dein PC aus für DoH:
Bash: curl -H "accept: application/dns-message" \
  "https://deine-domain.com/dns-query?name=google.com"
  
Healthcheck
Bash: curl -k https://deine-domain.com/health


Monitoring (optional)
Du kannst Prometheus und Grafana als weitere Container in derselben App hinzufügen.

Prometheus: Nutze ein eigenes Image mit der Scrape-Konfiguration für Unbound (Port 8953)
Grafana: Offizielles Image (grafana/grafana)

Hinweise

Bei Let's Encrypt Rate Limits wird automatisch ein selbstsigniertes Zertifikat verwendet.
Das Rate Limit für Zertifikate erneuert sich wöchentlich.
Unbound ist für volle rekursive Auflösung konfiguriert.

# DNS Magic Container for Bunny.net

A complete, production-ready Docker setup for running a **public DNS resolver** (DoH + DoT) on Bunny.net Magic Containers.

## Features
- **Knot Resolver** — Recursive resolver directly querying root servers + DNSSEC enabled
- **Nginx** — TLS termination for DoH (port 443) and DoT (port 853)
- **Automatic Let's Encrypt certificates** via Bunny DNS challenge
- **Automatic renewal** (daily via cron)
- **Supervisor** for stable process management
- **Prometheus metrics** exposed internally on port 8453
- Fully configurable via environment variables (no manual config editing needed)

Perfect for Bunny.net Magic Containers — deploy globally with just a few clicks.

## Required Environment Variables

| Variable          | Description                              | Required |
|-------------------|------------------------------------------|----------|
| `DOMAIN`          | Your domain (e.g. `dns.example.com`)     | Yes      |
| `EMAIL`           | Email for Let's Encrypt account          | Yes      |
| `BUNNY_API_KEY`   | Bunny.net DNS API Key                    | Yes      |

## Quick Start

### 1. Build and Push the Image

```bash
docker build -t ghcr.io/YOUR_USERNAME/dns-magic:latest .
docker push ghcr.io/YOUR_USERNAME/dns-magic:latest
```

### 2. Deploy on Bunny.net Magic Containers

1. Go to [dash.bunny.net](https://dash.bunny.net) → **Magic Containers**
2. Click **+ Add App**
3. Choose **Magic deployment** (recommended)
4. Click **Create**
5. Click **Add Container**
6. Select your registry and image (`ghcr.io/YOUR_USERNAME/dns-magic:latest`)
7. Add the following **Environment Variables**:
   - `DOMAIN` = your domain
   - `EMAIL` = your email
   - `BUNNY_API_KEY` = your Bunny DNS API key
8. Configure **Endpoints**:
   - Port **443** → HTTP/HTTPS (DoH)
   - Port **853** → TCP (DoT)
9. (Recommended) Add **Volumes**:
   - `certs` → `/etc/nginx/ssl`
   - `knot-data` → `/var/lib/knot-resolver`
10. Click **Deploy**

The container will automatically obtain a valid certificate on first start.

## Testing

**DoH:**
```bash
curl -H "accept: application/dns-message" \
  "https://your-domain.com/dns-query?name=example.com"
```

**DoT:**
```bash
kdig @your-domain.com +tls example.com
```

**Health Check:**
`https://your-domain.com/health`

**Metrics (Prometheus format):**
`http://your-app.bunny.run:8453/metrics`

## Local Testing

```bash
docker compose up --build
```

Edit `.env` or the `environment` section in `docker-compose.yml` with your values.

## Adding Monitoring (Optional)

You can add Prometheus and Grafana as additional containers in the **same Magic Container app** (they share the pod and can communicate via `localhost`).

## Updating

Simply build and push a new image version, then redeploy in Bunny.net.

## Notes

- The setup uses **Bunny DNS challenge** for certificate issuance (no port 80 required after initial setup).
- Certificates are automatically renewed daily.
- All configuration is driven by environment variables.
- Works great with Bunny.net Anycast IPs.

---

**Made to be reusable** — just set your own `DOMAIN`, `EMAIL`, and `BUNNY_API_KEY` when deploying.
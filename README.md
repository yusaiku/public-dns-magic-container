# DNS Magic Container

Öffentlicher DNS-Resolver (DoH und DoT) für bunny.net Magic Containers. Das Image enthält keine feste Domain. `DOMAIN` setzt du beim Container.

## Variablen

| Variable | Bedeutung |
|---|---|
| `DOMAIN` | Name, unter dem der Resolver erreichbar ist |
| `EMAIL` | Adresse für das Let's-Encrypt-Konto |
| `BUNNY_API_KEY` | Account-API-Key. acme.sh legt damit den DNS-01-TXT-Eintrag an. Die DNS-Zone der Domain muss bei bunny.net liegen. |
| Connect Storage | Legt `BUNNY_STORAGE_ZONE`, `BUNNY_STORAGE_PASSWORD` und `BUNNY_STORAGE_REGION` an |

`BUNNY_API_KEY` und das Storage-Passwort sind zwei verschiedene Schlüssel. Connect Storage ersetzt den DNS-API-Key nicht.

Optional: `BUNNY_STORAGE_PREFIX`, wenn mehrere Apps dieselbe Zone nutzen. Leer heißt Zone-Wurzel.

`DNS_MAGIC_SKIP_ACME=1` lässt Let's Encrypt aus und bleibt bei einem selbstsignierten Zertifikat. Nur für einen lokalen Test.

`DNS_MAGIC_SKIP_UPGRADE=1` überspringt die Paketaktualisierung beim Start. Nur für einen lokalen Test ohne Zugang zu den Debian-Spiegeln.

## Updates beim Start

Jeder Start des Containers, auch ein Neustart, holt zuerst die aktuellen Pakete aus Debian. Dazu gehören Unbound, Nginx, HAProxy, die mitinstallierten Bibliotheken und die CA-Zertifikate. Anschließend wird acme.sh aktualisiert, und Root-Hints sowie der DNSSEC-Trust-Anchor werden neu geladen. Unbound, HAProxy und Nginx starten erst danach, also mit den neuen Programmen.

Die Konfiguration aus der Storage Zone wird nach dem Update geladen. Eine neue Paketversion ersetzt `unbound.conf` und die Nginx-Vorlage nicht.

Ist der Debian-Spiegel oder GitHub nicht erreichbar, startet der Resolver mit den Versionen aus dem Image. Der Neustart bleibt damit nicht an einem Update hängen.

## Dateien in der Storage Zone

| Pfad | Richtung |
|---|---|
| `config/unbound.conf` | Zone nach Container. Beim ersten Start wird die mitgelieferte Datei hochgeladen. |
| `config/nginx.conf.template` | Zone nach Container. `${DOMAIN}` wird beim Laden eingesetzt. |
| `certs/fullchain.cer`, `certs/privkey.pem` | beide Richtungen |
| `acme/` | beide Richtungen. Konto und ausgestellte Zertifikate, ohne das acme.sh-Programm. |

Alle fünf Minuten prüft der Container die Zone. Eine geänderte `unbound.conf` wird nur übernommen, wenn `unbound-checkconf` erfolgreich ist. Eine geänderte Nginx-Vorlage nur, wenn `nginx -t` erfolgreich ist. Eine ungültige Datei bleibt in der Zone liegen, der laufende Resolver behält die letzte gültige Konfiguration.

Zertifikate schreibt der Container nach der Ausstellung oder Erneuerung zurück. Ein Pod übernimmt die Ausstellung, die anderen lesen das Ergebnis. Schlägt Let's Encrypt fehl, startet Unbound mit einem zwei Tage gültigen selbstsignierten Zertifikat und versucht es frühestens nach 12 Stunden erneut.

## Deploy

```bash
docker build --platform linux/amd64 -t ghcr.io/USER/dns-magic:latest .
docker push ghcr.io/USER/dns-magic:latest
```

Im Magic Container:

1. Image auswählen.
2. `DOMAIN`, `EMAIL` und `BUNNY_API_KEY` setzen.
3. **Connect Storage** auf eine Zone ohne Pull Zone.
4. Endpunkt für DoH: Anycast, Container-Port `443`, Exposed Port `443`.
5. Endpunkt für DoT: Anycast, Container-Port `853`, Exposed Port `853`.
6. Healthcheck: `http://<container>:8080/health` antwortet mit `OK`.

Nginx beendet TLS auf Port 443. Ein Browser auf `https://DOMAIN/` sieht eine Infoseite. `POST` und `GET` auf `/dns-query` gehen als DoH an Unbound. DoT auf Port 853 spricht Unbound direkt. Ein CDN-Endpunkt davor puffert oder cacht DNS-Anfragen.

Die Infoseite liegt im Image und wird beim Start mit `DOMAIN` gefüllt. Sie steht nicht in der Storage Zone.

Liegt in der Zone noch eine ältere `unbound.conf`, in der Unbound selbst Port 443 belegt, gilt diese Datei weiter. Für die Infoseite muss Unbound DoH nur auf `127.0.0.1@4443` mit `http-notls-downstream: yes` anbieten, und die Nginx-Vorlage muss Port 443 selbst bedienen. HAProxy auf `127.0.0.1:4444` übersetzt das HTTP/1.1 von Nginx in das HTTP/2 von Unbound.

Die Domain zeigt per A/AAAA oder CNAME auf den Endpunkt. Für das Zertifikat reicht die DNS-Zone bei bunny.net, der A-Eintrag darf später gesetzt werden.

Keine Pull Zone an diese Storage Zone hängen. `privkey.pem` und das acme.sh-Konto liegen dort im Klartext. Wer die Zone öffnen kann, kann den Schlüssel lesen. Über eine Pull Zone wäre er öffentlich abrufbar.

## Lokal

```bash
export DOMAIN=dns.example.com
export EMAIL=you@example.com
export BUNNY_API_KEY=...
export BUNNY_STORAGE_ZONE=...
export BUNNY_STORAGE_PASSWORD=...
export BUNNY_STORAGE_REGION=de
docker compose up --build
```

Seite: `https://DOMAIN/`

DoH: `curl --http2 -H 'accept: application/dns-message' 'https://DOMAIN/dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB'`

DoT: `dig @DOMAIN -p 853 +tls example.com`

## Grenzen

Eine Änderung in Manage Storage Zones ist nach dem nächsten Sync im Container, spätestens nach fünf Minuten. Schreiben Zone und Container dieselbe Datei, gilt der letzte Upload.

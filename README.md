# Baue deinen eigenen öffentlichen, unzensierten DNS-Resolver

Ein eigener zensurfreier DNS-Resolver auf [bunny.net Magic Containers](https://bunny.net/magic-containers/). Du brauchst keinen eigenen Server. Du setzt einen Namen, und der Container beantwortet DNS-Anfragen verschlüsselt, ohne Namen zu sperren und ohne die Abfragen mitzuschreiben.

Das fertige Image liegt öffentlich unter `ghcr.io/yusaiku/dns-magic:latest`. Eine eigene Domain trägst du erst beim Container ein.

## Was du damit bekommst

- **DNS-over-HTTPS** auf Port `443`, Pfad `/dns-query`. Das nutzen Brave, Chrome und Firefox.
- **Eine Infoseite** auf `https://dein-name/`. Sie erklärt die beiden Adressen. DNS-Anfragen laufen nicht über diese Seite.
- **DNS-over-TLS** auf Port `853`. Das nutzen Android („Privates DNS“) und `dig`.
- **Zensurfrei.** Der Resolver fragt die Root-Server des DNS und danach den zuständigen Nameserver. Er leitet keine Anfrage an Cloudflare, Google oder einen anderen Resolver weiter und sperrt keine Namen.
- **DNSSEC.** Antworten werden geprüft.
- **Keine Protokolle.** DNS-Abfragen werden nicht gespeichert und nicht mitgeschrieben. Das gilt für jeden, der den Resolver nutzt.
- **Ein Zertifikat von Let's Encrypt.** Der Container legt den nötigen DNS-Eintrag selbst an und erneuert das Zertifikat.
- **Konfiguration in einer Storage Zone.** `unbound.conf` und die Nginx-Vorlage kannst du danach im Bunny-Dashboard ändern. Der Container übernimmt eine gültige Datei innerhalb von fünf Minuten.
- **Grenzen gegen Missbrauch.** Ein Absender kann den Resolver nicht unbegrenzt fluten. Die Grenzen stehen unten.

Magic Containers, die Anycast-Adresse und die Storage Zone sind kostenpflichtige Funktionen von bunny.net. Ein Testkonto muss eine Zahlungsart hinterlegt haben, bevor eine App startet.

## Schutz vor Missbrauch

Port `53` ist nur im Container offen. Von außen gibt es DNS nur über TLS, also DoH und DoT. Das Image begrenzt zusätzlich, wie viel ein Absender anfragen kann:

- DoH erlaubt 20 Anfragen pro Sekunde und Adresse, ein kurzer Stoß bis 40. Darüber antwortet der Server mit HTTP `429`.
- Die Infoseite erlaubt 10 Anfragen pro Sekunde und Adresse.
- DoT erlaubt 8 gleichzeitige Verbindungen und 20 neue Verbindungen in 10 Sekunden pro Adresse. Eine Verbindung wird auf 64 KB pro Sekunde gebremst.
- Unbound hält die Zahl offener Anfragen klein, lehnt den Abfragetyp ANY ab und drosselt, wenn derselbe Name zu schnell wiederholt wird.
- Antworten enthalten keine privaten Adressen wie `192.168.0.0/16` oder `10.0.0.0/8`.

Eine normale Nutzung im Browser bleibt unter diesen Grenzen.

## Was du vorher brauchst

1. Ein Konto bei [bunny.net](https://dash.bunny.net).
2. Eine Domain, deren **DNS-Zone bei bunny.net** liegt. Der Registrar zeigt also auf die Nameserver von bunny.net. Nur so kann der Container den Prüfeintrag für das Zertifikat anlegen.
3. Den **Account-API-Key** aus den Kontoeinstellungen. Das ist ein Schlüssel für das ganze Konto. Er ist etwas anderes als das Passwort einer Storage Zone.

Den Namen in dieser Anleitung, `dns.example.com`, ersetzt du durch deinen eigenen. Die Zone wäre dann `example.com`, der Eintrag davor `dns`.

## Anlegen

### 1. DNS-Zone

1. Im Dashboard **DNS** öffnen und **Add DNS Zone** wählen.
2. Die Domain eintragen, zum Beispiel `example.com`.
3. Beim Registrar die Nameserver auf die Werte setzen, die Bunny anzeigt.
4. Warten, bis die Zone bei Bunny als aktiv gilt. Ohne diesen Schritt schlägt das Zertifikat fehl.

Den A-Eintrag für den Resolver legst du erst an, wenn die App läuft und unter Endpoints die Anycast-Adresse steht.

### 2. Storage Zone ohne öffentliche Adresse

1. **Storage** öffnen und eine Zone anlegen.
2. Eine Region nahe an der späteren Container-Region wählen. Für Frankfurt ist das `DE` / Falkenstein.
3. Keine Pull Zone verbinden und keine öffentliche URL einschalten.

In dieser Zone liegen später das Zertifikat und der private Schlüssel im Klartext. Wer die Zone öffnen kann, kann den Schlüssel lesen. Eine Pull Zone würde ihn über das CDN abrufbar machen.

### 3. App anlegen

1. **Magic Containers** öffnen und **+ Add App** wählen.
2. Im Suchfeld `yusaiku/dns-magic` eingeben. Die Registry ist die öffentliche GitHub Container Registry. Ein eigenes Registry-Konto ist dafür nicht nötig.
3. Den Tag `latest` lassen.
4. Dem Container einen kurzen Namen geben, zum Beispiel `dns`.

Magic Containers führt nur Images für `linux/amd64` aus. Das veröffentlichte Image ist bereits dafür gebaut.

### 4. Zwei Anycast-Endpunkte

DNS darf nicht durch ein CDN. Ein CDN-Endpunkt puffert oder speichert Antworten. Lege deshalb **keinen CDN-Endpunkt** an und schalte kein „SSL for origin“ ein. TLS beendet der Container selbst.

Lege zwei Endpunkte vom Typ **Anycast IP** an:

| Name | Container Port | Exposed Port, falls das Feld da ist |
|---|---|---|
| `doh` | `443` | `443` |
| `dot` | `853` | `853` |

Port `8080` nicht veröffentlichen. Den nutzt nur der Healthcheck innerhalb von Bunny.

Wenn das Formular wegen der im Image genannten Ports schon einen Endpunkt vorschlägt, prüfe Typ und Port, bevor du ihn übernimmst.

### 5. Keine Volumes

Unter **Persistent volumes** nichts eintragen. Die Daten liegen in der Storage Zone. Ein Volume auf `/etc/unbound` würde die Konfiguration aus dem Image verdecken.

### 6. Variablen

Trage diese drei Werte unter **Environment variables** ein. **+ Variable** oder der **Raw editor** tun dasselbe.

| Name | Wert |
|---|---|
| `DOMAIN` | `dns.example.com` |
| `EMAIL` | deine E-Mail-Adresse für das Let's-Encrypt-Konto |
| `BUNNY_API_KEY` | der Account-API-Key aus den Kontoeinstellungen |

`DOMAIN` ist ein voller DNS-Name mit Punkt, also `dns.example.com` und nicht nur `dns`.

Danach **Connect Storage** öffnen, die Zone aus Schritt 2 auswählen oder dort neu anlegen. Bunny setzt dann selbst `BUNNY_STORAGE_ZONE`, `BUNNY_STORAGE_PASSWORD` und `BUNNY_STORAGE_REGION`. Diese Einträge nicht löschen und nicht mit dem Account-API-Key überschreiben. Das Storage-Passwort und `BUNNY_API_KEY` sind zwei verschiedene Schlüssel.

Siehst du **Connect Storage** nicht, öffne die Storage Zone, dort **Access** und **API / HTTP**, und trage die Werte von Hand ein:

| Name | Wert |
|---|---|
| `BUNNY_STORAGE_ZONE` | Name der Zone |
| `BUNNY_STORAGE_PASSWORD` | Passwort aus Access, API / HTTP |
| `BUNNY_STORAGE_REGION` | Region der Zone, für Frankfurt `de` |
| `BUNNY_STORAGE_HOSTNAME` | der angezeigte Storage-Host, meist `storage.bunnycdn.com` |

### 7. Region und Start

1. Der App einen Namen geben, zum Beispiel `dns`.
2. **Eine** Region wählen, möglichst dieselbe Gegend wie die Storage Zone.
3. **Deploy** klicken.

Eine Instanz reicht. Weitere Instanzen teilen sich dieselbe Storage Zone. Ein Pod kümmert sich um das Zertifikat, die anderen lesen es.

### 8. Healthcheck

Wenn die App steht: **Container Settings**, **Edit**, Reiter **Monitoring**.

Für **Startup**, **Readiness** und **Liveness**:

- Methode: **HTTP GET**
- Port: `8080`
- Pfad: `/health`

Der Pfad antwortet mit `OK`. Der erste Start dauert einige Minuten, weil Pakete aktualisiert werden und das Zertifikat ausgestellt wird. Schlägt der Check in dieser Zeit fehl und startet der Container immer wieder neu, die erlaubten Fehlversuche oder die Startverzögerung anheben, falls das Formular diese Felder zeigt.

### 9. DNS-Eintrag

In der App unter **Endpoints** steht nach dem Start eine Anycast-Adresse. Beide Ports nutzen dieselbe Adresse. Das ist so vorgesehen.

In der DNS-Zone aus Schritt 1 einen A-Eintrag anlegen:

| Feld | Beispiel |
|---|---|
| Name | `dns`, wenn `DOMAIN` gleich `dns.example.com` ist |
| Typ | `A` |
| Wert | die Anycast-Adresse |
| TTL | `300` |

Liegt der Resolver direkt auf der Zone, also `DOMAIN` ist `example.com`, bleibt der Name leer. Eine AAAA-Adresse nur eintragen, wenn Bunny eine IPv6-Adresse anzeigt.

Das Zertifikat braucht diesen A-Eintrag nicht. Es braucht die Zone und den Account-API-Key. Besucher und Endgeräte brauchen den A-Eintrag, sonst finden sie den Resolver nicht.

## Prüfen

Der erste Start braucht ein paar Minuten. Im Log der App erscheinen nacheinander der Name des Resolvers, die hochgeladenen Standarddateien und danach eine Zeile, dass Let's Encrypt ein Zertifikat ausgestellt hat. Kurz davor kann ein selbstsigniertes Zertifikat im Einsatz sein. Lädt die Seite mit einer Zertifikatswarnung, zwei Minuten warten und neu laden.

Wenn das Log „Let's Encrypt issued a certificate“ zeigt:

1. `https://dns.example.com/` im Browser öffnen. Die Seite stellt sich als öffentlicher DNS-Resolver vor und nennt beide Adressen.
2. DNS-over-TLS:

```bash
dig @dns.example.com -p 853 +tls example.com
```

3. DNS-over-HTTPS:

```bash
curl --http2 -H 'accept: application/dns-message' \
  'https://dns.example.com/dns-query?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB'
```

Die Antwort ist binär und kurz. Ein Fehler wäre eine HTML-Seite oder ein HTTP-Status außer `200`.

## Beim Gerät eintragen

Die Infoseite sagt dasselbe. Hier die kurze Form:

- **Brave und Chrome:** Einstellungen, Datenschutz und Sicherheit, Sicherheit, Sicheres DNS verwenden, Benutzerdefiniert. Eintragen: `https://dns.example.com/dns-query`
- **Firefox:** Einstellungen, Datenschutz und Sicherheit, DNS über HTTPS, Anbieter auswählen, Benutzerdefiniert. Dieselbe Adresse eintragen.
- **Android:** Einstellungen, Netzwerk und Internet, Privates DNS, Hostname des privaten DNS-Anbieters: `dns.example.com`
- **dig:** `dig @dns.example.com -p 853 +tls example.com`

## Danach etwas ändern

Nach dem ersten erfolgreichen Start liegt in der Storage Zone:

| Pfad | Bedeutung |
|---|---|
| `config/unbound.conf` | Resolver-Konfiguration. Gilt aus der Zone. |
| `config/nginx.conf.template` | Webserver-Vorlage. `${DOMAIN}` wird beim Laden durch deinen Namen ersetzt. |
| `certs/fullchain.cer`, `certs/privkey.pem` | Zertifikat und privater Schlüssel. |
| `acme/` | Konto und ausgestellte Zertifikate von acme.sh, ohne das Programm selbst. |

Alle fünf Minuten liest der Container die Zone. Eine geänderte `unbound.conf` gilt nur, wenn sie gültig ist. Eine geänderte Nginx-Vorlage nur, wenn der Webserver sie annimmt. Eine ungültige Datei bleibt in der Zone, der laufende Resolver behält die letzte gültige Fassung. Im Log steht dann `rejected`.

Schreiben Zone und Container dieselbe Datei, gilt der letzte Upload.

Die Infoseite liegt im Image und wird beim Start aus `DOMAIN` gebaut. Sie steht nicht in der Zone.

`${DOMAIN}` in der Nginx-Vorlage stehen lassen. Der Container setzt den Namen ein.

Beim nächsten Neustart aktualisiert der Container zuerst Unbound, Nginx, HAProxy und die übrigen Pakete, danach acme.sh, die Root-Hints und den DNSSEC-Trust-Anchor. Erst dann lädt er die Dateien aus der Zone. Ist der Debian-Spiegel oder GitHub nicht erreichbar, startet er mit den Versionen aus dem Image.

## Wenn etwas hakt

| Was du siehst | Was du prüfst |
|---|---|
| Storage connection failed | Zonenname, Storage-Passwort und Region. Connect-Storage-Variablen nicht gelöscht. |
| Let's Encrypt failed | Die DNS-Zone liegt bei bunny.net und ist aktiv. `BUNNY_API_KEY` ist der Account-Key, nicht das Storage-Passwort. |
| Der Browser zeigt noch „Not found“ | In `config/unbound.conf` darf Port `443` nicht auf `0.0.0.0` liegen. Die mitgelieferte Datei spricht DoH nur auf `127.0.0.1@4443`. Danach den Container neu starten. |
| Zertifikatswarnung nach einer Viertelstunde | Dieselbe Prüfung wie bei „Let's Encrypt failed“. Bis dahin läuft ein zwei Tage gültiges selbstsigniertes Zertifikat. Der nächste Versuch kommt frühestens nach 12 Stunden. |
| DoH antwortet nicht, die Seite schon | Beide Anycast-Endpunkte prüfen: `443` und `853`, Typ Anycast, kein CDN. |
| Der Container findet die Zone nicht | `BUNNY_STORAGE_HOSTNAME` setzen, meist `storage.bunnycdn.com`. Für Frankfurt darf die Region leer oder `de` sein. |

Ein fehlgeschlagenes Zertifikat wirft das vorhandene Konto nicht weg. Die Standarddateien werden nur hochgeladen, wenn der Pfad in der Zone noch fehlt.

## Variablen

| Variable | Pflicht | Bedeutung |
|---|---|---|
| `DOMAIN` | ja | Name, unter dem der Resolver erreichbar ist |
| `EMAIL` | ja | Adresse für das Let's-Encrypt-Konto |
| `BUNNY_API_KEY` | ja | Account-API-Key für den DNS-01-Eintrag |
| `BUNNY_STORAGE_ZONE` | ja | Name der Storage Zone. Setzt Connect Storage. |
| `BUNNY_STORAGE_PASSWORD` | ja | Passwort dieser Zone. Setzt Connect Storage. |
| `BUNNY_STORAGE_REGION` | meist | Region der Zone, zum Beispiel `de` |
| `BUNNY_STORAGE_HOSTNAME` | meist | Storage-Host, den Bunny anzeigt |
| `BUNNY_STORAGE_PREFIX` | nein | Ordner in der Zone, wenn mehrere Apps sie teilen. Leer heißt Wurzel. |

`DNS_MAGIC_SKIP_ACME=1` und `DNS_MAGIC_SKIP_UPGRADE=1` sind nur für einen lokalen Test. In Magic Containers lässt du beide weg.

## Eigenes Image

Das veröffentlichte Image reicht für den Betrieb. Ein eigenes Image brauchst du nur, wenn du die Infoseite oder die Standardkonfiguration im Image ändern willst.

```bash
docker build --platform linux/amd64 -t ghcr.io/USER/dns-magic:latest .
docker push ghcr.io/USER/dns-magic:latest
```

Beim Anlegen dann dein Image statt `yusaiku/dns-magic` wählen. Ein privates Image braucht vorher eine verbundene GitHub-Registry mit einem Token, das Pakete lesen darf. Öffentliche Images funktionieren ohne diesen Schritt.

## Auf dem eigenen Rechner

Dafür brauchst du dieselben Zugangsdaten wie in Magic Containers, dazu Docker.

```bash
export DOMAIN=dns.example.com
export EMAIL=you@example.com
export BUNNY_API_KEY=...
export BUNNY_STORAGE_ZONE=...
export BUNNY_STORAGE_PASSWORD=...
export BUNNY_STORAGE_REGION=de
docker compose up --build
```

Die Ports am Rechner sind `443`, `853` und `8080`. `http://127.0.0.1:8080/health` antwortet mit `OK`.

# Server: Aufsetzen und Betrieb

Alles läuft in drei Docker-Containern: MediaMTX (WebRTC-Relay), die Website (Node 24 + SQLite) und Caddy (HTTPS mit Let's Encrypt).
Kein Transcoding, der Server reicht Streams nur weiter. Ein kleiner VPS mit 2 vCPU, 2–4 GB RAM reicht. Wichtig ist der Traffic:
pro Zuschauer und laufendem Stream etwa 8 Mbit/s ausgehend (Kamera 2,5 Mbit/s), bei 3 Streams und 6 Zuschauern kommen schnell einige TB im Monat zusammen.

## Voraussetzungen

- Linux-VPS (Debian 12/13 oder Ubuntu 22.04+), Root-Zugang per SSH.
- Eine Domain oder Subdomain, die auf die IP des Servers zeigt (ein kostenloser DynDNS-Dienst reicht).
- Offene Ports: 22/tcp (SSH), 80/tcp und 443/tcp (Caddy), 8189/udp (WebRTC-Medien). Siehe `server/firewall.md`.

## Erstinstallation

```bash
# Variante A: Release-Archiv
apt-get install -y unzip
unzip pommesbude-server.zip -d /opt/pommesbude
# Variante B: git
git clone https://github.com/<owner>/Pommesbude.git /opt/pommesbude

cd /opt/pommesbude
chmod +x server/install.sh
./server/install.sh
```

`install.sh` installiert Docker, fragt Domain, öffentliche IP und den Namen der Website ab (landet in `server/.env`), richtet `ufw` ein,
baut das Website-Image inklusive Client-Paket und startet alles. Danach:

1. `https://<domain>/` öffnen und **registrieren**. Der erste Nutzer ist automatisch freigegeben und kann weitere freischalten.
2. `relay.json` für die Streamer anlegen (Vorlage `relay.example.json`): `{"domain":"<domain>","siteName":"<Name>"}`.
   Diese Datei bekommt jeder Streamer zusammen mit dem Client-Paket (`https://<domain>/client/pommesbude-client.zip`). Sie gehört nicht ins Repo.

## Update des Servers

```bash
# Release-Archiv: neues Archiv ueber den bestehenden Ordner entpacken (server/.env bleibt, sie ist nicht im Archiv)
unzip -o pommesbude-server.zip -d /opt/pommesbude && /opt/pommesbude/server/install.sh
# git:
cd /opt/pommesbude && git pull && ./server/install.sh
```
Das Skript ist idempotent: `.env` bleibt, Nutzerdatenbank bleibt (Docker-Volume `stream-relay_web_data`), Image wird neu gebaut, Container neu gestartet.
Die Datei `VERSION` bestimmt die Client-Version, die der Server anbietet. Nach einem Update melden sich die Launcher der Streamer beim nächsten Start.
`MIN_CLIENT_VERSION` in `web/server.js` anheben, wenn alte Clients nicht mehr funktionieren würden (z. B. geänderte Pfade oder Szenen), dann ist das Update für alle Pflicht.

## Betrieb

```bash
cd /opt/pommesbude/server
docker compose ps
docker compose logs -f web mediamtx
docker compose restart
```

- Nutzerdatenbank sichern: `docker run --rm -v stream-relay_web_data:/data -v /root:/out alpine cp /data/app.db /out/app.db`
- Nutzer verwalten: auf der Website unter "Nutzer" (freigeben, löschen). Jeder freigegebene Nutzer darf das.
- Traffic im Panel des Anbieters beobachten.

## Konfiguration (`server/.env`)

| Variable | Bedeutung |
|---|---|
| `DOMAIN` | Domain der Website, Caddy holt dafür das Zertifikat |
| `PUBLIC_IP` | Öffentliche IPv4, wird MediaMTX als ICE-Kandidat mitgegeben |
| `SITE_NAME` | Name der Website (Titel, Kopfzeile) |
| `HOOK_SUBNET` | Docker-Subnetz, aus dem der MediaMTX-Auth-Hook kommen darf (Default passt zu `docker-compose.yml`) |
| `SESSION_SECRET` | reserviert, wird automatisch erzeugt |

## Architektur

```
Browser ──HTTPS──> Caddy ──┬─ /<name>/whip, /<name>/whep, /<name>-cam/… ──> mediamtx:8889   (WebRTC-Signalisierung)
                           └─ alles andere                              ──> web:3000        (Website + API)
OBS ─────HTTPS──> Caddy ───── /<name>/whip ────────────────────────────> mediamtx:8889
mediamtx ──HTTP──> web:3000/api/mediamtx/auth   (Auth-Hook: publish = Stream-Key, read = Viewer-Token)
web      ──HTTP──> mediamtx:9997/v3/paths/list  (wer ist live)
UDP 8189 (Medien) direkt an mediamtx.
```

- MediaMTX authentifiziert nicht selbst, sondern fragt bei jedem Publish/Read die Website (`authMethod: http`). Publish ist nur auf den eigenen Pfad `<name>` und `<name>-cam` mit dem eigenen Stream-Key erlaubt, Read nur mit einem kurzlebigen Viewer-Token, das die Website eingeloggten und freigegebenen Nutzern gibt.
- Der Hook ist von außen nicht erreichbar (Caddy antwortet 404, die Website prüft zusätzlich die Quell-IP).

## Lokaler Test ohne VPS (Docker unter WSL oder Linux)

```bash
mkdir -p ~/relay-test && cp -r server web client docs VERSION relay.example.json ~/relay-test/
cd ~/relay-test/server
printf "DOMAIN=localhost\nPUBLIC_IP=<eigene-ip>\nHOOK_SUBNET=172.30.0.0/24\nSITE_NAME=Test\n" > .env
sed -i "s|__PUBLIC_IP__|<eigene-ip>|" mediamtx.yml
docker compose -f docker-compose.yml -f compose.local.yml up -d --build
```
Website: `http://localhost:8080/` (Caddy ohne TLS, siehe `Caddyfile.local`). OBS sendet dann auf `http://<eigene-ip>:8889/<name>/whip`.

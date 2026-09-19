# Server: Aufsetzen und Betrieb

Alles läuft in Docker-Containern: MediaMTX (WebRTC-Relay), die Website (Node 24 + SQLite), Caddy (HTTPS mit Let's Encrypt), der Mumble-Server (Voice) und ein kleiner Sidecar `mumble-ice` (Voice-Präsenz für die Website, Zertifikatspflege).
Kein Transcoding, der Server reicht Streams nur weiter. Ein kleiner VPS mit 2 vCPU, 2–4 GB RAM reicht. Wichtig ist der Traffic:
pro Zuschauer und laufendem Stream etwa 8 Mbit/s ausgehend (Kamera 2,5 Mbit/s), bei 3 Streams und 6 Zuschauern kommen schnell einige TB im Monat zusammen.

## Voraussetzungen

- Linux-VPS (Debian 12/13 oder Ubuntu 22.04+), Root-Zugang per SSH.
- Eine Domain oder Subdomain, die auf die IP des Servers zeigt (ein kostenloser DynDNS-Dienst reicht).
- Offene Ports: 22/tcp (SSH), 80/tcp und 443/tcp (Caddy), 8189/udp (WebRTC-Medien), 64738/tcp+udp (Mumble). Siehe `server/firewall.md`.

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
docker compose logs -f web mediamtx mumble
docker compose restart
```

Update im laufenden Betrieb (Streams laufen weiter, Zuschauer laden nur neu): nur die geänderten Container ersetzen, z. B.
`docker compose build -q web && docker compose up -d --no-deps web`. Nach Änderungen am `Caddyfile`: `docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile`.

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
| `MUMBLE_PASSWORD` | Server-Passwort des Voice-Chats, automatisch erzeugt. Website und Client-Setup geben es nur freigegebenen Nutzern weiter (steckt in der `mumble://`-Adresse) |
| `MUMBLE_ICE_SECRET` | Secret für die Ice-Schnittstelle zwischen `mumble` und `mumble-ice`, automatisch erzeugt |

## Architektur

```
Browser ──HTTPS──> Caddy ──┬─ /<name>/whip, /<name>/whep, /<name>-cam/… ──> mediamtx:8889   (WebRTC-Signalisierung)
                           └─ alles andere                              ──> web:3000        (Website + API)
OBS ─────HTTPS──> Caddy ───── /<name>/whip ────────────────────────────> mediamtx:8889
mediamtx ──HTTP──> web:3000/api/mediamtx/auth   (Auth-Hook: publish = Stream-Key, read = Viewer-Token)
web      ──HTTP──> mediamtx:9997/v3/paths/list  (wer ist live)
UDP 8189 (Medien) direkt an mediamtx.
Mumble-Client ──TCP+UDP 64738──> mumble   (Voice; TLS mit dem Let's-Encrypt-Zertifikat von Caddy)
web ──HTTP──> mumble:6503/users  (mumble-ice: wer ist im Voice, per Ice vom Mumble-Server)
```

- MediaMTX authentifiziert nicht selbst, sondern fragt bei jedem Publish/Read die Website (`authMethod: http`). Publish ist nur auf den eigenen Pfad `<name>` und `<name>-cam` mit dem eigenen Stream-Key erlaubt, Read nur mit einem kurzlebigen Viewer-Token, das die Website eingeloggten und freigegebenen Nutzern gibt.
- Der Hook ist von außen nicht erreichbar (Caddy antwortet 404, die Website prüft zusätzlich die Quell-IP).

## Voice (Mumble)

- Ein Mumble-Server mit einem Server-Passwort (`MUMBLE_PASSWORD`). Nutzername im Voice = Website-Name. Die Website (`Voice beitreten`) und der Client (`Voice`-Verknüpfung, LIVE-Fenster) öffnen eine `mumble://name:passwort@domain:64738/`-Adresse, der Mumble-Client verbindet sich ohne Rückfrage.
- TLS: Beim Start kopiert der `mumble`-Container das Let's-Encrypt-Zertifikat aus dem Caddy-Volume (`caddy_data`, read-only) nach `/data/tls`. `mumble-ice` prüft alle 10 Minuten, ob Caddy es erneuert hat, kopiert es dann neu und lässt Mumble es per `SIGUSR1` neu laden (ohne Neustart, niemand fliegt raus). Solange Caddy noch kein Zertifikat hat (erste Minuten nach der Installation), nutzt Mumble ein selbstsigniertes; danach einmal `docker compose restart mumble`.
- Präsenz: `mumble-ice` liest die Nutzerliste über Ice (`icesecretread`) und liefert sie als `GET http://mumble:6503/users` nur im Docker-Netz. Die Website zeigt sie in der Kopfzeile, an den Namens-Chips und an den Stream-Kacheln (alle 500 ms per SSE bei Änderung).
- Wer spricht: Ice kennt das nicht, deshalb hängt `mumble-ice` als Bot-Nutzer **website** (Server-Passwort, pymumble, selbst stumm) im Wurzelkanal und merkt sich, von wem Audio kommt. Er ist in Mumble als normaler Nutzer sichtbar; die Website blendet ihn aus.
- Mikro/Ton auf der Website: `POST /api/voice/me {mute|deaf}` setzt über Ice `setState` einen **Server**-Mute/-Taub für den eigenen Nutzer (in Mumble als solcher sichtbar, dort nicht selbst aufhebbar, nur wieder über die Website). Ein in Mumble selbst gesetztes Stumm/Taub zeigt die Website an, kann es aber nicht aufheben.
- Chat: einfacher Gruppen-Chat in der Website (Tabelle `messages` in der SQLite-DB, letzte 2000 Nachrichten), live per Server-Sent Events (`/api/chat/stream`). Im `Caddyfile` ist dieser Pfad von `encode` ausgenommen, sonst würde Caddy die Events puffern.
- Voice abschalten: `MUMBLE_PASSWORD` aus `.env` entfernen und `docker compose up -d --no-deps web` (Website blendet Voice aus); Container mit `docker compose stop mumble mumble-ice`.

## Lokaler Test ohne VPS (Docker unter WSL oder Linux)

```bash
mkdir -p ~/relay-test && cp -r server web client docs VERSION relay.example.json ~/relay-test/
cd ~/relay-test/server
printf "DOMAIN=localhost\nPUBLIC_IP=<eigene-ip>\nHOOK_SUBNET=172.30.0.0/24\nSITE_NAME=Test\n" > .env
sed -i "s|__PUBLIC_IP__|<eigene-ip>|" mediamtx.yml
docker compose -f docker-compose.yml -f compose.local.yml up -d --build
```
Website: `http://localhost:8080/` (Caddy ohne TLS, siehe `Caddyfile.local`). OBS sendet dann auf `http://<eigene-ip>:8889/<name>/whip`.

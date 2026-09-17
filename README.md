# Pommesbude

Self-hosted 1080p60 game streaming for a Discord group. A small VPS relays WebRTC streams (no transcoding),
OBS sends via WHIP, everyone watches **all running streams on one website**: grid of large tiles, small strip for
cameras, drag and drop, resizable split. Latency around 0.3 s. Voice stays in Discord.

*Deutsche Version weiter unten.*

## Features

- **One website** with login and approval: register, someone from the group approves, done. Every approved user gets a stream key.
- **Grid + strip**: game streams large, webcams small, views *Standard / All large / All small / Custom*, drag tiles between grid and strip, draggable split bar, focus one tile, hide cameras, one audio source at a time. Layout is remembered per browser.
- **Launcher for Windows**: one desktop shortcut starts OBS in the background, shows a chooser (screen, any open window or game, webcam), and streams. Switch sources live, toggle the camera, stop everything from a small LIVE window.
- **Camera as a separate 720p stream** so viewers can show or hide it independently.
- **Updates**: the launcher asks the server for the current client version on every start, offers updates, and enforces them when the server requires a newer client.
- **Privacy by design**: WebRTC only, per-user stream keys, viewer tokens, no RTMP, the MediaMTX auth hook is not reachable from outside.
- **Cheap**: one small VPS (2 vCPU, 4 GB) plus traffic. No transcoding.

## How it works

```
Browser ──HTTPS──> Caddy ──┬─ /<name>/whip, /<name>/whep ──> mediamtx:8889   (WebRTC signalling)
                           └─ everything else            ──> web:3000        (website + API, Node 24 + SQLite)
OBS ─────HTTPS──> Caddy ───── /<name>/whip ─────────────────> mediamtx:8889
mediamtx ──HTTP──> web:3000/api/mediamtx/auth   (auth hook: publish = stream key, read = viewer token)
web      ──HTTP──> mediamtx:9997/v3/paths/list  (who is live)
UDP 8189 (media) directly to mediamtx.
```

## Repository layout

| Path | Contents |
|---|---|
| `server/` | `docker-compose.yml` (MediaMTX 1.21 + web + Caddy 2), `mediamtx.yml`, `Caddyfile`, `install.sh`, `firewall.md`, local test overrides |
| `web/` | Website and API: `server.js`, `db.js`, `public/`, `Dockerfile` (also builds the client package) |
| `client/` | Windows client: `setup-obs.ps1` (called by `Setup.cmd`), `stream.ps1` (launcher), OBS profiles and scene collections |
| `docs/` | `ANLEITUNG.md` (German user guide), `GUIDE.md` (English user guide), `SERVER.md` (operations, German) |
| `scripts/` | `build-packages.ps1` builds `dist/pommesbude-server.zip` and `dist/pommesbude-client.zip` (the two release downloads) |
| `VERSION` | single source of the client version the server announces |
| `relay.example.json` | template for the instance config that operators hand to their streamers |

## Downloads

Each release ships two separate archives:

| Archive | For whom | Contents |
|---|---|---|
| `pommesbude-server.zip` | the operator (one person per group) | everything needed to run a server: `server/`, `web/`, `client/`, `docs/`, `VERSION` |
| `pommesbude-client.zip` | every streamer | Windows client only: `Setup.cmd`, `client/`, the user guides, `VERSION`, `relay.example.json` |

The running server also serves its matching client package at `https://<domain>/client/pommesbude-client.zip`, so streamers normally get it there or from the operator, together with the operator's `relay.json`.

## Server setup (short)

```bash
# from the release archive
unzip pommesbude-server.zip -d /opt/pommesbude && cd /opt/pommesbude && chmod +x server/install.sh && ./server/install.sh
# or from git
git clone https://github.com/<owner>/Pommesbude.git /opt/pommesbude && cd /opt/pommesbude && chmod +x server/install.sh && ./server/install.sh
```
The script installs Docker, asks for domain, public IP and site name, sets up `ufw`, builds the image (including the client
package served at `/client/pommesbude-client.zip`) and starts everything. Open `https://<domain>/`, register (the first user is
approved automatically), create a `relay.json` from `relay.example.json` and give it to your streamers. Details: `docs/SERVER.md`.

## Client setup (short)

`Setup.cmd`, double-click `Setup.cmd`, enter your username and stream key from the website. OBS Studio 30+ is installed or upgraded on demand (winget). Then use the desktop shortcut
`VERSION`, run `client\setup-obs.ps1`, enter your username and stream key from the website. Then use the desktop shortcut
**Stream starten**. Details: `docs/GUIDE.md`.

## Updating

Server: unpack the new `pommesbude-server.zip` over the old folder (`server/.env` and the database stay) and run `./server/install.sh`, or `git pull && ./server/install.sh`. Clients update themselves through the launcher (bump `VERSION`; bump
`MIN_CLIENT_VERSION` in `web/server.js` when old clients must not connect any more).

## Requirements

- Server: Debian 12/13 or Ubuntu 22.04+, a domain pointing at it, ports 80/443 TCP and 8189 UDP.
- Streamers: Windows 10/11, OBS Studio 30+ (installed on demand), any GPU (the setup picks NVENC, AMF, QSV or x264 automatically), about 10 Mbit/s upload.
- Viewers: any current browser; roughly 8 Mbit/s download per stream shown.

## License

MIT, see `LICENSE`.

---

# Pommesbude (Deutsch)

Selbst gehostetes 1080p60-Game-Streaming für eine Discord-Gruppe. Ein kleiner VPS leitet WebRTC-Streams 1:1 weiter (kein
Transcoding), OBS sendet per WHIP, alle sehen **alle laufenden Streams auf einer Website**: großes Raster, kleine Leiste für
Kameras, Drag & Drop, verschiebbarer Trennbalken. Latenz etwa 0,3 s. Voice bleibt in Discord.

## Funktionen

- **Eine Website** mit Registrierung und Freigabe: registrieren, jemand aus der Gruppe schaltet frei, fertig. Jeder freigegebene Nutzer bekommt einen Stream-Key.
- **Raster + Leiste**: Spiel-Streams groß, Webcams klein, Ansichten *Standard / Alle groß / Alle klein / Eigene*, Kacheln ziehen, Trennbalken ziehen, eine Kachel fokussieren, Kameras ausblenden, genau eine Tonquelle. Die Zusammenstellung bleibt im Browser gespeichert.
- **Launcher für Windows**: eine Desktop-Verknüpfung startet OBS im Hintergrund, zeigt eine Auswahl (Bildschirm, offenes Fenster oder Spiel, Webcam) und streamt. Quelle live wechseln, Kamera an/aus, alles beenden im kleinen LIVE-Fenster.
- **Kamera als eigener 720p-Stream**, damit Zuschauer sie unabhängig ein- und ausblenden können.
- **Updates**: Der Launcher fragt bei jedem Start die aktuelle Client-Version beim Server ab, bietet Updates an und erzwingt sie, wenn der Server eine neuere Version verlangt.
- **Sicher**: nur WebRTC, Stream-Key pro Nutzer, Viewer-Tokens, kein RTMP, der MediaMTX-Auth-Hook ist von außen nicht erreichbar.
- **Günstig**: ein kleiner VPS (2 vCPU, 4 GB) plus Traffic. Kein Transcoding.

## Downloads

Jedes Release hat zwei getrennte Archive:

| Archiv | Für wen | Inhalt |
|---|---|---|
| `pommesbude-server.zip` | der Betreiber (eine Person pro Gruppe) | alles für den Server: `server/`, `web/`, `client/`, `docs/`, `VERSION` |
| `pommesbude-client.zip` | jeder Streamer | nur der Windows-Client: `Setup.cmd`, `client/`, die Anleitungen, `VERSION`, `relay.example.json` |

Der laufende Server liefert sein passendes Client-Paket zusätzlich unter `https://<domain>/client/pommesbude-client.zip` aus. Streamer bekommen es also dort oder vom Betreiber, zusammen mit dessen `relay.json`.

## Server einrichten (kurz)

```bash
# aus dem Release-Archiv
unzip pommesbude-server.zip -d /opt/pommesbude && cd /opt/pommesbude && chmod +x server/install.sh && ./server/install.sh
# oder per git
git clone https://github.com/<owner>/Pommesbude.git /opt/pommesbude && cd /opt/pommesbude && chmod +x server/install.sh && ./server/install.sh
```
Das Skript installiert Docker, fragt Domain, öffentliche IP und Namen der Website ab, richtet `ufw` ein, baut das Image (inklusive
Client-Paket unter `/client/pommesbude-client.zip`) und startet alles. Dann `https://<domain>/` öffnen, registrieren (der erste
Nutzer ist automatisch freigegeben), aus `relay.example.json` eine `relay.json` machen und an die Streamer geben. Details: `docs/SERVER.md`.

## Client einrichten (kurz)

`pommesbude-client.zip` laden (aus dem Release oder von `https://<domain>/client/pommesbude-client.zip`), entpacken, die `relay.json` des Betreibers neben
`Setup.cmd` legen, `Setup.cmd` doppelklicken, Benutzername und Stream-Key von der Website eingeben. OBS Studio 30+ wird bei Bedarf installiert oder aktualisiert (winget). Danach Doppelklick auf
**Stream starten**. Details: `docs/ANLEITUNG.md`.

## Updates

Server: neues `pommesbude-server.zip` über den alten Ordner entpacken (`server/.env` und Datenbank bleiben) und `./server/install.sh` ausführen, oder `git pull && ./server/install.sh`. Clients aktualisieren sich über den Launcher (`VERSION` erhöhen; `MIN_CLIENT_VERSION`
in `web/server.js` erhöhen, wenn alte Clients nicht mehr funktionieren dürfen).

## Voraussetzungen

- Server: Debian 12/13 oder Ubuntu 22.04+, eine Domain, die darauf zeigt, Ports 80/443 TCP und 8189 UDP.
- Streamer: Windows 10/11, OBS Studio 30+ (wird bei Bedarf installiert), beliebige GPU (das Setup wählt NVENC, AMF, QSV oder x264 automatisch), etwa 10 Mbit/s Upload.
- Zuschauer: aktueller Browser; etwa 8 Mbit/s Download je angezeigtem Stream.

## Lizenz

MIT, siehe `LICENSE`.

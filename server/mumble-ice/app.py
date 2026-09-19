#!/usr/bin/env python3
"""Sidecar fuer den Mumble-Server.

1. HTTP GET /users  -> JSON-Liste der verbundenen Nutzer (Name, stumm, taub, spricht), gelesen ueber Ice
   (tcp 127.0.0.1:6502, Secret ICE_SECRET = icesecretread/-write des Servers).
   HTTP POST /users/<name>/state  {"mute": bool, "deaf": bool} -> setzt Server-Mute/-Taub des Nutzers (Ice setState).
2. "Spricht gerade" kennt Ice nicht. Dafuer haengt ein Bot-Nutzer (BOT_NAME, pymumble) im Wurzelkanal und merkt sich,
   von wem zuletzt Audio kam. Er ist in Mumble als normaler Nutzer sichtbar und wird in /users weggelassen.
3. Zertifikat: kopiert alle CERT_INTERVAL Sekunden das Let's-Encrypt-Zertifikat von Caddy
   (CERT_SRC_CRT/CERT_SRC_KEY, read-only gemountet) nach /data/tls, wenn es sich geaendert hat,
   und schickt Mumble (PID 1 im geteilten PID-Namespace) SIGUSR1 = Zertifikat neu laden, ohne Neustart.
"""
import json
import os
import shutil
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import Ice

Ice.loadSlice("-I/usr/share/ice/slice MumbleServer.ice")
import MumbleServer  # noqa: E402  (vom Slice-Loader erzeugt)

ICE_SECRET = os.environ.get("ICE_SECRET", "")
ICE_ENDPOINT = os.environ.get("ICE_ENDPOINT", "tcp -h 127.0.0.1 -p 6502")
HTTP_PORT = int(os.environ.get("HTTP_PORT", "6503"))
CERT_SRC_CRT = os.environ.get("CERT_SRC_CRT", "")
CERT_SRC_KEY = os.environ.get("CERT_SRC_KEY", "")
CERT_DST_DIR = os.environ.get("CERT_DST_DIR", "/data/tls")
CERT_INTERVAL = int(os.environ.get("CERT_INTERVAL", "600"))
CERT_UID = int(os.environ.get("CERT_UID", "10000"))
BOT_NAME = os.environ.get("BOT_NAME", "website")
BOT_PASSWORD = os.environ.get("BOT_PASSWORD", "")
MUMBLE_PORT = int(os.environ.get("MUMBLE_PORT", "64738"))
TALK_HOLD = float(os.environ.get("TALK_HOLD", "0.5"))   # Sekunden ohne Audio, bis "spricht" erlischt


def log(msg):
    print(f"[mumble-ice] {msg}", flush=True)


# --- "spricht gerade": Zeitstempel des letzten Audiopakets je Nutzername ------------------------------
talk_lock = threading.Lock()
last_audio = {}   # name -> time.monotonic()


def note_audio(user, _chunk):
    try:
        name = user["name"]
    except Exception:
        return
    with talk_lock:
        last_audio[name] = time.monotonic()


def is_talking(name):
    with talk_lock:
        t = last_audio.get(name)
    return t is not None and (time.monotonic() - t) < TALK_HOLD


def bot_loop():
    if not BOT_PASSWORD:
        log("BOT_PASSWORD leer, Sprech-Erkennung aus")
        return
    try:
        import ssl
        if not hasattr(ssl, "wrap_socket"):   # pymumble 1.6 nutzt das seit Python 3.12 entfernte ssl.wrap_socket
            def _wrap_socket(sock, certfile=None, keyfile=None, **_kw):
                ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE      # Verbindung nur nach 127.0.0.1 im eigenen Netz-Namespace
                if certfile:
                    ctx.load_cert_chain(certfile, keyfile)
                return ctx.wrap_socket(sock)
            ssl.wrap_socket = _wrap_socket
        import pymumble_py3 as pymumble
        from pymumble_py3.constants import PYMUMBLE_CLBK_SOUNDRECEIVED, PYMUMBLE_CONN_STATE_CONNECTED
    except Exception as e:
        log(f"pymumble fehlt, Sprech-Erkennung aus: {e!r}")
        return
    while True:
        try:
            m = pymumble.Mumble("127.0.0.1", BOT_NAME, port=MUMBLE_PORT, password=BOT_PASSWORD, reconnect=False, debug=False)
            m.set_receive_sound(True)
            m.callbacks.set_callback(PYMUMBLE_CLBK_SOUNDRECEIVED, note_audio)
            m.start()
            m.is_ready()
            try:
                m.users.myself.mute()   # Bot sendet nie, nur mithoeren
                m.users.myself.comment("Sprech-Anzeige fuer die Website")
            except Exception:
                pass
            log(f"Bot '{BOT_NAME}' verbunden")
            while m.is_alive() and m.connected == PYMUMBLE_CONN_STATE_CONNECTED:
                time.sleep(1)
            log("Bot getrennt, verbinde neu")
        except Exception as e:
            log(f"Bot-Fehler: {e!r}")
        time.sleep(5)


class Presence:
    """Haelt eine Ice-Verbindung und liefert die Nutzerliste; baut die Verbindung bei Fehlern neu auf."""

    def __init__(self):
        self.lock = threading.Lock()
        self.comm = None
        self.meta = None

    def _connect(self):
        props = Ice.createProperties()
        props.setProperty("Ice.ImplicitContext", "Shared")
        props.setProperty("Ice.Default.EncodingVersion", "1.0")
        idd = Ice.InitializationData()
        idd.properties = props
        self.comm = Ice.initialize(idd)
        self.comm.getImplicitContext().put("secret", ICE_SECRET)
        base = self.comm.stringToProxy(f"Meta:{ICE_ENDPOINT}")
        self.meta = MumbleServer.MetaPrx.checkedCast(base)
        if self.meta is None:
            raise RuntimeError("Meta-Proxy nicht erreichbar")

    def _close(self):
        if self.comm is not None:
            try:
                self.comm.destroy()
            except Exception:
                pass
        self.comm = None
        self.meta = None

    def _call(self, fn):
        with self.lock:
            for attempt in (1, 2):
                try:
                    if self.meta is None:
                        self._connect()
                    return fn()
                except Exception as e:  # Verbindung weg, Server startet neu, falsches Secret ...
                    log(f"Ice-Fehler ({attempt}): {e!r}")
                    self._close()
                    if attempt == 2:
                        raise
                    time.sleep(0.5)

    def users(self):
        def go():
            out = []
            for server in self.meta.getBootedServers():
                for u in server.getUsers().values():
                    if u.name == BOT_NAME:
                        continue
                    out.append({
                        "name": u.name,
                        "mute": bool(u.mute or u.selfMute or u.suppress),
                        "serverMute": bool(u.mute),
                        "selfMute": bool(u.selfMute),
                        "deaf": bool(u.deaf or u.selfDeaf),
                        "serverDeaf": bool(u.deaf),
                        "selfDeaf": bool(u.selfDeaf),
                        "talking": is_talking(u.name) and not (u.mute or u.selfMute or u.suppress),
                        "channel": u.channel,
                        "online": u.onlinesecs,
                    })
            out.sort(key=lambda x: x["name"].lower())
            return out
        return self._call(go)

    def set_state(self, name, mute=None, deaf=None):
        def go():
            for server in self.meta.getBootedServers():
                for u in server.getUsers().values():
                    if u.name == name:
                        if deaf is not None:
                            u.deaf = bool(deaf)
                            if deaf:
                                u.mute = True          # taub schliesst stumm ein (wie in Mumble selbst)
                        if mute is not None:
                            u.mute = bool(mute)
                            if not mute:
                                u.deaf = False
                        server.setState(u)
                        return True
            return False
        return self._call(go)


presence = Presence()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # kein Zugriffslog, das ist nur intern
        pass

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/users":
            try:
                self._send(200, presence.users())
            except Exception as e:
                self._send(503, {"error": str(e)})
        elif self.path == "/health":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        parts = self.path.strip("/").split("/")
        if len(parts) == 3 and parts[0] == "users" and parts[2] == "state":
            try:
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                ok = presence.set_state(parts[1], mute=body.get("mute"), deaf=body.get("deaf"))
                self._send(200 if ok else 404, {"ok": ok})
            except Exception as e:
                self._send(503, {"error": str(e)})
        else:
            self._send(404, {"error": "not found"})


def _same(src, dst):
    try:
        with open(src, "rb") as a, open(dst, "rb") as b:
            return a.read() == b.read()
    except OSError:
        return False


def cert_loop():
    if not CERT_SRC_CRT or not CERT_SRC_KEY:
        log("Kein Zertifikatspfad gesetzt, Zertifikatspflege aus")
        return
    dst_crt = os.path.join(CERT_DST_DIR, "mumble.crt")
    dst_key = os.path.join(CERT_DST_DIR, "mumble.key")
    while True:
        try:
            if os.path.isfile(CERT_SRC_CRT) and os.path.isfile(CERT_SRC_KEY):
                if not (_same(CERT_SRC_CRT, dst_crt) and _same(CERT_SRC_KEY, dst_key)):
                    os.makedirs(CERT_DST_DIR, exist_ok=True)
                    for src, dst in ((CERT_SRC_CRT, dst_crt), (CERT_SRC_KEY, dst_key)):
                        shutil.copyfile(src, dst + ".tmp")
                        os.chown(dst + ".tmp", CERT_UID, CERT_UID)
                        os.chmod(dst + ".tmp", 0o600)
                        os.replace(dst + ".tmp", dst)
                    os.kill(1, signal.SIGUSR1)
                    log("Zertifikat aktualisiert, Mumble per SIGUSR1 zum Neuladen aufgefordert")
            else:
                log(f"Quellzertifikat fehlt noch: {CERT_SRC_CRT}")
        except Exception as e:
            log(f"Zertifikatspflege: {e!r}")
        time.sleep(CERT_INTERVAL)


def main():
    if not ICE_SECRET:
        log("WARNUNG: ICE_SECRET leer")
    threading.Thread(target=cert_loop, daemon=True).start()
    threading.Thread(target=bot_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    log(f"HTTP auf :{HTTP_PORT}, Ice {ICE_ENDPOINT}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())

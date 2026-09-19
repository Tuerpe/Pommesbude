# Sidecar fuer den Mumble-Server: liefert die Praesenz (wer ist im Voice, wer spricht) per HTTP an die Website,
# setzt Server-Mute/-Taub und haelt das TLS-Zertifikat aktuell (kopiert Caddys Let's-Encrypt-Zertifikat, dann SIGUSR1 an Mumble).
# Laeuft im Netz- und PID-Namespace des mumble-Containers (siehe docker-compose.yml).
# python3-zeroc-ice aus Debian, weil das pip-Paket fuer aktuelle Python-Versionen kein Wheel hat; pymumble (Bot fuer die
# Sprech-Erkennung) gibt es nur per pip.
FROM debian:trixie-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends python3 python3-pip python3-zeroc-ice zeroc-ice-slice libopus0 \
 && pip install -q --break-system-packages --root-user-action=ignore pymumble opuslib \
 && rm -rf /var/lib/apt/lists/* /root/.cache
WORKDIR /app
COPY MumbleServer.ice app.py ./
ENV PYTHONUNBUFFERED=1 PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python
CMD ["python3", "app.py"]

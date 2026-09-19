# Sidecar fuer den Mumble-Server: liefert die Praesenz (wer ist im Voice) per HTTP an die Website
# und haelt das TLS-Zertifikat aktuell (kopiert Caddys Let's-Encrypt-Zertifikat, dann SIGUSR1 an Mumble).
# Laeuft im Netz- und PID-Namespace des mumble-Containers (siehe docker-compose.yml).
# python3-zeroc-ice aus Debian, weil das pip-Paket fuer aktuelle Python-Versionen kein Wheel hat.
FROM debian:trixie-slim
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends python3 python3-zeroc-ice zeroc-ice-slice \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY MumbleServer.ice app.py ./
ENV PYTHONUNBUFFERED=1
CMD ["python3", "app.py"]

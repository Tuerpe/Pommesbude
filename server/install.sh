#!/usr/bin/env bash
# Einmaliges Setup bzw. Update auf dem VPS (Debian 12/13 oder Ubuntu 22.04+, als root). Idempotent.
# Aufruf aus dem Projektverzeichnis: ./server/install.sh   (z. B. /opt/pommesbude/server/install.sh)
# Ablauf: Docker installieren, .env anlegen, mediamtx.yml befuellen, ufw, Stack bauen und starten.
set -euo pipefail
cd "$(dirname "$0")"

# --- 1. Docker Engine + Compose-Plugin --------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  echo ">> Installiere Docker Engine ..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  . /etc/os-release   # ID = debian oder ubuntu, VERSION_CODENAME = trixie/bookworm/noble/...
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi
echo ">> Docker: $(docker --version)"

# --- 2. .env (Domain, oeffentliche IP, Secrets) --------------------------------
touch .env
if ! grep -q '^DOMAIN=' .env; then
  read -rp "Domain (z. B. stream.example.org): " DOMAIN
  echo "DOMAIN=${DOMAIN}" >> .env
fi
if ! grep -q '^PUBLIC_IP=' .env; then
  PUBLIC_IP="$(curl -4 -fsS https://ifconfig.me || true)"
  read -rp "Oeffentliche IPv4 [${PUBLIC_IP}]: " IP_IN
  echo "PUBLIC_IP=${IP_IN:-$PUBLIC_IP}" >> .env
fi
if ! grep -q '^SITE_NAME=' .env; then
  read -rp "Name der Website [Stream Relay]: " SITE_IN
  echo "SITE_NAME=${SITE_IN:-Stream Relay}" >> .env
fi
grep -q '^HOOK_SUBNET=' .env || echo "HOOK_SUBNET=172.30.0.0/24" >> .env
grep -q '^SESSION_SECRET=' .env || echo "SESSION_SECRET=$(openssl rand -hex 32)" >> .env
# Voice (Mumble): Server-Passwort (steht spaeter in der mumble://-URL, daher nur Buchstaben/Ziffern) und Ice-Secret.
grep -q '^MUMBLE_PASSWORD=' .env || echo "MUMBLE_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)" >> .env
grep -q '^MUMBLE_ICE_SECRET=' .env || echo "MUMBLE_ICE_SECRET=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)" >> .env
# shellcheck disable=SC1091
source .env
sed -i "s|__PUBLIC_IP__|${PUBLIC_IP}|" mediamtx.yml

# --- 3. Firewall (ufw), falls installiert -------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  if ! ufw status | grep -q "^Status: active"; then
    echo ">> Aktiviere ufw (22, 80, 443/tcp, 8189/udp, 64738/tcp+udp) ..."
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 22/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw allow 8189/udp >/dev/null
    ufw --force enable
  fi
  # Voice-Port, auch bei bestehender Installation nachziehen (idempotent).
  ufw allow 64738/tcp >/dev/null
  ufw allow 64738/udp >/dev/null
fi

# --- 4. Stack bauen und starten ----------------------------------------------------
# Erwartete Struktur: dieses Skript liegt in <projekt>/server/, daneben <projekt>/web, client, docs, VERSION (Build-Kontext ist <projekt>).
echo ">> Baue Website-Image (inkl. Client-Paket) und starte Container ..."
docker compose pull -q mediamtx caddy mumble
docker compose build -q web mumble-ice
docker compose up -d --remove-orphans
sleep 3
docker compose ps
echo
echo ">> Fertig. Website: https://${DOMAIN}/  (erster registrierter Nutzer ist automatisch freigegeben)"
echo ">> Voice: mumble://${DOMAIN}:64738 (Passwort MUMBLE_PASSWORD in .env; Website und Client-Setup verteilen es automatisch)"
echo ">> Logs:  docker compose logs -f web mediamtx mumble"

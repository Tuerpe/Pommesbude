# Firewall-Regeln

Standard: `ufw` auf dem Server. Bietet der Anbieter eine externe Cloud-Firewall, dort dieselben Ports freigeben.
`install.sh` richtet ufw automatisch ein (Abschnitt 4). Docker veroeffentlicht nur die Ports unten, alles andere ist zu.

## Regeln (ufw, von install.sh gesetzt)

| Richtung | Protokoll | Port | Quelle        | Zweck                                   |
|----------|-----------|------|---------------|-----------------------------------------|
| Eingehend| TCP       | 22   | any           | SSH (nur Key-Login, Passwort-Login ist abgeschaltet) |
| Eingehend| TCP       | 80   | any           | Caddy, Let's-Encrypt-HTTP-Challenge, Redirect |
| Eingehend| TCP       | 443  | any           | Caddy HTTPS -> MediaMTX 8889 (WHIP/WHEP, Player) |
| Eingehend| UDP       | 8189 | any           | WebRTC-Medien direkt an MediaMTX        |
| Eingehend| TCP       | 64738| any           | Mumble (Voice), Steuerung + TLS         |
| Eingehend| UDP       | 64738| any           | Mumble (Voice), Audio                   |

Ausgehend: alles erlauben (Default). Alles andere eingehend: zu.
Insbesondere 8889/tcp **nicht** freigeben, der Port ist im Compose gar nicht veroeffentlicht.

ICMP eingehend darf offen bleiben (Ping, Path-MTU).

## Manuell nachziehen (falls install.sh nicht genutzt wurde)

```bash
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8189/udp
ufw allow 64738/tcp
ufw allow 64738/udp
ufw enable
```

Hinweis: Weil Docker ufw umgeht, schuetzt das nur Ports, die nicht per `ports:` veroeffentlicht sind.
Fuer echten Schutz der Docker-Ports `{"iptables": false}` in `/etc/docker/daemon.json` ist **nicht** empfohlen (bricht Container-Netz).
Stattdessen: nur die Ports oben in `docker-compose.yml` veroeffentlichen, so wie es jetzt ist.

## Pruefen

```bash
ss -tulpn | grep -E ':(80|443|8189|8889|64738|6503)\b'
# erwartet: 80, 443, 8189, 64738 auf 0.0.0.0 (docker-proxy), 8889 und 6503 nur innerhalb des Compose-Netzes
```

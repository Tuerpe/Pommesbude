# Streamen und Zuschauen über unseren eigenen Server (1080p60)

Voice bleibt in Discord. Nur das Bild läuft über den eigenen Server. Alles läuft über **eine** Website.
Die Adresse steht in der `relay.json`, die ihr vom Betreiber bekommt (Feld `domain`), z. B. `https://stream.example.org/`.

## 1. Registrieren (einmalig, 1 Minute)

1. Website öffnen → **Registrieren** → Name (klein, z. B. `max`) und Passwort wählen.
   Der Name wird auch dein Stream-Name, also kurz und ohne Sonderzeichen.
2. Jemandem aus der Gruppe Bescheid sagen, der schon drin ist. Der klickt auf **Nutzer → Freigeben**.
3. Seite lädt danach automatisch weiter. Fertig, du kannst zuschauen.

## 2. Zuschauen

Website öffnen, einloggen. Alle laufenden Streams laufen sofort, alle stumm.
- **Ansicht** oben: *Standard* = Spiel-Streams groß im Raster, Kameras klein in der Leiste unten. *Alle groß*, *Alle klein*, *Eigene* = deine Zusammenstellung.
- **Ziehen**: Kacheln zwischen Raster und Leiste ziehen (oder ⬆/⬇ auf der Kachel). Die Seite merkt sich das.
- **Größenverhältnis**: Den Balken zwischen Raster und Leiste nach oben oder unten ziehen. Doppelklick auf den Balken = Standard. Das große Raster passt seine Kacheln immer in den freien Platz, ohne Scrollen.
- ⤢ auf einer Kachel = nur diese groß, nochmal = zurück.
- 🎥 Kameras an/aus blendet alle Kameras komplett aus (spart Download, ca. 2,5 Mbit/s je Kamera).
- 🔇 anklicken = Ton von genau diesem Stream. Nochmal klicken = wieder stumm. Kameras haben keinen Ton.
- Doppelklick = Vollbild.
- Wer gerade nicht streamt, steht als grauer Chip unter dem Raster.
- Dein eigener Stream wird nicht geladen (spart Traffic und verhindert den Spiegel-Effekt). Über den Chip "Du streamst gerade → Anzeigen" kannst du ihn trotzdem einblenden.

Hinweis: Jeder laufende Stream sind ca. 8 Mbit/s Download. Bei 3 Streams also ca. 24 Mbit/s.

## 3. Selbst streamen (einmalig einrichten, 5 Minuten)

1. **Client-Paket entpacken** (`pommesbude-client.zip`, gibt es auf der Website unter `/client/pommesbude-client.zip` oder vom Betreiber), z. B. nach `C:\pommesbude`.
   Die **`relay.json`** vom Betreiber in denselben Ordner legen (neben `Setup.cmd`).
2. **Doppelklick auf `Setup.cmd`.** Benutzername und Passwort der Website eingeben (dieselben wie beim Einloggen), den Rest holt sich das Setup selbst.
   Fehlt OBS Studio oder ist es älter als Version 30, bietet das Setup an, es automatisch zu installieren bzw. zu aktualisieren (Windows fragt dabei einmal nach Admin-Rechten). Danach OBS einmal starten, den Assistenten mit **Abbrechen** schließen, OBS beenden und im Setup Enter drücken.

Danach liegen auf dem Desktop: **Stream starten** und **Stream Stop**.

## 4. Streamen

1. **Doppelklick auf "Stream starten".** OBS startet im Hintergrund, nach ein paar Sekunden erscheint ein Fenster.
2. **Auswählen**, was gestreamt wird: einen Bildschirm oder ein offenes Fenster/Spiel. Doppelklick oder "Streamen".
   - *Ton von*: Standard ist der Ton des gewählten Fensters. Bei Bildschirm-Streams hier das Spiel wählen, sonst ist der Stream stumm.
   - *Spielaufnahme (Hook)*: nur für Spiele im echten Vollbild anhaken. Randlose Fenster gehen ohne.
   - *Kamera*: Webcam auswählen und "Kamera zusätzlich senden" anhaken, dann läuft sie als eigener 720p-Stream neben dem Bild. "Nur Kamera" in der Liste = nur die Webcam ohne Bildschirm.
3. Unten rechts bleibt ein kleines **LIVE**-Fenster: **Wechseln** öffnet die Auswahl erneut (Stream läuft dabei weiter), **Kamera an/aus** schaltet die Webcam einzeln, **Stream beenden** stoppt alles.
4. Alternativ: **Stream Stop** auf dem Desktop. Nicht über den Task-Manager abschießen, sonst fragt OBS beim nächsten Start nach dem "abgesicherten Modus".

Hotkeys im laufenden Stream (feste Szenen aus OBS): `Strg+Alt+1/2` = Monitor 1/2 (einmalig in OBS den Monitor wählen), `Strg+Alt+3` = zurück zur Auswahl-Szene.

## Ton

- Es wird nur der Ton **einer** Anwendung übertragen (die im Auswahlfenster unter "Ton von" steht). Discord-Voice landet nie im Stream.
- Mikrofon wird nicht übertragen, ihr redet ja in Discord.

## Updates

Beim Start prüft "Stream starten" beim Server, ob es eine neue Version gibt, und bietet sie an. Ist die installierte Version zu alt für den Server, ist das Update Pflicht. Das Update läuft automatisch; läuft OBS gerade, wird es dafür sauber beendet. Name, Stream-Key und Einstellungen bleiben erhalten.
Manuell: neues Paket entpacken, `relay.json` daneben legen, `Setup.cmd` erneut ausführen.

## Wenn etwas nicht geht

| Problem | Lösung |
|---|---|
| Bild ruckelt oder friert bei Zuschauern | Dein Upload ist zu schwach. OBS öffnen → Einstellungen → Ausgabe → Bitrate von 8000 auf 6000 (oder 4500) senken. |
| Spiel bleibt schwarz | Spiel auf "Randloses Fenster" stellen und im Auswahlfenster ohne Hook wählen. Bei echtem Vollbild das Häkchen "Spielaufnahme (Hook)" setzen. |
| "Verbindung fehlgeschlagen" beim Start | Stream-Key veraltet oder Server down. `Setup.cmd` nochmal ausführen (holt den aktuellen Key). |
| Ich sehe "Warte auf Freigabe" | Jemand muss dich unter **Nutzer** freigeben. |
| Passwort vergessen | Jemand aus der Gruppe klickt auf der Website unter **Nutzer** bei deinem Namen auf **Passwort** und schickt dir das Startpasswort. Danach unter "Passwort" ein eigenes setzen. |
| Stream-Key ist jemandem bekannt geworden | Website → Mein Stream-Key → **Neuen Key erzeugen**, dann `Setup.cmd` neu ausführen. |
| Beim Doppelklick auf "Stream starten" passiert nichts oder ein Fehlerfenster kommt | Einmal **Stream Stop** doppelklicken, 10 s warten, dann "Stream starten" erneut. Details stehen in `%LOCALAPPDATA%\stream-relay\launcher.log`. |
| Auswahlfenster ist leer oder Fehler "Keine Verbindung zu OBS" | OBS einmal komplett beenden (Stream Stop), 10 s warten, nochmal. Bleibt es: `Setup.cmd` erneut ausführen. |
| Kamera bleibt schwarz | Kamera wird gerade von Discord o. ä. benutzt, dort Video aus. Oder im LIVE-Fenster Kamera aus und wieder an. |
| "Starten der Ausgabe fehlgeschlagen" mit Hinweis auf NVENC/AMD | Der Encoder passt nicht zur Grafikkarte. `Setup.cmd` erneut ausführen, es wählt den Encoder automatisch (NVIDIA, AMD, Intel oder CPU). Erzwingen: `client\setup-obs.ps1 -Encoder x264`. |
| Hotkeys wirken nicht | Manche Spiele schlucken Strg+Alt+Zahl. In OBS unter Einstellungen → Hotkeys andere Tasten setzen. |

Voraussetzung zum Streamen: mindestens **10 Mbit/s Upload frei** (speedtest.net), mit Kamera ca. 13. Sonst Bitrate senken, siehe Tabelle.

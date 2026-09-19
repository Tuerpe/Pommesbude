# Streaming and watching on your own server (1080p60)

Video, voice and chat all run on the group's own server, no Discord needed. Everything happens on **one** website; voice uses Mumble (installed by the setup).
The address is in the `relay.json` you get from the operator (field `domain`), e.g. `https://stream.example.org/`.

## 1. Register (once, 1 minute)

1. Open the website → **Register** → pick a name (lowercase, e.g. `max`) and a password.
   The name is also your stream name, so keep it short, no special characters.
2. Tell someone from the group who is already in. They click **Users → Approve**.
3. The page continues automatically. Done, you can watch.

## 2. Watching

Open the website, log in. All running streams start immediately, all muted.
- **View** bar at the top: *Standard* = game streams large in the grid, cameras small in the bottom strip. *All large*, *All small*, *Custom* = your own arrangement.
- **Drag**: move tiles between grid and strip (or ⬆/⬇ on the tile). The page remembers it.
- **Ratio**: drag the bar between grid and strip up or down. Double-click the bar = default. The grid always fits its tiles into the free space, no scrolling.
- ⤢ on a tile = only this one large, again = back.
- 🎥 cameras on/off hides all cameras entirely (saves download, about 2.5 Mbit/s per camera).
- 🔇 click = audio from exactly this stream. Click again = mute. Cameras have no audio.
- Double-click = fullscreen.
- Whoever is not streaming appears as a grey chip below.
- Your own stream and camera are not loaded (saves traffic and avoids the mirror effect). Use the chip "You are streaming → Show" to see them anyway.

Note: every running stream is about 8 Mbit/s download, a camera about 2.5 Mbit/s.

## 3. Streaming yourself (one-time setup, 5 minutes)

1. **Unpack the client package** (`pommesbude-client.zip`, available on the website at `/client/pommesbude-client.zip` or from the operator), e.g. to `C:\pommesbude`.
   Put the **`relay.json`** from the operator into the same folder (next to `Setup.cmd`).
2. **Double-click `Setup.cmd`.** Enter your website username and password (the same you use to log in); the setup fetches everything else itself.
   If OBS Studio is missing or older than version 30, the setup offers to install or upgrade it automatically (Windows asks once for admin rights). Then start OBS once, close the wizard with **Cancel**, quit OBS and press Enter in the setup.

Afterwards you have three desktop shortcuts: **Stream starten** (start), **Stream Stop** and **Voice**.
   If Mumble (the voice client) is missing, the setup installs it automatically (Windows asks once for admin rights) and configures it (96 kbit/s Opus, low delay, RNNoise noise suppression, voice activation).

## 4. Streaming

1. **Double-click "Stream starten".** OBS starts in the background, a window appears after a few seconds.
2. **Choose** what to stream: a screen or an open window/game. Double-click or "Streamen".
   - *Ton von* (audio from): default is the audio of the chosen window. For screen streams pick the game here, otherwise the stream is silent.
   - *Spielaufnahme (Hook)*: only for games in true fullscreen. Borderless windows work without it.
   - *Kamera*: pick a webcam and tick "Kamera zusätzlich senden", then it runs as a separate 720p stream next to the picture. "Nur Kamera" in the list = webcam only, no screen.
   - *Voice-Chat beitreten (Mumble)*: when ticked, Mumble starts along with the stream and joins the channel. If Mumble is already running it is left alone. The choice is remembered.
3. A small **LIVE** window stays at the bottom right: **Wechseln** opens the chooser again (stream keeps running), **Kamera an/aus** toggles the webcam separately, **Stream beenden** stops everything.
4. Alternatively: **Stream Stop** on the desktop. Do not kill OBS via Task Manager, otherwise OBS asks about "safe mode" on the next start.

Hotkeys while streaming (fixed OBS scenes): `Ctrl+Alt+1/2` = monitor 1/2 (pick the monitor once in OBS), `Ctrl+Alt+3` = back to the chooser scene.

## Audio

- Only the audio of **one** application is sent (the one under "Ton von"). The voice chat never ends up in the stream.
- The microphone is not sent, you talk in the voice chat anyway.

## 5. Voice (Mumble)

- **Join**: tick "Voice-Chat beitreten" in the chooser of "Stream starten" (on by default), double-click **Voice** on the desktop, or click **🎙 Voice beitreten** at the top of the website, or **Voice** in the LIVE window. Mumble opens and is in the channel right away, no password, no prompts. If Mumble is already running, a second click just hands the address to it.
- Who is in the voice chat is shown next to the button on the website (and as 🎙 on the grey name chips). *(stumm)* = mic off, *(taub)* = deafened.
- **Voice activation** is preset (headsets). Prefer push-to-talk: in Mumble **Settings → Audio Input → Transmission: Push To Talk**, then set the key under **Shortcuts**.
- Mute / deafen: the buttons at the top of Mumble (or set shortcuts there). Mumble minimises to the tray; closing the window quits it.
- Quality: Opus 96 kbit/s, usually under 50 ms delay. If your mic level is off, run Mumble → **Settings → Audio Wizard** once.
- Mumble missing or uninstalled: run `Setup.cmd` again (installs it) or `winget install Mumble.Mumble.Client`.

## 6. Chat

**💬 Chat** at the top right opens the group chat next to the streams (full screen on phones). Enter sends, Shift+Enter inserts a line break, links are clickable. Unread messages show as a number on the button and in the tab title. History stays on the server (last 2000 messages).

## Updates

On start, "Stream starten" asks the server whether a new version exists and offers it. If the installed version is too old for the server, the update is mandatory. The update runs automatically; if OBS is running it is closed cleanly first. Name, stream key and settings are kept.
Manually: unpack the new package, put `relay.json` next to it, run `Setup.cmd` again.

## Troubleshooting

| Problem | Fix |
|---|---|
| Picture stutters or freezes for viewers | Your upload is too weak. OBS → Settings → Output → lower bitrate from 8000 to 6000 (or 4500). |
| Game picture stays black | Set the game to "borderless window" and pick it in the chooser without the hook. For true fullscreen tick "Spielaufnahme (Hook)". |
| "Connection failed" on start | Stream key outdated or server down. Run `Setup.cmd` again (fetches the current key). |
| I see "Waiting for approval" | Someone has to approve you under **Users**. |
| Forgot my password | Someone from the group clicks **Passwort** next to your name under **Users** on the website and sends you the temporary password. Then set your own under "Passwort". |
| Stream key leaked | Website → My stream key → **Generate new key**, then run `Setup.cmd` again. |
| Nothing happens on double-click or an error window appears | Double-click **Stream Stop** once, wait 10 s, then "Stream starten" again. Details are in `%LOCALAPPDATA%\stream-relay\launcher.log`. |
| Chooser window is empty or "No connection to OBS" | Quit OBS completely (Stream Stop), wait 10 s, try again. If it persists: run `Setup.cmd` again. |
| Camera stays black | The camera is in use by another program, turn video off there. Or toggle the camera off and on in the LIVE window. |
| "Voice" does nothing or says Mumble is not installed | Run `Setup.cmd` again, it installs Mumble. Then click "Voice" again. |
| Mumble asks for a certificate or shows the audio wizard | Click through once with "Next"; this only happens if Mumble was used before the setup ran. |
| Others cannot hear me / I hear nothing | Check the mute/deafen icons at the top of Mumble (red = off). Then Settings → Audio Input/Output → pick the right device (headset). |
| "Failed to start output" mentioning NVENC/AMD | The encoder does not match your GPU. Run `Setup.cmd` again, it picks the encoder automatically (NVIDIA, AMD, Intel or CPU). Force one: `client\setup-obs.ps1 -Encoder x264`. |
| Hotkeys do not work | Some games swallow Ctrl+Alt+number. Set other keys in OBS under Settings → Hotkeys. |

Requirement for streaming: at least **10 Mbit/s upload free** (speedtest.net), about 13 with camera. Otherwise lower the bitrate, see table.

# Streaming and watching on your own server (1080p60)

Voice stays in Discord. Only video goes through the group's own server. Everything happens on **one** website.
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

1. On the website click **My stream key** at the top. Copy the key (the part after the colon, 48 characters).
2. **Unpack the client package** (`pommesbude-client.zip`, available on the website at `/client/pommesbude-client.zip` or from the operator), e.g. to `C:\pommesbude`.
   Put the **`relay.json`** from the operator into the same folder (next to `Setup.cmd`).
3. **Double-click `Setup.cmd`.** Enter username and stream key.
   If OBS Studio is missing or older than version 30, the setup offers to install or upgrade it automatically (Windows asks once for admin rights). Then start OBS once, close the wizard with **Cancel**, quit OBS and press Enter in the setup.

Afterwards you have two desktop shortcuts: **Stream starten** (start) and **Stream Stop**.

## 4. Streaming

1. **Double-click "Stream starten".** OBS starts in the background, a window appears after a few seconds.
2. **Choose** what to stream: a screen or an open window/game. Double-click or "Streamen".
   - *Ton von* (audio from): default is the audio of the chosen window. For screen streams pick the game here, otherwise the stream is silent.
   - *Spielaufnahme (Hook)*: only for games in true fullscreen. Borderless windows work without it.
   - *Kamera*: pick a webcam and tick "Kamera zusätzlich senden", then it runs as a separate 720p stream next to the picture. "Nur Kamera" in the list = webcam only, no screen.
3. A small **LIVE** window stays at the bottom right: **Wechseln** opens the chooser again (stream keeps running), **Kamera an/aus** toggles the webcam separately, **Stream beenden** stops everything.
4. Alternatively: **Stream Stop** on the desktop. Do not kill OBS via Task Manager, otherwise OBS asks about "safe mode" on the next start.

Hotkeys while streaming (fixed OBS scenes): `Ctrl+Alt+1/2` = monitor 1/2 (pick the monitor once in OBS), `Ctrl+Alt+3` = back to the chooser scene.

## Audio

- Only the audio of **one** application is sent (the one under "Ton von"). Discord voice never ends up in the stream.
- The microphone is not sent, you talk in Discord anyway.

## Updates

On start, "Stream starten" asks the server whether a new version exists and offers it. If the installed version is too old for the server, the update is mandatory. The update runs automatically (OBS must not be running); name, stream key and settings are kept.
Manually: unpack the new package, put `relay.json` next to it, run `Setup.cmd` again.

## Troubleshooting

| Problem | Fix |
|---|---|
| Picture stutters or freezes for viewers | Your upload is too weak. OBS → Settings → Output → lower bitrate from 8000 to 6000 (or 4500). |
| Game picture stays black | Set the game to "borderless window" and pick it in the chooser without the hook. For true fullscreen tick "Spielaufnahme (Hook)". |
| "Connection failed" on start | Stream key wrong or server down. Check "My stream key" on the website, run `Setup.cmd` again. |
| I see "Waiting for approval" | Someone has to approve you under **Users**. |
| Stream key leaked | Website → My stream key → **Generate new key**, then run `Setup.cmd` again. |
| Nothing happens on double-click or an error window appears | Double-click **Stream Stop** once, wait 10 s, then "Stream starten" again. Details are in `%LOCALAPPDATA%\stream-relay\launcher.log`. |
| Chooser window is empty or "No connection to OBS" | Quit OBS completely (Stream Stop), wait 10 s, try again. If it persists: run `Setup.cmd` again. |
| Camera stays black | The camera is in use by Discord or similar, turn video off there. Or toggle the camera off and on in the LIVE window. |
| Hotkeys do not work | Some games swallow Ctrl+Alt+number. Set other keys in OBS under Settings → Hotkeys. |

Requirement for streaming: at least **10 Mbit/s upload free** (speedtest.net), about 13 with camera. Otherwise lower the bitrate, see table.

<#
.SYNOPSIS
  Einmal-Setup fuer einen Streamer-PC: OBS-Profile, Szenensammlungen, WHIP-Zugang, obs-websocket, Launcher und Desktop-Verknuepfungen.

.DESCRIPTION
  Rechtsklick -> "Mit PowerShell ausfuehren", oder in einer PowerShell:
    powershell -ExecutionPolicy Bypass -File .\setup-obs.ps1
  Die Adresse der Website kommt aus relay.json (liegt neben diesem Skript oder eine Ebene hoeher, wird vom Betreiber verteilt),
  sonst aus -Domain, sonst wird sie abgefragt.
  Optional ohne Rueckfragen:
    .\setup-obs.ps1 -Name max -StreamKey "<48 Hex-Zeichen von der Website>" -Domain stream.example.org
  Update (vom Launcher aufgerufen; uebernimmt Name, Stream-Key, Adresse und Einstellungen der bestehenden Installation):
    .\setup-obs.ps1 -Update
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9_-]{2,20}$')]
    [string]$Name,
    [string]$StreamKey,
    [string]$Domain,
    [string]$ObsDir = 'C:\Program Files\obs-studio',
    [ValidateSet('', 'nvenc', 'amf', 'qsv', 'x264')]
    [string]$Encoder,
    [switch]$Update
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$profileName = 'StreamRelay'
$collectionName = 'StreamRelay'
$launcherDir = Join-Path $env:LOCALAPPDATA 'stream-relay'

function Fail($msg) { Write-Host "FEHLER: $msg" -ForegroundColor Red; if (-not $Update) { Read-Host 'Enter zum Beenden' | Out-Null }; exit 1 }

# Version des Pakets (VERSION liegt im Paket-Root, eine Ebene ueber client/, oder direkt neben dem Skript)
$pkgVersion = '0.0.0'
foreach ($vf in @((Join-Path $here '..\VERSION'), (Join-Path $here 'VERSION'))) { if (Test-Path $vf) { $pkgVersion = (Get-Content $vf -Raw).Trim(); break } }

# Bestehende Installation (fuer Update und um Einstellungen zu behalten)
$existingCfg = $null
if (Test-Path (Join-Path $launcherDir 'launcher.json')) { $existingCfg = Get-Content (Join-Path $launcherDir 'launcher.json') -Raw | ConvertFrom-Json }

# --- 0. Vorbedingungen ---------------------------------------------------------
if (Get-Process obs64 -ErrorAction SilentlyContinue) { Fail 'OBS laeuft noch. Bitte erst beenden (Stream Stop).' }
$obsExe = Join-Path $ObsDir 'bin\64bit\obs64.exe'
if (-not (Test-Path $obsExe) -and $existingCfg -and $existingCfg.obsExe -and (Test-Path $existingCfg.obsExe)) { $obsExe = $existingCfg.obsExe }
function Get-ObsVersion { if (Test-Path $obsExe) { try { [version](((Get-Item $obsExe).VersionInfo.ProductVersion) -replace '[^\d.].*$', '') } catch { [version]'0.0' } } else { $null } }
# OBS fehlt oder ist zu alt (WHIP gibt es ab 30): Installation/Update per winget anbieten, sonst Download-Seite oeffnen.
function Ensure-Obs {
    $v = Get-ObsVersion
    if ($v -and $v -ge [version]'30.0') { return }
    $what = if ($v) { "OBS $v ist zu alt, mindestens Version 30 wird gebraucht." } else { "OBS Studio wurde nicht gefunden ($obsExe)." }
    if ($Update) { Fail "$what Bitte OBS aktualisieren (https://obsproject.com/download) und den Launcher erneut starten." }
    Write-Host $what -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $verb = if ($v) { 'aktualisieren' } else { 'installieren' }
        $a = Read-Host "Jetzt automatisch $verb (per winget)? Dauert 1-2 Minuten, Windows fragt einmal nach Admin-Rechten. [J/n]"
        if ($a -eq '' -or $a -match '^[jJyY]') {
            $cmd = if ($v) { 'upgrade' } else { 'install' }
            & winget $cmd --id OBSProject.OBSStudio -e --accept-package-agreements --accept-source-agreements
            if (-not (Test-Path $obsExe)) { $script:obsExe = 'C:\Program Files\obs-studio\bin\64bit\obs64.exe' }
            $v = Get-ObsVersion
            if ($v -and $v -ge [version]'30.0') {
                Write-Host "OBS $v ist installiert. Bitte OBS jetzt EINMAL starten, den Assistenten mit Abbrechen schliessen und OBS wieder beenden." -ForegroundColor Yellow
                Read-Host 'Danach hier Enter druecken' | Out-Null
                if (Get-Process obs64 -ErrorAction SilentlyContinue) { Fail 'OBS laeuft noch. Bitte beenden und Setup erneut starten.' }
                return
            }
            Write-Host 'winget hat OBS nicht auf Version 30 oder neuer gebracht.' -ForegroundColor Yellow
        }
    }
    Start-Process 'https://obsproject.com/download'
    Fail 'Bitte OBS Studio 30 oder neuer von obsproject.com installieren (Seite wurde geoeffnet), einmal starten, schliessen, dann Setup erneut ausfuehren.'
}
Ensure-Obs
$ObsDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $obsExe))
$ver = Get-ObsVersion
Write-Host "OBS $ver gefunden." -ForegroundColor Green

$cfg = Join-Path $env:APPDATA 'obs-studio'
$profilesDir = Join-Path $cfg 'basic\profiles'
$scenesDir = Join-Path $cfg 'basic\scenes'
if (-not (Test-Path $profilesDir) -or -not (Test-Path $scenesDir)) {
    Fail 'OBS wurde noch nie gestartet. Bitte OBS einmal oeffnen, den Assistenten abbrechen, schliessen, dann Skript erneut starten.'
}

# --- 1. Eingaben --------------------------------------------------------------
if ($Update) {
    # Alles aus der bestehenden Installation, keine Rueckfragen
    if (-not $existingCfg) { Fail 'Keine bestehende Installation gefunden (launcher.json fehlt). Bitte normales Setup ausfuehren.' }
    $Name = [string]$existingCfg.name
    $Domain = [string]$existingCfg.domain
    if (-not $Encoder -and $existingCfg.encoder) { $Encoder = [string]$existingCfg.encoder }
    $svcOld = Join-Path $profilesDir "$profileName\service.json"
    if (Test-Path $svcOld) {
        $tok = (Get-Content $svcOld -Raw | ConvertFrom-Json).settings.bearer_token
        if ($tok -match ':([0-9a-f]{48})$') { $StreamKey = $Matches[1] }
    }
    if (-not $StreamKey) { Fail 'Stream-Key der bestehenden Installation nicht gefunden. Bitte normales Setup ausfuehren.' }
    Write-Host "Update auf Version $pkgVersion fuer '$Name' ($Domain) ..." -ForegroundColor Cyan
}

# relay.json: Adresse der Website, vom Betreiber verteilt
if (-not $Domain) {
    foreach ($rf in @((Join-Path $here 'relay.json'), (Join-Path $here '..\relay.json'))) {
        if (Test-Path $rf) { $relay = Get-Content $rf -Raw | ConvertFrom-Json; if ($relay.domain) { $Domain = [string]$relay.domain; break } }
    }
}
if (-not $Domain) {
    Write-Host 'Keine relay.json gefunden. Die Adresse der Website bekommst du vom Betreiber (z. B. stream.example.org).'
    do { $Domain = ((Read-Host 'Adresse der Website (ohne https://)').Trim().ToLower() -replace '^https?://', '' -replace '/.*$', '') } until ($Domain -match '^[a-z0-9.-]+$')
}
if (-not $Name) {
    do { $Name = (Read-Host 'Dein Benutzername auf der Website (klein geschrieben)').Trim().ToLower() } until ($Name -match '^[a-z0-9_-]{2,20}$')
}
# Stream-Key: mit Name + Website-Passwort anmelden und den Key vom Server holen (kein Kopieren noetig).
if (-not $StreamKey) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    for ($attempt = 1; $attempt -le 3 -and -not $StreamKey; $attempt++) {
        $sec = Read-Host "Dein Passwort auf https://$Domain/" -AsSecureString
        $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        if (-not $pw) { continue }
        try {
            $body = @{ name = $Name; password = $pw } | ConvertTo-Json -Compress
            Invoke-RestMethod -Uri "https://$Domain/api/login" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -SessionVariable web -TimeoutSec 15 | Out-Null
            $me = Invoke-RestMethod -Uri "https://$Domain/api/me" -WebSession $web -TimeoutSec 15
            Invoke-RestMethod -Uri "https://$Domain/api/logout" -Method Post -WebSession $web -TimeoutSec 15 -ErrorAction SilentlyContinue | Out-Null
            if ($me.status -ne 'approved') { Fail "Dein Konto '$Name' ist noch nicht freigegeben. Bitte jemanden aus der Gruppe bitten, dich auf der Website unter 'Nutzer' freizuschalten, dann Setup erneut starten." }
            $StreamKey = [string]$me.streamKey
            Write-Host 'Angemeldet, Stream-Key vom Server geholt.' -ForegroundColor Green
        } catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -eq 401) { Write-Host 'Name oder Passwort falsch.' -ForegroundColor Yellow }
            elseif ($code -eq 429) { Fail 'Zu viele Fehlversuche. Bitte 15 Minuten warten.' }
            else { Fail "Website https://$Domain/ nicht erreichbar: $($_.Exception.Message)" }
        }
    }
    if (-not $StreamKey) { Fail 'Anmeldung fehlgeschlagen. Passwort auf der Website pruefen (dort gibt es auch "Passwort" zum Aendern).' }
}
if ($StreamKey -notmatch '^[0-9a-f]{48}$') { Fail 'Stream-Key sieht falsch aus (48 Hex-Zeichen erwartet).' }

# --- 1b. Voice-Chat (Mumble) -----------------------------------------------------
# Der Server sagt, ob Voice eingerichtet ist (mumble://-Adresse mit Server-Passwort, Nachweis = Stream-Key).
# Dann: Mumble per winget installieren, falls es fehlt, und beim ersten Mal die Client-Einstellungen vorbelegen
# (Assistenten aus, 96 kbit/s Opus, Low delay, RNNoise, Sprachaktivierung), damit "Voice" sofort funktioniert.
$voiceUrl = ''
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $body = @{ name = $Name; streamKey = $StreamKey } | ConvertTo-Json -Compress
    $v = Invoke-RestMethod -Uri "https://$Domain/api/client/voice" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 -UseBasicParsing
    if ($v.voiceUrl) { $voiceUrl = [string]$v.voiceUrl }
} catch { Write-Host "Voice-Abfrage beim Server fehlgeschlagen ($($_.Exception.Message)), Voice wird uebersprungen." -ForegroundColor Yellow }
function Get-MumbleExe {
    try { $c = (Get-ItemProperty 'Registry::HKEY_CLASSES_ROOT\mumble\shell\open\command' -ErrorAction Stop).'(default)'; if ($c -match '^"([^"]+)"') { if (Test-Path $Matches[1]) { return $Matches[1] } } } catch {}
    foreach ($p in @("$env:ProgramFiles\Mumble\client\mumble.exe", "${env:ProgramFiles(x86)}\Mumble\client\mumble.exe")) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}
function Ensure-Mumble {
    if (Get-MumbleExe) { return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host 'Mumble (Voice-Chat) fehlt und winget ist nicht verfuegbar. Bitte von https://www.mumble.info/downloads/ installieren.' -ForegroundColor Yellow
        if (-not $Update) { Start-Process 'https://www.mumble.info/downloads/' }
        return
    }
    if (-not $Update) {
        $a = Read-Host 'Mumble (Voice-Chat der Gruppe) ist nicht installiert. Jetzt automatisch installieren (per winget, Windows fragt einmal nach Admin-Rechten)? [J/n]'
        if (-not ($a -eq '' -or $a -match '^[jJyY]')) { return }
    }
    & winget install --id Mumble.Mumble.Client -e --accept-package-agreements --accept-source-agreements --silent
    if (Get-MumbleExe) { Write-Host 'Mumble installiert.' -ForegroundColor Green } else { Write-Host 'Mumble konnte nicht installiert werden (spaeter: Setup.cmd erneut ausfuehren oder winget install Mumble.Mumble.Client).' -ForegroundColor Yellow }
}
# Einstellungen nur anlegen, wenn Mumble noch nie lief (sonst bleiben die eigenen Einstellungen unangetastet).
function Initialize-MumbleSettings {
    $dir = Join-Path $env:LOCALAPPDATA 'Mumble\Mumble'
    $file = Join-Path $dir 'mumble_settings.json'
    if (Test-Path $file) { return }
    if (Get-Process mumble -ErrorAction SilentlyContinue) { return }
    # Client-Zertifikat vorab erzeugen (RSA, PKCS#12 ohne Passwort, wie Mumble es selbst macht), sonst zeigt Mumble beim ersten Start einen Assistenten.
    $cert = ''
    try {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest("CN=$Name, O=Mumble User", $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $x = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(20))
        $cert = [Convert]::ToBase64String($x.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, ''))
    } catch { Write-Host "Mumble-Zertifikat konnte nicht vorab erzeugt werden ($($_.Exception.Message)); Mumble fragt beim ersten Start einmal nach (einfach 'Weiter')." -ForegroundColor Yellow }
    $s = [ordered]@{
        settings_version = 1
        mumble_has_quit_normally = $true
        misc = [ordered]@{ audio_wizard_has_been_shown = $true; viewed_server_ping_consent_message = $true }
        audio = [ordered]@{ transmit_mode = 'VAD'; vad_mode = 'SignalToNoise'; audio_quality = 96000; allow_low_delay_mode = $true; noise_cancel_mode = 'RNN' }
        network = [ordered]@{ frames_per_packet = 1; reconnect_automatically = $true }
        tts = [ordered]@{ enable_tts = $false }
        update = [ordered]@{ check_for_updates = $false }
    }
    if ($cert) { $s['certificate'] = $cert }
    New-Item -ItemType Directory -Force $dir | Out-Null
    [IO.File]::WriteAllText($file, ($s | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    Write-Host 'Mumble-Einstellungen vorbelegt (96 kbit/s, Low delay, RNNoise, Sprachaktivierung).' -ForegroundColor Green
}
if ($voiceUrl) { Ensure-Mumble; if (Get-MumbleExe) { Initialize-MumbleSettings } }
else { Write-Host 'Voice ist auf diesem Server nicht eingerichtet, Mumble wird uebersprungen.' -ForegroundColor Yellow }

# --- 2. Encoder nach Grafikkarte waehlen ---------------------------------------
# Die Vorlagen sind fuer NVIDIA (NVENC). Andere GPUs bekommen den passenden Hardware-Encoder, sonst x264 (CPU).
if (-not $Encoder) {
    $gpus = ((Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ' ')
    $Encoder = if ($gpus -match 'NVIDIA') { 'nvenc' } elseif ($gpus -match 'AMD|Radeon') { 'amf' } elseif ($gpus -match 'Intel') { 'qsv' } else { 'x264' }
    Write-Host "Grafikkarte: $gpus -> Encoder $Encoder" -ForegroundColor Green
}
$encoderId = @{ nvenc = 'obs_nvenc_h264_tex'; amf = 'h264_texture_amf'; qsv = 'obs_qsv11_v2'; x264 = 'obs_x264' }[$Encoder]
function Get-EncoderSettings([int]$bitrate) {
    switch ($Encoder) {
        'amf'  { @{ rate_control = 'CBR'; bitrate = $bitrate; keyint_sec = 2; preset = 'quality'; profile = 'high'; bf = 0 } }
        'qsv'  { @{ rate_control = 'CBR'; bitrate = $bitrate; keyint_sec = 2; target_usage = 'TU4'; profile = 'high' } }
        'x264' { @{ rate_control = 'CBR'; bitrate = $bitrate; keyint_sec = 2; preset = 'veryfast'; profile = 'high'; tune = 'zerolatency' } }
        default { $null }   # nvenc: Vorlage aus dem Paket
    }
}

# --- 3. Profile (Bildschirm/Spiel + Kamera) ------------------------------------
function Install-Profile([string]$dirName, [string]$srcDir, [int]$bitrate) {
    $dst = Join-Path $profilesDir $dirName
    New-Item -ItemType Directory -Force $dst | Out-Null
    $ini = Get-Content (Join-Path $here "$srcDir\basic.ini") -Raw
    $ini = $ini -replace '(?m)^Encoder=.*$', "Encoder=$encoderId"
    [IO.File]::WriteAllText((Join-Path $dst 'basic.ini'), $ini, (New-Object Text.UTF8Encoding $false))
    $enc = Get-EncoderSettings $bitrate
    if ($enc) { [IO.File]::WriteAllText((Join-Path $dst 'streamEncoder.json'), ($enc | ConvertTo-Json), (New-Object Text.UTF8Encoding $false)) }
    else { Copy-Item (Join-Path $here "$srcDir\streamEncoder.json") (Join-Path $dst 'streamEncoder.json') -Force }
    $svc = (Get-Content (Join-Path $here "$srcDir\service.json.tmpl") -Raw).Replace('{{DOMAIN}}', $Domain).Replace('{{NAME}}', $Name).Replace('{{STREAMKEY}}', $StreamKey)
    [IO.File]::WriteAllText((Join-Path $dst 'service.json'), $svc, (New-Object Text.UTF8Encoding $false))
}
Install-Profile $profileName 'profile' 8000
Install-Profile 'StreamRelayCam' 'profile-cam' 2500
Write-Host "Profile '$profileName' und 'StreamRelayCam' angelegt (Encoder $encoderId)." -ForegroundColor Green

# --- 3. Szenensammlungen ---------------------------------------------------------
Copy-Item (Join-Path $here 'scenes\StreamRelay.json') (Join-Path $scenesDir "$collectionName.json") -Force
Copy-Item (Join-Path $here 'scenes\StreamRelayCam.json') (Join-Path $scenesDir 'StreamRelayCam.json') -Force
Write-Host "Szenensammlungen '$collectionName' und 'StreamRelayCam' angelegt." -ForegroundColor Green

# --- 4. Profil + Szenensammlung in user.ini aktiv setzen -----------------------
# OBS 31+: user.ini, aeltere Versionen: global.ini. Beide Dateien behandeln, wenn vorhanden.
function Set-IniValue([string]$file, [string]$section, [string]$key, [string]$value) {
    if (-not (Test-Path $file)) { return }
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($l in @(Get-Content $file -Encoding UTF8)) { if ($null -ne $l) { $lines.Add($l) } }
    $secIdx = $lines.FindIndex({ param($l) $l -eq "[$section]" })
    if ($secIdx -lt 0) { $lines.Add("[$section]"); $lines.Add("$key=$value"); }
    else {
        $end = $secIdx + 1
        while ($end -lt $lines.Count -and -not $lines[$end].StartsWith('[')) { $end++ }
        $found = $false
        for ($i = $secIdx + 1; $i -lt $end; $i++) {
            if ($lines[$i] -match "^$([regex]::Escape($key))=") { $lines[$i] = "$key=$value"; $found = $true; break }
        }
        if (-not $found) { $lines.Insert($end, "$key=$value") }
    }
    [IO.File]::WriteAllLines($file, $lines, (New-Object Text.UTF8Encoding $false))
}
foreach ($ini in @((Join-Path $cfg 'user.ini'), (Join-Path $cfg 'global.ini'))) {
    Set-IniValue $ini 'Basic' 'Profile' $profileName
    Set-IniValue $ini 'Basic' 'ProfileDir' $profileName
    Set-IniValue $ini 'Basic' 'SceneCollection' $collectionName
    Set-IniValue $ini 'Basic' 'SceneCollectionFile' $collectionName
    Set-IniValue $ini 'General' 'FirstRun' 'true'
    Set-IniValue $ini 'General' 'ConfirmOnExit' 'false'
    Set-IniValue $ini 'BasicWindow' 'SysTrayEnabled' 'true'
    Set-IniValue $ini 'BasicWindow' 'SysTrayMinimizeToTray' 'true'
}
Write-Host 'Profil und Szenensammlung als aktiv gesetzt.' -ForegroundColor Green

# --- 5. obs-websocket aktivieren (Launcher steuert OBS darueber) --------------
$wsDir = Join-Path $cfg 'plugin_config\obs-websocket'
New-Item -ItemType Directory -Force $wsDir | Out-Null
$wsFile = Join-Path $wsDir 'config.json'
$ws = if (Test-Path $wsFile) { Get-Content $wsFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
$wsPassword = if ($ws.server_password) { $ws.server_password } else { -join ((48..57 + 65..90 + 97..122) | Get-Random -Count 20 | ForEach-Object { [char]$_ }) }
$wsPort = if ($ws.server_port) { [int]$ws.server_port } else { 4455 }
$wsNew = [ordered]@{ alerts_enabled = $false; auth_required = $true; first_load = $false; server_enabled = $true; server_password = $wsPassword; server_port = $wsPort }
[IO.File]::WriteAllText($wsFile, ($wsNew | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
Write-Host "obs-websocket aktiviert (Port $wsPort)." -ForegroundColor Green

# --- 6. Launcher installieren (inkl. Kopie des Setups fuer spaetere Updates) ------------
New-Item -ItemType Directory -Force $launcherDir | Out-Null
Copy-Item (Join-Path $here 'stream.ps1') (Join-Path $launcherDir 'stream.ps1') -Force
$keep = @{ lastValue = ''; lastGameHook = $false; lastCamera = ''; lastCamOn = $false }
if ($existingCfg) { foreach ($k in @($keep.Keys)) { if ($existingCfg.PSObject.Properties.Name -contains $k) { $keep[$k] = $existingCfg.$k } } }
$launcherCfg = [ordered]@{
    version = $pkgVersion; obsExe = $obsExe; encoder = $Encoder; wsPort = $wsPort; wsPortCam = ($wsPort + 1); wsPassword = $wsPassword
    domain = $Domain; name = $Name; streamKey = $StreamKey; voiceUrl = $voiceUrl
    lastValue = $keep.lastValue; lastGameHook = $keep.lastGameHook; lastCamera = $keep.lastCamera; lastCamOn = $keep.lastCamOn
}
[IO.File]::WriteAllText((Join-Path $launcherDir 'launcher.json'), ($launcherCfg | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))

# --- 7. Desktop-Verknuepfungen -------------------------------------------------
$desktop = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
foreach ($old in 'Stream Monitor 1', 'Stream Monitor 2', 'Stream Spiel') { Remove-Item (Join-Path $desktop "$old.lnk") -ErrorAction SilentlyContinue }
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk = $shell.CreateShortcut((Join-Path $desktop 'Stream starten.lnk'))
$lnk.TargetPath = $ps
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherDir\stream.ps1`""
$lnk.WorkingDirectory = $launcherDir
$lnk.WindowStyle = 7
$lnk.IconLocation = "$obsExe,0"
$lnk.Description = 'Startet OBS, fragt was gestreamt werden soll, und streamt'
$lnk.Save()
$lnk = $shell.CreateShortcut((Join-Path $desktop 'Stream Stop.lnk'))
$lnk.TargetPath = $ps
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherDir\stream.ps1`" -Stop"
$lnk.WorkingDirectory = $launcherDir
$lnk.WindowStyle = 7
$lnk.IconLocation = "$obsExe,0"
$lnk.Description = 'Beendet den Stream und OBS'
$lnk.Save()
$shortcuts = '"Stream starten" und "Stream Stop"'
if ($voiceUrl) {
    $lnk = $shell.CreateShortcut((Join-Path $desktop 'Voice.lnk'))
    $lnk.TargetPath = $ps
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherDir\stream.ps1`" -Voice"
    $lnk.WorkingDirectory = $launcherDir
    $lnk.WindowStyle = 7
    $mExe = Get-MumbleExe; if ($mExe) { $lnk.IconLocation = "$mExe,0" }
    $lnk.Description = 'Dem Voice-Chat der Gruppe beitreten (Mumble)'
    $lnk.Save()
    $shortcuts = '"Stream starten", "Stream Stop" und "Voice"'
} else { Remove-Item (Join-Path $desktop 'Voice.lnk') -ErrorAction SilentlyContinue }
Write-Host "Desktop-Verknuepfungen angelegt: $shortcuts." -ForegroundColor Green

# --- 8. Zusammenfassung ---------------------------------------------------------
Write-Host ''
Write-Host '==================================================================' -ForegroundColor Cyan
Write-Host " Fertig, $Name (Client-Version $pkgVersion)." -ForegroundColor Cyan
Write-Host " Zuschauen (alle Streams): https://$Domain/"
Write-Host ' Streamen: Doppelklick auf die DESKTOP-Verknuepfung "Stream starten" (nicht auf stream.ps1 im Paket), Bildschirm oder Fenster waehlen, fertig.'
Write-Host ' Kamera:   im Auswahlfenster "Kamera zusaetzlich senden" oder "Nur Kamera", im LIVE-Fenster jederzeit an/aus.'
if ($voiceUrl) { Write-Host ' Voice:    Doppelklick auf "Voice" (oder Knopf "Voice beitreten" auf der Website / im LIVE-Fenster), Mumble verbindet sich von selbst.' }
Write-Host ' Hotkeys im Stream:    Strg+Alt+1/2 = Monitor 1/2, Strg+Alt+3 = Auswahl-Szene'
Write-Host '==================================================================' -ForegroundColor Cyan
if (-not $Update) { Read-Host 'Enter zum Beenden' | Out-Null }

<#
  Stream-Launcher: startet OBS, prueft Profil/Szenensammlung per obs-websocket, zeigt eine Auswahl
  (Bildschirm oder offenes Fenster/Spiel, optional Kamera), setzt die Quellen und startet den Stream.
  Kamera laeuft als zweite OBS-Instanz (Profil StreamRelayCam, eigener WebSocket-Port) auf den Pfad <name>-cam.
  Wird von setup-obs.ps1 nach %LOCALAPPDATA%\stream-relay\stream.ps1 kopiert; Einstellungen in launcher.json daneben.
  Aufruf: powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File stream.ps1 [-Stop]
#>
param([switch]$Stop)

$ErrorActionPreference = 'Stop'
# Eigenes Konsolenfenster verstecken (falls ohne -WindowStyle Hidden gestartet).
try {
    $hw = Add-Type -Name ConsoleWin -Namespace StreamRelay -PassThru -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);'
    [void]$hw::ShowWindow($hw::GetConsoleWindow(), 0)
} catch {}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# Wird das Skript aus dem Paketordner statt ueber die Desktop-Verknuepfung gestartet, die installierte Konfiguration nutzen.
$installDir = Join-Path $env:LOCALAPPDATA 'stream-relay'
if (-not (Test-Path (Join-Path $here 'launcher.json')) -and (Test-Path (Join-Path $installDir 'launcher.json'))) { $here = $installDir }
$cfgPath = Join-Path $here 'launcher.json'
if (-not (Test-Path $cfgPath)) { [System.Windows.Forms.MessageBox]::Show("Der Client ist noch nicht eingerichtet (launcher.json fehlt). Bitte zuerst Setup.cmd ausfuehren, danach die Desktop-Verknuepfung 'Stream starten' benutzen.", 'Stream', 'OK', 'Error') | Out-Null; exit 1 }
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
foreach ($k in 'lastValue', 'lastGameHook', 'lastCamera', 'lastCamOn', 'wsPortCam') {
    if (-not ($cfg.PSObject.Properties.Name -contains $k)) { $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $(if ($k -eq 'wsPortCam') { [int]$cfg.wsPort + 1 } elseif ($k -like 'last*On' -or $k -eq 'lastGameHook') { $false } else { '' }) }
}
$obsExe = $cfg.obsExe
$obsBin = Split-Path -Parent $obsExe
$obsCfg = Join-Path $env:APPDATA 'obs-studio'
$log = Join-Path $here 'launcher.log'
function Log($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) -Encoding UTF8 }
function Fail($m) { Log "FEHLER: $m"; [System.Windows.Forms.MessageBox]::Show($m, 'Stream', 'OK', 'Error') | Out-Null; exit 1 }
function Save-Cfg { $cfg | ConvertTo-Json | Set-Content $cfgPath -Encoding UTF8 }
if ((Test-Path $log) -and ((Get-Item $log).Length -gt 512KB)) { Remove-Item $log -Force }
Log "=== Start (Stop=$Stop)"
trap {
    $msg = "Unerwarteter Fehler: $($_.Exception.Message)`nZeile $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
    Log $msg; Log $_.ScriptStackTrace
    [System.Windows.Forms.MessageBox]::Show("$msg`n`nDetails: $log", 'Stream', 'OK', 'Error') | Out-Null
    exit 1
}

# ---------------------------------------------------------------- obs-websocket v5 Client (mehrere Verbindungen: 'main' und 'cam')
$script:conns = @{}
$script:reqId = 0
function Ws-Recv($ws) {
    $buf = New-Object byte[] 65536
    $ms = New-Object IO.MemoryStream
    do {
        $seg = New-Object ArraySegment[byte] -ArgumentList @(,$buf)
        $t = $ws.ReceiveAsync($seg, [Threading.CancellationToken]::None)
        if (-not $t.Wait(8000)) { throw 'obs-websocket antwortet nicht (Timeout).' }
        $r = $t.Result
        $ms.Write($buf, 0, $r.Count)
    } while (-not $r.EndOfMessage)
    return ([Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json)
}
function Ws-Send($ws, $obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 8 -Compress))
    $seg = New-Object ArraySegment[byte] -ArgumentList @(,$bytes)
    $ws.SendAsync($seg, 'Text', $true, [Threading.CancellationToken]::None).Wait(5000) | Out-Null
}
function Ws-Connect([string]$id, [string]$password, [int]$port) {
    $ws = New-Object Net.WebSockets.ClientWebSocket
    $ws.Options.AddSubProtocol('obswebsocket.json')
    $ws.ConnectAsync([Uri]"ws://127.0.0.1:$port", [Threading.CancellationToken]::None).Wait(5000) | Out-Null
    $hello = Ws-Recv $ws
    if ($hello.op -ne 0) { throw "Unerwartete Hello-Nachricht: $($hello | ConvertTo-Json -Compress)" }
    $identify = @{ op = 1; d = @{ rpcVersion = 1; eventSubscriptions = 0 } }
    if ($hello.d.authentication) {
        $sha = [Security.Cryptography.SHA256]::Create()
        $secret = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($password + $hello.d.authentication.salt)))
        $identify.d.authentication = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret + $hello.d.authentication.challenge)))
    }
    Ws-Send $ws $identify
    $ident = Ws-Recv $ws
    if ($ident.op -ne 2) { throw 'obs-websocket: Anmeldung fehlgeschlagen (Passwort falsch? setup-obs.ps1 erneut ausfuehren).' }
    $script:conns[$id] = $ws
}
function Ws-Close([string]$id) {
    $ws = $script:conns[$id]
    if ($ws) { try { $ws.CloseAsync('NormalClosure', '', [Threading.CancellationToken]::None).Wait(2000) | Out-Null } catch {}; $script:conns.Remove($id) }
}
# Obs <type> [data] [-On main|cam]. Code 207 = "OBS is not ready": bis 60 s alle 500 ms erneut fragen.
function Obs([string]$type, $data = @{}, [string]$On = 'main') {
    $ws = $script:conns[$On]
    if (-not $ws) { throw "Keine Verbindung zu OBS ($On)." }
    for ($try = 0; $try -lt 120; $try++) {
        $script:reqId++
        $id = "r$($script:reqId)"
        Ws-Send $ws @{ op = 6; d = @{ requestType = $type; requestId = $id; requestData = $data } }
        do { $m = Ws-Recv $ws } while ($m.op -ne 7 -or $m.d.requestId -ne $id)
        if ($m.d.requestStatus.result) { return $m.d.responseData }
        if ($m.d.requestStatus.code -ne 207) { throw "OBS-Anfrage $type fehlgeschlagen: $($m.d.requestStatus.comment) (Code $($m.d.requestStatus.code))" }
        if ($try -eq 0) { Log "OBS ($On) laedt noch, warte ..." }
        Start-Sleep -Milliseconds 500
    }
    throw "OBS ($On) ist nach 60 s immer noch nicht bereit ($type)."
}
function Obs-Connected([string]$On) { [bool]$script:conns[$On] }

# ---------------------------------------------------------------- OBS-Instanzen
# Beide Instanzen laufen mit --multi. Die Kamera-Instanz bekommt Port/Passwort per Kommandozeile (ueberschreibt die Plugin-Config).
function Get-ObsProcs { @(Get-CimInstance Win32_Process -Filter "Name='obs64.exe'") }
function Find-Instance([string]$profile) { Get-ObsProcs | Where-Object { $_.CommandLine -like "*--profile $profile *" -or $_.CommandLine -like "*--profile `"$profile`"*" } | Select-Object -First 1 }
function Start-Instance([string]$id) {
    if ($id -eq 'cam') {
        $args = @('--multi', '--minimize-to-tray', '--disable-updater', '--profile', 'StreamRelayCam', '--collection', 'StreamRelayCam', '--websocket_port', "$($cfg.wsPortCam)", '--websocket_password', "$($cfg.wsPassword)")
        $port = [int]$cfg.wsPortCam; $profile = 'StreamRelayCam'
    } else {
        $args = @('--multi', '--minimize-to-tray', '--disable-updater', '--profile', 'StreamRelay', '--collection', 'StreamRelay')
        $port = [int]$cfg.wsPort; $profile = 'StreamRelay'
    }
    if (-not (Find-Instance $profile)) {
        Start-Process -FilePath $obsExe -WorkingDirectory $obsBin -ArgumentList $args | Out-Null
        Log "OBS ($id) gestartet"
    }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $lastErr = $null
    while ($sw.Elapsed.TotalSeconds -lt 40) {
        try { Ws-Connect $id $cfg.wsPassword $port; break } catch { $lastErr = $_; Start-Sleep -Milliseconds 700 }
    }
    if (-not (Obs-Connected $id)) { throw "Keine Verbindung zu OBS ($id, Port $port).`n$lastErr`n`nsetup-obs.ps1 erneut ausfuehren, falls der WebSocket-Server nicht aktiv ist." }
    Log "verbunden ($id)"
    # Profil/Szenensammlung sicherstellen (wenn nicht gerade gestreamt wird)
    if (-not (Obs 'GetStreamStatus' @{} $id).outputActive) {
        $p = Obs 'GetProfileList' @{} $id
        $c = Obs 'GetSceneCollectionList' @{} $id
        if (($p.profiles -notcontains $profile) -or ($c.sceneCollections -notcontains $profile)) {
            throw "OBS ($id) kennt Profil oder Szenensammlung '$profile' nicht.`nProfile: $($p.profiles -join ', ')`nSammlungen: $($c.sceneCollections -join ', ')`n`nsetup-obs.ps1 erneut ausfuehren."
        }
        if ($p.currentProfileName -ne $profile) { Obs 'SetCurrentProfile' @{ profileName = $profile } $id | Out-Null; Log "Profil korrigiert ($id, war $($p.currentProfileName))" }
        if ($c.currentSceneCollectionName -ne $profile) { Obs 'SetCurrentSceneCollection' @{ sceneCollectionName = $profile } $id | Out-Null; Log "Szenensammlung korrigiert ($id)"; Start-Sleep 1 }
    }
}
function Stop-Instance([string]$id) {
    $profile = if ($id -eq 'cam') { 'StreamRelayCam' } else { 'StreamRelay' }
    if (Obs-Connected $id) { try { if ((Obs 'GetStreamStatus' @{} $id).outputActive) { Obs 'StopStream' @{} $id | Out-Null; Start-Sleep 1 } } catch {}; Ws-Close $id }
    $proc = Find-Instance $profile
    if ($proc) { & "$env:SystemRoot\System32\taskkill.exe" /PID $proc.ProcessId | Out-Null; Log "OBS ($id) beendet" }
}

# ---------------------------------------------------------------- Stop
if ($Stop) {
    foreach ($id in 'main', 'cam') {
        $port = if ($id -eq 'cam') { [int]$cfg.wsPortCam } else { [int]$cfg.wsPort }
        try { Ws-Connect $id $cfg.wsPassword $port } catch {}
        Stop-Instance $id
    }
    # Rest ohne Profil-Kennung (z. B. von Hand gestartetes OBS) und andere Launcher-Instanzen (LIVE-Fenster)
    if (Get-Process obs64 -ErrorAction SilentlyContinue) { & "$env:SystemRoot\System32\taskkill.exe" /IM obs64.exe | Out-Null }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*stream.ps1*' -and $_.CommandLine -notlike '*-Stop*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Log 'Stop: fertig'
    exit 0
}

# ---------------------------------------------------------------- 0. Update-Pruefung gegen den Server
# GET https://<domain>/api/config -> clientVersion (neueste), minClientVersion (Pflicht), clientUrl (Zip).
# Zu alt fuer den Server: Update ist Pflicht. Sonst: Update anbieten, "Spaeter" = 24 h Ruhe.
function Get-InstalledVersion { try { [version]($cfg.version) } catch { [version]'0.0.0' } }
function Invoke-ClientUpdate([string]$zipUrl, [string]$newVersion) {
    $tmp = Join-Path $env:TEMP 'pommesbude-update'
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $zip = Join-Path $tmp 'client.zip'
    Log "Update: lade $zipUrl"
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -TimeoutSec 60 -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp 'pkg') -Force
    $setup = Get-ChildItem (Join-Path $tmp 'pkg') -Recurse -Filter 'setup-obs.ps1' | Select-Object -First 1
    if (-not $setup) { throw 'Im Update-Paket fehlt setup-obs.ps1.' }
    # relay.json des Betreibers mitgeben, falls vorhanden (Domain bleibt ohnehin aus launcher.json)
    Log "Update: fuehre $($setup.FullName) -Update aus"
    $p = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($setup.FullName)`"", '-Update' -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw "Setup meldete Fehler (Exit $($p.ExitCode)). Details im Fenster von setup-obs.ps1 oder: setup-obs.ps1 aus dem neuen Paket von Hand ausfuehren." }
    Log "Update auf $newVersion abgeschlossen, starte neuen Launcher"
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$here\stream.ps1`"" | Out-Null
    exit 0
}
try {
    $remote = Invoke-RestMethod -Uri "https://$($cfg.domain)/api/config" -TimeoutSec 5 -UseBasicParsing
    $installed = Get-InstalledVersion
    $latest = [version]$remote.clientVersion
    $minimum = [version]$remote.minClientVersion
    $zipUrl = if ($remote.clientUrl) { if ($remote.clientUrl -like 'http*') { $remote.clientUrl } else { "https://$($cfg.domain)$($remote.clientUrl)" } } else { $null }
    Log "Version installiert $installed, Server $latest (mindestens $minimum)"
    $obsRunning = [bool](Get-Process obs64 -ErrorAction SilentlyContinue)
    if ($installed -lt $minimum) {
        if (-not $zipUrl) { Fail "Diese Version ($installed) ist zu alt fuer den Server (mindestens $minimum), aber der Server bietet kein Update-Paket an. Bitte neues Paket vom Betreiber holen und setup-obs.ps1 ausfuehren." }
        if ($obsRunning) { Fail "Update auf $latest ist erforderlich (installiert: $installed). Bitte erst 'Stream Stop' ausfuehren, dann 'Stream starten' erneut." }
        $r = [System.Windows.Forms.MessageBox]::Show("Update erforderlich: Version $installed ist zu alt fuer den Server (mindestens $minimum).`n`nJetzt auf $latest aktualisieren? Ohne Update kann nicht gestreamt werden.", 'Stream', 'OKCancel', 'Warning')
        if ($r -ne 'OK') { Log 'Pflicht-Update abgelehnt, Ende'; exit 1 }
        try { Invoke-ClientUpdate $zipUrl "$latest" } catch { Fail "Update fehlgeschlagen: $_" }
    } elseif ($installed -lt $latest -and $zipUrl -and -not $obsRunning) {
        $snooze = 0; try { $snooze = [long]$cfg.snoozeUntil } catch {}
        if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $snooze) {
            $r = [System.Windows.Forms.MessageBox]::Show("Update verfuegbar: $installed -> $latest.`n`nJetzt installieren? (Dauert ein paar Sekunden, OBS darf dabei nicht laufen.)", 'Stream', 'YesNo', 'Question')
            if ($r -eq 'Yes') {
                try { Invoke-ClientUpdate $zipUrl "$latest" } catch { [System.Windows.Forms.MessageBox]::Show("Update fehlgeschlagen, es geht mit der alten Version weiter:`n$_", 'Stream', 'OK', 'Warning') | Out-Null }
            } else {
                $cfg | Add-Member -NotePropertyName snoozeUntil -NotePropertyValue ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 86400) -Force; Save-Cfg
                Log 'Update auf spaeter verschoben (24 h)'
            }
        }
    }
} catch { Log "Update-Pruefung uebersprungen: $($_.Exception.Message)" }

# ---------------------------------------------------------------- 1. Haupt-Instanz starten und verbinden
if (-not (Test-Path $obsExe)) { Fail "OBS nicht gefunden: $obsExe" }
$mainWasRunning = [bool](Find-Instance 'StreamRelay')
try { Start-Instance 'main' } catch { Fail "$_" }
$streaming = [bool](Obs 'GetStreamStatus').outputActive
$camStreaming = $false
if (Find-Instance 'StreamRelayCam') { try { Start-Instance 'cam'; $camStreaming = [bool](Obs 'GetStreamStatus' @{} 'cam').outputActive } catch { Log "Kamera-Instanz nicht erreichbar: $_" } }

# ---------------------------------------------------------------- 2. Auswahl-Listen aus OBS holen
function Get-Monitors {
    (Obs 'GetInputPropertiesListPropertyItems' @{ inputName = 'Auto Bildschirm'; propertyName = 'monitor_id' }).propertyItems |
        Where-Object { $_.itemValue } | ForEach-Object { [pscustomobject]@{ Kind = 'monitor'; Label = $_.itemName; Value = $_.itemValue } }
}
function Get-Windows {
    $skip = '^(obs64\.exe|powershell\.exe|explorer\.exe|TextInputHost\.exe|ApplicationFrameHost\.exe|SystemSettings\.exe)$'
    (Obs 'GetInputPropertiesListPropertyItems' @{ inputName = 'Auto Fenster'; propertyName = 'window' }).propertyItems |
        Where-Object { $_.itemValue -and $_.itemValue -match '^(.*):([^:]*):([^:]*)$' } |
        ForEach-Object {
            $null = $_.itemValue -match '^(.*):([^:]*):([^:]*)$'
            $exe = $Matches[3]; $title = $Matches[1]
            if ($exe -match $skip -or -not $title) { return }
            [pscustomobject]@{ Kind = 'window'; Label = "$title  ($exe)"; Value = $_.itemValue; Exe = $exe; Title = $title }
        } | Sort-Object Exe, Title
}
function Get-Cameras {
    try {
        (Obs 'GetInputPropertiesListPropertyItems' @{ inputName = 'Kamera-Liste'; propertyName = 'video_device_id' }).propertyItems |
            Where-Object { $_.itemValue } | ForEach-Object { [pscustomobject]@{ Label = $_.itemName; Value = $_.itemValue } }
    } catch { Log "Kameraliste nicht verfuegbar: $_"; @() }
}

# ---------------------------------------------------------------- 3. Picker
function Show-Picker($monitors, $windows, $cameras, $last) {
    $f = New-Object Windows.Forms.Form
    $f.Text = if ($streaming -or $camStreaming) { 'Stream wechseln' } else { 'Was soll gestreamt werden?' }
    $f.Size = New-Object Drawing.Size(620, 640); $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.BackColor = [Drawing.Color]::FromArgb(43, 45, 49); $f.ForeColor = [Drawing.Color]::FromArgb(219, 222, 225)
    $f.Font = New-Object Drawing.Font('Segoe UI', 10)
    $dark = [Drawing.Color]::FromArgb(30, 31, 34)

    $lv = New-Object Windows.Forms.ListView
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false; $lv.HideSelection = $false; $lv.ShowGroups = $true
    $lv.Location = New-Object Drawing.Point(12, 12); $lv.Size = New-Object Drawing.Size(580, 380)
    $lv.BackColor = $dark; $lv.ForeColor = $f.ForeColor; $lv.BorderStyle = 'None'
    $lv.Columns.Add('Quelle', 400) | Out-Null; $lv.Columns.Add('Programm', 160) | Out-Null
    $gM = $lv.Groups.Add('m', 'Bildschirme'); $gW = $lv.Groups.Add('w', 'Fenster und Spiele'); $gC = $lv.Groups.Add('c', 'Kamera')
    foreach ($m in $monitors) { $it = New-Object Windows.Forms.ListViewItem($m.Label); $it.SubItems.Add('Monitor') | Out-Null; $it.Group = $gM; $it.Tag = $m; $lv.Items.Add($it) | Out-Null }
    foreach ($w in $windows) { $it = New-Object Windows.Forms.ListViewItem($w.Title); $it.SubItems.Add($w.Exe) | Out-Null; $it.Group = $gW; $it.Tag = $w; $lv.Items.Add($it) | Out-Null }
    if ($cameras.Count) {
        $it = New-Object Windows.Forms.ListViewItem('Nur Kamera (kein Bildschirm, kein Spiel)'); $it.SubItems.Add('Kamera') | Out-Null; $it.Group = $gC
        $it.Tag = [pscustomobject]@{ Kind = 'camonly'; Label = 'Nur Kamera'; Value = 'camonly' }; $lv.Items.Add($it) | Out-Null
    }
    $pre = $lv.Items | Where-Object { $_.Tag.Value -eq $last } | Select-Object -First 1
    if (-not $pre -and $lv.Items.Count) { $pre = $lv.Items[0] }
    if ($pre) { $pre.Selected = $true; $pre.EnsureVisible() }
    $f.Controls.Add($lv)

    $y = 405
    $lblA = New-Object Windows.Forms.Label; $lblA.Text = 'Ton von:'; $lblA.Location = New-Object Drawing.Point(12, ($y + 4)); $lblA.AutoSize = $true; $f.Controls.Add($lblA)
    $cbA = New-Object Windows.Forms.ComboBox; $cbA.DropDownStyle = 'DropDownList'; $cbA.Location = New-Object Drawing.Point(90, $y); $cbA.Size = New-Object Drawing.Size(502, 28)
    $cbA.BackColor = $dark; $cbA.ForeColor = $f.ForeColor
    [void]$cbA.Items.Add('(wie gewaehltes Fenster)'); [void]$cbA.Items.Add('(kein Ton)')
    foreach ($e in ($windows | Select-Object -ExpandProperty Exe -Unique | Sort-Object)) { [void]$cbA.Items.Add($e) }
    $cbA.SelectedIndex = 0
    $f.Controls.Add($cbA)

    $y = 440
    $lblC = New-Object Windows.Forms.Label; $lblC.Text = 'Kamera:'; $lblC.Location = New-Object Drawing.Point(12, ($y + 4)); $lblC.AutoSize = $true; $f.Controls.Add($lblC)
    $cbC = New-Object Windows.Forms.ComboBox; $cbC.DropDownStyle = 'DropDownList'; $cbC.Location = New-Object Drawing.Point(90, $y); $cbC.Size = New-Object Drawing.Size(300, 28)
    $cbC.BackColor = $dark; $cbC.ForeColor = $f.ForeColor
    [void]$cbC.Items.Add('(keine)')
    foreach ($c in $cameras) { [void]$cbC.Items.Add($c.Label) }
    $cbC.SelectedIndex = 0
    $preC = $cameras | Where-Object { $_.Value -eq $cfg.lastCamera } | Select-Object -First 1
    if ($preC) { $cbC.SelectedItem = $preC.Label }
    $f.Controls.Add($cbC)
    $chkC = New-Object Windows.Forms.CheckBox; $chkC.Text = 'Kamera zusaetzlich senden (720p)'; $chkC.Location = New-Object Drawing.Point(400, ($y + 2)); $chkC.AutoSize = $true
    $chkC.Checked = [bool]$cfg.lastCamOn -and [bool]$preC; $chkC.Enabled = [bool]$cameras.Count
    $f.Controls.Add($chkC)
    if (-not $cameras.Count) { $lblC.Text = 'Kamera: keine gefunden' }

    $chk = New-Object Windows.Forms.CheckBox; $chk.Text = 'Spielaufnahme (Hook) statt Fensteraufnahme, fuer Vollbild-Spiele'; $chk.Location = New-Object Drawing.Point(12, 478); $chk.AutoSize = $true
    $chk.Checked = [bool]$cfg.lastGameHook; $f.Controls.Add($chk)
    $hint = New-Object Windows.Forms.Label; $hint.Text = 'Discord-Voice wird nie mit uebertragen (kein Desktop-Audio). Hotkeys im Stream: Strg+Alt+1/2/3.'
    $hint.Location = New-Object Drawing.Point(12, 508); $hint.AutoSize = $true; $hint.ForeColor = [Drawing.Color]::FromArgb(148, 155, 164); $f.Controls.Add($hint)

    $ok = New-Object Windows.Forms.Button; $ok.Text = if ($streaming -or $camStreaming) { 'Wechseln' } else { 'Streamen' }; $ok.Location = New-Object Drawing.Point(452, 560); $ok.Size = New-Object Drawing.Size(140, 32)
    $ok.BackColor = [Drawing.Color]::FromArgb(88, 101, 242); $ok.ForeColor = [Drawing.Color]::White; $ok.FlatStyle = 'Flat'; $ok.DialogResult = 'OK'
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Abbrechen'; $cancel.Location = New-Object Drawing.Point(330, 560); $cancel.Size = New-Object Drawing.Size(112, 32)
    $cancel.BackColor = [Drawing.Color]::FromArgb(49, 51, 56); $cancel.ForeColor = $f.ForeColor; $cancel.FlatStyle = 'Flat'; $cancel.DialogResult = 'Cancel'
    $f.Controls.Add($ok); $f.Controls.Add($cancel); $f.AcceptButton = $ok; $f.CancelButton = $cancel
    $lv.Add_DoubleClick({ if ($lv.SelectedItems.Count) { $f.DialogResult = 'OK'; $f.Close() } })
    $lv.Add_SelectedIndexChanged({ if ($lv.SelectedItems.Count -and $lv.SelectedItems[0].Tag.Kind -eq 'camonly') { $chkC.Checked = $true; if ($cbC.SelectedIndex -eq 0 -and $cbC.Items.Count -gt 1) { $cbC.SelectedIndex = 1 } } })
    $f.Add_Shown({ $f.Activate() })

    if ($f.ShowDialog() -ne 'OK' -or -not $lv.SelectedItems.Count) { return $null }
    $cam = $null
    if ($cbC.SelectedIndex -gt 0) { $cam = $cameras | Where-Object { $_.Label -eq $cbC.SelectedItem } | Select-Object -First 1 }
    $sel = $lv.SelectedItems[0].Tag
    if ($sel.Kind -eq 'camonly' -and -not $cam) { [System.Windows.Forms.MessageBox]::Show('Fuer "Nur Kamera" bitte eine Kamera auswaehlen.', 'Stream', 'OK', 'Warning') | Out-Null; return (Show-Picker $monitors $windows $cameras $last) }
    return [pscustomobject]@{ Sel = $sel; Audio = $cbA.SelectedItem; GameHook = $chk.Checked; Camera = $cam; CamOn = ($chkC.Checked -and $cam) -or ($sel.Kind -eq 'camonly') }
}

# ---------------------------------------------------------------- 4. Quellen setzen, Streams starten/stoppen
function Set-ItemEnabled($sourceName, [bool]$on) {
    $id = (Obs 'GetSceneItemId' @{ sceneName = 'Auto'; sourceName = $sourceName }).sceneItemId
    Obs 'SetSceneItemEnabled' @{ sceneName = 'Auto'; sceneItemId = $id; sceneItemEnabled = $on } | Out-Null
}
function Apply-Main($choice, $windows) {
    $sel = $choice.Sel
    if ($sel.Kind -eq 'monitor') {
        Obs 'SetInputSettings' @{ inputName = 'Auto Bildschirm'; inputSettings = @{ monitor_id = $sel.Value } } | Out-Null
        Set-ItemEnabled 'Auto Bildschirm' $true; Set-ItemEnabled 'Auto Fenster' $false; Set-ItemEnabled 'Auto Spiel' $false
    } elseif ($choice.GameHook) {
        Obs 'SetInputSettings' @{ inputName = 'Auto Spiel'; inputSettings = @{ capture_mode = 'window'; window = $sel.Value; priority = 2 } } | Out-Null
        Set-ItemEnabled 'Auto Spiel' $true; Set-ItemEnabled 'Auto Fenster' $false; Set-ItemEnabled 'Auto Bildschirm' $false
    } else {
        Obs 'SetInputSettings' @{ inputName = 'Auto Fenster'; inputSettings = @{ window = $sel.Value; priority = 1; method = 2 } } | Out-Null
        Set-ItemEnabled 'Auto Fenster' $true; Set-ItemEnabled 'Auto Spiel' $false; Set-ItemEnabled 'Auto Bildschirm' $false
    }
    $audioWin = $null
    switch -Regex ($choice.Audio) {
        '^\(wie' { if ($sel.Kind -ne 'monitor') { $audioWin = $sel.Value } }
        '^\(kein' { $audioWin = $null }
        default { $audioWin = ($windows | Where-Object { $_.Exe -eq $choice.Audio } | Select-Object -First 1).Value }
    }
    if ($audioWin) { Obs 'SetInputSettings' @{ inputName = 'Auto Ton'; inputSettings = @{ window = $audioWin; priority = 2 } } | Out-Null; Set-ItemEnabled 'Auto Ton' $true }
    else { Set-ItemEnabled 'Auto Ton' $false }
    Obs 'SetCurrentProgramScene' @{ sceneName = 'Auto' } | Out-Null
    Log "Quelle: $($sel.Label) | Ton: $($choice.Audio) | Hook: $($choice.GameHook)"
}
function Start-MainStream {
    if ((Obs 'GetStreamStatus').outputActive) { return }
    try { Obs 'StartStream' | Out-Null } catch { throw "Stream konnte nicht gestartet werden:`n$_`n`nStream-Key pruefen (Website > Mein Stream-Key) oder OBS-Log ansehen: $obsCfg\logs" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 500; if ((Obs 'GetStreamStatus').outputActive) { $script:streaming = $true; Log 'Stream laeuft'; return } }
    throw "OBS meldet nach 15 s keinen aktiven Stream. Stream-Key pruefen (Website > Mein Stream-Key) oder OBS-Log ansehen: $obsCfg\logs"
}
function Stop-MainStream {
    try { if ((Obs 'GetStreamStatus').outputActive) { Obs 'StopStream' | Out-Null; Log 'Bildschirm-Stream gestoppt' } } catch {}
    $script:streaming = $false
}
function Start-Cam($camera) {
    if (-not (Obs-Connected 'cam')) { Start-Instance 'cam' }
    Obs 'SetInputSettings' @{ inputName = 'Kamera'; inputSettings = @{ video_device_id = $camera.Value; res_type = 1; resolution = '1280x720'; active = $true } } 'cam' | Out-Null
    # Die DirectShow-Quelle bleibt nach dem Laden ohne Geraet in einem "aktiv, aber ohne Bild"-Zustand:
    # einmal deaktivieren und wieder aktivieren (Button "Aktivieren" der Quelle), dann liefert die Kamera.
    $isActive = [bool](Obs 'GetInputSettings' @{ inputName = 'Kamera' } 'cam').inputSettings.active
    if ($isActive) { Obs 'PressInputPropertiesButton' @{ inputName = 'Kamera'; propertyName = 'activate' } 'cam' | Out-Null; Start-Sleep -Milliseconds 700 }
    Obs 'PressInputPropertiesButton' @{ inputName = 'Kamera'; propertyName = 'activate' } 'cam' | Out-Null
    Start-Sleep -Milliseconds 700
    if (-not (Obs 'GetStreamStatus' @{} 'cam').outputActive) {
        try { Obs 'StartStream' @{} 'cam' | Out-Null } catch { throw "Kamera-Stream konnte nicht gestartet werden:`n$_" }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 500; if ((Obs 'GetStreamStatus' @{} 'cam').outputActive) { break } }
        if (-not (Obs 'GetStreamStatus' @{} 'cam').outputActive) { throw 'OBS (Kamera) meldet nach 15 s keinen aktiven Stream.' }
    }
    $script:camStreaming = $true
    $cfg.lastCamera = $camera.Value; $cfg.lastCamOn = $true; Save-Cfg
    Log "Kamera laeuft: $($camera.Label)"
}
function Stop-Cam {
    if (Obs-Connected 'cam') { try { if ((Obs 'GetStreamStatus' @{} 'cam').outputActive) { Obs 'StopStream' @{} 'cam' | Out-Null; Log 'Kamera gestoppt' } } catch {} }
    $script:camStreaming = $false
    $cfg.lastCamOn = $false; Save-Cfg
}

# ---------------------------------------------------------------- 5. Auswahl anwenden
function Apply-Choice($choice, $windows) {
    if ($choice.Sel.Kind -eq 'camonly') {
        Stop-MainStream
    } else {
        Apply-Main $choice $windows
        Start-MainStream
        $cfg.lastValue = $choice.Sel.Value; $cfg.lastGameHook = $choice.GameHook; Save-Cfg
    }
    if ($choice.CamOn -and $choice.Camera) { Start-Cam $choice.Camera } else { Stop-Cam }
    if ($choice.Sel.Kind -eq 'camonly') { $cfg.lastValue = 'camonly'; Save-Cfg }
}

$monitors = @(Get-Monitors)
$windows = @(Get-Windows)
$cameras = @(Get-Cameras)
$choice = Show-Picker $monitors $windows $cameras $cfg.lastValue
if (-not $choice) {
    Log 'abgebrochen'
    if (-not $streaming -and -not $camStreaming -and -not $mainWasRunning) { Stop-Instance 'main'; Stop-Instance 'cam' } else { Ws-Close 'main'; Ws-Close 'cam' }
    exit 0
}
try { Apply-Choice $choice $windows } catch { Fail "$_" }

# ---------------------------------------------------------------- 6. LIVE-Fenster
function Live-Text {
    $parts = @()
    if ($script:streaming) { $parts += "LIVE: $($cfg.lastValue -replace '^.*:([^:]*)$', '$1')" }
    if ($script:camStreaming) { $parts += 'Kamera an' }
    if (-not $parts) { $parts = @('kein Stream aktiv') }
    return ($parts -join '  |  ')
}
$live = New-Object Windows.Forms.Form
$live.Text = 'LIVE'; $live.Size = New-Object Drawing.Size(430, 96); $live.StartPosition = 'Manual'; $live.TopMost = $true
$live.FormBorderStyle = 'FixedToolWindow'; $live.ShowInTaskbar = $true
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$live.Location = New-Object Drawing.Point(($area.Right - 440), ($area.Bottom - 106))
$live.BackColor = [Drawing.Color]::FromArgb(43, 45, 49); $live.ForeColor = [Drawing.Color]::FromArgb(219, 222, 225); $live.Font = New-Object Drawing.Font('Segoe UI', 9)
$lbl = New-Object Windows.Forms.Label; $lbl.Location = New-Object Drawing.Point(10, 8); $lbl.Size = New-Object Drawing.Size(400, 20)
$lbl.ForeColor = [Drawing.Color]::FromArgb(35, 165, 89); $live.Controls.Add($lbl)
$lbl.Text = "$(if ($choice.Sel.Kind -eq 'camonly') { 'Nur Kamera' } else { 'LIVE: ' + $choice.Sel.Label })$(if ($camStreaming -and $choice.Sel.Kind -ne 'camonly') { '  |  Kamera an' })"
function New-LiveButton($text, $x, $w, $bg) {
    $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.Location = New-Object Drawing.Point($x, 34); $b.Size = New-Object Drawing.Size($w, 28)
    $b.BackColor = $bg; $b.ForeColor = if ($bg.R -gt 150) { [Drawing.Color]::White } else { $live.ForeColor }; $b.FlatStyle = 'Flat'
    $live.Controls.Add($b); $b
}
$bSwitch = New-LiveButton 'Wechseln' 10 110 ([Drawing.Color]::FromArgb(49, 51, 56))
$bCam = New-LiveButton $(if ($camStreaming) { 'Kamera aus' } else { 'Kamera an' }) 130 110 ([Drawing.Color]::FromArgb(49, 51, 56))
$bStop = New-LiveButton 'Stream beenden' 250 160 ([Drawing.Color]::FromArgb(218, 55, 60))
$bCam.Enabled = [bool]$cameras.Count
$bSwitch.Add_Click({
    $w = @(Get-Windows); $m = @(Get-Monitors); $c = @(Get-Cameras)
    $ch = Show-Picker $m $w $c $cfg.lastValue
    if ($ch) {
        try { Apply-Choice $ch $w } catch { [System.Windows.Forms.MessageBox]::Show("$_", 'Stream', 'OK', 'Error') | Out-Null }
        $lbl.Text = "$(if ($ch.Sel.Kind -eq 'camonly') { 'Nur Kamera' } else { 'LIVE: ' + $ch.Sel.Label })$(if ($script:camStreaming -and $ch.Sel.Kind -ne 'camonly') { '  |  Kamera an' })"
        $bCam.Text = if ($script:camStreaming) { 'Kamera aus' } else { 'Kamera an' }
    }
})
$bCam.Add_Click({
    try {
        if ($script:camStreaming) { Stop-Cam; $bCam.Text = 'Kamera an' }
        else {
            $cams = @(Get-Cameras)
            $cam = $cams | Where-Object { $_.Value -eq $cfg.lastCamera } | Select-Object -First 1
            if (-not $cam) {
                # Kamera waehlen
                $pick = New-Object Windows.Forms.Form; $pick.Text = 'Kamera waehlen'; $pick.Size = New-Object Drawing.Size(420, 150); $pick.StartPosition = 'CenterScreen'; $pick.TopMost = $true; $pick.FormBorderStyle = 'FixedDialog'
                $pick.BackColor = $live.BackColor; $pick.ForeColor = $live.ForeColor
                $cb = New-Object Windows.Forms.ComboBox; $cb.DropDownStyle = 'DropDownList'; $cb.Location = New-Object Drawing.Point(12, 15); $cb.Size = New-Object Drawing.Size(380, 28)
                foreach ($x in $cams) { [void]$cb.Items.Add($x.Label) }; if ($cams.Count) { $cb.SelectedIndex = 0 }
                $okb = New-Object Windows.Forms.Button; $okb.Text = 'Kamera an'; $okb.Location = New-Object Drawing.Point(272, 60); $okb.Size = New-Object Drawing.Size(120, 30); $okb.DialogResult = 'OK'
                $pick.Controls.Add($cb); $pick.Controls.Add($okb); $pick.AcceptButton = $okb
                if ($pick.ShowDialog() -ne 'OK' -or $cb.SelectedIndex -lt 0) { return }
                $cam = $cams[$cb.SelectedIndex]
            }
            Start-Cam $cam; $bCam.Text = 'Kamera aus'
        }
        $lbl.Text = Live-Text
    } catch { [System.Windows.Forms.MessageBox]::Show("$_", 'Stream', 'OK', 'Error') | Out-Null }
})
$bStop.Add_Click({
    Stop-Instance 'main'; Stop-Instance 'cam'
    Log 'Stream beendet, OBS geschlossen'
    $live.Close()
})
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 5000
$timer.Add_Tick({
    try {
        $okMain = -not $script:streaming -or (Obs 'GetStreamStatus').outputActive
        $okCam = -not $script:camStreaming -or (Obs 'GetStreamStatus' @{} 'cam').outputActive
        if (-not ($okMain -and $okCam)) { $lbl.Text = '! Stream unterbrochen, OBS verbindet neu ...'; $lbl.ForeColor = [Drawing.Color]::FromArgb(240, 178, 50) }
        elseif ($lbl.Text -like '!*') { $lbl.Text = Live-Text; $lbl.ForeColor = [Drawing.Color]::FromArgb(35, 165, 89) }
    } catch {
        if (-not (Get-Process obs64 -ErrorAction SilentlyContinue)) { $timer.Stop(); Log 'OBS beendet, LIVE-Fenster geschlossen'; $live.Close() }
        else { $lbl.Text = '! Verbindung zu OBS verloren' }
    }
})
$live.Add_Shown({ $timer.Start() })
$live.Add_FormClosed({ $timer.Stop(); Ws-Close 'main'; Ws-Close 'cam' })
[void]$live.ShowDialog()
Log '=== Ende'

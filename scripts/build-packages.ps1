# Baut die beiden Download-Pakete nach dist\:
#   pommesbude-server.zip  = alles, was ein Betreiber braucht (server/, web/, client/, docs/, VERSION, README, LICENSE, relay.example.json)
#                            -> auf dem Server entpacken und server/install.sh ausfuehren; der Server baut daraus auch das Client-Paket
#   pommesbude-client.zip  = nur der Windows-Client (client/, Anleitungen, VERSION, relay.example.json)
#                            -> identisch zu dem Paket, das der Server unter /client/pommesbude-client.zip ausliefert
# Instanzdaten (relay.json, server/.env, PRIVATE*.md) werden nie eingepackt.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null

function New-Package([string]$name, [scriptblock]$fill) {
    $stage = Join-Path $env:TEMP "pommesbude-stage-$name"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force $stage | Out-Null
    & $fill $stage
    # Sicherheitsnetz: nichts Instanzspezifisches im Paket
    $bad = Get-ChildItem $stage -Recurse -File | Where-Object { $_.Name -in 'relay.json', '.env', 'launcher.json' -or $_.Name -like '.env.*' -or $_.Name -like 'PRIVATE*' -or $_.FullName -like '*node_modules*' }
    if ($bad) { throw "Paket $name enthaelt verbotene Dateien: $($bad.FullName -join ', ')" }
    $zip = Join-Path $dist "$name.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    # Nicht Compress-Archive: das schreibt unter PowerShell 5.1 Backslashes in die Pfade, was unter Linux kaputte Dateinamen ergibt.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem $stage -Recurse -File) {
            $entry = $file.FullName.Substring($stage.Length + 1).Replace([char]92, [char]47)
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $archive.Dispose() }
    Remove-Item $stage -Recurse -Force
    Write-Host "$zip  (Version $version)"
}

New-Package 'pommesbude-server' {
    param($stage)
    foreach ($d in 'server', 'web', 'client', 'docs', 'scripts') {
        Copy-Item (Join-Path $root $d) (Join-Path $stage $d) -Recurse -Force
    }
    Remove-Item (Join-Path $stage 'web\node_modules') -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem (Join-Path $stage 'server') -Filter '.env*' -Force -ErrorAction SilentlyContinue | Remove-Item -Force
    foreach ($f in 'VERSION', 'README.md', 'LICENSE', 'relay.example.json', 'Setup.cmd', '.dockerignore', '.gitignore') { Copy-Item (Join-Path $root $f) $stage -Force }
}

New-Package 'pommesbude-client' {
    param($stage)
    Copy-Item (Join-Path $root 'client') (Join-Path $stage 'client') -Recurse -Force
    foreach ($f in 'docs\ANLEITUNG.md', 'docs\GUIDE.md', 'VERSION', 'relay.example.json', 'Setup.cmd') { Copy-Item (Join-Path $root $f) $stage -Force }
}

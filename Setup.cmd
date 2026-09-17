@echo off
rem Pommesbude Client-Setup: Doppelklick genuegt. Startet setup-obs.ps1 ohne PowerShell-Sicherheitsabfragen.
setlocal
set "PKG=%~dp0"
title Pommesbude Setup
rem "Aus dem Internet"-Markierung aller Paketdateien entfernen, sonst fragt PowerShell bei jedem Skript nach.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath \"%PKG%.\" -Recurse -File | Unblock-File -ErrorAction SilentlyContinue"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PKG%client\setup-obs.ps1"
endlocal

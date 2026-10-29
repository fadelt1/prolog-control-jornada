@echo off
cd /d "%~dp0"
start "Puente Prolog + GINFO (No cerrar)" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "ginfo-bridge.ps1"
timeout /t 2 /nobreak >nul
start "" "http://localhost:3005"

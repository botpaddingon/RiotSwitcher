@echo off
start "" "%WINDIR%\System32\conhost.exe" --headless powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RiotSwitcher.ps1"

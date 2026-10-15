@echo off
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0RiotSwitcher.ps1" -CreateShortcut

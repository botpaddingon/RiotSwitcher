# Prépare une mise à jour de RiotSwitcher : crée version.json (version + empreinte SHA-256 + notes).
# 1. Augmente $AppVersion dans RiotSwitcher.ps1 (ex : 2.2.0 -> 2.3.0)
# 2. Lance :  powershell -ExecutionPolicy Bypass -File publier-maj.ps1 -Notes "ce qui change"
# 3. Envoie RiotSwitcher.ps1 ET version.json sur le dépôt GitHub (en même temps).

param([string]$Notes = '')

$ps1 = Join-Path $PSScriptRoot 'RiotSwitcher.ps1'
$version = [regex]::Match((Get-Content $ps1 -Raw), '\$AppVersion\s*=\s*''([^'']+)''').Groups[1].Value
if (-not $version) { throw 'Version introuvable dans RiotSwitcher.ps1.' }
$hash = (Get-FileHash $ps1 -Algorithm SHA256).Hash.ToLower()
$json = [ordered]@{ version = $version; sha256 = $hash; notes = $Notes } | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'version.json'), $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "version.json créé pour la v$version."
Write-Host 'Envoie maintenant RiotSwitcher.ps1 et version.json sur GitHub.'

# RiotSwitcher - change de compte League of Legends en échangeant les fichiers de session.
# Ne stocke AUCUN mot de passe : uniquement les sessions "Rester connecté" créées par Riot,
# chiffrées avec la session Windows (illisibles sur un autre PC ou un autre compte Windows).
# Ne modifie pas le Riot Client et ne touche pas à Vanguard.
# Rang, winrate, réglages, etc. passent par l'API locale du client LoL (127.0.0.1, sans clé).
#
# Utilisation :
#   RiotSwitcher.ps1                    -> fenêtre principale
#   RiotSwitcher.ps1 -Account "Main"    -> lance directement ce compte (raccourcis par compte)
#   RiotSwitcher.ps1 -CreateShortcut    -> crée le raccourci "Riot Switcher" sur le bureau

param([string]$Account, [switch]$CreateShortcut)

$AppVersion  = '2.3.0'
$ReleaseNotes = @'
- Plus aucune fenêtre de terminal derrière l'appli
- Icône près de l'horloge (clic droit = lancer un compte), réduction dans la barre
- Acceptation automatique des parties
- Recherche, filtre par serveur, masquer les bannis
- Thème sombre (menu Plus)
- Sanctions du compte (ranked bloquée, chat restreint)
- Clic droit sur un compte : op.gg, graphique des LP, etc.
- Graphique de l'évolution des LP
- Actualiser tous les comptes d'un coup
- Résumé des 7 derniers jours (LP, parties, alertes)
- Export de la liste pour Discord (texte ou image)
- Sessions chiffrées avec ta session Windows
- Sauvegarde / restauration protégée par mot de passe
'@
# Adresse des mises à jour : dossier contenant version.json et RiotSwitcher.ps1 (vide = désactivé).
$UpdateBaseUrl = 'https://raw.githubusercontent.com/botpaddingon/RiotSwitcher/main'

$Root        = $PSScriptRoot
$ScriptPath  = $PSCommandPath
$DataDir     = Join-Path $env:LOCALAPPDATA 'Riot Games\Riot Client\Data'
$Store       = Join-Path $Root 'profiles'
$MetaDir     = Join-Path $Root 'meta'
$SettingsDir = Join-Path $Root 'settings'
$Backup      = Join-Path $Root '_backup'
$ClientProcs = 'RiotClientServices','RiotClientUx','RiotClientUxRender','RiotClientCrashHandler',
               'LeagueClient','LeagueClientUx','LeagueClientUxRender'
$GameProcs   = 'League of Legends'
$LcuTimeoutSec = 180
$StaleDays     = 21
$HistoryMax    = 300
$EncExt        = '.dpapi'
$TierOrder   = 'IRON','BRONZE','SILVER','GOLD','PLATINUM','EMERALD','DIAMOND','MASTER','GRANDMASTER','CHALLENGER'
$TierNames   = @{ IRON = 'Fer'; BRONZE = 'Bronze'; SILVER = 'Argent'; GOLD = 'Or'; PLATINUM = 'Platine'; EMERALD = 'Émeraude'
                  DIAMOND = 'Diamant'; MASTER = 'Maître'; GRANDMASTER = 'Grand Maître'; CHALLENGER = 'Challenger' }
$MetaProps   = 'banned','riotId','region','queue','tier','division','lp','wins','losses','prev','updated','lastUsed',
               'rank','decayAt','topChamps','sanctions','history'
$SettingsEndpoints = [ordered]@{
    'game-settings'  = '/lol-game-settings/v1/game-settings'
    'input-settings' = '/lol-game-settings/v1/input-settings'
}
# Régions du client -> régions op.gg
$OpggRegions = @{ NA = 'na'; EUW = 'euw'; EUNE = 'eune'; KR = 'kr'; JP = 'jp'; BR = 'br'; LA1 = 'lan'; LAN = 'lan'
                  LA2 = 'las'; LAS = 'las'; OC1 = 'oce'; OCE = 'oce'; TR = 'tr'; RU = 'ru'; ME1 = 'me'; ME = 'me'
                  SG2 = 'sg'; SG = 'sg'; TW2 = 'tw'; TW = 'tw'; VN2 = 'vn'; VN = 'vn'; PH2 = 'ph'; TH2 = 'th' }

New-Item -ItemType Directory -Force $Store, $MetaDir | Out-Null
try { Start-Transcript -Path (Join-Path $Root 'log.txt') -Force | Out-Null } catch { }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic, System.Security
[Windows.Forms.Application]::EnableVisualStyles()

# Toute erreur non prévue s'affiche au lieu de fermer le script en silence.
trap {
    [Windows.Forms.MessageBox]::Show("Erreur : $($_.Exception.Message)`n`nLigne $($_.InvocationInfo.ScriptLineNumber)",
        'Riot Switcher', 'OK', 'Error') | Out-Null
    exit 1
}

# Le client LoL utilise un certificat auto-signé sur 127.0.0.1 : on l'accepte pour cette adresse uniquement.
# Partout ailleurs (mises à jour), seuls les certificats valides passent.
Add-Type @"
using System;
using System.Net;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
public class RsTrustLocal : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) {
        return p == 0 || r.RequestUri.Host == "127.0.0.1";
    }
}
public static class RsDwm {
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
"@
[Net.ServicePointManager]::CertificatePolicy = New-Object RsTrustLocal
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:StatusLabel = $null
$script:CancelButton = $null
$script:Form = $null
$script:CancelWait = $false
$script:CancelAll = $false
$script:Busy = $false

# ---------- Interface (marche avec ou sans fenêtre) ----------

function Say([string]$Msg) {
    Write-Host $Msg
    if ($script:StatusLabel) { $script:StatusLabel.Text = $Msg; [Windows.Forms.Application]::DoEvents() }
}

function Wait-Ui([double]$Seconds) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end -and -not $script:CancelWait) {
        [Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Ask-YesNo([string]$Msg) {
    [Windows.Forms.MessageBox]::Show($Msg, 'Riot Switcher', 'YesNo', 'Question') -eq 'Yes'
}

function Show-Info([string]$Msg) {
    [Windows.Forms.MessageBox]::Show($Msg, 'Riot Switcher', 'OK', 'Information') | Out-Null
}

# Petite fenêtre de mot de passe (caractères masqués).
function Read-Password([string]$Prompt, [switch]$Confirm) {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Riot Switcher'; $f.FormBorderStyle = 'FixedDialog'; $f.StartPosition = 'CenterScreen'
    $f.MinimizeBox = $false; $f.MaximizeBox = $false; $f.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $f.ClientSize = New-Object Drawing.Size(380, $(if ($Confirm) { 200 } else { 140 }))
    $lbl = New-Object Windows.Forms.Label
    $lbl.Text = $Prompt; $lbl.Location = New-Object Drawing.Point(12, 10); $lbl.Size = New-Object Drawing.Size(356, 48)
    $p1 = New-Object Windows.Forms.TextBox
    $p1.UseSystemPasswordChar = $true; $p1.Location = New-Object Drawing.Point(12, 62); $p1.Width = 356
    $f.Controls.AddRange(@($lbl, $p1))
    $y = 100
    if ($Confirm) {
        $l2 = New-Object Windows.Forms.Label
        $l2.Text = 'Confirmation :'; $l2.Location = New-Object Drawing.Point(12, 96); $l2.AutoSize = $true
        $p2 = New-Object Windows.Forms.TextBox
        $p2.UseSystemPasswordChar = $true; $p2.Location = New-Object Drawing.Point(12, 118); $p2.Width = 356
        $f.Controls.AddRange(@($l2, $p2))
        $y = 158
    }
    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'OK'; $ok.DialogResult = 'OK'; $ok.Location = New-Object Drawing.Point(212, $y); $ok.Width = 75
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Annuler'; $cancel.DialogResult = 'Cancel'; $cancel.Location = New-Object Drawing.Point(293, $y); $cancel.Width = 75
    $f.Controls.AddRange(@($ok, $cancel))
    $f.AcceptButton = $ok; $f.CancelButton = $cancel
    while ($true) {
        if ($f.ShowDialog() -ne 'OK') { return $null }
        if ($p1.Text.Length -lt 6) { Show-Info 'Le mot de passe doit faire au moins 6 caractères.'; continue }
        if ($Confirm -and $p1.Text -ne $p2.Text) { Show-Info 'Les deux mots de passe ne correspondent pas.'; continue }
        return $p1.Text
    }
}

# ---------- Chiffrement des sessions (DPAPI, lié à la session Windows) ----------

function Protect-Bytes([byte[]]$Bytes) {
    return ,[Security.Cryptography.ProtectedData]::Protect($Bytes, $null, 'CurrentUser')
}

function Unprotect-Bytes([byte[]]$Bytes) {
    return ,[Security.Cryptography.ProtectedData]::Unprotect($Bytes, $null, 'CurrentUser')
}

function Get-RelativePath([string]$Base, [string]$Full) {
    return $Full.Substring($Base.TrimEnd('\').Length + 1)
}

# Dossier en clair -> dossier chiffré.
function Copy-Encrypted([string]$From, [string]$To) {
    New-Item -ItemType Directory -Force $To | Out-Null
    $From = (Resolve-Path $From).Path
    foreach ($f in Get-ChildItem $From -Recurse -File) {
        $dst = Join-Path $To ((Get-RelativePath $From $f.FullName) + $EncExt)
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        [IO.File]::WriteAllBytes($dst, (Protect-Bytes ([IO.File]::ReadAllBytes($f.FullName))))
    }
}

# Dossier chiffré (ou ancien format en clair) -> dossier en clair.
function Copy-Decrypted([string]$From, [string]$To) {
    New-Item -ItemType Directory -Force $To | Out-Null
    $From = (Resolve-Path $From).Path
    foreach ($f in Get-ChildItem $From -Recurse -File) {
        $rel = Get-RelativePath $From $f.FullName
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        if ($rel.EndsWith($EncExt)) { $rel = $rel.Substring(0, $rel.Length - $EncExt.Length); $bytes = Unprotect-Bytes $bytes }
        $dst = Join-Path $To $rel
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        [IO.File]::WriteAllBytes($dst, $bytes)
    }
}

# Chiffre sur place les fichiers encore en clair (profils créés par une ancienne version).
function Protect-Folder([string]$Dir) {
    if (-not (Test-Path $Dir)) { return }
    foreach ($f in @(Get-ChildItem $Dir -Recurse -File | Where-Object { $_.Extension -ne $EncExt })) {
        [IO.File]::WriteAllBytes($f.FullName + $EncExt, (Protect-Bytes ([IO.File]::ReadAllBytes($f.FullName))))
        Remove-Item $f.FullName -Force
    }
}

# ---------- Métadonnées (rang, ban, historique) ----------

function Get-Meta([string]$Name) {
    $f = Join-Path $MetaDir "$Name.json"
    $m = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    foreach ($p in $MetaProps) {
        if ($m.PSObject.Properties.Name -notcontains $p) { $m | Add-Member -NotePropertyName $p -NotePropertyValue $null }
    }
    # Ancien format : rang stocké sous forme de texte.
    if ($m.rank -and -not $m.queue) {
        if ($m.rank -eq 'Unranked') { $m.queue = 'None' }
        elseif ($m.rank -cmatch '^(Solo|Flex): ([A-Z]+) ?(IV|III|II|I)? (\d+) LP \((\d+)V/(\d+)D\)') {
            $m.queue = $Matches[1]; $m.tier = $Matches[2]; $m.division = $Matches[3]
            $m.lp = [int]$Matches[4]; $m.wins = [int]$Matches[5]; $m.losses = [int]$Matches[6]
        }
    }
    if (-not $m.lastUsed) { $m.lastUsed = $m.updated }
    $m.banned = [bool]$m.banned
    $m.history = @($m.history | Where-Object { $_ })
    return $m
}

function Set-Meta([string]$Name, $Meta) {
    $Meta.rank = $null
    $Meta | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $MetaDir "$Name.json") -Encoding UTF8
}

function Get-Score($o) {
    $tier = [array]::IndexOf($TierOrder, [string]$o.tier)
    $div = switch ($o.division) { 'I' { 3 } 'II' { 2 } 'III' { 1 } default { 0 } }
    return $tier * 10000 + $div * 1000 + [int]$o.lp
}

# Position sur l'échelle de classement, en LP "continus" (Fer IV 0 LP = 0, Maître 0 LP = 2800).
function Get-Ladder($o) {
    $tier = [array]::IndexOf($TierOrder, [string]$o.tier)
    if ($tier -lt 0) { return $null }
    if ($tier -ge 7) { return 2800 + [int]$o.lp }
    $div = switch ($o.division) { 'I' { 3 } 'II' { 2 } 'III' { 1 } default { 0 } }
    return $tier * 400 + $div * 100 + [int]$o.lp
}

function Format-Ladder([double]$v) {
    if ($v -ge 2800) { return "Maître+ $([int]($v - 2800)) LP" }
    $tier = [math]::Floor($v / 400)
    $div = @('IV', 'III', 'II', 'I')[[math]::Floor(($v % 400) / 100)]
    return "$($TierNames[$TierOrder[$tier]]) $div"
}

# Tri : rang le plus haut d'abord, puis rang inconnu / Unranked, puis bannis.
function Get-SortScore($m) {
    if ($m.banned) { return -2 }
    if (-not $m.tier) { return -1 }
    return Get-Score $m
}

function Format-Tier($o) {
    if (-not $o.tier) { return '' }
    $t = $TierNames[[string]$o.tier]
    if (-not $t) { $t = [string]$o.tier }
    $d = if ($o.division) { " $($o.division)" } else { '' }
    return "$t$d $($o.lp) LP"
}

function Format-Rank($m) {
    if ($m.banned) { return 'BANNI' }
    if ($m.tier) { return (Format-Tier $m) + $(if ($m.queue -eq 'Flex') { ' (Flex)' } else { '' }) }
    if ($m.queue -eq 'None') { return 'Unranked' }
    return '?'
}

function Get-DecayDays($m) {
    if (-not $m.decayAt -or $m.banned) { return $null }
    return [int][math]::Ceiling(([datetime]$m.decayAt - (Get-Date)).TotalDays)
}

function Format-Decay($m) {
    $d = Get-DecayDays $m
    if ($null -eq $d) { return '' }
    if ($d -le 0) { return '⚠ perd des LP' }
    return "⚠ perte de LP dans $d j"
}

function Format-Delta($m) {
    $p = $m.prev
    if (-not $p -or -not $m.tier -or -not $p.tier) { return '' }
    $games = ([int]$m.wins + [int]$m.losses) - ([int]$p.wins + [int]$p.losses)
    $suffix = if ($games -gt 0) { " en $games partie$(if ($games -gt 1) { 's' })" } else { '' }
    if ($p.tier -eq $m.tier -and $p.division -eq $m.division) {
        $d = [int]$m.lp - [int]$p.lp
        $txt = if ($d -gt 0) { "+$d LP" } elseif ($d -lt 0) { "$d LP" } else { '= LP' }
        return "$txt$suffix"
    }
    $arrow = if ((Get-Score $m) -gt (Get-Score $p)) { '▲' } else { '▼' }
    return "$arrow depuis $(Format-Tier $p)$suffix"
}

function Format-Winrate($m) {
    $n = [int]$m.wins + [int]$m.losses
    if ($n -le 0) { return '' }
    return '{0} % ({1}V/{2}D)' -f [math]::Round(100 * [int]$m.wins / $n), $m.wins, $m.losses
}

function Format-Sanctions($m) {
    if ($null -eq $m.sanctions) { return '' }
    if ($m.sanctions -eq '') { return 'Aucune' }
    return [string]$m.sanctions
}

function Format-Age($iso) {
    if (-not $iso) { return 'jamais' }
    $d = (Get-Date) - [datetime]$iso
    if ($d.TotalHours -lt 1) { return 'à l''instant' }
    if ($d.TotalDays -lt 1)  { return "il y a $([int]$d.TotalHours) h" }
    return "il y a $([int]$d.TotalDays) j"
}

function Test-Stale($m) {
    return $m.lastUsed -and ((Get-Date) - [datetime]$m.lastUsed).TotalDays -gt $StaleDays
}

function Get-OpggUrl($m) {
    if (-not $m.riotId -or $m.riotId -notmatch '^(.+)#(.+)$') { return $null }
    $reg = $OpggRegions[[string]$m.region]
    if (-not $reg) { $reg = if ($m.region) { ([string]$m.region).ToLower() } else { 'euw' } }
    return "https://www.op.gg/summoners/$reg/$([uri]::EscapeDataString($Matches[1]))-$([uri]::EscapeDataString($Matches[2]))"
}

# ---------- Riot Client ----------

function Get-RiotClientPath {
    $json = 'C:\ProgramData\Riot Games\RiotClientInstalls.json'
    if (Test-Path $json) {
        $p = (Get-Content $json -Raw | ConvertFrom-Json).rc_default
        if ($p -and (Test-Path $p)) { return $p }
    }
    $fallback = 'C:\Riot Games\Riot Client\RiotClientServices.exe'
    if (Test-Path $fallback) { return $fallback }
    throw 'Riot Client introuvable.'
}

function Stop-Riot {
    if (Get-Process -Name $GameProcs -ErrorAction SilentlyContinue) {
        throw 'Une partie est en cours : ferme le jeu avant de changer de compte.'
    }
    Get-Process -Name $ClientProcs -ErrorAction SilentlyContinue | Stop-Process -Force
    Wait-Ui 2
}

# Lance directement League of Legends (pas l'accueil du Riot Client).
function Start-Riot {
    Start-Process (Get-RiotClientPath) '--launch-product=league_of_legends --launch-patchline=live'
}

function Clear-Session {
    if (Test-Path $DataDir) {
        if (Test-Path $Backup) { Remove-Item $Backup -Recurse -Force }
        Copy-Encrypted $DataDir $Backup
        Remove-Item "$DataDir\*" -Recurse -Force
    }
}

# ---------- API locale du client LoL ----------

function Get-LcuAuth {
    $proc = Get-Process -Name 'LeagueClientUx' -ErrorAction SilentlyContinue | Select-Object -First 1
    $dirs = @()
    if ($proc -and $proc.Path) { $dirs += Split-Path $proc.Path }
    $dirs += 'C:\Riot Games\League of Legends'
    foreach ($d in $dirs) {
        $lf = Join-Path $d 'lockfile'
        if (Test-Path $lf) {
            try {
                $parts = (Get-Content $lf -Raw -ErrorAction Stop).Split(':')
                $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("riot:$($parts[3])"))
                return @{ Base = "https://127.0.0.1:$($parts[2])"; Headers = @{ Authorization = "Basic $token" } }
            } catch { }
        }
    }
    return $null
}

function Invoke-Lcu($Auth, [string]$Path) {
    Invoke-RestMethod -Uri ($Auth.Base + $Path) -Headers $Auth.Headers -TimeoutSec 5
}

function Invoke-LcuRaw($Auth, [string]$Path, [string]$Method = 'Get', [string]$Body) {
    $p = @{ Uri = $Auth.Base + $Path; Headers = $Auth.Headers; Method = $Method; UseBasicParsing = $true; TimeoutSec = 10 }
    if ($Body) { $p.Body = [Text.Encoding]::UTF8.GetBytes($Body); $p.ContentType = 'application/json' }
    return (Invoke-WebRequest @p).Content
}

# Attend que LoL soit connecté et ait chargé le classement. Renvoie l'accès à l'API, ou $null.
function Wait-Lcu([int]$TimeoutSec) {
    $script:CancelWait = $false
    if ($script:CancelButton) { $script:CancelButton.Visible = $true }
    try {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline -and -not $script:CancelWait) {
            $auth = Get-LcuAuth
            if ($auth) {
                try {
                    $null = Invoke-Lcu $auth '/lol-summoner/v1/current-summoner'
                    if ((Invoke-Lcu $auth '/lol-ranked/v1/current-ranked-stats').queueMap) { return $auth }
                } catch { }
            }
            Wait-Ui 2
        }
        return $null
    } finally {
        if ($script:CancelButton) { $script:CancelButton.Visible = $false }
    }
}

function Get-QueueInfo($q) {
    if (-not $q -or -not $q.tier -or $q.tier -in 'NONE', 'UNRANKED') { return $null }
    return @{
        tier = $q.tier; lp = [int]$q.leaguePoints; wins = [int]$q.wins; losses = [int]$q.losses
        division = $(if ($q.division -and $q.division -ne 'NA') { $q.division } else { $null })
    }
}

# Perte de LP par inactivité (Diamant et plus) : date à laquelle elle commence, d'après le client.
function Get-DecayAt($q) {
    if ([array]::IndexOf($TierOrder, [string]$q.tier) -lt [array]::IndexOf($TierOrder, 'DIAMOND')) { return $null }
    $w = $q.warnings
    if (-not $w) { return $null }
    foreach ($p in 'daysUntilDecay', 'apexDaysUntilDecay') {
        if ($w.PSObject.Properties.Name -contains $p -and $null -ne $w.$p -and [int]$w.$p -ge 0) {
            return (Get-Date).Date.AddDays([int]$w.$p).ToString('o')
        }
    }
    return $null
}

# Les 3 champions les plus joués sur les 20 dernières parties.
function Get-TopChamps($Auth) {
    $games = (Invoke-Lcu $Auth '/lol-match-history/v1/products/lol/current-summoner/matches?begIndex=0&endIndex=20').games.games
    if (-not $games) { return $null }
    $names = @{}
    foreach ($c in (Invoke-Lcu $Auth '/lol-game-data/assets/v1/champion-summary.json')) { $names[[int]$c.id] = $c.name }
    $top = $games | ForEach-Object { $_.participants[0].championId } | Group-Object | Sort-Object Count -Descending | Select-Object -First 3
    return ($top | ForEach-Object { "$($names[[int]$_.Name]) ($($_.Count))" }) -join ', '
}

function Get-PositiveCount($o, [string[]]$Props) {
    if (-not $o) { return 0 }
    foreach ($p in $Props) {
        if ($o.PSObject.Properties.Name -contains $p -and [int]$o.$p -gt 0) { return [int]$o.$p }
    }
    return 0
}

# Sanctions visibles par le client : ranked bloquée, chat restreint. Renvoie '' si aucune.
function Get-Sanctions($Auth) {
    $out = @()
    try {
        $n = Get-PositiveCount (Invoke-Lcu $Auth '/lol-player-behavior/v1/ranked-restriction') 'punishedGamesRemaining', 'gamesRemaining'
        if ($n) { $out += "Ranked bloquée ($n parties)" }
    } catch { }
    try {
        $n = Get-PositiveCount (Invoke-Lcu $Auth '/lol-player-behavior/v1/chat-restriction') 'chatRestrictedGamesRemaining', 'restrictedChatGamesRemaining', 'punishedGamesRemaining', 'gamesRemaining'
        if ($n) { $out += "Chat restreint ($n parties)" }
    } catch { }
    return ($out -join ' · ')
}

function Update-RankFromLcu([string]$Name, $Auth) {
    $me = Invoke-Lcu $Auth '/lol-summoner/v1/current-summoner'
    $stats = Invoke-Lcu $Auth '/lol-ranked/v1/current-ranked-stats'
    $solo = Get-QueueInfo $stats.queueMap.RANKED_SOLO_5x5
    $flex = Get-QueueInfo $stats.queueMap.RANKED_FLEX_SR
    if ($solo) { $queue = 'Solo'; $r = $solo } elseif ($flex) { $queue = 'Flex'; $r = $flex } else { $queue = 'None'; $r = $null }

    $m = Get-Meta $Name
    # L'évolution compare au dernier rang connu, seulement si des parties ont été jouées entre-temps.
    $newGames = if ($r) { $r.wins + $r.losses } else { 0 }
    if ($m.queue -and $newGames -ne ([int]$m.wins + [int]$m.losses)) {
        $m.prev = [pscustomobject]@{ tier = $m.tier; division = $m.division; lp = $m.lp; wins = $m.wins; losses = $m.losses }
    }
    $m.riotId = "$($me.gameName)#$($me.tagLine)"
    try { $m.region = (Invoke-Lcu $Auth '/riotclient/region-locale').region } catch { }
    $m.decayAt = if ($solo) { Get-DecayAt $stats.queueMap.RANKED_SOLO_5x5 } else { $null }
    try { $champs = Get-TopChamps $Auth; if ($champs) { $m.topChamps = $champs } } catch { }
    try { $m.sanctions = Get-Sanctions $Auth } catch { }
    $m.queue = $queue
    $m.tier = $r.tier; $m.division = $r.division; $m.lp = $r.lp; $m.wins = $r.wins; $m.losses = $r.losses
    $m.banned = $false
    $m.updated = (Get-Date).ToString('o')

    # Historique pour le graphique et le résumé de la semaine.
    if ($r) {
        $v = Get-Ladder $m
        $last = if ($m.history.Count) { $m.history[-1] } else { $null }
        if (-not $last -or [int]$last.v -ne $v -or [int]$last.g -ne $newGames) {
            $m.history = @($m.history) + [pscustomobject]@{ t = $m.updated; v = $v; g = $newGames }
            if ($m.history.Count -gt $HistoryMax) { $m.history = $m.history[-$HistoryMax..-1] }
        }
    }
    Set-Meta $Name $m
    Say "$Name ($($m.riotId)) : $(Format-Rank $m)"
}

# ---------- Réglages communs à tous les comptes ----------

function Get-Config {
    $f = Join-Path $Root 'config.json'
    $c = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $defaults = @{ applyRef = $false; sortCol = 3; sortDesc = $true; autoAccept = $false; darkTheme = $false
                   lastVersion = $null; hideBanned = $false; trayHintShown = $false }
    foreach ($k in $defaults.Keys) {
        if ($c.PSObject.Properties.Name -notcontains $k) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
    }
    return $c
}

function Set-Config($c) { $c | ConvertTo-Json | Set-Content (Join-Path $Root 'config.json') -Encoding UTF8 }

function Set-ConfigValue([string]$Key, $Value) { $c = Get-Config; $c.$Key = $Value; Set-Config $c }

function Test-RefSettings {
    foreach ($k in $SettingsEndpoints.Keys) { if (-not (Test-Path (Join-Path $SettingsDir "$k.json"))) { return $false } }
    return $true
}

function Get-RefSettingsInfo {
    $f = Join-Path $SettingsDir 'source.txt'
    if ((Test-RefSettings) -and (Test-Path $f)) { return (Get-Content $f -Raw).Trim() }
    return $null
}

function Wait-SettingsReady($Auth) {
    for ($i = 0; $i -lt 20; $i++) {
        try { if (Invoke-Lcu $Auth '/lol-game-settings/v1/ready') { return $true } } catch { }
        Wait-Ui 1
    }
    return $false
}

function Save-RefSettings {
    $auth = Get-LcuAuth
    if (-not $auth) { throw 'Lance d''abord LoL sur le compte dont tu veux copier les réglages.' }
    if (-not (Wait-SettingsReady $auth)) { throw 'Les réglages de LoL ne sont pas encore chargés : réessaie dans quelques secondes.' }
    New-Item -ItemType Directory -Force $SettingsDir | Out-Null
    foreach ($k in $SettingsEndpoints.Keys) {
        [IO.File]::WriteAllText((Join-Path $SettingsDir "$k.json"), (Invoke-LcuRaw $auth $SettingsEndpoints[$k]))
    }
    $me = Invoke-Lcu $auth '/lol-summoner/v1/current-summoner'
    $info = "$($me.gameName)#$($me.tagLine), le $(Get-Date -Format 'dd/MM/yyyy à HH:mm')"
    Set-Content (Join-Path $SettingsDir 'source.txt') $info -Encoding UTF8
    Say "Réglages de référence copiés depuis $info."
}

function Apply-RefSettings($Auth) {
    if (-not (Test-RefSettings)) { return }
    Say 'Application de tes réglages...'
    try {
        if (-not (Wait-SettingsReady $Auth)) { Say 'Réglages non appliqués : LoL n''était pas prêt.'; return }
        foreach ($k in $SettingsEndpoints.Keys) {
            $raw = [IO.File]::ReadAllText((Join-Path $SettingsDir "$k.json"))
            $null = Invoke-LcuRaw $Auth $SettingsEndpoints[$k] 'Patch' $raw
        }
        $null = Invoke-LcuRaw $Auth '/lol-game-settings/v1/save' 'Post'
        Say 'Tes réglages ont été appliqués à ce compte.'
    } catch {
        Say "Réglages non appliqués : $($_.Exception.Message)"
    }
}

# ---------- Profils ----------

function Save-Profile([string]$Name) {
    Stop-Riot
    $dst = Join-Path $Store $Name
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    Copy-Encrypted $DataDir $dst
    $m = Get-Meta $Name
    $m.lastUsed = (Get-Date).ToString('o')
    Set-Meta $Name $m
    Say "Profil '$Name' enregistré (le client a été fermé pour sauvegarder la session)."
}

# -Batch : pas de question (utilisé par « Actualiser tous les comptes »).
function Use-Profile([string]$Name, [switch]$Batch) {
    $src = Join-Path $Store $Name
    if (-not (Test-Path $src)) { throw "Profil '$Name' introuvable." }
    $m = Get-Meta $Name
    if ($m.banned -and -not $Batch -and -not (Ask-YesNo "'$Name' est marqué BANNI. Lancer quand même ?")) { return $false }
    Stop-Riot
    Clear-Session
    Copy-Decrypted $src $DataDir
    Start-Riot
    Set-Content (Join-Path $Root 'current.txt') $Name -Encoding UTF8
    $m.lastUsed = (Get-Date).ToString('o')
    Set-Meta $Name $m

    Say "Lancement de '$Name'... en attente de LoL"
    $auth = Wait-Lcu $(if ($Batch) { 120 } else { $LcuTimeoutSec })
    if ($script:CancelWait) { Say 'Attente annulée (LoL continue de se lancer).'; return $false }
    if (-not $auth) {
        Say "LoL ne s'est pas connecté sur '$Name'."
        if ($Batch) { return $false }
        $msg = "LoL ne s'est pas connecté sur '$Name'.`n`n" +
               "- Si le Riot Client affiche un ban : réponds Oui pour marquer le compte BANNI.`n" +
               "- Si on te demande de te reconnecter, la session a expiré : réponds Non, connecte-toi, " +
               "puis utilise « Ré-enregistrer la session » (clic droit sur le compte).`n`nMarquer '$Name' comme BANNI ?"
        if (Ask-YesNo $msg) {
            $m = Get-Meta $Name; $m.banned = $true; $m.updated = (Get-Date).ToString('o'); Set-Meta $Name $m
        }
        return $false
    }
    Update-RankFromLcu $Name $auth
    if (-not $Batch -and (Get-Config).applyRef) { Apply-RefSettings $auth }
    return $true
}

function Update-AllAccounts {
    $targets = @(Get-ChildItem $Store -Directory | Where-Object { -not (Get-Meta $_.Name).banned })
    if (-not $targets.Count) { Show-Info 'Aucun compte à actualiser.'; return }
    $msg = "Le switcher va lancer les $($targets.Count) comptes un par un pour relire leurs infos " +
           "(environ 1 minute par compte).`n`nTu pourras arrêter avec « Annuler l'attente ». Continuer ?"
    if (-not (Ask-YesNo $msg)) { return }
    $ok = 0; $failed = @(); $i = 0
    foreach ($p in $targets) {
        if ($script:CancelAll) { break }
        $i++
        Say "Compte $i/$($targets.Count) : $($p.Name)..."
        try { if (Use-Profile $p.Name -Batch) { $ok++ } elseif (-not $script:CancelAll) { $failed += $p.Name } }
        catch { $failed += $p.Name }
    }
    $end = if ($script:CancelAll) { 'Actualisation arrêtée' } else { 'Actualisation terminée' }
    Say "$end : $ok/$($targets.Count) comptes à jour."
    if ($failed.Count) {
        Show-Info ("Ces comptes ne se sont pas connectés (session expirée ou ban ?) :`n`n- " + ($failed -join "`n- "))
    }
}

function Ask-ProfileName([string]$Default) {
    while ($true) {
        if ($script:Form) { $script:Form.Activate() }
        $name = [Microsoft.VisualBasic.Interaction]::InputBox('Nom du profil (ex : Main, Smurf ADC) :', 'Riot Switcher', $Default)
        if (-not $name) { return $null }
        $name = $name.Trim()
        if ($name -notmatch '^[\w\- ]{1,30}$') { Show-Info 'Utilise seulement des lettres, chiffres, espaces, - et _ (30 caractères max).'; continue }
        if ((Test-Path (Join-Path $Store $name)) -and -not (Ask-YesNo "Le profil '$name' existe déjà. Le remplacer ?")) { continue }
        return $name
    }
}

function New-Login {
    $msg = "Le Riot Client va s'ouvrir déconnecté.`n`n" +
           "1. Connecte-toi en cochant « Rester connecté ».`n" +
           "2. Lance League of Legends et attends l'accueil.`n`n" +
           "Le switcher détecte la connexion tout seul et te demandera un nom de profil."
    if ([Windows.Forms.MessageBox]::Show($msg, 'Riot Switcher', 'OKCancel', 'Information') -ne 'OK') { return }
    Stop-Riot
    Clear-Session
    Start-Riot
    Say 'En attente de ta connexion à LoL...'
    $auth = Wait-Lcu 600
    if ($script:CancelWait) { Say 'Ajout annulé.'; return }
    $default = ''
    if ($auth) { try { $default = (Invoke-Lcu $auth '/lol-summoner/v1/current-summoner').gameName -replace '[^\w\- ]', '' } catch { } }
    $name = Ask-ProfileName $default
    if (-not $name) { Say 'Ajout annulé.'; return }
    if ($auth) { Update-RankFromLcu $name $auth }
    Save-Profile $name
}

function Save-CurrentSessionAs([string]$Name) {
    $auth = Get-LcuAuth
    $id = $null
    if ($auth) { try { $me = Invoke-Lcu $auth '/lol-summoner/v1/current-summoner'; $id = "$($me.gameName)#$($me.tagLine)" } catch { } }
    $known = (Get-Meta $Name).riotId
    if ($id -and $known -and $id -ne $known) {
        if (-not (Ask-YesNo "Le compte connecté est $id, pas $known.`nL'enregistrer quand même sous '$Name' ?")) { return }
    } elseif (-not $id) {
        if (-not (Ask-YesNo "Enregistrer la session actuellement connectée dans le Riot Client sous '$Name' ?")) { return }
    }
    if ($auth -and $id) { try { Update-RankFromLcu $Name $auth } catch { } }
    Save-Profile $Name
}

# Lancement sans aucune fenêtre de terminal : sous Windows 11, "-WindowStyle Hidden" laisse
# une fenêtre Windows Terminal ouverte ; conhost --headless n'en ouvre aucune.
$ConhostExe = "$env:WINDIR\System32\conhost.exe"
function Get-LaunchArgs([string]$ExtraArgs) {
    return "--headless `"$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $ExtraArgs".Trim()
}

function Set-ShortcutTarget($s, [string]$ExtraArgs) {
    $s.TargetPath = $ConhostExe
    $s.Arguments = Get-LaunchArgs $ExtraArgs
    $s.WorkingDirectory = $Root
    try { $s.IconLocation = "$(Get-RiotClientPath),0" } catch { }
    $s.Save()
}

function New-Shortcut([string]$LinkName, [string]$ExtraArgs) {
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) "$LinkName.lnk"
    Set-ShortcutTarget ((New-Object -ComObject WScript.Shell).CreateShortcut($path)) $ExtraArgs
}

# Met au nouveau format les anciens raccourcis du bureau qui pointent vers ce script.
function Repair-Shortcuts {
    $shell = New-Object -ComObject WScript.Shell
    foreach ($f in Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -Filter '*.lnk' -ErrorAction SilentlyContinue) {
        try {
            $s = $shell.CreateShortcut($f.FullName)
            if ($s.TargetPath -like '*powershell.exe' -and $s.Arguments -like "*$ScriptPath*") {
                $extra = if ($s.Arguments -match '(-Account\s+".*")') { $Matches[1] } else { '' }
                Set-ShortcutTarget $s $extra
            }
        } catch { }
    }
}

function Remove-Profile([string]$Name) {
    Remove-Item (Join-Path $Store $Name) -Recurse -Force
    $f = Join-Path $MetaDir "$Name.json"
    if (Test-Path $f) { Remove-Item $f -Force }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "LoL - $Name.lnk"
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
    Say "Profil '$Name' supprimé."
}

# ---------- Sauvegarde / restauration (fichier protégé par mot de passe) ----------
# Format : "RSBK1" + HMAC-SHA256 (32) + sel (16) + IV (16) + données AES-256-CBC.
# Clés dérivées du mot de passe par PBKDF2-SHA256 (200 000 itérations).

$BackupMagic = [Text.Encoding]::ASCII.GetBytes('RSBK1')

function New-RandomBytes([int]$Count) {
    $b = New-Object byte[] $Count
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return ,$b
}

function Get-BackupKeys([string]$Password, [byte[]]$Salt) {
    $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $Salt, 200000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    $k = $kdf.GetBytes(64)
    return @{ Enc = [byte[]]$k[0..31]; Mac = [byte[]]$k[32..63] }
}

function Export-Backup {
    if (-not @(Get-ChildItem $Store -Directory).Count) { Show-Info 'Aucun compte à sauvegarder.'; return }
    $dlg = New-Object Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Sauvegarde Riot Switcher (*.rsbackup)|*.rsbackup'
    $dlg.FileName = "RiotSwitcher-sauvegarde-$(Get-Date -Format 'yyyy-MM-dd').rsbackup"
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $pw = Read-Password "Choisis un mot de passe pour protéger la sauvegarde (6 caractères minimum).`nSans lui, elle ne pourra pas être restaurée." -Confirm
    if (-not $pw) { return }

    Say 'Création de la sauvegarde...'
    $files = [ordered]@{}
    foreach ($dir in 'profiles', 'meta', 'settings') {
        $base = Join-Path $Root $dir
        if (-not (Test-Path $base)) { continue }
        foreach ($f in Get-ChildItem $base -Recurse -File) {
            $rel = "$dir\" + (Get-RelativePath $base $f.FullName)
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            if ($rel.EndsWith($EncExt)) { $rel = $rel.Substring(0, $rel.Length - $EncExt.Length); $bytes = Unprotect-Bytes $bytes }
            $files[$rel] = [Convert]::ToBase64String($bytes)
        }
    }
    $cfg = Join-Path $Root 'config.json'
    if (Test-Path $cfg) { $files['config.json'] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($cfg)) }

    $plain = [Text.Encoding]::UTF8.GetBytes(($files | ConvertTo-Json -Compress))
    $salt = New-RandomBytes 16
    $iv = New-RandomBytes 16
    $keys = Get-BackupKeys $pw $salt
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $keys.Enc; $aes.IV = $iv
    $cipher = $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    $body = [byte[]]($salt + $iv + $cipher)
    $mac = [Security.Cryptography.HMACSHA256]::new($keys.Mac).ComputeHash($body)
    [IO.File]::WriteAllBytes($dlg.FileName, [byte[]]($BackupMagic + $mac + $body))
    $n = @(Get-ChildItem $Store -Directory).Count
    Say "Sauvegarde créée : $n comptes dans $($dlg.FileName)"
    Show-Info "Sauvegarde créée ($n comptes).`n`nGarde bien le mot de passe : sans lui, impossible de la restaurer."
}

function Import-Backup {
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Sauvegarde Riot Switcher (*.rsbackup)|*.rsbackup'
    $dlg.InitialDirectory = [Environment]::GetFolderPath('MyDocuments')
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $all = [IO.File]::ReadAllBytes($dlg.FileName)
    if ($all.Length -lt 101 -or [Text.Encoding]::ASCII.GetString($all, 0, 5) -ne 'RSBK1') {
        throw 'Ce fichier n''est pas une sauvegarde Riot Switcher.'
    }
    $mac = [byte[]]$all[5..36]
    $body = [byte[]]$all[37..($all.Length - 1)]
    $pw = Read-Password 'Mot de passe de la sauvegarde :'
    if (-not $pw) { return }
    Say 'Vérification du mot de passe...'
    $keys = Get-BackupKeys $pw ([byte[]]$body[0..15])
    $check = [Security.Cryptography.HMACSHA256]::new($keys.Mac).ComputeHash($body)
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($check[$i] -bxor $mac[$i]) }
    if ($diff -ne 0) { throw 'Mot de passe incorrect (ou fichier abîmé).' }
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = $keys.Enc; $aes.IV = [byte[]]$body[16..31]
    $cipher = [byte[]]$body[32..($body.Length - 1)]
    $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
    $files = [Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json

    $names = @($files.PSObject.Properties.Name | Where-Object { $_ -like 'profiles\*' } |
        ForEach-Object { $_.Split('\')[1] } | Sort-Object -Unique)
    if (-not (Ask-YesNo "Restaurer $($names.Count) compte(s) : $($names -join ', ') ?`n`nLes comptes du même nom seront remplacés.")) { return }
    foreach ($n in $names) { $d = Join-Path $Store $n; if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
    foreach ($p in $files.PSObject.Properties) {
        $bytes = [Convert]::FromBase64String($p.Value)
        if ($p.Name -like 'profiles\*') { $dst = Join-Path $Root ($p.Name + $EncExt); $bytes = Protect-Bytes $bytes }
        else { $dst = Join-Path $Root $p.Name }
        New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
        [IO.File]::WriteAllBytes($dst, $bytes)
    }
    Say "Sauvegarde restaurée : $($names.Count) comptes."
}

# ---------- Mises à jour ----------

function Get-UpdateInfo {
    if (-not $UpdateBaseUrl) { return $null }
    try {
        $info = Invoke-RestMethod -Uri "$UpdateBaseUrl/version.json?t=$([DateTime]::UtcNow.Ticks)" -UseBasicParsing -TimeoutSec 5
        if ([version]$info.version -gt [version]$AppVersion) { return $info }
    } catch { }
    return $null
}

# Télécharge la nouvelle version, vérifie son empreinte SHA-256 et sa syntaxe, garde l'ancienne en secours.
function Install-Update($Info) {
    Say "Téléchargement de la version $($Info.version)..."
    $resp = Invoke-WebRequest -Uri "$UpdateBaseUrl/RiotSwitcher.ps1?t=$([DateTime]::UtcNow.Ticks)" -UseBasicParsing -TimeoutSec 30
    $bytes = $resp.RawContentStream.ToArray()
    $hash = -join ([Security.Cryptography.SHA256]::Create().ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    if ($hash -ne ([string]$Info.sha256).ToLower()) { throw 'Le fichier téléchargé ne correspond pas à l''empreinte annoncée : mise à jour annulée.' }
    $tmp = Join-Path $env:TEMP "RiotSwitcher-$($Info.version).ps1"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    $errs = $null
    [Management.Automation.Language.Parser]::ParseFile($tmp, [ref]$null, [ref]$errs) | Out-Null
    if ($errs.Count) { Remove-Item $tmp -Force; throw 'Le fichier téléchargé contient des erreurs : mise à jour annulée.' }
    Copy-Item $ScriptPath (Join-Path $Root 'RiotSwitcher.previous.ps1') -Force
    Copy-Item $tmp $ScriptPath -Force
    Remove-Item $tmp -Force
}

function Restart-App {
    Start-Process $ConhostExe (Get-LaunchArgs '')
}

# ---------- Démarrage ----------

# Les profils créés par une ancienne version sont chiffrés au premier lancement.
try { Protect-Folder $Store; Protect-Folder $Backup } catch { }

if ($CreateShortcut) {
    New-Shortcut 'Riot Switcher' ''
    Show-Info 'Raccourci « Riot Switcher » créé sur le bureau.'
    exit
}

if ($Account) {
    Use-Profile $Account | Out-Null
    exit
}

# Une seule fenêtre à la fois.
$createdNew = $false
$script:Mutex = [Threading.Mutex]::new($true, 'Local\RiotSwitcher-GUI', [ref]$createdNew)
if (-not $createdNew) {
    Show-Info 'Riot Switcher est déjà ouvert : regarde l''icône près de l''horloge.'
    exit
}

# ---------- Thèmes ----------

$Themes = @{
    Light = @{
        Dark = $false
        Back = [Drawing.SystemColors]::Window; Panel = [Drawing.SystemColors]::Control; Text = [Drawing.SystemColors]::ControlText
        Dim = [Drawing.Color]::DimGray; Button = [Drawing.SystemColors]::Control
        Header = [Drawing.Color]::FromArgb(240, 240, 240); Grid = [Drawing.Color]::FromArgb(210, 210, 210)
        Red = [Drawing.Color]::Firebrick; Green = [Drawing.Color]::ForestGreen; Orange = [Drawing.Color]::DarkOrange
        Accent = [Drawing.Color]::RoyalBlue
        Select = [Drawing.Color]::FromArgb(204, 228, 247); SelectText = [Drawing.Color]::Black
    }
    Dark = @{
        Dark = $true
        Back = [Drawing.Color]::FromArgb(32, 33, 36); Panel = [Drawing.Color]::FromArgb(24, 25, 28); Text = [Drawing.Color]::FromArgb(232, 232, 232)
        Dim = [Drawing.Color]::FromArgb(150, 152, 160); Button = [Drawing.Color]::FromArgb(48, 50, 56)
        Header = [Drawing.Color]::FromArgb(44, 46, 52); Grid = [Drawing.Color]::FromArgb(70, 72, 80)
        Red = [Drawing.Color]::FromArgb(255, 107, 107); Green = [Drawing.Color]::FromArgb(88, 214, 141); Orange = [Drawing.Color]::FromArgb(255, 183, 77)
        Accent = [Drawing.Color]::FromArgb(110, 168, 254)
        Select = [Drawing.Color]::FromArgb(52, 64, 92); SelectText = [Drawing.Color]::White
    }
}
$script:Theme = if ((Get-Config).darkTheme) { $Themes.Dark } else { $Themes.Light }

function Set-ControlTheme($c) {
    $t = $script:Theme
    switch ($c.GetType().Name) {
        'Button' {
            if ($t.Dark) { $c.FlatStyle = 'Flat'; $c.FlatAppearance.BorderColor = $t.Grid; $c.BackColor = $t.Button }
            else { $c.FlatStyle = 'Standard'; $c.BackColor = $t.Button; $c.UseVisualStyleBackColor = $true }
            $c.ForeColor = if ($c.Tag -eq 'accent') { $t.Accent } else { $t.Text }
        }
        'TextBox'  { $c.BackColor = $t.Back; $c.ForeColor = $t.Text }
        'ComboBox' { $c.BackColor = $t.Back; $c.ForeColor = $t.Text; $c.FlatStyle = $(if ($t.Dark) { 'Flat' } else { 'Standard' }) }
        'ListView' { $c.BackColor = $t.Back; $c.ForeColor = $t.Text }
        'CheckBox' { $c.ForeColor = $t.Text }
        'Label'    { $c.ForeColor = $(if ($c.Tag -eq 'dim') { $t.Dim } elseif ($c.Tag -eq 'accent') { $t.Accent } else { $t.Text }) }
        default    { $c.BackColor = $t.Panel; $c.ForeColor = $t.Text }
    }
    foreach ($child in $c.Controls) { Set-ControlTheme $child }
}

function Set-MenuTheme($menu) {
    $t = $script:Theme
    $menu.BackColor = $t.Panel; $menu.ForeColor = $t.Text
    foreach ($i in $menu.Items) { $i.BackColor = $t.Panel; $i.ForeColor = $t.Text }
}

function Set-AppTheme([bool]$Dark) {
    $script:Theme = if ($Dark) { $Themes.Dark } else { $Themes.Light }
    Set-ControlTheme $form
    $form.BackColor = $script:Theme.Panel
    try { $v = [int]$Dark; [void][RsDwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch { }
    $list.Invalidate()
    Update-List
}

# ---------- Fenêtre principale ----------

$form = New-Object Windows.Forms.Form
$form.Text = "Riot Switcher v$AppVersion"
$form.Size = New-Object Drawing.Size(1420, 620)
$form.MinimumSize = New-Object Drawing.Size(900, 420)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 9.5)
try { $form.Icon = [Drawing.Icon]::ExtractAssociatedIcon((Get-RiotClientPath)) } catch { }
$script:Form = $form

$list = New-Object Windows.Forms.ListView
$list.View = 'Details'
$list.FullRowSelect = $true
$list.MultiSelect = $false
$list.HideSelection = $false
$list.Dock = 'Fill'
$list.BorderStyle = 'None'
$ColumnNames = 'Compte', 'Riot ID', 'Serveur', 'Rang', 'Évolution', 'Winrate', 'Champions récents', 'Sanctions', 'Dernier lancement'
$ColumnWidths = 120, 140, 65, 265, 180, 125, 185, 150, 150
for ($i = 0; $i -lt $ColumnNames.Count; $i++) { [void]$list.Columns.Add($ColumnNames[$i], $ColumnWidths[$i]) }

# En-têtes dessinés à la main pour suivre le thème ; les lignes gardent le rendu standard.
$list.OwnerDraw = $true
$list.Add_DrawColumnHeader({
    param($s, $e)
    $t = $script:Theme
    $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $t.Header), $e.Bounds)
    $r = New-Object Drawing.Rectangle(($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 8), $e.Bounds.Height)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, $r, $t.Text,
        [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis')
    $e.Graphics.DrawLine((New-Object Drawing.Pen $t.Grid), ($e.Bounds.Right - 1), ($e.Bounds.Top + 4), ($e.Bounds.Right - 1), ($e.Bounds.Bottom - 4))
})
$list.Add_DrawItem({ param($s, $e) $e.DrawDefault = $false })
$list.Add_DrawSubItem({
    param($s, $e)
    $t = $script:Theme
    $selected = $e.Item.Selected
    $back = if ($selected) { $t.Select } else { $e.SubItem.BackColor }
    $fore = $e.SubItem.ForeColor
    if ($selected -and $fore -eq $t.Text) { $fore = $t.SelectText }
    $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $back), $e.Bounds)
    $r = New-Object Drawing.Rectangle(($e.Bounds.X + 4), $e.Bounds.Y, ($e.Bounds.Width - 6), $e.Bounds.Height)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $s.Font, $r, $fore,
        [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis, NoPrefix')
})
# La dernière colonne remplit la largeur restante (pas de zone d'en-tête vide à droite).
$list.Add_Resize({ if ($list.Columns.Count) { $list.Columns[$list.Columns.Count - 1].Width = -2 } })
# Évite le scintillement du dessin personnalisé.
$list.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic, Instance').SetValue($list, $true, $null)

# Barre du haut : recherche, filtres, résumé de la semaine.
$top = New-Object Windows.Forms.FlowLayoutPanel
$top.Dock = 'Top'; $top.AutoSize = $true; $top.AutoSizeMode = 'GrowAndShrink'
$top.Padding = New-Object Windows.Forms.Padding(6, 6, 6, 4)

$lblSearch = New-Object Windows.Forms.Label
$lblSearch.Text = 'Rechercher :'; $lblSearch.AutoSize = $true; $lblSearch.Margin = New-Object Windows.Forms.Padding(4, 7, 2, 0)
$txtSearch = New-Object Windows.Forms.TextBox
$txtSearch.Width = 200; $txtSearch.Margin = New-Object Windows.Forms.Padding(2, 4, 10, 0)
$cmbRegion = New-Object Windows.Forms.ComboBox
$cmbRegion.DropDownStyle = 'DropDownList'; $cmbRegion.Width = 140; $cmbRegion.Margin = New-Object Windows.Forms.Padding(2, 4, 10, 0)
[void]$cmbRegion.Items.Add('Tous les serveurs'); $cmbRegion.SelectedIndex = 0
$cmbRegion.DrawMode = 'OwnerDrawFixed'
$cmbRegion.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $t = $script:Theme
    $selected = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $e.Graphics.FillRectangle((New-Object Drawing.SolidBrush $(if ($selected) { $t.Select } else { $t.Back })), $e.Bounds)
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $e.Font, $e.Bounds,
        $(if ($selected) { $t.SelectText } else { $t.Text }), [Windows.Forms.TextFormatFlags]'VerticalCenter, Left')
})
$chkHideBanned = New-Object Windows.Forms.CheckBox
$chkHideBanned.Text = 'Masquer les bannis'; $chkHideBanned.AutoSize = $true; $chkHideBanned.Margin = New-Object Windows.Forms.Padding(2, 6, 16, 0)
$chkHideBanned.Checked = [bool](Get-Config).hideBanned
$summaryLabel = New-Object Windows.Forms.Label
$summaryLabel.AutoSize = $true; $summaryLabel.Tag = 'accent'; $summaryLabel.Margin = New-Object Windows.Forms.Padding(10, 7, 6, 0)
$top.Controls.AddRange(@($lblSearch, $txtSearch, $cmbRegion, $chkHideBanned, $summaryLabel))

$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Bottom'; $buttons.AutoSize = $true; $buttons.AutoSizeMode = 'GrowAndShrink'
$buttons.Padding = New-Object Windows.Forms.Padding(6, 6, 6, 0)

$opts = New-Object Windows.Forms.FlowLayoutPanel
$opts.Dock = 'Bottom'; $opts.AutoSize = $true; $opts.AutoSizeMode = 'GrowAndShrink'
$opts.Padding = New-Object Windows.Forms.Padding(6, 4, 6, 0)

$status = New-Object Windows.Forms.Label
$status.Dock = 'Bottom'; $status.Height = 28; $status.Tag = 'dim'
$status.Padding = New-Object Windows.Forms.Padding(10, 6, 10, 0)
$script:StatusLabel = $status

$script:ActionControls = @()

function Get-SelectedName([switch]$Quiet) {
    if ($list.SelectedItems.Count) { return [string]$list.SelectedItems[0].Tag }
    if (-not $Quiet) { Show-Info 'Sélectionne d''abord un compte dans la liste.' }
    return $null
}

# Tri par colonne (clic sur l'en-tête). Le choix est mémorisé.
$cfg = Get-Config
$script:SortCol = [int]$cfg.sortCol
$script:SortDesc = [bool]$cfg.sortDesc
$script:Updating = $false

function Get-SortKey([string]$Name, $m, [int]$Col) {
    switch ($Col) {
        0 { return $Name.ToLower() }
        1 { return ([string]$m.riotId).ToLower() }
        2 { return [string]$m.region }
        3 { return Get-SortScore $m }
        4 { if ($m.prev -and $m.tier -and $m.prev.tier) { return (Get-Score $m) - (Get-Score $m.prev) } else { return -999999 } }
        5 { $n = [int]$m.wins + [int]$m.losses; if ($n) { return [int]$m.wins / $n } else { return -1 } }
        6 { return ([string]$m.topChamps).ToLower() }
        7 { return [string]$m.sanctions }
        8 { if ($m.lastUsed) { return ([datetime]$m.lastUsed).Ticks } else { return 0 } }
    }
}

function Test-Filter([string]$Name, $m) {
    if ($chkHideBanned.Checked -and $m.banned) { return $false }
    if ($cmbRegion.SelectedIndex -gt 0 -and [string]$m.region -ne [string]$cmbRegion.SelectedItem) { return $false }
    $q = $txtSearch.Text.Trim()
    if (-not $q) { return $true }
    foreach ($v in @($Name, $m.riotId, $m.region, $m.topChamps, (Format-Rank $m))) {
        if ($v -and ([string]$v).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

# Résumé des 7 derniers jours, d'après l'historique de chaque compte.
function Get-WeekSummary($Rows) {
    $since = (Get-Date).AddDays(-7)
    $lp = 0; $games = 0; $any = $false; $decaying = 0
    foreach ($r in $Rows) {
        $m = $r.Meta
        if ($m.banned) { continue }
        $d = Get-DecayDays $m
        if ($null -ne $d -and $d -le 7) { $decaying++ }
        $h = @($m.history)
        if ($h.Count -lt 2) { continue }
        $base = $h | Where-Object { [datetime]$_.t -le $since } | Select-Object -Last 1
        if (-not $base) { $base = $h[0] }
        $lp += [int]$h[-1].v - [int]$base.v
        $games += [int]$h[-1].g - [int]$base.g
        $any = $true
    }
    $parts = @()
    if ($any) { $parts += "7 derniers jours : $(if ($lp -ge 0) { '+' })$lp LP · $games partie$(if ($games -gt 1) { 's' })" }
    if ($decaying) { $parts += "⚠ $decaying compte$(if ($decaying -gt 1) { 's' }) bientôt en perte de LP" }
    return ($parts -join '     ')
}

function Update-List {
    if ($script:Updating) { return }
    $script:Updating = $true
    try {
        $t = $script:Theme
        $sel = Get-SelectedName -Quiet
        $all = foreach ($p in Get-ChildItem $Store -Directory) {
            $m = Get-Meta $p.Name
            [pscustomobject]@{ Name = $p.Name; Meta = $m; Key = Get-SortKey $p.Name $m $script:SortCol }
        }
        $all = @($all | Sort-Object @{ Expression = 'Key'; Descending = $script:SortDesc }, Name)

        # Liste des serveurs pour le filtre (on garde la sélection).
        $regions = @($all | ForEach-Object { $_.Meta.region } | Where-Object { $_ } | Sort-Object -Unique)
        $curRegion = [string]$cmbRegion.SelectedItem
        $cmbRegion.Items.Clear(); [void]$cmbRegion.Items.Add('Tous les serveurs')
        foreach ($r in $regions) { [void]$cmbRegion.Items.Add($r) }
        $cmbRegion.SelectedIndex = [math]::Max(0, $cmbRegion.Items.IndexOf($curRegion))

        $list.BeginUpdate()
        $list.Items.Clear()
        $font = $list.Font
        foreach ($r in $all) {
            $m = $r.Meta
            if (-not (Test-Filter $r.Name $m)) { continue }
            $it = New-Object Windows.Forms.ListViewItem($r.Name)
            $it.Tag = $r.Name
            $it.UseItemStyleForSubItems = $false
            $it.ForeColor = $t.Text; $it.BackColor = $t.Back
            $decay = Format-Decay $m
            $rankText = (Format-Rank $m) + $(if ($decay) { "   $decay" } else { '' })
            foreach ($v in @($m.riotId, $m.region, $rankText, (Format-Delta $m), (Format-Winrate $m), $m.topChamps, (Format-Sanctions $m), (Format-Age $m.lastUsed))) {
                [void]$it.SubItems.Add([string]$v, $t.Text, $t.Back, $font)
            }
            if ($m.banned) {
                foreach ($s in $it.SubItems) { $s.ForeColor = $t.Red }
            } else {
                $delta = $it.SubItems[4]
                if ($delta.Text -match '^[+▲]') { $delta.ForeColor = $t.Green }
                elseif ($delta.Text -match '^[-▼]') { $delta.ForeColor = $t.Red }
                $dd = Get-DecayDays $m
                if ($null -ne $dd) { $it.SubItems[3].ForeColor = $(if ($dd -le 3) { $t.Red } else { $t.Orange }) }
                if ($m.sanctions) { $it.SubItems[7].ForeColor = $t.Red }
                if (Test-Stale $m) {
                    $it.SubItems[8].Text += '  ⚠ session à vérifier'
                    $it.SubItems[8].ForeColor = $t.Orange
                }
            }
            [void]$list.Items.Add($it)
            if ($r.Name -eq $sel) { $it.Selected = $true }
        }
        for ($i = 0; $i -lt $ColumnNames.Count; $i++) {
            $arrow = if ($i -eq $script:SortCol) { if ($script:SortDesc) { ' ▼' } else { ' ▲' } } else { '' }
            $list.Columns[$i].Text = $ColumnNames[$i] + $arrow
        }
        $list.EndUpdate()
        $summaryLabel.Text = Get-WeekSummary $all
        $info = Get-RefSettingsInfo
        $refLabel.Text = if ($info) { "Réglages de référence : $info" } else { 'Aucun réglage de référence enregistré.' }
    } finally {
        $script:Updating = $false
    }
}

function Invoke-Action([scriptblock]$Action) {
    if ($script:Busy) { Say 'Une action est déjà en cours.'; return }
    $script:Busy = $true
    $script:CancelWait = $false
    $script:CancelAll = $false
    foreach ($c in $script:ActionControls) { $c.Enabled = $false }
    $list.Enabled = $false
    try { & $Action }
    catch {
        Say "Erreur : $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Riot Switcher', 'OK', 'Warning') | Out-Null
    }
    finally {
        foreach ($c in $script:ActionControls) { $c.Enabled = $true }
        $list.Enabled = $true
        $script:Busy = $false
        Update-List
    }
}

function Add-Button($Panel, [string]$Text, [scriptblock]$OnClick) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $Text; $b.AutoSize = $true
    $b.Padding = New-Object Windows.Forms.Padding(6, 2, 6, 2)
    $b.Add_Click($OnClick)
    [void]$Panel.Controls.Add($b)
    $script:ActionControls += $b
    return $b
}

function Add-MenuItem($Menu, [string]$Text, [scriptblock]$OnClick) {
    $i = New-Object Windows.Forms.ToolStripMenuItem($Text)
    $i.Add_Click($OnClick)
    [void]$Menu.Items.Add($i)
    return $i
}

# ---------- Actions ----------

function Do-Launch      { $n = Get-SelectedName; if ($n) { Use-Profile $n | Out-Null } }
function Do-Resave      { $n = Get-SelectedName; if ($n) { Save-CurrentSessionAs $n } }
function Do-ToggleBan   { $n = Get-SelectedName; if ($n) { $m = Get-Meta $n; $m.banned = -not $m.banned; $m.updated = (Get-Date).ToString('o'); Set-Meta $n $m } }
function Do-Shortcut    { $n = Get-SelectedName; if ($n) { New-Shortcut "LoL - $n" "-Account `"$n`""; Say "Raccourci « LoL - $n » créé sur le bureau." } }
function Do-Delete      { $n = Get-SelectedName; if ($n -and (Ask-YesNo "Supprimer le profil '$n' ?")) { Remove-Profile $n } }
function Do-Opgg {
    $n = Get-SelectedName
    if (-not $n) { return }
    $url = Get-OpggUrl (Get-Meta $n)
    if ($url) { Start-Process $url } else { Show-Info "Riot ID inconnu pour '$n' : lance le compte une fois depuis le switcher." }
}
function Do-RefreshRank {
    $cur = Join-Path $Root 'current.txt'
    if (-not (Test-Path $cur)) { Show-Info 'Aucun compte lancé via le switcher.'; return }
    $n = (Get-Content $cur -Raw).Trim()
    $auth = Wait-Lcu 15
    if ($auth) { Update-RankFromLcu $n $auth } else { Say 'LoL n''est pas lancé.' }
}

function Show-LpGraph {
    $n = Get-SelectedName
    if (-not $n) { return }
    $h = @((Get-Meta $n).history)
    if ($h.Count -lt 2) {
        Show-Info "Pas encore assez de données pour '$n'.`n`nLe graphique se remplit à chaque lancement du compte (après des parties classées)."
        return
    }
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $t = $script:Theme
    $g = New-Object Windows.Forms.Form
    $g.Text = "Évolution des LP - $n"; $g.Size = New-Object Drawing.Size(900, 500); $g.StartPosition = 'CenterParent'
    $g.Icon = $form.Icon; $g.BackColor = $t.Panel
    $chart = New-Object Windows.Forms.DataVisualization.Charting.Chart
    $chart.Dock = 'Fill'; $chart.BackColor = $t.Panel
    $area = New-Object Windows.Forms.DataVisualization.Charting.ChartArea
    $area.BackColor = $t.Back
    foreach ($ax in $area.AxisX, $area.AxisY) {
        $ax.LineColor = $t.Grid; $ax.MajorGrid.LineColor = $t.Grid; $ax.LabelStyle.ForeColor = $t.Text
        $ax.MajorTickMark.LineColor = $t.Grid
    }
    $area.AxisX.LabelStyle.Format = 'dd/MM'
    $area.AxisX.IntervalAutoMode = 'VariableCount'
    [void]$chart.ChartAreas.Add($area)
    $series = New-Object Windows.Forms.DataVisualization.Charting.Series
    $series.ChartType = 'Line'; $series.XValueType = 'DateTime'; $series.BorderWidth = 3
    $series.Color = $t.Accent; $series.MarkerStyle = 'Circle'; $series.MarkerSize = 6
    foreach ($e in $h) {
        $idx = $series.Points.AddXY([datetime]$e.t, [double]$e.v)
        $series.Points[$idx].ToolTip = "$(([datetime]$e.t).ToString('dd/MM HH:mm')) : $(Format-Ladder ([double]$e.v))$(if ([double]$e.v -lt 2800) { " $([int]$e.v % 100) LP" })"
    }
    [void]$chart.Series.Add($series)
    # Axe vertical gradué en divisions (Or IV, Or III...).
    $vals = $h | ForEach-Object { [double]$_.v }
    $min = [math]::Floor((($vals | Measure-Object -Minimum).Minimum - 30) / 100) * 100
    $max = [math]::Ceiling((($vals | Measure-Object -Maximum).Maximum + 30) / 100) * 100
    $area.AxisY.Minimum = [math]::Max(0, $min); $area.AxisY.Maximum = $max; $area.AxisY.Interval = 100
    for ($b = $area.AxisY.Minimum; $b -lt $max; $b += 100) {
        [void]$area.AxisY.CustomLabels.Add($b - 50, $b + 50, (Format-Ladder $b))
    }
    $g.Controls.Add($chart)
    [void]$g.ShowDialog($form)
}

# Texte prêt à coller sur Discord (bloc de code aligné). Sans les Riot ID.
function Copy-ListText {
    $rows = @(, @('Compte', 'Serveur', 'Rang', 'Évolution', 'Winrate'))
    foreach ($it in $list.Items) {
        $m = Get-Meta ([string]$it.Tag)
        $rows += ,@([string]$it.Tag, [string]$m.region, (Format-Rank $m), (Format-Delta $m), (Format-Winrate $m))
    }
    $w = 0..4 | ForEach-Object { $c = $_; ($rows | ForEach-Object { ([string]$_[$c]).Length } | Measure-Object -Maximum).Maximum }
    $lines = foreach ($r in $rows) { ((0..4 | ForEach-Object { ([string]$r[$_]).PadRight($w[$_]) }) -join '  ').TrimEnd() }
    $fence = '```'
    $text = $fence + "`n" + ($lines -join "`n") + "`n" + $fence
    [Windows.Forms.Clipboard]::SetText($text)
    Say 'Liste copiée : colle-la sur Discord avec Ctrl+V.'
}

function Save-ListImage {
    $bmp = New-Object Drawing.Bitmap($list.Width, $list.Height)
    $list.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $list.Width, $list.Height)))
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Riot Switcher - comptes.png'
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    [Windows.Forms.Clipboard]::SetImage($bmp)
    Say "Image enregistrée sur le bureau et copiée (Ctrl+V sur Discord)."
}

# ---------- Boutons ----------

$btnLaunch = Add-Button $buttons '▶ Lancer' { Invoke-Action { Do-Launch } }
$btnLaunch.Font = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
Add-Button $buttons 'Ajouter un compte' { Invoke-Action { New-Login } } | Out-Null
Add-Button $buttons 'Actualiser le rang' { Invoke-Action { Do-RefreshRank } } | Out-Null
Add-Button $buttons 'Actualiser tous les comptes' { Invoke-Action { Update-AllAccounts } } | Out-Null
Add-Button $buttons 'Graphique des LP' { Invoke-Action { Show-LpGraph } } | Out-Null
Add-Button $buttons 'op.gg' { Invoke-Action { Do-Opgg } } | Out-Null

$moreMenu = New-Object Windows.Forms.ContextMenuStrip
Add-MenuItem $moreMenu 'Ré-enregistrer la session du compte' { Invoke-Action { Do-Resave } } | Out-Null
Add-MenuItem $moreMenu 'Créer un raccourci bureau pour ce compte' { Invoke-Action { Do-Shortcut } } | Out-Null
Add-MenuItem $moreMenu 'BAN / dé-BAN' { Invoke-Action { Do-ToggleBan } } | Out-Null
Add-MenuItem $moreMenu 'Supprimer le compte' { Invoke-Action { Do-Delete } } | Out-Null
[void]$moreMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
Add-MenuItem $moreMenu 'Copier la liste pour Discord (texte)' { Invoke-Action { Copy-ListText } } | Out-Null
Add-MenuItem $moreMenu 'Enregistrer une image de la liste' { Invoke-Action { Save-ListImage } } | Out-Null
[void]$moreMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
Add-MenuItem $moreMenu 'Sauvegarder mes comptes...' { Invoke-Action { Export-Backup } } | Out-Null
Add-MenuItem $moreMenu 'Restaurer une sauvegarde...' { Invoke-Action { Import-Backup } } | Out-Null
[void]$moreMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miDark = Add-MenuItem $moreMenu 'Thème sombre' {
    $miDark.Checked = -not $miDark.Checked
    Set-ConfigValue 'darkTheme' $miDark.Checked
    Set-AppTheme $miDark.Checked
}
$miDark.Checked = [bool](Get-Config).darkTheme
$moreMenu.Add_Opening({ Set-MenuTheme $moreMenu })

$btnMore = Add-Button $buttons 'Plus ▾' { $moreMenu.Show($btnMore, (New-Object Drawing.Point(0, $btnMore.Height))) }

$script:CancelButton = New-Object Windows.Forms.Button
$script:CancelButton.Text = 'Annuler l''attente'; $script:CancelButton.AutoSize = $true; $script:CancelButton.Visible = $false
$script:CancelButton.Add_Click({ $script:CancelWait = $true; $script:CancelAll = $true })
[void]$buttons.Controls.Add($script:CancelButton)

Add-Button $opts 'Copier mes réglages depuis le compte lancé' { Invoke-Action { Save-RefSettings } } | Out-Null

$chkApply = New-Object Windows.Forms.CheckBox
$chkApply.Text = 'Appliquer ces réglages à chaque lancement'
$chkApply.AutoSize = $true
$chkApply.Margin = New-Object Windows.Forms.Padding(12, 7, 6, 0)
$chkApply.Checked = [bool](Get-Config).applyRef
$chkApply.Add_CheckedChanged({
    if ($chkApply.Checked -and -not (Test-RefSettings)) {
        Show-Info 'Copie d''abord tes réglages : lance ton compte principal puis clique sur « Copier mes réglages depuis le compte lancé ».'
        $chkApply.Checked = $false
        return
    }
    Set-ConfigValue 'applyRef' $chkApply.Checked
})
[void]$opts.Controls.Add($chkApply)

$chkAccept = New-Object Windows.Forms.CheckBox
$chkAccept.Text = 'Accepter les parties automatiquement'
$chkAccept.AutoSize = $true
$chkAccept.Margin = New-Object Windows.Forms.Padding(16, 7, 6, 0)
$chkAccept.Checked = [bool](Get-Config).autoAccept
[void]$opts.Controls.Add($chkAccept)

$refLabel = New-Object Windows.Forms.Label
$refLabel.AutoSize = $true; $refLabel.Tag = 'dim'
$refLabel.Margin = New-Object Windows.Forms.Padding(16, 8, 6, 0)
[void]$opts.Controls.Add($refLabel)

$script:PendingUpdate = $null
$btnUpdate = Add-Button $opts 'Mettre à jour' {
    Invoke-Action {
        $u = $script:PendingUpdate
        if (-not $u) { return }
        $notes = if ($u.notes) { "`n`nNouveautés : $($u.notes)" } else { '' }
        if (-not (Ask-YesNo "Installer la version $($u.version) (actuelle : $AppVersion) ?$notes")) { return }
        Install-Update $u
        Show-Info "Version $($u.version) installée. Le switcher va redémarrer."
        $script:Mutex.ReleaseMutex()
        Restart-App
        $form.Close()
    }
}
$btnUpdate.Visible = $false
$btnUpdate.Tag = 'accent'

# ---------- Acceptation automatique des parties ----------

$acceptTimer = New-Object Windows.Forms.Timer
$acceptTimer.Interval = 1500
$script:InTick = $false
$acceptTimer.Add_Tick({
    if ($script:InTick) { return }
    $script:InTick = $true
    try {
        $auth = Get-LcuAuth
        if ($auth -and (Invoke-Lcu $auth '/lol-gameflow/v1/gameflow-phase') -eq 'ReadyCheck') {
            if ((Invoke-Lcu $auth '/lol-matchmaking/v1/ready-check').playerResponse -eq 'None') {
                $null = Invoke-LcuRaw $auth '/lol-matchmaking/v1/ready-check/accept' 'Post'
                Say "Partie acceptée automatiquement à $(Get-Date -Format 'HH:mm:ss')."
            }
        }
    } catch { } finally { $script:InTick = $false }
})
$acceptTimer.Enabled = $chkAccept.Checked
$chkAccept.Add_CheckedChanged({
    $acceptTimer.Enabled = $chkAccept.Checked
    Set-ConfigValue 'autoAccept' $chkAccept.Checked
    Say $(if ($chkAccept.Checked) { 'Acceptation automatique activée (tant que le switcher est ouvert).' } else { 'Acceptation automatique désactivée.' })
})

# ---------- Icône près de l'horloge ----------

$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = if ($form.Icon) { $form.Icon } else { [Drawing.SystemIcons]::Application }
$tray.Text = 'Riot Switcher'
$tray.Visible = $true
$trayMenu = New-Object Windows.Forms.ContextMenuStrip

function Show-Main {
    $form.Show()
    $form.WindowState = 'Normal'
    $form.Activate()
}

$trayMenu.Add_Opening({
    $trayMenu.Items.Clear()
    $rows = @(Get-ChildItem $Store -Directory | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Meta = (Get-Meta $_.Name) } } |
        Where-Object { -not $_.Meta.banned } | Sort-Object @{ Expression = { Get-SortScore $_.Meta }; Descending = $true })
    foreach ($r in $rows) {
        $i = New-Object Windows.Forms.ToolStripMenuItem("$($r.Name)   —   $(Format-Rank $r.Meta)")
        $i.Tag = $r.Name
        $i.Add_Click({ param($s, $e) $n = [string]$s.Tag; Invoke-Action { Use-Profile $n | Out-Null } })
        [void]$trayMenu.Items.Add($i)
    }
    if ($rows.Count) { [void]$trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) }
    $acc = New-Object Windows.Forms.ToolStripMenuItem('Accepter les parties automatiquement')
    $acc.Checked = $chkAccept.Checked
    $acc.Add_Click({ $chkAccept.Checked = -not $chkAccept.Checked })
    [void]$trayMenu.Items.Add($acc)
    $open = New-Object Windows.Forms.ToolStripMenuItem('Ouvrir Riot Switcher')
    $open.Add_Click({ Show-Main })
    [void]$trayMenu.Items.Add($open)
    $quit = New-Object Windows.Forms.ToolStripMenuItem('Quitter')
    $quit.Add_Click({ $form.Close() })
    [void]$trayMenu.Items.Add($quit)
    Set-MenuTheme $trayMenu
})
$tray.ContextMenuStrip = $trayMenu
$tray.Add_DoubleClick({ Show-Main })

# Réduire = aller près de l'horloge.
$form.Add_Resize({
    if ($form.WindowState -eq 'Minimized') {
        $form.Hide()
        if (-not (Get-Config).trayHintShown) {
            $tray.ShowBalloonTip(4000, 'Riot Switcher', 'Toujours là : clic droit sur cette icône pour lancer un compte.', 'Info')
            Set-ConfigValue 'trayHintShown' $true
        }
    }
})
$form.Add_FormClosed({
    $acceptTimer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
})

# ---------- Liste : clic droit, double-clic, tri, filtres ----------

$rowMenu = New-Object Windows.Forms.ContextMenuStrip
Add-MenuItem $rowMenu '▶ Lancer' { Invoke-Action { Do-Launch } } | Out-Null
Add-MenuItem $rowMenu 'Voir sur op.gg' { Invoke-Action { Do-Opgg } } | Out-Null
Add-MenuItem $rowMenu 'Graphique des LP' { Invoke-Action { Show-LpGraph } } | Out-Null
[void]$rowMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
Add-MenuItem $rowMenu 'Ré-enregistrer la session' { Invoke-Action { Do-Resave } } | Out-Null
Add-MenuItem $rowMenu 'Créer un raccourci bureau' { Invoke-Action { Do-Shortcut } } | Out-Null
Add-MenuItem $rowMenu 'BAN / dé-BAN' { Invoke-Action { Do-ToggleBan } } | Out-Null
Add-MenuItem $rowMenu 'Supprimer' { Invoke-Action { Do-Delete } } | Out-Null
$rowMenu.Add_Opening({ param($s, $e) if (-not $list.SelectedItems.Count) { $e.Cancel = $true } else { Set-MenuTheme $rowMenu } })
$list.ContextMenuStrip = $rowMenu
$list.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq 'Right') { $hit = $list.GetItemAt($e.X, $e.Y); if ($hit) { $hit.Selected = $true } }
})

$list.Add_ColumnClick({
    param($s, $e)
    if ($e.Column -eq $script:SortCol) { $script:SortDesc = -not $script:SortDesc }
    else { $script:SortCol = $e.Column; $script:SortDesc = $e.Column -in 3, 4, 5, 8 }   # texte A->Z, chiffres du plus grand au plus petit
    $c = Get-Config; $c.sortCol = $script:SortCol; $c.sortDesc = $script:SortDesc; Set-Config $c
    Update-List
})

$list.Add_DoubleClick({ Invoke-Action { $n = Get-SelectedName -Quiet; if ($n) { Use-Profile $n | Out-Null } } })
$txtSearch.Add_TextChanged({ Update-List })
$cmbRegion.Add_SelectedIndexChanged({ Update-List })
$chkHideBanned.Add_CheckedChanged({ Set-ConfigValue 'hideBanned' $chkHideBanned.Checked; Update-List })

# Ordre d'ajout : la liste occupe le centre, la recherche en haut, boutons, options et barre d'état en bas.
$form.Controls.AddRange(@($list, $top, $buttons, $opts, $status))
$list.BringToFront()

$form.Add_Shown({
    Set-AppTheme ([bool](Get-Config).darkTheme)
    try { Repair-Shortcuts } catch { }
    Update-List
    if ($list.Items.Count) { Say 'Double-clic sur un compte pour le lancer · clic droit pour plus d''options.' }
    else { Say 'Aucun compte : clique sur « Ajouter un compte ».' }

    # Nouveautés après une mise à jour.
    $c = Get-Config
    $upgraded = if ($c.lastVersion) { $c.lastVersion -ne $AppVersion } else { [bool]@(Get-ChildItem $Store -Directory).Count }
    if ($upgraded) { Show-Info "Nouveautés de la version $AppVersion :`n`n$ReleaseNotes" }
    if ($c.lastVersion -ne $AppVersion) { Set-ConfigValue 'lastVersion' $AppVersion }

    $script:PendingUpdate = Get-UpdateInfo
    if ($script:PendingUpdate) {
        $btnUpdate.Text = "⬆ Mettre à jour (v$($script:PendingUpdate.version))"
        $btnUpdate.Visible = $true
        Say "Nouvelle version $($script:PendingUpdate.version) disponible : clique sur « Mettre à jour »."
    }
})
[Windows.Forms.Application]::Run($form)

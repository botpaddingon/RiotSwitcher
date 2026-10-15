# RiotSwitcher - change de compte League of Legends en échangeant les fichiers de session.
# Ne stocke AUCUN mot de passe : uniquement les sessions "Rester connecté" créées par Riot.
# Ne modifie pas le Riot Client et ne touche pas à Vanguard.
# Rang, winrate et réglages passent par l'API locale du client LoL (127.0.0.1, sans clé).
#
# Utilisation :
#   RiotSwitcher.ps1                    -> fenêtre principale
#   RiotSwitcher.ps1 -Account "Main"    -> lance directement ce compte (raccourcis par compte)
#   RiotSwitcher.ps1 -CreateShortcut    -> crée le raccourci "Riot Switcher" sur le bureau

param([string]$Account, [switch]$CreateShortcut)

$AppVersion  = '2.2.0'
# Adresse des mises à jour : dossier contenant version.json et RiotSwitcher.ps1 (vide = désactivé).
# Ex : https://raw.githubusercontent.com/<pseudo>/RiotSwitcher/main
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
$TierOrder   = 'IRON','BRONZE','SILVER','GOLD','PLATINUM','EMERALD','DIAMOND','MASTER','GRANDMASTER','CHALLENGER'
$TierNames   = @{ IRON = 'Fer'; BRONZE = 'Bronze'; SILVER = 'Argent'; GOLD = 'Or'; PLATINUM = 'Platine'; EMERALD = 'Émeraude'
                  DIAMOND = 'Diamant'; MASTER = 'Maître'; GRANDMASTER = 'Grand Maître'; CHALLENGER = 'Challenger' }
$MetaProps   = 'banned','riotId','region','queue','tier','division','lp','wins','losses','prev','updated','lastUsed','rank','decayAt','topChamps'
$SettingsEndpoints = [ordered]@{
    'game-settings'  = '/lol-game-settings/v1/game-settings'
    'input-settings' = '/lol-game-settings/v1/input-settings'
}

New-Item -ItemType Directory -Force $Store, $MetaDir | Out-Null
try { Start-Transcript -Path (Join-Path $Root 'log.txt') -Force | Out-Null } catch { }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
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
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class RsTrustLocal : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) {
        return p == 0 || r.RequestUri.Host == "127.0.0.1";
    }
}
"@
[Net.ServicePointManager]::CertificatePolicy = New-Object RsTrustLocal
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:StatusLabel = $null
$script:CancelButton = $null
$script:Form = $null
$script:CancelWait = $false

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
    return $m
}

function Set-Meta([string]$Name, $Meta) {
    $Meta.rank = $null
    $Meta | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $MetaDir "$Name.json") -Encoding UTF8
}

function Get-Score($o) {
    $tier = [array]::IndexOf($TierOrder, [string]$o.tier)
    $div = switch ($o.division) { 'I' { 3 } 'II' { 2 } 'III' { 1 } default { 0 } }
    return $tier * 10000 + $div * 1000 + [int]$o.lp
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

function Start-Riot {
    Start-Process (Get-RiotClientPath) '--launch-product=league_of_legends --launch-patchline=live'
}

function Clear-Session {
    if (Test-Path $DataDir) {
        if (Test-Path $Backup) { Remove-Item $Backup -Recurse -Force }
        Copy-Item $DataDir $Backup -Recurse -Force
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
    $m.queue = $queue
    $m.tier = $r.tier; $m.division = $r.division; $m.lp = $r.lp; $m.wins = $r.wins; $m.losses = $r.losses
    $m.banned = $false
    $m.updated = (Get-Date).ToString('o')
    Set-Meta $Name $m
    Say "$Name ($($m.riotId)) : $(Format-Rank $m)"
}

# ---------- Réglages communs à tous les comptes ----------

function Get-Config {
    $f = Join-Path $Root 'config.json'
    $c = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $defaults = @{ applyRef = $false; sortCol = 3; sortDesc = $true }
    foreach ($k in $defaults.Keys) {
        if ($c.PSObject.Properties.Name -notcontains $k) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
    }
    return $c
}

function Set-Config($c) { $c | ConvertTo-Json | Set-Content (Join-Path $Root 'config.json') -Encoding UTF8 }

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
    Copy-Item $DataDir $dst -Recurse -Force
    $m = Get-Meta $Name
    $m.lastUsed = (Get-Date).ToString('o')
    Set-Meta $Name $m
    Say "Profil '$Name' enregistré (le client a été fermé pour sauvegarder la session)."
}

function Use-Profile([string]$Name) {
    $src = Join-Path $Store $Name
    if (-not (Test-Path $src)) { throw "Profil '$Name' introuvable." }
    $m = Get-Meta $Name
    if ($m.banned -and -not (Ask-YesNo "'$Name' est marqué BANNI. Lancer quand même ?")) { return $false }
    Stop-Riot
    Clear-Session
    New-Item -ItemType Directory -Force $DataDir | Out-Null
    Copy-Item "$src\*" $DataDir -Recurse -Force
    Start-Riot
    Set-Content (Join-Path $Root 'current.txt') $Name -Encoding UTF8
    $m.lastUsed = (Get-Date).ToString('o')
    Set-Meta $Name $m

    Say "Lancement de '$Name'... en attente de LoL"
    $auth = Wait-Lcu $LcuTimeoutSec
    if ($script:CancelWait) { Say 'Attente annulée (LoL continue de se lancer).'; return $true }
    if (-not $auth) {
        Say "LoL ne s'est pas connecté sur '$Name'."
        $msg = "LoL ne s'est pas connecté sur '$Name'.`n`n" +
               "- Si le Riot Client affiche un ban : réponds Oui pour marquer le compte BANNI.`n" +
               "- Si on te demande de te reconnecter, la session a expiré : réponds Non, connecte-toi, " +
               "puis utilise « Ré-enregistrer la session ».`n`nMarquer '$Name' comme BANNI ?"
        if (Ask-YesNo $msg) {
            $m = Get-Meta $Name; $m.banned = $true; $m.updated = (Get-Date).ToString('o'); Set-Meta $Name $m
        }
        return $false
    }
    Update-RankFromLcu $Name $auth
    if ((Get-Config).applyRef) { Apply-RefSettings $auth }
    return $true
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

function New-Shortcut([string]$LinkName, [string]$ExtraArgs) {
    $path = Join-Path ([Environment]::GetFolderPath('Desktop')) "$LinkName.lnk"
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
    $s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" $ExtraArgs".Trim()
    $s.WorkingDirectory = $Root
    try { $s.IconLocation = "$(Get-RiotClientPath),0" } catch { }
    $s.Save()
}

function Remove-Profile([string]$Name) {
    Remove-Item (Join-Path $Store $Name) -Recurse -Force
    $f = Join-Path $MetaDir "$Name.json"
    if (Test-Path $f) { Remove-Item $f -Force }
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) "LoL - $Name.lnk"
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
    Say "Profil '$Name' supprimé."
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
    Start-Process "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
}

# ---------- Modes sans fenêtre ----------

if ($CreateShortcut) {
    New-Shortcut 'Riot Switcher' ''
    Show-Info 'Raccourci « Riot Switcher » créé sur le bureau.'
    exit
}

if ($Account) {
    Use-Profile $Account | Out-Null
    exit
}

# ---------- Fenêtre principale ----------

$form = New-Object Windows.Forms.Form
$form.Text = "Riot Switcher v$AppVersion"
$form.Size = New-Object Drawing.Size(1340, 580)
$form.MinimumSize = New-Object Drawing.Size(780, 400)
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
$ColumnNames = 'Compte', 'Riot ID', 'Serveur', 'Rang', 'Évolution', 'Winrate', 'Champions récents', 'Dernier lancement'
$ColumnWidths = 120, 155, 65, 260, 190, 120, 230, 160
for ($i = 0; $i -lt $ColumnNames.Count; $i++) { [void]$list.Columns.Add($ColumnNames[$i], $ColumnWidths[$i]) }

# Tri par colonne (clic sur l'en-tête). Le choix est mémorisé.
$cfg = Get-Config
$script:SortCol = [int]$cfg.sortCol
$script:SortDesc = [bool]$cfg.sortDesc

function Get-SortKey([string]$Name, $m, [int]$Col) {
    switch ($Col) {
        0 { return $Name.ToLower() }
        1 { return ([string]$m.riotId).ToLower() }
        2 { return [string]$m.region }
        3 { return Get-SortScore $m }
        4 { if ($m.prev -and $m.tier -and $m.prev.tier) { return (Get-Score $m) - (Get-Score $m.prev) } else { return -999999 } }
        5 { $n = [int]$m.wins + [int]$m.losses; if ($n) { return [int]$m.wins / $n } else { return -1 } }
        6 { return ([string]$m.topChamps).ToLower() }
        7 { if ($m.lastUsed) { return ([datetime]$m.lastUsed).Ticks } else { return 0 } }
    }
}

$buttons = New-Object Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Bottom'; $buttons.AutoSize = $true; $buttons.AutoSizeMode = 'GrowAndShrink'
$buttons.Padding = New-Object Windows.Forms.Padding(6, 6, 6, 0)

$opts = New-Object Windows.Forms.FlowLayoutPanel
$opts.Dock = 'Bottom'; $opts.AutoSize = $true; $opts.AutoSizeMode = 'GrowAndShrink'
$opts.Padding = New-Object Windows.Forms.Padding(6, 4, 6, 0)

$status = New-Object Windows.Forms.Label
$status.Dock = 'Bottom'; $status.Height = 28
$status.Padding = New-Object Windows.Forms.Padding(10, 6, 10, 0)
$status.ForeColor = [Drawing.Color]::DimGray
$script:StatusLabel = $status

$script:ActionControls = @()

function Get-SelectedName([switch]$Quiet) {
    if ($list.SelectedItems.Count) { return [string]$list.SelectedItems[0].Tag }
    if (-not $Quiet) { Show-Info 'Sélectionne d''abord un compte dans la liste.' }
    return $null
}

function Update-List {
    $sel = Get-SelectedName -Quiet
    $list.BeginUpdate()
    $list.Items.Clear()
    $rows = foreach ($p in Get-ChildItem $Store -Directory) {
        $m = Get-Meta $p.Name
        [pscustomobject]@{ Name = $p.Name; Meta = $m; Key = Get-SortKey $p.Name $m $script:SortCol }
    }
    $rows = @($rows | Sort-Object @{ Expression = 'Key'; Descending = $script:SortDesc }, Name)
    foreach ($r in $rows) {
        $m = $r.Meta
        $it = New-Object Windows.Forms.ListViewItem($r.Name)
        $it.Tag = $r.Name
        $it.UseItemStyleForSubItems = $false
        $decay = Format-Decay $m
        $rankText = (Format-Rank $m) + $(if ($decay) { "   $decay" } else { '' })
        foreach ($v in @($m.riotId, $m.region, $rankText, (Format-Delta $m), (Format-Winrate $m), $m.topChamps, (Format-Age $m.lastUsed))) {
            [void]$it.SubItems.Add([string]$v)
        }
        if ($m.banned) {
            foreach ($s in $it.SubItems) { $s.ForeColor = [Drawing.Color]::Firebrick }
        } else {
            $delta = $it.SubItems[4]
            if ($delta.Text -match '^[+▲]') { $delta.ForeColor = [Drawing.Color]::ForestGreen }
            elseif ($delta.Text -match '^[-▼]') { $delta.ForeColor = [Drawing.Color]::Firebrick }
            $dd = Get-DecayDays $m
            if ($null -ne $dd) {
                $it.SubItems[3].ForeColor = if ($dd -le 3) { [Drawing.Color]::Firebrick } else { [Drawing.Color]::DarkOrange }
            }
            if (Test-Stale $m) {
                $it.SubItems[7].Text += '  ⚠ session à vérifier'
                $it.SubItems[7].ForeColor = [Drawing.Color]::DarkOrange
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
    $info = Get-RefSettingsInfo
    $refLabel.Text = if ($info) { "Réglages de référence : $info" } else { 'Aucun réglage de référence enregistré.' }
}

function Invoke-Action([scriptblock]$Action) {
    $script:CancelWait = $false
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

$btnLaunch = Add-Button $buttons '▶ Lancer' { Invoke-Action { $n = Get-SelectedName; if ($n) { Use-Profile $n | Out-Null } } }
$btnLaunch.Font = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
Add-Button $buttons 'Ajouter un compte' { Invoke-Action { New-Login } } | Out-Null
Add-Button $buttons 'Ré-enregistrer la session' { Invoke-Action { $n = Get-SelectedName; if ($n) { Save-CurrentSessionAs $n } } } | Out-Null
Add-Button $buttons 'Actualiser le rang' {
    Invoke-Action {
        $cur = Join-Path $Root 'current.txt'
        if (-not (Test-Path $cur)) { Show-Info 'Aucun compte lancé via le switcher.'; return }
        $n = (Get-Content $cur -Raw).Trim()
        $auth = Wait-Lcu 15
        if ($auth) { Update-RankFromLcu $n $auth } else { Say 'LoL n''est pas lancé.' }
    }
} | Out-Null
Add-Button $buttons 'BAN / dé-BAN' {
    Invoke-Action {
        $n = Get-SelectedName
        if ($n) { $m = Get-Meta $n; $m.banned = -not $m.banned; $m.updated = (Get-Date).ToString('o'); Set-Meta $n $m }
    }
} | Out-Null
Add-Button $buttons 'Raccourci bureau' {
    Invoke-Action {
        $n = Get-SelectedName
        if ($n) { New-Shortcut "LoL - $n" "-Account `"$n`""; Say "Raccourci « LoL - $n » créé sur le bureau." }
    }
} | Out-Null
Add-Button $buttons 'Supprimer' {
    Invoke-Action { $n = Get-SelectedName; if ($n -and (Ask-YesNo "Supprimer le profil '$n' ?")) { Remove-Profile $n } }
} | Out-Null

$script:CancelButton = New-Object Windows.Forms.Button
$script:CancelButton.Text = 'Annuler l''attente'; $script:CancelButton.AutoSize = $true; $script:CancelButton.Visible = $false
$script:CancelButton.Add_Click({ $script:CancelWait = $true })
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
    $c = Get-Config; $c.applyRef = $chkApply.Checked; Set-Config $c
})
[void]$opts.Controls.Add($chkApply)
$script:ActionControls += $chkApply

$refLabel = New-Object Windows.Forms.Label
$refLabel.AutoSize = $true
$refLabel.Margin = New-Object Windows.Forms.Padding(12, 8, 6, 0)
$refLabel.ForeColor = [Drawing.Color]::DimGray
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
        Restart-App
        $form.Close()
    }
}
$btnUpdate.Visible = $false
$btnUpdate.ForeColor = [Drawing.Color]::RoyalBlue

$list.Add_ColumnClick({
    param($sender, $e)
    if ($e.Column -eq $script:SortCol) { $script:SortDesc = -not $script:SortDesc }
    else { $script:SortCol = $e.Column; $script:SortDesc = $e.Column -in 3, 4, 5, 7 }   # texte A->Z, chiffres du plus grand au plus petit
    $c = Get-Config; $c.sortCol = $script:SortCol; $c.sortDesc = $script:SortDesc; Set-Config $c
    Update-List
})

$list.Add_DoubleClick({ Invoke-Action { $n = Get-SelectedName -Quiet; if ($n) { Use-Profile $n | Out-Null } } })

# Ordre d'ajout : la liste occupe le haut, puis boutons, options et barre d'état en bas.
$form.Controls.AddRange(@($list, $buttons, $opts, $status))
$list.BringToFront()

$form.Add_Shown({
    Update-List
    if ($list.Items.Count) { Say 'Double-clic sur un compte pour le lancer.' }
    else { Say 'Aucun compte : clique sur « Ajouter un compte ».' }
    $script:PendingUpdate = Get-UpdateInfo
    if ($script:PendingUpdate) {
        $btnUpdate.Text = "⬆ Mettre à jour (v$($script:PendingUpdate.version))"
        $btnUpdate.Visible = $true
        Say "Nouvelle version $($script:PendingUpdate.version) disponible : clique sur « Mettre à jour »."
    }
})
[void]$form.ShowDialog()

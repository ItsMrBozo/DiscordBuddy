#Requires -Version 5.1
<#
  DiscordBuddy Companion - companion app for the DiscordBuddy WoW addon.

  WoW addons cannot make web requests. On level-up the addon takes a tagged
  "marker" screenshot (a small grid of coloured blocks that encodes your level
  and name), then a clean screenshot. This script:
    * finds your World of Warcraft install and every game version in it
    * watches each version's Screenshots folder
    * decodes and deletes marker screenshots
    * reads the Discord webhook + message you saved in the addon's settings
      (WTF\Account\<account>\SavedVariables\DiscordBuddy.lua)
    * posts the message encoded in the marker, with the clean screenshot
    * after each weekly reset, posts the weekly recap the addon saved

  What it does NOT do: it never reads game memory, never sends anything
  anywhere except a discord.com webhook URL, never runs code from the game
  folder, and never sends a screenshot unless the addon tagged it.

  Log: %LOCALAPPDATA%\DiscordBuddy\companion.log
  Optional settings: %LOCALAPPDATA%\DiscordBuddy\settings.json
      { "wowPaths": [ "D:\\Games\\World of Warcraft" ] }
#>

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'

# ---- Marker format: MUST match DiscordBuddy.lua ---------------------------
$BlockFrac = 0.012
$Cols      = 40
$Signature = @(@(255, 0, 0), @(0, 255, 0), @(0, 0, 255))

$PollMs           = 500
$CleanShotTimeout = 10     # seconds to wait for the clean shot after a marker
$MinPostGap       = 2      # seconds between posts
$Week             = 604800
$RecapCheckEvery  = 300    # seconds
$MaxUploadBytes   = 8MB

$AppDir       = Join-Path $env:LOCALAPPDATA 'DiscordBuddy'
$LogPath      = Join-Path $AppDir 'companion.log'
$SettingsPath = Join-Path $AppDir 'settings.json'
$StatePath    = Join-Path $AppDir 'state.json'
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

# ---- Logging (never logs the webhook token) ---------------------------------
function Write-Log([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 1MB)) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
        }
        [IO.File]::AppendAllText($LogPath, $line + "`r`n", [Text.Encoding]::UTF8)
    } catch { }
    try { [Console]::WriteLine($line) } catch { }
}

function Get-Short([string]$Text, [int]$Max) {
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + '...'
}

# ---- Single instance ---------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\DiscordBuddyCompanion', [ref]$createdNew)
if (-not $createdNew) {
    Write-Log 'DiscordBuddy Companion is already running; this copy will exit.'
    exit 0
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(30)
$Http.DefaultRequestHeaders.UserAgent.ParseAdd("DiscordBuddyCompanion/$Version")

# ---- Finding World of Warcraft ----------------------------------------------
function Get-WowRoots {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $SettingsPath) {
        try {
            $s = [IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
            foreach ($p in @($s.wowPaths)) { if ($p) { $candidates.Add([string]$p) } }
        } catch { Write-Log "Couldn't read settings.json: $($_.Exception.Message)" }
    }
    foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft',
                       'HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft')) {
        try {
            $p = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).InstallPath
            if ($p) { $candidates.Add([string]$p) }
        } catch { }
    }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'World of Warcraft')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'World of Warcraft')) }
    foreach ($drive in [IO.DriveInfo]::GetDrives()) {
        try {
            if ($drive.DriveType -eq 'Fixed' -and $drive.IsReady) {
                $candidates.Add((Join-Path $drive.RootDirectory.FullName 'World of Warcraft'))
                $candidates.Add((Join-Path $drive.RootDirectory.FullName 'Games\World of Warcraft'))
                $candidates.Add((Join-Path $drive.RootDirectory.FullName 'Program Files (x86)\World of Warcraft'))
            }
        } catch { }
    }

    $roots = @{}
    foreach ($c in $candidates) {
        $c = $c.Trim().TrimEnd('\', '/')
        if (-not $c) { continue }
        if ((Split-Path -Leaf $c) -match '^_.+_$') { $c = Split-Path -Parent $c }
        if ((Test-Path -LiteralPath $c -PathType Container) -and -not $roots.ContainsKey($c.ToLowerInvariant())) {
            $roots[$c.ToLowerInvariant()] = $c
        }
    }
    return @($roots.Values)
}

# A "flavor" is one game version folder (_retail_, _classic_era_, _forever_, ...)
# that has the DiscordBuddy addon installed.
function Get-Flavors {
    $list = @()
    foreach ($root in @(Get-WowRoots)) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Name -notmatch '^_.+_$') { continue }
            $addon = Join-Path $dir.FullName 'Interface\AddOns\DiscordBuddy'
            if (-not (Test-Path -LiteralPath $addon)) { continue }
            $list += [pscustomobject]@{
                Name  = $dir.Name
                Path  = $dir.FullName
                Shots = Join-Path $dir.FullName 'Screenshots'
            }
        }
    }
    return $list
}

# ---- Reading the addon's saved settings -------------------------------------
function ConvertFrom-LuaString([string]$s) {
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $e = $m.Groups[1].Value
        switch -CaseSensitive ($e) {
            'n'  { return "`n" }
            't'  { return "`t" }
            'r'  { return "`r" }
            '"'  { return '"' }
            "'"  { return "'" }
            '\'  { return '\' }
            default {
                if ($e -match '^\d+$') { return [string][char][int]$e }
                return $e
            }
        }
    }
    return [regex]::Replace($s, '\\(\d{1,3}|.)', $evaluator)
}

function Get-ValidWebhook([string]$Url) {
    if (-not $Url) { return $null }
    $m = [regex]::Match($Url.Trim(), '^https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/(\d{15,25})/([A-Za-z0-9_-]{30,100})$')
    if (-not $m.Success) { return $null }
    return 'https://discord.com/api/webhooks/{0}/{1}' -f $m.Groups[1].Value, $m.Groups[2].Value
}

function Get-AddonSettings([string]$FlavorPath) {
    $accountRoot = Join-Path $FlavorPath 'WTF\Account'
    $best = $null
    foreach ($acct in @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue)) {
        $file = Join-Path $acct.FullName 'SavedVariables\DiscordBuddy.lua'
        if (Test-Path -LiteralPath $file) {
            $fi = Get-Item -LiteralPath $file
            if ($null -eq $best -or $fi.LastWriteTimeUtc -gt $best.LastWriteTimeUtc) { $best = $fi }
        }
    }
    if ($null -eq $best) { return $null }

    $text = [IO.File]::ReadAllText($best.FullName, [Text.Encoding]::UTF8)
    $settings = @{ Webhook = $null; Enabled = $true }
    $m = [regex]::Match($text, '\["webhook"\]\s*=\s*"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { $settings.Webhook = Get-ValidWebhook (ConvertFrom-LuaString $m.Groups[1].Value) }
    if ($text -match '\["enabled"\]\s*=\s*false') { $settings.Enabled = $false }
    return $settings
}

# Every account's saved settings in one game folder: webhook, recap switch, recap texts.
function Get-AllAccountSettings([string]$FlavorPath) {
    $result = @()
    $accountRoot = Join-Path $FlavorPath 'WTF\Account'
    foreach ($acct in @(Get-ChildItem -LiteralPath $accountRoot -Directory -ErrorAction SilentlyContinue)) {
        $file = Join-Path $acct.FullName 'SavedVariables\DiscordBuddy.lua'
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $fi = Get-Item -LiteralPath $file
        $text = [IO.File]::ReadAllText($fi.FullName, [Text.Encoding]::UTF8)
        $entry = @{
            Account      = $acct.Name
            Modified     = $fi.LastWriteTimeUtc
            Webhook      = $null
            RecapEnabled = -not ($text -match '\["recapEnabled"\]\s*=\s*false')
            Recaps       = @{}
        }
        $m = [regex]::Match($text, '\["webhook"\]\s*=\s*"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { $entry.Webhook = Get-ValidWebhook (ConvertFrom-LuaString $m.Groups[1].Value) }
        $block = [regex]::Match($text, '\["recaps"\]\s*=\s*\{(.*?)\n\}', [Text.RegularExpressions.RegexOptions]::Singleline)
        if ($block.Success) {
            foreach ($r in [regex]::Matches($block.Groups[1].Value, '\[(\d+)\]\s*=\s*"((?:[^"\\]|\\.)*)"')) {
                $entry.Recaps[[long]$r.Groups[1].Value] = ConvertFrom-LuaString $r.Groups[2].Value
            }
        }
        $result += $entry
    }
    return $result
}

# ---- Marker decoding ----------------------------------------------------------
function Get-BlockColor($Bitmap, [int]$Index) {
    $s   = $BlockFrac * $Bitmap.Height
    $col = $Index % $Cols
    $row = [math]::Floor($Index / $Cols)
    $cx  = ($col + 0.5) * $s
    $cy  = ($row + 0.5) * $s
    $r   = [math]::Max(1, [math]::Floor($s * 0.25))
    $x0 = [math]::Max(0, [math]::Floor($cx - $r)); $x1 = [math]::Min($Bitmap.Width - 1,  [math]::Floor($cx + $r))
    $y0 = [math]::Max(0, [math]::Floor($cy - $r)); $y1 = [math]::Min($Bitmap.Height - 1, [math]::Floor($cy + $r))
    $sr = 0.0; $sg = 0.0; $sb = 0.0; $n = 0
    for ($y = $y0; $y -le $y1; $y++) {
        for ($x = $x0; $x -le $x1; $x++) {
            $p = $Bitmap.GetPixel([int]$x, [int]$y)
            $sr += $p.R; $sg += $p.G; $sb += $p.B; $n++
        }
    }
    if ($n -eq 0) { return @(-999, -999, -999) }
    return @(($sr / $n), ($sg / $n), ($sb / $n))
}

# $Sample is a scriptblock: param($i) -> @(r, g, b). Kept separate from the
# bitmap so the decoding rules can be tested on their own.
function Read-MarkerFromSampler([scriptblock]$Sample) {
    for ($i = 0; $i -lt $Signature.Count; $i++) {
        $c = & $Sample $i
        for ($k = 0; $k -lt 3; $k++) {
            if ([math]::Abs($c[$k] - $Signature[$i][$k]) -gt 70) { return $null }
        }
    }
    $state = @{ Pos = $Signature.Count; Bad = $false }
    $read = {
        param([int]$Bits)
        $v = 0
        for ($bitIndex = 0; $bitIndex -lt $Bits; $bitIndex++) {
            $c = & $Sample $state.Pos
            $state.Pos++
            $lum = ($c[0] + $c[1] + $c[2]) / 3
            if ($lum -gt 70 -and $lum -lt 185) { $state.Bad = $true; return 0 }
            $v = $v * 2 + [int]($lum -ge 128)
        }
        return $v
    }
    $isTest = (& $read 1) -eq 1
    $length = & $read 7
    $flags  = & $read 8
    if ($state.Bad -or $length -lt 1) { return $null }
    $bytes = New-Object byte[] $length
    $sum = $length + $flags
    for ($i = 0; $i -lt $length; $i++) {
        $bytes[$i] = [byte](& $read 8)
        $sum += $bytes[$i]
    }
    $checksum = & $read 8
    if ($state.Bad -or ($sum % 256) -ne $checksum) { return $null }
    $payload = [Text.Encoding]::UTF8.GetString($bytes)
    $sep = $payload.IndexOf([char]31)
    if ($sep -lt 1) { return $null }
    return [pscustomobject]@{
        Key          = $payload.Substring(0, $sep)
        Message      = $payload.Substring($sep + 1)
        Test         = $isTest
        CleanFollows = [bool]($flags -band 1)
    }
}

function Read-Marker([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ms = New-Object IO.MemoryStream(, $bytes)
    $bmp = $null
    try {
        try { $bmp = New-Object System.Drawing.Bitmap($ms) } catch { return $null }
        if ($bmp.Height -lt 100) { return $null }
        $script:MarkerBitmap = $bmp
        return Read-MarkerFromSampler { param($i) Get-BlockColor $script:MarkerBitmap $i }
    } finally {
        $script:MarkerBitmap = $null
        if ($bmp) { $bmp.Dispose() }
        $ms.Dispose()
    }
}

# ---- Posting ------------------------------------------------------------------
function Get-UploadImage([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $isJpeg = $bytes.Length -gt 3 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8
    if ($isJpeg -and $bytes.Length -le $MaxUploadBytes) { return , $bytes }

    # PNG/BMP or an oversized JPEG: re-encode as JPEG, shrinking if needed.
    $ms = New-Object IO.MemoryStream(, $bytes)
    $src = New-Object System.Drawing.Bitmap($ms)
    try {
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]85)
        $scale = 1.0
        while ($true) {
            $w = [int]($src.Width * $scale); $h = [int]($src.Height * $scale)
            $bmp = New-Object System.Drawing.Bitmap($src, $w, $h)
            $out = New-Object IO.MemoryStream
            try { $bmp.Save($out, $codec, $params) } finally { $bmp.Dispose() }
            $result = $out.ToArray(); $out.Dispose()
            if ($result.Length -le $MaxUploadBytes -or $scale -lt 0.3) { return , $result }
            $scale *= 0.75
        }
    } finally { $src.Dispose(); $ms.Dispose() }
}

$Emoji = @{
    level = @(0x1F389); maxlevel = @(0x1F3C6); profession = @(0x1F6E0, 0xFE0F); reputation = @(0x1F91D)
    loot = @(0x1F48E); rare = @(0x2B50); boss = @(0x1F409); gold = @(0x1F4B0); death = @(0x1F480)
    legacy = @(0x1F4DC); pvp = @(0x2694, 0xFE0F); title = @(0x1F3F7, 0xFE0F); recap = @(0x1F4C5)
}

function Get-Emoji([string]$Key) {
    $codes = $Emoji[$Key]
    if (-not $codes) { return '' }
    return (($codes | ForEach-Object { [char]::ConvertFromUtf32($_) }) -join '')
}

# The addon sends the finished message; only make it safe and add the emoji.
function Format-Post([string]$Key, [string]$Message, [bool]$IsTest) {
    $zwsp = [string][char]0x200B
    $msg = [regex]::Replace($Message, '@(everyone|here)', ('@' + $zwsp + '$1'))
    $e = Get-Emoji $Key
    if ($e) { $msg = $msg + ' ' + $e }
    if ($IsTest) { $msg = '[test] ' + $msg }
    return (Get-Short $msg 1900)
}

function Send-Discord([string]$Webhook, [string]$Content, [byte[]]$Image) {
    $payload = @{
        username         = 'Buddy'
        content          = $Content
        allowed_mentions = @{ parse = @() }   # never ping anyone
    }
    if ($Image) { $payload.attachments = @(@{ id = 0; filename = 'ding.jpg' }) }
    $json = ConvertTo-Json -InputObject $payload -Depth 5 -Compress

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $form = New-Object System.Net.Http.MultipartFormDataContent
        try {
            $form.Add((New-Object System.Net.Http.StringContent($json, [Text.Encoding]::UTF8, 'application/json')), 'payload_json')
            if ($Image) {
                $img = New-Object System.Net.Http.ByteArrayContent(, $Image)
                $img.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('image/jpeg')
                $form.Add($img, 'files[0]', 'ding.jpg')
            }
            $resp = $Http.PostAsync($Webhook + '?wait=true', $form).GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            if ($resp.IsSuccessStatusCode) { return $true }
            $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if ($code -eq 429) {
                $wait = 2.0
                try { $wait = [double]((ConvertFrom-Json $body).retry_after) } catch { }
                Write-Log ('Discord rate limit; retrying in {0:N1}s' -f $wait)
                Start-Sleep -Milliseconds ([int](1000 * [math]::Min([math]::Max($wait, 0.5), 30)))
                continue
            }
            if ($code -eq 401 -or $code -eq 404) {
                Write-Log "Discord says this webhook doesn't exist (HTTP $code). Set a new one with /buddy in game."
            } else {
                Write-Log "Discord rejected the post: HTTP $code $(Get-Short $body 200)"
            }
            return $false
        } catch {
            Write-Log "Network error: $($_.Exception.GetBaseException().Message)"
            Start-Sleep -Seconds 3
        } finally {
            $form.Dispose()
        }
    }
    Write-Log 'Gave up posting after several attempts.'
    return $false
}

$script:LastPost = [datetime]::MinValue

function Publish-Event($Marker, $Settings, [string]$ImagePath) {
    $since = ((Get-Date) - $script:LastPost).TotalSeconds
    if ($since -lt $MinPostGap) { Start-Sleep -Milliseconds ([int](1000 * ($MinPostGap - $since))) }
    $content = Format-Post $Marker.Key $Marker.Message $Marker.Test
    $image = $null
    if ($ImagePath) {
        try { $image = Get-UploadImage $ImagePath } catch { Write-Log "Couldn't read the screenshot, posting text only: $($_.Exception.Message)" }
    }
    $script:LastPost = Get-Date
    if (Send-Discord $Settings.Webhook $content $image) {
        Write-Log ("Posted {0}{1}" -f $Marker.Key, $(if ($image) { ' with screenshot' } else { '' }))
    }
}

# ---- Weekly recap ----------------------------------------------------------------
function Get-PostedState {
    $posted = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $st = [IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
            foreach ($p in @($st.posted)) { if ($p) { $posted.Add([string]$p) } }
        } catch { }
    }
    return , $posted
}

function Save-PostedState($Posted) {
    while ($Posted.Count -gt 100) { $Posted.RemoveAt(0) }
    $json = ConvertTo-Json -InputObject @{ posted = @($Posted) } -Compress
    [IO.File]::WriteAllText($StatePath, $json, [Text.Encoding]::UTF8)
}

# Split long text into Discord-sized chunks on line boundaries.
function Split-Message([string]$Text, [int]$Max) {
    $chunks = New-Object 'System.Collections.Generic.List[string]'
    $cur = ''
    foreach ($line in $Text -split "`n") {
        if (($cur.Length + $line.Length + 1) -gt $Max -and $cur) { $chunks.Add($cur.TrimEnd()); $cur = '' }
        $cur += $line + "`n"
    }
    if ($cur.Trim()) { $chunks.Add($cur.TrimEnd()) }
    return , $chunks
}

function Invoke-RecapCheck($Flavors) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $posted = Get-PostedState
    $changed = $false
    foreach ($fl in $Flavors) {
        foreach ($acct in @(Get-AllAccountSettings $fl.Path)) {
            if (-not $acct.RecapEnabled -or -not $acct.Webhook) { continue }
            $modified = ([DateTimeOffset]$acct.Modified).ToUnixTimeSeconds()
            foreach ($ws in @($acct.Recaps.Keys | Sort-Object)) {
                $weekEnd = $ws + $Week
                if ($now -lt $weekEnd) { continue }                    # week not over yet
                if ($now -gt $weekEnd + 14 * 86400) { continue }       # too old, never post
                # wait until the game has saved after the reset, or a day has passed
                if ($modified -lt $weekEnd -and $now -lt $weekEnd + 86400) { continue }
                $id = '{0}|{1}|{2}' -f $fl.Name, $acct.Account, $ws
                if ($posted.Contains($id)) { continue }
                $text = $acct.Recaps[$ws]
                $ok = $true
                $first = $true
                foreach ($chunk in (Split-Message $text 1850)) {
                    $msg = if ($first) { (Get-Emoji 'recap') + ' ' + $chunk } else { $chunk }
                    $msg = [regex]::Replace($msg, '@(everyone|here)', ('@' + [char]0x200B + '$1'))
                    if (-not (Send-Discord $acct.Webhook $msg $null)) { $ok = $false; break }
                    $first = $false
                    Start-Sleep -Milliseconds 1200
                }
                if ($ok) {
                    $posted.Add($id); $changed = $true
                    Write-Log "Posted weekly recap for the week starting $([DateTimeOffset]::FromUnixTimeSeconds($ws).LocalDateTime.ToString('MMM d')) [$($fl.Name)]"
                }
            }
        }
    }
    if ($changed) { Save-PostedState $posted }
}

# ---- Watching ------------------------------------------------------------------
function Wait-FileReady([string]$Path) {
    $last = -1
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $len = (New-Object IO.FileInfo($Path)).Length
            if ($len -gt 0 -and $len -eq $last) {
                $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                $fs.Close()
                return $true
            }
            $last = $len
        } catch { }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-ShotFiles([string]$Dir) {
    try {
        return @([IO.Directory]::GetFiles($Dir) | Where-Object { $_ -match '\.(jpe?g|png|bmp|tga)$' } | Sort-Object)
    } catch { return @() }
}

function Invoke-Main {
    Write-Log "DiscordBuddy Companion $Version started."
    $flavors  = @()
    $watch    = @{}     # flavor path -> @{ Seen = HashSet; Stamp = last folder write time }
    $pending  = $null
    $nextScan = [datetime]::MinValue
    $nextRecap = (Get-Date).AddSeconds(30)
    $tgaWarned = $false

    while ($true) {
        if ((Get-Date) -ge $nextScan) {
            $flavors = @(Get-Flavors)
            foreach ($fl in $flavors) {
                if (-not $watch.ContainsKey($fl.Path)) {
                    if (-not (Test-Path -LiteralPath $fl.Shots)) {
                        try { New-Item -ItemType Directory -Path $fl.Shots | Out-Null } catch { }
                    }
                    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
                    foreach ($f in @(Get-ShotFiles $fl.Shots)) { [void]$seen.Add($f) }
                    $watch[$fl.Path] = @{ Seen = $seen; Stamp = [datetime]::MinValue }
                    $s = Get-AddonSettings $fl.Path
                    $hook = if ($s -and $s.Webhook) { 'webhook set' } else { 'no webhook saved yet - type /buddy in game' }
                    Write-Log "Watching $($fl.Name) ($hook): $($fl.Shots)"
                }
            }
            if ($flavors.Count -eq 0 -and -not $script:NoneWarned) {
                $script:NoneWarned = $true
                Write-Log 'No WoW game folder with DiscordBuddy installed found yet; will keep checking every minute.'
            }
            if ($flavors.Count -gt 0) { $script:NoneWarned = $false }
            $nextScan = (Get-Date).AddSeconds(60)
        }

        foreach ($fl in $flavors) {
            $w = $watch[$fl.Path]
            try { $stamp = [IO.Directory]::GetLastWriteTimeUtc($fl.Shots) } catch { continue }
            if ($stamp -eq $w.Stamp -and -not $pending) { continue }
            $w.Stamp = $stamp

            foreach ($file in @(Get-ShotFiles $fl.Shots)) {
                if ($w.Seen.Contains($file)) { continue }
                [void]$w.Seen.Add($file)
                if (-not (Wait-FileReady $file)) { continue }

                if ($file -match '\.tga$' -and -not $tgaWarned) {
                    $tgaWarned = $true
                    Write-Log 'Your screenshots are TGA, which this app can''t read. In WoW type: /console screenshotFormat jpg'
                }

                $marker = $null
                try { $marker = Read-Marker $file } catch { Write-Log "Couldn't read $([IO.Path]::GetFileName($file)): $($_.Exception.Message)" }

                if ($marker) {
                    if ($pending) {   # an earlier event never got its clean shot: post it as text
                        $p = $pending; $pending = $null
                        Publish-Event $p.Marker $p.Settings $null
                    }
                    Write-Log ("Marker: {0}{1} [{2}]" -f $marker.Key, $(if ($marker.Test) { ' (test)' } else { '' }), $fl.Name)
                    try { Remove-Item -LiteralPath $file -Force } catch { }
                    $settings = Get-AddonSettings $fl.Path
                    if (-not $settings -or -not $settings.Webhook) {
                        Write-Log 'No valid webhook saved. In game: /buddy, paste the webhook, click Set, then Save & Reload.'
                        $pending = $null
                        continue
                    }
                    if ($marker.CleanFollows) {
                        $pending = @{ Flavor = $fl.Path; Marker = $marker; Settings = $settings; Deadline = (Get-Date).AddSeconds($CleanShotTimeout) }
                    } else {
                        $pending = $null
                        Publish-Event $marker $settings $null
                    }
                } elseif ($pending -and $pending.Flavor -eq $fl.Path) {
                    $p = $pending; $pending = $null
                    Publish-Event $p.Marker $p.Settings $file
                }
                # anything else is a normal screenshot you took yourself: ignored
            }
        }

        if ((Get-Date) -ge $nextRecap -and -not $pending) {
            try { Invoke-RecapCheck $flavors } catch { Write-Log "Recap check failed: $($_.Exception.Message)" }
            $nextRecap = (Get-Date).AddSeconds($RecapCheckEvery)
        }

        if ($pending -and (Get-Date) -gt $pending.Deadline) {
            Write-Log 'The clean screenshot never arrived; posting text only.'
            $p = $pending; $pending = $null
            Publish-Event $p.Marker $p.Settings $null
        }

        Start-Sleep -Milliseconds $PollMs
    }
}

if ($env:DISCORDBUDDY_NO_MAIN -ne '1') {
    try {
        Invoke-Main
    } catch {
        Write-Log "Stopped because of an error: $($_.Exception.Message)"
        throw
    } finally {
        try { $mutex.ReleaseMutex() } catch { }
    }
}

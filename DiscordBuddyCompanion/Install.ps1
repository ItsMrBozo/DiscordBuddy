#Requires -Version 5.1
# Installs DiscordBuddy Companion for the current Windows user (no admin needed):
#   * copies DiscordBuddyCompanion.ps1 to %LOCALAPPDATA%\DiscordBuddy
#   * adds a shortcut to your Startup folder so it runs hidden when you sign in
#   * starts it now
$ErrorActionPreference = 'Stop'

$src    = Split-Path -Parent $MyInvocation.MyCommand.Path
$dest   = Join-Path $env:LOCALAPPDATA 'DiscordBuddy'
$script = Join-Path $dest 'DiscordBuddyCompanion.ps1'
$ps     = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk    = Join-Path ([Environment]::GetFolderPath('Startup')) 'DiscordBuddy Companion.lnk'
$launchArgs   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script

Write-Host ''
Write-Host 'Installing DiscordBuddy Companion...' -ForegroundColor Cyan

# Stop a copy that is already running (e.g. when updating).
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*DiscordBuddyCompanion.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# Remove the older "Ding Companion" (this app's previous name) so nothing posts twice.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*DingCompanion.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$oldLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Ding Companion.lnk'
$oldDir = Join-Path $env:LOCALAPPDATA 'DingCompanion'
if (Test-Path -LiteralPath $oldLnk) { Remove-Item -LiteralPath $oldLnk -Force }
if (Test-Path -LiteralPath $oldDir) { Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -LiteralPath (Join-Path $src 'DiscordBuddyCompanion.ps1') -Destination $script -Force
Unblock-File -LiteralPath $script   # remove the "downloaded from the internet" flag

$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($lnk)
$sc.TargetPath       = $ps
$sc.Arguments        = $launchArgs
$sc.WorkingDirectory = $dest
$sc.WindowStyle      = 7
$sc.Description      = 'DiscordBuddy Companion - posts your WoW level-ups to Discord (DiscordBuddy addon)'
$sc.Save()

Start-Process -FilePath $ps -ArgumentList $launchArgs -WindowStyle Hidden

Write-Host ''
Write-Host 'Done. DiscordBuddy Companion is running in the background and will start when you sign in to Windows.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next, in World of Warcraft:'
Write-Host '  1. Type /buddy'
Write-Host '  2. Paste your Discord webhook URL and click Set'
Write-Host '  3. Click Save & Reload, then Send test post'
Write-Host ''
Write-Host "Log file: $(Join-Path $dest 'companion.log')"
Write-Host 'To remove it later, run Uninstall.cmd.'

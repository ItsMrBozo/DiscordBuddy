#Requires -Version 5.1
# Removes DiscordBuddy Companion: stops it, deletes the Startup shortcut and its folder.
# Your WoW addon and its settings are not touched.
$ErrorActionPreference = 'Continue'

$dest = Join-Path $env:LOCALAPPDATA 'DiscordBuddy'
$lnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'DiscordBuddy Companion.lnk'

Write-Host ''
Write-Host 'Removing DiscordBuddy Companion...' -ForegroundColor Cyan

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*DiscordBuddyCompanion.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

if (Test-Path -LiteralPath $lnk)  { Remove-Item -LiteralPath $lnk -Force }
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }

Write-Host 'Done. DiscordBuddy Companion has been removed.' -ForegroundColor Green
Write-Host 'To stop level-up posts entirely, also disable or delete the DiscordBuddy addon.'

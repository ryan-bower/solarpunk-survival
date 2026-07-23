# Deploy the latest mod, launch Solarpunk, and confirm the mod loaded. This is the "run the app"
# entrypoint for the game+mod (Claude's /run uses it via .claude/skills/launch-solarpunk).
#
#   powershell -ExecutionPolicy Bypass -File tools/run.ps1 [-NoInstall] [-WaitSeconds 120] [-GameDir <path>]
#
# It stops any running instance (a fresh UE4SS injection needs a clean launch, and install.ps1
# cannot overwrite the locked DLL/paks while the game runs), re-runs install.ps1 to copy in the
# current mod + pak, launches via Steam, then tails ue4ss/UE4SS.log until the mod logs
# "SolarpunkSurvival vX.Y.Z starting".
param(
  [switch]$NoInstall,
  [int]$WaitSeconds = 120,
  [int]$AppId = 1805110,
  [string]$GameDir
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$procName = 'SolarpunkSteam-Win64-Shipping'

# 1) stop a running instance so the fresh mod injects on the next launch
$running = Get-Process $procName -ErrorAction SilentlyContinue
if ($running) {
  Write-Host 'Stopping the running game (a clean launch is needed to inject the fresh mod)...'
  $running | Stop-Process -Force
  Start-Sleep -Seconds 4   # let the OS release dwmapi.dll / the paks before install.ps1 rewrites them
}

# 2) deploy the current mod + pak, and learn the exact game dir from install.ps1's own detection
$game = $null
if (-not $NoInstall) {
  Write-Host 'Installing the latest mod...'
  $installArgs = @()
  if ($GameDir) { $installArgs += @('-GameDir', $GameDir) }
  $installArgs += $args
  $installOut = & powershell -ExecutionPolicy Bypass -File (Join-Path $repo 'install.ps1') @installArgs *>&1
  $installOut | ForEach-Object { Write-Host $_ }
  if ($LASTEXITCODE) { throw 'install.ps1 failed (see output above)' }
  $game = $installOut | ForEach-Object { if ($_ -match '^Game:\s+(.+?)\s*$') { $matches[1] } } | Select-Object -First 1
}
if (-not $game) {
  $game = if ($GameDir) { $GameDir } else { 'C:\Program Files (x86)\Steam\steamapps\common\Solarpunk\Solarpunk' }
}
$log = Join-Path $game 'Binaries\Win64\ue4ss\UE4SS.log'

# 3) launch and wait for the mod's own startup line in the UE4SS log
if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }
Write-Host ('Launching Solarpunk (app ' + $AppId + ')...')
Start-Process ('steam://rungameid/' + $AppId)

$pattern  = 'SolarpunkSurvival v[\d.]+ starting'
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 3
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern $pattern -Quiet)) { $ready = $true; break }
}

if ($ready) {
  Write-Host ''
  Write-Host 'Mod loaded. Recent SolarpunkSurvival log:' -ForegroundColor Green
  Select-String -Path $log -Pattern 'SolarpunkSurvival' | Select-Object -Last 15 | ForEach-Object { Write-Host ('  ' + $_.Line) }
  Write-Host ''
  Write-Host 'Load a save (the menu has no pawn, so most features need a world), then press P for a storm.'
} else {
  Write-Warning ("Did not see `"$pattern`" within $WaitSeconds s.")
  Write-Warning ('Check the UE4SS console window, or the log at: ' + $log)
  Write-Warning 'If UE4SS did not inject at all, confirm the Solarpunk-patched UE4SS is installed (install.ps1 -Force).'
  if (Test-Path $log) {
    Write-Host '--- last 20 lines of UE4SS.log ---'
    Get-Content $log -Tail 20 | ForEach-Object { Write-Host ('  ' + $_) }
  }
}

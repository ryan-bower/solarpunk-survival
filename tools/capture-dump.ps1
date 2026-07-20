# Launch Solarpunk, wait for UE4SS to produce output (log + any re_capture.txt), copy it into
# dumps/ (git-ignored), then stop the game. Use after install-dev-env.ps1.
# Usage:  powershell -File tools/capture-dump.ps1 [-WaitSeconds 90]
param(
  [string]$GameWin64 = 'C:\Program Files (x86)\Steam\steamapps\common\Solarpunk\Solarpunk\Binaries\Win64',
  [int]$AppId = 1805110,
  [int]$WaitSeconds = 90
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $repo ('dumps\' + $stamp)
New-Item -ItemType Directory -Force -Path $out | Out-Null

$log = Join-Path $GameWin64 'ue4ss\UE4SS.log'
$reFile = Join-Path $GameWin64 'ue4ss\Mods\SolarpunkSurvival\dump\re_capture.txt'
$procName = 'SolarpunkSteam-Win64-Shipping'

foreach ($f in @($log, $reFile)) { if (Test-Path $f) { Remove-Item $f -Force } }

Write-Host ('Launching Solarpunk (app ' + $AppId + ')...')
Start-Process ('steam://rungameid/' + $AppId)

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$sawLog = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  if (-not $sawLog -and (Test-Path $log)) { $sawLog = $true; Write-Host 'UE4SS.log appeared (injection OK).' }
  if (Test-Path $reFile) { Write-Host 're_capture.txt found.'; break }
  $alive = [bool](Get-Process $procName -ErrorAction SilentlyContinue)
  if ($sawLog -and -not $alive) { Write-Host 'Game exited.'; break }
}

if (Test-Path $log) { Copy-Item $log $out -Force }
if (Test-Path $reFile) { Copy-Item $reFile $out -Force }

Get-Process $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if (-not $sawLog) {
  Write-Warning 'No UE4SS.log was produced. UE4SS may be incompatible with this game build.'
  Write-Warning ('If the game also failed to launch, delete dwmapi.dll and ue4ss from ' + $GameWin64 + ' and use the Solarpunk-patched UE4SS from Nexus.')
}
Write-Host ('Artifacts in: ' + $out)
Get-ChildItem $out -ErrorAction SilentlyContinue | Select-Object Name, Length | Format-Table -AutoSize | Out-String | Write-Host
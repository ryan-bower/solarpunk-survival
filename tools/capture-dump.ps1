# Launch Solarpunk, wait for UE4SS to produce output (log + any re_capture.txt), copy it into
# dumps/ (git-ignored), then stop the game. Use after install-dev-env.ps1.
# Usage:  pwsh tools/capture-dump.ps1 [-WaitSeconds 150]
param(
  [string]$GameWin64 = 'C:\Program Files (x86)\Steam\steamapps\common\Solarpunk\Solarpunk\Binaries\Win64',
  [int]$AppId = 1805110,
  [int]$WaitSeconds = 150
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$out  = Join-Path $repo ('dumps\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $out | Out-Null

$log      = Join-Path $GameWin64 'ue4ss\UE4SS.log'
$reDir    = Join-Path $GameWin64 'ue4ss\Mods\SolarpunkSurvival\dump'
$reFile   = Join-Path $reDir 're_capture.txt'
$procName = 'SolarpunkSteam-Win64-Shipping'

# clear prior artifacts
foreach ($f in @($log, $reFile)) { if (Test-Path $f) { Remove-Item $f -Force } }

Write-Host "Launching Solarpunk (app $AppId)..."
Start-Process ("steam://rungameid/$AppId")

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$sawLog = $false
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  if (-not $sawLog -and (Test-Path $log)) { $sawLog = $true; Write-Host "UE4SS.log appeared (injection OK)." }
  if (Test-Path $reFile) { Write-Host "re_capture.txt found."; break }
  if (-not (Get-Process $procName -ErrorAction SilentlyContinue) -and $sawLog) {
    Write-Host "Game exited."; break
  }
}

if (Test-Path $log)    { Copy-Item $log    $out -Force }
if (Test-Path $reFile) { Copy-Item $reFile $out -Force }

# stop the game
Get-Process $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if (-not $sawLog) {
  Write-Warning "No UE4SS.log was produced — UE4SS may be incompatible with this build."
  Write-Warning "If the game also failed to launch, remove dwmapi.dll + ue4ss from $GameWin64 and try the Solarpunk-patched UE4SS from Nexus instead."
}
Write-Host "Artifacts (if any) in: $out"
Get-ChildItem $out -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("  " + $_.Name + "  (" + $_.Length + " bytes)") }

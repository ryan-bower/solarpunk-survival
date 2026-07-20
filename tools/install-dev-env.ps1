# Install UE4SS + this mod into a Solarpunk install. Idempotent - re-run to update the mod.
# Usage:  powershell -File tools/install-dev-env.ps1 [-GameWin64 <path>]
param(
  [string]$GameWin64 = 'C:\Program Files (x86)\Steam\steamapps\common\Solarpunk\Solarpunk\Binaries\Win64',
  [string]$Ue4ssUrl  = 'https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental-latest/UE4SS_v3.0.1-1012-gc838a8ac.zip'
)
$ErrorActionPreference = 'Stop'
$repo   = Split-Path -Parent $PSScriptRoot
$modSrc = Join-Path $repo 'mod\SolarpunkSurvival'

if (-not (Test-Path (Join-Path $GameWin64 'SolarpunkSteam-Win64-Shipping.exe'))) {
  throw ("Game exe not found under " + $GameWin64 + " - pass -GameWin64 with the path to Binaries\Win64")
}

# 1) Download + extract UE4SS (skip if already installed)
if (-not (Test-Path (Join-Path $GameWin64 'dwmapi.dll'))) {
  $tmp = Join-Path $env:TEMP ('ue4ss_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp 'ue4ss.zip'
  Write-Host "Downloading UE4SS..."
  Invoke-WebRequest -Uri $Ue4ssUrl -OutFile $zip -UseBasicParsing -Headers @{ 'User-Agent' = 'sps' }
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  Copy-Item (Join-Path $tmp 'dwmapi.dll') $GameWin64 -Force
  Copy-Item (Join-Path $tmp 'ue4ss') $GameWin64 -Recurse -Force
  Write-Host "UE4SS installed."
} else {
  Write-Host "UE4SS already present - leaving core files in place."
}

$ue4ss = Join-Path $GameWin64 'ue4ss'

# 2) Enable the UE4SS console (so logs/output are visible)
$ini = Join-Path $ue4ss 'UE4SS-settings.ini'
if (Test-Path $ini) {
  $txt = Get-Content $ini -Raw
  $txt = $txt -replace '(?m)^ConsoleEnabled\s*=.*$',    'ConsoleEnabled = 1'
  $txt = $txt -replace '(?m)^GuiConsoleEnabled\s*=.*$', 'GuiConsoleEnabled = 1'
  $txt = $txt -replace '(?m)^GuiConsoleVisible\s*=.*$', 'GuiConsoleVisible = 1'
  # Game is Unreal Engine 5.7.1; UE4SS cannot auto-detect it, so override + allow a longer AOB scan.
  $txt = $txt -replace '(?m)^MajorVersion\s*=.*$', 'MajorVersion = 5'
  $txt = $txt -replace '(?m)^MinorVersion\s*=.*$', 'MinorVersion = 7'
  $txt = $txt -replace '(?m)^SecondsToScanBeforeGivingUp\s*=.*$', 'SecondsToScanBeforeGivingUp = 120'
  Set-Content -Path $ini -Value $txt -Encoding ascii
  Write-Host "Enabled UE4SS console + set engine version override 5.7."
}

# 3) Copy the mod into UE4SS Mods (mirror, dropping any stale local save)
$modDst = Join-Path $ue4ss 'Mods\SolarpunkSurvival'
New-Item -ItemType Directory -Force -Path $modDst | Out-Null
Copy-Item (Join-Path $modSrc '*') $modDst -Recurse -Force
$stale = Join-Path $modDst 'save\state.json'
if (Test-Path $stale) { Remove-Item $stale -Force }
Write-Host ("Copied mod -> " + $modDst)

# 4) Ensure the mod is enabled in Mods/mods.txt
$modsTxt = Join-Path $ue4ss 'Mods\mods.txt'
if (Test-Path $modsTxt) {
  $lines = Get-Content $modsTxt
  if (-not ($lines -match '^\s*SolarpunkSurvival\s*:')) {
    $out = @()
    $inserted = $false
    foreach ($l in $lines) {
      if (-not $inserted -and $l -match '^\s*Keybinds\s*:') { $out += 'SolarpunkSurvival : 1'; $inserted = $true }
      $out += $l
    }
    if (-not $inserted) { $out += 'SolarpunkSurvival : 1' }
    Set-Content -Path $modsTxt -Value $out -Encoding ascii
    Write-Host "Enabled SolarpunkSurvival in mods.txt"
  } else {
    Write-Host "SolarpunkSurvival already enabled in mods.txt"
  }
}

Write-Host ""
Write-Host "Done. Launch Solarpunk; the UE4SS console should open and log 'SolarpunkSurvival vX starting'."
Write-Host ("To uninstall UE4SS: delete dwmapi.dll and the ue4ss folder from " + $GameWin64)

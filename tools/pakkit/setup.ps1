# One-time bootstrap for the content-pak toolchain (only needed if you BUILD the pak; players
# never run this). Fetches or builds everything build_wand_pak.py needs:
#
#   Python / .NET SDK / Lua / git  ->  winget
#   retoc.exe                      ->  GitHub release
#   UAssetAPI/                     ->  git clone
#   wandsmith.exe                  ->  dotnet build
#   legacy/                        ->  retoc to-legacy of the game's own paks (~2 GB, several minutes)
#
# The one thing it cannot fetch is Solarpunk.usmap - that is dumped from the RUNNING game (see
# HOWTO.md); you are told about it at the end if it is missing.
#
# Usage:  powershell -ExecutionPolicy Bypass -File tools/pakkit/setup.ps1 [-GamePaks <path>] [-SkipLegacy]
[CmdletBinding()]
param(
  [string]$GamePaks,
  [switch]$SkipLegacy
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$RETOC_URL = 'https://github.com/trumank/retoc/releases/download/v0.1.5/retoc_cli-x86_64-pc-windows-msvc.zip'

function Step([string]$m) { Write-Host "  $m" }
function Warn([string]$m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host ''; Write-Host $m -ForegroundColor Red; exit 1 }

function Have([string]$exe) { return [bool](Get-Command $exe -ErrorAction SilentlyContinue) }

function Ensure-Winget([string]$exe, [string]$id, [string]$label) {
  if (Have $exe) { Step "$label present"; return }
  if (-not (Have 'winget')) { Warn "$label missing and winget is unavailable - install $label manually"; return }
  Step "installing $label ($id)..."
  winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null
  # winget puts things on PATH for NEW shells; refresh this one so the rest of the script sees them.
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
  if (Have $exe) { Step "$label installed" } else { Warn "$label installed but not on PATH yet - reopen the shell and re-run" }
}

Write-Host 'pakkit setup'

# --- 1. toolchain from winget --------------------------------------------------------------
Ensure-Winget 'git'    'Git.Git'                'git'
Ensure-Winget 'python' 'Python.Python.3.12'     'Python 3.12'
Ensure-Winget 'dotnet' 'Microsoft.DotNet.SDK.10' '.NET 10 SDK'
Ensure-Winget 'lua'    'DEVCOM.Lua'             'Lua 5.4 (for tests/spec.lua)'

# --- 2. retoc.exe --------------------------------------------------------------------------
$retoc = Join-Path $here 'retoc.exe'
if (Test-Path $retoc) {
  Step 'retoc.exe present'
} else {
  Step 'downloading retoc...'
  $tmp = Join-Path $env:TEMP ('retoc_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp 'retoc.zip'
    Invoke-WebRequest -Uri $RETOC_URL -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    # the release zip has carried both retoc.exe and retoc_cli.exe over its life
    $exe = Get-ChildItem $tmp -Recurse -Filter 'retoc*.exe' | Select-Object -First 1
    if (-not $exe) { Fail "No retoc executable inside $RETOC_URL - grab it manually from https://github.com/trumank/retoc/releases" }
    Copy-Item $exe.FullName $retoc -Force
    Step 'retoc.exe installed'
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- 3. UAssetAPI + wandsmith --------------------------------------------------------------
$uapi = Join-Path $here 'UAssetAPI'
if (Test-Path (Join-Path $uapi 'UAssetAPI\UAssetAPI.csproj')) {
  Step 'UAssetAPI present'
} elseif (Have 'git') {
  Step 'cloning UAssetAPI...'
  git clone --depth 1 https://github.com/atenfyr/UAssetAPI $uapi
} else {
  Warn 'UAssetAPI missing and git is unavailable - clone https://github.com/atenfyr/UAssetAPI into tools/pakkit/UAssetAPI'
}

$ws = Join-Path $here 'wandsmith\bin\Release\net10.0\wandsmith.exe'
if (Have 'dotnet') {
  Step 'building wandsmith...'
  dotnet build -c Release (Join-Path $here 'wandsmith') --nologo -v quiet
  if (Test-Path $ws) { Step 'wandsmith built' } else { Warn 'wandsmith did not build - see the dotnet output above' }
} else {
  Warn 'no dotnet on PATH - cannot build wandsmith'
}

# --- 4. legacy/ : the game's own assets, extracted -----------------------------------------
$legacy = Join-Path $here 'legacy'
if ($SkipLegacy) {
  Step 'skipped the legacy/ extraction (-SkipLegacy)'
} elseif (Test-Path (Join-Path $legacy 'Solarpunk')) {
  Step 'legacy/ present'
} else {
  if (-not $GamePaks) {
    # same detection as install.ps1, just for the Paks folder
    $steam = @()
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
      try { $steam += (Get-ItemProperty -Path $k -ErrorAction Stop).SteamPath } catch {}
    }
    $steam += 'C:\Program Files (x86)\Steam'
    $libs = @()
    foreach ($s in ($steam | Where-Object { $_ } | Select-Object -Unique)) {
      $s = $s -replace '/', '\'
      $libs += $s
      $vdf = Join-Path $s 'steamapps\libraryfolders.vdf'
      if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
          $libs += $m.Groups[1].Value -replace '\\\\', '\'
        }
      }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
      $c = Join-Path $l 'steamapps\common\Solarpunk\Solarpunk\Content\Paks'
      if (Test-Path (Join-Path $c 'Solarpunk-Windows_0_P.utoc')) { $GamePaks = $c; break }
    }
  }
  if (-not $GamePaks) {
    Warn 'could not find the game Paks folder - re-run with -GamePaks "<game>\Content\Paks"'
  } else {
    Step "extracting the game's assets from $GamePaks (~2 GB, several minutes)..."
    & $retoc to-legacy $GamePaks $legacy
    if ($LASTEXITCODE -ne 0) { Fail 'retoc to-legacy failed' }
    Step 'legacy/ extracted'
  }
}

# --- 5. the one manual piece ---------------------------------------------------------------
Write-Host ''
if (Test-Path (Join-Path $here 'Solarpunk.usmap')) {
  Write-Host 'Ready:  python tools/pakkit/build_wand_pak.py'
} else {
  Warn 'Solarpunk.usmap is missing - it is dumped from the RUNNING game, so it cannot be fetched here.'
  Warn 'See the "Prerequisites" section of tools/pakkit/HOWTO.md (LoadAsset the item framework,'
  Warn 'then DumpUSMAP() over the mod remote channel), and drop the result here as Solarpunk.usmap.'
}

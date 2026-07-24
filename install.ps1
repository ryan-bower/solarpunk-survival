# Solarpunk Survival - one-command installer.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# Finds your Solarpunk install, puts UE4SS next to the game exe, copies the Lua mod into
# UE4SS's Mods folder and the content pak into Content/Paks. Idempotent - re-run any time to
# update the mod after a `git pull` (or to install a newer release zip over an older one).
#
# Works both from a clone of the repo and from an extracted release zip.
#
# Everything the mod needs at runtime is handled here: the VC++ 2015-2022 runtime UE4SS links
# against, UE4SS itself, the Lua mod and the content pak. The only piece that cannot be fetched
# automatically is the Solarpunk-patched UE4SS zip (Nexus requires a login) - drop it in your
# Downloads folder or beside this script and it is picked up.
#
#   -GameDir <path>   skip auto-detection (pass the Solarpunk folder, or its Binaries\Win64)
#   -Ue4ssZip <path>  the Solarpunk-patched UE4SS zip; else auto-found beside this script / in Downloads
#   -SkipPak          don't touch Content/Paks (Lua mod only - no wands, no codex)
#   -SkipVcRedist     don't check for / install the Visual C++ runtime
#   -Force            reinstall the UE4SS core even if it is already there
#   -Uninstall        remove the mod + content pak (leaves UE4SS in place)
[CmdletBinding()]
param(
  [string]$GameDir,
  [string]$Ue4ssZip,
  [switch]$SkipPak,
  [switch]$SkipVcRedist,
  [switch]$Force,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$EXE  = 'SolarpunkSteam-Win64-Shipping.exe'
$PAK  = 'Solarpunk-Windows_1_P'   # mount order 204 - ABOVE the game's own _0_P (104). See docs/INSTALL.md.

function Say([string]$m) { Write-Host $m }
function Step([string]$m) { Write-Host "  $m" }
function Warn([string]$m) { Write-Host "  ! $m" -ForegroundColor Yellow }
# Plain, stack-trace-free errors: this script is run by players, not by developers.
function Fail([string]$m) { Write-Host ''; Write-Host $m -ForegroundColor Red; exit 1 }

# --- locate the game -----------------------------------------------------------------------
# Returns the folder that holds Binaries\ and Content\ (...\steamapps\common\Solarpunk\Solarpunk).
function Resolve-GameDir([string]$d) {
  if (-not $d) { return $null }
  $d = $d.TrimEnd('\', '/')
  if (-not (Test-Path $d)) { return $null }
  foreach ($c in @($d, (Join-Path $d 'Solarpunk'), (Split-Path -Parent (Split-Path -Parent $d)))) {
    if ($c -and (Test-Path (Join-Path $c "Binaries\Win64\$EXE"))) { return (Resolve-Path $c).Path }
  }
  return $null
}

function Find-GameDir {
  $steam = @()
  foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
    try {
      $p = Get-ItemProperty -Path $k -ErrorAction Stop
      foreach ($v in @($p.SteamPath, $p.InstallPath)) { if ($v) { $steam += $v } }
    } catch {}
  }
  $steam += 'C:\Program Files (x86)\Steam'

  $libs = @()
  foreach ($s in ($steam | Select-Object -Unique)) {
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
    $hit = Resolve-GameDir (Join-Path $l 'steamapps\common\Solarpunk')
    if ($hit) { return $hit }
  }
  return $null
}

$game = $null
if ($GameDir) {
  $game = Resolve-GameDir $GameDir
  if (-not $game) { Fail "No $EXE under '$GameDir'. Pass -GameDir with the folder that contains Binaries\Win64." }
} else {
  $game = Find-GameDir
  if (-not $game) {
    Fail 'Could not find Solarpunk automatically. Re-run with -GameDir "<...\steamapps\common\Solarpunk\Solarpunk>"'
  }
}
$win64  = Join-Path $game 'Binaries\Win64'
$paks   = Join-Path $game 'Content\Paks'
$ue4ss  = Join-Path $win64 'ue4ss'
$modDst = Join-Path $ue4ss 'Mods\SolarpunkSurvival'
Say "Game:  $game"

# The game ships its own .pdb next to the exe, which is how UE4SS resolves symbols on this build.
# Verifying game files in Steam restores it if something stripped it.
if (-not (Test-Path (Join-Path $win64 ([IO.Path]::ChangeExtension($EXE, 'pdb'))))) {
  Warn "$([IO.Path]::ChangeExtension($EXE, 'pdb')) is missing from Binaries\Win64 - UE4SS may fail to"
  Warn 'resolve symbols. Steam > Solarpunk > Properties > Installed Files > Verify integrity.'
}

# The game holds its paks and dwmapi.dll open - nothing below can be replaced while it runs.
# Scoped to THIS install: Steam runs the game at higher integrity, so Path can come back empty -
# an unreadable path is treated as a match rather than risking a half-written pak.
foreach ($p in @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($EXE)) -ErrorAction SilentlyContinue)) {
  $path = $null
  try { $path = $p.Path } catch {}
  if ((-not $path) -or $path.StartsWith($win64, [StringComparison]::OrdinalIgnoreCase)) {
    Fail 'Solarpunk is running - quit the game first (its pak/DLL files are locked while it runs).'
  }
}

# --- uninstall -----------------------------------------------------------------------------
if ($Uninstall) {
  if (Test-Path $modDst) { Remove-Item $modDst -Recurse -Force; Step "removed $modDst" }
  foreach ($ext in @('.utoc', '.ucas', '.pak')) {
    $f = Join-Path $paks ($PAK + $ext)
    if (Test-Path $f) { Remove-Item $f -Force; Step "removed $f" }
  }
  Say ''
  Say 'Mod removed. UE4SS itself was left in place (other mods may use it);'
  Say "to remove it too, delete dwmapi.dll and the ue4ss folder from $win64"
  return
}

# --- 1. Visual C++ 2015-2022 x64 runtime (UE4SS links against it) --------------------------
if (-not $SkipVcRedist) {
  $haveVc = $false
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64')) {
    try { if ((Get-ItemProperty -Path $k -ErrorAction Stop).Installed -eq 1) { $haveVc = $true } } catch {}
  }
  if (-not $haveVc) { $haveVc = Test-Path (Join-Path $env:SystemRoot 'System32\vcruntime140_1.dll') }

  if ($haveVc) {
    Step 'Visual C++ runtime present'
  } else {
    $vc = Join-Path $env:TEMP 'vc_redist.x64.exe'
    try {
      Step 'installing the Visual C++ 2015-2022 x64 runtime (accept the UAC prompt)...'
      Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vc_redist.x64.exe' -OutFile $vc -UseBasicParsing
      $p = Start-Process -FilePath $vc -ArgumentList '/install', '/quiet', '/norestart' -Verb RunAs -Wait -PassThru
      # 3010 = installed, reboot pending. 1638 = a newer version is already there.
      if (@(0, 3010, 1638) -contains $p.ExitCode) { Step 'Visual C++ runtime installed' }
      else { Warn "vc_redist returned $($p.ExitCode) - if UE4SS fails to load, install it manually from https://aka.ms/vs/17/release/vc_redist.x64.exe" }
    } catch {
      Warn 'could not install the Visual C++ runtime automatically'
      Warn 'if UE4SS fails to load, install it from https://aka.ms/vs/17/release/vc_redist.x64.exe'
    } finally {
      Remove-Item $vc -Force -ErrorAction SilentlyContinue
    }
  }
}

# --- 2. UE4SS core -------------------------------------------------------------------------
# Stock UE4SS cannot scan this game's UE 5.7.1 build - the Solarpunk-patched zip is required.
# Look beside the script first, then wherever a browser would have dropped it.
if (-not $Ue4ssZip) {
  $hunt = @($root, (Join-Path $env:USERPROFILE 'Downloads'), (Join-Path $env:USERPROFILE 'Desktop'))
  foreach ($d in $hunt) {
    if (-not (Test-Path $d)) { continue }
    $found = Get-ChildItem -Path $d -Filter 'UE4SS*.zip' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($found) { $Ue4ssZip = $found.FullName; break }
  }
}
$haveUe4ss = Test-Path (Join-Path $win64 'dwmapi.dll')

if ($Ue4ssZip -and ((-not $haveUe4ss) -or $Force)) {
  if (-not (Test-Path $Ue4ssZip)) { Fail "UE4SS zip not found: $Ue4ssZip" }
  $tmp = Join-Path $env:TEMP ('ue4ss_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    Expand-Archive -LiteralPath $Ue4ssZip -DestinationPath $tmp -Force
    $dll = Get-ChildItem $tmp -Recurse -Filter 'dwmapi.dll' | Select-Object -First 1
    if (-not $dll) { Fail "No dwmapi.dll inside $Ue4ssZip - is that the UE4SS zip?" }
    Copy-Item $dll.FullName $win64 -Force
    Copy-Item (Join-Path $dll.Directory.FullName 'ue4ss') $win64 -Recurse -Force
    Step ("installed UE4SS from " + (Split-Path -Leaf $Ue4ssZip))
  } finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
} elseif ($haveUe4ss) {
  Step 'UE4SS already installed (-Force to reinstall)'
} else {
  Fail ("UE4SS is missing and no UE4SS*.zip was found beside this script.`n`n" +
         "Download the Solarpunk-patched UE4SS (stock UE4SS cannot scan this game's engine build):`n" +
         "    https://www.nexusmods.com/solarpunk/mods/4   ->  UE4SS-SP-Developer.zip`n" +
         "Drop the zip next to install.ps1 and re-run, or pass -Ue4ssZip with its path.")
}

# --- 3. UE4SS settings: dev console windows OFF, engine version pinned ---------------------
# UE4SS cannot auto-detect 5.7, and the AOB scan needs longer than the stock budget on this game.
# The console windows are dev tools (extra windows next to the game) - everything they show also
# lands in ue4ss\UE4SS.log, so keep them off; flip to 1 by hand if you want them for debugging.
$ini = Join-Path $ue4ss 'UE4SS-settings.ini'
if (Test-Path $ini) {
  $txt = Get-Content $ini -Raw
  $txt = $txt -replace '(?m)^ConsoleEnabled\s*=.*$',              'ConsoleEnabled = 0'
  $txt = $txt -replace '(?m)^GuiConsoleEnabled\s*=.*$',           'GuiConsoleEnabled = 0'
  $txt = $txt -replace '(?m)^GuiConsoleVisible\s*=.*$',           'GuiConsoleVisible = 0'
  $txt = $txt -replace '(?m)^MajorVersion\s*=.*$',                'MajorVersion = 5'
  $txt = $txt -replace '(?m)^MinorVersion\s*=.*$',                'MinorVersion = 7'
  $txt = $txt -replace '(?m)^SecondsToScanBeforeGivingUp\s*=.*$', 'SecondsToScanBeforeGivingUp = 120'
  Set-Content -Path $ini -Value $txt -Encoding ascii
  Step 'UE4SS console windows off, engine version pinned to 5.7'
}

# --- 4. the Lua mod ------------------------------------------------------------------------
# repo layout first, then the release-zip layout.
$modSrc = @(
  (Join-Path $root 'mod\SolarpunkSurvival'),
  (Join-Path $root 'ue4ss\Mods\SolarpunkSurvival'),
  (Join-Path $root 'SolarpunkSurvival')
) | Where-Object { Test-Path (Join-Path $_ 'Scripts\main.lua') } | Select-Object -First 1
if (-not $modSrc) { Fail "Could not find the mod source (Scripts\main.lua) under $root" }

New-Item -ItemType Directory -Force -Path $modDst | Out-Null
Copy-Item (Join-Path $modSrc '*') $modDst -Recurse -Force
# dev/recapture.lua writes RE dumps here with io.open, which will not create the directory itself.
New-Item -ItemType Directory -Force -Path (Join-Path $modDst 'dump') | Out-Null
Step "copied the mod -> $modDst"

# enabled.txt (shipped inside the mod folder) is what actually enables it; the mods.txt line is
# belt-and-braces for UE4SS builds that only read the list.
$modsTxt = Join-Path $ue4ss 'Mods\mods.txt'
if ((Test-Path $modsTxt) -and -not (Select-String -Path $modsTxt -Pattern '^\s*SolarpunkSurvival\s*:' -Quiet)) {
  $out = @()
  $done = $false
  foreach ($l in @(Get-Content $modsTxt)) {
    if (-not $done -and $l -match '^\s*Keybinds\s*:') { $out += 'SolarpunkSurvival : 1'; $done = $true }
    $out += $l
  }
  if (-not $done) { $out += 'SolarpunkSurvival : 1' }
  Set-Content -Path $modsTxt -Value $out -Encoding ascii
  Step 'enabled SolarpunkSurvival in mods.txt'
}

# --- 5. the content pak (wands, Tempest Codex, research card) ------------------------------
if ($SkipPak) {
  Step 'skipped the content pak (-SkipPak) - no wand/codex items'
} else {
  $triple = $null
  foreach ($cand in @(
    (Join-Path $root ('paks\' + $PAK)),
    (Join-Path $root 'paks\z_SolarpunkWand_P'),
    (Join-Path $root 'tools\pakkit\out\z_SolarpunkWand_P')
  )) {
    if ((Test-Path ($cand + '.utoc')) -and (Test-Path ($cand + '.ucas')) -and (Test-Path ($cand + '.pak'))) {
      $triple = $cand
      break
    }
  }
  if ($triple) {
    New-Item -ItemType Directory -Force -Path $paks | Out-Null
    foreach ($ext in @('.utoc', '.ucas', '.pak')) {
      Copy-Item ($triple + $ext) (Join-Path $paks ($PAK + $ext)) -Force
    }
    Step "installed the content pak -> $paks\$PAK.*"
  } else {
    # Game-derived cooked data, so it is not committed to the public repo: it ships in the
    # release zip, or you build it yourself from an extracted copy of the game's own assets.
    Warn 'no content pak found - the Tempest Codex, the wands and the research card will be missing'
    Warn 'get it from the release zip (paks\), or build it: python tools/pakkit/build_wand_pak.py'
  }
}

Say ''
Say 'Done. Launch Solarpunk - Binaries\Win64\ue4ss\UE4SS.log should log'
Say '"SolarpunkSurvival v0.1.0 starting". Every player in a co-op session needs this same install.'

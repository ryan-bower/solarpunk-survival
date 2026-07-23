# Assemble a release zip: install.ps1 + the UE4SS Lua mod + the content pak, laid out so a player
# unzips it, runs install.ps1, and is done.
# Usage:  powershell -File tools/package.ps1   (run from anywhere)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
$version = $manifest.modVersion
$name = "SolarpunkSurvival-v$version"
$PAK = 'Solarpunk-Windows_1_P'

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# 1) the installer - the only thing a player has to run
Copy-Item (Join-Path $root 'install.ps1') $stage -Force

# 2) UE4SS Lua mod (install.ps1 reads this layout as well as the repo's mod\ layout)
$modDst = Join-Path $stage 'ue4ss\Mods\SolarpunkSurvival'
New-Item -ItemType Directory -Force -Path $modDst | Out-Null
Copy-Item (Join-Path $root 'mod\SolarpunkSurvival\*') $modDst -Recurse -Force
# don't ship local saves
Get-ChildItem (Join-Path $modDst 'save') -Filter 'state.json' -ErrorAction SilentlyContinue | Remove-Item -Force

# 3) the content pak, pre-named to its final mount-order name
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
  $paksDst = Join-Path $stage 'paks'
  New-Item -ItemType Directory -Force -Path $paksDst | Out-Null
  foreach ($ext in @('.utoc', '.ucas', '.pak')) {
    Copy-Item ($triple + $ext) (Join-Path $paksDst ($PAK + $ext)) -Force
  }
  Write-Host "Content pak: $triple.*"
} else {
  Write-Warning 'No content pak found - the zip will install the Lua mod only (no wands, no codex).'
  Write-Warning 'Build one first: python tools/pakkit/build_wand_pak.py'
}

# 4) Docs
Copy-Item (Join-Path $root 'README.md') (Join-Path $stage 'README.txt') -Force
Copy-Item (Join-Path $root 'docs\INSTALL.md') (Join-Path $stage 'INSTALL.txt') -Force

# 5) Zip
$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Write-Host "Packaged -> $zip"
Write-Host "Tested game build(s): $($manifest.testedGameBuilds -join ', ')"
Write-Host 'Players unzip it, drop the Solarpunk-patched UE4SS zip in beside install.ps1, and run install.ps1.'

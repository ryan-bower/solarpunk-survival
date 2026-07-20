# Assemble a release zip: the UE4SS Lua mod + any cooked paks, laid out for a drop-in install.
# Usage:  pwsh tools/package.ps1   (run from the repo root)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content (Join-Path $root 'manifest.json') -Raw | ConvertFrom-Json
$version = $manifest.modVersion
$name = "SolarpunkSurvival-v$version"

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

# 1) UE4SS Lua mod
$modDst = Join-Path $stage 'ue4ss\Mods\SolarpunkSurvival'
New-Item -ItemType Directory -Force -Path $modDst | Out-Null
Copy-Item (Join-Path $root 'mod\SolarpunkSurvival\*') $modDst -Recurse -Force
# don't ship local saves
Get-ChildItem (Join-Path $modDst 'save') -Filter 'state.json' -ErrorAction SilentlyContinue | Remove-Item -Force

# 2) Cooked paks (if built)
$logic = Join-Path $root 'paks\logicmods'
if (Test-Path $logic) {
  $paksDst = Join-Path $stage 'Content\Paks\LogicMods'
  New-Item -ItemType Directory -Force -Path $paksDst | Out-Null
  Get-ChildItem $logic -Filter '*.pak' -ErrorAction SilentlyContinue | Copy-Item -Destination $paksDst -Force
}
$content = Join-Path $root 'paks\content'
if (Test-Path $content) {
  $cDst = Join-Path $stage 'Content\Paks\~mods'
  New-Item -ItemType Directory -Force -Path $cDst | Out-Null
  Get-ChildItem $content -Filter '*.pak' -ErrorAction SilentlyContinue | Copy-Item -Destination $cDst -Force
}

# 3) Docs
Copy-Item (Join-Path $root 'README.md') (Join-Path $stage 'README.txt') -Force
Copy-Item (Join-Path $root 'docs\INSTALL.md') (Join-Path $stage 'INSTALL.txt') -Force

# 4) Zip
$zip = Join-Path $dist "$name.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
Write-Host "Packaged -> $zip"
Write-Host "Tested game build(s): $($manifest.testedGameBuilds -join ', ')"

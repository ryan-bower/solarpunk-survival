#!/usr/bin/env bash
# Solarpunk Survival - one-command installer for Linux / Steam Deck (Proton).
#
#   bash install.sh
#
# The Proton counterpart to install.ps1. Solarpunk ships a Windows build only, so on Linux it runs
# under Proton; this mod injects into that same Windows process inside the Wine prefix. This script
# does everything the FILESYSTEM can do automatically - find the game via Steam's libraryfolders.vdf,
# put UE4SS next to the game exe with the right engine-version settings, copy the Lua mod into
# UE4SS's Mods folder and the content pak into Content/Paks - then prints the two Steam-side steps it
# cannot do for you (the dwmapi launch override, and the MSVC runtime via protontricks).
#
# Idempotent - re-run any time to update the mod after a `git pull` (or to install a newer release
# zip over an older one). Works from a clone of the repo or from an extracted release zip.
#
# The one piece that cannot be fetched automatically is the Solarpunk-patched UE4SS zip (Nexus needs
# a login) - drop it in ~/Downloads or beside this script and it is picked up.
#
#   --game-dir <path>   skip auto-detection (the Solarpunk folder, or its Binaries/Win64)
#   --ue4ss-zip <path>  the Solarpunk-patched UE4SS zip; else auto-found beside this script / ~/Downloads
#   --skip-pak          don't touch Content/Paks (Lua mod only - no wands, no codex)
#   --vcrun             also run `protontricks <appid> vcrun2022` now (needs the prefix to exist)
#   --force             reinstall the UE4SS core even if it is already there
#   --uninstall         remove the mod + content pak (leaves UE4SS in place)
#   -h, --help          this help

EXE="SolarpunkSteam-Win64-Shipping.exe"
PAK="Solarpunk-Windows_1_P"   # mount order 204 - ABOVE the game's own _0_P (104). See docs/INSTALL.md.
APPID="1805110"               # Solarpunk's Steam app id (the Proton prefix lives under compatdata/<appid>)

GAME_DIR=""; UE4SS_ZIP=""; SKIP_PAK=0; RUN_VCRUN=0; FORCE=0; UNINSTALL=0

# Plain, stack-trace-free output: this script is run by players, not developers.
say()  { printf '%s\n'   "$*"; }
step() { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
fail() { printf '\n%b\n' "$*" >&2; exit 1; }

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --game-dir)  GAME_DIR="${2:?--game-dir needs a path}"; shift 2 ;;
    --ue4ss-zip) UE4SS_ZIP="${2:?--ue4ss-zip needs a path}"; shift 2 ;;
    --skip-pak)  SKIP_PAK=1; shift ;;
    --vcrun)     RUN_VCRUN=1; shift ;;
    --force)     FORCE=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) fail "unknown argument: $1 (see --help)" ;;
  esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"

# --- locate the game -----------------------------------------------------------------------
# Echo the folder that holds Binaries/ and Content/ (...steamapps/common/Solarpunk/Solarpunk).
resolve_game_dir() {
  local d="${1%/}" c
  [ -n "$d" ] && [ -e "$d" ] || return 1
  for c in "$d" "$d/Solarpunk" "$(dirname "$(dirname "$d")")"; do
    if [ -f "$c/Binaries/Win64/$EXE" ]; then (cd "$c" && pwd); return 0; fi
  done
  return 1
}

# Steam roots across native, older, and Flatpak layouts.
steam_roots() {
  local r
  for r in "$HOME/.steam/steam" "$HOME/.steam/root" "$HOME/.local/share/Steam" \
           "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
    [ -d "$r" ] && printf '%s\n' "$r"
  done
}

# Every steamapps/ dir: each root's own, the extra libraries in libraryfolders.vdf, and Deck SD cards.
library_dirs() {
  local root vdf p m
  while IFS= read -r root; do
    printf '%s\n' "$root/steamapps"
    vdf="$root/steamapps/libraryfolders.vdf"
    if [ -f "$vdf" ]; then
      grep -oE '"path"[[:space:]]+"[^"]+"' "$vdf" 2>/dev/null \
        | sed -E 's/.*"path"[[:space:]]+"([^"]+)".*/\1/; s/\\\\/\//g' \
        | while IFS= read -r p; do [ -n "$p" ] && printf '%s\n' "$p/steamapps"; done
    fi
  done < <(steam_roots)
  for m in /run/media/*/*/steamapps /run/media/mmcblk0p1/steamapps; do
    [ -d "$m" ] && printf '%s\n' "$m"
  done
}

# Unique steamapps dirs, order-preserving.
uniq_libs() { library_dirs | awk 'NF && !seen[$0]++'; }

find_game_dir() {
  local sa hit
  while IFS= read -r sa; do
    if hit="$(resolve_game_dir "$sa/common/Solarpunk")"; then printf '%s\n' "$hit"; return 0; fi
  done < <(uniq_libs)
  return 1
}

if [ -n "$GAME_DIR" ]; then
  GAME="$(resolve_game_dir "$GAME_DIR")" \
    || fail "No $EXE under '$GAME_DIR'.\nPass --game-dir with the folder that contains Binaries/Win64."
else
  GAME="$(find_game_dir)" \
    || fail "Could not find Solarpunk automatically.\nRe-run with --game-dir <.../steamapps/common/Solarpunk/Solarpunk>"
fi
WIN64="$GAME/Binaries/Win64"
PAKS="$GAME/Content/Paks"
UE4SS_DIR="$WIN64/ue4ss"
MOD_DST="$UE4SS_DIR/Mods/SolarpunkSurvival"
say "Game:  $GAME"

# The game ships its own .pdb next to the exe, which is how UE4SS resolves symbols on this build.
if [ ! -f "$WIN64/${EXE%.exe}.pdb" ]; then
  warn "${EXE%.exe}.pdb is missing from Binaries/Win64 - UE4SS may fail to resolve symbols."
  warn "Steam > Solarpunk > Properties > Installed Files > Verify integrity."
fi

# Nothing below can replace the DLL/paks while the game holds them open.
if pgrep -f "$EXE" >/dev/null 2>&1; then
  fail "Solarpunk appears to be running - quit the game first (its pak/DLL files are locked while it runs)."
fi

# --- uninstall -----------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  [ -d "$MOD_DST" ] && { rm -rf "$MOD_DST"; step "removed $MOD_DST"; }
  for ext in utoc ucas pak; do
    f="$PAKS/$PAK.$ext"; [ -f "$f" ] && { rm -f "$f"; step "removed $f"; }
  done
  say ""
  say "Mod removed. UE4SS itself was left in place (other mods may use it);"
  say "to remove it too, delete dwmapi.dll and the ue4ss/ folder from $WIN64"
  exit 0
fi

# --- 1. UE4SS core -------------------------------------------------------------------------
# Stock UE4SS cannot scan this game's UE 5.7.1 build - the Solarpunk-patched zip is required.
if [ -z "$UE4SS_ZIP" ]; then
  for d in "$ROOT" "$HOME/Downloads" "$HOME/Desktop"; do
    [ -d "$d" ] || continue
    found="$(ls -t "$d"/UE4SS*.zip 2>/dev/null | head -n1)"
    [ -n "$found" ] && { UE4SS_ZIP="$found"; break; }
  done
fi
HAVE_UE4SS=0; [ -f "$WIN64/dwmapi.dll" ] && HAVE_UE4SS=1

if [ -n "$UE4SS_ZIP" ] && { [ "$HAVE_UE4SS" = 0 ] || [ "$FORCE" = 1 ]; }; then
  [ -f "$UE4SS_ZIP" ] || fail "UE4SS zip not found: $UE4SS_ZIP"
  command -v unzip >/dev/null 2>&1 || fail "'unzip' is required to extract UE4SS.\nInstall it (e.g. sudo apt install unzip / sudo pacman -S unzip)."
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  unzip -q -o "$UE4SS_ZIP" -d "$tmp" || fail "could not extract $UE4SS_ZIP"
  dll="$(find "$tmp" -name dwmapi.dll -print -quit 2>/dev/null)"
  [ -n "$dll" ] || fail "No dwmapi.dll inside $UE4SS_ZIP - is that the UE4SS zip?"
  dlldir="$(dirname "$dll")"
  cp -f "$dll" "$WIN64/" || fail "could not copy dwmapi.dll into $WIN64"
  cp -rf "$dlldir/ue4ss" "$WIN64/" || fail "could not copy the ue4ss/ folder into $WIN64"
  step "installed UE4SS from $(basename "$UE4SS_ZIP")"
elif [ "$HAVE_UE4SS" = 1 ]; then
  step "UE4SS already installed (--force to reinstall)"
else
  fail "UE4SS is missing and no UE4SS*.zip was found beside this script.\n\nDownload the Solarpunk-patched UE4SS (stock UE4SS cannot scan this game's engine build):\n    https://www.nexusmods.com/solarpunk/mods/4   ->  UE4SS-SP-Developer.zip\nDrop the zip next to install.sh and re-run, or pass --ue4ss-zip <path>."
fi

# --- 2. UE4SS settings: console on, engine version pinned ----------------------------------
# UE4SS cannot auto-detect 5.7, and the AOB scan needs longer than the stock budget on this game.
INI="$UE4SS_DIR/UE4SS-settings.ini"
if [ -f "$INI" ]; then
  sed -i -E \
    -e 's/^ConsoleEnabled[[:space:]]*=.*$/ConsoleEnabled = 1/' \
    -e 's/^GuiConsoleEnabled[[:space:]]*=.*$/GuiConsoleEnabled = 1/' \
    -e 's/^GuiConsoleVisible[[:space:]]*=.*$/GuiConsoleVisible = 1/' \
    -e 's/^MajorVersion[[:space:]]*=.*$/MajorVersion = 5/' \
    -e 's/^MinorVersion[[:space:]]*=.*$/MinorVersion = 7/' \
    -e 's/^SecondsToScanBeforeGivingUp[[:space:]]*=.*$/SecondsToScanBeforeGivingUp = 120/' \
    "$INI"
  step "UE4SS console enabled, engine version pinned to 5.7"
fi

# --- 3. the Lua mod ------------------------------------------------------------------------
MOD_SRC=""
for c in "$ROOT/mod/SolarpunkSurvival" "$ROOT/ue4ss/Mods/SolarpunkSurvival" "$ROOT/SolarpunkSurvival"; do
  [ -f "$c/Scripts/main.lua" ] && { MOD_SRC="$c"; break; }
done
[ -n "$MOD_SRC" ] || fail "Could not find the mod source (Scripts/main.lua) under $ROOT"

mkdir -p "$MOD_DST" || fail "could not create $MOD_DST"
cp -rf "$MOD_SRC/." "$MOD_DST/" || fail "could not copy the mod into $MOD_DST"
# dev/recapture.lua writes RE dumps here with io.open, which will not create the directory itself.
mkdir -p "$MOD_DST/dump"
step "copied the mod -> $MOD_DST"

# enabled.txt (shipped inside the mod folder) is what actually enables it; the mods.txt line is
# belt-and-braces for UE4SS builds that only read the list.
MODS_TXT="$UE4SS_DIR/Mods/mods.txt"
if [ -f "$MODS_TXT" ] && ! grep -qE '^[[:space:]]*SolarpunkSurvival[[:space:]]*:' "$MODS_TXT"; then
  if grep -qE '^[[:space:]]*Keybinds[[:space:]]*:' "$MODS_TXT"; then
    sed -i -E 's|^([[:space:]]*Keybinds[[:space:]]*:.*)$|SolarpunkSurvival : 1\n\1|' "$MODS_TXT"
  else
    printf 'SolarpunkSurvival : 1\n' >> "$MODS_TXT"
  fi
  step "enabled SolarpunkSurvival in mods.txt"
fi

# --- 4. the content pak (wands, Tempest Codex, research card) ------------------------------
if [ "$SKIP_PAK" = 1 ]; then
  step "skipped the content pak (--skip-pak) - no wand/codex items"
else
  triple=""
  for cand in "$ROOT/paks/$PAK" "$ROOT/paks/z_SolarpunkWand_P" "$ROOT/tools/pakkit/out/z_SolarpunkWand_P"; do
    if [ -f "$cand.utoc" ] && [ -f "$cand.ucas" ] && [ -f "$cand.pak" ]; then triple="$cand"; break; fi
  done
  if [ -n "$triple" ]; then
    mkdir -p "$PAKS"
    for ext in utoc ucas pak; do
      cp -f "$triple.$ext" "$PAKS/$PAK.$ext" || fail "could not copy the pak into $PAKS"
    done
    step "installed the content pak -> $PAKS/$PAK.*"
  else
    # Game-derived cooked data, so it is not committed to the public repo: it ships in the
    # release zip, or you build it yourself from an extracted copy of the game's own assets.
    warn "no content pak found - the Tempest Codex, the wands and the research card will be missing"
    warn "get it from the release zip (paks/), or build it: python tools/pakkit/build_wand_pak.py"
  fi
fi

# --- 5. Proton-only bits Steam has to do, not the filesystem -------------------------------
# Locate the Proton prefix (exists only after the game has been launched once under Proton).
PFX=""
while IFS= read -r sa; do
  if [ -d "$sa/compatdata/$APPID/pfx" ]; then PFX="$sa/compatdata/$APPID/pfx"; break; fi
done < <(uniq_libs)

# Which protontricks is available (native binary or the Flatpak)?
PT=""
if command -v protontricks >/dev/null 2>&1; then PT="protontricks"
elif command -v flatpak >/dev/null 2>&1 && flatpak info com.github.Matoking.protontricks >/dev/null 2>&1; then
  PT="flatpak run com.github.Matoking.protontricks"
fi

say ""
say "Two Proton steps remain (Steam settings, not files):"
say "  1) Launch option - Steam > Solarpunk > Properties > General > Launch Options:"
say "         WINEDLLOVERRIDES=\"dwmapi=n,b\" %command%"
say "     (so Wine loads UE4SS's proxy dwmapi.dll; n,b = native first, builtin fallback)"

if [ "$RUN_VCRUN" = 1 ]; then
  if [ -z "$PFX" ]; then
    warn "2) MSVC runtime: no Proton prefix yet (compatdata/$APPID). Launch the game once, then:"
    warn "     ${PT:-protontricks} $APPID vcrun2022"
  elif [ -z "$PT" ]; then
    warn "2) MSVC runtime: protontricks not found. Install it, then run:  protontricks $APPID vcrun2022"
    warn "   (Steam Deck: flatpak install com.github.Matoking.protontricks)"
  else
    say "  2) MSVC runtime - installing vcrun2022 into the prefix via protontricks (can take a minute)..."
    if $PT "$APPID" vcrun2022; then step "vcrun2022 installed into the Proton prefix"
    else warn "protontricks failed - run it yourself: $PT $APPID vcrun2022"; fi
  fi
else
  say "  2) MSVC runtime - UE4SS links against it; install it into the prefix (re-run with --vcrun"
  say "     to do this automatically):"
  say "         ${PT:-protontricks} $APPID vcrun2022"
  [ -z "$PT" ] && say "     (no protontricks found - Steam Deck: flatpak install com.github.Matoking.protontricks)"
  [ -z "$PFX" ] && say "     (launch the game once first so Proton creates its prefix under compatdata/$APPID)"
fi

say ""
say "Done. Launch Solarpunk - the UE4SS console window should open and log"
say '"SolarpunkSurvival v0.1.0 starting". Every player in a co-op session needs this same install.'

#!/usr/bin/env bash
# Deploy the latest mod, launch Solarpunk under Proton, and confirm the mod loaded. The Linux "run
# the app" entrypoint (Claude's /run uses it via .claude/skills/launch-solarpunk).
#
#   bash tools/run.sh [--no-install] [--wait <seconds>] [--game-dir <path>]
#
# It stops any running instance (a fresh UE4SS injection needs a clean launch, and install.sh cannot
# overwrite the locked DLL/paks while the game runs), re-runs install.sh to copy in the current
# mod + pak, launches via Steam, then tails ue4ss/UE4SS.log until the mod logs
# "SolarpunkSurvival vX.Y.Z starting". Proton must already be set up (see docs/INSTALL.md:
# the dwmapi override launch option + vcrun2022).
set -u
APPID=1805110
WAIT=120
NO_INSTALL=0
GAME_DIR=""
EXE="SolarpunkSteam-Win64-Shipping.exe"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-install) NO_INSTALL=1; shift ;;
    --wait)       WAIT="${2:?--wait needs seconds}"; shift 2 ;;
    --game-dir)   GAME_DIR="${2:?--game-dir needs a path}"; shift 2 ;;
    -h|--help)    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

REPO="$(cd "$(dirname "$0")/.." && pwd)"

# 1) stop a running instance so the fresh mod injects on the next launch
if pgrep -f "$EXE" >/dev/null 2>&1; then
  echo "Stopping the running game (a clean launch is needed to inject the fresh mod)..."
  pkill -f "$EXE" 2>/dev/null || true
  sleep 4
fi

# 2) deploy the current mod + pak, and learn the exact game dir from install.sh's own detection
GAME=""
if [ "$NO_INSTALL" = 0 ]; then
  echo "Installing the latest mod..."
  install_out="$(bash "$REPO/install.sh" 2>&1)"; rc=$?
  printf '%s\n' "$install_out"
  [ "$rc" -eq 0 ] || { echo "install.sh failed (see output above)" >&2; exit 1; }
  GAME="$(printf '%s\n' "$install_out" | sed -nE 's/^Game:[[:space:]]+(.+)$/\1/p' | head -n1)"
fi
[ -n "$GAME" ] || GAME="$GAME_DIR"
if [ -z "$GAME" ]; then
  echo "Could not determine the game dir; pass --game-dir <.../steamapps/common/Solarpunk/Solarpunk>" >&2
  exit 1
fi
LOG="$GAME/Binaries/Win64/ue4ss/UE4SS.log"

# 3) launch via Steam (native binary, xdg-open, or the Flatpak Steam - whichever exists)
[ -f "$LOG" ] && rm -f "$LOG"
echo "Launching Solarpunk (app $APPID)..."
url="steam://rungameid/$APPID"
if command -v steam >/dev/null 2>&1; then steam "$url" >/dev/null 2>&1 &
elif command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
  flatpak run com.valvesoftware.Steam "$url" >/dev/null 2>&1 &
elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
else
  echo "Could not find steam / flatpak / xdg-open to launch. Start Solarpunk from Steam yourself." >&2
fi

# 4) wait for the mod's own startup line in the UE4SS log
pattern='SolarpunkSurvival v[0-9.]+ starting'
deadline=$(( $(date +%s) + WAIT ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 3
  if [ -f "$LOG" ] && grep -qE "$pattern" "$LOG" 2>/dev/null; then ready=1; break; fi
done

echo ""
if [ "$ready" = 1 ]; then
  echo "Mod loaded. Recent SolarpunkSurvival log:"
  grep -E 'SolarpunkSurvival' "$LOG" | tail -n 15 | sed 's/^/  /'
  echo ""
  echo "Load a save (the menu has no pawn, so most features need a world), then press P for a storm."
else
  echo "! Did not see \"$pattern\" within ${WAIT}s." >&2
  echo "! Check the UE4SS log at: $LOG" >&2
  echo "! If UE4SS did not inject, confirm the Proton launch option WINEDLLOVERRIDES=\"dwmapi=n,b\" %command%" >&2
  echo "! and vcrun2022 in the prefix (docs/INSTALL.md), then bash install.sh --force." >&2
  [ -f "$LOG" ] && { echo "--- last 20 lines of UE4SS.log ---"; tail -n 20 "$LOG" | sed 's/^/  /'; }
fi

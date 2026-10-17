#!/usr/bin/env bash
# Stages and shoots the "Roadster hops the lineup" demo with Liftoff.
set -euo pipefail

usage() {
  cat <<'EOF'
Stage and shoot the Liftoff demo: Calculator (the "Roadster") hops a parked lineup of
Chess and Dictionary (open on "roadster"), like Tesla's Roadster demo.

Usage:
  scripts/demo.sh dress            Save your wallpaper and Dock setting, then switch to the
                                   night-track wallpaper and an auto-hiding Dock.
  scripts/demo.sh stage            Open the cast and park it on the floor.
  scripts/demo.sh take [seconds]   Count down (default 3), then fling the Roadster.
  scripts/demo.sh shoot [file]     Stage and record ~17s at 4K60 with only the cast in shot, a
                                   simplified menu bar and a raised floor: the hop over the lineup,
                                   then a throw into the sky (default ~/Movies/liftoff-take.mov).
  scripts/demo.sh reset            Park the Roadster back at the start line.
  scripts/demo.sh strike           Restore your wallpaper and Dock setting.
  scripts/demo.sh -h | --help

Options for take and shoot (environment variables):
  LIFTOFF_FLING="vx,vy"   Throw velocity in points/s (default "-650,-2600", up and to the left).
  LIFTOFF_LAND_X=x        Aim the landing near this x (shoot aims just left of Dictionary).
  LIFTOFF_SKY_FLING, LIFTOFF_SKY_GRAB   The second beat in shoot, which lands on Chess's roof
                          (default "250,-3300" and "50,-40").
  LIFTOFF_FLOOR_LIFT=90   How far shoot raises the floor, in points.
  LIFTOFF_GRAB="dx,dy"    Grab point relative to the window's center (default "-10,-60", a little above center).
                          Grab off-center for a flip, e.g. "-60,-80".
  LIFTOFF_DRIVER=…        Optional face in a driver-cam bubble: an emoji or the path to an
                          image, like a memoji sticker saved as PNG. None by default.

Liftoff must be running with its debug hooks on:
  defaults write run.lil.liftoff debugHooks -bool true   (then relaunch Liftoff)
EOF
}

repo="$(cd "$(dirname "$0")/.." && pwd)"
demo_dir="${HOME}/Library/Caches/liftoff-demo"
wallpaper="${repo}/assets/wallpaper-night-track.png"
hero="app:Calculator"
cast=("Calculator" "Chess" "Dictionary" "Liftoff")

# Posts a distributed notification that Liftoff's debug hooks listen for.
post() {
  osascript -l JavaScript - "$1" "$2" >/dev/null <<'JS'
ObjC.import('Foundation')
function run(argv) {
  $.NSDistributedNotificationCenter.defaultCenter
    .postNotificationNameObjectUserInfoDeliverImmediately(argv[0], argv[1], $(), true)
}
JS
}

screen_width() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSScreen.screens.objectAtIndex(0).visibleFrame.size.width'
}

check_liftoff() {
  if ! pgrep -qf "Liftoff.app/Contents/MacOS/Liftoff"; then
    echo "error: Liftoff isn't running. Open Liftoff.app first." >&2
    exit 1
  fi
  if [[ "$(defaults read run.lil.liftoff debugHooks 2>/dev/null || true)" != "1" ]]; then
    echo "error: Liftoff's debug hooks are off. Run:" >&2
    echo "  defaults write run.lil.liftoff debugHooks -bool true" >&2
    echo "then quit and reopen Liftoff." >&2
    exit 1
  fi
}

desktop_picture() {
  osascript -l JavaScript - "$@" <<'JS'
ObjC.import('AppKit')
function run(argv) {
  const screen = $.NSScreen.screens.objectAtIndex(0), workspace = $.NSWorkspace.sharedWorkspace
  if (argv.length === 0) return workspace.desktopImageURLForScreen(screen).path.js
  workspace.setDesktopImageURLForScreenOptionsError($.NSURL.fileURLWithPath(argv[0]), screen, $({}), null)
}
JS
}

dress() {
  mkdir -p "$demo_dir"
  if [[ ! -f "${demo_dir}/original-wallpaper" ]]; then
    local current
    current="$(desktop_picture)"
    # macOS keeps showing a wallpaper whose file was since deleted, but it can't be set back.
    if [[ ! -f "$current" && "${1:-}" != "--force" ]]; then
      echo "error: your current wallpaper's file is missing (${current}), so 'strike' couldn't restore it." >&2
      echo "Re-pick your wallpaper in System Settings first, or run 'scripts/demo.sh dress --force'." >&2
      exit 1
    fi
    echo "$current" > "${demo_dir}/original-wallpaper"
    defaults read com.apple.dock autohide 2>/dev/null > "${demo_dir}/original-dock-autohide" || echo "missing" > "${demo_dir}/original-dock-autohide"
  fi
  desktop_picture "$wallpaper"
  defaults write com.apple.dock autohide -bool true
  killall Dock
  echo "Dressed. Run 'scripts/demo.sh strike' to put your desktop back."
}

strike() {
  if [[ ! -f "${demo_dir}/original-wallpaper" ]]; then
    echo "Nothing to restore."
    return
  fi
  local original
  original="$(cat "${demo_dir}/original-wallpaper")"
  if [[ -f "$original" ]]; then
    desktop_picture "$original"
  else
    echo "warning: ${original} no longer exists; pick your wallpaper in System Settings." >&2
  fi
  case "$(cat "${demo_dir}/original-dock-autohide")" in
    missing) defaults delete com.apple.dock autohide ;;
    1) defaults write com.apple.dock autohide -bool true ;;
    *) defaults write com.apple.dock autohide -bool false ;;
  esac
  killall Dock
  rm -f "${demo_dir}/original-wallpaper" "${demo_dir}/original-dock-autohide"
  echo "Desktop restored."
}

# Scales a size designed for a 2048pt-wide screen.
scaled() {
  awk -v v="$1" -v w="$(screen_width)" 'BEGIN { printf "%d", v * w / 2048 }'
}

park() {
  # hero|width|height|x pins the Roadster at the start line; the rest pack left to right after it.
  # Like the original video, the Roadster takes off from the right and sets down on the left.
  # Sizes are each app's minimum; x positions are from the left edge of the safe area.
  local entries=("${hero}|$(scaled 230)|$(scaled 330)|$(scaled 1714)")
  if [[ "${1:-}" == "all" ]]; then
    entries+=(
      "app:Dictionary|$(scaled 400)|$(scaled 300)|$(scaled 520)"
      "app:Chess|$(scaled 500)|$(scaled 407)|$(scaled 994)"
    )
  fi
  local joined
  joined=$(IFS=';'; echo "${entries[*]}")
  post run.lil.liftoff.lineup "$(scaled 30),${joined}"
}

stage() {
  check_liftoff
  mkdir -p "$demo_dir"
  open -a Calculator
  open -a Chess
  open "dict://roadster"
  sleep "${LIFTOFF_STAGE_WAIT:-5}"
  park all
  sleep 1
  echo "Lineup parked."
}

take() {
  check_liftoff
  local seconds="${1:-3}" fling="${LIFTOFF_FLING:--650,-2600}" grab="${LIFTOFF_GRAB:--10,-60}"
  for ((i = seconds; i > 0; i--)); do
    echo "$i…"
    sleep 1
  done
  post run.lil.liftoff.driver "${LIFTOFF_DRIVER:-}"
  if [[ -n "${LIFTOFF_LAND_X:-}" ]]; then post run.lil.liftoff.landat "$LIFTOFF_LAND_X"; fi
  post run.lil.liftoff.throw "${grab},${fling},${hero}"
  echo "Liftoff."
}

# Two beats, timed so the touchdowns land on the soundtrack's hits at 5.18s and 12.26s once cut:
# the hop over the lineup, then a throw up into the sky that comes down on Chess's roof.
shoot() {
  local file="${1:-${HOME}/Movies/liftoff-take.mov}"
  local keep
  keep=$(IFS=';'; echo "${cast[*]}")
  post run.lil.liftoff.floor "$(scaled "${LIFTOFF_FLOOR_LIFT:-90}")"
  post run.lil.liftoff.menubar on
  post run.lil.liftoff.cast "${keep%;Liftoff}"
  stage
  open "dict://roadster"  # Dictionary sometimes reopens on its last lookup
  sleep 1
  park all
  sleep 0.5

  post run.lil.liftoff.record "${file},17,${keep}"
  sleep 1.5
  # Liftoff fires the sky throw 1.2s after the first touchdown, aimed at Chess's roof, which puts the
  # second touchdown about 7.1s after the first, matching the gap between the soundtrack's two hits.
  post run.lil.liftoff.after "1.2,${LIFTOFF_SKY_GRAB:-50,-40},${LIFTOFF_SKY_FLING:-250,-3300},${hero},$(scaled 1276)"
  LIFTOFF_LAND_X="$(scaled 380)" take 0
  sleep 16

  post run.lil.liftoff.floor 0
  post run.lil.liftoff.menubar off
  post run.lil.liftoff.cast ""
  echo "Saved ${file}"
}

case "${1:-}" in
  dress) shift; dress "$@" ;;
  stage) stage ;;
  take) shift; take "$@" ;;
  shoot) shift; shoot "$@" ;;
  reset) check_liftoff; park ;;
  strike) strike ;;
  -h | --help | help | "") usage ;;
  *) echo "error: unknown command: $1" >&2; usage >&2; exit 2 ;;
esac

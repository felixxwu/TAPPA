#!/usr/bin/env bash
# Re-bless one golden: rerun its mode with --bless so it rewrites its file in goldens/ (see goldens/README.md).
# This is the only thing that writes goldens/; commit the result with a "Bless:" line saying what changed and why.
#
#   ./bless.sh car-step [rec]   # goldens/car_step.jsonl.gz      (free-run car snapshot per tick)
#   ./bless.sh events           # goldens/events.jsonl.gz        (game-state trace)
#   ./bless.sh scene-counts     # goldens/scene_counts.jsonl.gz  (world items at pinned spots)
#   ./bless.sh menus            # goldens/menus.jsonl.gz         (keyboard and gamepad menu flow)
#   ./bless.sh touch            # goldens/touch.jsonl.gz         (touch and tilt flow)
set -u

GODOT="${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}"
[[ -x "$GODOT" ]] || GODOT=/Applications/Godot.app/Contents/MacOS/Godot
cd "$(dirname "$0")"

NAME="${1:-}"
shift || true

scene() {
  local tscn=$1; shift
  [[ -f "$tscn" ]] || { echo "$tscn doesn't exist yet, so '$NAME' can't be blessed" >&2; exit 1; }
  # Same physics-thread override as run_level_replay.sh --golden-check; goldens are only written single-threaded.
  if [[ -e override.cfg ]]; then echo "override.cfg already exists; move it away first" >&2; exit 1; fi
  printf '[physics]\n3d/run_on_separate_thread=false\n' > override.cfg
  trap 'rm -f override.cfg' EXIT
  "$GODOT" --headless --fixed-fps 60 "res://$tscn" -- --golden --seed=90210 --bless "$@"
}

mkdir -p goldens
case "$NAME" in
  car-step)     ./run_level_replay.sh --car-golden "$@" --bless ;;
  events)       ./run_level_replay.sh --events-golden "$@" --bless ;;
  scene-counts) scene benchmark/scene_counts.tscn "$@" ;;
  menus)        scene benchmark/menu_flow.tscn "$@" ;;
  touch)        scene benchmark/touch_flow.tscn "$@" ;;
  *) echo "usage: ./bless.sh <car-step|events|scene-counts|menus|touch> [args]" >&2; exit 2 ;;
esac

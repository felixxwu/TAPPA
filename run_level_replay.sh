#!/usr/bin/env bash
# Record a drive through the dev level, or replay it as a render benchmark (benchmark/level_replay.gd).
#
#   ./run_level_replay.sh --record [path]   # drive it yourself; quit to save
#   ./run_level_replay.sh [path] [--until=4 | --full] [--off=DustPuffs,TireMarks]   # replay uncapped and print frame stats
set -u

GODOT="${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}"
[[ -x "$GODOT" ]] || GODOT=/Applications/Godot.app/Contents/MacOS/Godot
cd "$(dirname "$0")"

if [[ "${1:-}" == "--record" ]]; then
  exec "$GODOT" res://benchmark/level_replay.tscn -- "--record=${2:-res://benchmark/runs/hafren.rec}"
fi
PATH_ARG=res://benchmark/runs/hafren.rec
if [[ $# -gt 0 && "$1" != --* ]]; then PATH_ARG="$1"; shift; fi
exec "$GODOT" res://benchmark/level_replay.tscn -- "--replay=$PATH_ARG" "$@"

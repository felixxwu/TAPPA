#!/usr/bin/env bash
# Record a drive through the dev level, or replay it as a render benchmark (benchmark/level_replay.gd).
#
#   ./run_level_replay.sh --record [path] [--car=beast]   # drive it yourself from the spawn teleport; quit to save
#   ./run_level_replay.sh [path] [--until=4 | --full] [--off=DustPuffs,TireMarks]   # replay uncapped and print frame stats
#   ./run_level_replay.sh --golden-check [path] [--until=15]   # replay twice (the second under CPU load); fail if the per-tick traces differ
set -u

GODOT="${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}"
[[ -x "$GODOT" ]] || GODOT=/Applications/Godot.app/Contents/MacOS/Godot
cd "$(dirname "$0")"

if [[ "${1:-}" == "--record" ]]; then
  shift
  REC=res://benchmark/runs/hafren.rec
  if [[ $# -gt 0 && "$1" != --* ]]; then REC="$1"; shift; fi
  exec "$GODOT" res://benchmark/level_replay.tscn -- "--record=$REC" "$@"
fi
GOLDEN=0
if [[ "${1:-}" == "--golden-check" ]]; then GOLDEN=1; shift; fi
PATH_ARG=res://benchmark/runs/hafren.rec
if [[ $# -gt 0 && "$1" != --* ]]; then PATH_ARG="$1"; shift; fi

if [[ $GOLDEN == 1 ]]; then
  # The physics thread can't be turned off from the command line, only by an override.cfg beside project.godot.
  if [[ -e override.cfg ]]; then echo "override.cfg already exists; move it away first" >&2; exit 1; fi
  printf '[physics]\n3d/run_on_separate_thread=false\n' > override.cfg
  trap 'rm -f override.cfg; kill $(jobs -p) 2>/dev/null' EXIT
  TMP=$(mktemp -d)
  run() {
    local trace=$1; shift
    "$GODOT" --headless --fixed-fps 60 res://benchmark/level_replay.tscn -- "--replay=$PATH_ARG" --golden --seed=90210 "--trace=$trace" "$@" || {
      echo "golden replay failed (exit $?)" >&2; exit 1; }
  }
  run "$TMP/a.jsonl" "$@"
  for _ in $(seq "$(getconf _NPROCESSORS_ONLN)"); do yes >/dev/null & done  # leftover timing dependence shows up under load
  run "$TMP/b.jsonl" "$@"
  kill $(jobs -p) 2>/dev/null
  if cmp -s "$TMP/a.jsonl" "$TMP/b.jsonl"; then
    echo "golden check: traces match ($(wc -l < "$TMP/a.jsonl" | tr -d ' ') ticks)"
    exit 0
  fi
  LINE=$(cmp "$TMP/a.jsonl" "$TMP/b.jsonl" 2>&1 | sed -n 's/.*line \([0-9]*\).*/\1/p')
  echo "golden check: traces differ ($TMP/a.jsonl vs $TMP/b.jsonl)" >&2
  if [[ -n "$LINE" ]]; then
    echo "first difference at tick $((LINE - 1)):" >&2
    echo "A: $(sed -n "${LINE}p" "$TMP/a.jsonl")" >&2
    echo "B: $(sed -n "${LINE}p" "$TMP/b.jsonl")" >&2
  else
    cmp "$TMP/a.jsonl" "$TMP/b.jsonl" >&2  # one trace is a prefix of the other
  fi
  exit 1
fi
exec "$GODOT" res://benchmark/level_replay.tscn -- "--replay=$PATH_ARG" "$@"

#!/usr/bin/env bash
# Record a drive through the dev level, or replay it as a render benchmark (benchmark/level_replay.gd).
#
#   ./run_level_replay.sh --record [path] [--car=beast]   # drive it yourself from the spawn teleport; quit to save
#   ./run_level_replay.sh [path] [--until=4 | --full] [--off=DustPuffs,TireMarks]   # replay uncapped and print frame stats
#   ./run_level_replay.sh --golden-check [path] [--until=15]   # replay twice (the second under CPU load); fail if the per-tick traces or event logs differ
#   ./run_level_replay.sh --car-golden [rec] [--check | --bless]     # free-run car state per tick (goldens/car_step.jsonl.gz)
#   ./run_level_replay.sh --events-golden [rec] [--check | --bless]  # game events on the pose-fed replay (goldens/events.jsonl.gz)
# With neither --check nor --bless, a golden mode runs twice and checks the two runs match.
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
MODE=bench
case "${1:-}" in
  --golden-check) MODE=check; shift ;;
  --car-golden) MODE=car; shift ;;
  --events-golden) MODE=events; shift ;;
esac
PATH_ARG=res://benchmark/runs/hafren.rec
[[ $MODE == car ]] && PATH_ARG=""
if [[ $# -gt 0 && "$1" != --* ]]; then PATH_ARG="$1"; shift; fi
[[ $MODE == bench ]] && exec "$GODOT" res://benchmark/level_replay.tscn -- "--replay=$PATH_ARG" "$@"

ACTION=self
ARGS=()
for a in "$@"; do
  case "$a" in
    --check) ACTION=check ;;
    --bless) ACTION=bless ;;
    *) ARGS+=("$a") ;;
  esac
done
GAME_SCRIPT=res://benchmark/runs/game_script.json

# The physics thread can't be turned off from the command line, only by an override.cfg beside project.godot.
if [[ -e override.cfg ]]; then echo "override.cfg already exists; move it away first" >&2; exit 1; fi
printf '[physics]\n3d/run_on_separate_thread=false\n' > override.cfg
TMP=$(mktemp -d)
trap 'rm -f override.cfg; kill $(jobs -p) 2>/dev/null' EXIT

godot_run() {
  "$GODOT" --headless --fixed-fps 60 res://benchmark/level_replay.tscn -- "$@" || {
    echo "golden replay failed (exit $?)" >&2; exit 1; }
}

# Prints the first line two JSON-lines files differ on, and the first key path inside it that differs.
first_diff() {
  python3 - "$1" "$2" <<'EOF' >&2
import json, sys
def walk(a, b, path):
    if type(a) != type(b) or not isinstance(a, (dict, list)):
        return None if a == b else (path, a, b)
    if isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            r = walk(a.get(k), b.get(k), f"{path}.{k}")
            if r: return r
        return None
    for i in range(max(len(a), len(b))):
        r = walk(a[i] if i < len(a) else None, b[i] if i < len(b) else None, f"{path}[{i}]")
        if r: return r
    return None
with open(sys.argv[1]) as fa, open(sys.argv[2]) as fb:
    for n, (la, lb) in enumerate(zip(fa, fb), 1):
        if la != lb:
            ja, jb = json.loads(la), json.loads(lb)
            path, va, vb = walk(ja, jb, "") or ("", la, lb)
            print(f"first difference on line {n} (tick {ja.get('tick', 'header')}), at {path or 'the whole row'}:\n  A: {va}\n  B: {vb}")
            break
    else:
        print("one file is a prefix of the other")
EOF
}

compare() {  # compare <what> <a> <b>
  if cmp -s "$2" "$3"; then
    echo "$1: match ($(wc -l < "$2" | tr -d ' ') lines)"
    return 0
  fi
  echo "$1: differ ($2 vs $3)" >&2
  first_diff "$2" "$3"
  return 1
}

if [[ $MODE == check ]]; then
  run() {
    local out=$1; shift
    godot_run "--replay=$PATH_ARG" --golden --seed=90210 "--trace=$out.jsonl" "--events=$out.events.jsonl" "--game-script=$GAME_SCRIPT" "$@"
  }
  run "$TMP/a" ${ARGS[@]+"${ARGS[@]}"}
  for _ in $(seq "$(getconf _NPROCESSORS_ONLN)"); do yes >/dev/null & done  # leftover timing dependence shows up under load
  run "$TMP/b" ${ARGS[@]+"${ARGS[@]}"}
  kill $(jobs -p) 2>/dev/null
  OK=0
  compare "golden check: traces" "$TMP/a.jsonl" "$TMP/b.jsonl" || OK=1
  compare "golden check: events" "$TMP/a.events.jsonl" "$TMP/b.events.jsonl" || OK=1
  exit $OK
fi

if [[ $MODE == car ]]; then
  GOLDEN=goldens/car_step.jsonl.gz
  if [[ -z "$PATH_ARG" ]]; then
    # Until the hand drive (benchmark/runs/hafren_free.rec) exists, a scripted one stands in, built fresh each run.
    if [[ -f benchmark/runs/hafren_free.rec ]]; then
      PATH_ARG=res://benchmark/runs/hafren_free.rec
    else
      PATH_ARG="$TMP/synthetic_car_golden.rec"
      "$GODOT" --headless res://benchmark/level_replay.tscn -- --script=res://benchmark/runs/car_golden_script.json \
        "--record=$PATH_ARG" >/dev/null || { echo "couldn't build the synthetic recording" >&2; exit 1; }
    fi
  fi
  run() { godot_run "--replay=$PATH_ARG" --free --full --golden --seed=90210 "--car-trace=$1" ${ARGS[@]+"${ARGS[@]}"}; }
else
  GOLDEN=goldens/events.jsonl.gz
  run() { godot_run "--replay=$PATH_ARG" --full --golden --seed=90210 "--events=$1" "--game-script=$GAME_SCRIPT" ${ARGS[@]+"${ARGS[@]}"}; }
fi

run "$TMP/a.jsonl"
case $ACTION in
  bless)
    mkdir -p goldens
    gzip -n -c "$TMP/a.jsonl" > "$GOLDEN"
    echo "blessed $GOLDEN ($(wc -l < "$TMP/a.jsonl" | tr -d ' ') lines); commit it with a Bless: line saying why"
    ;;
  check)
    [[ -f "$GOLDEN" ]] || { echo "$GOLDEN doesn't exist yet; ./bless.sh it first" >&2; exit 1; }
    gunzip -c "$GOLDEN" > "$TMP/golden.jsonl"
    compare "$GOLDEN" "$TMP/golden.jsonl" "$TMP/a.jsonl"
    ;;
  self)
    run "$TMP/b.jsonl"
    compare "two runs" "$TMP/a.jsonl" "$TMP/b.jsonl"
    ;;
esac

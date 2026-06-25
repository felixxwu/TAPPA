#!/usr/bin/env bash
# Test runner for the rally project:
#   headless: smoke + gameplay tests (tests/headless/)
# Flags:
#   --fast <name>   run only test files whose name matches <name>
#                   (substring, e.g. --fast engine -> test_engine*.gd),
#                   for quick iteration. Final checks should run the full suite.
set -u

# Godot binary: honour $GODOT if set, otherwise try known per-platform
# locations (macOS app bundle, Steam Deck/Linux download) in order.
if [[ -z "${GODOT:-}" ]]; then
  for candidate in \
    /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot \
    /home/deck/tools/godot/Godot_v4.6-stable_linux.x86_64; do
    if [[ -x "$candidate" ]]; then GODOT="$candidate"; break; fi
  done
fi
if [[ -z "${GODOT:-}" || ! -x "$GODOT" ]]; then
  echo "error: Godot binary not found (set \$GODOT to override)" >&2
  exit 2
fi

SELECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast)
      shift
      [[ $# -gt 0 ]] || { echo "error: --fast needs a name (e.g. --fast engine)" >&2; exit 2; }
      SELECT="$1"
      ;;
    *) echo "error: unknown flag $1 (known: --fast <name>)" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")"
FAIL=0

# GUT's exit code only reflects assertion failures — a script that fails to
# parse/load logs "SCRIPT ERROR" but still exits 0, so scan the output too.
run_pass() {
  local out
  out="$("$@" 2>&1)"
  local status=$?
  printf '%s\n' "$out"
  if grep -qE 'SCRIPT ERROR|Parse Error|Failed to load script' <<<"$out"; then
    echo "error: script errors detected in test output" >&2
    return 1
  fi
  return $status
}

# Warm the global class cache before testing. On a cold start Godot doesn't
# always have .godot/global_script_class_cache.cfg populated when GUT compiles
# scripts, so cross-script `class_name` references (CarLibrary, Drivetrain, ...)
# intermittently fail to resolve. A headless --import pass rebuilds the cache
# first, making script loading deterministic run-to-run.
echo "=== warmup: rebuild class cache (--import) ==="
"$GODOT" --headless --import >/dev/null 2>&1 || true

# --fixed-fps 60 decouples the main loop from wall-clock: each iteration advances
# by a fixed 1/60 s delta (matching the default physics_ticks_per_second) and the
# loop runs at CPU speed instead of being paced to real time. The per-step physics
# delta is unchanged, so the sim is bit-for-bit identical to a real-time run — it
# just stops costing ~1/60 s of wall-clock per awaited frame. Must equal the
# physics tick rate so exactly one physics tick fires per frame.
GUT_ARGS=(--headless --fixed-fps 60 -d -s addons/gut/gut_cmdln.gd -gdir=res://tests/headless -ginclude_subdirs -gexit)
if [[ -n "$SELECT" ]]; then
  echo "=== headless (--fast: matching '$SELECT') ==="
  GUT_ARGS+=(-gselect="$SELECT")
else
  echo "=== headless (smoke + gameplay) ==="
fi
run_pass "$GODOT" "${GUT_ARGS[@]}"
[[ $? -ne 0 ]] && FAIL=1

if [[ $FAIL -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "TESTS FAILED" >&2
fi
exit $FAIL

#!/usr/bin/env bash
# Test runner for the rally project:
#   headless: smoke + gameplay tests (tests/headless/)
# Flags:
#   --fast <name>   run only test files whose name matches <name>
#                   (substring, e.g. --fast engine -> test_engine*.gd),
#                   for quick iteration. Final checks should run the full suite.
# Env:
#   TEST_TIMEOUT    hard wall-clock cap for the test run, seconds (default 1800 = 30 min).
#   WARMUP_TIMEOUT  hard cap for the class-cache warmup, seconds (default 300 = 5 min).
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

# Hard wall-clock cap so a hung or stuck run can never run forever (a headless
# Godot process that wedges otherwise lingers for ages, starving later runs of
# CPU — we have seen 40-minute orphans). Defaults: 30 min for the test run, 5 min
# for the class-cache warmup; override with TEST_TIMEOUT / WARMUP_TIMEOUT (seconds).
# `timeout` sends SIGTERM at the deadline, then SIGKILL after TIMEOUT_KILL_GRACE —
# the -k matters because Godot has been seen to ignore SIGTERM, so only the
# SIGKILL fallback guarantees the process actually dies.
TEST_TIMEOUT="${TEST_TIMEOUT:-1800}"
WARMUP_TIMEOUT="${WARMUP_TIMEOUT:-300}"
TIMEOUT_KILL_GRACE=30
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN="gtimeout"  # GNU coreutils on macOS (brew install coreutils)
else
  echo "warning: no 'timeout'/'gtimeout' on PATH — running WITHOUT the hard timeout" \
    "(on macOS: brew install coreutils)" >&2
fi

# Run a command under the hard timeout when available, else run it bare. Usage:
#   with_timeout <seconds> <command...>
with_timeout() {
  local secs="$1"; shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" -k "$TIMEOUT_KILL_GRACE" "$secs" "$@"
  else
    "$@"
  fi
}

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
with_timeout "$WARMUP_TIMEOUT" "$GODOT" --headless --import >/dev/null 2>&1 || true

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
run_pass with_timeout "$TEST_TIMEOUT" "$GODOT" "${GUT_ARGS[@]}"
status=$?
# timeout exits 124 (SIGTERM at the deadline) or 128+9 = 137 (SIGKILL after the
# grace). Either means the run was killed for exceeding the cap, not a test
# failure — call it out distinctly.
if [[ $status -eq 124 || $status -eq 137 ]]; then
  echo "error: tests exceeded the hard timeout of ${TEST_TIMEOUT}s and were killed" >&2
fi
[[ $status -ne 0 ]] && FAIL=1

if [[ $FAIL -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "TESTS FAILED" >&2
fi
exit $FAIL

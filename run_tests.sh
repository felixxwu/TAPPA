#!/usr/bin/env bash
# Test runner for the rally project:
#   headless: smoke + gameplay tests (tests/headless/)
# Flags:
#   --fast <name>...  run only test files whose name matches <name>
#                     (substring, e.g. --fast engine -> test_engine*.gd),
#                     for quick iteration. Accepts MULTIPLE names — as separate
#                     args (--fast menu_flow rally_flag) or one whitespace-
#                     separated string (--fast "menu_flow rally_flag") — and runs
#                     each as its own selection. Final checks should run the full suite.
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

SELECTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fast)
      shift
      [[ $# -gt 0 ]] || { echo "error: --fast needs at least one name (e.g. --fast engine, or --fast 'menu_flow rally_flag')" >&2; exit 2; }
      # Everything after --fast is a test-name pattern. Split each arg on whitespace
      # (without glob expansion, via read -ra) so both `--fast a b` and `--fast "a b"`
      # yield the same list of selections.
      for arg in "$@"; do
        read -ra parts <<<"$arg"
        [[ ${#parts[@]} -gt 0 ]] && SELECTS+=("${parts[@]}")
      done
      break
      ;;
    *) echo "error: unknown flag $1 (known: --fast <name>...)" >&2; exit 2 ;;
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
GUT_BASE=(--headless --fixed-fps 60 -d -s addons/gut/gut_cmdln.gd -gdir=res://tests/headless -ginclude_subdirs -gexit)

# Run one GUT pass; pass a non-empty selection to restrict to matching scripts.
# Returns the run's exit status (timeout-kill codes flagged distinctly).
run_selection() {
  local sel="$1"
  local args=("${GUT_BASE[@]}")
  if [[ -n "$sel" ]]; then
    echo "=== headless (--fast: matching '$sel') ==="
    args+=(-gselect="$sel")
  else
    echo "=== headless (smoke + gameplay) ==="
  fi
  run_pass with_timeout "$TEST_TIMEOUT" "$GODOT" "${args[@]}"
  local status=$?
  # timeout exits 124 (SIGTERM at the deadline) or 128+9 = 137 (SIGKILL after the
  # grace). Either means the run was killed for exceeding the cap, not a test
  # failure — call it out distinctly.
  if [[ $status -eq 124 || $status -eq 137 ]]; then
    echo "error: tests exceeded the hard timeout of ${TEST_TIMEOUT}s and were killed" >&2
  fi
  return $status
}

# No selection -> one full run. One or more --fast names -> one pass each, so a
# failure in any selection fails the whole invocation.
if [[ ${#SELECTS[@]} -eq 0 ]]; then
  run_selection "" || FAIL=1
else
  for sel in "${SELECTS[@]}"; do
    run_selection "$sel" || FAIL=1
  done
fi

if [[ $FAIL -eq 0 ]]; then
  echo "ALL TESTS PASSED"
else
  echo "TESTS FAILED" >&2
fi
exit $FAIL

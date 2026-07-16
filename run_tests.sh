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

# The single source of truth for "GUT exited 0 but the output betrays a broken
# script" — GUT's exit code only reflects assertion failures, so a script that
# fails to parse/load logs one of these but still exits 0. Scanned in run_pass;
# keep new known-fatal output strings in THIS pattern (one place) so the runner
# and anyone reading it agree on what counts as a hidden failure.
TEST_ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script'

# Retry budget for engine SIGSEGV crashes (not test failures — see below).
TEST_CRASH_RETRIES="${TEST_CRASH_RETRIES:-2}"

run_pass() {
  # tee so the output STREAMS live (long runs aren't silent until the end) while
  # still being captured for the error scan. PIPESTATUS[0] is the command's own
  # exit status (tee always exits 0).
  local tmp; tmp="$(mktemp -t rally_test_out.XXXXXX)"
  local status attempt=0
  while true; do
    "$@" 2>&1 | tee "$tmp"
    status=${PIPESTATUS[0]}
    # Retry ONLY an engine-level crash. The full headless suite intermittently
    # SIGSEGVs in Godot's audio mix thread during scene teardown (backtrace:
    # AudioStreamPlaybackResampled::mix -> AudioServer::_mix_step ->
    # AudioDriverDummy::thread_func) — a pre-existing engine race, not our code
    # (it reproduces on clean main at a similar rate). A crash dies by SIGNAL and
    # prints "Program crashed with signal"; a genuine test failure exits CLEANLY
    # via GUT (status 1) and a timeout is 124/137 — none of those are retried, so
    # this can never mask a real failure. A crash that persists past the retries
    # still fails the run.
    if grep -q "Program crashed with signal" "$tmp" \
        && [[ $status -ne 124 && $status -ne 137 && $status -ne 1 ]] \
        && [[ $attempt -lt $TEST_CRASH_RETRIES ]]; then
      attempt=$((attempt + 1))
      echo "warning: headless engine crash (audio-thread SIGSEGV flake) — retrying (${attempt}/${TEST_CRASH_RETRIES})" >&2
      continue
    fi
    break
  done
  if grep -qE "$TEST_ERROR_PATTERN" "$tmp"; then
    rm -f "$tmp"
    echo "error: script errors detected in test output" >&2
    return 1
  fi
  rm -f "$tmp"
  return $status
}

# Warm the global class cache before testing. On a cold start Godot doesn't
# always have .godot/global_script_class_cache.cfg populated when GUT compiles
# scripts, so cross-script `class_name` references (CarLibrary, Drivetrain, ...)
# intermittently fail to resolve. A headless --import pass rebuilds the cache
# first, making script loading deterministic run-to-run.
echo "=== warmup: rebuild class cache (--import) ==="
# Best-effort (the tests still run if it fails), but SURFACE the failure rather
# than silently swallowing it with `|| true` — a broken warmup is the usual cause
# of intermittent, run-to-run class_name resolution flakiness, so a visible
# warning is what lets you connect the two.
if ! with_timeout "$WARMUP_TIMEOUT" "$GODOT" --headless --import >/dev/null 2>&1; then
  echo "warning: class-cache warmup (--import) failed or timed out — script loading" \
    "may be nondeterministic this run (cross-script class_name references can flake)" >&2
fi

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

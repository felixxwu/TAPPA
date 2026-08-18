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
#   TEST_TIMEOUT    hard wall-clock cap for the whole run, seconds (default 1800 = 30 min).
#   TEST_STALL      per-test cap: kill the run if NO test output for this many seconds
#                   (default 120). Reports the last test that started. Raise it for a
#                   legitimately slow test rather than removing it.
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
  # NO coreutils `timeout` on this box (stock macOS has neither). It used to just warn and run
  # UNCAPPED, which is how wedged headless runs sat there for 10-16 minutes eating CPU and looking
  # like a hung agent. A tiny bash watchdog is enough, so there is no excuse for running uncapped.
  TIMEOUT_BIN="builtin"
fi

# Pure-bash stand-in for `timeout -k`: run the command, and if it outlives the deadline send TERM,
# then KILL after the grace. Exits 124 on the deadline, matching coreutils so callers need no
# special-casing.
builtin_timeout() {
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  # Publish the RUN's pid for stall_watchdog. This is the only place that has it: everything above is
  # a shell function, and killing a function's subshell leaves its Godot child running.
  if [[ -n "${RUN_PIDFILE:-}" ]]; then
    echo "$cmd_pid" >"$RUN_PIDFILE"
  fi
  (
    local waited=0
    while (( waited < secs )); do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    kill -TERM "$cmd_pid" 2>/dev/null
    local grace=0
    while (( grace < TIMEOUT_KILL_GRACE )); do
      kill -0 "$cmd_pid" 2>/dev/null || exit 0
      sleep 1
      grace=$((grace + 1))
    done
    kill -KILL "$cmd_pid" 2>/dev/null
  ) &
  local watchdog=$!
  local status=0
  wait "$cmd_pid" 2>/dev/null || status=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  # 143 = 128+SIGTERM, 137 = 128+SIGKILL: both mean the watchdog fired.
  if [[ $status -eq 143 || $status -eq 137 ]]; then
    return 124
  fi
  return $status
}

# Run a command under the hard timeout when available, else run it bare. Usage:
#   with_timeout <seconds> <command...>
with_timeout() {
  local secs="$1"; shift
  if [[ "$TIMEOUT_BIN" == "builtin" ]]; then
    builtin_timeout "$secs" "$@"
  else
    "$TIMEOUT_BIN" -k "$TIMEOUT_KILL_GRACE" "$secs" "$@"
  fi
}

# PER-TEST HARD TIMEOUT, as an output-inactivity watchdog.
#
# The wall-clock cap above only catches a run that hangs for half an hour; a single wedged test is
# far more common and far more useful to catch early — an infinite layout/resize loop, an await that
# never resolves. GUT streams a line per test as it starts, so a HEALTHY run never goes quiet for
# long: if the captured output stops growing for TEST_STALL seconds, a test is stuck.
#
# When it fires it names the LAST TEST THAT STARTED, which is the thing you actually want to know and
# which neither a wall-clock cap nor GUT itself will tell you.
TEST_STALL="${TEST_STALL:-120}"

# Watches the log FILE, not the pipeline. It is started before the run and killed after; it takes no
# pid deliberately, because waiting on a backgrounded PIPELINE returns tee's status rather than
# Godot's — which would report a FAILING run as passing. The run stays in the foreground so
# PIPESTATUS[0] keeps meaning what it did.
stall_watchdog() {
  local logfile="$1" pidfile="$2"
  local last_size=0 idle=0 size
  while true; do
    sleep 5
    size=$(wc -c <"$logfile" 2>/dev/null || echo 0)
    if [[ "$size" == "$last_size" ]]; then
      idle=$((idle + 5))
      if (( idle >= TEST_STALL )); then
        # Match the test name ANYWHERE on the line: GUT indents and colourises its per-test lines, so
        # anchoring to "^* test_" found nothing. Fall back to the last real line of output, which at
        # least names the script when the very first test is the one that wedged.
        local stuck tail_line
        stuck="$(grep -oE "test_[A-Za-z0-9_]+" "$logfile" 2>/dev/null | tail -1)"
        tail_line="$(grep -v "^[[:space:]]*$" "$logfile" 2>/dev/null | tail -1)"
        echo "" >&2
        echo "error: no test output for ${TEST_STALL}s — a test is STUCK. Killing the run." >&2
        echo "error: last test seen: ${stuck:-<none>}" >&2
        echo "error: last output line: ${tail_line:-<none>}" >&2
        echo "error: (raise the cap with TEST_STALL=<seconds> if a test is legitimately slow)" >&2
        # KILL ONLY OUR OWN RUN, by pid. `pkill -f gut_cmdln.gd` matched every Godot test process on
        # the machine — and this repo assumes PARALLEL AGENTS in one checkout, so a stall here would
        # have killed another agent's healthy run with nothing in their log to explain it.
        local victim
        victim="$(cat "$pidfile" 2>/dev/null)"
        if [[ -n "$victim" ]]; then
          kill -KILL "$victim" 2>/dev/null
        else
          # Only when the pid was never published (the coreutils `timeout` path, which wraps the run in
          # its own process). Pattern-killing is the blunt fallback, so say so — in a checkout shared
          # with parallel agents it can take out someone else's healthy run.
          echo "error: (no run pid recorded — falling back to pkill, which may hit other runs)" >&2
          pkill -f "gut_cmdln.gd" 2>/dev/null
        fi
        return 0
      fi
    else
      last_size="$size"
      idle=0
    fi
  done
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
# "PROFILE SANDBOX VIOLATION" is printed by tests/headless/save_sandbox_post_hook.gd
# when the run modified the REAL player profile (user://profile.json) instead of a
# throwaway one — a data-loss bug that has already cost one developer their career
# save, so it fails the run outright.
TEST_ERROR_PATTERN='SCRIPT ERROR|Parse Error|Failed to load script|PROFILE SANDBOX VIOLATION'

# Retry budget for engine SIGSEGV crashes (not test failures — see below).
TEST_CRASH_RETRIES="${TEST_CRASH_RETRIES:-2}"

run_pass() {
  # tee so the output STREAMS live (long runs aren't silent until the end) while
  # still being captured for the error scan. PIPESTATUS[0] is the command's own
  # exit status (tee always exits 0).
  local tmp; tmp="$(mktemp -t rally_test_out.XXXXXX)"
  local pidfile; pidfile="$(mktemp -t rally_test_pid.XXXXXX)"
  local status attempt=0
  while true; do
    : >"$tmp"
    : >"$pidfile"
    stall_watchdog "$tmp" "$pidfile" &
    local dog_pid=$!
    RUN_PIDFILE="$pidfile" "$@" 2>&1 | tee "$tmp"
    status=${PIPESTATUS[0]}
    kill "$dog_pid" 2>/dev/null
    wait "$dog_pid" 2>/dev/null
    # Retry ONLY an engine-level crash. The full headless suite intermittently
    # SIGSEGVs in Godot's audio mix thread during scene teardown (backtrace:
    # AudioStreamPlaybackResampled::mix -> AudioServer::_mix_step ->
    # AudioDriverDummy::thread_func) — a pre-existing engine race, not our code
    # (it reproduces on clean main at a similar rate). A crash dies by SIGNAL and
    # prints "Program crashed with signal"; a genuine test failure exits CLEANLY
    # via GUT (status 1) and a timeout is 124/137 — none of those are retried, so
    # this can never mask a real failure. A crash that persists past the retries
    # still fails the run.
    # 137 (SIGKILL) covers both the wall-clock timeout and a stall kill, so neither is retried.
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
    rm -f "$tmp" "$pidfile"
    echo "error: script errors detected in test output" >&2
    return 1
  fi
  rm -f "$tmp" "$pidfile"
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
#
# The pre/post-run hooks install the run's SAFETY DEFAULTS (GUT allows one of each, so
# the pre hook hosts both):
#   * the player profile is sandboxed to a throwaway file, so a test that forgets to
#     redirect cannot write user://profile.json — that once wiped a real career, and the
#     post hook verifies the real file was left untouched;
#   * real scene changes are suppressed (Scenes.block_real_changes), so an escaped
#     transition cannot park a live scene under /root and corrupt the physics space for
#     every file that runs afterwards.
# See tests/headless/save_sandbox_pre_hook.gd for the full rationale on both.
GUT_BASE=(--headless --fixed-fps 60 -d -s addons/gut/gut_cmdln.gd -gdir=res://tests/headless -ginclude_subdirs -gexit
  -gpre_run_script=res://tests/headless/save_sandbox_pre_hook.gd
  -gpost_run_script=res://tests/headless/save_sandbox_post_hook.gd)

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

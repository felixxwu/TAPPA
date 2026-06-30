#!/usr/bin/env bash
# Standalone performance benchmark — NOT part of the test suite (run_tests.sh).
# Run on demand to investigate choppiness / performance regressions.
#
#   ./run_benchmark.sh             # windowed: CPU chunk timings + GPU/render time
#   ./run_benchmark.sh --headless  # CPU-only (no GPU), quick
#
# Loads benchmark/perf_benchmark.tscn, which prints a report and quits.
set -u

GODOT="${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}"
if [[ ! -x "$GODOT" ]]; then
  echo "error: Godot binary not found at $GODOT (set \$GODOT to override)" >&2
  exit 2
fi

HEADLESS=""
ISOLATE=0
case "${1:-}" in
  --headless) HEADLESS="--headless" ;;
  --isolate)  ISOLATE=1 ;;        # run each driving variant in its own process
  "") ;;
  *) echo "error: unknown flag $1 (known: --headless, --isolate)" >&2; exit 2 ;;
esac

cd "$(dirname "$0")"

# Warm the global class cache so cross-script class_name refs resolve (same as
# run_tests.sh).
"$GODOT" --headless --import >/dev/null 2>&1 || true

if [[ $ISOLATE -eq 1 ]]; then
  # One fresh process per variant => no leftover chunk colliders / scenes from a
  # prior variant skewing the next. Spec = skipmesh:skipcol:reqperframe:label.
  echo "=== isolated driving variants (one process each) ==="
  for spec in \
    "0:0:0:0:0:baseline (mesh + collision)" \
    "0:1:0:0:0:no collision" \
    "1:0:0:0:0:no mesh upload" \
    "0:0:1:0:0:throttled gen (1/frame)" \
    "0:0:0:0:1:no unload" \
    "0:0:0:1:0:no streaming (control)"; do
    BENCH_DRIVE="$spec" "$GODOT" res://benchmark/perf_benchmark.tscn 2>&1 \
      | grep -E "^\s+\[|integrated [0-9]"
  done
  exit 0
fi

exec "$GODOT" $HEADLESS res://benchmark/perf_benchmark.tscn

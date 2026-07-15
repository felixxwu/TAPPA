#!/usr/bin/env bash
# Standalone performance benchmark — NOT part of the test suite (run_tests.sh).
# Run on demand to investigate choppiness / performance regressions.
#
#   ./run_benchmark.sh             # windowed: real frame timing + GPU/render time
#   ./run_benchmark.sh --headless  # CPU-only (no GPU), quick
#
# Loads benchmark/perf_benchmark.tscn, which drives the in-game benchmark run
# (the auto-piloted fixed seeded stage, features/benchmark.md), prints its stats
# breakdown, and quits.
set -u

GODOT="${GODOT:-/Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot}"
if [[ ! -x "$GODOT" ]]; then
  echo "error: Godot binary not found at $GODOT (set \$GODOT to override)" >&2
  exit 2
fi

HEADLESS=""
case "${1:-}" in
  --headless) HEADLESS="--headless" ;;
  "") ;;
  *) echo "error: unknown flag $1 (known: --headless)" >&2; exit 2 ;;
esac

cd "$(dirname "$0")"

# Warm the global class cache so cross-script class_name refs resolve (same as
# run_tests.sh).
"$GODOT" --headless --import >/dev/null 2>&1 || true

exec "$GODOT" $HEADLESS res://benchmark/perf_benchmark.tscn

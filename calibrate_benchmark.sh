#!/usr/bin/env bash
# C1 — benchmark fidelity. Does the CarPerformance benchmark lap RANK cars the same
# way real generated stages do? Reports the Spearman rank correlation between benchmark
# time and mean optimum time over a sample of live-generated stages spanning archetypes,
# names the worst over-/under-rated builds, and sweeps the benchmark geometry knobs.
#
# A reporting tool, not a pass/fail gate — same posture as report_eligibility.sh.
# Design: docs/superpowers/specs/2026-08-15-car-performance-rating-design.md > Calibration (C1)
#
#   ./calibrate_benchmark.sh
#   ./calibrate_benchmark.sh -- --stages=8 --straight=350,500,750 --sweeper=70,90,120
#
# Stage generation is the whole cost (a few seconds each), so keep --stages sane.
set -euo pipefail

if [[ -z "${GODOT:-}" ]]; then
  for candidate in \
    /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot \
    /usr/local/bin/godot \
    /home/deck/tools/godot/Godot_v4.6-stable_linux.x86_64; do
    if [[ -x "$candidate" ]]; then GODOT="$candidate"; break; fi
  done
fi
if [[ -z "${GODOT:-}" || ! -x "$GODOT" ]]; then
  echo "error: Godot binary not found (set \$GODOT to override)" >&2
  exit 2
fi

exec "$GODOT" --headless --path . res://tools/calibrate_benchmark.tscn "$@"

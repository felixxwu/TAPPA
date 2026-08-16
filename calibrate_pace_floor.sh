#!/usr/bin/env bash
# C2 — pace floor. Inventories every time-like data source in the repo/save and reports
# what can and cannot be concluded about the human/optimum ratio behind
# RallyLibrary.PACE_MIN_FLOOR. It deliberately does NOT invent a human-performance
# number: there is no recorded human-time corpus here, and saying so (plus what would
# need collecting) is the honest output.
#
# A reporting tool, not a pass/fail gate — same posture as report_eligibility.sh.
# Design: docs/superpowers/specs/2026-08-15-car-performance-rating-design.md > Calibration (C2)
#
#   ./calibrate_pace_floor.sh
#   ./calibrate_pace_floor.sh -- --profile=user://profile.json --no-solve
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

exec "$GODOT" --headless --path . res://tools/calibrate_pace_floor.tscn "$@"

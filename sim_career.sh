#!/usr/bin/env bash
# Simulate many whole careers as pure computation — no track generation, no
# physics, no main.tscn — using the REAL progression predicates
# (RallyLibrary.rally_revealed / is_eligible / incomplete_rallies_enterable_by,
# RewardSystem.draw_car) over a synthetic profile. Reports, per rally completed,
# the mean number of cars owned and unfinished-but-enterable rallies, plus how
# often a career SOFT-LOCKS (rallies left, no owned car in band for any of them).
#
# A reporting tool, not a pass/fail gate — same posture as report_eligibility.sh.
# Design: docs/superpowers/specs/2026-08-05-career-sim-design.md
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

exec "$GODOT" --headless --path . res://tools/sim_career.tscn

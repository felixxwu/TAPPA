#!/usr/bin/env bash
# Report car<->rally eligibility for every rally in RallyLibrary.RALLIES x every
# car in CarLibrary.CARS, using the real RallyLibrary.is_eligible /
# ineligibility_reason predicates (never a re-implementation). Flags rallies
# with < 2 or > 4 eligible cars and cars that can enter almost nothing, so a
# bad `restriction` is visible at authoring time instead of in-game. See
# todo/one-map-four-corners.md > "New task: an eligibility-report tool".
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

exec "$GODOT" --headless --path . res://tools/report_eligibility.tscn

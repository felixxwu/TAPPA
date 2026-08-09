#!/usr/bin/env bash
# Regenerate data/eligibility.json — the rally x car matrix tools/fit_map_pins.py reads.
# Run after changing any restriction band, car or engine. See tools/export_eligibility.gd.
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
exec "$GODOT" --headless --path . res://tools/export_eligibility.tscn

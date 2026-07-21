#!/usr/bin/env bash
# Regenerate the committed opponent-field lockfile (data/opponent_cache.json).
# Requires a FRESH track cache first (run ./cache_tracks.sh, or use ./cache_all.sh).
# See docs/superpowers/specs/2026-07-21-opponent-field-cache-design.md.
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

exec "$GODOT" --headless --path . res://tools/generate_opponent_cache.tscn

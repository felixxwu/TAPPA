#!/usr/bin/env bash
# Probe ONE stage's track generation without touching data/track_cache.json.
# The debugging companion to cache_tracks.sh (which always rebakes every stage):
# when the baker reports "track cache: region X slot N candidate C seed S did not
# complete", run
#
#   ./probe_track.sh --from-region=X --seed=S
#
# to see the resolved TrackGenParams, the waterline around the start, and how many
# corners the DFS actually placed. Other forms:
#   ./probe_track.sh --from-region=home                         # every stage of a region
#   ./probe_track.sh --seed=54103 --turns=31 --straightness=0.2 --water=-4.0
# Exits 1 if any probed event failed to complete.
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

exec "$GODOT" --headless --path . res://tools/probe_track_event.tscn -- "$@"

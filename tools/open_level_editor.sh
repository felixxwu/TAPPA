#!/bin/sh
# Serves the repo and opens the level editor with the Hafren level loaded.
cd "$(dirname "$0")/.." || exit 1
PORT=${PORT:-8765}
python3 -m http.server "$PORT" >/dev/null 2>&1 &
trap 'kill $!' EXIT INT TERM
sleep 1
open "http://localhost:$PORT/tools/level_editor_lab.html?level=levels/hafren_5km.json"
echo "Serving on :$PORT — Ctrl-C to stop."
wait

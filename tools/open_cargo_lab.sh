#!/bin/sh
# Serves the repo and opens the cargo lab (it loads the car models and car_cargo.json over HTTP).
cd "$(dirname "$0")/.." || exit 1
PORT=${PORT:-8765}
lsof -ti tcp:"$PORT" -sTCP:LISTEN | xargs kill 2>/dev/null
python3 -m http.server "$PORT" >/dev/null 2>&1 &
trap 'kill $!' EXIT INT TERM
sleep 1
open "http://localhost:$PORT/tools/cargo_lab.html${1:+?car=$1}"
echo "Serving on :$PORT — Ctrl-C to stop."
wait

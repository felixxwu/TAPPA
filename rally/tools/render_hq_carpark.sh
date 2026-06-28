#!/usr/bin/env bash
# Verification aid: boot the real HQ scene with a full collection parked and
# capture the exterior/title shot + the car-park (car-select) framing to
# docs/garage/hq_exterior_view.png / hq_carpark_view.png. Needs the global class
# cache, so it runs a headless --import first. Uses xvfb + the opengl3 driver.
#
# Usage: tools/render_hq_carpark.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

cd "$HERE"
"$GODOT" --headless --import >/dev/null 2>&1 || true
xvfb-run -a -s "-screen 0 1600x900x24" \
	"$GODOT" --rendering-driver opengl3 \
	--path "$HERE" --script "res://tools/render_hq_carpark.gd" \
	2>&1 | grep -E "hq-render|SCRIPT ERROR" || true

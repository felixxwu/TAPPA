#!/usr/bin/env bash
# Verification aid: boot the real HQ scene and capture the garage station to
# docs/garage/hq_garage_view.png (proves the garage model frames the map table
# and tuning lift in-context). Needs the global class cache, so it runs a
# headless --import first. Uses xvfb + the opengl3 driver to capture pixels.
#
# Usage: tools/render_hq_garage.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

cd "$HERE"
"$GODOT" --headless --import >/dev/null 2>&1 || true
xvfb-run -a -s "-screen 0 1600x900x24" \
	"$GODOT" --rendering-driver opengl3 \
	--path "$HERE" --script "res://tools/render_hq_garage.gd" \
	2>&1 | grep -E "hq-render|SCRIPT ERROR" || true

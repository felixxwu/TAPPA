#!/usr/bin/env bash
# Render every BarrierSection style (straight run + corner run + two contact
# sheets) into docs/barriers/*.png.
#
# Godot needs a real GL context to capture viewport images, which the --headless
# dummy renderer can't provide, so we run the OpenGL driver inside a virtual X
# display (xvfb) — same recipe as tools/render_garage.sh.
#
# Usage: tools/render_barriers.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"

cd "$HERE"
xvfb-run -a -s "-screen 0 1600x900x24" \
	"$GODOT" --rendering-driver opengl3 --resolution 1280x720 \
	--path "$HERE" --script "res://tools/render_barriers.gd" \
	2>&1 | grep -vE "Identifier .* not declared|Could not find type|Cannot infer|Failed to (load|instantiate)|GDScript::reload|modules/gdscript|main/main.cpp" || true

echo "--- rendered files ---"
ls -la "$HERE/docs/barriers/" 2>/dev/null || echo "(no output dir)"

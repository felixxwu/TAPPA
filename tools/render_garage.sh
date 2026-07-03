#!/usr/bin/env bash
# Render the garage model from several angles into docs/garage/*.png.
#
# Godot needs a GL context to capture viewport images, which the --headless
# dummy renderer can't provide, so we run the real OpenGL driver inside a
# virtual X display (xvfb). Output PNGs land in rally/docs/garage/.
#
# Usage: tools/render_garage.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the rally/ project dir
GODOT="${GODOT:-godot}"

cd "$HERE"
xvfb-run -a -s "-screen 0 1600x900x24" \
	"$GODOT" --rendering-driver opengl3 --resolution 1280x720 \
	--path "$HERE" --script "res://tools/render_garage.gd" \
	2>&1 | grep -vE "Identifier .* not declared|Could not find type|Cannot infer|Failed to (load|instantiate)|GDScript::reload|modules/gdscript|main/main.cpp" || true

echo "--- rendered files ---"
ls -la "$HERE/docs/garage/" 2>/dev/null || echo "(no output dir)"

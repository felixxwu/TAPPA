#!/usr/bin/env bash
# Render the HQ map table model from several angles into docs/map_table/*.png.
#
# Godot needs a GL context to capture viewport images, which the --headless
# dummy renderer can't provide, so we run the real OpenGL driver inside a
# virtual X display (xvfb). A headless --import first populates the global
# class cache (MapTable's class_name). Output PNGs land in rally/docs/map_table/.
#
# Usage: tools/render_map_table.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # the rally/ project dir
GODOT="${GODOT:-godot}"

cd "$HERE"
"$GODOT" --headless --import >/dev/null 2>&1 || true
xvfb-run -a -s "-screen 0 1600x900x24" \
	"$GODOT" --rendering-driver opengl3 --resolution 1280x720 \
	--path "$HERE" --script "res://tools/render_map_table.gd" \
	2>&1 | grep -vE "Identifier .* not declared|Could not find type|Cannot infer|Failed to (load|instantiate)|GDScript::reload|modules/gdscript|main/main.cpp" || true

echo "--- rendered files ---"
ls -la "$HERE/docs/map_table/" 2>/dev/null || echo "(no output dir)"

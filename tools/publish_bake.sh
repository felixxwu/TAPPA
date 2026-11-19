#!/bin/bash
# Uploads a level's baked .bake.res to the `bakes` GitHub release as <name>-<key>.bake.res. Usage: tools/publish_bake.sh tools/levels/<name>.json
cd "$(dirname "$0")/.." || exit 1
GODOT=${GODOT:-$(ls /Applications/Godot.app/Contents/MacOS/Godot /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot 2>/dev/null | head -1)}
save=${1:?usage: tools/publish_bake.sh tools/levels/<name>.json}
read -r _ key status < <("$GODOT" --headless --path . res://tools/bake_key.tscn -- "res://${save#res://}" 2>&1 | grep '^bake_key:')
[ "$status" = ok ] || { echo "$save: its bake is $status; run tools/bake_level.sh first"; exit 1; }
name=$(basename "${save%.json}")
asset="$(mktemp -d)/$name-$key.bake.res"
cp "${save%.json}.bake.res" "$asset"
gh release view bakes >/dev/null 2>&1 || gh release create bakes --title "Level bakes" --notes "Built by tools/bake_level.sh; fetched by tools/fetch_bakes.sh"
gh release upload bakes "$asset" --clobber
echo "published $(basename "$asset")"

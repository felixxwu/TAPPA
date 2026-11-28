#!/bin/bash
# Uploads a level's baked .bake.res and its neutral .bake.bin to the `bakes` GitHub release as <name>-<key>.bake.res and <name>-<neutral key>.bake.bin. Usage: tools/publish_bake.sh [tools/levels/<name>.json], defaulting to GameConfig.level_path
cd "$(dirname "$0")/.." || exit 1
GODOT=${GODOT:-$(ls /Applications/Godot.app/Contents/MacOS/Godot /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot 2>/dev/null | head -1)}
save=${1:-$(grep -o 'var level_path.*"res://[^"]*"' scripts/game_config.gd | grep -o 'res://[^"]*')}
save=${save#res://}
read -r _ key status < <("$GODOT" --headless --path . res://tools/bake_key.tscn -- "res://${save#res://}" 2>&1 | grep '^bake_key:')
[ "$status" = ok ] || { echo "$save: its bake is $status; run tools/bake_level.sh first"; exit 1; }
"$GODOT" --headless --path . res://tools/neutral_export.tscn -- --bake="res://$save" || { echo "$save: neutral export failed"; exit 1; }
nkey=$(node tools/neutral_key.js "$save") || exit 1
name=$(basename "${save%.json}")
dir=$(mktemp -d)
asset="$dir/$name-$key.bake.res"
neutral="$dir/$name-$nkey.bake.bin"
cp "${save%.json}.bake.res" "$asset"
cp "${save%.json}.bake.bin" "$neutral" || exit 1 || exit 1
gh release view bakes >/dev/null 2>&1 || gh release create bakes --title "Level bakes" --notes "Built by tools/bake_level.sh; fetched by tools/fetch_bakes.sh"
gh release upload bakes "$asset" "$neutral" --clobber
echo "published $(basename "$asset") $(basename "$neutral")"

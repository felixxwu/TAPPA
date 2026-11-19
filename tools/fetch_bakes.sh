#!/bin/bash
# Downloads each shipped level's bake from the `bakes` release into tools/levels/. Run by CI before exporting; set GODOT if godot is not on PATH.
cd "$(dirname "$0")/.." || exit 1
GODOT=${GODOT:-godot}
for save in tools/levels/*.json; do
	name=$(basename "${save%.json}")
	read -r _ key _ < <("$GODOT" --headless --path . res://tools/bake_key.tscn -- "res://$save" 2>&1 | grep '^bake_key:')
	asset="$name-$key.bake.res"
	gh release download bakes --pattern "$asset" --output "${save%.json}.bake.res" --clobber 2>/dev/null \
		|| { echo "no bake published for $name ($asset); run: tools/bake_level.sh && tools/publish_bake.sh $save"; exit 1; }
done

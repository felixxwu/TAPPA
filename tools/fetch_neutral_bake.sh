#!/bin/bash
# Downloads each shipped level's neutral bake (.bake.bin) from the `bakes` release into tools/levels/. Needs node and gh, not Godot.
cd "$(dirname "$0")/.." || exit 1
for save in tools/levels/*.json; do
	name=$(basename "${save%.json}")
	[[ $name == *.* ]] && continue  # a sidecar like <level>.buildings.json, not a level
	key=$(node tools/neutral_key.js "$save") || exit 1
	asset="$name-$key.bake.bin"
	gh release download bakes --pattern "$asset" --output "${save%.json}.bake.bin" --clobber 2>/dev/null \
		|| { echo "no neutral bake published for $name ($asset); run: tools/publish_bake.sh $save"; exit 1; }
done

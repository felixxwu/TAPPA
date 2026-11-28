#!/bin/bash
# Phase 2 parity check: Godot exports the neutral files, the Rust reader reads them, and both manifests must match line for line.
# Needs godot (set GODOT), node and cargo. Run tools/fetch_bakes.sh first so each level's .bake.res is present.
cd "$(dirname "$0")/.." || exit 1
GODOT=${GODOT:-godot}
OUT=build/neutral
export_run() { "$GODOT" --headless --path . res://tools/neutral_export.tscn -- "$@"; }

node tools/neutral_key.js --self-test || exit 1
rm -rf "$OUT" && mkdir -p "$OUT"
for save in tools/levels/*.json; do
	[[ $(basename "${save%.json}") == *.* ]] && continue  # a sidecar like <level>.buildings.json, not a level
	export_run --bake="res://$save" --out="res://$OUT" || exit 1
done
export_run --assets="$OUT" || exit 1
export_run --geometry="$OUT" || exit 1
cargo test -p assets || exit 1
cargo run --release -p assets --bin asset_check -- "$OUT" > "$OUT/rust.manifest" || exit 1
if ! diff "$OUT/godot.manifest" "$OUT/rust.manifest" > "$OUT/manifest.diff"; then
	echo "neutral_check: manifests differ (first 20 lines of the diff):"
	head -20 "$OUT/manifest.diff"
	exit 1
fi
echo "neutral_check: manifests match ($(wc -l < "$OUT/godot.manifest") lines)"

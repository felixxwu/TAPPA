#!/bin/bash
# Windows are small, side by side and always on top: macOS stops drawing a covered window, which stalls the bake.
# Bakes a level with its visibility rendered by N parallel Godot windows, then merges and publishes it (tools/publish_bake.sh). Usage: BAKE_LEVEL=res://tools/levels/x.json tools/bake_level.sh [N]
cd "$(dirname "$0")/.." || exit 1
GODOT=${GODOT:-$(ls /Applications/Godot.app/Contents/MacOS/Godot /Users/felixwu/Downloads/Godot.app/Contents/MacOS/Godot 2>/dev/null | head -1)}
N=${1:-$(( $(sysctl -n hw.ncpu 2>/dev/null || nproc) / 2 ))}
DATA=${XDG_DATA_HOME:-$HOME/Library/Application Support/Godot/app_userdata}
rm -f "$DATA"/TAPPA/bake_shard_*.var
pids=()
for ((i = 0; i < N; i++)); do
	"$GODOT" --audio-driver Dummy --always-on-top --resolution 200x150 --position $((i % 8 * 210)),$((i / 8 * 200)) --path . res://tools/bake_level.tscn -- --shard=$i/$N > "${TMPDIR:-/tmp}/bake_shard_$i.log" 2>&1 &
	pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
if [ $fail = 1 ]; then echo "a shard failed; see ${TMPDIR:-/tmp}/bake_shard_*.log"; exit 1; fi
"$GODOT" --audio-driver Dummy --path . --headless res://tools/bake_level.tscn -- --merge=$N || exit 1
level=${BAKE_LEVEL:-$(grep -o 'var level_path.*"res://[^"]*"' scripts/game_config.gd | grep -o 'res://[^"]*')}
exec tools/publish_bake.sh "${level#res://}"

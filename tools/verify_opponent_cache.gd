extends Node
# Fast, generation-free freshness check for the opponent-field lockfile. Recomputes
# the sorted set of per-rally keys and compares to the stored source_hash. A mismatch
# means a rally/car/grip/physics input changed but the lockfile wasn't regenerated.
# Runs as a scene (autoloads needed). See
# docs/superpowers/specs/2026-07-21-opponent-field-cache-design.md.

const CACHE_PATH := "res://data/opponent_cache.json"


func _ready() -> void:
	if not FileAccess.file_exists(CACHE_PATH):
		push_error("opponent cache: %s is missing — run ./cache_all.sh and commit" % CACHE_PATH)
		get_tree().quit(1)
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		push_error("opponent cache: %s is not valid JSON" % CACHE_PATH)
		get_tree().quit(1)
		return
	var committed := String(data.get("source_hash", ""))
	var current := TrackCache.source_hash_of(OpponentCache.all_rally_keys())
	if committed == current:
		print("opponent cache: source hash fresh (%s)" % current)
		get_tree().quit(0)
	else:
		push_error("opponent cache STALE: committed %s != current %s — run ./cache_all.sh and commit" % [committed, current])
		get_tree().quit(1)

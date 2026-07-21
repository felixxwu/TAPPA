extends Node
# Fast, generation-free freshness check for the committed track-turn lockfile.
# Recomputes the rally library's input fingerprint (the sorted set of per-event
# cache keys) and compares it to the source_hash stored in data/track_cache.json.
# A mismatch means seeds/params/terrain/version changed but the lockfile wasn't
# regenerated. Runs as a scene (autoloads needed). See
# docs/superpowers/specs/2026-07-21-track-turn-cache-design.md.

const CACHE_PATH := "res://data/track_cache.json"


func _ready() -> void:
	if not FileAccess.file_exists(CACHE_PATH):
		push_error("track cache: %s is missing — run ./cache_tracks.sh and commit" % CACHE_PATH)
		get_tree().quit(1)
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CACHE_PATH))
	if typeof(data) != TYPE_DICTIONARY:
		push_error("track cache: %s is not valid JSON" % CACHE_PATH)
		get_tree().quit(1)
		return
	var committed := String(data.get("source_hash", ""))
	var current := TrackCache.source_hash_of(TrackCache.all_event_keys())
	if committed == current:
		print("track cache: source hash fresh (%s)" % current)
		get_tree().quit(0)
	else:
		push_error("track cache STALE: committed %s != current %s — run ./cache_tracks.sh and commit" % [committed, current])
		get_tree().quit(1)

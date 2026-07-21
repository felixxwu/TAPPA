extends Node
# Scene-run generator for the opponent-field lockfile (data/opponent_cache.json).
# Rebuilds each event's track from the TRACK cache (fast), runs the deterministic
# opponent-field generation, and commits the result. Run AFTER the track cache is
# fresh (cache_all.sh enforces order). See
# docs/superpowers/specs/2026-07-21-opponent-field-cache-design.md.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")
const OUT_PATH := "res://data/opponent_cache.json"


func _ready() -> void:
	var entries: Dictionary = {}
	var keys: Array = []
	for rally in RallyLibrary.all():
		var events: Array = rally.get("events", [])
		var results: Array = []
		for event in events:
			var cfg := RallySession.canonical_event_config(event)
			var params := TrackGenParams.for_event(event, cfg)
			results.append(await TrackGenerator.generate_cached(params, cfg))
		var field := RallyLibrary.generate_opponent_field(rally, results, events)
		var key := OpponentCache.key_for(rally)
		keys.append(key)
		entries[key] = OpponentCache.serialize_field(field)
		print("opponent cache: rally %s -> %d rivals" % [rally.get("id", "?"), field.size()])
	var sorted_keys := entries.keys()
	sorted_keys.sort()
	var ordered: Dictionary = {}
	for k in sorted_keys:
		ordered[k] = entries[k]
	var out := {
		"version": 1,
		"source_hash": TrackCache.source_hash_of(keys),
		"entries": ordered,
	}
	if not DirAccess.dir_exists_absolute("res://data"):
		DirAccess.make_dir_recursive_absolute("res://data")
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		push_error("opponent cache: cannot open %s (err %d)" % [OUT_PATH, FileAccess.get_open_error()])
		get_tree().quit(1)
		return
	# 4-arg: indent, sort_keys, full_precision=true (wreck_progress is a float; the
	# 3rd arg is sort_keys, NOT full_precision).
	f.store_string(JSON.stringify(out, "  ", true, true))
	f.close()
	print("opponent cache: wrote %d entries to %s" % [ordered.size(), OUT_PATH])
	get_tree().quit(0)

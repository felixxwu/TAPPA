extends Node
# Scene-run lockfile generator (NOT a --script SceneTree: Config/RallySession are
# autoloads that only exist in a scene run). Writes res://data/track_cache.json.
# Invoked by cache_tracks.sh; validated in CI. See
# docs/superpowers/specs/2026-07-21-track-turn-cache-design.md.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")
const OUT_PATH := "res://data/track_cache.json"


func _ready() -> void:
	var entries: Dictionary = {}
	var keys: Array = []
	var failures := 0
	for rally in RallyLibrary.all():
		for event in rally.get("events", []):
			print("track cache: generating rally %s seed %d ..." % [rally.get("id", "?"), int(event.get("seed", -1))])
			var cfg := RallySession.canonical_event_config(event)
			var params := TrackGenParams.for_event(event, cfg)
			var result := await TrackGenerator.generate(params)
			var key := TrackCache.key_for(params, cfg)
			keys.append(key)
			if not result["complete"]:
				push_error("track cache: rally %s seed %d did not complete" % [rally.get("id", "?"), params.seed])
				failures += 1
			entries[key] = { "pieces": _serialize(result["pieces"]), "complete": result["complete"] }
	# Sort keys so the committed diff is stable across runs.
	var sorted_keys := entries.keys()
	sorted_keys.sort()
	var ordered: Dictionary = {}
	for k in sorted_keys:
		ordered[k] = entries[k]
	# source_hash lets CI verify freshness without regenerating any track (compares
	# the library's current input fingerprint against this stored value).
	var out := {
		"version": 1,
		"source_hash": TrackCache.source_hash_of(keys),
		"entries": ordered,
	}
	# res://data may not exist on a fresh checkout of the tools; ensure it before write.
	if not DirAccess.dir_exists_absolute("res://data"):
		DirAccess.make_dir_recursive_absolute("res://data")
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		push_error("track cache: cannot open %s for write (err %d)" % [OUT_PATH, FileAccess.get_open_error()])
		get_tree().quit(1)
		return
	# full_precision = true: the default truncates entry_pos/entry_heading doubles,
	# which would shift rebuilt points and destabilise the committed file.
	f.store_string(JSON.stringify(out, "  ", true, true))
	f.close()
	print("track cache: wrote %d entries to %s" % [ordered.size(), OUT_PATH])
	get_tree().quit(1 if failures > 0 else 0)


func _serialize(pieces: Array) -> Array:
	var out: Array = []
	for p in pieces:
		out.append({
			"corner": p["corner"],
			"flip": p["flip"],
			"straight": p["straight"],
			"entry_pos": [p["entry_pos"].x, p["entry_pos"].y],
			"entry_heading": [p["entry_heading"].x, p["entry_heading"].y],
		})
	return out

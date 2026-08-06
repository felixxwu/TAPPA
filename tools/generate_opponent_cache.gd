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
		_fill_ghost_seeds(field, results, rally, events)
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


# Solve and store each event's rival-ghost pace seed (features/rival-ghost.md).
#
# Only for that event's P1 — the fastest rival with a real time — because P1 is the only
# rival a ghost is ever built for. Every other rival gets -1 ("no seed"), which the runtime
# reads as "solve from scratch". Filling the whole field would be ~10x the bake cost for
# pace nobody displays; a future multi-rival field is where that changes.
#
# The seed is a HINT, not gospel: the runtime re-solves one sweep with it and falls back to
# the full bisection if the residual is out of tolerance. That check is what makes a
# cached-vs-live divergence visible instead of silently wrong, so an approximate seed here
# (this has no TrackProgress, so no live timed span) is safe by construction.
func _fill_ghost_seeds(field: Array, results: Array, rally: Dictionary, events: Array) -> void:
	for opp in field:
		var seeds: Array = []
		for _i in events.size():
			seeds.append(-1.0)
		opp["skill_k"] = seeds
	for ev_i in events.size():
		if ev_i >= results.size():
			continue
		var track: Dictionary = results[ev_i]
		if track.is_empty():
			continue
		var best := -1
		var best_ms := -1
		for i in field.size():
			var times: Array = field[i].get("event_times_ms", [])
			if ev_i >= times.size():
				continue
			var t := int(times[ev_i])
			if t < 0:
				continue
			if best_ms < 0 or t < best_ms:
				best_ms = t
				best = i
		if best < 0:
			continue
		var row: Dictionary = field[best]
		var entry := CarLibrary.by_id(String(row.get("car_id", "")))
		if entry.is_empty():
			continue
		var eid := String(row.get("engine_id", ""))
		var owned: Dictionary = {"swapped_engine": eid} if eid != "" else {}
		var meta := UpgradeLibrary.effective_meta(owned, entry)
		var event: Dictionary = (events[ev_i] as Dictionary).duplicate()
		event["region"] = rally.get("region", "")
		var pace: RivalPace = RivalPace.solve(track, meta, event, best_ms)
		if pace.is_degenerate():
			continue
		row["skill_k"][ev_i] = pace.solved_k()

class_name MusicLibrary
extends RefCounted
# The music catalogue: id -> { bpm, segments }. Same pattern as EngineLibrary.
# Each song is split into 4 SEGMENTS, each authored as 4 bars lead-in + 8 bars
# main + 4 bars lead-out (see MusicSchedule / features/music.md). The segments
# play in order (1->2->3->4->1); the 8-bar main re-triggers, so a swap to another
# song can land every 8 bars. bpm is authored per song (all its segments share it)
# and is what the scheduler uses to derive bar durations — it must match the true
# tempo or the loop drifts.
#
# NOTE: these are ~128 kbps Ogg Vorbis. Unlike MP3, Vorbis carries no fixed
# per-file encoder head-delay, so both the within-song segment loop and the
# cross-SONG swap (echo_chamber <-> skillz, at different tempos) stay tightly
# aligned at the seam.

# LAZY LOADING. The table stores segment PATHS, not preloaded streams: a
# `preload` inside a const is resolved at parse time, so merely touching
# MusicLibrary (which the `Music` autoload does at boot) used to pull every
# segment of every song into memory — ~4.5 MB resident before the first frame on
# the single-threaded wasm build, when only one song (~4 x 180 KB) is ever
# audible at a time. `by_id` now `load()`s a song's segments on first request and
# caches the resolved entry, so only songs that actually play cost memory.
# Anything that just needs shape (`segment_count`, iterating the table) must read
# `segment_paths` and NOT call `by_id`, or the laziness is defeated.
const SONGS: Array[Dictionary] = [
	{
		"id": "echo_chamber",
		"bpm": 168.0,  # authored (the HQ theme); every segment shares this tempo
		"segment_paths": [
			"res://music/echochamber1.ogg",
			"res://music/echochamber2.ogg",
			"res://music/echochamber3.ogg",
			"res://music/echochamber4.ogg",
		],
	},
	{
		"id": "skillz",
		"bpm": 170.0,  # authored (a rally theme)
		"segment_paths": [
			"res://music/skillz1.ogg",
			"res://music/skillz2.ogg",
			"res://music/skillz3.ogg",
			"res://music/skillz4.ogg",
		],
	},
	{
		"id": "deadlock",
		"bpm": 174.0,  # authored (a rally theme)
		"segment_paths": [
			"res://music/deadlock1.ogg",
			"res://music/deadlock2.ogg",
			"res://music/deadlock3.ogg",
			"res://music/deadlock4.ogg",
		],
	},
	{
		"id": "nightandday",
		"bpm": 171.0,  # authored (a rally theme)
		"segment_paths": [
			"res://music/nightandday1.ogg",
			"res://music/nightandday2.ogg",
			"res://music/nightandday3.ogg",
			"res://music/nightandday4.ogg",
		],
	},
	{
		"id": "threaded",
		"bpm": 174.0,  # authored (a rally theme)
		"segment_paths": [
			"res://music/threaded1.ogg",
			"res://music/threaded2.ogg",
			"res://music/threaded3.ogg",
			"res://music/threaded4.ogg",
		],
	},
	{
		"id": "whoyouare",
		"bpm": 174.0,  # authored (a rally theme)
		"segment_paths": [
			"res://music/whoyouare1.ogg",
			"res://music/whoyouare2.ogg",
			"res://music/whoyouare3.ogg",
			"res://music/whoyouare4.ogg",
		],
	},
]

# Which song plays in which context. Driven by the live SCENE STATE (not by
# transition hooks, which are fragile): the HQ scene gets a song from HQ_SONGS,
# every other scene (loading, start line, driving, standings, podium …) gets a
# RALLY song. Both the HQ song and the rally song are chosen at random by
# MusicDirector at every loading screen (see MusicDirector._update_loading_edge)
# and held for the whole HQ visit / event respectively. The swap latches at the
# next 8-bar handoff, so it always lands beat-aligned.
const HQ_SCENE := "res://hq.tscn"
# The pool the HQ context draws from. Any of these is a valid HQ song; the
# director picks one per HQ visit. Order is not significant.
const HQ_SONGS: Array[String] = ["echo_chamber", "skillz"]
# The pool the rally context draws from. Any of these is a valid rally song; the
# director picks one per event. Order is not significant.
const RALLY_SONGS: Array[String] = ["skillz", "deadlock", "nightandday", "threaded", "whoyouare"]


# id -> the resolved entry ({id, bpm, segments}) with its streams loaded. Filled
# on first by_id for that id and kept for the session, so a song that plays again
# doesn't re-load.
static var _loaded: Dictionary = {}


# The song entry with its segments LOADED (streams). First call for an id loads
# that song's segment files; later calls return the very same cached entry.
# Returns {} for an unknown id. Callers that only need shape should use
# segment_count / entry_of instead — those never load.
static func by_id(id: String) -> Dictionary:
	if _loaded.has(id):
		return _loaded[id]
	var raw := entry_of(id)
	if raw.is_empty():
		return {}
	var streams: Array[AudioStream] = []
	for path in (raw["segment_paths"] as Array):
		var stream := load(String(path)) as AudioStream
		if stream != null:
			streams.append(stream)
	var resolved := {"id": raw["id"], "bpm": raw["bpm"], "segments": streams}
	_loaded[id] = resolved
	return resolved


# The raw authored entry (paths, not streams) — never loads anything. {} if unknown.
static func entry_of(id: String) -> Dictionary:
	for song in SONGS:
		if song["id"] == id:
			return song
	return {}


# True once this song's segments have been loaded into the cache.
static func is_loaded(id: String) -> bool:
	return _loaded.has(id)


# Drop the loaded-stream cache (test hook; Godot's own resource cache means a
# re-load of a still-referenced stream returns the same resource anyway).
static func clear_cache() -> void:
	_loaded.clear()


# How many segments a song has (0 if unknown). Reads the authored paths, so it
# does NOT load the audio.
static func segment_count(id: String) -> int:
	var song := entry_of(id)
	return (song["segment_paths"] as Array).size() if not song.is_empty() else 0


# True when the given scene is the HQ (the one context with a fixed song). Every
# other scene is a "rally" context that plays a randomly-chosen RALLY_SONGS entry.
static func is_hq_scene(scene_path: String) -> bool:
	return scene_path == HQ_SCENE


# A random rally song id, avoiding `exclude_id` when the pool has more than one
# entry (so the same song never plays two events in a row). `exclude_id` may be
# "" (nothing to avoid, e.g. the first pick).
static func random_rally_song(exclude_id := "") -> String:
	return _random_from_pool(RALLY_SONGS, exclude_id)


# A random HQ song id, avoiding `exclude_id` when the pool has more than one
# entry (so the same song never plays two HQ visits in a row). `exclude_id` may
# be "" (nothing to avoid, e.g. the first pick).
static func random_hq_song(exclude_id := "") -> String:
	return _random_from_pool(HQ_SONGS, exclude_id)


# Shared picker: a uniformly random entry of `pool`, avoiding `exclude_id` when
# the pool has more than one entry.
static func _random_from_pool(pool: Array[String], exclude_id: String) -> String:
	var choices := pool.duplicate()
	if choices.size() > 1 and choices.has(exclude_id):
		choices.erase(exclude_id)
	return choices[randi() % choices.size()]

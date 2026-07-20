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

const SONGS: Array[Dictionary] = [
	{
		"id": "echo_chamber",
		"bpm": 168.0,  # authored (the HQ theme); every segment shares this tempo
		"segments": [
			preload("res://music/echochamber1.ogg"),
			preload("res://music/echochamber2.ogg"),
			preload("res://music/echochamber3.ogg"),
			preload("res://music/echochamber4.ogg"),
		],
	},
	{
		"id": "skillz",
		"bpm": 170.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/skillz1.ogg"),
			preload("res://music/skillz2.ogg"),
			preload("res://music/skillz3.ogg"),
			preload("res://music/skillz4.ogg"),
		],
	},
	{
		"id": "deadlock",
		"bpm": 174.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/deadlock1.ogg"),
			preload("res://music/deadlock2.ogg"),
			preload("res://music/deadlock3.ogg"),
			preload("res://music/deadlock4.ogg"),
		],
	},
	{
		"id": "nightandday",
		"bpm": 171.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/nightandday1.ogg"),
			preload("res://music/nightandday2.ogg"),
			preload("res://music/nightandday3.ogg"),
			preload("res://music/nightandday4.ogg"),
		],
	},
	{
		"id": "threaded",
		"bpm": 174.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/threaded1.ogg"),
			preload("res://music/threaded2.ogg"),
			preload("res://music/threaded3.ogg"),
			preload("res://music/threaded4.ogg"),
		],
	},
	{
		"id": "whoyouare",
		"bpm": 174.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/whoyouare1.ogg"),
			preload("res://music/whoyouare2.ogg"),
			preload("res://music/whoyouare3.ogg"),
			preload("res://music/whoyouare4.ogg"),
		],
	},
]

# Which song plays in which context. Driven by the live SCENE STATE (not by
# transition hooks, which are fragile): the HQ scene gets HQ_SONG, every other
# scene (loading, start line, driving, standings, podium …) gets a RALLY song.
# The HQ song is fixed; the rally song is one of RALLY_SONGS, chosen at random by
# MusicDirector at every loading screen (see MusicDirector._pick_rally_song) and
# held for the whole event. The swap latches at the next 8-bar handoff, so it
# always lands beat-aligned.
const HQ_SCENE := "res://hq.tscn"
const HQ_SONG := "echo_chamber"
# The pool the rally context draws from. Any of these is a valid rally song; the
# director picks one per event. Order is not significant.
const RALLY_SONGS: Array[String] = ["skillz", "deadlock", "nightandday", "threaded", "whoyouare"]


static func by_id(id: String) -> Dictionary:
	for song in SONGS:
		if song["id"] == id:
			return song
	return {}


# How many segments a song has (0 if unknown).
static func segment_count(id: String) -> int:
	var song := by_id(id)
	return (song["segments"] as Array).size() if not song.is_empty() else 0


# True when the given scene is the HQ (the one context with a fixed song). Every
# other scene is a "rally" context that plays a randomly-chosen RALLY_SONGS entry.
static func is_hq_scene(scene_path: String) -> bool:
	return scene_path == HQ_SCENE


# A random rally song id, avoiding `exclude_id` when the pool has more than one
# entry (so the same song never plays two events in a row). `exclude_id` may be
# "" (nothing to avoid, e.g. the first pick).
static func random_rally_song(exclude_id := "") -> String:
	var pool := RALLY_SONGS.duplicate()
	if pool.size() > 1 and pool.has(exclude_id):
		pool.erase(exclude_id)
	return pool[randi() % pool.size()]

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
# NOTE: these are 320 kbps MP3s. Fine for a song looping through its own segments
# (they share the same encoder head-delay, so the summed tails stay relatively
# aligned). The cross-SONG swap (echo_chamber <-> skillz, at different tempos) can
# be a few tens of ms out of alignment at the seam because of per-file MP3 delay;
# convert to Ogg Vorbis if that ever sounds off.

const SONGS: Array[Dictionary] = [
	{
		"id": "echo_chamber",
		"bpm": 168.0,  # authored (the HQ theme); every segment shares this tempo
		"segments": [
			preload("res://music/echochamber1.mp3"),
			preload("res://music/echochamber2.mp3"),
			preload("res://music/echochamber3.mp3"),
			preload("res://music/echochamber4.mp3"),
		],
	},
	{
		"id": "skillz",
		"bpm": 170.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/skillz1.mp3"),
			preload("res://music/skillz2.mp3"),
			preload("res://music/skillz3.mp3"),
			preload("res://music/skillz4.mp3"),
		],
	},
	{
		"id": "deadlock",
		"bpm": 174.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/deadlock1.mp3"),
			preload("res://music/deadlock2.mp3"),
			preload("res://music/deadlock3.mp3"),
			preload("res://music/deadlock4.mp3"),
		],
	},
	{
		"id": "nightandday",
		"bpm": 171.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/nightandday1.mp3"),
			preload("res://music/nightandday2.mp3"),
			preload("res://music/nightandday3.mp3"),
			preload("res://music/nightandday4.mp3"),
		],
	},
	{
		"id": "threaded",
		"bpm": 174.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/threaded1.mp3"),
			preload("res://music/threaded2.mp3"),
			preload("res://music/threaded3.mp3"),
			preload("res://music/threaded4.mp3"),
		],
	},
	{
		"id": "whoyouare",
		"bpm": 174.0,  # authored (a rally theme)
		"segments": [
			preload("res://music/whoyouare1.mp3"),
			preload("res://music/whoyouare2.mp3"),
			preload("res://music/whoyouare3.mp3"),
			preload("res://music/whoyouare4.mp3"),
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

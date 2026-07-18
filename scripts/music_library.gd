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
		"bpm": 170.0,  # authored (the run theme)
		"segments": [
			preload("res://music/skillz1.mp3"),
			preload("res://music/skillz2.mp3"),
			preload("res://music/skillz3.mp3"),
			preload("res://music/skillz4.mp3"),
		],
	},
]

# Which song plays in which context. Driven by the live SCENE STATE (not by
# transition hooks, which are fragile): the HQ scene gets HQ_SONG, everything else
# (loading, start line, driving, standings, podium …) gets RUN_SONG. The swap
# latches at the next 32-bar handoff, so it always lands beat-aligned.
const HQ_SCENE := "res://hq.tscn"
const HQ_SONG := "echo_chamber"
const RUN_SONG := "skillz"


static func by_id(id: String) -> Dictionary:
	for song in SONGS:
		if song["id"] == id:
			return song
	return {}


# How many segments a song has (0 if unknown).
static func segment_count(id: String) -> int:
	var song := by_id(id)
	return (song["segments"] as Array).size() if not song.is_empty() else 0


# The song for whatever scene is current — the single decision point for context
# music. Any scene that is not the HQ is treated as a "run" context.
static func song_for_scene(scene_path: String) -> String:
	return HQ_SONG if scene_path == HQ_SCENE else RUN_SONG

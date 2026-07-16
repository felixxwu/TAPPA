class_name MusicLibrary
extends RefCounted
# The music catalogue: id -> { bpm, stream }. Same pattern as EngineLibrary.
# Each song file follows the 8/32/8-bar structure (see MusicSchedule /
# features/music.md). bpm is authored per song and is what the scheduler uses to
# derive bar durations — it must match the file's true tempo or the loop drifts.
#
# NOTE: Skillz is a 320 kbps MP3. That is fine for looping a song INTO ITSELF
# (every voice shares the same encoder head-delay, so the summed tails stay
# relatively aligned). Before adding a SECOND song that transitions against this
# one, convert both to Ogg Vorbis — MP3 encoder delay breaks cross-song
# "lead-in ends exactly at the handoff" alignment.

const SONGS: Array[Dictionary] = [
	{
		"id": "echo_chamber",
		"bpm": 168.0,  # authored; 8/32/8 bars like every track
		"stream": preload("res://music/Echo Chamber.mp3"),
	},
	{
		"id": "skillz",
		# 170 bpm, authored (confirmed): 48 bars = 67.76 s of music (the file's
		# 67.81 s includes ~0.05 s MP3 padding). Exact tempo — the self-loop
		# relies on it not drifting over minutes.
		"bpm": 170.0,
		"stream": preload("res://music/Skillz.mp3"),
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


# The song for whatever scene is current — the single decision point for context
# music. Any scene that is not the HQ is treated as a "run" context.
static func song_for_scene(scene_path: String) -> String:
	return HQ_SONG if scene_path == HQ_SCENE else RUN_SONG

class_name MusicDirector
extends Node
# Autoload: drives the interactive music loop. Owns ONE AudioStreamPlayer running
# an AudioStreamPolyphonic; each 32-bar iteration is a voice launched via
# play_stream(stream, from_offset), so overlapping lead-out + lead-in tails share
# one mix timeline (sample-accurate relative alignment). All timing math is in
# MusicSchedule; this node is deliberately thin. See features/music.md.
#
# Scheduling state is mutated by advance()/seed(), which are pure w.r.t. audio and
# fully unit-tested. The audio surface (_ready/_process/_audio_now/_launch) is
# thin glue around them.

# Player-facing music level, persisted in the save profile (the single source of
# truth — see features/music.md). Linear [0,1]; the settings menu drives it.
const SETTING_KEY := "music_volume"
const DEFAULT_VOLUME := 0.6

var current_id := ""        # song occupying the grid now ("" = idle)
var requested_id := ""      # latched swap target; applied at next handoff
var next_handoff := 0.0     # grid time (s) of the next main-loop start

var _bpm_override := {}      # test hook: {id: bpm}; bypasses MusicLibrary when set
var _player: AudioStreamPlayer = null
var _playback: AudioStreamPlaybackPolyphonic = null


func _bpm_for(id: String) -> float:
	if _bpm_override.has(id):
		return _bpm_override[id]
	var song := MusicLibrary.by_id(id)
	return song.get("bpm", 0.0) if not song.is_empty() else 0.0


# First-play grid seed: current = requested = id, and the first handoff is one
# loop body after the first main loop begins. (Named seed_grid, not seed, to
# avoid shadowing GDScript's built-in global seed().)
func seed_grid(now: float, id: String) -> void:
	current_id = id
	requested_id = id
	next_handoff = MusicSchedule.seed_handoff(now, _bpm_for(id))


# Pure per-frame decision. Returns {} (no fire) or {song_id, from_offset}.
# Mutates grid state; touches no audio.
func advance(now: float) -> Dictionary:
	if current_id == "":
		return {}
	next_handoff = MusicSchedule.catch_up(next_handoff, now, _bpm_for(current_id))
	var in_bpm := _bpm_for(requested_id)
	var start := MusicSchedule.fire_start(next_handoff, in_bpm)
	if not MusicSchedule.should_fire(now, start):
		return {}
	var late := MusicSchedule.late_by(now, start, in_bpm)
	var launched := requested_id
	current_id = launched
	next_handoff = MusicSchedule.advance_handoff(next_handoff, in_bpm)
	return {"song_id": launched, "from_offset": late}


# Start if idle (seed + launch the first voice as an intro), else latch a swap
# that advance() applies at the next handoff.
func play_song(id: String) -> void:
	requested_id = id
	if current_id == "":
		var now := _audio_now()
		seed_grid(now, id)
		_launch(id, 0.0)


# --- Audio glue -------------------------------------------------------------

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep music running while paused
	_ensure_music_bus()
	_player = AudioStreamPlayer.new()
	_player.bus = "Music"
	var poly := AudioStreamPolyphonic.new()
	poly.polyphony = 4  # >= 2 overlapping voices (outgoing tail + incoming lead-in)
	_player.stream = poly
	add_child(_player)
	_player.play()  # start the continuous polyphonic timeline (our clock)
	_playback = _player.get_stream_playback() as AudioStreamPlaybackPolyphonic
	_apply_volume()
	# No hardcoded autostart — _process picks the song from the live scene state
	# (see update_for_scene), so the first frame starts the right context track.


func _process(_delta: float) -> void:
	# Context music is driven by SCENE STATE, not transition hooks: each frame we
	# ask which song the current scene wants and (re)queue it. play_song latches a
	# swap for the next handoff, so this is idempotent and beat-aligned.
	update_for_scene(_current_scene_path())
	if current_id == "" or _playback == null:
		return
	var fire := advance(_audio_now())
	if not fire.is_empty():
		_launch(fire["song_id"], fire["from_offset"])


# The scene_file_path of the running scene ("" if none yet). Reading the live
# scene is the state the music context keys off.
func _current_scene_path() -> String:
	var t := get_tree()
	if t == null or t.current_scene == null:
		return ""
	return t.current_scene.scene_file_path


# Queue the song the given scene wants (HQ song in the HQ scene, run song
# elsewhere). No-op when it already matches what's requested; seeds immediately if
# idle, otherwise latches a swap for the next 32-bar handoff.
func update_for_scene(scene_path: String) -> void:
	var want := MusicLibrary.song_for_scene(scene_path)
	if want != "" and want != requested_id:
		play_song(want)


func _audio_now() -> float:
	# Monotonic wall clock. NOTE: AudioStreamPlayer.get_playback_position() does
	# NOT advance for an AudioStreamPolyphonic stream (no single timeline), so it
	# cannot be the clock. We schedule against the wall clock instead; overlapping
	# voices still stay sample-aligned because they share the one polyphonic mix
	# timeline, and from_offset absorbs per-frame jitter. Wall-vs-audio drift is
	# ~ppm — negligible over a session.
	return Time.get_ticks_usec() / 1_000_000.0


func _launch(id: String, from_offset: float) -> void:
	if _playback == null:
		return
	var song := MusicLibrary.by_id(id)
	if song.is_empty():
		return
	_playback.play_stream(song["stream"], from_offset)


func _ensure_music_bus() -> void:
	if AudioServer.get_bus_index("Music") != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, "Music")
	AudioServer.set_bus_send(idx, "Master")


# Set the music level (linear [0,1]): apply it live to the Music bus and, unless
# persist is false, store it in the save profile. Called by the settings slider.
func set_volume(linear: float, persist := true) -> void:
	var lin := clampf(linear, 0.0, 1.0)
	if persist:
		Save.set_setting(SETTING_KEY, lin)
	_apply_bus_volume(lin)


func _apply_volume() -> void:
	_apply_bus_volume(clampf(float(Save.get_setting(SETTING_KEY, DEFAULT_VOLUME)), 0.0, 1.0))


func _apply_bus_volume(lin: float) -> void:
	var idx := AudioServer.get_bus_index("Music")
	if idx == -1:
		return
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(lin, 0.0001)))

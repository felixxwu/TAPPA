class_name MusicDirector
extends Node
# Autoload: drives the interactive music loop. Owns ONE AudioStreamPlayer running
# an AudioStreamPolyphonic; each 8-bar segment is a voice launched via
# play_stream(stream, from_offset), so overlapping lead-out + lead-in tails share
# one mix timeline (sample-accurate relative alignment). All timing math is in
# MusicSchedule; this node is deliberately thin. See features/music.md.
#
# A song is 4 SEGMENTS played in order (0->1->2->3->0). At each 8-bar handoff we
# advance to the next segment; on the wrap after the last segment we loop back to
# segment 0 UNLESS a different song has been requested, in which case we jump to
# segment 0 of that song instead. Scheduling state is mutated by advance()/
# seed_grid(), which are pure w.r.t. audio and fully unit-tested; the audio surface
# (_ready/_process/_audio_now/_launch) is thin glue.

# Player-facing music level, persisted in the save profile (the single source of
# truth — see features/music.md). Linear [0,1]; the settings menu drives it.
const SETTING_KEY := "music_volume"
const DEFAULT_VOLUME := 0.7

# Stall-recovery fallback defaults (GameConfig overrides these at runtime).
const DEFAULT_STALL_THRESHOLD_SEC := 0.5
const DEFAULT_RESUME_STABLE_SEC := 0.4

var current_song := ""      # song sounding now ("" = idle)
var requested_song := ""    # what the scene wants; a change interrupts the sequence
var current_segment := 0    # which segment of current_song is playing (0-based)
var next_handoff := 0.0     # grid time (s) of the next segment's main-loop start

var _bpm_override := {}              # test hook: {id: bpm}; bypasses MusicLibrary
var _segment_count_override := {}    # test hook: {id: count}; bypasses MusicLibrary
var _last_now := 0.0            # previous frame's _audio_now(); 0 until first frame
var _suspended := false         # true between a detected stall and a clean resume
var _stable_sec := 0.0          # accumulated normal-delta time since the last stall
var _stall_threshold_override = null    # test hook: float
var _resume_stable_override = null      # test hook: float
var _stall_recovery_override = null     # test hook: bool
var _player: AudioStreamPlayer = null
var _playback: AudioStreamPlaybackPolyphonic = null


func _bpm_for(id: String) -> float:
	if _bpm_override.has(id):
		return _bpm_override[id]
	var song := MusicLibrary.by_id(id)
	return song.get("bpm", 0.0) if not song.is_empty() else 0.0


func _segment_count(id: String) -> int:
	if _segment_count_override.has(id):
		return _segment_count_override[id]
	return maxi(1, MusicLibrary.segment_count(id))


# First-play grid seed: start segment 0 of `id`, first handoff one loop body after
# its main loop begins. (Named seed_grid, not seed, to avoid shadowing GDScript's
# built-in global seed().)
func seed_grid(now: float, id: String) -> void:
	current_song = id
	requested_song = id
	current_segment = 0
	next_handoff = MusicSchedule.seed_handoff(now, _bpm_for(id))


# Pure per-frame decision. Returns {} (no fire) or {song, segment, from_offset}.
# Mutates grid state; touches no audio. Picks the next segment: segment 0 of a
# newly-requested song, else the next segment of the current song (wrapping to 0).
func advance(now: float) -> Dictionary:
	if current_song == "":
		return {}
	next_handoff = MusicSchedule.catch_up(next_handoff, now, _bpm_for(current_song))
	var next_song := current_song
	var next_seg := (current_segment + 1) % _segment_count(current_song)
	if requested_song != current_song:
		next_song = requested_song
		next_seg = 0
	var in_bpm := _bpm_for(next_song)
	var start := MusicSchedule.fire_start(next_handoff, in_bpm)
	if not MusicSchedule.should_fire(now, start):
		return {}
	var late := MusicSchedule.late_by(now, start, in_bpm)
	current_song = next_song
	current_segment = next_seg
	next_handoff = MusicSchedule.advance_handoff(next_handoff, in_bpm)
	return {"song": next_song, "segment": next_seg, "from_offset": late}


# Start if idle (seed + launch segment 0 immediately), else latch a swap that
# advance() applies at the next handoff (jumping to segment 0 of the new song).
func play_song(id: String) -> void:
	requested_song = id
	if current_song == "":
		var now := _audio_now()
		seed_grid(now, id)
		_launch(id, 0, 0.0)


func _stall_threshold() -> float:
	if _stall_threshold_override != null:
		return float(_stall_threshold_override)
	var cfg := _cfg()
	return cfg.music_stall_threshold_sec if cfg != null else DEFAULT_STALL_THRESHOLD_SEC


func _resume_stable_sec() -> float:
	if _resume_stable_override != null:
		return float(_resume_stable_override)
	var cfg := _cfg()
	return cfg.music_resume_stable_sec if cfg != null else DEFAULT_RESUME_STABLE_SEC


func _stall_recovery_enabled() -> bool:
	if _stall_recovery_override != null:
		return bool(_stall_recovery_override)
	return OS.has_feature("web")


func _cfg() -> GameConfig:
	return Config.data if Config != null else null


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
	_tick(_audio_now())


# The whole per-frame body, driveable with a synthetic `now` in tests.
func _tick(now: float) -> void:
	# Stall/stable bookkeeping FIRST — before advance() or update_for_scene(), so a
	# stall frame can never fire a stale voice or trip the scene auto-restart path.
	var gap := now - _last_now
	var had_prev := _last_now > 0.0
	_last_now = now

	if _stall_recovery_enabled() and had_prev and gap > _stall_threshold():
		_enter_suspend()
		return

	if _suspended:
		_stable_sec += gap
		_try_resume(now)
		return

	# Normal path (matches the Task 4 extraction: gate _launch on _playback, not an
	# early return, so off-tree tests can advance the grid; _launch self-guards too).
	var scene_path := _current_scene_path()
	if scene_path != "":
		update_for_scene(scene_path)
	if current_song == "":
		return
	var fire := advance(now)
	if not fire.is_empty() and _playback != null:
		_launch(fire["song"], fire["segment"], fire["from_offset"])


# Enter the suspended state ON THE TRANSITION only. world.gd yields a frame between
# every generation stage, so many processed frames during a load have stall-sized
# gaps; the stop/clear must happen once, not every stall frame. While already
# suspended, a fresh stall just resets the stable window.
func _enter_suspend() -> void:
	if _suspended:
		_stable_sec = 0.0
		return
	_suspended = true
	_stable_sec = 0.0
	current_song = ""
	requested_song = ""
	if _player != null:
		_player.stop()   # frees the polyphonic playback + all voices
		_player.play()   # fresh, empty mix timeline
		_playback = _player.get_stream_playback() as AudioStreamPlaybackPolyphonic


# Resume only once frames have flowed normally for the stable window AND no loading
# screen is up. The group check is load-bearing: individual chunk-precompute frames
# (world.gd) can be under threshold, so _stable_sec could satisfy the window
# mid-generation — only the group check prevents a mid-load resume. On resume we
# re-seed from the current clock and start segment 0 of the scene's wanted song.
func _try_resume(now: float) -> void:
	if _stable_sec < _resume_stable_sec():
		return
	if not is_inside_tree() or not get_tree().get_nodes_in_group("loading_screen").is_empty():
		return
	_suspended = false
	var want := MusicLibrary.song_for_scene(_current_scene_path())
	if want != "":
		seed_grid(now, want)
		_launch(want, 0, 0.0)


# The scene_file_path of the running scene ("" if none yet). Reading the live
# scene is the state the music context keys off.
func _current_scene_path() -> String:
	if not is_inside_tree():
		return ""
	var t := get_tree()
	if t == null or t.current_scene == null:
		return ""
	return t.current_scene.scene_file_path


# Queue the song the given scene wants (HQ song in the HQ scene, run song
# elsewhere). No-op when it already matches what's requested; seeds immediately if
# idle, otherwise latches a swap for the next 8-bar handoff.
func update_for_scene(scene_path: String) -> void:
	var want := MusicLibrary.song_for_scene(scene_path)
	if want != "" and want != requested_song:
		play_song(want)


func _audio_now() -> float:
	# Monotonic wall clock. NOTE: AudioStreamPlayer.get_playback_position() does
	# NOT advance for an AudioStreamPolyphonic stream (no single timeline), so it
	# cannot be the clock. We schedule against the wall clock instead; overlapping
	# voices still stay sample-aligned because they share the one polyphonic mix
	# timeline, and from_offset absorbs per-frame jitter. Wall-vs-audio drift is
	# ~ppm — negligible over a session.
	return Time.get_ticks_usec() / 1_000_000.0


func _launch(id: String, segment: int, from_offset: float) -> void:
	if _playback == null:
		return
	var song := MusicLibrary.by_id(id)
	if song.is_empty():
		return
	var segs: Array = song["segments"]
	if segment < 0 or segment >= segs.size():
		return
	# Force STREAM playback and route to the Music bus explicitly. On the web export
	# the default playback type resolves to SAMPLE (WebAudio one-shot samples), which
	# doesn't emit for AudioStreamPlaybackPolyphonic — so music was silent on web
	# while working on desktop. play_stream()'s `bus` also defaults to "Master" (NOT
	# the player's bus), so without this the music-volume bus never applied either.
	_playback.play_stream(segs[segment], from_offset, 0.0, 1.0,
		AudioServer.PLAYBACK_TYPE_STREAM, &"Music")


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

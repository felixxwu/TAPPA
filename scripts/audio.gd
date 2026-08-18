class_name AudioManager
extends Node
# Docs: features/sfx.md, todo/audio.md — update in the same change as this file.
# Tests: tests/headless/test_audio.gd — extend in the same change.
#
# Autoload ("Audio"): the ONE place this project plays a one-shot sound effect.
#
# READ THIS BEFORE ADDING A SOUND ANYWHERE. If you want a sound on some event
# (a countdown tick, a menu move, a crash, a reward reveal), the whole job is:
#
#     Audio.play_beep()                 # the standard cue, tuned in GameConfig
#     Audio.play_beep(1200.0, 0.25)     # a higher/longer variant
#
# Do NOT build an AudioStreamGenerator, AudioStreamPlayer or PCM loop at the call
# site. That has been tried and it goes wrong four ways at once, all of which are
# already solved here, once:
#
#   1. push_buffer(PackedVector2Array) is the bulk call; push_frame() takes a single
#      Vector2. Mixing them up is a compile-time type error that breaks the whole file.
#   2. get_stream_playback() returns null on a STOPPED player. The order must be
#      play() THEN get_stream_playback() (see engine_audio.gd _ready) — the other way
#      round the usual `if playback == null: return` guard silently swallows it and you
#      ship silence with no error.
#   3. Headless (tests/CI) must never play(). Godot's dummy driver still runs a mix
#      thread and frees a PLAYING generator playback underneath it at teardown — a
#      use-after-free that SIGSEGVs intermittently. See features/testing.md
#      ("Headless audio invariant") and features/engine-audio.md.
#   4. The player and generator are built ONCE, at boot. Rebuilding them per call
#      (especially from a _process path) reassigns `stream` and invalidates the very
#      playback you just fetched.
#
# There are no audio SAMPLES in this project — nothing is authored, and the engine
# note is synthesized too (engine_audio.gd / EngineAudioSynth). So the primitive
# here is a PROCEDURAL beep rather than a clip library. When authored .ogg clips do
# land, add a play_sfx(id) alongside play_beep() on this same node/bus; see
# todo/audio.md for the planned clip set.

# Dedicated mix bus for one-shots, created at boot (mirrors the Music / Engine buses
# in music_director.gd). A named bus is the house convention: never route SFX to
# Master, or there is no single lever for an SFX volume slider.
const BUS := &"SFX"

# Fallbacks used only when GameConfig is unavailable (e.g. an off-tree unit test).
# The real values are authored in config/game_config.tres — tune them THERE.
const DEFAULT_FREQUENCY_HZ := 880.0
const DEFAULT_DURATION_SEC := 0.12
const DEFAULT_VOLUME_DB := -6.0
const DEFAULT_DECAY := 12.0
const DEFAULT_MIX_RATE := 22050.0

# Generator buffer depth. Must comfortably exceed the longest beep, since a beep is
# rendered in one push; anything past the buffer is dropped.
const BUFFER_SECONDS := 1.0

var _player: AudioStreamPlayer = null
var _playback: AudioStreamGeneratorPlayback = null
var _mix_rate := DEFAULT_MIX_RATE


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # cues still sound while the game is paused
	_ensure_bus()
	# Headless: build NOTHING. Leaving _player/_playback null makes every public call
	# below a no-op through its existing null guard, so tests exercise the call sites
	# without an audio device and without the teardown segfault described in the
	# header. Shipping builds are never headless.
	if Platform.is_headless():
		return
	_mix_rate = _cfg_float("sfx_mix_rate", DEFAULT_MIX_RATE)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _mix_rate
	gen.buffer_length = BUFFER_SECONDS
	_player = AudioStreamPlayer.new()
	_player.bus = BUS
	_player.stream = gen
	add_child(_player)
	# ORDER MATTERS: play() first, then get_stream_playback(). See header note 2.
	_player.play()
	_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback


# True when real playback is possible (i.e. not headless and the generator is live).
# Call sites do not need this — play_beep() self-guards — but tests and diagnostics do.
func is_available() -> bool:
	return _playback != null


# Play a short decaying sine "blip" on the SFX bus. THE call to use for any cue.
#
#   frequency_hz  pitch; <= 0 means "the configured default" (sfx_beep_frequency_hz)
#   duration_sec  length;  <= 0 means "the configured default" (sfx_beep_duration_sec)
#   volume_db     OFFSET applied on top of the configured level (0.0 = as configured),
#                 so a caller can make one cue louder without restating the base level
#
# Returns true if audio was actually pushed. Safe (and false) headless, when SFX are
# disabled in config, and when the generator buffer is full — never errors, never
# blocks the caller. Idempotent in the sense that repeated calls only ever queue more
# audio; they never rebuild or invalidate the player.
func play_beep(frequency_hz := 0.0, duration_sec := 0.0, volume_db := 0.0) -> bool:
	if _playback == null:
		return false  # headless / no audio device
	var spec := beep_spec(frequency_hz, duration_sec, volume_db)
	if spec.is_empty():
		return false
	var frames := mini(int(spec["duration_sec"] * _mix_rate), _playback.get_frames_available())
	if frames <= 0:
		return false
	_playback.push_buffer(render_beep(frames, spec["frequency_hz"], _mix_rate,
		db_to_linear(spec["volume_db"]), spec["decay"]))
	return true


# Resolve a play_beep() request against config: apply the enabled gate and fill in the
# configured defaults for any argument the caller left at 0. Returns {} when nothing
# should sound at all. Split out from play_beep() so the decision is testable headless,
# where no real playback exists — audio behaviour that can only be checked with a sound
# card is audio behaviour nobody checks.
func beep_spec(frequency_hz := 0.0, duration_sec := 0.0, volume_db := 0.0) -> Dictionary:
	if not _cfg_bool("sfx_enabled", true):
		return {}
	var freq := frequency_hz if frequency_hz > 0.0 else _cfg_float(
		"sfx_beep_frequency_hz", DEFAULT_FREQUENCY_HZ)
	var dur := duration_sec if duration_sec > 0.0 else _cfg_float(
		"sfx_beep_duration_sec", DEFAULT_DURATION_SEC)
	if freq <= 0.0 or dur <= 0.0:
		return {}
	return {
		"frequency_hz": freq,
		"duration_sec": dur,
		"volume_db": _cfg_float("sfx_beep_volume_db", DEFAULT_VOLUME_DB) + volume_db,
		"decay": _cfg_float("sfx_beep_decay", DEFAULT_DECAY),
	}


# Pure DSP: one exponentially-decaying sine, as stereo frames. Static and node-free so
# the waveform is testable without an audio device. `amplitude` is linear (not dB);
# `decay` is the exponential rate per second (higher = shorter tail).
static func render_beep(frames: int, frequency_hz: float, mix_rate: float,
		amplitude: float, decay: float) -> PackedVector2Array:
	var buf := PackedVector2Array()
	if frames <= 0 or mix_rate <= 0.0:
		return buf
	buf.resize(frames)
	var phase_step := TAU * frequency_hz / mix_rate
	for i in frames:
		var t := float(i) / mix_rate
		var s := sin(phase_step * i) * amplitude * exp(-decay * t)
		buf[i] = Vector2(s, s)
	return buf


# --- Bus + config plumbing --------------------------------------------------

# Create the SFX bus if it isn't there yet, sending to Master. Idempotent, and safe
# headless (AudioServer's bus graph exists under the dummy driver; only PLAYBACK is
# unsafe there), so the bus-layout contract holds in tests too.
func _ensure_bus() -> void:
	if AudioServer.get_bus_index(BUS) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, BUS)
	AudioServer.set_bus_send(idx, "Master")


func _cfg() -> GameConfig:
	return Config.data if Config != null else null


func _cfg_float(field: String, fallback: float) -> float:
	var cfg := _cfg()
	if cfg == null:
		return fallback
	var v = cfg.get(field)
	return float(v) if v != null else fallback


func _cfg_bool(field: String, fallback: bool) -> bool:
	var cfg := _cfg()
	if cfg == null:
		return fallback
	var v = cfg.get(field)
	return bool(v) if v != null else fallback

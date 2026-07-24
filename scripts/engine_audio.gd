extends AudioStreamPlayer
# Bridges the simulated engine to audio: reads EngineSim state each frame and
# pushes synthesized PCM into an AudioStreamGenerator. The DSP lives in
# EngineAudioSynth; this node only owns the generator and the per-frame pull.

const MIX_RATE := 22050.0
# Generator buffer depth, chosen per-device (see buffer_seconds()). The fill runs
# in _process on the main thread, so the buffer is the only thing keeping audio
# alive across a slow frame: if the gap between _process calls exceeds it, the
# buffer drains and the engine note crackles/drops. On a single-threaded web TOUCH
# device (phone/tablet browser) a frame is ~33 ms at the 30 fps web cap
# (target_fps_web) before jitter/GC hitches on top, so the buffer has to bridge
# that whole gap: 0.2 s ≈ six 30 fps frames of headroom. Desktop (native, and
# desktop web at the full 60 fps cap with far fewer hitches) needs nowhere near
# that, and the buffer is pure throttle→rev latency — roughly BUFFER_SECONDS_* plus
# the WebAudio output_latency.web from project.godot — so desktop uses a much
# tighter buffer to keep the sound responsive. Terrain is precomputed at load (see
# features/terrain.md) so chunk crossings are cheap; the touch margin covers the
# sustained low frame rate plus web-export/GC hitches.
const BUFFER_SECONDS_TOUCH := 0.2    # single-threaded web on a phone: ~6 frames of 30 fps headroom
const BUFFER_SECONDS_DESKTOP := 0.05 # ~3 frames at 60 fps — responsive, still covers a hitch


# Touch devices (incl. web-touch) need the deep underrun margin; desktop (native or
# desktop web) takes the tight, low-latency buffer. Mirrors Platform.is_touch(), the
# same split the frame cap and touch-control picker use.
static func buffer_seconds() -> float:
	return BUFFER_SECONDS_TOUCH if Platform.is_touch() else BUFFER_SECONDS_DESKTOP

var _synth: EngineAudioSynth
var _playback: AudioStreamGeneratorPlayback
var _scratch := PackedVector2Array()


# The car injects an isolated GameConfig copy into its own `config` (so a prop/
# display car can't clobber the active car's tuning via the global Config.data).
# Read that copy like the rest of the physics stack. Falls back to Config.data
# when the parent's config isn't set yet — notably at _ready(), which fires
# bottom-up BEFORE the parent car's _ready() populates `config`; reconfigure()
# (called from car.apply_car once `config` is final) then rebuilds off the copy.
func _car_config() -> GameConfig:
	var parent := get_parent()
	if parent != null and parent.get("config") != null:
		return parent.config
	return Config.data


func _ready() -> void:
	var cfg: GameConfig = _car_config()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = buffer_seconds()
	stream = gen  # set the stream unconditionally (smoke test checks its type)
	_synth = EngineAudioSynth.new(cfg, MIX_RATE)
	# Headless (test/CI): set up the stream but never PLAY it. Godot's headless
	# AudioDriverDummy still runs a mix thread, and a *playing* AudioStreamGeneratorPlayback
	# (which extends AudioStreamPlaybackResampled) is freed underneath it at engine teardown
	# (-gexit) — a use-after-free that SIGSEGVs in AudioStreamPlaybackResampled::mix. A
	# stopped player is never mixed. Leaving _playback null is exactly the state
	# _timed_process()/skip_count() already guard for ("headless / no audio device"), so
	# nothing synthesizes or mixes and the per-frame DSP fill is skipped. The pure-DSP path
	# is covered by test_engine_audio (EngineAudioSynth directly). Shipping is never headless.
	if Platform.is_headless():
		return
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback


# Rebuild the synth from the current config — call after a car swap changes the
# engine (cylinder count + firing order), which the synth caches at init.
func reconfigure() -> void:
	_synth = EngineAudioSynth.new(_car_config(), MIX_RATE)


# Cumulative generator buffer underruns ("skips"): each one is a frame that drained
# the buffer before the next _process fill — i.e. an audible audio overrun. Sampled
# by the benchmark to log overruns and correlate them with slow frames
# (features/benchmark.md). 0 headless / before the device is up.
func skip_count() -> int:
	return _playback.get_skips() if _playback != null else 0


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"engine_audio", Time.get_ticks_usec() - __t)


func _timed_process(_delta: float) -> void:
	if _playback == null:
		return  # headless / no audio device
	var engine: EngineSim = get_parent().drivetrain.engine
	var n := _playback.get_frames_available()
	if n <= 0:
		return
	# Size the scratch buffer to exactly n frames so we can push it directly,
	# avoiding a per-frame slice() allocation. resize only fires when n changes.
	if _scratch.size() != n:
		_scratch.resize(n)
	var cfg: GameConfig = _car_config()
	# Proximity attenuation: quieter as the active camera moves away. Non-positional
	# player, so we drive volume_db ourselves from the squared camera distance (no
	# sqrt) through the physical 1/d curve. Never runs headless (guarded above by the
	# null _playback), so tests that instantiate the intro are unaffected.
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var d2 := cam.global_position.distance_squared_to(get_parent().global_position)
		volume_db = EngineAudioSynth.attenuation_db(
			d2, cfg.engine_audio_ref_distance_m, cfg.engine_audio_max_attenuation_db)
	# fuel_cut (limiter OR damage misfire) ducks the note; the crackle burst is
	# limiter-only (engine.limiting) — a damaged engine sputters without the pop.
	# turbo_spin normalizes the shaft speed so the whistle pitch tracks it; boost/
	# bov_event/antilag_active drive the whistle amplitude and the transient bursts.
	var turbo_spin := engine.omega_turbo / cfg.turbo_omega_ref if cfg.turbo_omega_ref > 0.0 else 0.0
	# bov_event is latched by the sim across the physics substeps; consume it here so
	# each blow-off fires exactly once and re-arms (the synth edge-detects it).
	var bov := engine.bov_event
	engine.bov_event = false
	_synth.fill(_scratch, engine.rpm(), engine.throttle, engine.shift_timer > 0.0, n, engine.fuel_cut, engine.limiting, engine.boost, turbo_spin, bov, engine.antilag_active)
	_playback.push_buffer(_scratch)

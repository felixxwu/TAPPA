extends AudioStreamPlayer
# Bridges the simulated engine to audio: reads EngineSim state each frame and
# pushes synthesized PCM into an AudioStreamGenerator. The DSP lives in
# EngineAudioSynth; this node only owns the generator and the per-frame pull.

const MIX_RATE := 22050.0
# Generator buffer depth. The fill runs in _process on the main thread, so the
# buffer is the only thing keeping audio alive across a slow frame: if the gap
# between _process calls exceeds it, the buffer drains and the engine note
# crackles/drops. On the single-threaded web build a chunk-crossing frame can be
# tens of ms, so 0.1 s left almost no headroom. 0.15 s covers the worst post-
# optimisation frame (terrain is now precomputed at load — see
# features/terrain.md — so chunk crossings are cheap cache pulls, not a
# rebuild; this margin instead covers web-export/GC hitches) with margin, while
# keeping throttle→rev audio latency low enough to still feel responsive. Raise
# toward ~0.2 if underruns persist on the weakest devices (at a little more lag).
const BUFFER_SECONDS := 0.15

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
	gen.buffer_length = BUFFER_SECONDS
	stream = gen
	_synth = EngineAudioSynth.new(cfg, MIX_RATE)
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
	# fuel_cut (limiter OR damage misfire) ducks the note; the crackle burst is
	# limiter-only (engine.limiting) — a damaged engine sputters without the pop.
	# turbo_spin normalizes the shaft speed so the whistle pitch tracks it; boost/
	# bov_event/antilag_active drive the whistle amplitude and the transient bursts.
	var cfg: GameConfig = _car_config()
	var turbo_spin := engine.omega_turbo / cfg.turbo_omega_ref if cfg.turbo_omega_ref > 0.0 else 0.0
	# bov_event is latched by the sim across the physics substeps; consume it here so
	# each blow-off fires exactly once and re-arms (the synth edge-detects it).
	var bov := engine.bov_event
	engine.bov_event = false
	_synth.fill(_scratch, engine.rpm(), engine.throttle, engine.shift_timer > 0.0, n, engine.fuel_cut, engine.limiting, engine.boost, turbo_spin, bov, engine.antilag_active)
	_playback.push_buffer(_scratch)

class_name CarPreviewAudio
extends AudioStreamPlayer
# Plays a short engine rev for the car currently highlighted in the HQ lineup, so
# the player hears each car as they flick through it. rev(engine_id) holds the
# throttle for GameConfig.preview_rev_hold_seconds on a free-revving EngineSim —
# stepped in NEUTRAL (gear 0), so the flywheel climbs against crank torque + engine
# friction with no wheels/load — then releases so the revs fall back to idle
# naturally. A fresh rev() call rebuilds from idle and flushes the buffer, so
# starting a new preview instantly cancels the one in flight.
#
# Fully self-contained: it owns its AudioStreamGenerator, EngineSim and
# EngineAudioSynth, so it needs no live physics car. EngineAudioSynth.fill() only
# wants floats + a GameConfig, mirroring scripts/engine_audio.gd.

const MIX_RATE := 22050.0
# Generator buffer depth, per-device — same rationale as engine_audio.gd (covers a
# slow frame on single-threaded web-touch; desktop takes a tight, low-latency
# buffer). Not a tuning knob. See engine_audio.gd's buffer_seconds() for the touch split.
const BUFFER_SECONDS_TOUCH := 0.15
const BUFFER_SECONDS_DESKTOP := 0.05
# Largest engine sub-step accepted per frame: clamps a stall/GC hitch so a huge
# delta can't fling the flywheel in one integration step. Not a tuning knob.
const MAX_STEP := 0.05

var _synth: EngineAudioSynth
var _playback: AudioStreamGeneratorPlayback
var _scratch := PackedVector2Array()
var _cfg: GameConfig
var _engine: EngineSim
var _hold_left := 0.0  # seconds of throttle-held rev remaining; <= 0 is the coast-down
var _active := false  # a rev is climbing or coasting back to idle


func _ready() -> void:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = BUFFER_SECONDS_TOUCH if Platform.is_touch() else BUFFER_SECONDS_DESKTOP
	stream = gen
	# Silent until the first rev() — playback starts there so nothing plays on load.


# Start (or restart) a rev for the given engine. A call mid-preview cancels the
# previous one: the engine is rebuilt from idle and the generator buffer flushed,
# so flicking the lineup plays a clean series of little revs.
#
# `owned_car` is the highlighted car's save dict (optional, {} for a bare engine
# audition): passing it applies that car's FITTED UPGRADES on top of the stock
# engine, in the same order as the fielded-car pipeline, so a turbo or supercharger
# the player bolted on is actually heard here — both its extra torque (the flywheel
# climbs harder) and its own audio layer (whistle / BOV / blower whine). Without it
# the preview would only ever play the factory engine. See features/engine-audio.md.
func rev(engine_id: String, owned_car: Dictionary = {}) -> void:
	var engine := EngineLibrary.by_id(engine_id)
	if engine.is_empty():
		return
	# Isolated config copy (like a prop car) so applying this engine can't clobber
	# the active car's tuning through the global.
	_cfg = Config.data.duplicate(true)
	EngineLibrary.apply(engine, _cfg)
	if not owned_car.is_empty():
		UpgradeLibrary.apply(owned_car, _cfg)
	_engine = EngineSim.new(_cfg)
	_engine.gear = 0  # neutral: clutch open, the flywheel revs freely (no load)
	_synth = EngineAudioSynth.new(_cfg, MIX_RATE)
	_hold_left = _cfg.preview_rev_hold_seconds
	_active = true
	# Flush any tail of the previous rev and restart the generator from empty.
	# Headless (test/CI): skip real playback — a playing generator is mixed by the
	# dummy-audio thread and freed underneath it at teardown, SIGSEGV'ing in
	# AudioStreamPlaybackResampled::mix. _advance()/state still run for tests; leaving
	# _playback null makes _process's fill a no-op (same guard as engine_audio).
	if is_inside_tree() and not Platform.is_headless():
		stop()
		play()
		_playback = get_stream_playback() as AudioStreamGeneratorPlayback


func _process(delta: float) -> void:
	if not _active:
		return
	_advance(minf(delta, MAX_STEP))
	_fill_audio()


# Step the free-revving engine one frame and walk the throttle envelope: hold at
# full throttle while time remains, then release and let engine braking pull the
# revs down until they settle back to idle, at which point the preview ends.
func _advance(h: float) -> void:
	if _hold_left > 0.0:
		_hold_left -= h
		_engine.step(h, 1.0, 0.0)
	else:
		_engine.step(h, 0.0, 0.0)
		# omega is clamped to idle by step(), so it returns to idle_rpm exactly.
		if _engine.rpm() <= _cfg.idle_rpm + 1.0:
			_active = false


func _fill_audio() -> void:
	if _playback == null:
		return  # headless / no audio device
	var n := _playback.get_frames_available()
	if n <= 0:
		return
	if _scratch.size() != n:
		_scratch.resize(n)
	var turbo_spin := _engine.omega_turbo / _cfg.turbo_omega_ref if _cfg.turbo_omega_ref > 0.0 else 0.0
	var bov := _engine.bov_event
	_engine.bov_event = false
	# Raw `boost`, deliberately NOT EngineSim.boost_reading(): this argument drives the
	# turbo WHISTLE and blow-off valve, layers a supercharged car does not have (its whine
	# is rpm-pitched, and install_supercharger clears turbo_enabled so neither can fire).
	# Feeding belt boost in would make a blown car whistle and vent like a turbo.
	# The nitrous args are hard-FALSE for the same class of reason: rev() applies the
	# highlighted car's fitted upgrades, so a nitrous-equipped car HAS nitrous in this
	# config — but nobody is pressing the button in the garage. The hiss layer is gated
	# on the DELIVERY state, not on nitrous being fitted, so the preview stays silent.
	_synth.fill(_scratch, _engine.rpm(), _engine.throttle, _engine.shift_timer > 0.0, n, _engine.fuel_cut, _engine.limiting, _engine.boost, turbo_spin, bov, _engine.antilag_active, false, false, false)
	_playback.push_buffer(_scratch)

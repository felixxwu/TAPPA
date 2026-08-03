extends AudioStreamPlayer
# Bridges the simulated engine to audio: reads EngineSim state each frame and
# pushes synthesized PCM into an AudioStreamGenerator. The DSP lives in
# EngineAudioSynth; this node only owns the generator and the per-frame pull.

# Base (full-rate) synth mix rate. Every target runs at this EXCEPT a web TOUCH
# device, which resolves a lower rate through GameConfig.engine_mix_rate_for() —
# the synth is a per-sample GDScript loop, so its CPU cost is proportional to the
# mix rate, not the frame rate. Always go through the resolver (never branch on
# Platform here) so the project keeps ONE notion of "mobile".
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
var _scratch_silent := false  # true while _scratch holds the all-zero silence buffer

# Resolved-once references for the per-frame fill. Walking the parent chain (and the
# dynamic string-keyed `get("config")` in _car_config()) every frame is exactly the
# per-frame node-walking this project bans on low-end mobile; the car, its engine and
# its config only change at spawn / car swap, and every one of those paths already
# calls reconfigure() (car.gd `_reconfigure_engine_audio`), so that's where we refresh.
var _car: Node3D
var _engine: EngineSim
var _cfg: GameConfig
# The active camera CAN legitimately change at runtime (chase ↔ free-roam ↔ replay), so
# it's check-and-update rather than cache-once: compare the viewport's current camera to
# the cached one and only re-seat when it actually differs.
var _cam: Camera3D
# Effective mix rate for this device, resolved once per (re)configure.
var _mix_rate := MIX_RATE


# Mix rate the synth and the generator run at on this device. Pure pass-through to
# the config resolver so web-touch is the only branch and it lives in one place.
func _resolve_mix_rate(cfg: GameConfig) -> float:
	if cfg == null:
		return MIX_RATE
	return cfg.engine_mix_rate_for(Platform.is_web(), Platform.is_touch(), MIX_RATE)


# Re-resolve the cached car / engine / config. Safe to call before the parent car's
# _ready() has run (drivetrain is still null then) — the per-frame path re-resolves
# lazily until the real references exist.
func _resolve_refs() -> void:
	_car = get_parent() as Node3D
	_cfg = _car_config()
	_engine = _car.drivetrain.engine if _car != null and _car.get("drivetrain") != null else null


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
	# Route through the dedicated "Engine" bus (created by MusicDirector._ready,
	# an autoload that's always ready before this node — see
	# music_director.gd _ensure_engine_bus) so the whole engine mix can be muted
	# with one AudioServer call while a loading screen is up (music_director.gd
	# _apply_engine_mute) without touching Music/Master or threading a flag through
	# every EngineAudio instance. Harmless if the bus doesn't exist yet (falls back
	# to Master) and irrelevant headless, where play() is never called below.
	bus = &"Engine"
	_resolve_refs()
	var cfg: GameConfig = _cfg
	_mix_rate = _resolve_mix_rate(cfg)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = _mix_rate
	gen.buffer_length = buffer_seconds()
	stream = gen  # set the stream unconditionally (smoke test checks its type)
	_synth = EngineAudioSynth.new(cfg, _mix_rate)
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
	_resolve_refs()
	var rate := _resolve_mix_rate(_cfg)
	# The car injects its own GameConfig copy, so the resolved rate CAN change on a
	# swap. The generator's mix_rate is baked into the live playback, so re-seat the
	# stream when (and only when) it actually differs — a swap is already an audible
	# discontinuity, whereas a synth running at a rate the generator doesn't share
	# would be permanently detuned.
	if not is_equal_approx(rate, _mix_rate):
		_mix_rate = rate
		var gen := stream as AudioStreamGenerator
		if gen != null:
			gen.mix_rate = rate
		if _playback != null:
			play()
			_playback = get_stream_playback() as AudioStreamGeneratorPlayback
	_synth = EngineAudioSynth.new(_cfg, _mix_rate)


# Cumulative generator buffer underruns ("skips"): each one is a frame that drained
# the buffer before the next _process fill — i.e. an audible audio overrun. Sampled
# by the benchmark to log overruns and correlate them with slow frames
# (features/benchmark.md). 0 headless / before the device is up.
func skip_count() -> int:
	return _playback.get_skips() if _playback != null else 0


# True when the proximity attenuation has bottomed out at its floor, i.e. the voice
# is at the quietest level the curve can produce and synthesizing it is pointless.
# The small epsilon keeps this a "reached the clamp" test rather than an exact
# float compare. Pure/static so it's testable without an audio device.
static func is_audio_inaudible(vol_db: float, floor_db: float) -> bool:
	return vol_db <= floor_db + 0.001


# Fill the scratch buffer with silence and push it. Keeps the generator fed (an
# unfed buffer underruns and crackles) at a fraction of the cost of a real fill.
# The scratch is only re-zeroed on the transition into silence — once it's all
# zeros it stays that way while we keep taking this path.
# Takes no frame count: the caller has already sized _scratch to exactly n frames
# (see the resize in _timed_process) before reaching either fill path.
func _push_silence() -> void:
	if not _scratch_silent:
		_scratch.fill(Vector2.ZERO)
		_scratch_silent = true
	_playback.push_buffer(_scratch)


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"engine_audio", Time.get_ticks_usec() - __t)


func _timed_process(_delta: float) -> void:
	if _playback == null:
		return  # headless / no audio device
	if _engine == null:
		_resolve_refs()  # parent car wasn't built yet at our _ready(); resolve on first use
		if _engine == null:
			return
	var engine: EngineSim = _engine
	var n := _playback.get_frames_available()
	if n <= 0:
		return
	# Size the scratch buffer to exactly n frames so we can push it directly,
	# avoiding a per-frame slice() allocation. resize only fires when n changes.
	if _scratch.size() != n:
		_scratch.resize(n)
		_scratch_silent = false  # a grown buffer keeps its old (non-zero) head samples
	var cfg: GameConfig = _cfg
	# Proximity attenuation: quieter as the active camera moves away. Non-positional
	# player, so we drive volume_db ourselves from the squared camera distance (no
	# sqrt) through the physical 1/d curve. Never runs headless (guarded above by the
	# null _playback), so tests that instantiate the intro are unaffected.
	var cur := get_viewport().get_camera_3d()
	if cur != _cam:
		_cam = cur  # check-and-update: only re-seat when the active camera actually changed
	if _cam != null and _car != null:
		var d2 := _cam.global_position.distance_squared_to(_car.global_position)
		# During the start-line REVEAL sequence, tighten the radius for cars waiting
		# behind the reveal-card focus car (see engine_audio_ref_distance_reveal_m):
		# the queue spacing is smaller than the normal radius, so every queued car
		# otherwise sits at/near full volume at once. The focus car itself (the one
		# on the card, closest to the anchored camera) is exempted so it keeps
		# sounding exactly as it did before this change; a car that has actually
		# launched is never in _grid any more, so its normal falloff is untouched.
		var ref_dist := cfg.engine_audio_ref_distance_m
		var sl := StartLine.active_instance
		if sl != null and _car != sl.reveal_focus_car() and sl.sequence_phase() == StartLine.Seq.REVEAL:
			ref_dist = cfg.engine_audio_ref_distance_reveal_m
		volume_db = EngineAudioSynth.attenuation_db(
			d2, ref_dist, cfg.engine_audio_max_attenuation_db)
	# Far enough away that attenuation has pinned the level to its floor: the synth
	# output is inaudible, so paying the per-sample DSP for it is wasted CPU. Push
	# silence instead and skip the fill entirely. Matters wherever several cars are
	# alive but distant — the start line, and the opponent wreck out on the stage.
	# The buffer still has to be pushed (an unfed generator underruns), and the
	# latched bov_event still has to be consumed so the sim re-arms.
	if is_audio_inaudible(volume_db, cfg.engine_audio_max_attenuation_db):
		_push_silence()
		engine.bov_event = false
		return
	# fuel_cut (limiter OR damage misfire) ducks the note; the crackle burst is
	# limiter-only (engine.limiting) — a damaged engine sputters without the pop.
	# turbo_spin normalizes the shaft speed so the whistle pitch tracks it; boost/
	# bov_event/antilag_active drive the whistle amplitude and the transient bursts.
	var turbo_spin := engine.omega_turbo / cfg.turbo_omega_ref if cfg.turbo_omega_ref > 0.0 else 0.0
	# bov_event is latched by the sim across the physics substeps; consume it here so
	# each blow-off fires exactly once and re-arms (the synth edge-detects it).
	var bov := engine.bov_event
	engine.bov_event = false
	# Raw `boost`, deliberately NOT EngineSim.boost_reading(): this argument drives the
	# turbo WHISTLE and blow-off valve, layers a supercharged car does not have (its whine
	# is rpm-pitched, and install_supercharger clears turbo_enabled so neither can fire).
	# Feeding belt boost in would make a blown car whistle and vent like a turbo.
	_synth.fill(_scratch, engine.rpm(), engine.throttle, engine.shift_timer > 0.0, n, engine.fuel_cut, engine.limiting, engine.boost, turbo_spin, bov, engine.antilag_active)
	_scratch_silent = false
	_playback.push_buffer(_scratch)

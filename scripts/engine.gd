class_name EngineSim
extends RefCounted
# Engine flywheel + gearbox + clutch, owned by Drivetrain and stepped inside
# its spin substeps. The crank torque comes from a curve over RPM; the clutch
# couples the flywheel to the rear axle through the selected ratio. There is
# no stalling: omega is clamped to idle, and the auto-clutch opens when
# coasting slowly, during shifts, and when the gearbox input over-revs.

# Seconds over which a clutch dump may convert the flywheel's speed margin
# above idle into drive torque (model stability constant, not a tuning knob).
const FLYWHEEL_DRAIN_TIME := 0.3

# Boost above which snapping the throttle shut vents the blow-off valve.
const BOV_BOOST_THRESHOLD := 0.3

var omega := 0.0  # rad/s engine flywheel speed
var gear := 1  # -1 = reverse, 0 = neutral, 1..N forward
var auto := false  # automatic gearbox (picks the gear from the airspeed)
var shift_timer := 0.0  # seconds of clutch-open throttle cut left in a shift
var throttle := 0.0  # last drive request seen by step(), for the audio synth
var limiting := false  # rev-limiter fuel cut latched on (see _update_limiter)
# Combined fuel-cut state (rev limiter OR a damage misfire) for the audio synth:
# while true, combustion has stopped this substep — the note ducks and crackles.
var fuel_cut := false
# Turbo shaft state (features/forced-induction.md). omega_turbo integrates against
# turbo_inertia in step(); boost = (omega_turbo/omega_ref)^2 multiplies delivered
# torque. Zero and inert on an NA engine (config.turbo_enabled false). The audio
# bridge reads boost/omega_turbo/bov_event/antilag_active for the whistle + bursts.
var omega_turbo := 0.0  # rad/s turbo shaft speed
var boost := 0.0  # 0..1 boost fraction
var bov_event := false  # set the substep a blow-off vents (lift while boosted)
var antilag_active := false  # true while anti-lag bangs (off-throttle, still boosted)
# Supercharger belt boost (0..1). Unlike the turbo this carries NO state — being
# crank-driven it is a pure function of the current rpm, recomputed every substep
# and inert (0) whenever supercharger_boost_gain is 0. See forced-induction.md.
var sc_boost := 0.0
# Nitrous (features/nitrous.md). A per-STAGE resource: reset() refills the tank, so
# every stage start and every reset-to-start begins full and there is no spent state to
# carry or exploit. `nitrous_active` is written each tick by car.gd from the `nitrous`
# action; step() multiplies delivered torque by (1 + nitrous_boost_gain) while it is
# held and the tank has charge, draining nitrous_charge by the substep. The audio bridge
# reads nitrous_delivering / nitrous_event / nitrous_emptied for the hiss and its cues.
var nitrous_charge := 0.0    # seconds of nitrous left in the tank
var nitrous_active := false  # driver is holding the nitrous action this tick
# Whether nitrous is actually DELIVERING right now — held AND charged AND combusting.
# Latched (not per-substep) so the audio bridge and any other reader share the ONE
# definition in _step_nitrous rather than re-deriving a subtly different one: holding the
# button off-throttle or under a fuel cut delivers no torque and drains nothing, so it must
# not make a sound either.
var nitrous_delivering := false
var nitrous_event := false   # set the substep nitrous STARTS delivering (trigger crack)
var nitrous_emptied := false # set the substep the tank runs dry (cutoff cue)
var _prev_nitrous := false   # for the nitrous_event edge
# config.has_nitrous() cached at _init/reset(), so step() pays one bool check instead of a
# call and two property reads per substep — the same treatment the supercharger's `blown`
# gets. reset() runs on every stage start and reset-to-start, which is when the config can
# have been re-applied for a different car.
#
# SCOPE: this is a per-SUBSTEP optimisation only. Per-frame readers (nitrous_fraction, and so
# the HUD gauge and audio) deliberately go to the live config instead, so a refit between
# resets can never leave them showing a stale reading.
var _has_nitrous := false
var _prev_throttle := 0.0  # for the blow-off lift edge
var _prev_shifting := false  # for the blow-off shift edge (driver lifts to change gear)
# Damage fraction 0..1 (0 = healthy), set each tick by car.gd. Drives the stochastic
# misfire below — a damaged engine cuts fuel in stumbling bursts, more often with
# damage and under load. Replaces the old smooth power derate. See features/damage.md.
var misfire_level := 0.0
var _misfire_timer := 0.0  # seconds left in the current damage fuel-cut (0 = firing)
# Monotonic count of damage misfire cut ONSETS (not the rev limiter). EngineSmoke
# reads the delta each frame to puff a burst of smoke per cut. See features/engine-smoke.md.
var misfire_count := 0
# Monotonic count of REV-LIMITER cut onsets (not the damage misfire above). The
# limiter cut is the one that pops unburnt fuel in the exhaust, so it is what both the
# audio crackle burst and the exhaust flame key off — a damaged engine stumbles without
# a bang. ExhaustFlames reads the delta each frame, exactly as EngineSmoke reads
# misfire_count. See features/exhaust-flames.md.
var limiter_cut_count := 0
# Own RNG so misfires are reproducible in tests (set _rng.seed) and each car instance
# stumbles independently. Randomised at runtime in _init.
var _rng := RandomNumberGenerator.new()
# Per-gear upshift airspeeds (m/s), one per forward gear. shift_up_speeds[g-1]
# is the forward ground speed at which gear g nears redline; the box upshifts
# on reaching it. The top gear's slot is INF.
var shift_up_speeds: Array[float] = []

# The car's config (config for the active car, an isolated copy for prop cars),
# injected by Drivetrain so a second car instance can't clobber this engine's tuning
# through the shared global. See car.gd `config`.
var config: GameConfig


func _init(p_config: GameConfig) -> void:
	config = p_config
	omega = idle_omega()
	auto = config.auto_gearbox
	# Seed the cached gate here as well as in reset(): _init does not call reset(), so a
	# freshly built engine stepped before its first reset would otherwise read as unfitted.
	_has_nitrous = config.has_nitrous()
	nitrous_charge = config.nitrous_tank_seconds if _has_nitrous else 0.0
	# In benchmark mode use a fixed seed so misfires (and their smoke FX) repeat
	# identically run-to-run; otherwise randomise so each car instance stumbles
	# independently in normal play. See features/benchmark.md.
	if Benchmark.active:
		_rng.seed = Benchmark.RNG_SEED
	else:
		_rng.randomize()
	_compute_shift_speeds()


func idle_omega() -> float:
	return config.idle_rpm * TAU / 60.0


func redline_omega() -> float:
	return config.redline_rpm * TAU / 60.0


func rpm() -> float:
	return omega * 60.0 / TAU


# Total drive ratio engine -> rear axle: negative in reverse, zero in neutral
# (where the clutch is open and no torque reaches the wheels).
func ratio() -> float:
	var cfg: GameConfig = config
	if gear < 0:
		return -cfg.reverse_ratio * cfg.final_drive
	if gear == 0:
		return 0.0
	return cfg.gear_ratios[gear - 1] * cfg.final_drive


# Manual sequential shift by one position through R - N - 1 - 2 ... N.
func request_shift(direction: int) -> void:
	if shift_timer > 0.0:
		return
	var target := clampi(gear + direction, -1, config.gear_ratios.size())
	if target == gear:
		return
	gear = target
	shift_timer = config.shift_time


# Automatic gearbox: keep a sensible forward gear for the vehicle's forward
# airspeed (m/s), NOT the engine revs — wheelspin spikes the revs without
# moving the car, which would climb the gears unnecessarily. Each gear's shift
# point is the speed at which it nears redline, with a hysteresis dead band on
# the way down. Direction (reverse vs forward) is still chosen by select_*.
func update_auto(throttle_in: float, airspeed: float) -> void:
	if shift_timer > 0.0:
		return
	if gear == 0:
		gear = 1  # an automatic never idles in neutral
		return
	if gear < 1:
		return  # reverse holds until select_forward swaps it
	var n: int = config.gear_ratios.size()
	if gear < n and airspeed > shift_up_speeds[gear - 1] and throttle_in > 0.1:
		request_shift(1)
	elif gear > 1 and airspeed < _downshift_speed(gear):
		request_shift(-1)


# The airspeed below which gear g drops to g-1: the lower pair's upshift
# crossover, pulled down by the hysteresis fraction to open a dead band.
func _downshift_speed(g: int) -> float:
	return shift_up_speeds[g - 2] * (1.0 - config.shift_hysteresis)


# Precompute each gear's upshift airspeed: the ground speed at which the gear
# reaches upshift_redline_fraction of redline rpm (no-slip). Kept below the
# rev-limiter speed so the car always reaches it despite wheel slip; the top
# gear never upshifts, so its slot is INF.
func _compute_shift_speeds() -> void:
	var cfg: GameConfig = config
	var n: int = cfg.gear_ratios.size()
	shift_up_speeds = []
	shift_up_speeds.resize(n)
	shift_up_speeds[n - 1] = INF
	for g in range(1, n):
		var gr: float = cfg.gear_ratios[g - 1] * cfg.final_drive
		var redline_v := redline_omega() / gr * cfg.wheel_radius
		shift_up_speeds[g - 1] = redline_v * cfg.upshift_redline_fraction


# Gear direction changes only happen near standstill. Returns whether the
# requested direction is selected (drive torque must not flow otherwise).
func select_reverse(rear_omega: float) -> bool:
	if gear >= 0 and absf(rear_omega) * config.wheel_radius < 1.0:
		gear = -1
	return gear < 0


func select_forward(rear_omega: float) -> bool:
	if gear < 1 and absf(rear_omega) * config.wheel_radius < 1.0:
		gear = 1
	return gear >= 1


# Resolve nitrous delivery for this substep and drain the tank. Only called when nitrous is
# FITTED (the caller checks `_has_nitrous`). `combusting` is whether the engine is actually
# making torque (throttle open, not mid-shift, not fuel-cut) — nitrous only flows when it
# would do something, so the tank can't be dumped off-throttle.
# Sets nitrous_event on the delivery edge and nitrous_emptied on the substep the tank
# runs dry; both are one-substep flags the audio bridge consumes. Returns whether the
# torque multiplier applies.
func _step_nitrous(h: float, combusting: bool) -> bool:
	nitrous_event = false
	nitrous_emptied = false
	var on := nitrous_active and combusting and nitrous_charge > 0.0
	if on:
		nitrous_event = not _prev_nitrous
		nitrous_charge = maxf(nitrous_charge - h, 0.0)
		nitrous_emptied = nitrous_charge <= 0.0
	_prev_nitrous = on
	nitrous_delivering = on
	return on


# Nitrous left as a 0..1 fraction of a full tank — the HUD gauge reading. 0 when no
# nitrous is fitted (the gauge is hidden in that case; see hud.gd).
func nitrous_fraction() -> float:
	# Reads the LIVE config, not the cached _has_nitrous. This runs per FRAME (the HUD gauge
	# and the audio bridge), not per substep, so the two property reads are free — and using
	# the cache here would show a stale gauge after any live refit that re-applies the config
	# without a reset(), as well as risking a divide by a zero tank.
	var tank := config.nitrous_tank_seconds
	if tank <= 0.0 or config.nitrous_boost_gain <= 0.0:
		return 0.0
	return clampf(nitrous_charge / tank, 0.0, 1.0)


# Re-read the config-derived fitment caches after something has REWRITTEN the live config
# under a already-built engine (car.gd's apply_owned / _rederive_live_config: the upgrade
# layer runs after the drivetrain is constructed, so nitrous is installed *after* _init has
# already cached "not fitted"). Without this the per-substep gate stays stale-false and a
# fitted nitrous is silently dead until the next reset() — which staging happens to provide
# for a rally, but free roam does not.
#
# Deliberately NOT reset(): this can run on a live body, so it must not touch omega, gear or
# the tank's current charge. It only re-derives the gate, and tops up a tank that has just
# appeared (a newly fitted nitrous starts full, like any stage start).
func refresh_fitment() -> void:
	var was_fitted := _has_nitrous
	_has_nitrous = config.has_nitrous()
	if _has_nitrous and not was_fitted:
		nitrous_charge = config.nitrous_tank_seconds
	elif not _has_nitrous:
		nitrous_charge = 0.0
		nitrous_delivering = false


func reset() -> void:
	omega = idle_omega()
	gear = 1
	shift_timer = 0.0
	limiting = false
	fuel_cut = false
	_misfire_timer = 0.0
	omega_turbo = 0.0
	boost = 0.0
	sc_boost = 0.0
	bov_event = false
	antilag_active = false
	# A full tank at every stage start AND every reset-to-start (car.gd reset_to calls
	# this) — the deliberate "no spent state" rule, so there is nothing to savescum.
	_has_nitrous = config.has_nitrous()
	nitrous_charge = config.nitrous_tank_seconds if _has_nitrous else 0.0
	nitrous_active = false
	nitrous_delivering = false
	nitrous_event = false
	nitrous_emptied = false
	_prev_nitrous = false
	_prev_throttle = 0.0
	_prev_shifting = false


# One substep of length h: integrates the flywheel against crank and clutch
# torque and returns the clutch torque as seen at the wheels (N·m). throttle
# is the 0..1 drive request; reverse comes from the gear's sign. driveline_omega
# is the driven axle(s)' spin (rear for RWD, front for FWD, mean for AWD).
func step(h: float, throttle_in: float, driveline_omega: float, declutch := false) -> float:
	throttle = throttle_in
	var cfg: GameConfig = config
	shift_timer = maxf(shift_timer - h, 0.0)
	# Combustion stops this substep if the rev limiter OR a damage misfire cuts fuel.
	fuel_cut = _update_limiter(cfg) or _update_misfire(cfg, h)
	# Always-on engine friction (pumping/viscous losses), affine in RPM the way
	# FMEP is fit on real engines: a constant breakaway term plus a slope that
	# grows with revs. The torque curve is treated as GROSS (indicated) output,
	# so this is subtracted on every path — off throttle and fuel-cut it IS the
	# engine braking (now larger at high revs), which lets the revs bounce off
	# the limiter; the no-stall idle clamp below still holds the bottom.
	# A fitted turbo adds a CONSTANT parasitic drag (backpressure/pumping loss), sized by
	# the turbo — always-on, not gated on boost or rpm. Off boost it just bogs the engine;
	# once boost is up the delivered torque swamps it. Big turbo + small engine = big
	# fraction of peak torque, so it struggles to climb the low range. See forced-induction.md.
	# A belt-driven supercharger instead costs drag that GROWS with rpm (it takes more
	# to spin the faster it turns) — the mirror image of the turbo's constant term. Both
	# the drag and the boost are skipped outright on an engine with no blower fitted, so
	# an NA/turbo car pays one bool check rather than a call and a divide per substep.
	#
	# rpm() is hoisted once here and reused for the whole substep: omega is not touched
	# again until the integration at the very bottom, so every reader below would compute
	# the same value, and this runs 8 substeps x 60 Hz per car.
	var r := rpm()
	var blown := cfg.has_supercharger_physics()
	var friction := (
		cfg.engine_friction_base
		+ cfg.engine_friction_slope * r / 1000.0
		+ cfg.turbo_parasitic_friction
		+ (supercharger_parasitic(r, cfg.supercharger_parasitic_coef) if blown else 0.0)
	)
	var crank := -friction
	# Turbo: integrate the shaft (real inertia) and derive boost BEFORE building
	# crank torque, so the boost multiplier reflects this substep. NA engines skip it.
	_step_turbo(cfg, h, throttle_in)
	# Belt boost is stateless — straight off this substep's rpm, no spool.
	sc_boost = supercharger_boost_fraction(r, cfg.supercharger_rpm_ref) if blown else 0.0
	# Whether combustion is making torque this substep — hoisted because both the nitrous
	# gate and the crank-torque block below need it, and this runs 8 substeps x 60 Hz per car.
	var combusting := throttle > 0.001 and shift_timer <= 0.0 and not fuel_cut
	# Nitrous: resolve + drain BEFORE the crank torque so the multiplier and the audio cues
	# reflect this substep. Gated on the same combustion conditions as the torque below —
	# holding the button off-throttle or under a fuel cut delivers nothing and so must not
	# drain the tank. Skipped outright on a car with no nitrous fitted, so it pays one bool
	# check rather than a call and two property reads per substep (as with `blown` above).
	var nitrous_on := _step_nitrous(h, combusting) if _has_nitrous else false
	if combusting:
		# global_torque_scale is a hidden global de-rate: it scales the torque the
		# engine actually delivers without altering cfg.peak_torque, so the stats
		# panel still shows the full published figure while every car is dialled back.
		# The turbo multiplies delivered torque by boost_torque_factor(): a shaping
		# exponent (turbo_boost_response) bends the delivery toward full spool so lag
		# is felt (see features/forced-induction.md); response 1.0 = the old linear gain.
		# The two forced-induction paths MULTIPLY, but the turbo and supercharger parts
		# share one upgrade slot so in practice only one is ever non-unity.
		# Nitrous multiplies on top of both induction paths — it is a separate system
		# (a chemical charge, not compressed air), so it stacks rather than sharing a slot.
		crank += (
			throttle * cfg.peak_torque * cfg.global_torque_scale * _torque_fraction(r)
			* boost_torque_factor(boost, cfg.turbo_boost_gain, cfg.turbo_boost_response)
			* (1.0 + sc_boost * cfg.supercharger_boost_gain)
			* ((1.0 + cfg.nitrous_boost_gain) if nitrous_on else 1.0)
		)

	var gr := ratio()
	var input_omega := driveline_omega * gr
	var engaged := (
		gear != 0  # neutral: clutch fully open, the engine revs freely
		and not declutch  # handbrake held: open the clutch so the engine can rev
		and shift_timer <= 0.0
		and absf(input_omega) < redline_omega() * 1.05
		and (throttle_in > 0.001 or absf(driveline_omega) * cfg.wheel_radius > cfg.clutch_engage_speed)
	)
	var clutch_torque := 0.0
	if engaged:
		# Torque that would zero the engine<->input slip within one substep,
		# given both sides' inertias (same stability trick as the tire model),
		# clamped to what the clutch can hold.
		var slip := omega - input_omega
		var lock := slip / (h * (1.0 / cfg.engine_inertia + gr * gr / cfg.axle_inertia))
		clutch_torque = clampf(lock, -cfg.clutch_max_torque, cfg.clutch_max_torque)
		# The no-stall idle clamp must not become a free torque source: the
		# clutch can never drain more than the crank produces plus the
		# flywheel's margin above idle (released over FLYWHEEL_DRAIN_TIME, not
		# one substep, or the clamp still pumps unbounded energy). This is
		# what makes a high-gear standstill launch bog instead of spinning
		# the wheels: at idle, drive torque is capped at crank torque.
		var sustainable := crank + (omega - idle_omega()) * cfg.engine_inertia / FLYWHEEL_DRAIN_TIME
		clutch_torque = minf(clutch_torque, maxf(sustainable, 0.0))

	omega += (crank - clutch_torque) / cfg.engine_inertia * h
	omega = clampf(omega, idle_omega(), redline_omega() * 1.02)
	return clutch_torque * gr


# Bouncing rev limiter with hysteresis: latch the fuel cut ON at redline and
# OFF only once the revs fall a full band below it. While latched, step() makes
# no crank torque, so engine braking pulls the revs down through the band until
# fuel restores and they climb again — the engine bounces off the limit.
func _update_limiter(cfg: GameConfig) -> bool:
	var band_omega := cfg.rev_limiter_band * TAU / 60.0
	if omega >= redline_omega():
		if not limiting:
			limiter_cut_count += 1  # ONSET only — one bang per bounce off the limiter
		limiting = true
	elif omega <= redline_omega() - band_omega:
		limiting = false
	return limiting


# Damage misfire cut rate (cuts/second): 0 on a healthy engine, climbing with the
# damage fraction and with engine load. `bias` (0..1) is how much fires regardless
# of load — the rest is scaled by `load` (a 0..1 throttle/rpm blend). Pure/static so
# the maths is unit-testable without pinning the authored config values.
static func misfire_rate(level: float, load_frac: float, rate_max: float, bias: float) -> float:
	if level <= 0.0:
		return 0.0
	var load_factor := bias + (1.0 - bias) * clampf(load_frac, 0.0, 1.0)
	return rate_max * clampf(level, 0.0, 1.0) * load_factor


# --- Turbo shaft maths (pure, unit-testable; wired into step() below) --------
# Boost pressure fraction from shaft speed: centrifugal compressor pressure rises
# with the square of speed, saturating at 1.0 (the fitted turbo's design ceiling).
static func boost_fraction(turbo_omega: float, omega_ref: float) -> float:
	if omega_ref <= 0.0:
		return 0.0
	var r := turbo_omega / omega_ref
	return clampf(r * r, 0.0, 1.0)


# Turbo torque multiplier applied to the NA torque: 1 + boost^response * gain. The
# response exponent shapes HOW the gain arrives across the boost range while leaving the
# endpoints fixed (0 boost -> 1, full boost -> 1 + gain): response 1.0 is the old linear
# gain; response > 1 makes a partially-spooled turbo deliver disproportionately little
# power (lag felt more) without changing peak power. Pure/static so it's unit-testable.
static func boost_torque_factor(boost_frac: float, gain: float, response: float) -> float:
	return 1.0 + pow(clampf(boost_frac, 0.0, 1.0), maxf(response, 0.0)) * gain


# THE forced-induction reading (0..1) for anything that wants "how much boost is this
# engine making right now" — a gauge, telemetry, a second readout. Turbo and supercharger
# share the one "turbo" upgrade slot, so at most one of the two is ever non-zero and the
# max is simply whichever is live.
#
# NOTE the audio bridges (engine_audio.gd / car_preview_audio.gd) deliberately pass the
# raw `boost` field instead: it drives the turbo WHISTLE and blow-off valve, layers a
# blown car does not have (install_supercharger clears turbo_enabled precisely so they
# cannot fire). Feeding belt boost in would make a supercharged car whistle and vent like
# a turbo. The supercharger's own whine is rpm-pitched, not boost-driven.
func boost_reading() -> float:
	return maxf(boost, sc_boost)


# Belt boost fraction: LINEAR in rpm, saturating at 1.0 from rpm_ref up. A positive-
# displacement blower is geared to the crank, so its pressure ratio tracks engine speed
# directly — there is no shaft to spool, hence no inertia, no lag and no threshold.
static func supercharger_boost_fraction(engine_rpm: float, rpm_ref: float) -> float:
	if rpm_ref <= 0.0:
		return 0.0
	return clampf(engine_rpm / rpm_ref, 0.0, 1.0)


# Belt drag on the crank (N·m), affine in rpm the way the base engine friction is: the
# coefficient is authored per 1000 rpm. Grows with revs, unlike turbo backpressure.
static func supercharger_parasitic(engine_rpm: float, coef: float) -> float:
	return coef * maxf(engine_rpm, 0.0) / 1000.0


# Exhaust energy available to spin the shaft: proportional to mass flow (throttle *
# rpm). Anti-lag injects a residual drive floor off-throttle so the shaft stays lit.
static func turbo_exhaust_drive(engine_rpm: float, throttle_in: float, drive_gain: float, antilag: bool, antilag_drive: float) -> float:
	var drive := drive_gain * clampf(throttle_in, 0.0, 1.0) * maxf(engine_rpm, 0.0)
	if antilag:
		drive = maxf(drive, antilag_drive)
	return drive


# Net angular acceleration of the shaft: (exhaust drive − ω² bearing/aero drag) / inertia.
static func turbo_shaft_accel(exhaust_drive: float, turbo_omega: float, drag_coef: float, inertia: float) -> float:
	var drag := drag_coef * turbo_omega * turbo_omega
	return (exhaust_drive - drag) / maxf(inertia, 1.0e-9)


# Stochastic damage misfire: while a cut is in progress hold it (returning true) until
# its rolled duration elapses; otherwise roll each substep to START a cut with
# probability rate*h, so the frequency is framerate-independent. A healthy engine
# (misfire_level 0) never cuts. Biased to fire more under load/high revs.
func _update_misfire(cfg: GameConfig, h: float) -> bool:
	if misfire_level <= 0.0:
		_misfire_timer = 0.0
		return false
	if _misfire_timer > 0.0:
		_misfire_timer -= h
		return _misfire_timer > 0.0
	var load_frac := 0.5 * clampf(throttle, 0.0, 1.0) + 0.5 * clampf(rpm() / cfg.redline_rpm, 0.0, 1.0)
	var rate := misfire_rate(misfire_level, load_frac, cfg.damage_misfire_rate_max, cfg.damage_misfire_load_bias)
	if _rng.randf() < rate * h:
		_misfire_timer = _rng.randf_range(cfg.damage_misfire_duration_min, cfg.damage_misfire_duration_max)
		misfire_count += 1
		return true
	return false


# Fraction of peak_torque available at the given RPM: 70% at zero, full at
# the peak, tapering to 70% at redline, hard cut (rev limiter) above.
func _torque_fraction(at_rpm: float) -> float:
	var cfg: GameConfig = config
	if at_rpm >= cfg.redline_rpm:
		return 0.0
	if at_rpm <= cfg.peak_torque_rpm:
		return lerpf(0.7, 1.0, at_rpm / cfg.peak_torque_rpm)
	return lerpf(
		1.0, 0.7,
		(at_rpm - cfg.peak_torque_rpm) / (cfg.redline_rpm - cfg.peak_torque_rpm)
	)


# Advance the turbo shaft one substep and update boost + audio-signal flags.
# omega_turbo integrates (exhaust_drive − ω² drag) / inertia; boost = (ω/ω_ref)².
# Lag, boost threshold, mid-range surge and off-throttle bleed all fall out of this.
func _step_turbo(cfg: GameConfig, h: float, throttle_in: float) -> void:
	if not cfg.turbo_enabled:
		omega_turbo = 0.0
		boost = 0.0
		antilag_active = false
		_prev_throttle = throttle_in
		return
	# Exhaust flow follows COMBUSTION, not the pedal: mid-shift the clutch is open and
	# fuel is cut (`combusting` in step()), so there is nothing coming out of the ports to
	# spin the shaft — an automatic upshift must bleed boost exactly as if the driver had
	# lifted, not keep spooling because the throttle input is still held. Anti-lag is the
	# one thing that holds boost through a shift, and it still does: its residual drive is
	# a floor inside turbo_exhaust_drive, independent of throttle.
	var exhaust_throttle := 0.0 if shift_timer > 0.0 else throttle_in
	var drive := turbo_exhaust_drive(rpm(), exhaust_throttle, cfg.turbo_drive_gain, cfg.turbo_antilag, cfg.turbo_antilag_drive)
	omega_turbo = maxf(omega_turbo + turbo_shaft_accel(drive, omega_turbo, cfg.turbo_drag_coef, cfg.turbo_inertia) * h, 0.0)
	boost = boost_fraction(omega_turbo, cfg.turbo_omega_ref)
	# Blow-off: venting the dump valve while boosted. Two triggers, both LATCHED
	# (not cleared per-substep) — the engine steps 8x per physics tick but the audio
	# bridge samples once per rendered frame, so a single-substep pulse would be
	# missed; engine_audio.gd consumes + clears it.
	#   1. A throttle lift (snap shut) while on boost.
	#   2. The START of a gear shift — the driver lifts to change gear, so a shift
	#      dumps boost too even if the throttle input is still held down.
	var shifting := shift_timer > 0.0
	if boost > BOV_BOOST_THRESHOLD:
		if _prev_throttle > 0.1 and throttle_in <= 0.05:
			bov_event = true
		elif shifting and not _prev_shifting:
			bov_event = true
	# Anti-lag bangs while coasting on boost.
	antilag_active = cfg.turbo_antilag and throttle_in <= 0.05 and boost > 0.05
	_prev_throttle = throttle_in
	_prev_shifting = shifting

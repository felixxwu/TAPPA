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

var omega := 0.0  # rad/s engine flywheel speed
var gear := 1  # -1 = reverse, 0 = neutral, 1..N forward
var auto := false  # automatic gearbox (picks the gear from the airspeed)
var shift_timer := 0.0  # seconds of clutch-open throttle cut left in a shift
var throttle := 0.0  # last drive request seen by step(), for the audio synth
var limiting := false  # rev-limiter fuel cut latched on (see _update_limiter)
# Per-gear upshift airspeeds (m/s), one per forward gear. shift_up_speeds[g-1]
# is the forward ground speed at which gear g nears redline; the box upshifts
# on reaching it. The top gear's slot is INF.
var shift_up_speeds: Array[float] = []


func _init() -> void:
	omega = idle_omega()
	auto = Config.data.auto_gearbox
	_compute_shift_speeds()


func idle_omega() -> float:
	return Config.data.idle_rpm * TAU / 60.0


func redline_omega() -> float:
	return Config.data.redline_rpm * TAU / 60.0


func rpm() -> float:
	return omega * 60.0 / TAU


# Total drive ratio engine -> rear axle: negative in reverse, zero in neutral
# (where the clutch is open and no torque reaches the wheels).
func ratio() -> float:
	var cfg: GameConfig = Config.data
	if gear < 0:
		return -cfg.reverse_ratio * cfg.final_drive
	if gear == 0:
		return 0.0
	return cfg.gear_ratios[gear - 1] * cfg.final_drive


# Manual sequential shift by one position through R - N - 1 - 2 ... N.
func request_shift(direction: int) -> void:
	if shift_timer > 0.0:
		return
	var target := clampi(gear + direction, -1, Config.data.gear_ratios.size())
	if target == gear:
		return
	gear = target
	shift_timer = Config.data.shift_time


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
	var n: int = Config.data.gear_ratios.size()
	if gear < n and airspeed > shift_up_speeds[gear - 1] and throttle_in > 0.1:
		request_shift(1)
	elif gear > 1 and airspeed < _downshift_speed(gear):
		request_shift(-1)


# The airspeed below which gear g drops to g-1: the lower pair's upshift
# crossover, pulled down by the hysteresis fraction to open a dead band.
func _downshift_speed(g: int) -> float:
	return shift_up_speeds[g - 2] * (1.0 - Config.data.shift_hysteresis)


# Precompute each gear's upshift airspeed: the ground speed at which the gear
# reaches upshift_redline_fraction of redline rpm (no-slip). Kept below the
# rev-limiter speed so the car always reaches it despite wheel slip; the top
# gear never upshifts, so its slot is INF.
func _compute_shift_speeds() -> void:
	var cfg: GameConfig = Config.data
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
	if gear >= 0 and absf(rear_omega) * Config.data.wheel_radius < 1.0:
		gear = -1
	return gear < 0


func select_forward(rear_omega: float) -> bool:
	if gear < 1 and absf(rear_omega) * Config.data.wheel_radius < 1.0:
		gear = 1
	return gear >= 1


func reset() -> void:
	omega = idle_omega()
	gear = 1
	shift_timer = 0.0
	limiting = false


# One substep of length h: integrates the flywheel against crank and clutch
# torque and returns the clutch torque as seen at the wheels (N·m). throttle
# is the 0..1 drive request; reverse comes from the gear's sign. driveline_omega
# is the driven axle(s)' spin (rear for RWD, front for FWD, mean for AWD).
func step(h: float, throttle_in: float, driveline_omega: float) -> float:
	throttle = throttle_in
	var cfg: GameConfig = Config.data
	shift_timer = maxf(shift_timer - h, 0.0)
	var fuel_cut := _update_limiter(cfg)
	# Always-on engine friction (pumping/viscous losses), affine in RPM the way
	# FMEP is fit on real engines: a constant breakaway term plus a slope that
	# grows with revs. The torque curve is treated as GROSS (indicated) output,
	# so this is subtracted on every path — off throttle and fuel-cut it IS the
	# engine braking (now larger at high revs), which lets the revs bounce off
	# the limiter; the no-stall idle clamp below still holds the bottom.
	var friction := cfg.engine_friction_base + cfg.engine_friction_slope * rpm() / 1000.0
	var crank := -friction
	if throttle > 0.001 and shift_timer <= 0.0 and not fuel_cut:
		# global_torque_scale is a hidden global de-rate: it scales the torque the
		# engine actually delivers without altering cfg.peak_torque, so the stats
		# panel still shows the full published figure while every car is dialled back.
		crank += throttle * cfg.peak_torque * cfg.global_torque_scale * _torque_fraction(rpm())

	var gr := ratio()
	var input_omega := driveline_omega * gr
	var engaged := (
		gear != 0  # neutral: clutch fully open, the engine revs freely
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
		limiting = true
	elif omega <= redline_omega() - band_omega:
		limiting = false
	return limiting


# Fraction of peak_torque available at the given RPM: 70% at zero, full at
# the peak, tapering to 70% at redline, hard cut (rev limiter) above.
func _torque_fraction(at_rpm: float) -> float:
	var cfg: GameConfig = Config.data
	if at_rpm >= cfg.redline_rpm:
		return 0.0
	if at_rpm <= cfg.peak_torque_rpm:
		return lerpf(0.7, 1.0, at_rpm / cfg.peak_torque_rpm)
	return lerpf(
		1.0, 0.7,
		(at_rpm - cfg.peak_torque_rpm) / (cfg.redline_rpm - cfg.peak_torque_rpm)
	)

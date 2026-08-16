extends RefCounted
class_name LapTimeModel

# Quasi-steady-state (QSS) lap-time model. Treats the car as a point mass that
# follows the centerline exactly, subject to its real forces (power, weight, drag,
# grip, braking). Produces a velocity/time profile via a three-pass sweep:
#   1. cornering ceiling  v_cap^2 = mu*g / (kappa - mu*D/m)
#   2. forward accel pass (engine + friction-circle + drive-mode limited)
#   3. backward braking pass (friction-circle limited)
# The longitudinal grip available is bounded by the friction circle: grip spent
# cornering (a_lat = v^2 * kappa) is unavailable for accel/braking. See
# docs/superpowers/specs/2026-06-30-physics-lap-time-design.md.
#
# The friction circle GROWS with speed when the car makes downforce: the envelope is
# mu*(g + D*v^2/m), applied identically in all three passes. Drive mode gates how much
# of that envelope can be put down as drive (forward pass only). Both terms are exact
# no-ops at their defaults — a car with no downforce and traction_factor_* = 1.0
# produces byte-identical times to before they existed. See
# docs/superpowers/specs/2026-08-15-car-performance-rating-design.md.
#
# What this model still does NOT read: brake torque/bias, gearbox ratios, shift time,
# turbo lag, suspension, weight distribution, tyre width. Braking in particular is a
# single friction-circle term, so two cars alike but for their brakes time identically.

static var G: float = Platform.gravity()  # m/s^2, single source of truth: physics/3d/default_gravity (const can't call into Platform)
const ROLLING_G := 0.2          # baseline rolling-resistance decel (fraction of g)
const SAMPLE_STEP_M := 2.0      # curvature/profile sample spacing
const KAPPA_MIN := 1.0e-5       # below this, treat as straight (no cornering cap)
const V_UNBOUNDED := 1.0e12     # m^2/s^2 sentinel for "no cornering cap"
# Hard speed ceiling (m/s) for the aero-boosted cornering cap. With downforce the
# cap is v^2 = mu_g / (kappa - mu*D/m), which is SINGULAR: once mu*D/m >= kappa the
# denominator hits zero or flips sign, i.e. "aero alone holds the car at any speed".
# That is reachable in practice (the aero_kit part adds downforce, and a sweeper's
# kappa is small by design), so the cap is clamped here rather than allowed to run
# away. 150 m/s = 540 km/h — far above anything drivable, so it never binds on a
# real car and only exists to keep a degenerate combination finite.
const V_CAP_MAX_MS := 150.0
const KAPPA_DENOM_MIN := 1.0e-6  # floor for (kappa - aero term); pairs with V_CAP_MAX_MS
# Speed floor (m/s) for the forward pass, applied ONLY on a track with a gradient
# profile. See the forward pass for why a climb needs one at all.
const V_CRAWL_MS := 1.0
# Half-width, in samples, of the smoothing applied to the gradient profile. The road
# follows terrain noise whose finest layers turn over in a few metres, so the raw
# per-sample gradient at SAMPLE_STEP_M carries spikes no real car experiences — a
# wheelbase spans several samples and bridges them. Smoothing over roughly a car length
# is both the physical reading and what keeps those spikes from dominating the solve.
const SLOPE_SMOOTH_SAMPLES := 2

# Full velocity/time profile. Returns parallel arrays sampled every ~SAMPLE_STEP_M
# along the centerline, plus the total time in ms. Empty/zero for a degenerate track.
#
# grip_mult / power_mult are the rival ghost's "driver skill" seam
# (features/rival-ghost.md): the ghost re-solves this model with a degraded envelope
# until the total lands on the rival's drawn time, so a slower crew loses time in the
# corners (grip) and only slightly on the straights (power). They apply at two
# DIFFERENT sites — grip folds into _surface_grip's mu, power scales p_peak_w below —
# because _surface_grip never sees power.
#
# Both default to exactly 1.0 and are pure no-ops at that value, which is what keeps
# every existing caller, and every rival time, unchanged. Passing these from optimum_ms
# (the rival-time path) WOULD move rival times.
# mu_override is CarPerformance's "frozen conditions" seam: a value >= 0 replaces the
# surface/weather grip lookup entirely, so the benchmark rating cannot be moved by a
# gravel/tarmac/weather retune. Negative (the default) is a pure no-op and keeps the
# normal Config-driven path. The car's own tire_compound is NOT bypassed — the caller
# folds it into the override, because it is a property of the car, not the conditions.
static func optimum_profile(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {},
		grip_mult := 1.0, power_mult := 1.0, mu_override := -1.0) -> Dictionary:
	var empty := {"s": PackedFloat32Array(), "v": PackedFloat32Array(), "t": PackedFloat32Array(), "total_ms": 0}
	var centerline := track_result.get("centerline") as Curve2D
	if centerline == null:
		return empty
	var length := centerline.get_baked_length()
	if length <= 0.0:
		return empty

	# The road's lengthwise gradient, when the caller supplied a height sampler (see
	# the "slope" notes below). Absent -> an all-zero profile, i.e. exactly the old
	# flat-earth model, so every synthetic-track caller and the frozen CarPerformance
	# benchmark are byte-identical to before this existed.
	var prof := _curvature_profile(centerline, length,
		track_result.get("road_height", Callable()) as Callable)
	var s: PackedFloat32Array = prof["s"]
	var kappa: PackedFloat32Array = prof["kappa"]
	var slope: PackedFloat32Array = prof["slope"]
	var has_slope: bool = prof["has_slope"]
	var n := s.size()
	if n < 2:
		return empty

	# --- Car physical envelope ------------------------------------------------
	var mass: float = maxf(float(car_meta.get("mass", 1200.0)), 1.0)
	var mu := (mu_override * maxf(grip_mult, 0.0)) if mu_override >= 0.0 \
		else _surface_grip(car_meta, event, grip_mult)
	var mu_g := mu * G
	var rolling := ROLLING_G * G
	var drag: float = float(car_meta.get("drag", 0.0))
	# Peak power in watts. power_to_weight is kW/kg, so * mass * 1000 -> W.
	# power_mult is the skill seam's secondary term (see the docstring) — 1.0 by default.
	var p_peak_w := CarLibrary.power_to_weight(car_meta) * mass * 1000.0 * maxf(power_mult, 0.0)
	# Aero downforce coefficient: total force is F = D * v^2 (car.gd::_apply_aero
	# applies downforce_front and downforce_rear at their axles against v^2). Here the
	# car is a point mass, so only the sum matters. The grip it buys is mu * D * v^2 / m
	# — it passes THROUGH mu, exactly like the car's weight does.
	var aero := maxf(float(car_meta.get("downforce_front", 0.0)) + float(car_meta.get("downforce_rear", 0.0)), 0.0)
	var aero_a := mu * aero / mass       # lateral/longitudinal accel per unit v^2
	var traction := _traction_factor(car_meta)

	# --- Pass 1: cornering ceiling (stored as v^2) ----------------------------
	# Without aero: kappa * v^2 = mu_g            -> v^2 = mu_g / kappa
	# With aero:    kappa * v^2 = mu_g + aero_a*v^2 -> v^2 = mu_g / (kappa - aero_a)
	# Note this is LINEAR in v^2, and singular as aero_a approaches kappa; see
	# V_CAP_MAX_MS.
	var cap2 := PackedFloat32Array(); cap2.resize(n)
	var cap_ceiling := V_CAP_MAX_MS * V_CAP_MAX_MS
	for i in n:
		if kappa[i] <= KAPPA_MIN:
			cap2[i] = V_UNBOUNDED
			continue
		var denom := kappa[i] - aero_a
		cap2[i] = cap_ceiling if denom <= KAPPA_DENOM_MIN else minf(mu_g / denom, cap_ceiling)

	# --- Pass 2: forward accel pass (v^2), standing start at s=0 --------------
	var fwd2 := PackedFloat32Array(); fwd2.resize(n)
	fwd2[0] = 0.0
	for i in range(1, n):
		var step := s[i] - s[i - 1]
		var v_prev2 := fwd2[i - 1]
		var a_lat := v_prev2 * kappa[i - 1]
		var grip_long := _grip_long(mu_g, aero_a, v_prev2, a_lat)
		var v_prev := sqrt(maxf(v_prev2, 0.0))
		var a_engine := p_peak_w / (maxf(v_prev, 0.5) * mass) - drag * v_prev2 / mass - rolling
		# Drive mode gates how much of the available grip can be PUT DOWN as drive.
		# Forward pass only: braking is not a drivetrain function.
		# Gravity along the slope is subtracted OUTSIDE the min, not folded into
		# a_engine: it is not a traction limit and the drivetrain does not gate it. A
		# grip-limited car on a climb still puts down all the grip it has AND still
		# carries its own weight backwards, so both terms bite at once.
		var a := minf(grip_long * traction, a_engine) - G * slope[i - 1]
		var v_next2 := v_prev2 + 2.0 * a * step
		# Floored at a crawl rather than 0: on a steep enough climb at low grip `a` goes
		# negative from a standstill, and the honest physical answer is "this car cannot
		# climb this". Left at 0 the car would sit there forever and the integrator would
		# hand the whole rival field a nonsense stage time. The floor keeps the solve
		# finite and monotonic; a stage leaning on it is already unreasonable, and the
		# thing to retune is grip, not this.
		# Zero without a gradient profile, so the flat path stays byte-identical.
		var floor2 := (V_CRAWL_MS * V_CRAWL_MS) if has_slope else 0.0
		fwd2[i] = clampf(v_next2, floor2, maxf(cap2[i], floor2))

	# --- Pass 3: backward braking pass (v^2); finish line unconstrained -------
	var v2 := PackedFloat32Array(); v2.resize(n)
	v2[n - 1] = fwd2[n - 1]
	for i in range(n - 2, -1, -1):
		var step := s[i + 1] - s[i]
		var v_next2 := v2[i + 1]
		var a_lat := v_next2 * kappa[i + 1]
		var grip_long := _grip_long(mu_g, aero_a, v_next2, a_lat)
		# Braking is grip-limited; rolling + drag also help slow the car. So does gravity
		# when the interval i -> i+1 climbs, and it works against the brakes when that
		# interval drops — the SAME signed slope[i] the forward pass used over the same
		# interval, which is what keeps the two passes describing one consistent hill.
		var a_brake := grip_long + rolling + drag * v_next2 / mass + G * slope[i]
		# a_brake can go NEGATIVE on a steep descent, where gravity beats grip + rolling +
		# drag and the car simply cannot shed speed for the corner ahead. That is the
		# right physics, but it must not run the backward recursion below zero and
		# cascade, so the running v^2 is floored here rather than only at the final sqrt.
		var v_here2 := maxf(v_next2 + 2.0 * a_brake * step, 0.0)
		v2[i] = minf(v_here2, fwd2[i])

	# --- Integrate time t[i] = sum ds / v_avg --------------------------------
	var v := PackedFloat32Array(); v.resize(n)
	var t := PackedFloat32Array(); t.resize(n)
	for i in n:
		v[i] = sqrt(maxf(v2[i], 0.0))
	t[0] = 0.0
	for i in range(1, n):
		var step := s[i] - s[i - 1]
		var v_sum := v[i] + v[i - 1]
		# Trapezoidal: dt = 2*ds / (v0 + v1). v_sum is 0 only if both ends are at rest.
		t[i] = t[i - 1] + (2.0 * step / v_sum if v_sum > 0.01 else step / 0.5)
	return {"s": s, "v": v, "t": t, "total_ms": int(round(t[n - 1] * 1000.0))}


static func optimum_ms(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {},
		grip_mult := 1.0, power_mult := 1.0, mu_override := -1.0) -> int:
	return int(optimum_profile(track_result, car_meta, event, grip_mult, power_mult, mu_override)["total_ms"])


# Longitudinal grip left over after cornering, on a friction circle whose RADIUS
# grows with speed when the car makes downforce.
#
# The total available accel is mu*(g + D*v^2/m) = mu_g + aero_a*v^2. This MUST be the
# same envelope pass 1 caps against: if only the cornering ceiling knew about aero, a
# car sitting at its aero-boosted cap would have a_lat > mu_g, grip_long would collapse
# to zero, and the car could neither accelerate nor brake at a speed the ceiling just
# declared legal. With aero_a = 0 this is exactly the old sqrt(mu_g^2 - a_lat^2).
static func _grip_long(mu_g: float, aero_a: float, v2: float, a_lat: float) -> float:
	var mu_g_v := mu_g + aero_a * maxf(v2, 0.0)
	return sqrt(maxf(mu_g_v * mu_g_v - a_lat * a_lat, 0.0))


# Corner-exit traction ceiling for the car's drive mode. Defaults to 1.0 for an
# unknown/absent drive_mode so a synthetic meta without the field is unchanged.
static func _traction_factor(car_meta: Dictionary) -> float:
	var cfg: GameConfig = Config.data
	match int(car_meta.get("drive_mode", CarLibrary.RWD)):
		CarLibrary.AWD: return maxf(cfg.traction_factor_awd, 0.0)
		CarLibrary.FWD: return maxf(cfg.traction_factor_fwd, 0.0)
		_: return maxf(cfg.traction_factor_rwd, 0.0)


# Sampled curvature kappa(s) = |d(heading)| / ds along the baked centerline, with
# a light 3-tap smoothing to kill discretization spikes. Endpoints are treated as
# straight (kappa = 0).
#
# `road_height`, when valid, is a Callable(x, z) -> float giving the road surface height
# at a world XZ point — the headless TerrainNoise.make_sampler, the same one the track
# generator's water constraint uses. It adds a "slope"
# entry: sin(theta) per sample, POSITIVE UPHILL in the direction of travel, so the
# forward pass can subtract G * slope. Without it "slope" is all zeros and "has_slope"
# is false, which is what makes the gradient term an exact no-op for every caller that
# has no terrain (CarPerformance's frozen benchmark, synthetic test tracks).
static func _curvature_profile(centerline: Curve2D, length: float,
		road_height: Callable = Callable()) -> Dictionary:
	var n := maxi(int(ceil(length / SAMPLE_STEP_M)) + 1, 2)
	var s := PackedFloat32Array(); s.resize(n)
	var pts: Array[Vector2] = []
	for i in n:
		var off := length * float(i) / float(n - 1)
		s[i] = off
		pts.append(centerline.sample_baked(off))
	var raw := PackedFloat32Array(); raw.resize(n)
	raw[0] = 0.0
	raw[n - 1] = 0.0
	for i in range(1, n - 1):
		var h_prev := (pts[i] - pts[i - 1]).angle()
		var h_next := (pts[i + 1] - pts[i]).angle()
		var dtheta := absf(wrapf(h_next - h_prev, -PI, PI))
		var dl := s[i + 1] - s[i]   # one-step interval; dtheta is the change over one step
		raw[i] = (dtheta / dl) if dl > 0.0 else 0.0
	# 3-tap smoothing.
	var kappa := PackedFloat32Array(); kappa.resize(n)
	for i in n:
		var lo := maxi(i - 1, 0)
		var hi := mini(i + 1, n - 1)
		kappa[i] = (raw[lo] + raw[i] + raw[hi]) / 3.0
	return {"s": s, "kappa": kappa, "has_slope": road_height.is_valid(),
		"slope": _slope_profile(s, pts, road_height)}


# sin(theta) per sample along the centerline, positive uphill. Entry i describes the
# interval i -> i+1 (the last entry repeats the one before it, so both passes can index
# it without a bounds branch).
#
# sin, not the rise/run tangent: the model resolves gravity along the direction of
# TRAVEL, and s is measured in the horizontal plane, so rise/run would overstate the
# term on the steepest sections — exactly where it matters most.
static func _slope_profile(s: PackedFloat32Array, pts: Array[Vector2],
		road_height: Callable) -> PackedFloat32Array:
	var n := s.size()
	var slope := PackedFloat32Array(); slope.resize(n)
	if not road_height.is_valid() or n < 2:
		return slope   # all zeros: the flat-earth model, unchanged
	var h := PackedFloat32Array(); h.resize(n)
	for i in n:
		h[i] = float(road_height.call(pts[i].x, pts[i].y))
	var raw := PackedFloat32Array(); raw.resize(n)
	for i in range(n - 1):
		var run := s[i + 1] - s[i]
		var rise := h[i + 1] - h[i]
		var hyp := sqrt(run * run + rise * rise)
		raw[i] = (rise / hyp) if hyp > 0.0 else 0.0
	raw[n - 1] = raw[n - 2]
	# Box-smooth over ~a car length; see SLOPE_SMOOTH_SAMPLES.
	for i in n:
		var lo := maxi(i - SLOPE_SMOOTH_SAMPLES, 0)
		var hi := mini(i + SLOPE_SMOOTH_SAMPLES, n - 1)
		var sum := 0.0
		for k in range(lo, hi + 1):
			sum += raw[k]
		slope[i] = sum / float(hi - lo + 1)
	return slope


# Average tyre grip (front+rear) blended by the event's surface mix, using the
# GameConfig gravel/tarmac grip multipliers (matches rally_library's surface model).
#
# Every rival's time is a multiple of this car's physics optimum
# (RallyLibrary.PACE_FAST_BASE 1.10x down to a tier-dependent slow end), so scaling
# the optimum here scales the ENTIRE AI field. That's why the rain penalty belongs
# here rather than in the field generator: it keeps a wet stage fair — the podium
# cut scales with conditions along with the player, and rain changes how the car
# must be driven rather than how hard the stage is to podium.
#
# The multiplier itself is the weather table's, not a local per-condition test —
# see WeatherLibrary / features/weather.md.
static func _surface_grip(car_meta: Dictionary, event: Dictionary, skill_grip_mult := 1.0) -> float:
	var base := float(car_meta.get("tire_compound", 1.0))
	var tarmac := RallyLibrary.event_tarmac_fraction(event)
	var cfg: GameConfig = Config.data
	var mu := base * ((1.0 - tarmac) * cfg.gravel_grip + tarmac * cfg.tarmac_grip)
	# Unconditional: WeatherLibrary resolves dry (and any unknown string) to exactly
	# 1.0, so there is no per-condition branch here and a new condition needs no edit.
	# skill_grip_mult is the ghost's driver-skill term (1.0 = no-op); it multiplies the
	# same mu the weather/surface model scales, which is why it needed no new concept.
	return mu * WeatherLibrary.grip_mult(cfg, RallyLibrary.event_weather(event)) * maxf(skill_grip_mult, 0.0)

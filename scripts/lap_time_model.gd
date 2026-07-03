extends RefCounted
class_name LapTimeModel

# Quasi-steady-state (QSS) lap-time model. Treats the car as a point mass that
# follows the centerline exactly, subject to its real forces (power, weight, drag,
# grip, braking). Produces a velocity/time profile via a three-pass sweep:
#   1. cornering ceiling  v_cap = sqrt(mu*g / kappa)
#   2. forward accel pass (engine + friction-circle limited)
#   3. backward braking pass (friction-circle limited)
# The longitudinal grip available is bounded by the friction circle: grip spent
# cornering (a_lat = v^2 * kappa) is unavailable for accel/braking. See
# docs/superpowers/specs/2026-06-30-physics-lap-time-design.md.

const G := 9.81                 # m/s^2
const ROLLING_G := 0.2          # baseline rolling-resistance decel (fraction of g)
const SAMPLE_STEP_M := 2.0      # curvature/profile sample spacing
const KAPPA_MIN := 1.0e-5       # below this, treat as straight (no cornering cap)
const V_UNBOUNDED := 1.0e12     # m^2/s^2 sentinel for "no cornering cap"

# Full velocity/time profile. Returns parallel arrays sampled every ~SAMPLE_STEP_M
# along the centerline, plus the total time in ms. Empty/zero for a degenerate track.
static func optimum_profile(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> Dictionary:
	var empty := {"s": PackedFloat32Array(), "v": PackedFloat32Array(), "t": PackedFloat32Array(), "total_ms": 0}
	var centerline := track_result.get("centerline") as Curve2D
	if centerline == null:
		return empty
	var length := centerline.get_baked_length()
	if length <= 0.0:
		return empty

	var prof := _curvature_profile(centerline, length)
	var s: PackedFloat32Array = prof["s"]
	var kappa: PackedFloat32Array = prof["kappa"]
	var n := s.size()
	if n < 2:
		return empty

	# --- Car physical envelope ------------------------------------------------
	var mass: float = maxf(float(car_meta.get("mass", 1200.0)), 1.0)
	var mu := _surface_grip(car_meta, event)
	var mu_g := mu * G
	var rolling := ROLLING_G * G
	var drag: float = float(car_meta.get("drag", 0.0))
	# Peak power in watts. power_to_weight is kW/kg, so * mass * 1000 -> W.
	var p_peak_w := CarLibrary.power_to_weight(car_meta) * mass * 1000.0

	# --- Pass 1: cornering ceiling (stored as v^2) ----------------------------
	var cap2 := PackedFloat32Array(); cap2.resize(n)
	for i in n:
		cap2[i] = (mu_g / kappa[i]) if kappa[i] > KAPPA_MIN else V_UNBOUNDED

	# --- Pass 2: forward accel pass (v^2), standing start at s=0 --------------
	var fwd2 := PackedFloat32Array(); fwd2.resize(n)
	fwd2[0] = 0.0
	for i in range(1, n):
		var step := s[i] - s[i - 1]
		var v_prev2 := fwd2[i - 1]
		var a_lat := v_prev2 * kappa[i - 1]
		var grip_long := sqrt(maxf(mu_g * mu_g - a_lat * a_lat, 0.0))
		var v_prev := sqrt(maxf(v_prev2, 0.0))
		var a_engine := p_peak_w / (maxf(v_prev, 0.5) * mass) - drag * v_prev2 / mass - rolling
		var a := minf(grip_long, a_engine)
		var v_next2 := v_prev2 + 2.0 * a * step
		fwd2[i] = clampf(v_next2, 0.0, cap2[i])

	# --- Pass 3: backward braking pass (v^2); finish line unconstrained -------
	var v2 := PackedFloat32Array(); v2.resize(n)
	v2[n - 1] = fwd2[n - 1]
	for i in range(n - 2, -1, -1):
		var step := s[i + 1] - s[i]
		var v_next2 := v2[i + 1]
		var a_lat := v_next2 * kappa[i + 1]
		var grip_long := sqrt(maxf(mu_g * mu_g - a_lat * a_lat, 0.0))
		# Braking is grip-limited; rolling + drag also help slow the car.
		var a_brake := grip_long + rolling + drag * v_next2 / mass
		var v_here2 := v_next2 + 2.0 * a_brake * step
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


static func optimum_ms(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> int:
	return int(optimum_profile(track_result, car_meta, event)["total_ms"])


# Sampled curvature kappa(s) = |d(heading)| / ds along the baked centerline, with
# a light 3-tap smoothing to kill discretization spikes. Endpoints are treated as
# straight (kappa = 0).
static func _curvature_profile(centerline: Curve2D, length: float) -> Dictionary:
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
	return {"s": s, "kappa": kappa}


# Average tyre grip (front+rear) blended by the event's surface mix, using the
# GameConfig gravel/tarmac grip multipliers (matches rally_library's surface model).
static func _surface_grip(car_meta: Dictionary, event: Dictionary) -> float:
	var base := float(car_meta.get("tire_compound", 1.0))
	var tarmac := RallyLibrary.event_tarmac_fraction(event)
	var cfg: GameConfig = Config.data
	return base * ((1.0 - tarmac) * cfg.gravel_grip + tarmac * cfg.tarmac_grip)

extends RefCounted
class_name RivalPace

# The rival ghost's pace model (features/rival-ghost.md).
#
# Turns "this rival drove the stage in T ms" into "where were they at elapsed t", by
# re-solving LapTimeModel.optimum_profile with a degraded driver-skill envelope until
# the profile's total lands on T. That is deliberately NOT a uniform time scale: a
# uniform scale would make the rival slower by the same percentage everywhere, so a
# backmarker would trundle down the straights like a broken car. Degrading the ENVELOPE
# instead makes them lose time where slow drivers actually lose it — corner entry, apex
# speed, braking — while straight-line pace stays near normal.
#
# Pure: no nodes, no scene, no knowledge of the rendered world. The caller owns the
# curve (world.gd builds the timed-span sub-curve via timed_span_track below) and owns
# mapping profile space onto rendered arc length. Profile space here is simply
# "metres from the start of the curve you handed me", with t=0 at a standing start.
#
# One object serves both the ghost you can see and the in-stage "vs P1" delta popup, so
# the two cannot disagree about the same rival.

# The skill factor's two arms, both exponents of k:
#   grip_mult  = pow(k, rival_ghost_grip_exponent)
#   power_mult = pow(k, rival_ghost_power_exponent)
# Two arms are needed because optimum_profile's forward pass takes min(grip_long,
# a_engine): grip does not bind at all on a power-limited straight, and power barely binds
# mid-corner, so either alone leaves a class of stage it cannot slow down.
# Exponents rather than direct multipliers so either arm can be disabled independently --
# pow(k, 0) == 1. The shipped default sets the GRIP exponent to 0, so the ghost corners at
# the car's true limit and loses time only on the straights.
var _k := 1.0
var _residual_ms := 0
var _used_fallback := false
var _degenerate := true

# The solved profile, micro-scaled onto the target. `_t` is seconds, `_s` metres,
# `_v` m/s — parallel arrays, monotonic in _s and _t.
var _s := PackedFloat32Array()
var _v := PackedFloat32Array()
var _t := PackedFloat32Array()
var _total_ms := 0


# Solve for the envelope that puts this car's profile on `target_ms` over `track_result`.
#
# `cached_k` is an optional seed seeded from data/opponent_cache.json: pass <= 0 for
# "none". A seed is VALIDATED, not trusted — one sweep, and if its residual is outside
# the configured cap we warn and fall back to the full bisection. That check is what
# turns the cache into a cached-vs-live divergence detector rather than a silent risk.
static func solve(track_result: Dictionary, car_meta: Dictionary, event: Dictionary,
		target_ms: int, cached_k := -1.0) -> RivalPace:
	var pace := RivalPace.new()
	if target_ms <= 0:
		return pace
	var cfg: GameConfig = Config.data
	var grip_exponent: float = cfg.rival_ghost_grip_exponent
	var power_exponent: float = cfg.rival_ghost_power_exponent
	var k_min: float = cfg.rival_ghost_skill_min
	var k_max: float = cfg.rival_ghost_skill_max
	var cap: int = cfg.rival_ghost_max_time_residual_ms

	# A probe returns the whole profile so the accepted one can be kept without resolving.
	# Both arms are exponents of the same skill factor, so either can be switched off
	# independently: pow(k, 0) == 1, i.e. grip_exponent 0 leaves cornering grip untouched
	# and the whole deficit comes from power.
	var probe := func(k: float) -> Dictionary:
		return LapTimeModel.optimum_profile(track_result, car_meta, event,
				pow(k, grip_exponent), pow(k, power_exponent))

	var at_min: Dictionary = probe.call(k_min)
	var at_max: Dictionary = probe.call(k_max)
	if int(at_min["total_ms"]) <= 0 or int(at_max["total_ms"]) <= 0:
		return pace   # degenerate track; nothing to pose along

	# Time is strictly decreasing in k (less grip and less power are each strictly
	# slower), so the bracket is ordered: at_max is the fastest, at_min the slowest.
	var chosen: Dictionary
	if target_ms < int(at_max["total_ms"]):
		# Target faster than the car can go even with the envelope flattered. Reachable:
		# rival times are baked over the CACHED track while this solves over the LIVE one.
		push_warning(("RivalPace: target %d ms is faster than the k_max=%.2f optimum (%d ms) — "
				+ "clamping and micro-scaling. Cached and live tracks have diverged.")
				% [target_ms, k_max, int(at_max["total_ms"])])
		chosen = at_max
		pace._k = k_max
		pace._used_fallback = true
	elif target_ms > int(at_min["total_ms"]):
		push_warning(("RivalPace: target %d ms is slower than the k_min=%.2f optimum (%d ms) — "
				+ "clamping and micro-scaling. Lower rival_ghost_skill_min to widen the range.")
				% [target_ms, k_min, int(at_min["total_ms"])])
		chosen = at_min
		pace._k = k_min
		pace._used_fallback = true
	else:
		# A cached seed short-circuits the search when it holds up.
		var seeded := {}
		if cached_k > 0.0:
			var probe_k: float = clampf(cached_k, k_min, k_max)
			var candidate: Dictionary = probe.call(probe_k)
			if absi(int(candidate["total_ms"]) - target_ms) <= cap:
				seeded = candidate
				pace._k = probe_k
			else:
				push_warning(("RivalPace: cached skill factor %.3f gives %d ms against a %d ms "
						+ "target (cap %d ms) — re-solving. The baked cache and the live track "
						+ "have diverged.") % [cached_k, int(candidate["total_ms"]), target_ms, cap])
		if not seeded.is_empty():
			chosen = seeded
		else:
			chosen = pace._bisect(probe, k_min, k_max, target_ms, cfg.rival_ghost_skill_iterations)

	pace._adopt(chosen, target_ms)
	if pace._residual_ms > cap:
		push_warning(("RivalPace: bisection left a %d ms residual against a %d ms cap — the "
				+ "micro-scale is doing the work the envelope should, i.e. this is a disguised "
				+ "uniform slowdown. Check rival_ghost_skill_min / _power_exponent.")
				% [pace._residual_ms, cap])
	return pace


# Bisect k until the profile's total straddles the target. Records the winning k on
# self and returns its profile.
func _bisect(probe: Callable, k_min: float, k_max: float, target_ms: int, iterations: int) -> Dictionary:
	var lo := k_min      # slower end
	var hi := k_max      # faster end
	var best: Dictionary = probe.call(hi)
	_k = hi
	for _i in maxi(iterations, 1):
		var mid := (lo + hi) * 0.5
		var prof: Dictionary = probe.call(mid)
		best = prof
		_k = mid
		var total := int(prof["total_ms"])
		if total > target_ms:
			lo = mid   # too slow -> need more skill
		else:
			hi = mid   # too fast -> need less
	return best


# Take a solved profile and micro-scale its clock onto the target. The bisection gets
# the SHAPE; this makes the number exact — to +/-1 ms, since total_ms is an int round.
func _adopt(prof: Dictionary, target_ms: int) -> void:
	var t: PackedFloat32Array = prof["t"]
	var n := t.size()
	if n < 2:
		return
	var natural_ms := int(prof["total_ms"])
	_residual_ms = absi(natural_ms - target_ms)
	var natural_s := float(t[n - 1])
	if natural_s <= 0.0:
		return
	var scale := (float(target_ms) / 1000.0) / natural_s

	_s = prof["s"]
	var src_v: PackedFloat32Array = prof["v"]
	_t = PackedFloat32Array(); _t.resize(n)
	_v = PackedFloat32Array(); _v.resize(n)
	for i in n:
		_t[i] = float(t[i]) * scale
		# Stretching the clock stretches the speeds inversely: the same metres now take
		# `scale` times as long, so the car is covering them `1/scale` as fast.
		_v[i] = float(src_v[i]) / scale
	_total_ms = int(round(float(_t[n - 1]) * 1000.0))
	_degenerate = false


# --- Queries ----------------------------------------------------------------------

# Arc offset (m, from the start of the solved curve) at `elapsed_s` seconds of stage
# time. Clamped at both ends: before GO the ghost sits at the origin, and after its
# target time it PARKS at the finish rather than running on into the runoff (or looping,
# which is what the post-event replay ghost does).
func offset_at(elapsed_s: float) -> float:
	if _degenerate:
		return 0.0
	var n := _t.size()
	if elapsed_s <= float(_t[0]):
		return float(_s[0])
	if elapsed_s >= float(_t[n - 1]):
		return float(_s[n - 1])
	var i := _index_for(_t, elapsed_s)
	var span := float(_t[i + 1]) - float(_t[i])
	var f := 0.0 if span <= 0.0 else (elapsed_s - float(_t[i])) / span
	return lerpf(float(_s[i]), float(_s[i + 1]), f)


# Speed (m/s) at `elapsed_s`. Drives the ghost's wheel spin and dust.
func speed_at(elapsed_s: float) -> float:
	if _degenerate:
		return 0.0
	var n := _t.size()
	if elapsed_s <= float(_t[0]):
		return float(_v[0])
	if elapsed_s >= float(_t[n - 1]):
		return float(_v[n - 1])
	var i := _index_for(_t, elapsed_s)
	var span := float(_t[i + 1]) - float(_t[i])
	var f := 0.0 if span <= 0.0 else (elapsed_s - float(_t[i])) / span
	return lerpf(float(_v[i]), float(_v[i + 1]), f)


# Elapsed seconds at an arc offset — the inverse read, used by the "vs P1" popup for
# its per-turn splits. Offsets must already be in THIS profile's space.
func time_at_offset(offset_m: float) -> float:
	if _degenerate:
		return 0.0
	var n := _s.size()
	if offset_m <= float(_s[0]):
		return float(_t[0])
	if offset_m >= float(_s[n - 1]):
		return float(_t[n - 1])
	var i := _index_for(_s, offset_m)
	var span := float(_s[i + 1]) - float(_s[i])
	var f := 0.0 if span <= 0.0 else (offset_m - float(_s[i])) / span
	return lerpf(float(_t[i]), float(_t[i + 1]), f)


# Binary search: the largest index whose value is <= `value`, bounded so index+1 is
# always valid. Both _s and _t are monotonic, so one helper serves both.
func _index_for(arr: PackedFloat32Array, value: float) -> int:
	var lo := 0
	var hi := arr.size() - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if float(arr[mid]) <= value:
			lo = mid
		else:
			hi = mid
	return lo


func total_ms() -> int:
	return _total_ms

func span_m() -> float:
	return 0.0 if _degenerate else float(_s[_s.size() - 1])

# The solved skill factor — read by the opponent-cache bake so the search can be
# skipped next time, and by tests asserting which path the solve took.
func solved_k() -> float:
	return _k

# How far the bisection missed by before the micro-scale absorbed it. A large value
# means the shape search failed and the result is a disguised uniform slowdown.
func residual_ms() -> int:
	return _residual_ms

# True when the target could not be bracketed and k was clamped.
func used_fallback() -> bool:
	return _used_fallback

# No usable profile (degenerate track, or a non-positive target).
func is_degenerate() -> bool:
	return _degenerate


# --- The timed-span sub-curve ------------------------------------------------------

# Resample `source` between two arc offsets into a fresh Curve2D, wrapped in the
# {"centerline": ...} dict LapTimeModel consumes.
#
# The ghost must be solved over the span the PLAYER is timed on — origin_offset() to
# finish_offset() — not the raw generated centerline. The raw curve starts at the
# generated origin, which is tens of metres past where the player actually launches
# (they are staged behind the start line), and optimum_profile puts t=0 at a standing
# start wherever its curve begins. Solving over the raw curve therefore parks the ghost
# short of the finish arch.
#
# Step: deliberately much finer than LapTimeModel.SAMPLE_STEP_M. _curvature_profile
# derives kappa from chord heading changes over one sample step; resampling AT the
# sample step would concentrate each vertex's whole turn onto one sample, producing a
# kappa spike/zero comb that biases the cornering cap (mu_g/kappa, nonlinear) downward
# and makes every ghost systematically slow.
#
# What a finer step CANNOT do is add fidelity: Curve2D.sample_baked interpolates
# linearly between points baked at bake_interval, so any resample reproduces those
# chords. That is fine — the goal here is PARITY with the profile the authored rival
# times were computed from, not a better one.
const SUB_CURVE_STEP_M := 0.5

static func timed_span_track(source: Curve2D, from_offset: float, to_offset: float) -> Dictionary:
	var out := Curve2D.new()
	if source == null:
		return {"centerline": out, "pieces": []}
	var length := source.get_baked_length()
	var lo := clampf(minf(from_offset, to_offset), 0.0, length)
	var hi := clampf(maxf(from_offset, to_offset), 0.0, length)
	var span := hi - lo
	if span <= 0.0:
		out.add_point(source.sample_baked(lo))
		return {"centerline": out, "pieces": []}
	var n := maxi(2, int(ceil(span / SUB_CURVE_STEP_M)) + 1)
	var step := span / float(n - 1)
	for i in n:
		out.add_point(source.sample_baked(lo + minf(float(i) * step, span)))
	# No "pieces": those are turn boundaries in the SOURCE curve's coordinate system.
	# Carrying them onto a re-origined sub-curve would silently mismatch the two spaces.
	return {"centerline": out, "pieces": []}

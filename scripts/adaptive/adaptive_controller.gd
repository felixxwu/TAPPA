class_name AdaptiveController
extends RefCounted
# Docs: features/adaptive-graphics.md — update in the same change as this file.
## Decides, frame by frame, which AdaptiveKnob to cut or raise to keep the frame inside its budget,
## learning each knob's cost from the change every decision makes. Pure logic: fed samples, no scene.

var knobs: Array[AdaptiveKnob] = []
var enabled := true
var at_floor := false
var last_decision := ""
var last_decision_s := -INF

var _hist: Array[PackedFloat64Array] = []  # [now_s, cost_ms, interval_ms, draws, prims], oldest first
var _over_since := INF
var _room_since := INF
var _hold_until := -INF
var _next_drop_s := -INF
var _last_raise := {}  # {knob, from, at_s, headroom}
var _exp := {}  # the change being measured: {knob, from, to, at_s, before, draws, prims, sum, n, d_sum, p_sum}
var _misses := -1
var _decay_at := 0.0
var _fit := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])  # n, Σx, Σy, Σc, Σxx, Σyy, Σxy, Σxc, Σyc, Σcc
var _per_draw := 0.0
var _per_kprim := 0.0
var _fit_ok := false
var _fit_age := 0
const NOISE_MS := 0.2  # a cut that saves less than this saved nothing measurable
const MAX_COST_MS := 50.0
const MIN_WINDOW := 10  # frames since the last change needed before judging the frame time


func cfg() -> GameConfig:
	return Config.data


## One drawn frame: {now_s, cost_ms, budget_ms, interval_ms, gpu_ms, draws, prims, quiet, near_misses}.
func feed(s: Dictionary) -> void:
	if not enabled:
		return
	var now: float = s.get("now_s", 0.0)
	var interval: float = s.get("interval_ms", 0.0)
	if interval > cfg().adaptive_pause_ms:
		disturbed(now)
		return
	var cost := maxf(float(s.get("cost_ms", 0.0)), float(s.get("gpu_ms", 0.0)))
	var budget: float = s.get("budget_ms", 1000.0 / 60.0)
	var draws := float(s.get("draws", 0))
	var prims := float(s.get("prims", 0))
	var quiet: bool = s.get("quiet", true)
	_hist.append(PackedFloat64Array([now, cost, interval, draws, prims]))
	var keep_s := maxf(cfg().adaptive_window_s, cfg().adaptive_experiment_s) + 0.1
	while _hist.size() > 1 and _hist[0][0] < now - keep_s:
		_hist.pop_front()
	if quiet:
		_fit_add(draws, prims / 1000.0, cost)
	_decay(now)
	_measure(now, cost, draws, prims, quiet)
	var misses := int(s.get("near_misses", -1))
	var missed_now := _misses >= 0 and misses > _misses
	_misses = misses
	if now < _hold_until or _window_size() < MIN_WINDOW:
		return
	if missed_now:
		_drop_for_miss(now)
	var target := budget * cfg().adaptive_margin
	var p90 := p90_ms()
	var over := p90 > target or _missed(budget) >= cfg().adaptive_miss_count
	if over:
		_room_since = INF
		_over_since = minf(_over_since, now)
		if now - _over_since >= cfg().adaptive_over_hold_s and now >= _next_drop_s:
			_drop(now, p90 - target)
		return
	_over_since = INF
	var room := target - p90
	_room_since = minf(_room_since, now)
	if at_floor and now - _room_since >= cfg().adaptive_raise_hold_s:
		at_floor = false
	if _exp.is_empty():
		_raise(now, room)


## Something unrelated to the knobs just changed what the frame costs (teleport, weather, menus).
func disturbed(now_s: float) -> void:
	_misses = -1
	_exp = {}
	_last_raise = {}
	_hist.clear()
	_over_since = INF
	_room_since = INF
	_hold_until = now_s + cfg().adaptive_settle_s


func p90_ms() -> float:
	var n := _window_start()
	var costs := PackedFloat64Array()
	for i in range(n, _hist.size()):
		costs.append(_hist[i][1])
	if costs.is_empty():
		return 0.0
	costs.sort()
	return costs[mini(costs.size() - 1, int(costs.size() * 0.9))]


func headroom_ms(budget_ms: float) -> float:
	return budget_ms * cfg().adaptive_margin - p90_ms()


## What one step of `k` is expected to cost, in ms.
func est_cost(k: AdaptiveKnob) -> float:
	return k.cost_ms if k.samples > 0 else k.prior_ms


func ms_per_draw() -> float:
	return maxf(_per_draw, 0.0) if _fit_ok else 0.0


func ms_per_kprim() -> float:
	return maxf(_per_kprim, 0.0) if _fit_ok else 0.0


## Seconds until `k` may be raised again (0 when it may now).
func raise_wait_s(k: AdaptiveKnob, now_s: float) -> float:
	return maxf(0.0, k.backoff_until_s - now_s)


func to_dict() -> Dictionary:
	var out := {}
	for k in knobs:
		out[String(k.id)] = {"level": k.level, "cost_ms": k.cost_ms, "samples": k.samples, "fails": k.fails,
			"backoff_until_s": k.backoff_until_s}
	return {"knobs": out}


## Restores what to_dict saved, tolerating missing, unknown or out-of-range entries.
func from_dict(d: Variant) -> void:
	if not d is Dictionary or not (d as Dictionary).get("knobs") is Dictionary:
		return
	var saved: Dictionary = d["knobs"]
	for k in knobs:
		var e: Variant = saved.get(String(k.id))
		if not e is Dictionary:
			continue
		k.level = clampi(int(_num(e.get("level"), k.level)), 0, k.top())
		k.cost_ms = clampf(_num(e.get("cost_ms"), k.prior_ms), 0.0, MAX_COST_MS)
		k.samples = maxi(0, int(_num(e.get("samples"), 0)))
		k.fails = clampi(int(_num(e.get("fails"), 0)), 0, 8)
		var now := Time.get_ticks_usec() / 1e6
		k.backoff_until_s = clampf(_num(e.get("backoff_until_s"), 0.0), 0.0, now + cfg().adaptive_backoff_s[-1])


static func _num(v: Variant, fallback: float) -> float:
	return float(v) if (v is float or v is int) and is_finite(float(v)) else fallback


func _window_start() -> int:
	if _hist.is_empty():
		return 0
	var since: float = maxf(_hist[-1][0] - cfg().adaptive_window_s, last_decision_s + cfg().adaptive_settle_s)
	var i := _hist.size() - 1
	while i > 0 and _hist[i - 1][0] >= since:
		i -= 1
	return i


func _window_size() -> int:
	return 0 if _hist.is_empty() or _hist[-1][0] < last_decision_s + cfg().adaptive_settle_s else _hist.size() - _window_start()


func _missed(budget: float) -> int:
	var n := 0
	for i in range(_window_start(), _hist.size()):
		if _hist[i][2] >= budget * cfg().adaptive_miss_factor:
			n += 1
	return n


func _drop(now: float, over_by: float) -> void:
	if not _last_raise.is_empty() and now - float(_last_raise["at_s"]) <= cfg().adaptive_revert_window_s:
		var k: AdaptiveKnob = _last_raise["knob"]
		var from := int(_last_raise["from"])
		k.cost_ms = maxf(est_cost(k), float(_last_raise["headroom"]) + over_by)
		k.samples = maxi(k.samples, 1)
		_fail(k, now)
		_change(k, from, now, "undid %s → %d/%d (over by %.1f ms)" % [k.name, from, k.top(), over_by])
		return
	var pick: AdaptiveKnob = null
	var best := -INF
	for k in knobs:
		if k.last_resort or k.level <= 0:
			continue
		var score := est_cost(k) / maxf(k.step_weight(k.level), 0.001)
		if score > best:
			best = score
			pick = k
	if pick == null:
		for k in knobs:
			if k.last_resort and k.level > 0 and now >= k.backoff_until_s and _exp.get("knob") != k:
				pick = k
				break
	if pick == null:
		at_floor = true
		_next_drop_s = now + cfg().adaptive_drop_cooldown_s
		return
	_change(pick, pick.level - 1, now, "cut %s → %d/%d (over by %.1f ms)" % [pick.name, pick.level - 1, pick.top(), over_by])


func _drop_for_miss(now: float) -> void:
	for k in knobs:
		if k.miss_target and k.level > 0 and now >= _next_drop_s:
			if not _last_raise.is_empty() and _last_raise["knob"] == k and now - float(_last_raise["at_s"]) <= cfg().adaptive_revert_window_s:
				_fail(k, now)
			else:
				k.backoff_until_s = maxf(k.backoff_until_s, now + cfg().adaptive_backoff_s[0])
			_change(k, k.level - 1, now, "cut %s → %d/%d (terrain fell behind the car)" % [k.name, k.level - 1, k.top()])
			return


func _raise(now: float, room: float) -> void:
	var held := now - _room_since
	for k in knobs:
		if k.last_resort and k.level < k.top() and now >= k.backoff_until_s:
			if held >= cfg().adaptive_raise_hold_s:
				_raise_knob(k, now, room)
			return
	var pick: AdaptiveKnob = null
	var best := -INF
	for k in knobs:
		if k.level >= k.top() or now < k.backoff_until_s:
			continue
		var w := k.step_weight(k.level + 1)
		var c := est_cost(k)
		if w <= 0.0 or c > room:
			continue
		var score := w / maxf(c, 0.01)
		if score > best:
			best = score
			pick = k
	if pick == null:
		return
	if held >= cfg().adaptive_raise_hold_s or (held >= cfg().adaptive_settle_s and room > est_cost(pick) * cfg().adaptive_fast_climb_factor):
		_raise_knob(pick, now, room)


func _raise_knob(k: AdaptiveKnob, now: float, room: float) -> void:
	_last_raise = {"knob": k, "from": k.level, "at_s": now, "headroom": room}
	_change(k, k.level + 1, now, "raised %s → %d/%d (%.1f ms spare)" % [k.name, k.level + 1, k.top(), room])


func _change(k: AdaptiveKnob, to: int, now: float, why: String) -> void:
	var from := k.level
	var before := _mean_since(now - cfg().adaptive_experiment_s)
	k.set_level(to)
	last_decision = why
	last_decision_s = now
	_next_drop_s = now + cfg().adaptive_drop_cooldown_s
	_room_since = INF
	_over_since = INF
	_exp = {} if before.x < 0.0 else {"knob": k, "from": from, "to": to, "at_s": now, "before": before,
		"sum": 0.0, "n": 0, "d_sum": 0.0, "p_sum": 0.0}
	if to < from:
		_last_raise = {}


func _fail(k: AdaptiveKnob, now: float) -> void:
	k.fails += 1
	k.last_fail_s = now
	var sched: Array[float] = cfg().adaptive_backoff_s
	k.backoff_until_s = now + sched[mini(k.fails - 1, sched.size() - 1)]
	_last_raise = {}


# Folds frames after a change into its experiment and, once enough are in, learns from it.
func _measure(now: float, cost: float, draws: float, prims: float, quiet: bool) -> void:
	if _exp.is_empty():
		return
	var start: float = float(_exp["at_s"]) + cfg().adaptive_settle_s
	if now < start:
		return
	if now > start + cfg().adaptive_experiment_s * 3.0:
		_exp = {}
		return
	if not quiet:
		return
	_exp["sum"] += cost
	_exp["d_sum"] += draws
	_exp["p_sum"] += prims
	_exp["n"] += 1
	if now < start + cfg().adaptive_experiment_s:
		return
	var n := float(_exp["n"])
	var k: AdaptiveKnob = _exp["knob"]
	var steps := float(int(_exp["to"]) - int(_exp["from"]))
	var before: Vector3 = _exp["before"]
	var timed: float = (float(_exp["sum"]) / n - before.x) / steps
	var sample := timed
	k.from_fit = false
	if _fit_ok:
		var by_draws: float = ((float(_exp["d_sum"]) / n - before.y) * ms_per_draw() + (float(_exp["p_sum"]) / n - before.z) / 1000.0 * ms_per_kprim()) / steps
		if by_draws > 0.0:
			sample = 0.5 * (timed + by_draws)
			k.from_fit = true
	if k.last_resort and steps < 0.0 and timed < NOISE_MS:
		_fail(k, now)
		at_floor = true
		k.set_level(int(_exp["from"]))
		_exp = {}
		last_decision = "undid %s: cutting it saved nothing" % k.name
		last_decision_s = now
		return
	sample = maxf(sample, 0.0)
	k.samples += 1
	k.cost_ms = lerpf(k.cost_ms if k.samples > 1 else k.prior_ms, sample, maxf(1.0 / k.samples, 0.3))
	_exp = {}


# Mean (cost, draws, prims) over frames since `since`; x < 0 when there are too few.
func _mean_since(since: float) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for i in range(_hist.size() - 1, -1, -1):
		if _hist[i][0] < since:
			break
		sum += Vector3(_hist[i][1], _hist[i][3], _hist[i][4])
		n += 1
	return sum / n if n >= 10 else Vector3(-1, 0, 0)


func _decay(now: float) -> void:
	if now < _decay_at:
		return
	var dt := 1.0 if _decay_at > 0.0 else 0.0
	_decay_at = now + 1.0
	for k in knobs:
		if k.samples > 0 and dt > 0.0:
			k.cost_ms = lerpf(k.cost_ms, k.prior_ms, clampf(dt / cfg().adaptive_estimate_decay_s, 0.0, 1.0))
		if k.fails > 0 and now - k.last_fail_s > cfg().adaptive_backoff_shrink_s:
			k.fails -= 1
			k.last_fail_s = now


# Least-squares fit of frame cost against draw calls and thousands of primitives, slowly forgetting
# old frames. Centred sums keep the 2×2 solve accurate when draws and primitives rise together.
func _fit_add(x: float, y: float, c: float) -> void:
	const FORGET := 0.9995
	for i in _fit.size():
		_fit[i] *= FORGET
	var add := [1.0, x, y, c, x * x, y * y, x * y, x * c, y * c, c * c]
	for i in _fit.size():
		_fit[i] += add[i]
	_fit_age += 1
	if _fit_age % 30 != 0:
		return
	var n := _fit[0]
	if n < 300.0:
		_fit_ok = false
		return
	var mx := _fit[1] / n
	var my := _fit[2] / n
	var mc := _fit[3] / n
	var sxx := _fit[4] / n - mx * mx
	var syy := _fit[5] / n - my * my
	var sxy := _fit[6] / n - mx * my
	var sxc := _fit[7] / n - mx * mc
	var syc := _fit[8] / n - my * mc
	var det := sxx * syy - sxy * sxy
	if sxx <= 0.0 or syy <= 0.0 or det <= 1e-6 * sxx * syy:
		_fit_ok = false
		return
	_per_draw = (sxc * syy - syc * sxy) / det
	_per_kprim = (syc * sxx - sxc * sxy) / det
	_fit_ok = true

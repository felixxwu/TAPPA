extends GutTest
# AdaptiveController (features/adaptive-graphics.md): cuts and raises synthetic settings against a
# fake frame cost, checking behaviour that holds for any reasonable tuning.

const BUDGET := 1000.0 / 60.0
const DT := 1.0 / 60.0

var _per_step := {}  # knob id -> ms one step costs in the fake world
var _base := 5.0
var _now := 0.0


func before_each() -> void:
	Config.reset()
	_per_step = {}
	_base = 5.0
	_now = 0.0


func after_each() -> void:
	Config.reset()


func _knob(id: StringName, levels: int, level: int, step_ms: float, last_resort := false) -> AdaptiveKnob:
	var k := AdaptiveKnob.new()
	k.id = id
	k.name = String(id)
	k.levels = levels
	k.level = level
	k.prior_ms = 0.3
	k.cost_ms = 0.3
	k.last_resort = last_resort
	_per_step[id] = step_ms
	return k


func _controller(knobs: Array[AdaptiveKnob]) -> AdaptiveController:
	var c := AdaptiveController.new()
	c.knobs = knobs
	return c


func _cost(c: AdaptiveController) -> float:
	var cost := _base
	for k in c.knobs:
		cost += k.level * float(_per_step[k.id])
	return cost


func _run(c: AdaptiveController, seconds: float, interval_ms := BUDGET, extra_cost := 0.0) -> void:
	var end := _now + seconds
	while _now < end:
		_now += DT
		var draws := 0
		for k in c.knobs:
			draws += k.level * 10
		c.feed({"now_s": _now, "cost_ms": _cost(c) + extra_cost, "budget_ms": BUDGET, "interval_ms": interval_ms,
			"gpu_ms": 0.0, "draws": draws, "prims": 0, "quiet": true, "near_misses": 0})


func _all_at_top(c: AdaptiveController) -> bool:
	for k in c.knobs:
		if k.level != k.top():
			return false
	return true


func test_drops_when_over_budget() -> void:
	var c := _controller([_knob(&"a", 5, 4, 1.0), _knob(&"b", 5, 4, 1.0)])
	_base = BUDGET * 2.0
	_run(c, 3.0)
	assert_lt(c.knobs[0].level + c.knobs[1].level, 8, "something was cut")


func test_drops_the_expensive_setting_first() -> void:
	var cheap := _knob(&"cheap", 5, 4, 0.2)
	var dear := _knob(&"dear", 5, 4, 4.0)
	for k in [cheap, dear]:
		k.cost_ms = _per_step[k.id]
		k.samples = 3
	var c := _controller([cheap, dear])
	_base = BUDGET
	_run(c, 1.5)
	assert_lt(dear.level, 4, "the costly setting is cut")
	assert_eq(cheap.level, 4, "before the cheap one")


func test_raises_every_setting_when_there_is_room() -> void:
	var c := _controller([_knob(&"a", 4, 0, 0.3), _knob(&"b", 4, 0, 0.3)])
	_base = 2.0
	_run(c, 240.0)
	assert_true(_all_at_top(c), "both settings climb to their top")


func test_a_raise_that_backfires_is_undone_and_waits() -> void:
	var k := _knob(&"a", 2, 0, BUDGET)
	var c := _controller([k])
	_base = 4.0
	_run(c, 12.0)
	assert_eq(k.level, 0, "the raise that blew the budget was undone")
	assert_gt(k.fails, 0)
	assert_gt(c.raise_wait_s(k, _now), 0.0, "and it waits before trying again")
	var wait := c.raise_wait_s(k, _now)
	_run(c, wait * 0.5)
	assert_eq(k.level, 0, "no retry while it waits")


func test_never_stuck_low_once_the_cost_goes_away() -> void:
	var c := _controller([_knob(&"a", 4, 3, 1.0), _knob(&"b", 4, 3, 1.0), _knob(&"res", 3, 2, 0.5, true)])
	_base = BUDGET * 3.0
	_run(c, 20.0)
	assert_eq(c.knobs[0].level + c.knobs[1].level, 0, "a costly spell cuts everything")
	_base = 2.0
	_run(c, 600.0)
	assert_true(_all_at_top(c), "and everything climbs back once it passes")


func test_last_resort_is_cut_only_when_everything_else_is_down() -> void:
	var a := _knob(&"a", 3, 2, 1.0)
	var res := _knob(&"res", 3, 2, 1.0, true)
	var c := _controller([res, a])
	_base = BUDGET * 3.0
	while _now < 20.0 and res.level == res.top():
		_run(c, DT)
	assert_lt(res.level, res.top(), "the last resort was cut in the end")
	assert_eq(a.level, 0, "but only after the other setting reached its lowest")


func test_a_long_frame_gap_is_a_pause_not_a_slow_frame() -> void:
	var c := _controller([_knob(&"a", 3, 2, 0.5)])
	_base = 3.0
	_run(c, 1.0)
	_run(c, 2.0, 2000.0, 100.0)
	assert_eq(c.knobs[0].level, 2, "frames during a hidden tab or hitch cut nothing")


func test_disturbed_throws_the_measurement_away() -> void:
	for disturb in [false, true]:
		_now = 0.0
		var k := _knob(&"a", 2, 1, 2.0)
		var c := _controller([k])
		_base = BUDGET
		_run(c, 0.5)
		_base = 2.0
		_run(c, 1.0)
		assert_eq(k.level, 0, "precondition: it was cut")
		if disturb:
			c.disturbed(_now)
		_run(c, 3.0)
		assert_eq(k.samples, 0 if disturb else 1, "a disturbance discards the change's measurement" if disturb else "control: it is measured")


func test_disabled_does_nothing() -> void:
	var c := _controller([_knob(&"a", 3, 2, 1.0)])
	c.enabled = false
	_base = BUDGET * 3.0
	_run(c, 5.0)
	assert_eq(c.knobs[0].level, 2)


func test_saved_state_round_trips_and_bad_entries_are_ignored() -> void:
	var c := _controller([_knob(&"a", 4, 1, 1.0), _knob(&"b", 4, 2, 1.0)])
	var saved := c.to_dict()
	var d := _controller([_knob(&"a", 4, 3, 1.0), _knob(&"b", 4, 3, 1.0)])
	d.from_dict(saved)
	assert_eq([d.knobs[0].level, d.knobs[1].level], [1, 2])
	d.from_dict({"knobs": {"a": {"level": 99, "cost_ms": "x"}, "gone": {"level": 1}, "b": "junk"}})
	assert_eq(d.knobs[0].level, 3, "a level past the top is clamped")
	assert_true(is_finite(d.knobs[0].cost_ms))
	d.from_dict("not a dict")
	d.from_dict(null)
	assert_eq(d.knobs[1].level, 2, "garbage changes nothing")


func test_a_resolution_cut_that_saves_nothing_is_not_repeated_while_it_waits() -> void:
	var res := _knob(&"res", 3, 2, 0.0, true)
	var c := _controller([res, _knob(&"a", 2, 0, 1.0)])
	_base = BUDGET * 3.0
	_run(c, 8.0)
	assert_eq(res.level, res.top(), "the useless cut was undone")
	assert_true(c.at_floor)
	var cuts := 0
	var was := res.level
	for i in 600:
		_run(c, DT)
		if res.level < was:
			cuts += 1
		was = res.level
	assert_eq(cuts, 0, "and not tried again while it backs off")


func test_coming_back_from_a_pause_does_not_raise_at_once() -> void:
	var c := _controller([_knob(&"a", 3, 0, 0.2)])
	_base = 2.0
	_run(c, 3.0)
	_run(c, 0.5, 2000.0)
	var lvl := c.knobs[0].level
	_run(c, 1.0)
	assert_eq(c.knobs[0].level, lvl, "the spare time before the pause doesn't count after it")


func test_a_terrain_miss_seen_during_a_disturbance_cuts_nothing() -> void:
	var k := _knob(&"terrain", 3, 2, 0.1)
	k.miss_target = true
	var c := _controller([k])
	_base = 2.0
	_run(c, 1.0)
	c.disturbed(_now)
	for i in 120:
		_now += DT
		c.feed({"now_s": _now, "cost_ms": 3.0, "budget_ms": BUDGET, "interval_ms": BUDGET, "gpu_ms": 0.0,
			"draws": 0, "prims": 0, "quiet": true, "near_misses": 5 if i > 10 else 0})
	assert_eq(k.level, 2)

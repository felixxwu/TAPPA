extends GutTest
# BarrierLayout: the pure corner-barrier planner (scripts/barrier_layout.gd). No
# scene, no terrain — a hand-built Curve2D plus hand-built piece dicts, so these
# assert the placement RULES: only sharp corners get a run, modules are stitched at
# the configured pitch, the run sits on the OUTSIDE of the bend, the style follows
# the road surface, and neighbouring runs never stack on the same verge.
#
# Values here (pitch, lead, threshold) are supplied by the test, never read from
# GameConfig — a designer retuning the real ones must not break these.

const PITCH := 2.0
const TRACK_WIDTH := 7.0
const ROAD_GAP := 0.5
# How far off the centerline the barrier line runs — the planner derives the same
# figure from the params below, and it is the line module spacing is measured along.
const LATERAL := TRACK_WIDTH * 0.5 + ROAD_GAP


# The hill-or-drop probe: `PROBE` out from the road edge, so the far sample lands
# TRACK_WIDTH/2 + PROBE from the centerline and the near one at 55% of that.
const PROBE := 5.0
const DROP_MIN := 1.0


func _params(lead := 0.0, threshold := 0.5, min_run := 1) -> Dictionary:
	return {
		"section_length_m": PITCH,
		"lead_m": lead,
		"tarmac_threshold": threshold,
		"track_width": TRACK_WIDTH,
		"road_gap_m": ROAD_GAP,
		"slope_probe_m": PROBE,
		"drop_min_m": DROP_MIN,
		"min_run_modules": min_run,
	}


# Where a planned module actually stands: its centerline point pushed out to the
# barrier line. Mirrors BarrierField._module_transform (minus the per-style face
# reach, a few cm) — this is the line the modules must tile along.
func _barrier_point(entry: Dictionary) -> Vector2:
	var tangent: Vector2 = entry["tangent"]
	return (entry["pos"] as Vector2) \
		+ float(entry["side"]) * Vector2(-tangent.y, tangent.x) * LATERAL


# A curve that runs straight up +Z, bends 90 degrees to the right (toward +X), then
# runs straight along +X. The arc's centre — the INSIDE of the bend — is BEND_CENTRE.
const BEND_R := 16.0
const BEND_CENTRE := Vector2(16.0, 40.0)

func _right_bend_curve() -> Curve2D:
	var c := Curve2D.new()
	for z in range(0, 41, 4):
		c.add_point(Vector2(0.0, float(z)))          # straight along +Z, up to (0, 40)
	# Sweep the angle DOWN from PI to PI/2, which is the direction that leaves (0, 40)
	# still heading +Z and arrives heading +X. Sweeping up instead doubles the road
	# back on itself (a cusp, not a corner).
	for i in range(1, 10):
		var a: float = PI - (i / 9.0) * (PI * 0.5)
		c.add_point(BEND_CENTRE + Vector2(cos(a), sin(a)) * BEND_R)
	for x in range(4, 41, 4):
		c.add_point(Vector2(BEND_CENTRE.x + float(x), BEND_CENTRE.y + BEND_R))
	return c


# The bend as TWO pieces, so the sharp corner's span ends where the arc does (the next
# piece's entry pose) instead of running on down the trailing straight. That keeps the
# planned run inside the arc, where the radial ground fields below are exact.
func _bend_pieces() -> Array:
	var arc_end := BEND_CENTRE + Vector2(0.0, BEND_R)   # (16, 56): heading +X from here
	return [
		_piece("Square"),
		{"corner": "Straight", "flip": false, "straight": 0.0,
			"entry_pos": arc_end, "entry_heading": Vector2(1.0, 0.0)},
	]


# A ground field for the bend: flat at road level out to `BEND_R + 5` from the corner's
# centre, then stepping to `outboard` beyond it. The step sits OUTSIDE the barrier line
# (BEND_R + ~4) but inside both probes (BEND_R + 6.25 and + 8.5), so the barrier stands
# on level ground and only the probes read the change — a drop with `outboard` negative,
# a bank with it positive. `only_beyond_z` restricts the change to part of the arc.
func _radial_ground(outboard: float, only_beyond_z := -INF) -> Callable:
	return func(p: Vector2) -> float:
		if p.distance_to(BEND_CENTRE) <= BEND_R + 5.0:
			return 0.0
		return outboard if p.y > only_beyond_z else 0.0


# A straight curve up +Z.
func _straight_curve() -> Curve2D:
	var c := Curve2D.new()
	for z in range(0, 61, 5):
		c.add_point(Vector2(0.0, float(z)))
	return c


# One piece whose corner begins `straight` metres along +Z from the origin.
func _piece(corner: String, straight := 40.0) -> Dictionary:
	return {"corner": corner, "flip": false, "straight": straight,
		"entry_pos": Vector2.ZERO, "entry_heading": Vector2(0.0, 1.0)}


func test_only_sharp_corners_get_a_barrier() -> void:
	var curve := _right_bend_curve()
	for corner in BarrierLayout.BARRIER_CORNERS:
		var plan := BarrierLayout.plan(curve, [_piece(corner)], _params())
		assert_gt(plan.size(), 0, "corner %s gets a barrier run" % corner)
	# Gentler corners (and straights) are left bare — a sweeper needs no armco.
	for corner in ["3", "4", "5", "6", "Straight"]:
		if BarrierLayout.BARRIER_CORNERS.has(corner):
			continue
		var plan := BarrierLayout.plan(curve, [_piece(corner)], _params())
		assert_eq(plan.size(), 0, "corner %s is left bare" % corner)


func test_modules_are_stitched_at_the_configured_pitch() -> void:
	var curve := _right_bend_curve()
	var plan := BarrierLayout.plan(curve, [_piece("Hairpin")], _params())
	assert_gt(plan.size(), 1, "a run has several modules")
	# Consecutive modules sit one pitch apart ON THE BARRIER LINE, which is what makes
	# their meshes (each a pitch long, overrunning its ends) meet. Spacing them along
	# the CENTERLINE instead would fan them apart on the outside of the bend, because
	# that is the shorter arc. Straight-line distance is a touch under the arc on a
	# bend, so allow the chord shortfall.
	for i in range(1, plan.size()):
		var d: float = _barrier_point(plan[i]).distance_to(_barrier_point(plan[i - 1]))
		assert_almost_eq(d, PITCH, 0.1, "module %d is one pitch from its neighbour" % i)


func test_modules_are_not_pitched_along_the_centerline() -> void:
	# Guard the bug directly: on the outside of a bend the barrier line is the LONGER
	# arc, so centerline spacing must come out visibly SHORTER than the pitch (it is
	# pitch * R / (R + lateral)). If this ever equals the pitch, the run is fanning
	# apart again and every joint has a hole in it.
	var plan := BarrierLayout.plan(_right_bend_curve(), [_piece("Square")], _params())
	assert_gt(plan.size(), 2, "a run has several modules")
	# The run covers the bend AND the straights either side of it, where centerline and
	# barrier line are the same length — so check the TIGHTEST pair, which is the one
	# deepest into the bend.
	var tightest := PITCH * 10.0
	for i in range(1, plan.size()):
		var d: float = (plan[i]["pos"] as Vector2).distance_to(plan[i - 1]["pos"])
		tightest = minf(tightest, d)
		assert_lt(d, PITCH * 1.05, "no pair is spaced WIDER than the pitch")
	assert_lt(tightest, PITCH * 0.95,
		"in the bend, modules sit closer on the centerline than the pitch")


func test_the_run_sits_on_the_outside_of_the_bend() -> void:
	# The curve above bends toward +X, so the outside of the corner is -X. Placement
	# is pos + side * Vector2(-tangent.y, tangent.x) * distance, so check where that
	# actually lands rather than trusting a sign convention.
	var curve := _right_bend_curve()
	var plan := BarrierLayout.plan(curve, [_piece("Square")], _params())
	assert_gt(plan.size(), 0, "the corner got a run")
	for entry in plan:
		var pos: Vector2 = entry["pos"]
		var tangent: Vector2 = entry["tangent"]
		var perp := Vector2(-tangent.y, tangent.x)
		var edge: Vector2 = pos + float(entry["side"]) * perp * 5.0
		assert_gt(edge.distance_to(BEND_CENTRE), pos.distance_to(BEND_CENTRE),
			"the barrier is further from the corner's inside than the centerline is")


func test_the_style_follows_the_road_surface() -> void:
	var curve := _right_bend_curve()
	var piece := _piece("Hairpin")
	var all_tarmac := func(_p: Vector2) -> float: return 1.0
	var all_gravel := func(_p: Vector2) -> float: return 0.0
	for entry in BarrierLayout.plan(curve, [piece], _params(), all_tarmac):
		assert_eq(entry["style"], BarrierSection.Style.JERSEY,
			"a tarmac corner gets the concrete jersey rail")
	for entry in BarrierLayout.plan(curve, [piece], _params(), all_gravel):
		assert_eq(entry["style"], BarrierSection.Style.ARMCO,
			"a gravel corner gets the steel armco")
	# With no surface sampler at all (a caller with no baked terrain) it must still
	# plan a run rather than fail — falling back to the gravel barrier.
	var plan := BarrierLayout.plan(curve, [piece], _params())
	assert_gt(plan.size(), 0, "no sampler still plans a run")
	assert_eq(plan[0]["style"], BarrierSection.Style.ARMCO, "the fallback is armco")


func test_a_surface_switch_inside_a_corner_switches_the_barrier() -> void:
	# Half the corner on tarmac, half on gravel: the run must carry both styles, so
	# the barrier changes type at the seam instead of picking one for the whole run.
	var curve := _right_bend_curve()
	# x rises from 0 to 56 across the run, so this splits it mid-corner.
	var split := func(p: Vector2) -> float: return 1.0 if p.x > 8.0 else 0.0
	var plan := BarrierLayout.plan(curve, [_piece("Hairpin")], _params(), split)
	var styles := {}
	for entry in plan:
		styles[entry["style"]] = true
	assert_eq(styles.size(), 2, "the run switches barrier where the surface switches")


func test_lead_extends_the_run_beyond_the_corner() -> void:
	var curve := _right_bend_curve()
	var piece := _piece("Square")
	var tight := BarrierLayout.plan(curve, [piece], _params(0.0))
	var lead := BarrierLayout.plan(curve, [piece], _params(10.0))
	assert_gt(lead.size(), tight.size(), "a lead-in adds modules either side of the corner")


func test_adjacent_runs_do_not_stack_on_the_same_verge() -> void:
	# Two sharp corners whose lead-ins would overlap: the second run must start where
	# the first ended, not double up a second barrier over the same stretch.
	var curve := _straight_curve()
	var pieces := [_piece("Hairpin", 10.0), _piece("Square", 14.0)]
	var plan := BarrierLayout.plan(curve, pieces, _params(30.0))
	assert_gt(plan.size(), 0, "something was planned")
	var seen := []
	for entry in plan:
		for other in seen:
			assert_gt((entry["pos"] as Vector2).distance_to(other), PITCH * 0.5,
				"no two modules land on top of each other")
		seen.append(entry["pos"])


func test_degenerate_input_plans_nothing() -> void:
	assert_eq(BarrierLayout.plan(null, [_piece("Square")], _params()).size(), 0,
		"a null centerline plans nothing")
	assert_eq(BarrierLayout.plan(Curve2D.new(), [_piece("Square")], _params()).size(), 0,
		"an empty centerline plans nothing")
	assert_eq(BarrierLayout.plan(_right_bend_curve(), [], _params()).size(), 0,
		"no pieces plans nothing")


func test_plan_is_deterministic() -> void:
	var curve := _right_bend_curve()
	var a := BarrierLayout.plan(curve, [_piece("Hairpin")], _params(6.0))
	var b := BarrierLayout.plan(curve, [_piece("Hairpin")], _params(6.0))
	assert_eq(a.size(), b.size(), "same input, same module count")
	for i in range(a.size()):
		assert_eq(a[i]["pos"], b[i]["pos"], "module %d lands in the same place" % i)
		assert_eq(a[i]["side"], b[i]["side"], "module %d picks the same edge" % i)


# --- The terrain rule: barriers guard drops, not banks -------------------------

func test_a_drop_on_the_outside_gets_a_barrier() -> void:
	var plan := BarrierLayout.plan(_right_bend_curve(), _bend_pieces(), _params(),
		Callable(), _radial_ground(-8.0))
	assert_gt(plan.size(), 2, "a corner with the land falling away outboard is barriered")


func test_a_bank_on_the_outside_gets_no_barrier() -> void:
	# The hillside already stops the car, and a guardrail buried in a slope looks wrong.
	var plan := BarrierLayout.plan(_right_bend_curve(), _bend_pieces(), _params(),
		Callable(), _radial_ground(8.0))
	assert_eq(plan.size(), 0, "a corner cut into a bank gets nothing")


func test_flat_ground_gets_no_barrier() -> void:
	# "Only if there is a drop" — level verge is not a drop, so it goes unguarded.
	var flat := func(_p: Vector2) -> float: return 0.0
	var plan := BarrierLayout.plan(_right_bend_curve(), _bend_pieces(), _params(),
		Callable(), flat)
	assert_eq(plan.size(), 0, "flat ground either side gets nothing")


func test_only_the_falling_stretch_of_a_corner_is_barriered() -> void:
	# Half the corner falling away, half level: the barrier covers the falling half only,
	# rather than the whole corner or none of it.
	var pieces := _bend_pieces()
	var full := BarrierLayout.plan(_right_bend_curve(), pieces, _params(),
		Callable(), _radial_ground(-8.0))
	var partial := BarrierLayout.plan(_right_bend_curve(), pieces, _params(),
		Callable(), _radial_ground(-8.0, 48.0))
	assert_gt(partial.size(), 0, "the falling stretch is barriered")
	assert_lt(partial.size(), full.size(), "the level stretch is not")


func test_a_stretch_shorter_than_the_minimum_is_dropped() -> void:
	# A one- or two-module stub reads as debris on the verge, so it is not built at all.
	var pieces := _bend_pieces()
	var ground := _radial_ground(-8.0, 54.0)   # only the last sliver of the arc falls
	var kept := BarrierLayout.plan(_right_bend_curve(), pieces, _params(0.0, 0.5, 1),
		Callable(), ground)
	assert_gt(kept.size(), 0, "setup: the falling sliver does yield modules")
	# Raise the minimum past everything that survived: whatever stretches those modules
	# formed, each is now too short, so the whole lot goes.
	var filtered := BarrierLayout.plan(_right_bend_curve(), pieces,
		_params(0.0, 0.5, kept.size() + 1), Callable(), ground)
	assert_eq(filtered.size(), 0, "a stub shorter than the minimum is not built")


func test_no_ground_sampler_keeps_every_module() -> void:
	# A caller with no terrain to read (the render harness, a bare unit test) must still
	# get a full run rather than silently nothing.
	var pieces := _bend_pieces()
	var blind := BarrierLayout.plan(_right_bend_curve(), pieces, _params())
	var seeing := BarrierLayout.plan(_right_bend_curve(), pieces, _params(),
		Callable(), _radial_ground(-8.0))
	assert_gt(blind.size(), 0, "no sampler still plans a run")
	assert_eq(blind.size(), seeing.size(), "…the same run a fully-falling corner gets")


func test_each_separated_stretch_is_its_own_run() -> void:
	# Runs are the batching unit, so two stretches split by a level middle must not share
	# a run index (they would end up in one MultiMesh anchored between them).
	var ground := func(p: Vector2) -> float:
		if p.distance_to(BEND_CENTRE) <= BEND_R + 5.0:
			return 0.0
		# Falls away at both ends of the arc, level across its middle.
		return 0.0 if p.y > 46.0 and p.y < 52.0 else -8.0
	var plan := BarrierLayout.plan(_right_bend_curve(), _bend_pieces(),
		_params(0.0, 0.5, 1), Callable(), ground)
	var runs := {}
	for entry in plan:
		runs[entry["run"]] = true
	assert_gt(runs.size(), 1, "the split corner yields more than one run")


# --- Slope: spacing follows the sloping ground, not its shadow -----------------

# Ground for the STRAIGHT curve: climbs `grade` along the run (+Z) and falls away 8 m on
# the -X side, which is the outside the planner picks for a straight. The fall starts
# outboard of the barrier but inside both probes, and does not vary along the run, so the
# whole straight is one unbroken barriered stretch on a constant gradient.
func _straight_ramp(grade: float) -> Callable:
	return func(p: Vector2) -> float:
		var climb := grade * p.y
		return climb - 8.0 if p.x < -6.0 else climb


func _spacings_along_the_barrier(plan: Array) -> Array:
	var out: Array = []
	for i in range(1, plan.size()):
		if int(plan[i]["run"]) != int(plan[i - 1]["run"]):
			continue   # a joint between separate runs is not a module joint
		out.append(_barrier_point(plan[i]).distance_to(_barrier_point(plan[i - 1])))
	return out


func test_a_climb_tightens_the_horizontal_spacing() -> void:
	# A module is a rigid PITCH-long bar: laid on a climb it covers only
	# PITCH * cos(slope) of GROUND, so centres have to be spaced along the sloping
	# ground. Space them horizontally instead and every joint opens a gap that grows with
	# the gradient. So on a ramp the horizontal spacing must come out short of the pitch,
	# by exactly the cosine.
	var grade := 0.30
	var plan := BarrierLayout.plan(_straight_curve(), [_piece("Hairpin", 5.0)], _params(),
		Callable(), _straight_ramp(grade))
	var spacings := _spacings_along_the_barrier(plan)
	assert_gt(spacings.size(), 2, "the climb is barriered as one run")
	var expected: float = PITCH / sqrt(1.0 + grade * grade)
	for i in range(spacings.size()):
		assert_almost_eq(float(spacings[i]), expected, 0.05,
			"joint %d is a pitch apart ALONG THE GROUND" % i)


func test_level_ground_still_spaces_by_the_pitch() -> void:
	# The 3D spacing must collapse back to the plain pitch with no gradient, or every
	# flat run silently changes length.
	var plan := BarrierLayout.plan(_straight_curve(), [_piece("Hairpin", 5.0)], _params(),
		Callable(), _straight_ramp(0.0))
	var spacings := _spacings_along_the_barrier(plan)
	assert_gt(spacings.size(), 2, "the run is barriered")
	for i in range(spacings.size()):
		assert_almost_eq(float(spacings[i]), PITCH, 0.02, "joint %d is one pitch along" % i)

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


func _params(lead := 0.0, threshold := 0.5) -> Dictionary:
	return {
		"section_length_m": PITCH,
		"lead_m": lead,
		"tarmac_threshold": threshold,
		"track_width": TRACK_WIDTH,
		"road_gap_m": ROAD_GAP,
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

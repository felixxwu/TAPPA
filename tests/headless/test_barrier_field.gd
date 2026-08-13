extends GutTest
# BarrierField: the corner-barrier builder (scripts/barrier_field.gd). It takes its
# terrain as an injected `func(Vector2) -> float` height sampler, so these run with a
# synthetic ground and NO scene, terrain or world — hand-built layouts, and the exact
# poses read back off `module_transforms`.
#
# What matters here: modules land outside the road facing it, they are PITCHED onto the
# ground so a run joins up over a slope, and a whole run renders batched with one solid
# hitbox per module.

const PITCH := 2.0
const TRACK_WIDTH := 7.0
const ROAD_GAP := 0.5
const RAMP := 0.15   # ground metres climbed per metre along +Z in _ramp()

var _fields: Array[Node] = []


func after_each() -> void:
	for f in _fields:
		if is_instance_valid(f):
			f.free()
	_fields.clear()


func _params() -> Dictionary:
	return {
		"section_length_m": PITCH,
		"track_width": TRACK_WIDTH,
		"road_gap_m": ROAD_GAP,
		"sink_m": 0.0,
		"render_distance_m": 0.0,
		"render_fade_m": 0.0,
	}


# A straight run of `count` modules up +Z at the origin's road, all one style.
func _layout(count: int, style := BarrierSection.Style.ARMCO) -> Array:
	var out: Array = []
	for i in range(count):
		out.append({"pos": Vector2(0.0, i * PITCH), "tangent": Vector2(0.0, 1.0),
			"side": 1, "style": style, "run": 0})
	return out


func _flat() -> Callable:
	return func(_p: Vector2) -> float: return 0.0


# Ground climbing steadily along +Z — the "up a hill" case.
func _ramp() -> Callable:
	return func(p: Vector2) -> float: return RAMP * p.y


func _build(layout: Array, ground := Callable()) -> BarrierField:
	var field := BarrierField.new()
	add_child(field)
	_fields.append(field)
	field.build(layout, _params(), ground)
	return field


# A module's two end points in world space: its origin walked along its own length axis.
func _ends(xform: Transform3D) -> Array:
	var half: Vector3 = xform.basis.z.normalized() * (PITCH * 0.5)
	return [xform.origin - half, xform.origin + half]


func test_a_run_stands_outside_the_road_facing_it() -> void:
	var layout := _layout(4)
	var field := _build(layout, _flat())
	assert_eq(field.barrier_count, layout.size(), "one module per layout entry")
	for i in range(layout.size()):
		var xform: Transform3D = field.module_transforms[i]
		var centre: Vector2 = layout[i]["pos"]
		var here := Vector2(xform.origin.x, xform.origin.z)
		assert_gt(here.distance_to(centre), TRACK_WIDTH * 0.5,
			"module %d stands beyond the road edge" % i)
		var to_road := Vector3(centre.x - here.x, 0.0, centre.y - here.y).normalized()
		assert_gt(xform.basis.x.normalized().dot(to_road), 0.9, "module %d faces the road" % i)


func test_a_run_on_level_ground_stays_level() -> void:
	var field := _build(_layout(4), _flat())
	for i in range(field.module_transforms.size()):
		var xform: Transform3D = field.module_transforms[i]
		assert_almost_eq(xform.basis.z.normalized().y, 0.0, 0.0001,
			"module %d is level" % i)
		assert_almost_eq(xform.origin.y, 0.0, 0.0001, "module %d sits on the ground" % i)


func test_modules_are_pitched_onto_the_slope() -> void:
	# The length axis follows the ground's gradient — without this a run up a hill is a
	# staircase of level modules with a gap at every joint.
	var field := _build(_layout(5), _ramp())
	var expected := Vector3(0.0, RAMP, 1.0).normalized().y
	for i in range(field.module_transforms.size()):
		var xform: Transform3D = field.module_transforms[i]
		assert_almost_eq(xform.basis.z.normalized().y, expected, 0.005,
			"module %d leans along the slope" % i)


func test_a_pitched_module_does_not_roll_sideways() -> void:
	# It leans ALONG the run only: the road-facing axis stays horizontal, so posts stand
	# up rather than the whole barrier tipping toward the road.
	var field := _build(_layout(4), _ramp())
	for i in range(field.module_transforms.size()):
		var basis: Basis = field.module_transforms[i].basis
		assert_almost_eq(basis.x.normalized().y, 0.0, 0.0001, "module %d has no roll" % i)
		assert_almost_eq(basis.get_scale(), Vector3.ONE, Vector3.ONE * 0.001,
			"module %d is not skewed or scaled" % i)


func test_stitched_modules_meet_in_HEIGHT_over_a_slope() -> void:
	# The joint test that matters on a hill: neighbouring ends must arrive at the same
	# HEIGHT, so the rail is continuous instead of stepping. (Their horizontal spacing is
	# the planner's job — BarrierLayout spaces centres along the sloping ground for
	# exactly this reason; see test_barrier_layout.gd. This layout is hand-spaced flat.)
	var field := _build(_layout(6), _ramp())
	for i in range(1, field.module_transforms.size()):
		var prev_front: Vector3 = _ends(field.module_transforms[i - 1])[1]
		var this_back: Vector3 = _ends(field.module_transforms[i])[0]
		assert_almost_eq(this_back.y, prev_front.y, 0.02,
			"module %d meets its neighbour's end height" % i)


func test_each_module_sits_on_the_ground_under_its_ends() -> void:
	# Sunk/floating check on a slope: a module's ends follow the terrain rather than a
	# single centre height being reused for the whole module.
	var ground := _ramp()
	var field := _build(_layout(4), ground)
	for i in range(field.module_transforms.size()):
		for end: Vector3 in _ends(field.module_transforms[i]):
			var expect: float = float(ground.call(Vector2(end.x, end.z)))
			assert_almost_eq(end.y, expect, 0.01, "module %d has an end on the ground" % i)


func test_a_run_renders_batched_and_collides_as_one_obstacle_body() -> void:
	var field := _build(_layout(5, BarrierSection.Style.JERSEY), _ramp())
	var mms := field.get_children().filter(func(c): return c is MultiMeshInstance3D)
	assert_gt(mms.size(), 0, "a run renders through MultiMeshes")
	for mmi: MultiMeshInstance3D in mms:
		assert_eq(mmi.multimesh.instance_count, field.barrier_count,
			"each part batch carries one instance per module")
	assert_eq(field.get_children().filter(func(c): return c is MeshInstance3D).size(), 0,
		"no per-module mesh nodes — the whole run is batched")
	var bodies := field.get_children().filter(func(c): return c is StaticBody3D)
	assert_eq(bodies.size(), 1, "one shared-shape body for the run")
	var body := bodies[0] as StaticBody3D
	assert_true(body.is_in_group(DamageModel.OBSTACLE_GROUP), "a barrier is a damage obstacle")
	assert_eq(PhysicsServer3D.body_get_shape_count(body.get_rid()), field.barrier_count,
		"one collision box per module, sharing one shape")


func test_two_styles_in_one_run_build_separate_batches() -> void:
	# A stage whose surface switches mid-corner: each style needs its own batches and
	# its own hitbox size, but they belong to the same run.
	var layout := _layout(3)
	for entry in _layout(3, BarrierSection.Style.JERSEY):
		entry["pos"] = Vector2(0.0, 6.0 + float(entry["pos"].y))
		layout.append(entry)
	var field := _build(layout, _flat())
	assert_eq(field.barrier_count, 6, "every module is built")
	assert_eq(field.get_children().filter(func(c): return c is StaticBody3D).size(), 2,
		"one hitbox body per style")


func test_an_empty_layout_builds_nothing() -> void:
	var field := _build([], _flat())
	assert_eq(field.barrier_count, 0, "no modules")
	assert_eq(field.get_child_count(), 0, "and no nodes at all")

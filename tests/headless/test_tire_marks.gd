extends GutTest
# TireMarks: gravel ruts laid behind the wheels (features/tire-marks.md). Driven
# against a straight Curve2D with a stub car + stub wheels, so the gating /
# emission / ring-buffer logic is tested without a real vehicle or rendering.


# Stub wheel: duck-typed like VehicleWheel3D (is_in_contact + global_position).
class StubWheel:
	extends Node3D
	var _contact := true
	func is_in_contact() -> bool:
		return _contact


# Stub car: just the bits TireMarks reads — a velocity, a position, and (for the
# tarmac-skid gate) an optional drivetrain. Null drivetrain = can't detect spin.
class StubCar:
	extends Node3D
	var linear_velocity := Vector3(0, 0, 10.0)  # moving, above the speed floor
	var drivetrain = null


# Stub drivetrain: the slice TireMarks._wheel_spinning reads, mirroring Drivetrain.
# `surface_speed` is the tread speed (omega x radius); `roll_speed` is the ground
# speed along the roll direction. Wheelspin = surface_speed − roll_speed.
class StubDrivetrain:
	extends RefCounted
	var driven := true
	var surface_speed := 0.0
	var roll_speed := 0.0
	func is_wheel_driven(_w) -> bool:
		return driven
	func wheel_omega(_w) -> float:
		return surface_speed / maxf(Config.data.wheel_radius, 0.0001)
	func wheel_forward(_w) -> Vector3:
		return Vector3(0, 0, 1)
	func velocity_at(_cp) -> Vector3:
		return Vector3(0, 0, roll_speed)


# Stub terrain: reports (road_weight, tarmac_weight) like TerrainManager.surface_at.
# A constant tarmac-ness lets a test put the whole road on tarmac (or gravel).
# Extends Node because TireMarks.setup() types the terrain argument as Node.
class StubTerrain:
	extends Node
	var tarmac := 0.0
	func surface_at(_x: float, _z: float) -> Vector2:
		return Vector2(1.0, tarmac)


var _car: StubCar
var _curve: Curve2D
var _wheels: Array = []


func before_each() -> void:
	Config.reset()
	Config.data.tire_marks_enabled = true
	# A straight road 200 m along +Z (curve points are Vector2(world_x, world_z)).
	_curve = Curve2D.new()
	_curve.add_point(Vector2(0, 0))
	_curve.add_point(Vector2(0, 200))
	_car = StubCar.new()
	add_child_autofree(_car)
	_wheels = []
	for i in 4:
		var w := StubWheel.new()
		_car.add_child(w)  # in-tree so global_position resolves
		_wheels.append(w)


func after_each() -> void:
	Config.reset()


func _make(half_width := 3.0) -> TireMarks:
	var tm := TireMarks.new()
	add_child_autofree(tm)
	tm.setup(_curve, _car, null, half_width)  # null terrain -> ground height 0
	return tm


func _make_with_terrain(terrain: StubTerrain, half_width := 3.0) -> TireMarks:
	add_child_autofree(terrain)
	var tm := TireMarks.new()
	add_child_autofree(tm)
	tm.setup(_curve, _car, terrain, half_width)
	return tm


# Drive the car (and its wheels) to world z and tick. Wheels are children of the
# car, so each wheel's local x with the car at z puts it at world (x, 0, z) — car
# and wheels advance together (the gravel gate searches the centerline around the
# CAR's offset, so the wheels must stay near the car, as in real play). `xs` is the
# per-wheel lateral offset from the centerline; pass fewer to leave wheels at 0.
func _drive(tm: TireMarks, z: float, xs: Array) -> void:
	_car.position = Vector3(0.0, 0.0, z)
	for i in _wheels.size():
		var x: float = xs[i] if i < xs.size() else 0.0
		_wheels[i].position = Vector3(x, 0.0, 0.0)  # local; world == (x, 0, z)
	tm._physics_process(0.0)


func test_collects_four_wheels() -> void:
	var tm := _make()
	assert_eq(tm.wheel_count(), 4, "one ribbon per wheel")


func test_warm_up_draws_then_clears() -> void:
	# warm_up() adds a throwaway quad (same material) so the shader compiles behind
	# the loading screen; clear_warm_up() must free it again.
	var tm := _make()
	tm.warm_up(Vector3(0, 0, 10))
	assert_not_null(tm._warm_mi, "warm-up creates a drawable quad")
	assert_gt((tm._warm_mi.mesh as Mesh).get_surface_count(), 0, "the warm-up quad has geometry to draw")
	tm.clear_warm_up()
	assert_null(tm._warm_mi, "clear_warm_up drops the warm-up quad")


func test_marks_accumulate_on_gravel() -> void:
	var tm := _make()
	# Wheels straddle the centerline (|x| <= 3.3 gate) — on the gravel — advancing
	# 1 m per tick (> the 0.5 m segment step).
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_gt(tm.segment_count(i), 1, "wheel %d lays a ribbon on the gravel" % i)


func test_no_marks_off_the_gravel() -> void:
	var tm := _make()
	# Wheels far to the side (x = 10 m > 3.3 gate) while the car drives the road.
	for s in 6:
		_drive(tm, s, [10.0, 10.0, 10.0, 10.0])
	for i in 4:
		assert_eq(tm.segment_count(i), 0, "wheel %d off the gravel lays no marks" % i)


func test_marks_lay_on_gravel_surface() -> void:
	# Terrain present and reporting gravel (tarmac_weight 0): the road marks as before.
	var terrain := StubTerrain.new()
	terrain.tarmac = 0.0
	var tm := _make_with_terrain(terrain)
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_gt(tm.segment_count(i), 1, "wheel %d lays a ribbon on the gravel" % i)


func test_no_marks_on_tarmac_without_wheelspin() -> void:
	# On tarmac (tarmac_weight 1) but the wheels roll cleanly (no drivetrain spin) —
	# a cleanly rolling wheel on tarmac leaves no skidmark.
	var terrain := StubTerrain.new()
	terrain.tarmac = 1.0
	_car.drivetrain = StubDrivetrain.new()  # not spinning (surface == roll == 0)
	var tm := _make_with_terrain(terrain)
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_eq(tm.segment_count(i), 0, "wheel %d rolling on tarmac lays no skidmark" % i)


func test_skidmarks_on_tarmac_under_wheelspin() -> void:
	# On tarmac with the driven wheels spinning (tread outrunning the ground past the
	# slip floor): a dark skidmark IS laid.
	var terrain := StubTerrain.new()
	terrain.tarmac = 1.0
	var dt := StubDrivetrain.new()
	dt.surface_speed = 20.0  # tread speed
	dt.roll_speed = 5.0      # ground speed -> slip 15 m/s >> the min-slip floor
	_car.drivetrain = dt
	var tm := _make_with_terrain(terrain)
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_gt(tm.segment_count(i), 1, "wheel %d spinning on tarmac lays a skidmark" % i)


func test_no_skidmarks_on_tarmac_from_undriven_wheels() -> void:
	# A spinning reading but the wheel is undriven (free-rolling): no skidmark, matching
	# the gravel-spray gate that only fires for driven wheels.
	var terrain := StubTerrain.new()
	terrain.tarmac = 1.0
	var dt := StubDrivetrain.new()
	dt.driven = false
	dt.surface_speed = 20.0
	dt.roll_speed = 5.0
	_car.drivetrain = dt
	var tm := _make_with_terrain(terrain)
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_eq(tm.segment_count(i), 0, "undriven wheel %d on tarmac lays no skidmark" % i)


func test_corner_wheel_on_road_ahead_still_marks() -> void:
	# Curved road: up +Z to (0,40), then a 90-degree turn running +X. A wheel that's
	# on the post-bend road but well ahead of the car along the curve must still mark
	# — it's gated by ITS OWN nearest road point (distance 0 here), not the car's
	# tangent (against which it reads ~5 m off-axis and would be wrongly rejected).
	var curve := Curve2D.new()
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(0, 40))
	curve.add_point(Vector2(40, 40))
	var tm := TireMarks.new()
	add_child_autofree(tm)
	tm.setup(curve, _car, null, 3.0)
	_car.position = Vector3(0, 0, 35)            # just before the bend
	_wheels[0].global_position = Vector3(5, 0, 40)  # on the post-bend road, 5 m along +X
	tm._physics_process(0.0)
	assert_gt(tm.segment_count(0), 0, "a wheel on the road ahead of the bend still marks")


func test_sub_step_movement_adds_no_segment() -> void:
	var tm := _make()
	_drive(tm, 0.0, [])           # first point
	var after_first := tm.segment_count(0)
	_drive(tm, 0.1, [])           # moved 0.1 m < 0.5 m step
	assert_eq(tm.segment_count(0), after_first, "no new segment until the wheel moves a full step")


func test_ring_buffer_caps_segments() -> void:
	Config.data.tire_mark_max_segments = 5
	var tm := _make()
	for s in 50:
		_drive(tm, s, [])
	assert_eq(tm.segment_count(0), 5, "the per-wheel ribbon is capped to max_segments")


func test_below_min_speed_lays_nothing() -> void:
	var tm := _make()
	_car.linear_velocity = Vector3(0, 0, 0.5)  # below the 2 m/s floor
	for s in 6:
		_drive(tm, s, [])
	assert_eq(tm.segment_count(0), 0, "no marks below the speed floor")


func test_airborne_wheel_stops_marking() -> void:
	var tm := _make()
	_drive(tm, 0.0, [])
	_drive(tm, 1.0, [])
	var before := tm.segment_count(0)
	_wheels[0]._contact = false  # lift the wheel off the ground
	_drive(tm, 2.0, [])
	assert_eq(tm.segment_count(0), before, "an airborne wheel lays no new segment")


func test_incremental_buffer_matches_full_rebuild() -> void:
	# The ribbon mesh is maintained incrementally (append a quad per segment, trim
	# one off the front when the ring buffer drops a point) rather than rebuilt from
	# _pairs each emit. That incremental buffer must always equal a from-scratch
	# rebuild — exercise growth, a mid-strip gap (airborne), and the cap, then compare.
	Config.data.tire_mark_max_segments = 4
	var tm := _make()
	_drive(tm, 0.0, [])          # strip start
	_drive(tm, 1.0, [])          # connected
	_drive(tm, 2.0, [])          # connected
	_wheels[0]._contact = false  # airborne: breaks the strip
	_drive(tm, 3.0, [])
	_wheels[0]._contact = true
	_drive(tm, 4.0, [])          # landing point: starts a NEW strip (a gap here)
	for s in range(5, 12):       # keep laying so the ring buffer pops from the front
		_drive(tm, float(s), [])
	tm.flush_uploads()           # uploads are coalesced to a rendered frame
	var expected: Dictionary = TireMarks._build_ribbon(tm._pairs[0])
	assert_eq(tm.ribbon_verts(0), expected["verts"], "incremental verts match a full rebuild")
	assert_eq(tm.ribbon_cols(0), expected["cols"], "incremental colours match a full rebuild")


func test_uploads_are_coalesced_to_one_per_wheel_per_frame() -> void:
	# Mesh uploads are batched to at most one per wheel per RENDERED frame, not one per
	# physics tick — the expensive part (clear_surfaces + add_surface_from_arrays) must
	# not scale with the tick rate.
	var tm := _make()
	for s in 12:
		_drive(tm, float(s), [-0.8, 0.8, -0.8, 0.8])
	assert_gt(tm.segment_count(0), 1, "the run laid several segments (precondition)")
	assert_eq(tm.upload_count(), 0, "no mesh upload happens on the physics tick itself")
	tm.flush_uploads()
	assert_eq(tm.upload_count(), tm.wheel_count(),
		"one upload per wheel for the whole batch of ticks, not one per segment")
	# And a second flush with nothing new does no work at all.
	tm.flush_uploads()
	assert_eq(tm.upload_count(), tm.wheel_count(), "a clean flush uploads nothing")


func test_coalescing_loses_no_segments() -> void:
	# The real risk of batching: geometry emitted between flushes going missing. After a
	# single flush covering many ticks, what actually reached each wheel's MESH must equal
	# the reference full rebuild of its segment list — same geometry, fewer uploads. Read
	# the surface back off the mesh rather than an internal buffer, so this can't pass on
	# a ribbon that was staged but never uploaded.
	var tm := _make()
	for s in 15:
		_drive(tm, float(s), [-0.8, 0.8, -0.8, 0.8])
	tm.flush_uploads()
	for i in tm.wheel_count():
		var expected: Dictionary = TireMarks._build_ribbon(tm._pairs[i])
		var mesh := tm._ribbons[i].mesh as ArrayMesh
		assert_eq(mesh.get_surface_count(), 1,
			"wheel %d: the ribbon mesh has a drawable surface after the flush" % i)
		var arrays: Array = mesh.surface_get_arrays(0)
		assert_eq(arrays[Mesh.ARRAY_VERTEX], expected["verts"],
			"wheel %d: the uploaded mesh holds every segment's verts" % i)
		# Colours round-trip through the mesh's 8-bit-per-channel storage, so compare
		# the count exactly and the values approximately.
		var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var want: PackedColorArray = expected["cols"]
		assert_eq(cols.size(), want.size(),
			"wheel %d: the uploaded mesh holds every segment's colours" % i)
		assert_almost_eq(cols[0].r, want[0].r, 0.01,
			"wheel %d: the uploaded colour is the segment's colour" % i)


func test_coalescing_survives_a_broken_strip_and_the_cap() -> void:
	# Batch several ticks that also cross a break (airborne) and the ring-buffer cap,
	# then flush once: the mesh still matches the reference rebuild, so neither the
	# dropped front quads nor the gap desync the coalesced upload.
	Config.data.tire_mark_max_segments = 4
	var tm := _make()
	for s in 3:
		_drive(tm, float(s), [])
	_wheels[0]._contact = false
	_drive(tm, 3.0, [])
	_wheels[0]._contact = true
	for s in range(4, 14):
		_drive(tm, float(s), [])
	tm.flush_uploads()
	var expected: Dictionary = TireMarks._build_ribbon(tm._pairs[0])
	assert_eq(tm.ribbon_verts(0), expected["verts"], "batched verts match the full rebuild")
	assert_eq(tm.ribbon_cols(0), expected["cols"], "batched colours match the full rebuild")
	assert_eq(tm.segment_count(0), Config.data.tire_mark_max_segments,
		"the cap still holds across coalesced uploads")


func test_jump_leaves_a_gap_not_a_stretched_quad() -> void:
	var tm := _make()
	_drive(tm, 0.0, [])          # strip start (point 0)
	_drive(tm, 1.0, [])          # point 1 — connected to 0
	_wheels[0]._contact = false  # car jumps: airborne, no point
	_drive(tm, 5.0, [])
	_wheels[0]._contact = true   # land 4 m further on
	_drive(tm, 5.0, [])          # landing point — must NOT bridge across the jump
	var pairs: Array = tm._pairs[0]
	assert_true(bool(pairs[1][2]), "consecutive on-ground points stay connected")
	assert_false(bool(pairs[pairs.size() - 1][2]),
		"the landing point starts a new strip, leaving a gap across the jump")

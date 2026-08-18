extends GutTest
# TireMarks: gravel ruts laid behind the wheels (features/tire-marks.md). Driven
# against a straight Curve2D with a stub car + stub wheels, so the gating /
# emission / ring-buffer logic is tested without a real vehicle or rendering.


# Stub wheel: duck-typed like VehicleWheel3D (is_in_contact + global_position).
class StubWheel:
	extends Node3D
	var _contact := true
	# VehicleWheel3D's own flag: the front axle steers, which is how the mark width picks
	# between wheel_width_front and wheel_width_rear (car.gd::_relocate_wheels does the same).
	var use_as_steering := true
	func is_in_contact() -> bool:
		return _contact


# Stub car: just the bits TireMarks reads — a velocity, a position, and (for the
# tarmac-skid gate) an optional drivetrain. Null drivetrain = can't detect spin.
class StubCar:
	extends Node3D
	var linear_velocity := Vector3(0, 0, 10.0)  # moving, above the speed floor
	var drivetrain = null


# Stub drivetrain: the live per-wheel tire state TireMarks reads to size each mark —
# the force the tire puts through the ground (gravel ruts) and how far up its grip
# curve it is (tarmac skids). Mirrors Drivetrain.wheel_force_n / wheel_grip_usage.
class StubDrivetrain:
	extends RefCounted
	var force_n := 0.0
	var grip_usage := 0.0
	func wheel_force_n(_w) -> float:
		return force_n
	func wheel_grip_usage(_w) -> float:
		return grip_usage


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


# A fresh all-tarmac surface, for the skid tests.
func _tarmac_terrain() -> StubTerrain:
	var terrain := StubTerrain.new()
	terrain.tarmac = 1.0
	return terrain


# Drive a straight run down the road and hand back the opacity of the mark that laid,
# so an opacity test reads one number instead of re-deriving the drive each time.
func _laid_alpha(tm: TireMarks) -> float:
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	return tm.segment_color(0, 1).a


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


func test_no_marks_on_tarmac_below_the_grip_band() -> void:
	# On tarmac (tarmac_weight 1) with the tires well within their limits — normal
	# driving on a paved road leaves nothing at all.
	Config.data.tire_mark_tarmac_grip_min = 0.8
	Config.data.tire_mark_tarmac_grip_max = 1.0
	var terrain := StubTerrain.new()
	terrain.tarmac = 1.0
	var dt := StubDrivetrain.new()
	dt.grip_usage = 0.5  # cruising, nowhere near the limit
	_car.drivetrain = dt
	var tm := _make_with_terrain(terrain)
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_eq(tm.segment_count(i), 0, "wheel %d within its limits lays no skidmark" % i)


func test_skidmarks_on_tarmac_above_the_grip_band() -> void:
	# Past the top of the band (sliding): a solid dark skidmark IS laid.
	Config.data.tire_mark_tarmac_grip_min = 0.8
	Config.data.tire_mark_tarmac_grip_max = 1.0
	var terrain := StubTerrain.new()
	terrain.tarmac = 1.0
	var dt := StubDrivetrain.new()
	dt.grip_usage = 1.4  # past the limit — the tire is sliding
	_car.drivetrain = dt
	var tm := _make_with_terrain(terrain)
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_gt(tm.segment_count(i), 1, "wheel %d sliding on tarmac lays a skidmark" % i)
		# The CEILING, not 1.0: intensity lives in the alpha now, so a fully-worked tire
		# reaches the authored per-surface maximum rather than full opacity. Read from the
		# config so retuning how dark a skid can get cannot break this.
		assert_almost_eq(tm.segment_color(i, 1).a, Config.data.tire_mark_tarmac_color.a, 0.001,
			"wheel %d past the band reaches the tarmac ceiling" % i)


func test_tarmac_skid_fades_in_across_the_grip_band() -> void:
	# Between the band edges the skid is partly transparent, and harder use is darker.
	# The band is set here rather than read from the config, so this tests the ramp
	# rather than whichever band is currently authored.
	Config.data.tire_mark_tarmac_grip_min = 0.8
	Config.data.tire_mark_tarmac_grip_max = 1.0
	var terrain := StubTerrain.new()
	terrain.tarmac = 1.0
	var dt := StubDrivetrain.new()
	_car.drivetrain = dt
	dt.grip_usage = 0.85
	var low := _laid_alpha(_make_with_terrain(terrain))
	dt.grip_usage = 0.95
	var high := _laid_alpha(_make_with_terrain(_tarmac_terrain()))
	assert_gt(low, 0.0, "inside the band the skid is visible")
	assert_lt(low, Config.data.tire_mark_tarmac_color.a,
		"inside the band the skid has not reached its ceiling")
	assert_gt(high, low, "working the tire harder lays a darker skid")


# --- Gravel rut opacity (tire force) -----------------------------------------

func test_gravel_rut_opacity_scales_with_tire_force() -> void:
	# The rut deepens with how many newtons the tire is putting through the gravel.
	# The reference force is set here, so this tests the ramp, not the authored value.
	Config.data.tire_mark_gravel_full_force_n = 4000.0
	var dt := StubDrivetrain.new()
	_car.drivetrain = dt
	dt.force_n = 1000.0
	var light := _laid_alpha(_make_with_terrain(StubTerrain.new()))
	dt.force_n = 3000.0
	var hard := _laid_alpha(_make_with_terrain(StubTerrain.new()))
	assert_gt(light, 0.0, "a lightly loaded tire still scuffs a faint rut")
	assert_gt(hard, light, "a harder-working tire digs a darker rut")
	assert_lt(hard, Config.data.tire_mark_color.a,
		"below the reference force the rut has not reached its ceiling")


func test_gravel_rut_is_solid_at_and_above_the_reference_force() -> void:
	Config.data.tire_mark_gravel_full_force_n = 4000.0
	var dt := StubDrivetrain.new()
	dt.force_n = 9000.0  # well past the reference — clamps, never overshoots
	_car.drivetrain = dt
	assert_almost_eq(_laid_alpha(_make_with_terrain(StubTerrain.new())),
		Config.data.tire_mark_color.a, 0.001,
		"at or past the reference force the rut reaches the gravel ceiling")


func test_negligible_tire_force_lays_no_gravel_rut() -> void:
	# A mark too faint to see is not laid at all — an invisible quad still rasterises
	# and still sorts in the transparent pass.
	Config.data.tire_mark_gravel_full_force_n = 4000.0
	Config.data.tire_mark_min_alpha = 0.03
	var dt := StubDrivetrain.new()
	dt.force_n = 10.0  # 0.0025 of the reference — far below the cull threshold
	_car.drivetrain = dt
	var tm := _make_with_terrain(StubTerrain.new())
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	assert_eq(tm.segment_count(0), 0, "a mark below the cull threshold is never laid")


# --- The fade toggle ---------------------------------------------------------

func test_disabling_the_fade_lays_solid_marks_in_the_same_places() -> void:
	# tire_mark_alpha_enabled off must change only HOW SOLID marks are, never WHERE they
	# are — same segments, all at full opacity.
	Config.data.tire_mark_gravel_full_force_n = 4000.0
	var dt := StubDrivetrain.new()
	dt.force_n = 1000.0  # a quarter of the reference: clearly faded when the fade is on
	_car.drivetrain = dt
	var faded := _make_with_terrain(StubTerrain.new())
	var faded_alpha := _laid_alpha(faded)
	Config.data.tire_mark_alpha_enabled = false
	var solid := _make_with_terrain(StubTerrain.new())
	var solid_alpha := _laid_alpha(solid)
	var ceiling: float = Config.data.tire_mark_color.a
	assert_lt(faded_alpha, ceiling,
		"with the fade on this mark sits below its surface's ceiling")
	assert_almost_eq(solid_alpha, ceiling, 0.001,
		"with the fade off the same mark is laid at the ceiling")
	assert_eq(solid.segment_count(0), faded.segment_count(0),
		"the same segments are laid either way")


func test_material_transparency_follows_the_toggle() -> void:
	# The ribbons must sit in the transparent pass only while the fade is on — an opaque
	# material there would pay alpha sorting for nothing.
	var tm := _make()
	assert_eq(tm._material.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA,
		"the fade renders the ribbons through the alpha pass")
	assert_eq(tm._material.depth_draw_mode, BaseMaterial3D.DEPTH_DRAW_DISABLED,
		"crossing ribbons must not fight the depth buffer")
	# Flipping the toggle rebuilds the material on the next flush, without a new track.
	Config.data.tire_mark_alpha_enabled = false
	tm.flush_uploads()
	assert_eq(tm._material.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED,
		"with the fade off the ribbons go back to the opaque pass")


func test_flipping_the_toggle_re_uploads_the_ribbons() -> void:
	# A rebuilt material only reaches the GPU when the surfaces are re-uploaded — a
	# ribbon still carrying the old material would keep rendering in the old pass.
	var tm := _make()
	for s in 6:
		_drive(tm, float(s), [-0.8, 0.8, -0.8, 0.8])
	tm.flush_uploads()
	var before := tm.upload_count()
	Config.data.tire_mark_alpha_enabled = false
	tm.flush_uploads()
	assert_eq(tm.upload_count(), before + tm.wheel_count(),
		"every ribbon re-uploads against the rebuilt material")
	for i in tm.wheel_count():
		var mesh := tm._ribbons[i].mesh as ArrayMesh
		assert_eq(mesh.surface_get_material(0), tm._material,
			"wheel %d's surface carries the rebuilt material" % i)


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


# --- Black marks, intensity in the alpha --------------------------------------

func test_both_mark_colours_are_pure_black() -> void:
	# NOT a pinned tunable: how DARK a mark gets is the alpha, and that is free to be
	# retuned. The RGB being black is the contract — these materials are unshaded, so a
	# mark with any colour of its own keeps that colour at full brightness at night and
	# on snow, and reads as paint on top of the world instead of a scuff in it. Black at
	# partial opacity darkens whatever is underneath, in every condition, for free.
	for col: Color in [Config.data.tire_mark_color, Config.data.tire_mark_tarmac_color]:
		assert_almost_eq(col.r, 0.0, 0.001, "mark colour carries no red")
		assert_almost_eq(col.g, 0.0, 0.001, "mark colour carries no green")
		assert_almost_eq(col.b, 0.0, 0.001, "mark colour carries no blue")


func test_a_laid_mark_is_black_whatever_the_surface() -> void:
	# The end-to-end version of the rule: whichever surface branch ran, what reaches the
	# ribbon is black — so the only thing distinguishing a rut from a skid is opacity.
	var dt := StubDrivetrain.new()
	dt.force_n = 3000.0
	dt.grip_usage = 1.4
	_car.drivetrain = dt
	for terrain in [StubTerrain.new(), _tarmac_terrain()]:
		var tm := _make_with_terrain(terrain)
		for s in 6:
			_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
		var col := tm.segment_color(0, 1)
		assert_almost_eq(col.r, 0.0, 0.001, "a laid mark has no red")
		assert_almost_eq(col.g, 0.0, 0.001, "a laid mark has no green")
		assert_almost_eq(col.b, 0.0, 0.001, "a laid mark has no blue")
		assert_gt(col.a, 0.0, "...and is visible through its alpha alone")


# --- Ungated mode (the overworld) ---------------------------------------------
#
# setup() with a NULL centerline drops the corridor test entirely and lets the terrain's
# surface answer decide, because the overworld has a road network rather than one curve.
# See features/tire-marks.md -> "Ungated mode".


# Stub terrain whose ROAD weight is settable too, so a test can put a wheel on open
# ground (road weight 0) as well as on a carved road.
class StubSurface:
	extends Node
	var road := 1.0
	var tarmac := 0.0
	func surface_at(_x: float, _z: float) -> Vector2:
		return Vector2(road, tarmac)


func _make_ungated(terrain: Node) -> TireMarks:
	if terrain != null:
		add_child_autofree(terrain)
	var tm := TireMarks.new()
	add_child_autofree(tm)
	tm.setup(null, _car, terrain, 3.0)
	return tm


func test_ungated_lays_marks_far_from_any_centerline() -> void:
	# Wheels 200 m off the (absent) corridor: with no centerline there is nothing to be
	# off, so the marks still lay. The same drive would be rejected in gated mode.
	var tm := _make_ungated(null)
	for s in 6:
		_drive(tm, s, [-200.0, 200.0, -200.0, 200.0])
	for i in 4:
		assert_gt(tm.segment_count(i), 1, "wheel %d marks with no centerline to gate on" % i)


func test_ungated_grass_does_not_mark() -> void:
	# The terrain's ROAD weight is the ungated gate: open ground lays nothing.
	var surface := StubSurface.new()
	surface.road = 0.0
	var tm := _make_ungated(surface)
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_eq(tm.segment_count(i), 0, "wheel %d lays nothing off a carved road" % i)


func test_ungated_carved_road_marks() -> void:
	# ...and the same drive on a carved road does mark, so the gate is the weight and
	# not simply "ungated never marks".
	var surface := StubSurface.new()
	surface.road = 1.0
	var tm := _make_ungated(surface)
	for s in 6:
		_drive(tm, s, [-0.8, 0.8, -0.8, 0.8])
	for i in 4:
		assert_gt(tm.segment_count(i), 1, "wheel %d marks on a carved road" % i)


func test_gated_mode_still_rejects_off_road_wheels() -> void:
	# The ungated path is purely additive: supplying a centerline keeps the corridor gate.
	var tm := _make()
	for s in 6:
		_drive(tm, s, [-200.0, 200.0, -200.0, 200.0])
	for i in 4:
		assert_eq(tm.segment_count(i), 0, "wheel %d is still gated when a centerline exists" % i)


# --- Mark width and spread direction ------------------------------------------
#
# A segment point is the contact CENTRE spread half a width either side of it, PERPENDICULAR
# TO TRAVEL. Spreading perpendicular to the tyre's HEADING instead is the sideways bug: once
# travel lined up with the spread direction the pairs went collinear and the quads collapsed
# into a sliver. Nothing here pins a tunable — widths are set BY the test and the assertions
# compare against whatever GameConfig currently holds.


# The width of the ribbon's newest pair, in metres: the last quad's l1..r1 span. The quad
# layout is [l0, l1, r0, r0, l1, r1] (see TireMarks._append_quad).
func _newest_span(tm: TireMarks, wheel: int) -> float:
	var v := tm.ribbon_verts(wheel)
	if v.size() < 6:
		return 0.0
	return (v[v.size() - 5] - v[v.size() - 1]).length()


# Drive the car (wheels co-located with it) `steps` metres along `dir`, with the velocity
# pointing the same way, and tick each step. Ungated so no corridor can reject a heading.
func _drive_along(tm: TireMarks, dir: Vector2, steps := 6) -> void:
	var d := dir.normalized()
	for s in steps:
		var p := d * float(s)
		_car.position = Vector3(p.x, 0.0, p.y)
		_car.linear_velocity = Vector3(d.x, 0.0, d.y) * 10.0
		for w in _wheels:
			w.position = Vector3.ZERO
		tm._physics_process(0.0)


func test_mark_width_survives_every_travel_direction() -> void:
	# THE BUG: the car's heading never changes here, only where it is GOING. With the spread
	# taken from the heading, the direction closest to the old across-axis collapsed the quads.
	var want: float = Config.data.wheel_width_front
	for dir in [Vector2(0, 1), Vector2(1, 0), Vector2(1, 1), Vector2(-1, 0.3), Vector2(0.2, -1)]:
		var tm := _make_ungated(null)
		_drive_along(tm, dir)
		assert_almost_eq(_newest_span(tm, 0), want, 0.001,
			"a mark travelling %s is still a full tyre wide" % dir)


func test_mark_width_follows_the_tyre_width() -> void:
	# ANY reasonable pair of widths: the wider tyre must lay the wider mark, and the mark must
	# be the tyre's own width rather than a constant.
	for width in [0.12, 0.4]:
		Config.data.wheel_width_front = width
		Config.data.wheel_width_rear = width
		var tm := _make_ungated(null)
		_drive_along(tm, Vector2(0, 1))
		assert_almost_eq(_newest_span(tm, 0), width, 0.001,
			"a %.2f m tyre lays a %.2f m mark" % [width, width])


func test_rear_axle_uses_the_rear_tyre_width() -> void:
	# A staggered car: the non-steering wheels are the rear axle and must read wheel_width_rear.
	Config.data.wheel_width_front = 0.18
	Config.data.wheel_width_rear = 0.32
	_wheels[0].use_as_steering = true
	_wheels[1].use_as_steering = false
	var tm := _make_ungated(null)
	_drive_along(tm, Vector2(0, 1))
	assert_almost_eq(_newest_span(tm, 0), Config.data.wheel_width_front, 0.001,
		"the steering wheel marks at the FRONT width")
	assert_almost_eq(_newest_span(tm, 1), Config.data.wheel_width_rear, 0.001,
		"the non-steering wheel marks at the REAR width")
	assert_gt(_newest_span(tm, 1), _newest_span(tm, 0),
		"...so a staggered car leaves wider rear marks")


func test_tire_mark_width_is_only_a_fallback() -> void:
	# With no tyre width available (a spec authoring none) the GameConfig fallback applies.
	Config.data.wheel_width_front = 0.0
	Config.data.wheel_width_rear = 0.0
	var tm := _make_ungated(null)
	_drive_along(tm, Vector2(0, 1))
	assert_almost_eq(_newest_span(tm, 0), Config.data.tire_mark_width_m, 0.001,
		"tire_mark_width_m stands in when the tyre width is unknown")


func test_gated_marks_also_spread_across_travel() -> void:
	# The stage path gets the same fix: a car sliding sideways ACROSS a straight road still lays
	# full-width marks. The road runs along +Z, so this drive is pure lateral travel inside the
	# corridor gate.
	var tm := _make()
	var want: float = Config.data.wheel_width_front
	for s in 6:
		_car.position = Vector3(-1.5 + 0.5 * float(s), 0.0, 10.0)
		_car.linear_velocity = Vector3(10.0, 0.0, 0.0)
		for w in _wheels:
			w.position = Vector3.ZERO
		tm._physics_process(0.0)
	assert_almost_eq(_newest_span(tm, 0), want, 0.001,
		"a sideways slide on a stage road lays a full-width mark")

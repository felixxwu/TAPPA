extends GutTest
# ExhaustFlames: flame geometry shown at each exhaust pipe on a rev-limiter bang and while
# nitrous delivers, its texture swapped between generated frames so a sustained flame
# flickers (features/exhaust-flames.md). Driven against a stub car exposing
# drivetrain.engine with the two signals it reads, so the trigger / hold / frame-cycling
# logic is exercised without a real vehicle or rendering.
#
# Every config value this file depends on is SET by the test, so retuning the shipped
# defaults can't break it: what's asserted is the behaviour that follows from a setting,
# never the setting itself.


# Stub engine: only the two signals ExhaustFlames reads.
class StubEngine:
	extends RefCounted
	var limiter_cut_count := 0
	var nitrous_delivering := false


class StubDrivetrain:
	extends RefCounted
	var engine


# Stub car: a drivetrain + a transform + the per-car pipe list.
class StubCar:
	extends Node3D
	var drivetrain
	var exhaust_locals := PackedVector4Array([Vector4(0.3, 0.0, 1.2, 0.0)])


var _car: StubCar
var _engine: StubEngine
var _flames: ExhaustFlames

const POP_S := 0.1
const TICK := 1.0 / 60.0


func before_each() -> void:
	Config.reset()
	Config.data.exhaust_flames_enabled = true
	Config.data.exhaust_flame_frames = 4
	Config.data.exhaust_flame_frame_seconds = 0.05
	Config.data.exhaust_flame_pop_seconds = POP_S
	Config.data.exhaust_flame_texture_px = 16  # small: these tests never look at pixels
	_engine = StubEngine.new()
	var dt := StubDrivetrain.new()
	dt.engine = _engine
	_car = StubCar.new()
	_car.drivetrain = dt
	add_child_autofree(_car)
	_flames = ExhaustFlames.new()
	add_child_autofree(_flames)
	_flames.setup(_car)


func after_each() -> void:
	Config.reset()


# --- Triggers ----------------------------------------------------------------


func test_a_limiter_cut_lights_the_flame() -> void:
	assert_false(_flames.is_lit(), "nothing burns before the engine bangs")
	_engine.limiter_cut_count += 1
	_flames._timed_physics_process(TICK)
	assert_true(_flames.is_lit(), "a limiter cut should light the pipes")


func test_a_steady_engine_never_lights() -> void:
	for _i in 30:
		_flames._timed_physics_process(TICK)
	assert_false(_flames.is_lit(),
		"a car that never hits the limiter and never uses nitrous should never flame")


func test_the_bang_goes_out_after_its_hold() -> void:
	_engine.limiter_cut_count += 1
	_flames._timed_physics_process(TICK)
	assert_true(_flames.is_lit(), "precondition: the bang lit it")
	_flames._timed_physics_process(POP_S * 2.0)
	assert_false(_flames.is_lit(), "the bang should not stay lit indefinitely")


# The hold is RETRIGGERABLE: bouncing off the limiter re-arms it each bang rather than
# queueing, which is what makes a limiter bounce read as flicker instead of one long flame.
func test_a_further_bang_re_arms_the_hold() -> void:
	_engine.limiter_cut_count += 1
	_flames._timed_physics_process(TICK)
	# Run most of the hold down, then bang again.
	_flames._timed_physics_process(POP_S * 0.9)
	_engine.limiter_cut_count += 1
	_flames._timed_physics_process(TICK)
	# A tick that would have finished the ORIGINAL hold must not put it out.
	_flames._timed_physics_process(POP_S * 0.5)
	assert_true(_flames.is_lit(), "the second bang should have re-armed the hold")


func test_nitrous_delivery_stays_lit_far_beyond_a_bang() -> void:
	_engine.nitrous_delivering = true
	for _i in 30:
		_flames._timed_physics_process(TICK)  # ~0.5s, well past the pop hold
	assert_true(_flames.is_lit(), "a delivering bottle should hold the flame open")
	_engine.nitrous_delivering = false
	_flames._timed_physics_process(TICK)
	assert_false(_flames.is_lit(), "and it should go out the moment delivery stops")


# "Fitted but empty" must not flame: the flame reads the LATCHED delivery state, which the
# sim clears when the tank runs dry, not "a bottle is installed".
func test_nitrous_not_delivering_does_not_light() -> void:
	_engine.nitrous_delivering = false
	for _i in 30:
		_flames._timed_physics_process(TICK)
	assert_false(_flames.is_lit(), "a non-delivering bottle should produce no flame")


func test_disabled_flames_never_light() -> void:
	Config.data.exhaust_flames_enabled = false
	_engine.limiter_cut_count += 1
	_engine.nitrous_delivering = true
	_flames._timed_physics_process(TICK)
	assert_false(_flames.is_lit(), "the master switch should suppress the flame entirely")


# --- Geometry ----------------------------------------------------------------


# One rig per pipe, not one for the car — the whole reason the offsets are a list.
func test_one_rig_is_built_per_pipe() -> void:
	assert_eq(_flames.pipe_count(), 1, "the stub car has one pipe")
	var twin := ExhaustFlames.new()
	add_child_autofree(twin)
	_car.exhaust_locals = PackedVector4Array([Vector4(0.3, 0.0, 1.2, 0.0), Vector4(-0.3, 0.0, 1.2, 0.0)])
	twin.setup(_car)
	assert_eq(twin.pipe_count(), 2, "a twin-exit car gets a rig at each pipe")


# The yaw has to reach the GEOMETRY, not just survive config resolution — the flame is
# aimed by rotating the pipe's rig, and a yaw that stopped at the config would leave every
# side exit still firing straight back.
func test_an_authored_yaw_rotates_the_pipe_rig() -> void:
	var angled := ExhaustFlames.new()
	add_child_autofree(angled)
	_car.exhaust_locals = PackedVector4Array([Vector4(0.9, 0.0, 0.0, 30.0)])
	angled.setup(_car)
	var basis := angled.pipe_transform(0).basis
	# The flame runs along the rig's local +Z; yaw turns that in the horizontal plane.
	var aim := basis * Vector3.BACK
	assert_almost_eq(aim.y, 0.0, 0.001, "a horizontal-plane yaw must not tilt the flame")
	assert_gt(aim.x, 0.0, "a POSITIVE yaw should aim the flame toward the car's right (+X)")
	assert_gt(aim.z, 0.0, "and it should still be heading rearward, not sideways-only")


func test_a_negative_yaw_aims_the_other_way() -> void:
	var angled := ExhaustFlames.new()
	add_child_autofree(angled)
	_car.exhaust_locals = PackedVector4Array([Vector4(-0.9, 0.0, 0.0, -30.0)])
	angled.setup(_car)
	var aim := angled.pipe_transform(0).basis * Vector3.BACK
	assert_lt(aim.x, 0.0, "a negative yaw should aim toward the car's left")


func test_a_pipe_with_no_yaw_points_straight_back() -> void:
	var aim := _flames.pipe_transform(0).basis * Vector3.BACK
	assert_almost_eq(aim.x, 0.0, 0.001, "yaw 0 has no lateral component")
	assert_almost_eq(aim.z, 1.0, 0.001, "yaw 0 points straight down the car's rearward axis")


func test_the_rig_sits_at_the_authored_pipe_position() -> void:
	_car.exhaust_locals = PackedVector4Array([Vector4(0.4, -0.1, 1.7, 15.0)])
	var moved := ExhaustFlames.new()
	add_child_autofree(moved)
	moved.setup(_car)
	assert_almost_eq(moved.pipe_transform(0).origin.distance_to(Vector3(0.4, -0.1, 1.7)),
		0.0, 0.001, "the yaw must not disturb where the pipe sits")


func test_warm_up_shows_then_hides_the_flame() -> void:
	_flames.warm_up(Vector3(1, 2, 3))
	assert_true(_flames.is_lit(),
		"warm-up must actually draw, or the shader never compiles behind the loading overlay")
	_flames.clear_warm_up()
	assert_false(_flames.is_lit(), "and it must not be left burning afterwards")


# --- Frames ------------------------------------------------------------------


func test_the_configured_number_of_frames_is_generated() -> void:
	assert_eq(_flames.frame_count(), Config.data.exhaust_flame_frames)


# A "handful of variations" that are all identical would animate nothing. This is the
# assertion that the per-frame variation is real rather than nominal.
func test_the_generated_frames_actually_differ() -> void:
	var frames := ExhaustFlames.build_frames(Config.data)
	assert_gt(frames.size(), 1, "precondition: more than one frame")
	var first := frames[0].get_image().get_data()
	var any_different := false
	for i in range(1, frames.size()):
		if frames[i].get_image().get_data() != first:
			any_different = true
	assert_true(any_different, "the frames must vary, or the flicker is a still image")


# Generation is seeded per frame index, so the same config always yields the same frames —
# the variation is authored, not a per-run accident that could differ between two cars.
func test_frame_generation_is_deterministic() -> void:
	var a := ExhaustFlames.build_frames(Config.data)
	var b := ExhaustFlames.build_frames(Config.data)
	assert_eq(a[0].get_image().get_data(), b[0].get_image().get_data(),
		"the same config should generate the same frames")


func test_a_frame_is_never_swapped_for_itself() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	for _i in 200:
		for current in 4:
			assert_ne(ExhaustFlames.next_frame(current, 4, rng), current,
				"swapping to the same frame would be a visible stall in the flicker")


func test_next_frame_stays_in_range_and_copes_with_a_single_frame() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for _i in 50:
		var n := ExhaustFlames.next_frame(2, 5, rng)
		assert_between(n, 0, 4, "a frame index must be a real index")
	assert_eq(ExhaustFlames.next_frame(0, 1, rng), 0,
		"with only one frame there is nothing to swap to")


func test_the_flame_cycles_frames_while_it_burns() -> void:
	_engine.nitrous_delivering = true
	_flames._timed_physics_process(TICK)
	var seen := {}
	for _i in 60:
		# Each tick is longer than the frame interval, so every one should swap.
		_flames._timed_physics_process(Config.data.exhaust_flame_frame_seconds * 1.5)
		seen[_flames.current_frame()] = true
	assert_gt(seen.size(), 1, "a sustained flame should not sit on one frame")

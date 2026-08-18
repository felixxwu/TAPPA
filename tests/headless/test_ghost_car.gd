extends GutTest
# GhostCar: the rival ghost's in-world posing (features/rival-ghost.md).
#
# Most of this needs no car and no world — the risky part is the ARITHMETIC that maps a
# pace profile onto the arc-length space TrackProgress measures in, which is where four
# of five spec-review rounds found a defect. Those cases run against a bare TrackProgress
# with a stub car. A small scene-backed section at the end covers the display car itself.

const RivalPace = preload("res://scripts/rival_pace.gd")
const CAR_SCENE := "res://car.tscn"

const CAR := {
	"mass": 1200.0, "peak_torque": 300.0, "redline": 7000.0,
	"tire_compound": 1.1, "drag": 0.2,
}


class StubCar:
	extends Node3D
	var linear_velocity := Vector3.ZERO
	var throttling := false
	func reset_to(_xform: Transform3D) -> void: pass
	func is_throttling() -> bool: return throttling


# Stands in for the display car in the external-offset tests below: pose_at_offset only
# needs `drivetrain` (read by _drive_wheels) and tolerates the rest being absent via
# has_method guards, so this is cheaper than building a real car.tscn instance.
class StubDisplayCar:
	extends Node3D
	var drivetrain: Variant = null


var _stub: StubCar


func before_each() -> void:
	Config.reset()
	_stub = StubCar.new()
	add_child_autofree(_stub)


func after_each() -> void:
	Config.reset()


# A straight road with a generous run-up, so an "origin" partway along it stands in for
# the player's grid slot sitting behind the start line.
func _progress_on_straight(length := 300.0) -> TrackProgress:
	var curve := Curve2D.new()
	curve.add_point(Vector2(0, 0))
	curve.add_point(Vector2(0, length))
	var tp := TrackProgress.new()
	add_child_autofree(tp)
	tp.setup(curve, _stub, null)
	return tp


func _pace_over(track: Dictionary, factor := 1.3) -> RivalPace:
	var target := int(round(float(LapTimeModel.optimum_ms(track, CAR, {})) * factor))
	return RivalPace.solve(track, CAR, {}, target)


func _ghost_with(pace: RivalPace, tp: TrackProgress) -> GhostCar:
	var g := GhostCar.new()
	add_child_autofree(g)
	# No car scene: the geometry helpers under test don't need a car, and building one
	# costs a car.tscn instance per test.
	g.setup(pace, tp, null, {}, null, {})
	g.pace = pace
	return g


# --- Coordinate mapping: the part that kept being wrong ----------------------------

func test_offset_is_measured_from_the_live_timing_origin() -> void:
	# NOT from the start line and NOT from a config-reconstructed lead-in: the player is
	# staged behind the line, so mark_start() anchors wherever they actually sit, and the
	# ghost has to share that anchor.
	var tp := _progress_on_straight()
	_stub.global_position = Vector3(0, 0, 40)
	tp.mark_start()
	var pace := _pace_over(TrackFixtures.straight_then_arc(80.0, 45.0, PI))
	var ghost := _ghost_with(pace, tp)
	assert_almost_eq(ghost.rendered_offset_at(0.0), tp.origin_offset(), 0.5,
			"at t=0 the ghost sits on the timing origin, not on arc-length zero")

func test_the_ghost_parks_at_the_finish_and_never_runs_on() -> void:
	# It must not sail into the post-finish runoff, and must not loop the way the
	# post-event replay ghost does.
	var tp := _progress_on_straight()
	tp.mark_start()
	var pace := _pace_over(TrackFixtures.straight_then_arc(80.0, 45.0, PI))
	var ghost := _ghost_with(pace, tp)
	var at_target := ghost.rendered_offset_at(float(pace.total_ms()) / 1000.0)
	var long_after := ghost.rendered_offset_at(float(pace.total_ms()) / 1000.0 + 120.0)
	assert_almost_eq(long_after, at_target, 0.01,
			"the offset is frozen once the target time has passed")
	assert_true(long_after <= tp.finish_offset() + 0.01,
			"and never passes the finish offset")

func test_the_rendered_offset_advances_monotonically() -> void:
	var tp := _progress_on_straight()
	tp.mark_start()
	var pace := _pace_over(TrackFixtures.straight_then_arc(80.0, 45.0, PI))
	var ghost := _ghost_with(pace, tp)
	var prev := -1.0
	for i in 40:
		var t := float(pace.total_ms()) / 1000.0 * float(i) / 39.0
		var off := ghost.rendered_offset_at(t)
		assert_true(off >= prev - 0.001, "offset never goes backwards at sample %d" % i)
		prev = off


# --- Cosmetics: direction and bounds, never the tuned values -----------------------

func test_a_looser_surface_has_a_higher_optimum_slip_angle() -> void:
	# The slip angle now comes from the TYRE MODEL: *_slip_peak is a normalised slip (the
	# sine of the slip angle), so the peak angle is asin(slip_peak). Gravel peaking later
	# than tarmac is therefore a property of the rubber/surface, not a second set of
	# authored angles. The test sets both peaks itself rather than leaning on the shipped
	# ordering, which is a tunable.
	Config.data.gravel_slip_peak = 0.35
	Config.data.tarmac_slip_peak = 0.20
	var gravel := GhostCar._optimum_slip_rad(Config.data, {"surface_mix": 0.0})
	var tarmac := GhostCar._optimum_slip_rad(Config.data, {"surface_mix": 1.0})
	assert_gt(gravel, tarmac, "the looser surface peaks at a larger slip angle")
	assert_almost_eq(gravel, asin(0.35), 0.001, "gravel angle is asin(gravel_slip_peak)")
	assert_almost_eq(tarmac, asin(0.20), 0.001, "tarmac angle is asin(tarmac_slip_peak)")

func test_the_optimum_slip_follows_the_surface_mix() -> void:
	Config.data.gravel_slip_peak = 0.40
	Config.data.tarmac_slip_peak = 0.0
	var half := GhostCar._optimum_slip_rad(Config.data, {"surface_mix": 0.5})
	assert_almost_eq(half, asin(0.20), 0.001,
			"a half-and-half surface blends the two peaks before taking the angle")

# --- External-offset posing: no RivalPace (features/multiplayer-lobby.md) ---------

func test_pose_at_offset_places_the_car_without_a_pace() -> void:
	var tp := _progress_on_straight()
	tp.mark_start()
	var g := GhostCar.new()
	add_child_autofree(g)
	g.setup(null, tp, null, {}, null, {})
	g.car = StubDisplayCar.new()
	add_child_autofree(g.car)
	var offset := tp.origin_offset() + 50.0
	g.pose_at_offset(offset, 20.0, 0.0, 0.0)
	var expected: Vector2 = tp.sample_at(offset)
	assert_almost_eq(g.car.global_position.x, expected.x, 1.5,
			"external-offset posing lands the car at the sampled track x for that offset")
	assert_almost_eq(g.car.global_position.z, expected.y, 1.5,
			"external-offset posing lands the car at the sampled track z for that offset")

func test_pose_at_offset_moves_forward_as_the_offset_increases() -> void:
	var tp := _progress_on_straight()
	tp.mark_start()
	var g := GhostCar.new()
	add_child_autofree(g)
	g.setup(null, tp, null, {}, null, {})
	g.car = StubDisplayCar.new()
	add_child_autofree(g.car)
	var origin := tp.origin_offset()
	g.pose_at_offset(origin + 20.0, 20.0, 0.0, 0.0)
	var first_z: float = g.car.global_position.z
	g.pose_at_offset(origin + 60.0, 20.0, 0.0, 0.05)
	var second_z: float = g.car.global_position.z
	assert_gt(second_z, first_z,
			"a later, larger offset moves the ghost further down the straight")

func test_process_drives_the_external_offset_path_with_no_pace() -> void:
	var tp := _progress_on_straight()
	tp.mark_start()
	var g := GhostCar.new()
	add_child_autofree(g)
	g.setup(null, tp, null, {}, null, {})
	g.car = StubDisplayCar.new()
	add_child_autofree(g.car)
	g.running = true
	var origin := tp.origin_offset()
	g.offset_source = func() -> Dictionary:
		return {"offset_m": origin + 30.0, "speed_mps": 15.0}
	g._process(0.05)
	assert_true(g._has_pose, "the external-offset path poses the car with pace == null")
	var expected: Vector2 = tp.sample_at(origin + 30.0)
	assert_almost_eq(g.car.global_position.x, expected.x, 1.5,
			"the _process-driven external path lands at the sampled offset")

func test_process_clamps_the_external_offset_to_the_stage_bounds() -> void:
	var tp := _progress_on_straight()
	tp.mark_start()
	var g := GhostCar.new()
	add_child_autofree(g)
	g.setup(null, tp, null, {}, null, {})
	g.car = StubDisplayCar.new()
	add_child_autofree(g.car)
	g.running = true
	g.offset_source = func() -> Dictionary:
		return {"offset_m": tp.finish_offset() + 500.0, "speed_mps": 15.0}
	g._process(0.05)
	var expected: Vector2 = tp.sample_at(tp.finish_offset())
	assert_almost_eq(g.car.global_position.x, expected.x, 1.5,
			"an out-of-range external offset is clamped to the finish before posing")


func test_the_optimum_slip_angle_ignores_weather() -> void:
	# Deliberate: rain lowers mu, and the pace profile already answers that by cornering
	# slower. The angle at which a tyre PEAKS is a property of the rubber and surface, not
	# of how much grip is on offer. An earlier version divided by the weather multiplier to
	# make wet "slide more", which was invented rather than derived.
	Config.data.gravel_slip_peak = 0.35
	var dry := GhostCar._optimum_slip_rad(Config.data,
			{"surface_mix": 0.0, "weather": RallyLibrary.WEATHER_DRY})
	var wet := GhostCar._optimum_slip_rad(Config.data,
			{"surface_mix": 0.0, "weather": RallyLibrary.WEATHER_RAIN})
	assert_almost_eq(wet, dry, 0.0001, "the peak-slip ANGLE is unchanged by weather")

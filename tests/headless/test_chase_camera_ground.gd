extends GutTest
# Chase camera ground seating (chase_camera.gd -> _ground_height_at). The camera
# never seats below the lake surface, and — the regression this file exists for —
# it reads that waterline LIVE rather than caching it in _ready().
#
# Why live matters: ChaseCamera is a child of main.tscn's root, so its _ready runs
# BEFORE world.gd._ready, which is where the event's/stage's track params reach the
# live config (DrivingContext.apply_stage_config). A cached copy would be the
# PREVIOUS run's waterline, and the camera would float above the car over any basin
# whose real water sits lower.

var _cam: Camera3D
var _target: Node3D
var _saved_water := 0.0


func before_each() -> void:
	_saved_water = Config.data.track_water_level_m
	_target = Node3D.new()
	add_child(_target)
	_cam = load("res://scripts/chase_camera.gd").new()
	_cam.target = _target
	add_child(_cam)  # _ready() caches config into the _* fields
	_cam.set_physics_process(false)


func after_each() -> void:
	Config.data.track_water_level_m = _saved_water
	_cam.free()
	_target.free()


# No terrain sibling here, so _ground_height_at's terrain term is 0 and the result
# is purely the waterline clamp — which is exactly what's under test.
func test_ground_never_seats_below_the_water_surface() -> void:
	Config.data.track_water_level_m = 6.0
	assert_almost_eq(_cam._ground_height_at(0.0, 0.0), 6.0, 0.001,
		"water above the ground raises the seat to the water surface")


func test_water_below_the_ground_does_not_lower_the_seat() -> void:
	Config.data.track_water_level_m = -10.0
	assert_almost_eq(_cam._ground_height_at(0.0, 0.0), 0.0, 0.001,
		"a waterline below the ground leaves the ground as the seat")


func test_waterline_written_after_ready_is_honoured() -> void:
	# The bug: the config is seated by world.gd._ready, which runs AFTER this
	# camera's _ready. Writing the waterline post-add must still be picked up.
	Config.data.track_water_level_m = 8.0
	var high: float = _cam._ground_height_at(0.0, 0.0)
	Config.data.track_water_level_m = 3.0
	var low: float = _cam._ground_height_at(0.0, 0.0)
	assert_almost_eq(high, 8.0, 0.001, "picks up a waterline set after _ready")
	assert_almost_eq(low, 3.0, 0.001, "and keeps tracking it when it changes again")

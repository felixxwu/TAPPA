extends GutTest
# Smoke coverage for the phase-1 menu showcase prototype
# (todo/menu-background-showcase.md). Mirrors test_smoke.gd's main.tscn pattern:
# instantiate, let _ready's awaited build run, then assert on the result.

var _scene: MenuShowcase


func after_each() -> void:
	if is_instance_valid(_scene):
		_scene.free()
	_scene = null


func test_builds_a_track_and_starts_the_camera() -> void:
	_scene = load("res://menu_showcase.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let _build() (TrackGenerator.generate, set_track) run

	assert_true(_scene.is_built(), "the showcase finished building")
	var cam := _scene.camera()
	assert_not_null(cam, "a MenuShowcaseCamera was created")
	assert_true(cam.current, "the showcase camera is the active camera")
	assert_gt(cam.shot_count(), 0, "at least one shot was authored from the generated track")

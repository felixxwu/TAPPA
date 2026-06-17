extends GutTest
# Camera cycling: C advances chase -> bonnet -> chase, exactly one camera active.

var _scene: Node3D
var _mgr: Node


func before_each() -> void:
	Config.reset()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_mgr = _scene.get_node("CameraManager")


func _current_count() -> int:
	var n := 0
	if (_scene.get_node("ChaseCamera") as Camera3D).current:
		n += 1
	if (_scene.get_node("Car/BonnetCamera") as Camera3D).current:
		n += 1
	return n


func test_starts_on_chase_camera() -> void:
	assert_eq(_mgr.active_index(), 0, "starts on chase (index 0)")
	assert_true((_scene.get_node("ChaseCamera") as Camera3D).current, "chase is current at start")
	assert_eq(_current_count(), 1, "exactly one camera current")


func test_cycle_switches_to_bonnet_then_back() -> void:
	_mgr.cycle()
	assert_eq(_mgr.active_index(), 1, "after one cycle, on bonnet (index 1)")
	assert_true((_scene.get_node("Car/BonnetCamera") as Camera3D).current, "bonnet current after cycle")
	assert_eq(_current_count(), 1, "still exactly one camera current")
	_mgr.cycle()
	assert_eq(_mgr.active_index(), 0, "second cycle wraps back to chase")
	assert_true((_scene.get_node("ChaseCamera") as Camera3D).current, "chase current after wrap")
	assert_eq(_current_count(), 1, "still exactly one camera current")


func test_bonnet_uses_configured_offset_and_fov() -> void:
	var cfg: GameConfig = Config.data
	var bonnet := _scene.get_node("Car/BonnetCamera") as Camera3D
	assert_almost_eq(bonnet.transform.origin, cfg.bonnet_offset, Vector3(0.001, 0.001, 0.001), "bonnet at configured offset")
	assert_almost_eq(bonnet.fov, cfg.bonnet_fov, 0.001, "bonnet at configured fov")


func test_cycle_car_retargets_both_cameras() -> void:
	var old_car := _scene.get_node("Car")
	_scene.cycle_car()
	var fresh := _scene.get_node("Car")
	assert_ne(fresh, old_car, "cycle_car spawns a fresh car node")
	var chase := _scene.get_node("ChaseCamera") as Camera3D
	assert_eq(chase.target, fresh, "chase camera re-targeted to fresh car")
	var bonnet := _mgr.bonnet_camera as Camera3D
	assert_eq(bonnet.get_parent(), fresh, "bonnet camera re-parented onto fresh car")

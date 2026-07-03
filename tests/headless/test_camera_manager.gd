extends GutTest
# Camera cycling: C advances chase -> bonnet -> chase, exactly one camera active.

const TEST_PATH := "user://test_camera_profile.json"

var _scene: Node3D
var _mgr: Node
var _save: Node


# minimal_world() trims main.tscn's expensive terrain/track/foliage generation
# (see scene_helpers.gd), and we build the scene ONCE for the whole script. The
# two mutating tests are order-safe: the
# camera-cycle test wraps back to chase (net-neutral), and the destructive
# cycle_car test (which swaps the Car node) is defined last. GUT runs tests in
# definition order, so a single shared instance is safe.
#
# The manager now persists the chosen mode to the save profile, so redirect Save to
# a throwaway file (a fresh profile has no camera_mode → defaults to chase) — both so
# the "starts on chase" assertion is deterministic and so the test doesn't touch the
# real profile.
func before_all() -> void:
	# Cameras/CameraManager/cycle_car need the wired world, but not its track shape
	# or foliage — minimal_world() trims generation to a 1-turn, tree-free build.
	SceneTestHelpers.minimal_world()
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	await get_tree().physics_frame  # let world._ready() generate + apply + build
	_mgr = _scene.get_node("CameraManager")


func after_all() -> void:
	_scene.free()
	Config.reset()  # minimal_world() zeroed foliage/track — restore the baseline for later files
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


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


func test_set_mode_selects_and_persists() -> void:
	# The settings page jumps straight to a mode and persists it to the save profile.
	_mgr.set_mode(CameraManager.Mode.BONNET)
	assert_eq(_mgr.active_index(), 1, "set_mode(BONNET) switches to the bonnet camera")
	assert_true((_scene.get_node("Car/BonnetCamera") as Camera3D).current, "bonnet current after set_mode")
	assert_eq(int(_save.get_setting(CameraManager.SETTING_KEY, -1)),
		CameraManager.Mode.BONNET, "the chosen camera mode is saved")
	# Restore chase so later tests start from the default (net-neutral).
	_mgr.set_mode(CameraManager.Mode.CHASE)
	assert_eq(_mgr.active_index(), 0, "set_mode(CHASE) restores chase")


func test_bonnet_uses_configured_offset_and_fov() -> void:
	var cfg: GameConfig = Config.data
	var bonnet := _scene.get_node("Car/BonnetCamera") as Camera3D
	assert_almost_eq(bonnet.transform.origin, cfg.bonnet_offset, Vector3(0.001, 0.001, 0.001), "bonnet at configured offset")
	assert_almost_eq(bonnet.fov, cfg.bonnet_fov, 0.001, "bonnet at configured fov")


func test_bonnet_offset_composes_base_plus_per_car() -> void:
	# retarget() must place the bonnet camera at the shared GameConfig.bonnet_offset
	# PLUS the active car's per-car bonnet_cam_offset (whatever those values are).
	var cfg: GameConfig = Config.data
	var car := _scene.get_node("Car")
	var bonnet := _mgr.bonnet_camera as Camera3D
	var per_car := Vector3.ZERO
	if car.has_method("bonnet_cam_offset"):
		per_car = car.bonnet_cam_offset()
	_mgr.retarget(car)
	assert_almost_eq(bonnet.transform.origin, cfg.bonnet_offset + per_car,
		Vector3(0.001, 0.001, 0.001), "bonnet origin = base offset + per-car offset")


func test_cycle_car_retargets_both_cameras() -> void:
	var old_car := _scene.get_node("Car")
	_scene.cycle_car()
	var fresh := _scene.get_node("Car")
	assert_ne(fresh, old_car, "cycle_car spawns a fresh car node")
	var chase := _scene.get_node("ChaseCamera") as Camera3D
	assert_eq(chase.target, fresh, "chase camera re-targeted to fresh car")
	var bonnet := _mgr.bonnet_camera as Camera3D
	assert_eq(bonnet.get_parent(), fresh, "bonnet camera re-parented onto fresh car")

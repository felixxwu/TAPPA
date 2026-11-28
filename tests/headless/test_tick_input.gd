extends GutTest
# TickInput records the driver's actions per physics tick and replays them by pressing the same
# actions through Input, which is how the level replay's --free mode drives the car.


# Applies one row per physics tick, after every other node, as the free replay does: a press made
# during a tick reads as just-pressed on the next one.
class _Presser extends Node:
	var rows: Array[PackedFloat32Array] = []
	var next := 0
	func _init() -> void:
		process_physics_priority = 1 << 20
	func _physics_process(_delta: float) -> void:
		if next < rows.size():
			TickInput.apply(rows[next])
			next += 1


class _Watcher extends Node:
	var just: Array[bool] = []
	var held: Array[bool] = []
	func _physics_process(_delta: float) -> void:
		just.append(Input.is_action_just_pressed("shift_up"))
		held.append(Input.is_action_pressed("shift_up"))


func after_each() -> void:
	TickInput.release_all()


func _wait_physics(n: int) -> void:
	for _i in n:
		await get_tree().physics_frame


func test_pack_unpack_round_trips() -> void:
	var strengths := {&"accelerate": 0.75, &"steer_left": 0.25, &"shift_up": 1.0}
	var out := TickInput.unpack(TickInput.pack(strengths, [&"shift_up", &"nitrous"]))
	for a in TickInput.ACTIONS:
		assert_almost_eq(float(out["strengths"][a]), float(strengths.get(a, 0.0)), 1e-6, String(a))
	assert_eq(out["just_pressed"], [&"shift_up", &"nitrous"] as Array[StringName])


func test_apply_then_sample_gives_the_same_row() -> void:
	var row := TickInput.pack({&"accelerate": 1.0, &"steer_right": 0.5, &"handbrake": 1.0}, [&"accelerate", &"steer_right", &"handbrake"])
	TickInput.apply(row)
	assert_eq(TickInput.sample(), row)


func test_held_action_releases_when_the_row_drops_it() -> void:
	TickInput.apply(TickInput.pack({&"accelerate": 1.0}, [&"accelerate"]))
	TickInput.apply(TickInput.pack({}, []))
	assert_false(Input.is_action_pressed("accelerate"))


func test_press_at_the_end_of_a_tick_is_just_pressed_on_the_next_tick_only() -> void:
	var watcher := _Watcher.new()
	var presser := _Presser.new()
	presser.rows = [TickInput.pack({&"shift_up": 1.0}, [&"shift_up"])]
	add_child_autofree(watcher)
	add_child_autofree(presser)
	await _wait_physics(4)
	assert_eq(watcher.just.slice(0, 3), [false, true, false] as Array[bool], "the car sees the press on the next tick, once")
	assert_eq(watcher.held.slice(0, 3), [false, true, true] as Array[bool], "held from the next tick on")


func test_recorded_throttle_drives_the_car_without_pose_writes() -> void:
	Config.reset()
	var world := await SceneTestHelpers.add_level_world(self)
	var car: VehicleBody3D = world.get_node("Car")
	car.controls_locked = false
	var start := car.global_position
	var forward := -car.global_transform.basis.z
	var presser := _Presser.new()
	for i in 60:
		presser.rows.append(TickInput.pack({&"accelerate": 1.0}, [&"accelerate"] if i == 0 else []))
	add_child_autofree(presser)
	await _wait_physics(62)
	TickInput.release_all()
	assert_gt((car.global_position - start).dot(forward), 0.5, "the replayed throttle moved the car forward")
	world.free()
	SceneTestHelpers.remove_level_world()
	Config.reset()

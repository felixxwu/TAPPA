extends GutTest


func test_wheel_force_arrows_drawn_when_grounded() -> void:
	# Flat fixture (car + ground) — this only inspects the car's debug overlay, so
	# it doesn't need main.tscn's terrain/track/foliage generation.
	var scene: Node3D = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(scene)
	var car: VehicleBody3D = scene.get_node("Car")
	for i in 60:  # let the car settle onto its wheels
		await get_tree().physics_frame
	var overlay: WheelForceDebug = null
	for child in car.get_children():
		if child is WheelForceDebug:
			overlay = child
	assert_not_null(overlay, "debug overlay node present")
	if overlay == null:
		return
	# Hidden by default; nothing drawn until the user presses H.
	assert_false(overlay.visible, "arrows hidden on startup")
	assert_eq(overlay.mesh.get_surface_count(), 0, "no arrows drawn while hidden")
	Input.action_press("toggle_debug_arrows")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("toggle_debug_arrows")
	assert_true(overlay.visible, "H shows the arrows")
	# At rest on the floor every wheel has contact, so suspension and friction
	# arrows must have been emitted (one ImmediateMesh surface with vertices).
	assert_gt(overlay.mesh.get_surface_count(), 0, "arrows drawn while wheels touch ground")


func test_collision_box_shown_and_transparent_with_arrows() -> void:
	# Flat fixture (car + ground) — only inspects the car's overlay/collision box.
	var scene: Node3D = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(scene)
	var car: VehicleBody3D = scene.get_node("Car")
	for i in 30:
		await get_tree().physics_frame
	var overlay: WheelForceDebug = null
	for child in car.get_children():
		if child is WheelForceDebug:
			overlay = child
	assert_not_null(overlay, "debug overlay present")
	if overlay == null:
		return
	var box := overlay._collision_box
	assert_not_null(box, "collision box overlay built")
	if box == null:
		return
	# Lives under the collision shape so it inherits its exact transform.
	assert_true(box.get_parent() is CollisionShape3D, "box parented to CollisionShape3D")
	# Transparent so the car shows through.
	var mat := box.material_override as StandardMaterial3D
	assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_ALPHA, "box uses alpha transparency")
	assert_lt(mat.albedo_color.a, 1.0, "box is see-through")
	# Hidden with the arrows, shown with them.
	assert_false(box.visible, "box hidden on startup")
	Input.action_press("toggle_debug_arrows")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("toggle_debug_arrows")
	assert_true(box.visible, "H shows the collision box")
	# Sized to match the chassis collision shape.
	var shape := (car.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	assert_eq((box.mesh as BoxMesh).size, shape.size, "box matches collision shape size")


func _surface_vertex_count(overlay: WheelForceDebug) -> int:
	if overlay.mesh.get_surface_count() == 0:
		return 0
	return overlay.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()


func test_downforce_arrows_drawn_at_speed() -> void:
	# Uses the flat test_track fixture for reliable velocity injection.
	var scene: Node3D = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(scene)
	var car: VehicleBody3D = scene.get_node("Car")
	for i in 60:
		await get_tree().physics_frame
	var overlay: WheelForceDebug = null
	for child in car.get_children():
		if child is WheelForceDebug:
			overlay = child
	assert_not_null(overlay, "debug overlay present")
	if overlay == null:
		return

	# Enable the overlay
	Input.action_press("toggle_debug_arrows")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("toggle_debug_arrows")
	assert_true(overlay.visible, "overlay should be visible")

	# Baseline: zero downforce, moving at speed — count committed mesh vertices
	var cfg: GameConfig = Config.data
	var saved_front := cfg.downforce_front
	var saved_rear := cfg.downforce_rear
	cfg.downforce_front = 0.0
	cfg.downforce_rear = 0.0
	car.linear_velocity = -car.global_transform.basis.z * 30.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	var baseline_verts: int = _surface_vertex_count(overlay)

	# Enable downforce — two arrows of 6 vertices each should appear
	cfg.downforce_front = 1.0
	cfg.downforce_rear = 1.0
	car.linear_velocity = -car.global_transform.basis.z * 30.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	var new_verts: int = _surface_vertex_count(overlay)

	# Restore
	cfg.downforce_front = saved_front
	cfg.downforce_rear = saved_rear
	Input.action_press("toggle_debug_arrows")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("toggle_debug_arrows")

	assert_gte(new_verts, baseline_verts + 12,
		"two downforce arrows (6 verts each) must appear when downforce > 0 at speed")


func test_assist_arrow_reflects_combined_yaw_assist() -> void:
	# The single yellow assist arrow is driven by car.steer_assist_readout (steer
	# assist + spin protection, summed as a signed yaw scalar). Verify the logic
	# that must hold for ANY tuning: steering at speed produces an assist torque
	# whose sign matches the steer direction, and the overlay draws an extra
	# arrow when that torque is non-zero (vs none when the aid is switched off).
	var scene: Node3D = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(scene)
	var car: VehicleBody3D = scene.get_node("Car")
	for i in 60:
		await get_tree().physics_frame
	var overlay: WheelForceDebug = null
	for child in car.get_children():
		if child is WheelForceDebug:
			overlay = child
	assert_not_null(overlay, "debug overlay present")
	if overlay == null:
		return
	Input.action_press("toggle_debug_arrows")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("toggle_debug_arrows")

	var cfg: GameConfig = Config.data
	var saved_steer := cfg.steer_assist_torque
	var saved_spin := cfg.spin_assist_torque
	# Isolate the steer-assist term with a known positive torque; drive forward
	# above the assist speed threshold and steer left.
	cfg.steer_assist_torque = 20000.0
	cfg.spin_assist_torque = 0.0
	Input.action_press("steer_left")
	for i in 30:
		car.linear_velocity = -car.global_transform.basis.z * 30.0
		await get_tree().physics_frame
	var assist_on_verts := _surface_vertex_count(overlay)
	assert_gt(car.steer_assist_readout, 0.0, "steering left yields a positive (nose-left) assist torque")

	# Switch the aid off: readout collapses to zero and the assist arrow drops out.
	cfg.steer_assist_torque = 0.0
	for i in 30:
		car.linear_velocity = -car.global_transform.basis.z * 30.0
		await get_tree().physics_frame
	var assist_off_verts := _surface_vertex_count(overlay)
	assert_almost_eq(car.steer_assist_readout, 0.0, 0.001, "no assist torque when the aid is disabled")

	Input.action_release("steer_left")
	cfg.steer_assist_torque = saved_steer
	cfg.spin_assist_torque = saved_spin
	Input.action_press("toggle_debug_arrows")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("toggle_debug_arrows")

	assert_gte(assist_on_verts, assist_off_verts + 6,
		"the assist arrow (6 verts) appears only when a yaw-assist torque is applied")


func test_h_key_toggles_arrows() -> void:
	# Flat fixture (car + ground) — only inspects the car's overlay.
	var scene: Node3D = load("res://tests/fixtures/test_track.tscn").instantiate()
	add_child_autofree(scene)
	var car: VehicleBody3D = scene.get_node("Car")
	for i in 30:
		await get_tree().physics_frame
	var overlay: WheelForceDebug = null
	for child in car.get_children():
		if child is WheelForceDebug:
			overlay = child
	assert_not_null(overlay, "debug overlay present")
	if overlay == null:
		return
	var was_visible := overlay.visible
	Input.action_press("toggle_debug_arrows")
	await get_tree().physics_frame
	await get_tree().physics_frame
	Input.action_release("toggle_debug_arrows")
	assert_eq(overlay.visible, not was_visible, "H toggles the arrow overlay")
	if not overlay.visible:
		assert_eq(overlay.mesh.get_surface_count(), 0, "no arrows drawn while hidden")

extends GutTest
# SignField rendering contract (scripts/sign_field.gd): resting signs are drawn
# by shared MultiMeshes (one per face material, two panel instances per sign),
# not per-sign MeshInstance3Ds; a knocked sign swaps to real panel meshes on its
# body so it can tumble. Built against a synthetic layout + a bare flat terrain —
# no catalogue or generated-track dependency.


# A dynamic body standing in for the car (only what _wake_sign/_launch_sign read).
class FakeCar:
	extends RigidBody3D


func _params() -> Dictionary:
	# The real config contract — values themselves don't matter to these tests.
	return GameConfig.new().sign_render_params()


func _layout(n: int, texture_keys: Array) -> Array:
	var out := []
	for i in n:
		out.append({
			"pos": Vector2(i * 10.0, 0.0),
			"tangent": Vector2(1, 0),
			"side": 1 if i % 2 == 0 else -1,
			"kind": "turn",
			"texture_key": texture_keys[i % texture_keys.size()],
		})
	return out


func _field(n := 4, texture_keys := ["left_1", "right_1"]) -> SignField:
	var terrain := TerrainManager.new()
	terrain.focus_path = NodePath("")
	add_child_autofree(terrain)
	var field := SignField.new()
	add_child_autofree(field)
	field.build(_layout(n, texture_keys), terrain, _params())
	return field


func _multimeshes(field: SignField) -> Array:
	return field.get_children().filter(func(c): return c is MultiMeshInstance3D)


func _body_panels(field: SignField, index: int) -> Array:
	return field.get_node("Sign%d" % index).get_children().filter(
		func(c): return c is MeshInstance3D)


func test_resting_signs_render_via_multimesh_not_nodes() -> void:
	var field := _field(4, ["left_1", "right_1"])
	assert_eq(field.sign_count, 4, "one sign per layout entry")
	var mms := _multimeshes(field)
	assert_eq(mms.size(), 2, "one MultiMesh per distinct face material")
	var instances := 0
	for mmi in mms:
		instances += (mmi as MultiMeshInstance3D).multimesh.instance_count
		assert_not_null(mmi.material_override, "batched panels carry the face material")
	assert_eq(instances, 8, "two panel instances per sign")
	for i in field.sign_count:
		assert_eq(_body_panels(field, i).size(), 0,
			"a resting sign body carries no per-node panel meshes")


func test_knocked_sign_swaps_to_real_panels() -> void:
	var field := _field(2, ["left_1"])
	var body := field.get_node("Sign0") as RigidBody3D
	var car := FakeCar.new()
	add_child_autofree(car)

	field._wake_sign(car, body)

	assert_false(body.freeze, "knocked sign goes dynamic")
	assert_eq(_body_panels(field, 0).size(), 2, "knocked sign gains its two panel meshes")
	assert_eq(_body_panels(field, 1).size(), 0, "the other sign stays batched")
	# The knocked sign's batch entry is consumed (its MultiMesh slots were
	# zero-scaled — not observable headless, where the dummy RenderingServer
	# drops instance transforms); the survivor stays batched.
	assert_false(field._rendered.has(body), "knocked sign left the MultiMesh batch")
	assert_true(field._rendered.has(field.get_node("Sign1")), "the other sign stays in the batch")


func test_wake_is_one_shot_per_sign() -> void:
	var field := _field(1, ["left_1"])
	var body := field.get_node("Sign0") as RigidBody3D
	var car := FakeCar.new()
	add_child_autofree(car)
	field._wake_sign(car, body)
	field._wake_sign(car, body)  # second hit: already dynamic, must not double-panel
	assert_eq(_body_panels(field, 0).size(), 2, "panels are attached exactly once")


func test_reset_knocked_stands_a_knocked_sign_back_up() -> void:
	var field := _field(2, ["left_1"])
	var body := field.get_node("Sign0") as RigidBody3D
	var rest := body.transform
	var car := FakeCar.new()
	add_child_autofree(car)
	field._wake_sign(car, body)
	assert_false(body.freeze, "sanity: the sign was knocked dynamic")

	field.reset_knocked()
	await get_tree().process_frame  # queue_free of the panel meshes settles next frame

	assert_true(body.freeze, "reset re-freezes the knocked sign")
	assert_true(body.transform.is_equal_approx(rest),
		"reset restores the sign's resting pose")
	assert_eq(_body_panels(field, 0).size(), 0,
		"reset drops the per-node panel meshes (back to MultiMesh rendering)")
	assert_true(field._rendered.has(body), "reset returns the sign to the MultiMesh batch")


func test_reset_leaves_standing_signs_untouched() -> void:
	var field := _field(2, ["left_1"])
	var knocked := field.get_node("Sign0") as RigidBody3D
	var standing := field.get_node("Sign1") as RigidBody3D
	var car := FakeCar.new()
	add_child_autofree(car)
	field._wake_sign(car, knocked)

	field.reset_knocked()

	# The un-knocked sign never left the batch, so reset is a no-op for it — it must not
	# gain phantom panel meshes or be re-processed.
	assert_true(field._rendered.has(standing), "the standing sign stays batched throughout")
	assert_eq(_body_panels(field, 1).size(), 0, "the standing sign gains no panel meshes")


func test_a_reset_sign_can_be_knocked_again() -> void:
	var field := _field(1, ["left_1"])
	var body := field.get_node("Sign0") as RigidBody3D
	var car := FakeCar.new()
	add_child_autofree(car)
	field._wake_sign(car, body)
	field.reset_knocked()
	await get_tree().process_frame

	field._wake_sign(car, body)  # a fresh run knocks it over once more
	assert_false(body.freeze, "a reset sign wakes again on the next hit")
	assert_eq(_body_panels(field, 0).size(), 2, "and re-materialises exactly its two panels")

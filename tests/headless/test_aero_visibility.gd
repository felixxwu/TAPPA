extends GutTest
# Aero-part visibility: spoilers/splitters (meshes tagged `_aero` inside a car
# body) are hidden by default and revealed only when the aero kit is fitted+
# enabled. Tests the LOGIC (traversal + reveal-follows-enabled-state), never an
# authored value; the aero gate itself is covered in test_upgrade_library.gd.

const Car = preload("res://scripts/car.gd")


# Build a bare body node with two aero meshes (one nested) + one non-aero mesh.
func _make_body() -> Node3D:
	var body := Node3D.new()
	var wing := MeshInstance3D.new()
	wing.name = "wing_aero"
	body.add_child(wing)
	var door := MeshInstance3D.new()
	door.name = "door_panel"
	body.add_child(door)
	var group := Node3D.new()
	group.name = "front"
	body.add_child(group)
	var splitter := MeshInstance3D.new()
	splitter.name = "splitter_aero"
	group.add_child(splitter)
	return body


func test_set_aero_visible_hides_only_aero_meshes() -> void:
	var body := _make_body()
	add_child_autofree(body)
	Car._set_aero_visible(body, false)
	assert_false(body.get_node("wing_aero").visible, "top-level aero mesh hidden")
	assert_false(body.get_node("front/splitter_aero").visible, "nested aero mesh hidden")
	assert_true(body.get_node("door_panel").visible, "non-aero mesh untouched")


func test_set_aero_visible_reveals_aero_meshes() -> void:
	var body := _make_body()
	add_child_autofree(body)
	Car._set_aero_visible(body, false)
	Car._set_aero_visible(body, true)
	assert_true(body.get_node("wing_aero").visible, "top-level aero mesh revealed")
	assert_true(body.get_node("front/splitter_aero").visible, "nested aero mesh revealed")


func test_set_aero_visible_null_body_is_noop() -> void:
	Car._set_aero_visible(null, true)  # must not crash
	assert_true(true, "null body is a safe no-op")


const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

var _scene: Node3D


# The wiring tests need a car with a glb body (use_model). Pick one from the
# REAL catalogue by opaque iteration (not by hard-coded id), so the test tracks
# the code contract, not a specific entry.
func _first_model_car() -> Dictionary:
	for i in CarLibrary.all().size():
		var spec: Dictionary = CarLibrary.all()[i]
		if bool(spec.get("use_model", false)):
			return {"index": i, "spec": spec}
	return {}


func before_each() -> void:
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)


func after_each() -> void:
	Config.reset()


func test_body_reveal_hides_wing_by_default() -> void:
	var found := _first_model_car()
	if found.is_empty():
		pass_test("no glb-body car in the catalogue; skipping")
		return
	var car: VehicleBody3D = _scene.get_node("Car")
	var body := car.get_node(String(found.spec["model_node"]))
	var stub := MeshInstance3D.new()
	stub.name = "stub_aero"
	body.add_child(stub)
	car.apply_car(int(found.index))
	assert_false(stub.visible, "wing hidden by default when a body is revealed")


func test_aero_visibility_follows_enabled_state() -> void:
	var found := _first_model_car()
	if found.is_empty():
		pass_test("no glb-body car in the catalogue; skipping")
		return
	var car: VehicleBody3D = _scene.get_node("Car")
	var body := car.get_node(String(found.spec["model_node"]))
	var stub := MeshInstance3D.new()
	stub.name = "stub_aero"
	body.add_child(stub)
	car.apply_car(int(found.index))
	var model_id := String(found.spec["id"])
	car._apply_aero_visibility({
		"model_id": model_id, "installed_upgrades": ["aero_kit"], "disabled_upgrades": [],
	})
	assert_true(stub.visible, "wing shown when aero kit is fitted+enabled")
	car._apply_aero_visibility({
		"model_id": model_id, "installed_upgrades": ["aero_kit"], "disabled_upgrades": ["aero_kit"],
	})
	assert_false(stub.visible, "wing hidden when the aero kit is disabled")
	car._apply_aero_visibility({
		"model_id": model_id, "installed_upgrades": [], "disabled_upgrades": [],
	})
	assert_false(stub.visible, "wing hidden with no aero kit")


func test_set_body_hidden_restore_keeps_wing_for_upgraded_car() -> void:
	var found := _first_model_car()
	if found.is_empty():
		pass_test("no glb-body car in the catalogue; skipping")
		return
	var car: VehicleBody3D = _scene.get_node("Car")
	var body := car.get_node(String(found.spec["model_node"]))
	var stub := MeshInstance3D.new()
	stub.name = "stub_aero"
	body.add_child(stub)
	car.apply_car(int(found.index))
	car._apply_aero_visibility({
		"model_id": String(found.spec["id"]), "installed_upgrades": ["aero_kit"], "disabled_upgrades": [],
	})
	assert_true(stub.visible, "precondition: wing shown")
	car.set_body_hidden(true)
	# set_body_hidden(true) hides the whole body (the wing's parent), not the wing's
	# own `visible` flag, so check effective tree visibility rather than the local flag.
	assert_false(stub.is_visible_in_tree(), "wing hidden while body is hidden")
	car.set_body_hidden(false)
	assert_true(stub.visible, "wing restored for an upgraded car after un-hiding")


func test_aero_meshes_keep_their_own_material() -> void:
	# The body-material pass re-skins glb meshes with the car's baked PS1 texture,
	# but aero parts (bolt-on, distinct look, no UVs on the body atlas) must KEEP
	# their own authored material. Inject a sentinel material on a *_aero mesh and a
	# non-aero mesh, field the body, and assert only the non-aero one is re-skinned.
	var found := _first_model_car()
	if found.is_empty():
		pass_test("no glb-body car in the catalogue; skipping")
		return
	var car: VehicleBody3D = _scene.get_node("Car")
	var body := car.get_node(String(found.spec["model_node"]))
	var sentinel := StandardMaterial3D.new()  # not the PS1 ShaderMaterial the body pass applies
	var wing := MeshInstance3D.new()
	wing.name = "wing_aero"
	wing.mesh = BoxMesh.new()  # needs a surface for a surface-0 material slot
	wing.set_surface_override_material(0, sentinel)
	body.add_child(wing)
	var panel := MeshInstance3D.new()
	panel.name = "spare_panel"  # non-aero: should be re-skinned
	panel.mesh = BoxMesh.new()
	body.add_child(panel)
	# _apply_model_material walks find_children(..., owned=true) like the real glb
	# import, so injected nodes need an owner to be seen (mirrors imported meshes).
	wing.owner = _scene
	panel.owner = _scene
	car.apply_car(int(found.index))  # runs _apply_model_material over the body
	assert_eq(wing.get_surface_override_material(0), sentinel,
		"aero mesh keeps its own authored material")
	assert_true(panel.get_surface_override_material(0) is ShaderMaterial,
		"a non-aero body mesh is re-skinned with the PS1 material")

extends GutTest
# Aero MESHES on a REAL booted car: a spoiler/splitter is a mesh tagged `_aero` inside a
# car body's glb. It used to be HIDDEN by default and revealed only when the aero PART was
# fitted; that gate went with the parts model (todo/roguelike-pivot.md decision 24 — the
# wing is "a plain per-car property" now, and the property is the authored geometry), so
# what is left to test is the one thing car.gd still does with the tag: the body-material
# pass must leave an aero mesh's own material alone.
#
# The deleted half (`_set_aero_visible` / `_apply_aero_visibility`, and the pure-traversal
# file test_aero_visible_traversal.gd that covered it) went with the gate.

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


func before_all() -> void:
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)


func after_all() -> void:
	_scene.free()
	Config.reset()


# THE WING IS PART OF THE BODY. Nothing hides it any more, so revealing a model car's body
# must reveal its aero meshes with it — the regression this guards is a re-introduced
# default-hide (which is exactly how the old code started).
func test_revealing_a_model_body_leaves_its_aero_meshes_visible() -> void:
	var found := _first_model_car()
	if found.is_empty():
		pass_test("no glb-body car in the catalogue; skipping")
		return
	var car: VehicleBody3D = _scene.get_node("Car")
	var body := car.get_node(String(found.spec["model_node"]))
	var stub := MeshInstance3D.new()
	stub.name = "stub_aero"
	autofree(stub)
	body.add_child(stub)
	car.apply_car(int(found.index))
	assert_true(stub.visible, "an aero mesh is shown with the body it belongs to")
	assert_true(stub.is_visible_in_tree(), "and is actually on screen")
	# The debug-overlay round trip must not lose it either.
	car.set_body_hidden(true)
	assert_false(stub.is_visible_in_tree(), "hidden with the whole body")
	car.set_body_hidden(false)
	assert_true(stub.is_visible_in_tree(), "and back with it")


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
	autofree(wing)
	body.add_child(wing)
	var panel := MeshInstance3D.new()
	panel.name = "spare_panel"  # non-aero: should be re-skinned
	panel.mesh = BoxMesh.new()
	autofree(panel)
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

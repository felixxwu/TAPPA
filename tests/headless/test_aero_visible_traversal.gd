extends GutTest
# Pure traversal logic for Car._set_aero_visible: it walks a body node and toggles
# ONLY the meshes tagged `_aero` (including nested ones), leaving everything else
# alone. Split out of test_aero_visibility.gd, whose before_each builds
# minimal_world() + main.tscn for every test (~1.1 s each) — these three drive a
# hand-built Node3D and never touch that scene, so the build was pure cost.
#
# The scene-backed half (aero reveal follows the fitted+enabled upgrade state on a
# real booted car) stays in test_aero_visibility.gd.

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

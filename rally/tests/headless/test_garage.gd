extends GutTest

# Structural smoke test for the procedural rally-team garage (scripts/garage.gd,
# garage.tscn). The garage builds entirely from primitives in _ready with no
# autoload dependency and no terrain generation, so it's cheap to instance here.
# We assert the model came up with its key elements (structure, branded fascia,
# bay floors, crew pillars, ceiling lights, the hero car, crew figures) and that
# building it raises no script errors (the runner fails on any "SCRIPT ERROR").

var _garage: Node3D


func before_all() -> void:
	_garage = load("res://garage.tscn").instantiate()
	add_child(_garage)
	await get_tree().process_frame  # let _ready() build the model


func after_all() -> void:
	_garage.free()


# All Label3D text in the model, lowercased, joined — handy for branding checks.
func _all_text() -> String:
	var parts := PackedStringArray()
	for l in _garage.find_children("*", "Label3D", true, false):
		parts.append((l as Label3D).text)
	return "\n".join(parts)


func test_garage_instantiates() -> void:
	assert_not_null(_garage, "garage scene instantiates")


func test_has_substantial_geometry() -> void:
	# The structure, floors, pillars, lights, car, clutter and figures add up to a
	# lot of mesh instances — a low count means a build step silently no-op'd.
	var meshes := _garage.find_children("*", "MeshInstance3D", true, false)
	assert_gt(meshes.size(), 40, "garage built a substantial number of mesh instances")


func test_environment_and_lighting_present() -> void:
	var we := _garage.find_children("*", "WorldEnvironment", true, false)
	assert_eq(we.size(), 1, "garage builds its own WorldEnvironment")
	var sun := _garage.find_children("*", "DirectionalLight3D", true, false)
	assert_eq(sun.size(), 1, "garage builds a sun (DirectionalLight3D)")
	var lamps := _garage.find_children("*", "OmniLight3D", true, false)
	assert_eq(lamps.size(), _garage.NUM_BAYS, "one interior lamp per bay")


func test_brand_fascia_text_present() -> void:
	var text := _all_text()
	assert_true(text.contains("GR"), "GR logo text on the fascia")
	assert_true(text.contains("TOYOTA GAZOO Racing"), "Toyota Gazoo Racing wordmark present")
	assert_true(text.contains("Pushing the limits for Better"), "tagline present")


func test_crew_name_pillars_present() -> void:
	var text := _all_text()
	for crew in _garage.CREW_NAMES:
		assert_true(text.contains(crew), "crew name plate present: " + crew)


func test_hero_car_present_with_number() -> void:
	# The hero car is a Node3D holding the body blocks + four wheel hubs; it shows
	# the #18 number panel. Find it by the number label and assert it has wheels.
	assert_true(_all_text().contains("18"), "hero car carries its race number")
	var cylinders := 0
	for mi in _garage.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).mesh is CylinderMesh:
			cylinders += 1
	# 4 car wheels (tyre+rim = 8 cylinders) + tyre stack + hose pole etc.
	assert_gt(cylinders, 8, "wheels / tyres built from cylinders")


func test_timing_screen_present() -> void:
	assert_true(_all_text().contains("11:26:54"), "pit timing screen shows the clock")


func test_crew_figures_present() -> void:
	# Each crew figure has a sphere head; assert several heads exist.
	var spheres := 0
	for mi in _garage.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).mesh is SphereMesh:
			spheres += 1
	assert_gt(spheres, 2, "crew figures (sphere heads) populate the bays")


func test_survives_a_few_frames() -> void:
	for _i in 4:
		await get_tree().process_frame
	assert_true(true, "garage survives a few process frames without errors")

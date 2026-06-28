extends GutTest

# Structural smoke test for the procedural rally-team garage (scripts/garage.gd,
# garage.tscn). The garage builds entirely from primitives in _ready with no
# autoload dependency and no terrain generation, so it's cheap to instance here.
# It's a deliberately bare two-bay shell, so the checks assert the structure +
# lighting are present, the interior is EMPTY, and there's no leftover branding.
# Building it must raise no script errors (the runner fails on any "SCRIPT ERROR").

var _garage: Node3D


func before_all() -> void:
	_garage = load("res://garage.tscn").instantiate()
	add_child(_garage)
	await get_tree().process_frame  # let _ready() build the model


func after_all() -> void:
	_garage.free()


func test_garage_instantiates() -> void:
	assert_not_null(_garage, "garage scene instantiates")


func test_two_bays() -> void:
	assert_eq(_garage.NUM_BAYS, 2, "garage has two bays")


func test_structure_geometry_present() -> void:
	# Slab, back + 2 side walls, 3 pillars, fascia, roof, 2 ground planes and the
	# 2 ceiling strips — a modest, simplified mesh count. Assert it's in a sane
	# band: enough to be the shell, few enough to confirm the interior is bare.
	var meshes := _garage.find_children("*", "MeshInstance3D", true, false)
	assert_between(meshes.size(), 10, 22, "garage built the simplified shell (no clutter)")


func test_interior_is_empty() -> void:
	# An empty shell carries no signage, no car/lift and no crew, so there are no
	# Label3D nodes and no cylinder/sphere/torus props anywhere in the model.
	assert_eq(_garage.find_children("*", "Label3D", true, false).size(), 0,
		"no text/signage in the empty garage")
	for mi in _garage.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		assert_true(mesh is BoxMesh or mesh is PlaneMesh,
			"only structural box/plane meshes remain (no prop primitives)")


func test_environment_and_lighting_present() -> void:
	var we := _garage.find_children("*", "WorldEnvironment", true, false)
	assert_eq(we.size(), 1, "garage builds its own WorldEnvironment")
	var sun := _garage.find_children("*", "DirectionalLight3D", true, false)
	assert_eq(sun.size(), 1, "garage builds a sun (DirectionalLight3D)")
	var lamps := _garage.find_children("*", "OmniLight3D", true, false)
	assert_eq(lamps.size(), _garage.NUM_BAYS, "one interior lamp per bay")


func test_survives_a_few_frames() -> void:
	for _i in 4:
		await get_tree().process_frame
	assert_true(true, "garage survives a few process frames without errors")

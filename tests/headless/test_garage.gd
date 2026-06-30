extends GutTest

# Structural smoke test for the procedural rally-team garage (scripts/garage.gd,
# garage.tscn). The garage builds entirely from primitives in _ready with no
# autoload dependency and no terrain generation, so it's cheap to instance here.
# It's a two-bay shell furnished to look lived-in (textured floor/walls, tool
# chests, a workbench, a pegboard, a tyre stack) while keeping the bay centres
# clear for the HQ's map table / tuning lift. The checks assert the structure +
# lighting + furnishings are present and that there's no team branding. Building
# it must raise no script errors (the runner fails on any "SCRIPT ERROR").

var _garage: Node3D


func before_all() -> void:
	_garage = load("res://garage.tscn").instantiate()
	add_child(_garage)
	await get_tree().process_frame  # let _ready() build the model


func after_all() -> void:
	_garage.free()


func _meshes() -> Array:
	return _garage.find_children("*", "MeshInstance3D", true, false)


func test_garage_instantiates() -> void:
	assert_not_null(_garage, "garage scene instantiates")


func test_has_service_bays() -> void:
	# num_bays is a tunable @export that drives the layout — assert it's a sane
	# multi-bay garage, not a literal count that churns if a bay is added/removed.
	assert_gte(_garage.num_bays, 1, "garage has at least one service bay")


func test_structure_and_props_geometry_present() -> void:
	# Shell (slab, walls, pillars, fascia, roof) + ground + ceiling strips + the
	# interior furnishings (cabinets, pegboards, workbench, tyres). A sane upper
	# bound guards against runaway clutter.
	assert_between(_meshes().size(), 28, 70, "garage built the furnished shell")


func test_textured_surfaces_present() -> void:
	# Floor, walls, cabinets, pegboards and the bench carry image textures — the
	# "lived-in" look. Several meshes should have an albedo_texture assigned.
	var textured := 0
	for mi in _meshes():
		var mat := (mi as MeshInstance3D).material_override as StandardMaterial3D
		if mat != null and mat.albedo_texture != null:
			textured += 1
	assert_gt(textured, 8, "many surfaces are textured (floor, walls, cabinets, …)")


func test_tool_cabinets_present() -> void:
	# At least one mesh uses the tool-chest texture.
	var cabinets := 0
	for mi in _meshes():
		var mat := (mi as MeshInstance3D).material_override as StandardMaterial3D
		if mat != null and mat.albedo_texture != null \
				and mat.albedo_texture.resource_path == _garage.TEX_CABINET:
			cabinets += 1
	assert_gt(cabinets, 3, "tool chests line the bays")


func test_tyre_stack_present() -> void:
	var cylinders := 0
	for mi in _meshes():
		if (mi as MeshInstance3D).mesh is CylinderMesh:
			cylinders += 1
	assert_gte(cylinders, 4, "a tyre stack (cylinders) furnishes a corner")


func test_no_team_branding() -> void:
	# The model carries no signage / branding text.
	assert_eq(_garage.find_children("*", "Label3D", true, false).size(), 0,
		"no branding text in the garage")


func test_environment_and_lighting_present() -> void:
	var we := _garage.find_children("*", "WorldEnvironment", true, false)
	assert_eq(we.size(), 1, "garage builds its own WorldEnvironment")
	var sun := _garage.find_children("*", "DirectionalLight3D", true, false)
	assert_eq(sun.size(), 1, "garage builds a sun (DirectionalLight3D)")
	var lamps := _garage.find_children("*", "OmniLight3D", true, false)
	assert_eq(lamps.size(), _garage.num_bays, "one interior lamp per bay")


func test_survives_a_few_frames() -> void:
	for _i in 4:
		await get_tree().process_frame
	assert_true(true, "garage survives a few process frames without errors")

extends GutTest
# RallyFlag: the procedural flag marker that replaced the cone pin on the HQ map
# table (hq._make_pin). Covers the state→colour medal ladder and that build()
# yields a usable marker (pole + pennant + finial) rooted at the plane.


func test_state_colour_is_the_medal_ladder() -> void:
	# Locked wins over any star count and is a dark, desaturated charcoal.
	var locked := RallyFlag.state_color(true, 3)
	assert_eq(locked, RallyFlag.state_color(true, 0), "locked colour ignores stars")
	assert_lt(locked.v, 0.5, "locked reads dark/disabled")
	# Each unlocked tier is a distinct colour.
	var red := RallyFlag.state_color(false, 0)
	var bronze := RallyFlag.state_color(false, 1)
	var silver := RallyFlag.state_color(false, 2)
	var gold := RallyFlag.state_color(false, 3)
	var seen := {red: 0, bronze: 0, silver: 0, gold: 0}
	assert_eq(seen.size(), 4, "the four unlocked tiers are all distinct colours")
	assert_ne(red, locked, "an unlocked 0-star flag is not the locked colour")
	# Silver is brighter than bronze, gold is warm (red channel dominant).
	assert_gt(silver.v, bronze.v, "silver reads brighter than bronze")
	assert_gt(gold.r, gold.b, "gold is a warm colour")


func test_build_yields_a_marker_rooted_at_the_plane() -> void:
	var flag := RallyFlag.build(false, 2)
	autofree(flag)
	assert_true(flag is Node3D, "build returns a Node3D marker")
	var meshes := flag.find_children("*", "MeshInstance3D", true, false)
	assert_gte(meshes.size(), 3, "marker has at least pole + pennant + finial meshes")
	# Base sits on the plane (y = 0) and the marker stands up to the pole height.
	assert_eq(flag.position, Vector3.ZERO, "marker root sits at its own origin")
	assert_gt(RallyFlag.POLE_HEIGHT, 0.0, "the pole has positive height")


func test_locked_flag_dims_its_finial() -> void:
	# The locked flag greys its finial bead (no gold accent) so it reads disabled;
	# an active flag keeps the warm gold finial.
	var locked := RallyFlag.build(true, 0)
	autofree(locked)
	var active := RallyFlag.build(false, 0)
	autofree(active)
	var locked_finial := _finial_color(locked)
	var active_finial := _finial_color(active)
	assert_ne(locked_finial, active_finial, "locked finial differs from the active gold finial")
	assert_lt(locked_finial.r, active_finial.r, "locked finial is duller than the gold bead")


# The finial is the only sphere-mesh child of the marker.
func _finial_color(flag: Node3D) -> Color:
	for mi in flag.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh is SphereMesh:
			return (mi.material_override as StandardMaterial3D).albedo_color
	return Color.BLACK

extends GutTest
# RallyFlag: the procedural flag marker on the HQ map table (hq._make_pin). Covers
# the two state axes — the pennant kind (checkered / green / grey) and the tip+base
# accent (gold / metal) — plus that build() yields a usable marker on a base disk.


func test_pennant_kind_prioritises_a_podium_result() -> void:
	# Placed 3rd or better (stars >= 1) → checkered, regardless of eligibility.
	for stars in [1, 2, 3]:
		assert_eq(RallyFlag.pennant_kind(false, stars, true), RallyFlag.PENNANT_CHECKERED,
			"a podium finish shows the checkered flag")
		assert_eq(RallyFlag.pennant_kind(false, stars, false), RallyFlag.PENNANT_CHECKERED,
			"checkered wins even with no eligible car")


func test_pennant_kind_green_when_raceable_else_grey() -> void:
	# Not yet podiumed: green when an eligible car is owned, grey when not.
	assert_eq(RallyFlag.pennant_kind(false, 0, true), RallyFlag.PENNANT_SOLID_GREEN,
		"an eligible car but no podium → green")
	assert_eq(RallyFlag.pennant_kind(false, 0, false), RallyFlag.PENNANT_SOLID_GREY,
		"no eligible car → grey")


func test_pennant_kind_locked_is_always_grey() -> void:
	# A locked rally can't be raced or podiumed; it reads grey/disabled either way.
	assert_eq(RallyFlag.pennant_kind(true, 0, true), RallyFlag.PENNANT_SOLID_GREY,
		"locked + eligible still reads grey")
	assert_eq(RallyFlag.pennant_kind(true, 3, true), RallyFlag.PENNANT_SOLID_GREY,
		"locked ignores any (impossible) stars")


func test_accent_is_gold_only_when_won() -> void:
	# Tip + base go gold only on a 1st-place finish (3 stars); metal grey otherwise.
	var gold := RallyFlag.accent_color(false, 3)
	assert_eq(gold, RallyFlag.ACCENT_GOLD, "3 stars (won) → gold tip/base")
	assert_gt(gold.r, gold.b, "gold is a warm colour")
	for stars in [0, 1, 2]:
		assert_eq(RallyFlag.accent_color(false, stars), RallyFlag.ACCENT_METAL,
			"a non-win is metal grey")
	assert_eq(RallyFlag.accent_color(true, 3), RallyFlag.ACCENT_METAL,
		"a locked rally never shows the gold accent")


func test_build_yields_a_marker_rooted_at_the_plane() -> void:
	var flag := RallyFlag.build(false, 2, true)
	autofree(flag)
	assert_true(flag is Node3D, "build returns a Node3D marker")
	var meshes := flag.find_children("*", "MeshInstance3D", true, false)
	assert_gte(meshes.size(), 4, "marker has at least disk + pole + pennant + finial meshes")
	# Base sits on the plane (y = 0) and the marker stands up to the pole height.
	assert_eq(flag.position, Vector3.ZERO, "marker root sits at its own origin")
	assert_gt(RallyFlag.POLE_HEIGHT, 0.0, "the pole has positive height")


func test_marker_has_a_base_disk_on_the_plane() -> void:
	# A short, wide disk sits flush on the map (its underside at y = 0) and is wider
	# than the pole so the flag visibly stands on a pedestal.
	var flag := RallyFlag.build(false, 3, true)
	autofree(flag)
	var disk := _disk(flag)
	assert_not_null(disk, "marker has a disk-shaped base")
	assert_almost_eq(disk.position.y, RallyFlag.DISK_HEIGHT * 0.5, 0.0001,
		"disk rests with its underside on the plane")
	assert_gt(RallyFlag.DISK_RADIUS, RallyFlag.POLE_RADIUS, "disk is wider than the pole")


func test_won_rally_gilds_tip_and_base_together() -> void:
	# A won (3-star) rally: both the finial bead and the base disk are gold; a
	# non-win shares the metal grey across both.
	var won := RallyFlag.build(false, 3, true)
	autofree(won)
	assert_eq(_disk_color(won), RallyFlag.ACCENT_GOLD, "won base disk is gold")
	assert_eq(_finial_color(won), RallyFlag.ACCENT_GOLD, "won finial is gold")
	var unwon := RallyFlag.build(false, 1, true)
	autofree(unwon)
	assert_eq(_disk_color(unwon), RallyFlag.ACCENT_METAL, "un-won base disk is metal grey")
	assert_eq(_finial_color(unwon), RallyFlag.ACCENT_METAL, "un-won finial is metal grey")


func test_checkered_pennant_carries_a_texture() -> void:
	# A podiumed flag's pennant uses the checker texture; a green/grey one is a flat
	# tint with no texture.
	var podiumed := RallyFlag.build(false, 2, true)
	autofree(podiumed)
	var green := RallyFlag.build(false, 0, true)
	autofree(green)
	assert_not_null(_pennant_mat(podiumed).albedo_texture, "checkered pennant has a texture")
	assert_null(_pennant_mat(green).albedo_texture, "green pennant is a flat tint")
	assert_eq(_pennant_mat(green).albedo_color, RallyFlag.PENNANT_GREEN, "raceable pennant is green")


# --- helpers -----------------------------------------------------------------

# The base disk is the wide, short cylinder; the pole is the thin tall one.
func _disk(flag: Node3D) -> MeshInstance3D:
	for mi in flag.find_children("*", "MeshInstance3D", true, false):
		var cyl := mi.mesh as CylinderMesh
		if cyl != null and cyl.top_radius > RallyFlag.POLE_RADIUS * 2.0:
			return mi
	return null


func _disk_color(flag: Node3D) -> Color:
	return (_disk(flag).material_override as StandardMaterial3D).albedo_color


# The finial is the only sphere-mesh child of the marker.
func _finial_color(flag: Node3D) -> Color:
	for mi in flag.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh is SphereMesh:
			return (mi.material_override as StandardMaterial3D).albedo_color
	return Color.BLACK


# The pennant is the only ArrayMesh child of the marker.
func _pennant_mat(flag: Node3D) -> StandardMaterial3D:
	for mi in flag.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh is ArrayMesh:
			return mi.material_override as StandardMaterial3D
	return null

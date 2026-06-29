extends GutTest
# RoadMarkings: static lane paint (two solid edge lines + a dashed centre line)
# built along the tarmac sections of the centerline. Driven against a straight
# Curve2D with a stub terrain, so the surface gating / geometry is checked without
# a real track or rendering. See features/track.md.

const RoadMarkings = preload("res://scripts/road_markings.gd")


# Stub terrain: reports (road_weight, tarmac_weight) like TerrainManager.surface_at.
# `tarmac_from_z` lets a test paint only part of the road (tarmac past a z line) so
# the spatial gating can be asserted. height_at/light_at are omitted on purpose —
# RoadMarkings duck-types them, so absence reads as ground 0 / unlit white.
class StubTerrain:
	extends Node
	var tarmac := 1.0
	var tarmac_from_z := -INF  # tarmac only where world z >= this
	func surface_at(_x: float, z: float) -> Vector2:
		var t: float = tarmac if z >= tarmac_from_z else 0.0
		return Vector2(1.0, t)


var _curve: Curve2D


func before_each() -> void:
	# A straight road 200 m along +Z (curve points are Vector2(world_x, world_z)).
	_curve = Curve2D.new()
	_curve.add_point(Vector2(0, 0))
	_curve.add_point(Vector2(0, 200))


# Default params (track_width 6 -> half_width 3); merge any overrides on top.
func _params(overrides := {}) -> Dictionary:
	var p := {
		"enabled": true,
		"half_width": 3.0,
		"color": Color(0.82, 0.82, 0.78),
		"width_m": 0.12,
		"edge_inset_m": 0.4,
		"center_dash_m": 1.5,
		"center_gap_m": 3.0,
		"height_m": 0.05,
		"tarmac_threshold": 0.5,
		"sample_step_m": 0.4,
	}
	for k in overrides:
		p[k] = overrides[k]
	return p


func _make(terrain: Node, overrides := {}) -> RoadMarkings:
	var rm := RoadMarkings.new()
	add_child_autofree(rm)
	rm.build(_curve, terrain, _params(overrides))
	return rm


func test_paints_lines_on_tarmac() -> void:
	# Whole road tarmac (null terrain reads as full tarmac): all three lines appear.
	var rm := _make(null)
	assert_gt(rm.triangle_count(), 0, "lane paint is laid on a tarmac road")


func test_no_paint_on_gravel() -> void:
	var terrain := StubTerrain.new()
	terrain.tarmac = 0.0
	add_child_autofree(terrain)
	var rm := _make(terrain)
	assert_eq(rm.triangle_count(), 0, "a gravel road carries no painted lines")


func test_disabled_paints_nothing() -> void:
	var rm := _make(null, {"enabled": false})
	assert_eq(rm.triangle_count(), 0, "disabled -> no paint mesh")


func test_edge_lines_sit_inside_the_road_edges() -> void:
	# Straight road along +Z: the painted mesh spans the two edge lines. Each edge
	# line centre sits at half_width - edge_inset = 2.6 m; the stripe's outer rail is
	# half the width further out (2.66 m), so the mesh is ~5.32 m wide and stays
	# inside the 6 m road.
	var rm := _make(null)
	var box := rm.aabb()
	var outer := 3.0 - 0.4 + 0.12 * 0.5
	assert_almost_eq(box.size.x, outer * 2.0, 0.05, "paint spans both edge lines, inside the road")
	assert_lt(box.size.x, 6.0, "no stripe spills past the road edge")


func test_paint_only_on_the_tarmac_stretch() -> void:
	# Tarmac only past z = 100: the paint mesh starts there, not at the gravel start.
	var terrain := StubTerrain.new()
	terrain.tarmac_from_z = 100.0
	add_child_autofree(terrain)
	var rm := _make(terrain)
	assert_gt(rm.triangle_count(), 0, "the tarmac half is painted")
	var box := rm.aabb()
	assert_gt(box.position.z, 100.0 - 5.0, "no paint on the gravel half before the switch")


func test_dashed_centre_line_leaves_gaps() -> void:
	# A larger gap paints fewer centre-line quads, so the total triangle count drops —
	# i.e. the centre line really is broken into dashes rather than drawn solid.
	var dense := _make(null, {"center_gap_m": 1.0}).triangle_count()
	var sparse := _make(null, {"center_gap_m": 20.0}).triangle_count()
	assert_lt(sparse, dense, "wider dash gaps remove centre-line geometry")

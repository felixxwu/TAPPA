extends GutTest

# Tests for scripts/chunk_border_debug.gd — the H-toggle chunk-border overlay.
# LOGIC only: hidden = no geometry; visible = line geometry that scales with the
# chunk count; colour encodes each chunk's ring role.

const ManagerScript := preload("res://scripts/terrain_manager.gd")


func _make_manager() -> Node3D:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	var layer := TerrainLayer.new()
	layer.wavelength_m = 60.0
	layer.amplitude_m = 2.0
	m.layers = [layer] as Array[TerrainLayer]
	autofree(m)
	return m


func _vertex_count(d: ChunkBorderDebug) -> int:
	if d.mesh.get_surface_count() == 0:
		return 0
	var verts: PackedVector3Array = d.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	return verts.size()


func test_hidden_rebuild_draws_nothing() -> void:
	var m := _make_manager()
	var d := ChunkBorderDebug.new()
	autofree(d)
	d.visible = false
	d.rebuild(m, [Vector2i(0, 0)], Vector2i(0, 0))
	assert_eq(d.mesh.get_surface_count(), 0, "no geometry built while hidden")


func test_visible_geometry_scales_with_chunk_count() -> void:
	var m := _make_manager()
	var d := ChunkBorderDebug.new()
	autofree(d)
	d.visible = true
	d.rebuild(m, [Vector2i(0, 0)], Vector2i(0, 0))
	var one := _vertex_count(d)
	assert_gt(one, 0, "visible rebuild produces line vertices")
	d.rebuild(m, [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)], Vector2i(0, 0))
	assert_eq(_vertex_count(d), one * 3, "vertex count scales linearly with chunk count")


func test_colour_encodes_ring_role() -> void:
	var m := _make_manager()  # collision_ring defaults to 1
	var d := ChunkBorderDebug.new()
	autofree(d)
	d.visible = true
	# center (0,0) → current (yellow); (3,0) is ring 3 > collision_ring → render-only (blue).
	d.rebuild(m, [Vector2i(0, 0), Vector2i(3, 0)], Vector2i(0, 0))
	var colors: PackedColorArray = d.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	# Mesh colours are stored 8-bit, so match with a small tolerance rather than exact.
	var a := ChunkBorderDebug.LINE_ALPHA
	assert_true(_has_color(colors, Color(Color.YELLOW, a)), "current chunk drawn yellow at overlay alpha")
	assert_true(_has_color(colors, Color(Color.DEEP_SKY_BLUE, a)), "far render-only chunk drawn sky blue at overlay alpha")
	for c: Color in colors:
		assert_almost_eq(c.a, a, 0.02, "every line at overlay opacity")


func _has_color(colors: PackedColorArray, target: Color, tol: float = 0.02) -> bool:
	for c in colors:
		if absf(c.r - target.r) < tol and absf(c.g - target.g) < tol \
				and absf(c.b - target.b) < tol and absf(c.a - target.a) < tol:
			return true
	return false

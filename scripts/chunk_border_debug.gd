@tool
class_name ChunkBorderDebug
extends MeshInstance3D

# Minecraft-style terrain chunk-border overlay, toggled with H
# (`toggle_debug_arrows`, the same debug key as the wheel-force arrows) in debug
# builds. Draws the outline of every loaded TerrainChunk as terrain-hugging line
# loops plus vertical corner posts, drawn THROUGH the terrain (no depth test) so
# the grid reads even over hills. Colour encodes each chunk's role in the LOD /
# collision system so the overlay doubles as a view of that structure:
#   • YELLOW      — the chunk the car is currently in (focus centre)
#   • LIME        — near band: chunks with LIVE collision (within collision_ring)
#   • SKY BLUE    — render-only chunks (far band, no collision)
#
# Owned by TerrainManager, which rebuilds it on chunk crossings while visible.
# `top_level` so its vertices are plain world coordinates regardless of the
# manager's transform. Pure geometry; headless-tested (test_chunk_border_debug).

const EDGE_SEGMENTS := 10          # terrain-following samples per chunk edge
const POST_HEIGHT_M := 8.0         # vertical corner post length
const LINE_ALPHA := 0.3            # subtle overlay — 30% opacity

var _im: ImmediateMesh


func _init() -> void:
	top_level = true
	_im = ImmediateMesh.new()
	mesh = _im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA  # honour the per-vertex alpha
	mat.no_depth_test = true                        # draw the grid over hills
	mat.render_priority = 10
	material_override = mat
	visible = false


# Rebuild the border geometry for `coords` (loaded chunk coords), colouring each
# by its ring distance from `center`. No-op when hidden. Pure: reads tm.height_at,
# tm.collision_ring, and the CHUNK_M constant only.
func rebuild(tm: TerrainManager, coords: Array, center: Vector2i) -> void:
	if not visible:
		return
	_im.clear_surfaces()
	if coords.is_empty():
		return
	_im.surface_begin(Mesh.PRIMITIVE_LINES)
	var chunk_m: float = TerrainManager.CHUNK_M
	for coord: Vector2i in coords:
		var ring: int = maxi(absi(coord.x - center.x), absi(coord.y - center.y))
		var col := Color.YELLOW if coord == center \
			else (Color.LIME_GREEN if ring <= tm.collision_ring else Color.DEEP_SKY_BLUE)
		col.a = LINE_ALPHA
		var x0 := coord.x * chunk_m
		var z0 := coord.y * chunk_m
		var x1 := x0 + chunk_m
		var z1 := z0 + chunk_m
		# Four terrain-following edges.
		_edge(tm, col, x0, z0, x1, z0)
		_edge(tm, col, x1, z0, x1, z1)
		_edge(tm, col, x1, z1, x0, z1)
		_edge(tm, col, x0, z1, x0, z0)
		# Vertical corner posts.
		for c: Vector2 in [Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1)]:
			var h := tm.height_at(c.x, c.y)
			_line(col, Vector3(c.x, h, c.y), Vector3(c.x, h + POST_HEIGHT_M, c.y))
	_im.surface_end()


# One chunk edge as a polyline that follows the terrain height across EDGE_SEGMENTS.
func _edge(tm: TerrainManager, col: Color, ax: float, az: float, bx: float, bz: float) -> void:
	var prev := Vector3(ax, tm.height_at(ax, az), az)
	for s in range(1, EDGE_SEGMENTS + 1):
		var t := float(s) / float(EDGE_SEGMENTS)
		var x := lerpf(ax, bx, t)
		var z := lerpf(az, bz, t)
		var cur := Vector3(x, tm.height_at(x, z), z)
		_line(col, prev, cur)
		prev = cur


func _line(col: Color, a: Vector3, b: Vector3) -> void:
	_im.surface_set_color(col)
	_im.surface_add_vertex(a)
	_im.surface_set_color(col)
	_im.surface_add_vertex(b)

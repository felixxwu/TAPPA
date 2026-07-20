class_name MeshUtil
extends RefCounted

## Shared helpers for pulling meshes out of imported (glb/scene) PackedScenes.


# Instantiate `scene`, recursively walk its node tree to find the first
# MeshInstance3D, and return that instance's `.mesh` (or null if the scene is
# null or contains no MeshInstance3D). The temporary instance is always freed.
#
# Mirrors the extraction logic used across the project (Foliage.tree_mesh /
# Foliage.bush_mesh, spectator_group._extract_mesh, and the car/hq/podium mesh
# pulls): a depth-first search that returns the first mesh found.
static func first_mesh(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var inst := scene.instantiate()
	var mi := _find_mesh_instance(inst)
	var mesh: Mesh = mi.mesh if mi != null else null
	inst.free()
	return mesh


# Apply a distance cull to every GeometryInstance3D in `root`'s subtree (root
# included): each stops drawing (with a `fade_m` dither-fade band) past `end_m`.
# This is how the SHARED world-prop render distance (cfg.tree_render_distance_m /
# tree_render_fade_m) reaches non-foliage props — spectators, signs, the start /
# finish arches — so everything roadside pops in at one range instead of each
# system choosing its own. `end_m <= 0` leaves the subtree uncapped (Godot treats
# visibility_range_end 0 as "no limit"), which keeps flat test fixtures unculled.
# Returns the number of instances touched (for tests). Covers MeshInstance3D,
# MultiMeshInstance3D and Label3D — all GeometryInstance3D.
static func apply_visibility_range(root: Node, end_m: float, fade_m: float) -> int:
	if root == null or end_m <= 0.0:
		return 0
	var touched := 0
	if root is GeometryInstance3D:
		var gi := root as GeometryInstance3D
		gi.visibility_range_end = end_m
		gi.visibility_range_end_margin = fade_m
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		touched += 1
	for child in root.get_children():
		touched += apply_visibility_range(child, end_m, fade_m)
	return touched


# A MeshInstance3D holding a BoxMesh of `size`, carrying `material`, positioned
# at `pos`. NOT parented — the caller adds it to whatever node it wants. Shared
# by the placeholder HQ art (garage / map table / hq environment), which all
# built this same BoxMesh + material_override + position instance by hand.
static func box(size: Vector3, material: Material, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = material
	mi.position = pos
	return mi


# A flat, subdivided square ground grid (size × size, centred on the origin)
# carrying per-vertex the grass→tarmac blend the road-blend shader
# (ps1_models.gdshader, blend_road = true) consumes: COLOR.a is the tarmac
# weight — 1 inside any of the rectangular `pads` (Rect2 in world XZ),
# smoothstep-feathered to 0 across `feather` metres beyond the pad edge — and
# UV2.x = 1 selects pure tarmac (no gravel band). UV carries world XZ so the
# material's texture_tile sets the grass tiling. Shared by the podium's tarmac
# pads and the HQ's concrete apron, so every tarmac edge in the game dissolves
# into grass the way the generated track's verges do.
static func feathered_ground_mesh(size: float, subdiv: int, pads: Array[Rect2], feather: float) -> ArrayMesh:
	var fth := maxf(feather, 0.001)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := maxi(subdiv, 1)
	var step := size / float(n)
	var origin := -size * 0.5
	# Build the (n+1)^2 vertex grid, then index two triangles per cell.
	for j in n + 1:
		for i in n + 1:
			var x := origin + float(i) * step
			var z := origin + float(j) * step
			var w := 0.0
			for pad in pads:
				var c := pad.get_center()
				# Per-axis distance beyond the rect's half-extent (<= 0 inside);
				# feather across the band just outside the edge.
				var d := maxf(absf(x - c.x) - pad.size.x * 0.5, absf(z - c.y) - pad.size.y * 0.5)
				w = maxf(w, 1.0 - smoothstep(0.0, fth, d))
			st.set_color(Color(1.0, 1.0, 1.0, w))
			st.set_uv(Vector2(x, z))
			st.set_uv2(Vector2(1.0, 0.0))
			st.set_normal(Vector3.UP)  # flat floor; keeps the mesh well-formed
			st.add_vertex(Vector3(x, 0.0, z))
	var row := n + 1
	for j in n:
		for i in n:
			var a := j * row + i
			var b := a + 1
			var cc := a + row
			var d := cc + 1
			# Wound so the front face points UP: the shared ps1_models shader culls back
			# faces, so a downward-facing floor draws nothing when viewed from above.
			st.add_index(a); st.add_index(b); st.add_index(cc)
			st.add_index(b); st.add_index(d); st.add_index(cc)
	return st.commit()


# The road-blend ground material the feathered ground mesh is drawn with: the
# grass texture everywhere, blended to the flat tarmac colour by the per-vertex
# weight (see feathered_ground_mesh). Same shader + parameters as the generated
# track's terrain surface.
static func feathered_ground_material(cfg: GameConfig) -> ShaderMaterial:
	var gm := ShaderMaterial.new()
	gm.shader = load("res://shaders/ps1_models.gdshader")
	gm.set_shader_parameter("albedo_texture", load("res://textures/grass.jpg"))
	gm.set_shader_parameter("tarmac_color", cfg.tarmac_color)
	gm.set_shader_parameter("blend_road", true)
	var tpm: float = cfg.terrain_tile_per_meter
	gm.set_shader_parameter("texture_tile", Vector2(tpm, tpm))
	return gm


# Depth-first search for the first MeshInstance3D at or below `n`.
static func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var found := _find_mesh_instance(c)
		if found != null:
			return found
	return null

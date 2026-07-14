class_name TerrainLod
extends RefCounted

# Builds decimated display meshes for terrain LOD. A chunk's full-resolution data
# (SAMPLES × SAMPLES grid, from TerrainChunkBuilder) is the L0 surface used for
# collision and all height/light queries; the coarser display levels are pure
# SUBSAMPLES of that same grid — every level-N vertex is an exact L0 vertex — so
# the levels can never disagree with collision or with each other (the property
# that lets DistantTerrain be retired: one surface, decimated, nothing to clip).
#
# The chunk carries one MeshInstance3D per level, each with a visibility_range
# band + dither crossfade, so the ENGINE selects and blends levels by real camera
# distance every frame at zero script cost (see terrain_chunk.gd). This file is
# pure/static so it's headless-testable.
#
# Seams between neighbouring chunks at different levels are hidden by a downward
# SKIRT (a vertical wall dropped `skirt_m` below each level mesh's perimeter),
# which fills any crack from behind — invisible under fog, cheap, and needs no
# neighbour awareness.

# Stride per level: how many L0 cells each display cell spans. 1 = full detail.
# The strides must DIVIDE (SAMPLES-1) so the coarse grid lands exactly on L0
# vertices (SAMPLES-1 = 50 → clean at 1/2/5/10/25). Level count = LOD_STRIDES.size().
# The coarsest (25) is a 2×2-cell chunk (8 tris + skirt) for the far ring.
const LOD_STRIDES: PackedInt32Array = [1, 2, 5, 10, 25]


# Build the decimated ArrayMesh for one level from a chunk's full-res `data`
# dict (the shape compute_chunk_data returns). `stride` picks every stride-th L0
# vertex along each edge; `skirt_m` (>0) hangs a downward wall off the perimeter.
static func build_level(data: Dictionary, stride: int, skirt_m: float) -> ArrayMesh:
	var samples: int = TerrainManager.SAMPLES
	var per_edge := samples - 1
	assert(per_edge % stride == 0, "LOD stride must divide SAMPLES-1")
	var n := per_edge / stride + 1        # vertices per edge at this level

	var full_v: PackedVector3Array = data["vertices"]
	var full_uv: PackedVector2Array = data["uvs"]
	var full_c: PackedColorArray = data["colors"]
	var has_uv2: bool = data.has("uv2s")
	var full_uv2: PackedVector2Array = data["uv2s"] if has_uv2 else PackedVector2Array()

	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var uv2s := PackedVector2Array()

	# Grid: subsample the L0 arrays at (x*stride, z*stride).
	for zi in n:
		var fz := zi * stride
		for xi in n:
			var fx := xi * stride
			var fidx := fz * samples + fx
			verts.append(full_v[fidx])
			uvs.append(full_uv[fidx])
			colors.append(full_c[fidx])
			if has_uv2:
				uv2s.append(full_uv2[fidx])

	var indices := PackedInt32Array()
	for zi in n - 1:
		for xi in n - 1:
			var a := zi * n + xi
			var b := a + 1
			var c := a + n
			var d := c + 1
			# Clockwise a,b,c / b,d,c — matches TerrainChunkBuilder.data().
			indices.append_array([a, b, c, b, d, c])

	if skirt_m > 0.0:
		_add_skirt(verts, uvs, colors, uv2s, indices, n, has_uv2, skirt_m)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	if has_uv2:
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# All LOD levels for a chunk, one ArrayMesh per LOD_STRIDES entry (index = level).
static func build_all(data: Dictionary, skirt_m: float) -> Array:
	var out: Array = []
	for stride in LOD_STRIDES:
		out.append(build_level(data, stride, skirt_m))
	return out


# Append a downward skirt around the n×n grid perimeter: for each edge vertex,
# add a copy pushed down by skirt_m, then stitch consecutive edge/skirt pairs into
# quads. The skirt reuses the edge vertex's UV/colour so it shades like the ground.
static func _add_skirt(verts: PackedVector3Array, uvs: PackedVector2Array,
		colors: PackedColorArray, uv2s: PackedVector2Array, indices: PackedInt32Array,
		n: int, has_uv2: bool, skirt_m: float) -> void:
	# Perimeter vertex grid-indices in a continuous loop (top edge L→R, right edge
	# T→B, bottom edge R→L, left edge B→T), each appearing once.
	var ring: PackedInt32Array = []
	for xi in n:                       # top row (zi = 0)
		ring.append(xi)
	for zi in range(1, n):             # right column (xi = n-1)
		ring.append(zi * n + (n - 1))
	for xi in range(n - 2, -1, -1):    # bottom row (zi = n-1)
		ring.append((n - 1) * n + xi)
	for zi in range(n - 2, 0, -1):     # left column (xi = 0)
		ring.append(zi * n)

	# Add a lowered copy of each ring vertex; remember its new index.
	var skirt_base := verts.size()
	for gi in ring:
		var v := verts[gi]
		verts.append(Vector3(v.x, v.y - skirt_m, v.z))
		uvs.append(uvs[gi])
		colors.append(colors[gi])
		if has_uv2:
			uv2s.append(uv2s[gi])

	# Stitch each consecutive ring pair into a quad (top edge verts + their skirts).
	# The terrain material is cull_back (ps1_models.gdshader has no cull_disabled), and
	# the outward-facing side of a skirt differs per edge, so emit each quad TWO-SIDED
	# (both windings) — otherwise the back-facing walls cull and the crack shows through
	# to whatever is below (e.g. the lake plane). Skirts are perimeter-only, so the
	# doubled triangle count is negligible.
	var count := ring.size()
	for i in count:
		var t0 := ring[i]
		var t1 := ring[(i + 1) % count]
		var s0 := skirt_base + i
		var s1 := skirt_base + (i + 1) % count
		indices.append_array([t0, t1, s0, t1, s1, s0,     # front
			t0, s0, t1, t1, s0, s1])                       # back

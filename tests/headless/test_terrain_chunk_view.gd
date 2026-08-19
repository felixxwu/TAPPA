extends GutTest
# `TerrainManager._chunk_view` — the shared preamble of the five _apply_* chunk modifiers
# (see features/terrain.md -> "Chunk modifiers"). What is pinned here is the SKIP/ACCEPT
# logic and the derived world rect: which chunks a pass runs on, and where the helper thinks
# the chunk sits in the world. The five modifiers are NOT identical in what they demand, so
# each divergence gets its own case — flattening one of them away would silently change
# which chunks get modified.
#
# Bare logic, no scene: every input is a synthetic chunk dict carrying only the keys the
# helper reads, so nothing here depends on real terrain generation, on the catalogue, or on
# any tunable value.

const ManagerScript := preload("res://scripts/terrain_manager.gd")


func _make_manager() -> TerrainManager:
	# Never added to the tree — _chunk_view is pure and needs no _ready.
	var m := Node3D.new()
	m.set_script(ManagerScript)
	return autofree(m)


# A chunk dict with mutually consistent arrays of `n` entries, centred at (cx, cz).
func _chunk(n: int, cx: float = 0.0, cz: float = 0.0, stride: int = 1) -> Dictionary:
	var heights := PackedFloat32Array()
	heights.resize(n)
	var verts := PackedVector3Array()
	verts.resize(n)
	var colors := PackedColorArray()
	colors.resize(n)
	var uv2s := PackedVector2Array()
	uv2s.resize(n)
	return {
		"heights": heights,
		"vertices": verts,
		"colors": colors,
		"uv2s": uv2s,
		"center": Vector3(cx, 0.0, cz),
		"stride": stride,
	}


func test_consistent_chunk_is_accepted_for_every_need() -> void:
	var m := _make_manager()
	var data := _chunk(9)
	assert_true(m._chunk_view(data, ManagerScript.VIEW_HEIGHTS),
		"heights-only pass accepts a consistent chunk")
	assert_true(m._chunk_view(data, ManagerScript.VIEW_UV2S | ManagerScript.VIEW_FULL_RES),
		"uv2s pass accepts a consistent chunk")
	assert_true(m._chunk_view(data,
			ManagerScript.VIEW_HEIGHTS | ManagerScript.VIEW_COLORS
			| ManagerScript.VIEW_UV2S | ManagerScript.VIEW_FULL_RES),
		"the road carve's full set accepts a consistent chunk")


func test_empty_or_missing_arrays_are_skipped() -> void:
	var m := _make_manager()
	assert_false(m._chunk_view({}, ManagerScript.VIEW_HEIGHTS),
		"a dict with no arrays at all is skipped")
	assert_false(m._chunk_view(_chunk(0), ManagerScript.VIEW_HEIGHTS),
		"an empty height grid is skipped")
	assert_false(m._chunk_view(_chunk(0), ManagerScript.VIEW_UV2S),
		"an empty uv2 grid is skipped")


func test_mismatched_array_sizes_are_skipped() -> void:
	var m := _make_manager()
	# vertices shorter than heights: the lockstep height/vertex rewrite would run off the end.
	var short_verts := _chunk(9)
	var verts: PackedVector3Array = short_verts["vertices"]
	verts.resize(8)
	short_verts["vertices"] = verts
	assert_false(m._chunk_view(short_verts, ManagerScript.VIEW_HEIGHTS),
		"a vertex/height size mismatch is skipped")

	# colors/uv2s mismatched against heights: only the road carve asks for those, and only it
	# should reject the chunk. A heights-only pass must still run on it.
	var short_colors := _chunk(9)
	var colors: PackedColorArray = short_colors["colors"]
	colors.resize(4)
	short_colors["colors"] = colors
	assert_false(m._chunk_view(short_colors,
			ManagerScript.VIEW_HEIGHTS | ManagerScript.VIEW_COLORS
			| ManagerScript.VIEW_UV2S | ManagerScript.VIEW_FULL_RES),
		"a colour/height size mismatch is skipped when colours are needed")
	assert_true(m._chunk_view(short_colors, ManagerScript.VIEW_HEIGHTS),
		"a colour/height size mismatch does NOT skip a pass that ignores colours")

	var short_uv2s := _chunk(9)
	var uv2s: PackedVector2Array = short_uv2s["uv2s"]
	uv2s.resize(4)
	short_uv2s["uv2s"] = uv2s
	assert_false(m._chunk_view(short_uv2s,
			ManagerScript.VIEW_HEIGHTS | ManagerScript.VIEW_COLORS
			| ManagerScript.VIEW_UV2S | ManagerScript.VIEW_FULL_RES),
		"a uv2/height size mismatch is skipped when uv2s are needed")


# The region blend sizes itself against `uv2s` and never reads a height, so it must run on a
# chunk whose heights are absent — the one divergence that makes VIEW_UV2S-without-
# VIEW_HEIGHTS a distinct mode rather than a subset.
func test_uv2_only_pass_ignores_missing_heights() -> void:
	var m := _make_manager()
	var data := _chunk(9)
	data.erase("heights")
	assert_true(m._chunk_view(data, ManagerScript.VIEW_UV2S | ManagerScript.VIEW_FULL_RES),
		"a uv2-only pass runs on a chunk with no heights")
	assert_false(m._chunk_view(data, ManagerScript.VIEW_HEIGHTS),
		"a height pass skips the same chunk")


# VIEW_FULL_RES is what the three passes with the "full-res grids only" LOD note ask for. The
# taper and the quantum deliberately do NOT, so a coarse chunk must still pass for them.
func test_stride_guard_applies_only_when_requested() -> void:
	var m := _make_manager()
	var coarse := _chunk(9, 0.0, 0.0, 2)
	assert_false(m._chunk_view(coarse, ManagerScript.VIEW_HEIGHTS | ManagerScript.VIEW_FULL_RES),
		"a coarse chunk is skipped by a full-res-only pass")
	assert_false(m._chunk_view(coarse, ManagerScript.VIEW_UV2S | ManagerScript.VIEW_FULL_RES),
		"a coarse chunk is skipped by the uv2 full-res-only pass")
	assert_true(m._chunk_view(coarse, ManagerScript.VIEW_HEIGHTS),
		"a coarse chunk is still tapered/quantised (no VIEW_FULL_RES)")
	# A chunk dict with no `stride` key at all defaults to full res.
	var no_stride := _chunk(9)
	no_stride.erase("stride")
	assert_true(m._chunk_view(no_stride, ManagerScript.VIEW_HEIGHTS | ManagerScript.VIEW_FULL_RES),
		"a chunk with no stride key is treated as full res")


# The rect the pad query and the road query are both driven from: a CHUNK_M square centred on
# the chunk's `center`, in world space, in the XZ plane. Derived from the constant, never from
# a hardcoded number.
func test_world_rect_is_a_chunk_square_around_the_centre() -> void:
	var m := _make_manager()
	var side: float = ManagerScript.CHUNK_M
	var cx := 3.0 * side
	var cz := -2.0 * side
	assert_true(m._chunk_view(_chunk(9, cx, cz), ManagerScript.VIEW_HEIGHTS))
	var rect: Rect2 = m._cvw_rect
	assert_almost_eq(rect.size.x, side, 0.001, "rect is one chunk wide")
	assert_almost_eq(rect.size.y, side, 0.001, "rect is one chunk deep")
	assert_almost_eq(rect.get_center().x, cx, 0.001, "rect is centred on center.x")
	assert_almost_eq(rect.get_center().y, cz, 0.001, "rect is centred on center.z (XZ plane)")
	assert_almost_eq(m._cvw_half, side / 2.0, 0.001, "half is half a chunk")
	assert_eq(m._cvw_center, Vector3(cx, 0.0, cz), "center is passed through unchanged")
	# A chunk with no `center` key sits at the origin.
	var no_center := _chunk(9)
	no_center.erase("center")
	assert_true(m._chunk_view(no_center, ManagerScript.VIEW_HEIGHTS))
	assert_eq(m._cvw_center, Vector3.ZERO, "a centre-less chunk defaults to the origin")


# The scratch the accepted view hands back must be the chunk's own arrays, not copies of some
# other chunk's — the modifiers read them straight out of the _cvw_* fields.
func test_accepted_view_exposes_the_chunks_arrays() -> void:
	var m := _make_manager()
	var data := _chunk(9)
	var heights := PackedFloat32Array()
	heights.resize(9)
	heights[4] = 12.5
	data["heights"] = heights
	assert_true(m._chunk_view(data,
		ManagerScript.VIEW_HEIGHTS | ManagerScript.VIEW_COLORS
		| ManagerScript.VIEW_UV2S | ManagerScript.VIEW_FULL_RES))
	assert_eq(m._cvw_heights.size(), 9, "heights are exposed")
	assert_almost_eq(m._cvw_heights[4], 12.5, 0.0001, "with the chunk's own values")
	assert_eq(m._cvw_verts.size(), 9, "vertices are exposed")
	assert_eq(m._cvw_colors.size(), 9, "colours are exposed")
	assert_eq(m._cvw_uv2s.size(), 9, "uv2s are exposed")

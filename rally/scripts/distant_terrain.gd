class_name DistantTerrain
extends MeshInstance3D
# A coarse, low-resolution "backdrop" of the terrain that extends far past the
# detailed TerrainManager chunk ring (which only reaches ~75 m, see RADIUS=1 /
# CHUNK_M=50). It exists purely to give the SKY a distant horizon to sit above:
# without it, reducing the fog would reveal the hard edge where the 3x3 detail
# ring ends. See todo/distant-terrain-and-sky.md §1.
#
# Cheap by design: one indexed mesh (one draw call), built at a coarse cell size
# from the SAME noise as the real terrain (TerrainManager.height_at), with NO
# collision (the car never leaves the detailed ring, which follows it). The coarse
# geometry re-centres on every focus CHUNK crossing and is a FULL, UNCUT grid:
# it underlaps the entire detail ring rather than holing out the loaded chunks.
#
# To stop the coarse mesh poking through the detailed ring, the WHOLE backdrop is
# sunk `sink_m` (1-2 m) below true terrain height. The detail ring renders at true
# height on top, so it always wins the overlap; the coarse mesh stays hidden
# beneath it. At the ring's outer edge the coarse surface steps down by `sink_m`,
# but that edge is ~75 m away and softened by fog, so the step is imperceptible.
#
# This deliberately trades a tiny, constant bit of (occluded) coarse overdraw under
# the detail ring for ZERO per-crossing hole-cutting work: there is no longer any
# loaded-chunk tracking, index re-cut on chunk integration, or skybox-flash race
# to manage — the backdrop only rebuilds when the focus crosses a chunk.
#
# Reuses the terrain's chunk_material so it gets the same grass texture, baked
# light (via TerrainManager.light_at) and fog/post-process as everything else.
# Vertex-colour alpha is 0 (no road blend out here).

var _terrain: TerrainManager
var _focus: Node3D
var radius_m := 250.0       # half-extent of the backdrop square (m)
var cell_m := 10.0          # coarse grid spacing (m) — blocky is fine at distance
var sink_m := 1.5           # drop the whole backdrop below true height so the detail ring wins

# Coarse-backdrop rows built per frame on the incremental (in-play) rebuild path.
# The backdrop is ~2,600 light-baked vertices — as heavy as a detail chunk — so it
# is built a few rows at a time rather than whole on one frame (see _step_rebuild).
const ROWS_PER_FRAME := 8

var _focus_chunk := Vector2i(2147483647, 0)  # force first build
var _per_edge := 0
# A focus chunk crossing marks the backdrop dirty; the actual rebuild is deferred
# to a frame when the detail ring isn't streaming (see _process), so this heavy
# coarse mesh build never lands on the same frame as a detail-chunk build.
var _rebuild_pending := false
var _pending_center := Vector3.ZERO
# Incremental rebuild state: the in-play rebuild fills a fresh grid a few rows per
# frame and swaps it in only when complete, so a re-centre never stalls one frame.
# The visible mesh stays the previous backdrop until the new one finishes.
var _building := false
var _b_samples := 0
var _b_grid_min := Vector2.ZERO
var _b_tile := 1.0
var _b_row := 0
var _b_verts: PackedVector3Array
var _b_uvs: PackedVector2Array
var _b_colors: PackedColorArray


# `terrain` supplies height_at/light_at + the shared chunk material; `focus` (the
# car) drives rebuilds. Builds the first backdrop immediately.
func setup(terrain: TerrainManager, focus: Node3D) -> void:
	_terrain = terrain
	_focus = focus
	if terrain != null and terrain.chunk_material != null:
		material_override = terrain.chunk_material
	var center := _focus.global_position if _focus != null else Vector3.ZERO
	rebuild_around(center)


# Re-centre the coarse geometry on a focus chunk crossing — DEFERRED and SLICED.
# The rebuild is the same ~2,600-vertex, light-baked cost as a detail chunk, so it
# is neither done on the crossing frame nor in one tick: a crossing only marks the
# backdrop dirty (coalescing to the latest centre); the rebuild STARTS on a frame
# when TerrainManager isn't streaming detail chunks (so its first rows don't pile
# onto a detail-chunk build), then fills ROWS_PER_FRAME rows per frame until it
# completes and swaps in. The backdrop is huge and fog-softened, so the few frames'
# lag in re-centring is imperceptible.
func _process(_delta: float) -> void:
	if _focus == null or _terrain == null:
		return
	var chunk := _terrain.chunk_coord_for(_focus.global_position)
	if chunk != _focus_chunk:
		_focus_chunk = chunk  # update now so the crossing isn't re-detected every frame
		_pending_center = _focus.global_position
		_rebuild_pending = true
	# The backdrop never shares a frame with detail-chunk streaming: it only STARTS
	# and only STEPS on frames when nothing is queued/building, so it fills purely in
	# the gaps between detail builds and the two heavy mesh builds never stack. Detail
	# (the ground the car drives on) always has priority; the far, fog-softened
	# backdrop yields and catches up in the idle window before the next crossing.
	if _terrain.is_streaming_chunks():
		return
	if _rebuild_pending and not _building:
		_rebuild_pending = false
		_begin_rebuild(_pending_center)
	if _building:
		_step_rebuild(ROWS_PER_FRAME)


# Build the coarse backdrop centred on `center` synchronously (one call). Used for
# the initial build at world load (behind the loading screen) and by any caller
# that wants it whole; the in-play re-centre uses the sliced _begin/_step path.
func rebuild_around(center: Vector3) -> void:
	if _terrain == null:
		return
	_begin_rebuild(center)
	while _building:
		_step_rebuild(_b_samples)


# Set up a fresh grid centred on `center`, snapped to the cell grid so the surface
# doesn't swim. Allocates the scratch arrays; samples nothing yet (that's _step_rebuild).
func _begin_rebuild(center: Vector3) -> void:
	if _terrain == null:
		return
	_focus_chunk = _terrain.chunk_coord_for(center)
	var cx := snappedf(center.x, cell_m)
	var cz := snappedf(center.z, cell_m)
	_per_edge = int(round((radius_m * 2.0) / cell_m))
	_b_samples = _per_edge + 1
	_b_grid_min = Vector2(cx - radius_m, cz - radius_m)
	_b_tile = _terrain.texture_tile_per_meter
	var count := _b_samples * _b_samples
	_b_verts = PackedVector3Array(); _b_verts.resize(count)
	_b_uvs = PackedVector2Array(); _b_uvs.resize(count)
	_b_colors = PackedColorArray(); _b_colors.resize(count)
	_b_row = 0
	_building = true


# Sample up to `max_rows` grid rows (heights/light come from the terrain noise, so
# the backdrop matches the detail ring at the seam minus the uniform sink). On the
# last row, assemble the indexed mesh and swap it in — a full uncut grid, no holes.
func _step_rebuild(max_rows: int) -> void:
	var done := 0
	while _b_row < _b_samples and done < max_rows:
		var wz := _b_grid_min.y + _b_row * cell_m
		var base := _b_row * _b_samples
		for xi in _b_samples:
			var wx := _b_grid_min.x + xi * cell_m
			var idx := base + xi
			_b_verts[idx] = Vector3(wx, _terrain.height_at(wx, wz) - sink_m, wz)
			_b_uvs[idx] = Vector2(wx, wz) * _b_tile
			var lgt := _terrain.light_at(wx, wz)
			_b_colors[idx] = Color(lgt.r, lgt.g, lgt.b, 0.0)  # alpha 0 = no road blend
		_b_row += 1
		done += 1
	if _b_row >= _b_samples:
		_finish_rebuild()


func _finish_rebuild() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _b_verts
	arrays[Mesh.ARRAY_TEX_UV] = _b_uvs
	arrays[Mesh.ARRAY_COLOR] = _b_colors
	arrays[Mesh.ARRAY_INDEX] = _build_indices(_b_samples)
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = am  # atomic swap — the previous backdrop was visible until now
	_building = false
	# Release the scratch (the mesh owns its own copies now).
	_b_verts = PackedVector3Array()
	_b_uvs = PackedVector2Array()
	_b_colors = PackedColorArray()


# Two triangles per coarse cell, full grid (no holes cut). `samples` is the vertex
# count per edge (_per_edge + 1).
func _build_indices(samples: int) -> PackedInt32Array:
	var indices := PackedInt32Array()
	for zi in _per_edge:
		for xi in _per_edge:
			var a := zi * samples + xi
			var b := a + 1
			var c := a + samples
			var d := c + 1
			indices.append(a); indices.append(b); indices.append(c)
			indices.append(b); indices.append(d); indices.append(c)
	return indices

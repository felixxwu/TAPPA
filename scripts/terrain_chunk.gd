@tool
extends StaticBody3D
class_name TerrainChunk
# Docs: features/terrain.md — update in the same change as this file.
# Tests: tests/headless/test_terrain.gd, tests/headless/test_terrain_lod.gd, tests/headless/test_terrain_noise.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'TerrainChunk' tests/headless/` and read the assertions that pin what you are about to change (5 test files touch this script).

# One tile of the chunked terrain, built at runtime by TerrainManager. Centred
# on its chunk so the centred mesh + HeightMapShape3D span exactly the tile.
#
# LOD: the chunk carries one MeshInstance3D per LOD level (TerrainLod.LOD_STRIDES),
# each with a visibility_range distance band + dither crossfade, so the ENGINE
# selects and blends the right level by real camera distance every frame at zero
# script cost. Collision is a single HeightMapShape3D built from the full-res L0
# heights, ENABLED only when the chunk is near the car (TerrainManager gates it) —
# far chunks are render-only, so shrinking/keeping collision doesn't grow the
# broadphase.

var coord: Vector2i
var _mesh_instances: Array[MeshInstance3D] = []
var _collision: CollisionShape3D
# True when level 0 was deliberately left unbuilt by the precompute and can be built (and
# dropped again) on demand — see TerrainManager's detail ring / TerrainLod.build_finest.
# False for coarse chunks (whose fine levels are pruned for good) and for on-demand
# editor/test builds (which build every level up front).
var _lazy_finest := false


func _init() -> void:
	_collision = CollisionShape3D.new()
	_collision.name = "CollisionShape3D"
	# HeightMapShape3D spans (SAMPLES-1) cells of 1 unit; scale cells to CELL_M.
	# Scaling collision shapes is discouraged in Godot but is the standard
	# workaround since HeightMapShape3D has no cell-size property.
	_collision.scale = Vector3(TerrainManager.CELL_M, 1.0, TerrainManager.CELL_M)
	add_child(_collision)


func setup(manager: TerrainManager, chunk_coord: Vector2i) -> void:
	apply_data(manager, chunk_coord, manager.compute_chunk_data(chunk_coord))


# Main-thread only: assemble the per-level GPU meshes + collision from precomputed
# arrays. `data["lod_meshes"]` is prebaked (TerrainLod.build_all) when the chunk
# comes from the corridor cache; built on demand otherwise (editor / tests).
func apply_data(manager: TerrainManager, chunk_coord: Vector2i, data: Dictionary) -> void:
	coord = chunk_coord
	position = data["center"]

	var meshes: Array = data.get("lod_meshes", [])
	if meshes.is_empty():
		# On-demand (editor / test) data straight out of compute_chunk_data still carries
		# the mesh source arrays, so it can build its levels here. A CACHED dict never
		# can: cache_chunk erases them once TerrainLod.build_all has consumed them
		# (TerrainManager.DEAD_AFTER_PREBAKE). Reaching this branch without `vertices`
		# means a cached chunk lost its prebaked meshes — fail LOUDLY with a mesh-less
		# (but still collidable) chunk rather than building garbage off missing arrays.
		if not data.has("vertices"):
			push_error("terrain chunk %s has no prebaked lod_meshes and no source arrays "
				% chunk_coord + "— cached mesh arrays are freed after prebake")
		else:
			meshes = TerrainLod.build_all(data, manager.lod_skirt_m)
	_ensure_mesh_instances(meshes.size())
	for i in _mesh_instances.size():
		_mesh_instances[i].mesh = meshes[i]   # may be null (pruned coarse / lazy finest)
	_lazy_finest = not data.get("coarse", false) and not meshes.is_empty() \
		and meshes[0] == null
	_apply_level_bands(manager)

	# Collision only when the full-res heightfield is present (full-res chunks). Coarse
	# chunks are never inside collision_ring (see collision-band classification), so a
	# missing shape is safe; assert the invariant to catch any drift loudly.
	#
	# Prefer a PREBUILT shape (TerrainManager.cache_chunk built it behind the loading
	# screen for every chunk in the leash-bounded collision band — see
	# features/terrain.md) so a chunk crossing just reuses the same PhysicsServer
	# resource instead of paying the HeightMapShape3D commit cost again on this frame.
	# Only the on-demand paths (editor preview, tests, cache-empty fallback) lack a
	# prebuilt shape and fall back to building one fresh here.
	var heights: PackedFloat32Array = data.get("heights", PackedFloat32Array())
	if data.get("shape") != null:
		_collision.shape = data["shape"]
	elif heights.size() == TerrainManager.SAMPLES * TerrainManager.SAMPLES:
		var shape := HeightMapShape3D.new()
		shape.map_width = TerrainManager.SAMPLES
		shape.map_depth = TerrainManager.SAMPLES
		shape.map_data = heights
		_collision.shape = shape
	else:
		_collision.shape = null
		assert(data.get("coarse", false), "chunk without full-res heights must be coarse")


# Configure each present level's visibility band from the manager's cutoffs.
#
# Level i is visible from the previous PRESENT level's cutoff out to bands[i], a HARD
# cutoff (no fade). The dithered visibility-range fade is a Forward+/Mobile feature — the
# Compatibility renderer this game uses IGNORES it and hard-cuts anyway, and the dither is
# an alpha-hash `discard` that would defeat early-Z on tile GPUs (bad on our opaque
# terrain). The pop is small and hidden by construction: coarse levels are EXACT
# subsamples (shared vertices don't move), the terrain is gentle, skirts cover the crack,
# and fog softens distance. Indices are clamped so a bands/levels length mismatch can't
# range-error (deepest levels then share the last boundary).
#
# "Previous PRESENT level" is what makes an absent level safe rather than a hole: when
# level 0 has not been built (lazy) or was pruned (coarse), level 1 simply starts at 0 and
# covers the near band itself. Worst case the ground is one step coarser than ideal — it
# is never missing. Called again whenever a level's mesh appears or disappears.
func _apply_level_bands(manager: TerrainManager) -> void:
	var bands: PackedFloat32Array = manager.lod_band_ends()
	for i in _mesh_instances.size():
		var mi := _mesh_instances[i]
		if mi.mesh == null:
			mi.visible = false
			continue
		mi.visible = true
		mi.material_override = manager.chunk_material
		var prev := i - 1
		while prev >= 0 and _mesh_instances[prev].mesh == null:
			prev -= 1
		var begin := bands[mini(prev, bands.size() - 1)] if prev >= 0 else 0.0
		var end := bands[i] if i < bands.size() else 0.0  # last level: no far cutoff
		mi.visibility_range_begin = begin
		mi.visibility_range_end = end
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


# Build (or drop) the lazily-deferred finest level. No-op unless this chunk's level 0 was
# deferred by the precompute. Dropping the mesh releases its GPU buffers, so a chunk that
# leaves the detail ring gives the VRAM straight back; the band re-apply keeps the next
# level covering the near distance either way.
func set_finest_detail(manager: TerrainManager, data: Dictionary, on: bool) -> void:
	if not _lazy_finest or _mesh_instances.is_empty():
		return
	var mi := _mesh_instances[0]
	if on == (mi.mesh != null):
		return
	mi.mesh = TerrainLod.build_finest(manager, coord, data, manager.lod_skirt_m) if on else null
	_apply_level_bands(manager)


# Whether the finest level currently has a built mesh (tests / debug).
func has_finest_mesh() -> bool:
	return not _mesh_instances.is_empty() and _mesh_instances[0].mesh != null


# Whether this chunk's finest level is the DEFERRED kind — i.e. set_finest_detail can
# build it. False for coarse chunks (pruned for good) and for fully-prebaked ones.
func is_finest_deferred() -> bool:
	return _lazy_finest


# Grow/shrink the pool of per-level MeshInstance3D children to `count`.
func _ensure_mesh_instances(count: int) -> void:
	while _mesh_instances.size() < count:
		var mi := MeshInstance3D.new()
		mi.name = "LOD%d" % _mesh_instances.size()
		add_child(mi)
		_mesh_instances.append(mi)
	while _mesh_instances.size() > count:
		_mesh_instances.pop_back().queue_free()


# Enable/disable this chunk's collision. Far chunks are render-only (disabled), so
# their heightfield is not a live broadphase entry. Cheap toggle, no shape rebuild.
func set_collision_enabled(on: bool) -> void:
	_collision.disabled = not on

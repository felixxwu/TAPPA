class_name Crowd
extends RefCounted
# Centralised spectator-figure spawning. ONE place owns the shared crowd-figure
# mesh, the ground foot-offset, and how a static decorative crowd is built into a
# MultiMesh — so every crowd references the same model at the same size, the way
# Foliage does for trees/bushes. Before this, four call sites each loaded
# res://blender/spectator/spectator.glb, recomputed the foot offset
# (`-aabb.position.y`), and hand-built a MultiMesh at the mesh's native size; they
# stayed consistent only by accident (nothing scaled them), and any change to one
# would silently drift from the others.
#
# The three DECORATIVE crowds — the podium (podium.gd), the HQ clearing
# (hq_environment.gd), and the wreck onlookers (world.gd) — build a static crowd
# via multimesh_instance(). The live, car-reactive stage crowd (SpectatorGroup)
# owns its own dynamic MultiMesh (rewritten each frame) and uses the mesh for
# ragdolls too, so it isn't a static-crowd caller — but it still pulls the mesh +
# foot offset through mesh() / foot_offset() so the figure can't drift either.

const SPECTATOR_SCENE := preload("res://blender/spectator/spectator.glb")

static var _mesh_cache: Mesh


# The shared crowd-figure mesh, extracted once from the GLB and reused everywhere
# (a shared, immutable render resource). May be null if the GLB has no mesh.
static func mesh() -> Mesh:
	if _mesh_cache == null:
		_mesh_cache = MeshUtil.first_mesh(SPECTATOR_SCENE)
	return _mesh_cache


# How far to lift the figure so its feet sit on the ground: its feet are this far
# above its own origin (the negated mesh-AABB bottom). 0.0 for a null mesh.
static func foot_offset(m: Mesh) -> float:
	return -m.get_aabb().position.y if m != null else 0.0


# Build a static decorative crowd MultiMeshInstance3D named `node_name` from world
# XZ `positions` and per-figure `yaws`, seating each figure on the ground —
# `ground_at.call(x, z)` (or 0 when the Callable is invalid, e.g. flat ground)
# lifted by the shared foot offset. The scatter is stashed in a `positions` meta so
# headless tests can read it back (the MultiMesh transform buffer is a
# RenderingServer no-op stub under --headless). Returns null when the shared mesh is
# missing or no positions were supplied (nothing to render). The caller adds the
# returned node to the tree.
static func multimesh_instance(node_name: String, positions: PackedVector2Array,
		yaws: PackedFloat32Array, ground_at: Callable) -> MultiMeshInstance3D:
	var m := mesh()
	if m == null or positions.is_empty():
		return null
	var foot := foot_offset(m)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = m
	mm.instance_count = positions.size()
	for i in positions.size():
		var p := positions[i]
		var y: float = (ground_at.call(p.x, p.y) if ground_at.is_valid() else 0.0) + foot
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, yaws[i]), Vector3(p.x, y, p.y)))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.set_meta("positions", positions)
	return mmi

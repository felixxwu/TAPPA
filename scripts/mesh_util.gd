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


# Depth-first search for the first MeshInstance3D at or below `n`.
static func _find_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var found := _find_mesh_instance(c)
		if found != null:
			return found
	return null

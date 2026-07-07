class_name Foliage
extends RefCounted
# Centralised foliage spawning. ONE place decides how a tree is represented
# (opaque billboard cutout vs 3D low-poly mesh, per cfg.use_billboard_trees) and
# owns the shared mesh/material construction, so trees + bushes look identical
# everywhere they appear — the stage (world.gd), the HQ clearing
# (hq_environment.gd), and any future scene. Before this, world.gd honoured the
# billboard toggle but the HQ hardcoded the 3D mesh, so the two never matched;
# route every spawn through here and they can't drift again.
#
# The extracted meshes are cached statically (process-wide) — they are shared,
# immutable render resources, so building them once and reusing them across
# scenes is both correct and cheaper.

const TREE_MODEL := preload("res://models/low_poly_tree.glb")
const GROUNDCOVER_SCENE := preload("res://models/vegetation/groundcover_opaque.glb")
# Old billboard tree texture, used when cfg.use_billboard_trees is true (the perf
# A/B path — see features/trees.md).
const TREE_TEXTURE := preload("res://textures/tree.png")
# Silhouette build params for the opaque billboard tree cutout (rendering
# constants, not gameplay balance). Higher threshold = airier/more fragmented
# canopy; higher epsilon = fewer triangles. See TreeSilhouette / features/trees.md.
const TREE_SILHOUETTE_ALPHA := 0.3
const TREE_SILHOUETTE_EPSILON := 3.0
# Near-camera dither dissolve applied to the tree canopy so trees don't block the
# chase camera when it pushes inside them (see shaders/tree_canopy.gdshader).
const TREE_CANOPY_SHADER := preload("res://shaders/tree_canopy.gdshader")

static var _tree_mesh_cache: Mesh
static var _tree_silhouette_cache: Mesh


# Spawn a tree field as a child of `parent`: a BillboardField (opaque cutout) when
# cfg.use_billboard_trees, else a 3D TreeMeshField. Positions are lifted onto
# `terrain`; `with_collision` gates the per-instance hitboxes (stages want them,
# decorative clearings don't). Returns the created field node.
static func spawn_trees(parent: Node3D, positions: PackedVector2Array, terrain: TerrainManager,
		with_collision: bool, render_distance: float, render_fade: float) -> Node:
	var cfg: GameConfig = Config.data
	if cfg.use_billboard_trees:
		var billboards := BillboardField.new()
		parent.add_child(billboards)
		billboards.build(positions, terrain, cfg.tree_size_m, TREE_TEXTURE,
			cfg.tree_collision_radius_m, cfg.tree_collision_height_m, with_collision,
			render_distance, render_fade, 0.0, tree_silhouette_mesh(), true)
		return billboards
	var field := TreeMeshField.new()
	parent.add_child(field)
	field.build(positions, terrain, tree_mesh(),
		cfg.tree_size_m.y, cfg.tree_collision_radius_m, cfg.tree_collision_height_m,
		render_distance, render_fade, cfg.tree_bin_size_m, with_collision)
	return field


# Spawn the ground-cover bush field as a child of `parent`: always a 3D
# TreeMeshField (the low-poly bush mesh), never a billboard, with NO collision
# (bushes are pass-through — world.gd adds a separate BushField hit volume in the
# stage) and per-instance baked terrain light so they match the ground. Scaled to
# cfg.bush_height_m — the SAME target height the stage uses, so a bush is the same
# size wherever it grows. Returns the created field node.
static func spawn_bushes(parent: Node3D, positions: PackedVector2Array, terrain: TerrainManager,
		render_distance: float, render_fade: float) -> TreeMeshField:
	var cfg: GameConfig = Config.data
	var field := TreeMeshField.new()
	parent.add_child(field)
	field.build(positions, terrain, bush_mesh(),
		cfg.bush_height_m, 0.0, 0.0,
		render_distance, render_fade, cfg.tree_bin_size_m, false, true)
	return field


# The 3D tree ArrayMesh, extracted once from the GLB and shared by every mesh-path
# field. A single ArrayMesh carrying the trunk + canopy as separate surfaces: the
# GLB's baked StandardMaterials import with linear filtering (blurs the leaves), so
# force nearest, and swap the textured canopy surface to the tree_canopy
# ShaderMaterial (unshaded, double-sided, vertex-tinted, dither-dissolving near the
# camera so a tree the chase camera enters stops blocking the view).
static func tree_mesh() -> Mesh:
	if _tree_mesh_cache != null:
		return _tree_mesh_cache
	_tree_mesh_cache = MeshUtil.first_mesh(TREE_MODEL)
	if _tree_mesh_cache != null:
		var cfg: GameConfig = Config.data
		for s in _tree_mesh_cache.get_surface_count():
			var sm := _tree_mesh_cache.surface_get_material(s) as BaseMaterial3D
			if sm == null:
				continue
			sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
			if sm.albedo_texture != null:
				var canopy := ShaderMaterial.new()
				canopy.shader = TREE_CANOPY_SHADER
				canopy.set_shader_parameter("albedo", sm.albedo_texture)
				canopy.set_shader_parameter("near_fade_start", cfg.tree_near_fade_start_m)
				canopy.set_shader_parameter("near_fade_end", cfg.tree_near_fade_end_m)
				_tree_mesh_cache.surface_set_material(s, canopy)
	return _tree_mesh_cache


# The opaque billboard-tree silhouette mesh, traced once from TREE_TEXTURE's alpha
# and shared by every instance in the tree BillboardField.
static func tree_silhouette_mesh() -> Mesh:
	if _tree_silhouette_cache != null:
		return _tree_silhouette_cache
	_tree_silhouette_cache = TreeSilhouette.build(
		TREE_TEXTURE.get_image(), TREE_SILHOUETTE_ALPHA, TREE_SILHOUETTE_EPSILON)
	return _tree_silhouette_cache


# The ground-cover bush mesh: the low-poly GLB mesh, its imported (tone-matched)
# foliage texture kept but the surface rebuilt as the flat unshaded PS1 material
# with vertex_color_use_as_albedo — so the per-instance baked terrain light
# TreeMeshField writes into the MultiMesh COLOR multiplies the albedo (matching the
# ground tint everywhere). Duplicated so the cached scene resource is not mutated.
# NOT cached: the caller-agnostic material carries cfg.bush_tint, cheap to rebuild.
static func bush_mesh() -> Mesh:
	var cfg: GameConfig = Config.data
	var mesh: Mesh = MeshUtil.first_mesh(GROUNDCOVER_SCENE).duplicate()
	var base := mesh.surface_get_material(0) as StandardMaterial3D
	var albedo: Texture2D = base.albedo_texture if base != null else null
	var mat := PS1Material.unshaded(albedo, true)
	mat.albedo_color = cfg.bush_tint
	mesh.surface_set_material(0, mat)
	return mesh

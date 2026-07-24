class_name Foliage
extends RefCounted
# Centralised foliage spawning. ONE place owns how trees + bushes are represented
# and builds the shared mesh/material, so they look identical everywhere they
# appear — the stage (world.gd), the HQ clearing (hq_environment.gd), and any
# future scene. Trees are ALWAYS opaque billboard cutouts (BillboardField);
# bushes are ALWAYS 3D low-poly meshes (TreeMeshField). Routing every spawn
# through here keeps the scenes from drifting apart.
#
# The extracted meshes are cached statically (process-wide) — they are shared,
# immutable render resources, so building them once and reusing them across
# scenes is both correct and cheaper.

const GROUNDCOVER_SCENE := preload("res://models/vegetation/groundcover_opaque.glb")
# Default (home region) billboard tree texture. Region overrides pass their own
# texture to spawn_trees; see features/trees.md.
const TREE_TEXTURE := preload("res://textures/tree.png")
# Silhouette build params for the opaque billboard tree cutout (rendering
# constants, not gameplay balance). Higher threshold = airier/more fragmented
# canopy; higher epsilon = fewer triangles. See TreeSilhouette / features/trees.md.
const TREE_SILHOUETTE_ALPHA := 0.3
const TREE_SILHOUETTE_EPSILON := 3.0
# Near-camera dither dissolve applied to the tree canopy so trees don't block the
# chase camera when it pushes inside them (see shaders/tree_canopy.gdshader).
const TREE_CANOPY_SHADER := preload("res://shaders/tree_canopy.gdshader")

# Silhouette meshes are traced per source texture (the home tree.png plus any region
# billboard texture, e.g. tree-greece.webp) and cached by the texture's resource path,
# so each distinct cutout is built once and shared across every instance in its field.
static var _tree_silhouette_cache: Dictionary = {}


# Spawn a tree field as a child of `parent`: always a BillboardField (opaque
# cutout). Positions are lifted onto `terrain`; `with_collision` gates the
# per-instance hitboxes (stages want them, decorative clearings don't). Returns
# the created field node.
#
# `billboard_texture`, when non-null, selects that texture's star-shaped cutout in
# place of the home tree.png. `use_region_profile` picks the GameConfig sizing/jitter
# block independently of the texture: true → the region canopy profile
# (region_tree_billboard_size_m etc., e.g. Greece's tall olive), false → the home
# profile (tree_size_m etc.). The two are decoupled so a region's mix can carry the
# home tree.png at HOME sizing alongside its own tree at region sizing (see
# RegionLibrary.tree_mix / features/regions.md).
static func spawn_trees(parent: Node3D, positions: PackedVector2Array, terrain: TerrainManager,
		with_collision: bool, render_distance: float, render_fade: float,
		billboard_texture: Texture2D = null, use_region_profile: bool = false) -> Node:
	var cfg: GameConfig = Config.data
	var tex: Texture2D = billboard_texture if billboard_texture != null else TREE_TEXTURE
	var size := cfg.region_tree_billboard_size_m if use_region_profile else cfg.tree_size_m
	# Both billboard paths get per-instance random size jitter so a stand isn't
	# uniform, each with its own tunable floor: the region path (e.g. Greece)
	# uses region_tree_billboard_min_scale, the home path tree_billboard_min_scale.
	var size_jitter := cfg.region_tree_billboard_min_scale if use_region_profile else cfg.tree_billboard_min_scale
	# Sink the cards into the ground by a per-path tunable offset (negative) to hide
	# the seam where the trunk meets a sloped surface — same split as size_jitter.
	var ground_offset := cfg.region_tree_billboard_ground_offset_m if use_region_profile else cfg.tree_billboard_ground_offset_m
	# Per-instance width/height aspect jitter, same per-path split as size_jitter:
	# how drastically silhouettes vary in shape (taller-narrower vs shorter-wider).
	var aspect_jitter := cfg.region_tree_billboard_aspect_jitter if use_region_profile else cfg.tree_billboard_aspect_jitter
	var billboards := BillboardField.new()
	parent.add_child(billboards)
	billboards.build(positions, terrain, size, tex,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m, with_collision,
		render_distance, render_fade, ground_offset, tree_silhouette_mesh(tex), true,
		size_jitter, aspect_jitter)
	return billboards


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


# The opaque billboard-tree silhouette mesh, traced once from `tex`'s alpha (default
# the home TREE_TEXTURE) and shared by every instance in a tree BillboardField.
# Cached per texture path so each distinct cutout (home + any region tree) is built
# once. Region textures (tree-greece.webp) trace the same single camera-facing card.
static func tree_silhouette_mesh(tex: Texture2D = TREE_TEXTURE) -> Mesh:
	var key := tex.resource_path
	if _tree_silhouette_cache.has(key):
		return _tree_silhouette_cache[key]
	var mesh := TreeSilhouette.build(
		tex.get_image(), TREE_SILHOUETTE_ALPHA, TREE_SILHOUETTE_EPSILON)
	_tree_silhouette_cache[key] = mesh
	return mesh


# The ground-cover bush mesh: the low-poly GLB mesh, its imported (tone-matched)
# foliage texture kept but the surface rebuilt as the shared foliage near-fade
# ShaderMaterial (TREE_CANOPY_SHADER). It multiplies the texture by the per-instance
# MultiMesh COLOR (the baked terrain light TreeMeshField writes, matching the ground
# tint everywhere) AND by cfg.bush_tint, is double-sided (the shader is cull_disabled,
# so the single-sided cards don't vanish from behind), and — the point of the swap —
# dithers out near the camera just like the trees, so a bush right in front of the
# camera (chase cam brushing one, or a planted replay cam sitting among them) turns
# see-through instead of filling the frame. Duplicated so the cached scene resource is
# not mutated; NOT cached (the material carries cfg.bush_tint, cheap to rebuild).
static func bush_mesh() -> Mesh:
	var cfg: GameConfig = Config.data
	var mesh: Mesh = MeshUtil.first_mesh(GROUNDCOVER_SCENE).duplicate()
	var base := mesh.surface_get_material(0) as StandardMaterial3D
	var albedo: Texture2D = base.albedo_texture if base != null else null
	var mat := ShaderMaterial.new()
	mat.shader = TREE_CANOPY_SHADER
	mat.set_shader_parameter("albedo", albedo)
	mat.set_shader_parameter("tint", cfg.bush_tint)
	mat.set_shader_parameter("near_fade_start", cfg.tree_near_fade_start_m)
	mat.set_shader_parameter("near_fade_end", cfg.tree_near_fade_end_m)
	# Bushes scale uniformly to bush_height_m, so the shader can't read the world
	# height off the instance basis (unlike the normalized tree mesh) — pass it so the
	# near-fade clamps its reference point to the bush's vertical span.
	mat.set_shader_parameter("canopy_height", cfg.bush_height_m)
	mesh.surface_set_material(0, mat)
	return mesh

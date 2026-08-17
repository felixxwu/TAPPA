class_name Foliage
extends RefCounted
# Centralised foliage spawning. ONE place owns how trees + bushes are represented
# and builds the shared mesh/material, so they look identical everywhere they
# appear — the stage (world.gd), the HQ clearing (hq_environment.gd), and any
# future scene. Trees are ALWAYS opaque billboard cutouts (BillboardField);
# bushes and rocks are ALWAYS 3D low-poly meshes (TreeMeshField). Routing every
# spawn through here keeps the scenes from drifting apart.
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


# How far the VISIBLE ground sits above the terrain height the CPU reports, in metres.
#
# On a deep-snow stage the off-road ground is raised in the terrain's VERTEX SHADER
# (ps1_terrain_snow.gdshader: `VERTEX.y += snow_depth * (1 - road_weight)`) so the snow
# reads as deep. That lift is GPU-only — TerrainManager.height_at, which every scatter
# uses to seat its props, still returns the UNLIFTED height. So anything placed at
# height_at() on a snow stage is planted below the snow the player can see, by exactly
# the lift: on the Alps that buried the conifers' trunks up to their authored sink plus
# another snow_visual_depth_m on top, and read as the trees having their bases chopped off.
#
# Added to every prop's ground offset so props sit on the surface that is DRAWN. Zero on
# every non-snow stage, so it is an exact no-op everywhere else.
#
# Only the off-road lift is modelled: the shader leaves the road itself unraised, and no
# scatter places props on the carriageway (they are all road-rejected), so the road case
# cannot arise.
static func visual_ground_lift() -> float:
	return maxf(Config.data.deep_snow_depth_m, 0.0)


# --- Rocks -------------------------------------------------------------------
#
# Roadside boulders: low-poly MESHES, not billboards. A tree card is tall, thin and
# seen at distance, so a camera-facing quad never gives itself away; a boulder is
# squat and you drive within a metre of it, where a flat card reads as cardboard.
# So rocks reuse the bush path (TreeMeshField) rather than the tree one — with
# collision turned ON, which the bushes deliberately do without.
#
# Source: Kenney "Nature Kit" (kenney.nl), CC0. See models/rocks/README.md.
const ROCK_SCENES := [
	preload("res://models/rocks/rock_largeA.glb"),
	preload("res://models/rocks/rock_largeD.glb"),
	preload("res://models/rocks/rock_smallA.glb"),
]
# Per-species height as a MULTIPLE of cfg.rock_height_m, the single knob a designer
# moves to resize the whole scatter.
#
# It has to be authored per species because TreeMeshField scales UNIFORMLY from the
# target height (uniform_scale_for = height / aabb.size.y), and these three have very
# different aspect ratios: largeA is a flat slab (0.79 x 0.26 x 1.02 in source units)
# while largeD is a rounder lump (1.07 x 0.57 x 1.03). Scaling both to one height would
# blow the slab up to ~3 m across to reach a boulder's height. The multiples below are
# picked so all three land at a sane FOOTPRINT (~1.5-1.9 m for the large pair, ~0.7 m
# for the small one) rather than a matching height.
const ROCK_HEIGHT_SCALES := [0.55, 1.25, 0.48]
# Rocks are static solid geometry with real normals, so they take the live per-vertex
# fake-sun shader (unshaded + NdotL against cfg.sun_direction) rather than the terrain's
# CPU-baked vertex light or the billboards' camera-facing approximation. Shared with the
# car, barriers and the finish arch; fed by cfg.apply_car_light so rocks dim with the
# weather and pick up the headlight cone at night.
const ROCK_SHADER := preload("res://shaders/ps1_models_lit.gdshader")
# Kenney authors the cap material as "grass" and the body as "dirt"/"_defaultMat".
# Matched by NAME rather than by surface index because the order differs per model
# (rock_smallA lists grass first, the other two list dirt first).
const ROCK_CAP_MATERIAL := "grass"

# Merged rock meshes, cached process-wide by species index — shared immutable render
# resources, same rationale as the silhouette cache above.
static var _rock_mesh_cache: Dictionary = {}


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
		billboard_texture: Texture2D = null, use_region_profile: bool = false,
		size_scale: Vector2 = Vector2.ONE) -> Node:
	var cfg: GameConfig = Config.data
	var tex: Texture2D = billboard_texture if billboard_texture != null else TREE_TEXTURE
	var size := cfg.region_tree_billboard_size_m if use_region_profile else cfg.tree_size_m
	# Per-species BASELINE PROPORTIONS, on top of the profile's size (features/trees.md).
	#
	# The card the two profiles describe is SQUARE (7.5 x 7.5), so every billboard is
	# stretched to a 1:1 ratio no matter what shape its texture actually is. A broad
	# deciduous tree survives that; a conifer does not — the Alps' dense spruce is a
	# 125x256 cutout (natural 0.49) and was being drawn at twice its real width.
	#
	# So a species may state its own width/height multiplier. Vector2.ONE (the default,
	# and what every home/Greece species uses) leaves the profile size untouched, so this
	# is an exact no-op everywhere it is not authored. It multiplies the BASE size only —
	# the per-instance size and aspect jitter still apply on top, so a stand still varies.
	size = Vector2(size.x * size_scale.x, size.y * size_scale.y)
	# Both billboard paths get per-instance random size jitter so a stand isn't
	# uniform, each with its own tunable floor: the region path (e.g. Greece)
	# uses region_tree_billboard_min_scale, the home path tree_billboard_min_scale.
	var size_jitter := cfg.region_tree_billboard_min_scale if use_region_profile else cfg.tree_billboard_min_scale
	# Sink the cards into the ground by a per-path tunable offset (negative) to hide
	# the seam where the trunk meets a sloped surface — same split as size_jitter.
	# ...lifted onto the DRAWN ground, which on a deep-snow stage sits above the terrain
	# height this scatter seats itself from (see visual_ground_lift).
	var ground_offset := visual_ground_lift() + (
		cfg.region_tree_billboard_ground_offset_m if use_region_profile
		else cfg.tree_billboard_ground_offset_m)
	# Per-instance width/height aspect jitter, same per-path split as size_jitter:
	# how drastically silhouettes vary in shape (taller-narrower vs shorter-wider).
	var aspect_jitter := cfg.region_tree_billboard_aspect_jitter if use_region_profile else cfg.tree_billboard_aspect_jitter
	var billboards := BillboardField.new()
	parent.add_child(billboards)
	billboards.build(positions, terrain, size, tex,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m, with_collision,
		render_distance, render_fade, ground_offset, tree_silhouette_mesh(tex),
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
		render_distance, render_fade, cfg.tree_bin_size_m, false, true,
		visual_ground_lift())
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


# The world-space height one rock species is scaled to: the shared cfg.rock_height_m
# times that species' authored multiple (see ROCK_HEIGHT_SCALES).
static func rock_height(index: int) -> float:
	var cfg: GameConfig = Config.data
	return cfg.rock_height_m * float(ROCK_HEIGHT_SCALES[index])


# One rock species' render mesh, MERGED to a single surface.
#
# Kenney's rocks arrive as 2-3 primitives (a "dirt" body, a "grass" cap, sometimes a
# default) that carry their colour as a material baseColorFactor — no texture and no
# vertex-colour array at all. Kept as-authored that would be 2-3 draw calls per
# MultiMesh bin for a 16-136 triangle rock, and it would ship Kenney's palette (an
# orange body under a turquoise cap) which is nothing like this game's ground.
#
# So every primitive is welded into ONE surface and its material colour is written into
# VERTEX COLOURS instead, remapped to the two authored stone colours in GameConfig.
# That buys: one surface, one material, one draw call per bin, no texture sampled at
# all, and the body/cap split preserved as data the shader multiplies in (ps1_models_lit
# already does `* COLOR.rgb`). MultiMesh instance colours are left OFF for rocks, so
# COLOR is the vertex colour and nothing competes for it.
#
# Cached per species — the colours come from config, which does not change at runtime.
static func rock_mesh(index: int) -> Mesh:
	if _rock_mesh_cache.has(index):
		return _rock_mesh_cache[index]
	var cfg: GameConfig = Config.data
	var src: Mesh = MeshUtil.first_mesh(ROCK_SCENES[index])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in range(src.get_surface_count()):
		var mat_name := ""
		var src_mat := src.surface_get_material(s)
		if src_mat != null:
			mat_name = src_mat.resource_name
		var colour: Color = cfg.rock_cap_color if mat_name == ROCK_CAP_MATERIAL \
			else cfg.rock_body_color
		var arrays := src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		# An unindexed surface is legal glTF; walk the vertices straight through.
		if indices.is_empty():
			indices = PackedInt32Array(range(verts.size()))
		for i in indices:
			st.set_color(colour)
			if i < normals.size():
				st.set_normal(normals[i])
			st.add_vertex(verts[i])
	# Weld the duplicated corners the de-indexing above created back down.
	st.index()
	var mesh: ArrayMesh = st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = ROCK_SHADER
	cfg.apply_car_light(mat)
	mesh.surface_set_material(0, mat)
	_rock_mesh_cache[index] = mesh
	return mesh


# Spawn one rock species as a child of `parent` — a TreeMeshField (binned MultiMeshes,
# per-instance yaw, distance fade) WITH collision, so the car can hit them.
#
# `bake_terrain_light` is deliberately false: rocks are lit live per-vertex by the
# shader off their real normals, unlike the bushes, which have no useful normals of
# their own and instead take the ground's baked light per instance.
#
# The collision box is derived from the mesh rather than authored: a species' scaled
# horizontal half-extent times cfg.rock_collision_radius_frac, so resizing rocks resizes
# their hitbox and the two can never drift apart. The box is full rock height, so a
# low slab does not present a boulder-height wall.
static func spawn_rocks(parent: Node3D, positions: PackedVector2Array,
		terrain: TerrainManager, index: int, with_collision: bool,
		render_distance: float, render_fade: float) -> TreeMeshField:
	var cfg: GameConfig = Config.data
	var mesh := rock_mesh(index)
	var height := rock_height(index)
	var field := TreeMeshField.new()
	parent.add_child(field)
	# The sink goes through build's `ground_offset` so the meshes, the recorded
	# instance_positions and the collision boxes are all placed at the same buried Y.
	field.build(positions, terrain, mesh, height,
		TreeMeshField.xz_radius(mesh, height) * cfg.rock_collision_radius_frac, height,
		render_distance, render_fade, cfg.tree_bin_size_m, with_collision, false,
		visual_ground_lift() - height * cfg.rock_sink_frac)
	return field

class_name LakeField
extends Node3D
# Renders lakes as ONE large flat water plane at the water level (features/lakes.md).
# Wherever terrain sits below the level the plane shows through; higher terrain
# occludes it via the depth test — so there's no per-lake geometry and no
# flood-fill. The "is this point in water?" query is a direct terrain-height check
# (wired by world.gd), and the 2D previews sample below-water cells via
# submerged_cells(); neither needs this node.

const WATER_SHADER := preload("res://shaders/water.gdshader")
# Pre-baked seamless (tileable) Perlin tile scrolled as the water surface detail.
# It used to be generated at load by a NoiseTexture2D — whose bake only goes to a
# worker thread when threads exist. The web export ships
# `variant/thread_support = false`, so there was no worker and the bake (4x the
# samples, because `seamless` cross-blends a larger buffer) ran on the main loop:
# ~1.1 s per stage load on web vs ~14 ms native. Committing the tile removes it
# entirely. Regenerate by baking a NoiseTexture2D with the same settings
# (FastNoiseLite, Perlin, FBM, 3 octaves, frequency 0.06, seed 0, 128x128,
# seamless) and saving its image over the asset.
const WATER_TEX := preload("res://textures/water_noise.png")
# Plane edge length (m). Centred on the origin it covers ±5 km — far larger than
# any stage — so it never needs to follow the car.
const SPAN := 10000.0


# `frozen` (cfg.frozen_water_grip > 0.0, i.e. the Alps) turns the lake to ICE: pale
# cold colours, a still surface instead of scrolling ripples, and — the point — a SOLID
# collider the car drives out onto. See features/snow-region.md.
func build(water_level: float, cfg: GameConfig) -> void:
	var frozen := cfg.frozen_water_grip > 0.0
	var mat := ShaderMaterial.new()
	mat.shader = WATER_SHADER
	mat.set_shader_parameter("water_color", cfg.ice_color if frozen else cfg.water_color)
	mat.set_shader_parameter("shore_color",
		cfg.ice_shore_color if frozen else cfg.water_shore_color)
	# Ice does not flow. Zeroing the scroll is what separates it from water at a glance,
	# and it needs no second shader — the existing one simply stops animating.
	mat.set_shader_parameter("scroll_speed", 0.0 if frozen else cfg.water_ripple_speed)
	mat.set_shader_parameter("sparkle_strength", cfg.water_sparkle_strength)
	mat.set_shader_parameter("water_tex", WATER_TEX)
	var plane := PlaneMesh.new()
	plane.size = Vector2(SPAN, SPAN)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.position = Vector3(0.0, water_level, 0.0)
	add_child(mi)
	if frozen:
		_add_ice_collider(water_level)


# The ice surface the car drives on.
#
# A WorldBoundaryShape3D — an INFINITE half-space plane — rather than a mesh matching
# the lake outline, and that is the whole trick. There is no lake geometry in this game
# (see the class comment: one plane, terrain occludes it by depth test), so there is no
# outline to match. An infinite plane at the waterline gives the right answer anyway,
# because the TERRAIN collider is still there: wherever the ground is above the
# waterline the car rests on the ground as usual, and wherever it dips below — which is
# exactly where a lake is drawn — the car rests on the ice instead. The two colliders
# together reproduce the lake's shape for free.
#
# It is also the cheapest collider the physics engine has: no vertices, no broadphase
# volume, one plane test. A 10 km trimesh matching the visual plane would cost far more
# and be no more correct.
#
# Side effect, accepted and arguably desirable: nothing can fall below the waterline
# anywhere on a frozen stage, including a car that goes off a cliff into a dry basin
# below sea level. On these stages that reads as landing on ice, not as a bug.
func _add_ice_collider(water_level: float) -> void:
	var body := StaticBody3D.new()
	body.name = "IceSurface"
	var shape := CollisionShape3D.new()
	shape.shape = WorldBoundaryShape3D.new()
	body.add_child(shape)
	body.position = Vector3(0.0, water_level, 0.0)
	add_child(body)


# Below-water cell CENTRES over `bounds` (world XZ), for the 2D loading/seed-lab
# previews. `sampler` is a pure terrain-height Callable(x, z) -> float.
static func submerged_cells(sampler: Callable, water_level: float,
		bounds: Rect2, step: float) -> PackedVector2Array:
	var cells := PackedVector2Array()
	if not sampler.is_valid() or step <= 0.0:
		return cells
	var x := bounds.position.x
	while x <= bounds.position.x + bounds.size.x:
		var z := bounds.position.y
		while z <= bounds.position.y + bounds.size.y:
			if float(sampler.call(x, z)) < water_level:
				cells.append(Vector2(x, z))
			z += step
		x += step
	return cells


# Below-water preview cells over `bounds` plus the step used, for the loading
# screen (world.gd) and the dev seed lab (settings_menu). Caps the scan at ~grid^2
# samples so big stages don't stall. Returns [cells: PackedVector2Array, step: float].
static func preview_cells(params: TrackGenParams, bounds: Rect2) -> Array:
	if not params.water_enabled:
		return [PackedVector2Array(), TerrainManager.CELL_M]
	return preview_cells_for(params.water_sampler, params.water_level, bounds)


# preview_cells against an ARBITRARY height sampler. The params-based entry point
# above samples pure noise, which is all that exists before the road is baked — but
# the terrain the player actually gets is the BAKED one (road flatten + cliff
# offsets, TerrainManager.height_at), and cliff drops are signed, so a stage with
# real cliffiness ends up with substantially more ground under water than the noise
# predicts. world.gd repaints the preview through this once the bake has run, so the
# loading screen ends up showing the water that's really there. Same grid/step rule
# as preview_cells, so the repaint lands on the identical lattice.
static func preview_cells_for(sampler: Callable, water_level: float, bounds: Rect2) -> Array:
	if not sampler.is_valid():
		return [PackedVector2Array(), TerrainManager.CELL_M]
	var grid := 220.0
	var step: float = maxf(TerrainManager.CELL_M, maxf(bounds.size.x, bounds.size.y) / grid)
	return [submerged_cells(sampler, water_level, bounds, step), step]

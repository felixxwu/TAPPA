class_name LakeField
extends Node3D
# Docs: features/lakes.md — update in the same change as this file.
# Tests: tests/headless/test_lake_field.gd, tests/headless/test_lakes_integration.gd — extend in the same change.
# Renders lakes as ONE large flat water plane at the water level (features/lakes.md).
# Wherever terrain sits below the level the plane shows through; higher terrain
# occludes it via the depth test — so there's no per-lake geometry and no
# flood-fill. The "is this point in water?" query is a direct terrain-height check
# (wired by world.gd); submerged_cells() samples below-water cells without this node.

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
	# Dimmed by the weather's sun multiplier like every other fake-lit surface. The
	# water shader is `unshaded` and takes an authored colour straight to ALBEDO, so
	# without this a lake renders full daylight blue on a night stage and glows
	# against the dark terrain around it — the brightest thing on screen, and the
	# opposite of what water does at night.
	mat.set_shader_parameter("water_color",
		cfg.weather_lit(cfg.ice_color if frozen else cfg.water_color))
	mat.set_shader_parameter("shore_color",
		cfg.weather_lit(cfg.ice_shore_color if frozen else cfg.water_shore_color))
	# Ice does not flow. Zeroing the scroll is what separates it from water at a glance,
	# and it needs no second shader — the existing one simply stops animating.
	mat.set_shader_parameter("scroll_speed", 0.0 if frozen else cfg.water_ripple_speed)
	# The sparkle is a sun glint, so it scales with the sun too — a full-strength
	# sparkle band on an otherwise dark lake reads as the surface being lit from
	# somewhere that isn't there.
	mat.set_shader_parameter("sparkle_strength",
		cfg.water_sparkle_strength * cfg.weather_sun_mult)
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

class_name LakeField
extends Node3D
# Renders lakes as ONE large flat water plane at the water level (features/lakes.md).
# Wherever terrain sits below the level the plane shows through; higher terrain
# occludes it via the depth test — so there's no per-lake geometry and no
# flood-fill. The "is this point in water?" query is a direct terrain-height check
# (wired by world.gd), and the 2D previews sample below-water cells via
# submerged_cells(); neither needs this node.

const WATER_SHADER := "res://shaders/water.gdshader"
# Plane edge length (m). Centred on the origin it covers ±5 km — far larger than
# any stage — so it never needs to follow the car.
const SPAN := 10000.0


func build(water_level: float, cfg: GameConfig) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load(WATER_SHADER)
	mat.set_shader_parameter("water_color", cfg.water_color)
	mat.set_shader_parameter("shore_color", cfg.water_shore_color)
	mat.set_shader_parameter("scroll_speed", cfg.water_ripple_speed)
	mat.set_shader_parameter("sparkle_strength", cfg.water_sparkle_strength)
	mat.set_shader_parameter("water_tex", _make_water_texture())
	var plane := PlaneMesh.new()
	plane.size = Vector2(SPAN, SPAN)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.position = Vector3(0.0, water_level, 0.0)
	add_child(mi)


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
	if not params.water_enabled or not params.water_sampler.is_valid():
		return [PackedVector2Array(), TerrainManager.CELL_M]
	var grid := 220.0
	var step: float = maxf(TerrainManager.CELL_M, maxf(bounds.size.x, bounds.size.y) / grid)
	return [submerged_cells(params.water_sampler, params.water_level, bounds, step), step]


# A seamless (tileable) Perlin texture used as the scrolling water surface detail.
# Generated so the water repeats cleanly across the whole plane and needs no asset
# on disk. NoiseTexture2D bakes on a worker thread; the material picks it up when ready.
static func _make_water_texture() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	noise.frequency = 0.06
	var tex := NoiseTexture2D.new()
	tex.width = 128
	tex.height = 128
	tex.seamless = true
	tex.noise = noise
	return tex

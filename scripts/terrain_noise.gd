class_name TerrainNoise
extends RefCounted
# Pure, headless Perlin height sampler. Mirrors TerrainManager._make_noise /
# _build_noises / _sample_height EXACTLY (per-layer seed offset seed+i,
# frequency = 1/wavelength) so it reproduces the terrain the player sees, without
# a live TerrainManager node. Used for the water constraint during track
# generation and target-time derivation (which run with no world).

# layers: Array of Vector2(wavelength_m, amplitude_m) (see GameConfig.terrain_layers()).
static func _build(seed_value: int, layers: Array) -> Array:
	var noises: Array[FastNoiseLite] = []
	var amplitudes: PackedFloat32Array = PackedFloat32Array()
	for i in layers.size():
		var wl: float = layers[i].x
		if wl <= 0.0:
			continue
		var noise := FastNoiseLite.new()
		noise.noise_type = FastNoiseLite.TYPE_PERLIN
		noise.fractal_type = FastNoiseLite.FRACTAL_NONE
		noise.seed = seed_value + i
		noise.frequency = 1.0 / wl
		noises.append(noise)
		amplitudes.append(layers[i].y)
	return [noises, amplitudes]


static func make_sampler(seed_value: int, layers: Array) -> Callable:
	var pair := _build(seed_value, layers)
	var noises: Array = pair[0]
	var amplitudes: PackedFloat32Array = pair[1]
	return func(x: float, z: float) -> float:
		var h := 0.0
		for i in noises.size():
			h += noises[i].get_noise_2d(x, z) * amplitudes[i]
		return h


static func height_at(seed_value: int, layers: Array, x: float, z: float) -> float:
	return make_sampler(seed_value, layers).call(x, z)

extends GutTest
# TerrainNoise must reproduce TerrainManager's pure noise height exactly, headless,
# from (seed, layers) alone — so target-time derivation can sample water without a
# live terrain node.

const TerrainNoise = preload("res://scripts/terrain_noise.gd")

func test_matches_terrain_manager_noise() -> void:
	var layers := [Vector2(60.0, 1.5), Vector2(15.0, 0.4), Vector2(3.0, 0.1)]
	var tm := TerrainManager.new()
	tm.noise_seed = 4242
	var tm_layers: Array[TerrainLayer] = []
	for v in layers:
		var l := TerrainLayer.new()
		l.wavelength_m = v.x
		l.amplitude_m = v.y
		tm_layers.append(l)
	tm.layers = tm_layers
	var sampler := TerrainNoise.make_sampler(4242, layers)
	for p in [Vector2(0, 0), Vector2(12.5, -30.0), Vector2(-7.0, 88.0)]:
		assert_almost_eq(sampler.call(p.x, p.y), tm._noise_height_at(p.x, p.y), 0.0001,
			"headless sampler matches TerrainManager noise at %s" % p)
	tm.free()

func test_deterministic() -> void:
	var layers := [Vector2(60.0, 1.5)]
	var a := TerrainNoise.make_sampler(9, layers)
	var b := TerrainNoise.make_sampler(9, layers)
	assert_almost_eq(a.call(3.0, 4.0), b.call(3.0, 4.0), 0.0001, "same seed -> same height")

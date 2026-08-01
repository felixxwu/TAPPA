extends GutTest
# The loading screen's water preview must agree with the water the player drives into.
#
# This is the test gap that let three separate waterline bugs ship. Every preview
# call in world.gd is guarded by `loading != null and not _headless`, so the painting
# itself can never run headlessly — but the thing that actually broke was never the
# painting, it was the SAMPLER CHOICE. That is testable, and it's what this file pins:
#
#   - the real lake (world.gd::_build_lakes) floods where the BAKED terrain is below
#     the waterline (TerrainManager.height_at / baked_height_at),
#   - so a preview sampled from pure noise (TerrainNoise, via params.water_sampler)
#     disagrees with it wherever the bake moved the ground — which cliff offsets do,
#     signed and metres deep.
#
# See features/lakes.md -> "Three water passes".

const ManagerScript := preload("res://scripts/terrain_manager.gd")


func _layer(wavelength: float, amplitude: float) -> TerrainLayer:
	var layer := TerrainLayer.new()
	layer.wavelength_m = wavelength
	layer.amplitude_m = amplitude
	return layer


# A bare manager with cliffs on. Not added to the tree: bake_track needs no scene
# when should_yield is false, which is the whole reason a preview bake is cheap.
func _manager() -> Node3D:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	m.noise_seed = 11
	m.layers = [_layer(60.0, 1.5)] as Array[TerrainLayer]
	m.cliff_enabled = true
	m.cliff_wavelength_m = 40.0
	m.cliff_gain = 5.0
	m.cliff_max_height_m = 10.0
	m.cliff_run_m = 10.0
	m.cliff_fade_m = 10.0
	m.cliff_open_radius_m = 0.0
	m.cliff_amount = 1.0
	m.cliff_seed = 11
	return m


func _straight_centerline() -> Curve2D:
	var c := Curve2D.new()
	for i in 30:
		c.add_point(Vector2(float(i) * 10.0, 0.0))
	return c


func test_baked_sampler_disagrees_with_pure_noise_once_cliffs_are_baked() -> void:
	# The core of all three bugs: after the bake, the noise sampler is no longer a
	# description of the ground. If this ever stops holding, previewing from noise
	# would be harmless — and this test should be deleted rather than weakened.
	var m := _manager()
	autofree(m)
	await m.bake_track(_straight_centerline(), 6.0, 4.0)
	assert_gt(m.cliff_offsets.size(), 0, "the bake produced cliff offsets to disagree about")
	var differed := 0
	for gv in m.cliff_offsets:
		var x := float(gv.x) * ManagerScript.CELL_M
		var z := float(gv.y) * ManagerScript.CELL_M
		if absf(m.baked_height_at(x, z) - m._noise_height_at(x, z)) > 0.001:
			differed += 1
	assert_gt(differed, 0,
		"baked ground differs from pure noise wherever cliffs were carved — so a noise-sampled preview cannot match the driven world")


func test_preview_and_real_lake_flood_the_same_ground() -> void:
	# The agreement that matters: LakeField.preview_cells_for (what the loading screen
	# and Seed Lab paint) and the real lake's submersion query (world.gd::_build_lakes /
	# _drop_submerged, `height_at(x, z) < water_level`) must classify a point the same
	# way when handed the same sampler. Same sampler in, same verdict out.
	var m := _manager()
	autofree(m)
	await m.bake_track(_straight_centerline(), 6.0, 4.0)
	var bounds := Rect2(0.0, -60.0, 300.0, 120.0)
	# A level in the middle of the baked relief, so both sets are non-trivially mixed.
	var level: float = m.baked_height_at(150.0, 0.0)
	var out: Array = LakeField.preview_cells_for(m.baked_height_at, level, bounds)
	var cells: PackedVector2Array = out[0]
	assert_gt(cells.size(), 0, "the preview found submerged ground to compare")
	for c in cells:
		assert_lt(m.baked_height_at(c.x, c.y), level,
			"every cell the preview paints as water is ground the real submersion query also calls water")


func test_bake_args_are_derived_in_one_place() -> void:
	# world.gd and TerrainManager.baked_preview (the Seed Lab's bake) both go through
	# bake_args, so the two bakers can't drift into carving different roads for the
	# same config — which would put the lab's water back out of step with the game's.
	# Shape/derivation only: no authored value is pinned.
	var cfg: GameConfig = Config.data
	var a := ManagerScript.bake_args(cfg)
	assert_eq(a.size(), 5, "width, transition, tarmac fraction, tarmac-first, feather")
	assert_eq(a[0], cfg.track_width, "width comes straight from the config")
	assert_eq(a[1], cfg.track_transition_cells * ManagerScript.CELL_M,
		"the transition band is cells converted to metres, not an independent value")
	assert_typeof(a[3], TYPE_BOOL, "the surface orientation is a bool")
	assert_eq(a[3], TrackSurface.orientation_tarmac_first(cfg.track_seed),
		"and it is seeded off track_seed, so both bakers open on the same surface")

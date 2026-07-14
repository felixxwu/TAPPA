extends GutTest
# generate() takes a TrackGenParams object. With water disabled the layout is the
# old deterministic one; with a sampler + level, no placed footprint cell sits
# below water_level + shore_clearance.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")

func _params(water: bool, sampler: Callable, level: float) -> TrackGenParams:
	var p := TrackGenParams.new()
	p.seed = 7
	p.turn_count = 6
	p.width = 6.0
	p.origin = Vector2.ZERO
	p.heading = Vector2(0.0, -1.0)
	p.water_enabled = water
	p.water_level = level
	p.shore_clearance = 1.0
	p.water_sampler = sampler
	return p

func test_water_disabled_is_deterministic() -> void:
	var a := await TrackGenerator.generate(_params(false, Callable(), 0.0))
	var b := await TrackGenerator.generate(_params(false, Callable(), 0.0))
	assert_eq(a["cells"].size(), b["cells"].size(), "same seed -> same footprint")
	assert_eq(a["complete"], b["complete"])

func test_road_avoids_water() -> void:
	# Synthetic water: everything with world z > 5 is underwater. The road must
	# stay LARGELY out of it (tolerant reject allows skimming a shoreline, not
	# crossing a lake), so only a small fraction of road cells may be wet.
	var sampler := func(x: float, z: float) -> float:
		return -10.0 if z > 5.0 else 10.0
	var res := await TrackGenerator.generate(_params(true, sampler, 0.0))
	var total: int = res["cells"].size()
	var wet := 0
	for cell in res["cells"]:
		var centre := Vector2((cell.x + 0.5) * TrackGenerator.CELL_M, (cell.y + 0.5) * TrackGenerator.CELL_M)
		if sampler.call(centre.x, centre.y) < 0.0:
			wet += 1
	assert_gt(total, 0, "the track generated")
	assert_lt(float(wet) / float(total), 0.1, "road stays largely out of the water (only shoreline skims)")

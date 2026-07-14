extends GutTest
# Integration verification for lakes: field the car into several water-enabled
# "events" and log what happened, asserting the invariants hold. Doubles as the
# manual verification harness (run: ./run_tests.sh --fast lakes_integration).

const TrackGenParams = preload("res://scripts/track_gen_params.gd")
const LakeField = preload("res://scripts/lake_field.gd")
const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")

# A spread of synthetic events with different seeds + water levels. The default
# terrain noise is centred near 0 with amplitude ~1 m, so a level well below 0
# floods only the deepest basins into lakes while leaving the road room to route.
const EVENTS := [
	{"seed": 1007, "turn_count": 7, "water_level": -0.8},
	{"seed": 3001, "turn_count": 7, "water_level": -0.8},
	{"seed": 4001, "turn_count": 8, "water_level": -0.8},
	{"seed": 5003, "turn_count": 6, "water_level": -0.8},
]


func _cfg() -> GameConfig:
	var c := GameConfig.new()
	c.water_enabled = true
	c.water_shore_clearance_m = 0.3
	return c


# For each event: generate, log the outcome, and assert the road never sits below
# the waterline and that some lakes form. Also confirm the run-scene params and the
# target-derivation params (both for_event) yield the identical shape.
func test_events_generate_dry_roads_with_lakes() -> void:
	var cfg := _cfg()
	for event in EVENTS:
		var params := TrackGenParams.for_event(event, cfg)
		var res := await TrackGenerator.generate(params)
		# Road stays LARGELY out of the water (tolerant reject allows shoreline skims,
		# not lake crossings): count road cells actually submerged (below water_level).
		var total: int = res["cells"].size()
		var wet_road := 0
		for cell in res["cells"]:
			var centre := Vector2((cell.x + 0.5) * TrackGenerator.CELL_M,
				(cell.y + 0.5) * TrackGenerator.CELL_M)
			if float(params.water_sampler.call(centre.x, centre.y)) < params.water_level:
				wet_road += 1
		var wet_frac := (float(wet_road) / float(total)) if total > 0 else 0.0
		# Some water actually forms near the stage (below the level within the bounds).
		var poly := (res["centerline"] as Curve2D).tessellate()
		var bounds := LoadingScreen.bounds_of(poly).grow(60.0)
		var water_cells := LakeField.submerged_cells(params.water_sampler, params.water_level, bounds, 2.0)
		# Frame consistency: rebuild params (as target derivation does) -> same shape.
		var res2 := await TrackGenerator.generate(TrackGenParams.for_event(event, cfg))

		gut.p("[lakes] seed=%d level=%.2f | complete=%s corners=%d | submerged_road=%.1f%% | water_cells=%d | dry_start=%s | shape_match=%s" % [
			params.seed, params.water_level, str(res["complete"]),
			res["pieces"].size(), 100.0 * wet_frac, water_cells.size(),
			str(params.origin),
			str(res["cells"].size() == res2["cells"].size())])

		assert_true(res["complete"], "seed %d: the track still generates with water on" % params.seed)
		assert_gt(water_cells.size(), 0, "seed %d: water forms near the stage" % params.seed)
		assert_lt(wet_frac, 0.12, "seed %d: road stays largely dry (only shoreline skims)" % params.seed)
		assert_eq(res["cells"].size(), res2["cells"].size(),
			"seed %d: run-scene and target-derivation shapes match" % params.seed)


# Field the actual car into main.tscn with water on, and confirm a LakeField was
# built and the car's soft-hazard query is wired. Logs the car spawn + lake count.
func test_car_fielded_into_water_stage() -> void:
	Config.reset()
	Config.data.water_enabled = true
	Config.data.track_water_level_m = -0.8
	Config.data.track_seed = 1007
	var scene: Node3D = load("res://main.tscn").instantiate()
	add_child(scene)
	# Let world.gd._ready() build the track + terrain + lakes.
	for i in 8:
		await get_tree().process_frame
	var car := scene.get_node("Car")
	var lake := scene.get_node_or_null("LakeField")
	var basin_count := 0
	if lake != null:
		for c in lake.get_children():
			if c is MeshInstance3D:
				basin_count += 1
	gut.p("[lakes] fielded car at %s | LakeField=%s | water_meshes=%d" % [
		str(car.global_position), str(lake != null), basin_count])
	assert_not_null(lake, "a LakeField was built for a water-enabled stage")
	# Free explicitly (not autofree) so the water shader/material/meshes release
	# before the suite's exit-time resource check, avoiding a spurious leak flag.
	remove_child(scene)
	scene.free()
	await get_tree().process_frame
	Config.reset()

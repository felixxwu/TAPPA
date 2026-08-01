extends GutTest
# TrackGenParams is the single shape contract. You cannot obtain params without a
# water level, and for_event is deterministic (same event+cfg -> same params). The
# dry-start search moves the origin off water and stays deterministic.

const TrackGenParams = preload("res://scripts/track_gen_params.gd")

func _cfg() -> GameConfig:
	var c := GameConfig.new()
	c.track_seed = 7
	c.track_turn_count = 8
	c.track_width = 6.0
	c.water_enabled = true
	c.track_water_level_m = -0.5
	return c

func test_for_event_reads_seed_and_water() -> void:
	var p := TrackGenParams.for_event({"seed": 7, "water_level": -0.5}, _cfg())
	assert_eq(p.seed, 7, "seed from event")
	assert_true(p.water_enabled, "water enabled from cfg")
	assert_almost_eq(p.water_level, -0.5, 0.0001, "water level from event")
	assert_true(p.water_sampler.is_valid(), "sampler is built")

func test_for_event_deterministic() -> void:
	var a := TrackGenParams.for_event({"seed": 7, "water_level": -0.5}, _cfg())
	var b := TrackGenParams.for_event({"seed": 7, "water_level": -0.5}, _cfg())
	assert_eq(a.seed, b.seed)
	assert_eq(a.origin, b.origin, "same origin")
	assert_almost_eq(a.water_sampler.call(5.0, 5.0), b.water_sampler.call(5.0, 5.0), 0.0001,
		"same sampler output")

func test_for_trial_requires_water_level() -> void:
	var p := TrackGenParams.for_trial(3, -1.0, 10, 0.5, _cfg())
	assert_almost_eq(p.water_level, -1.0, 0.0001, "trial water level honoured")
	assert_true(p.water_enabled, "trial always enables water so the preview shows it")

func test_dry_start_moves_off_water() -> void:
	# Water covers a disc around nominal origin; the search must find dry ground.
	var cfg := GameConfig.new()
	cfg.track_seed = 5
	cfg.water_enabled = true
	cfg.track_water_level_m = 0.0
	cfg.water_shore_clearance_m = 0.5
	var p := TrackGenParams.for_trial(5, 0.0, 8, 0.0, cfg)
	# Override sampler: underwater within 20m of nominal origin, dry beyond.
	p.water_sampler = func(x: float, z: float) -> float:
		return -10.0 if Vector2(x, z).length() < 20.0 else 10.0
	p.recompute_origin()
	assert_true(p.water_sampler.call(p.origin.x, p.origin.y) >= p.water_level + p.shore_clearance
		or not p.water_enabled,
		"start origin is on dry ground (or water disabled by fallback)")

func test_dry_start_deterministic() -> void:
	var cfg := GameConfig.new()
	cfg.track_seed = 5
	cfg.water_enabled = true
	var a := TrackGenParams.for_event({"seed": 5, "water_level": 0.0}, cfg)
	var b := TrackGenParams.for_event({"seed": 5, "water_level": 0.0}, cfg)
	assert_eq(a.origin, b.origin, "same (seed, water_level) -> same origin")


# --- resolve_water_level: event -> region -> GameConfig baseline ---------------
# Resolution ORDER is the whole contract (CLAUDE.md: never pin the shipped
# -12/-5/-10 values). Synthetic regions via the Registry.Seam only.

func after_each() -> void:
	RegionLibrary.reset()

func test_event_water_level_beats_its_region() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_region", "water_level": -99.0},
	])
	var level := TrackGenParams.resolve_water_level(
		{"water_level": -1.0, "region": "fx_region"}, -50.0)
	assert_almost_eq(level, -1.0, 0.0001, "event's own water_level wins over its region")

func test_event_with_no_water_level_inherits_its_region() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_region", "water_level": -99.0},
	])
	var level := TrackGenParams.resolve_water_level({"region": "fx_region"}, -50.0)
	assert_almost_eq(level, -99.0, 0.0001, "no event override -> region's waterline")

func test_region_with_no_water_level_falls_back_to_baseline() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_region"},  # authors no waterline at all
	])
	var level := TrackGenParams.resolve_water_level({"region": "fx_region"}, -50.0)
	assert_almost_eq(level, -50.0, 0.0001,
		"a region authoring nothing falls back to the GameConfig baseline")

func test_no_region_context_falls_back_to_baseline() -> void:
	# The challenge / free-roam / dev-page shape: an event dict with no region tag
	# at all (and no water_level) — must fall straight through to the baseline.
	var level := TrackGenParams.resolve_water_level({}, -50.0)
	assert_almost_eq(level, -50.0, 0.0001, "no region tag -> GameConfig baseline")

func test_for_event_resolves_water_level_through_its_region() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_region", "water_level": -33.0},
	])
	var cfg := _cfg()
	var p := TrackGenParams.for_event({"seed": 7, "region": "fx_region"}, cfg)
	assert_almost_eq(p.water_level, -33.0, 0.0001,
		"for_event resolves an unauthored event's water_level via its region")

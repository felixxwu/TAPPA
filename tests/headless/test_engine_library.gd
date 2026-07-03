extends GutTest
# EngineLibrary is the single source of truth for engine data. Every engine
# must be internally sane, and apply() must write the whole profile onto GameConfig.


func before_each() -> void:
	# Leak guard: this file asserts on the REAL catalogue, so make sure no other
	# file's fixture override is still installed.
	CarLibrary.reset()
	EngineLibrary.reset()


func test_catalog_is_a_sane_range_of_engines() -> void:
	assert_gt(EngineLibrary.ENGINES.size(), 1, "a catalog, not one engine")
	var ids := {}
	var layouts := {}
	for eng in EngineLibrary.ENGINES:
		var who: String = eng.get("id", "?")
		assert_false(ids.has(eng["id"]), "id '%s' is unique" % who)
		ids[eng["id"]] = true
		layouts[eng["layout"]] = true
		assert_true(EngineLibrary.FIRING.has(eng["layout"]), who + " layout has a firing table")
		assert_gt(eng["peak_torque"], 0.0, who + " positive peak_torque")
		assert_gt(eng["redline_rpm"], 0.0, who + " positive redline")
		# The real invariant the old blanket 6500 floor was standing in for:
		assert_gt(eng["redline_rpm"], eng["peak_torque_rpm"], who + " redline above its torque peak")
		assert_gt(eng["engine_inertia"], 0.0, who + " engine_inertia is positive")
		assert_between(eng["low_octave_mix"], 0.0, 1.0, who + " low_octave_mix is a 0..1 blend")
		# The transmission bolted to the engine (moved here from CarLibrary so a swap
		# carries the gearbox): ratios non-empty, strictly DESCENDING and positive (1st
		# is the shortest), positive final drive + shift time.
		var ratios: Array = eng["gear_ratios"]
		assert_gt(ratios.size(), 0, who + " has at least one forward gear")
		assert_gt(eng["final_drive"], 0.0, who + " positive final_drive")
		assert_gt(eng["shift_time"], 0.0, who + " positive shift_time")
		for g in ratios.size():
			assert_gt(ratios[g], 0.0, who + " gear %d ratio positive" % (g + 1))
			if g > 0:
				assert_lt(ratios[g], ratios[g - 1], who + " gear %d shorter than gear %d" % [g + 1, g])
	assert_gte(layouts.size(), 4, "a range of layouts / sounds")


func test_stable_id_lookups() -> void:
	for i in EngineLibrary.ENGINES.size():
		var id: String = EngineLibrary.ENGINES[i]["id"]
		assert_eq(EngineLibrary.index_of(id), i, "index_of('%s')" % id)
		assert_eq(EngineLibrary.by_id(id)["name"], EngineLibrary.ENGINES[i]["name"], "by_id('%s')" % id)
	assert_eq(EngineLibrary.index_of("nope"), -1, "unknown id -> -1")
	assert_true(EngineLibrary.by_id("nope").is_empty(), "unknown id -> empty")


func test_apply_writes_the_whole_profile_onto_config() -> void:
	var cfg := GameConfig.new()
	var eng := EngineLibrary.by_id("mopar_440_v8")
	EngineLibrary.apply(eng, cfg)
	var firing: Array = EngineLibrary.FIRING[eng["layout"]]
	assert_eq(cfg.engine_cylinders, firing.size(), "cylinders derived from firing table length")
	assert_eq(cfg.engine_firing_angles.size(), firing.size(), "firing angles copied")
	assert_almost_eq(cfg.redline_rpm, float(eng["redline_rpm"]), 0.001, "redline")
	assert_almost_eq(cfg.peak_torque, float(eng["peak_torque"]), 0.001, "peak_torque")
	assert_almost_eq(cfg.peak_torque_rpm, float(eng["peak_torque_rpm"]), 0.001, "peak_torque_rpm")
	assert_almost_eq(cfg.engine_inertia, float(eng["engine_inertia"]), 0.001, "inertia")
	assert_almost_eq(cfg.engine_low_octave_mix, float(eng["low_octave_mix"]), 0.001, "octave mix")
	assert_almost_eq(cfg.engine_volume_db, float(eng["volume_db"]), 0.001, "volume_db")
	assert_almost_eq(cfg.engine_noise_level, db_to_linear(float(eng["noise_db"])), 0.0001, "noise_db -> linear")
	assert_almost_eq(cfg.engine_soft_clip_post_gain, float(eng["soft_clip_post_gain"]), 0.001, "soft clip post gain")
	# The transmission is written too, so a swapped engine brings its gearbox.
	assert_eq(cfg.gear_ratios.size(), (eng["gear_ratios"] as Array).size(), "gear count written from the engine")
	for g in cfg.gear_ratios.size():
		assert_almost_eq(cfg.gear_ratios[g], float(eng["gear_ratios"][g]), 0.001, "gear %d ratio written" % (g + 1))
	assert_almost_eq(cfg.final_drive, float(eng["final_drive"]), 0.001, "final_drive written")
	assert_almost_eq(cfg.shift_time, float(eng["shift_time"]), 0.001, "shift_time written")


func test_apply_copies_forced_induction_fields() -> void:
	# Synthetic engine dicts (not the shipped catalogue): a turbo engine and a plain NA one.
	var cfg := GameConfig.new()
	var turbo_engine := {
		"layout": "i4", "redline_rpm": 7000.0, "peak_torque": 300.0, "peak_torque_rpm": 4000.0,
		"engine_inertia": 0.15, "low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0,
		"soft_clip_post_gain": 0.07,
		"turbo_enabled": true, "turbo_boost_gain": 0.7, "turbo_inertia": 8.0e-6,
		"engine_turbo_whistle_gain": 0.4,
	}
	EngineLibrary.apply(turbo_engine, cfg)
	assert_true(cfg.turbo_enabled, "a turbo engine sets turbo_enabled")
	assert_gt(cfg.turbo_boost_gain, 0.0, "turbo boost gain is copied through")
	assert_gt(cfg.engine_turbo_whistle_gain, 0.0, "whistle gain is copied through")

	var cfg2 := GameConfig.new()
	var na_engine := {
		"layout": "i4", "redline_rpm": 7000.0, "peak_torque": 200.0, "peak_torque_rpm": 4500.0,
		"engine_inertia": 0.15, "low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0,
		"soft_clip_post_gain": 0.07,
	}
	EngineLibrary.apply(na_engine, cfg2)
	assert_false(cfg2.turbo_enabled, "an engine without turbo keys stays NA")
	assert_false(cfg2.supercharger_enabled, "an engine without supercharger key stays unblown")


func test_every_engine_has_a_positive_mass() -> void:
	# Sanity guard only (not a value pin): the weight simulation divides/weights by
	# engine mass, so each engine must carry a finite positive dry weight.
	for eng in EngineLibrary.ENGINES:
		assert_true(eng.has("mass"), "%s declares a mass" % eng["id"])
		assert_gt(float(eng["mass"]), 0.0, "%s mass is positive" % eng["id"])
		assert_true(is_finite(float(eng["mass"])), "%s mass is finite" % eng["id"])



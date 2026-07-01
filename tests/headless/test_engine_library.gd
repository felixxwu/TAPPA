extends GutTest
# EngineLibrary is the single source of truth for engine data. Every engine
# must be internally sane, and apply() must write the whole profile onto GameConfig.


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



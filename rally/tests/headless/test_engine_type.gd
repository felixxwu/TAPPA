extends GutTest
# Engine-type presets: selecting GameConfig.engine_type drives both the sound
# (cylinder count + firing angles) and the performance numbers (redline, peak
# torque, peak-torque rpm). Presets win; there are no per-field sliders.

# Enum order must match the @export_enum in game_config.gd.
const I4 := 0
const I5 := 1
const I6 := 2
const V6 := 3
const V8 := 4
const V10 := 5
const V12 := 6


func test_default_is_inline4() -> void:
	var cfg := GameConfig.new()
	assert_eq(cfg.engine_type, I4, "defaults to i4")
	assert_eq(cfg.engine_cylinders, 4, "i4 has four cylinders")
	assert_eq(cfg.engine_firing_angles, [0.0, 180.0, 360.0, 540.0], "i4 even 180 deg")
	# The setter copies the preset's torque, so assert it matches the preset entry
	# (a tunable value) rather than pinning a literal that churns when it's rebalanced.
	assert_almost_eq(cfg.peak_torque, float(GameConfig.ENGINE_PRESETS[I4]["peak_torque"]), 0.001,
		"i4 peak torque matches its preset")


func test_selecting_v8_applies_eight_cylinders() -> void:
	var cfg := GameConfig.new()
	cfg.engine_type = V8
	assert_eq(cfg.engine_cylinders, 8, "v8 has eight cylinders")
	assert_eq(cfg.engine_firing_angles.size(), 8, "eight firing angles")
	# Compare against the i4 preset read live (not a literal) so this stays true
	# through torque rebalancing — same robustness as the i4 check above.
	assert_gt(cfg.peak_torque, float(GameConfig.ENGINE_PRESETS[I4]["peak_torque"]),
		"v8 makes more torque than the i4")


func test_each_preset_sets_a_full_sane_profile() -> void:
	var cfg := GameConfig.new()
	var expected_cyl := {I4: 4, I5: 5, I6: 6, V6: 6, V8: 8, V10: 10, V12: 12}
	for t in expected_cyl:
		cfg.engine_type = t
		assert_eq(cfg.engine_cylinders, expected_cyl[t], "cylinder count for type %d" % t)
		assert_eq(cfg.engine_firing_angles.size(), expected_cyl[t],
			"one firing angle per cylinder for type %d" % t)
		assert_gt(cfg.redline_rpm, cfg.idle_rpm, "redline above idle for type %d" % t)
		assert_gt(cfg.peak_torque, 0.0, "positive peak torque for type %d" % t)
		assert_gt(cfg.peak_torque_rpm, 0.0, "positive peak-torque rpm for type %d" % t)
		assert_lt(cfg.peak_torque_rpm, cfg.redline_rpm, "torque peaks below redline for type %d" % t)


func test_even_presets_have_evenly_spaced_phases() -> void:
	var cfg := GameConfig.new()
	for t in [I6, V12]:
		cfg.engine_type = t
		assert_true(_phases_evenly_spaced(cfg.engine_firing_phases()),
			"type %d should fire evenly (smooth)" % t)


func test_uneven_presets_have_unevenly_spaced_phases() -> void:
	var cfg := GameConfig.new()
	for t in [V6, V8]:
		cfg.engine_type = t
		assert_false(_phases_evenly_spaced(cfg.engine_firing_phases()),
			"type %d should fire unevenly (burble)" % t)


# Gaps between consecutive sorted phases (wrapping the 0..1 cycle) are all equal.
func _phases_evenly_spaced(phases: Array) -> bool:
	var sorted := phases.duplicate()
	sorted.sort()
	var n := sorted.size()
	var first_gap := fposmod(sorted[1] - sorted[0], 1.0)
	for i in range(n):
		var gap := fposmod(sorted[(i + 1) % n] - sorted[i], 1.0)
		if absf(gap - first_gap) > 0.001:
			return false
	return true

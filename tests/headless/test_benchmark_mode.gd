extends GutTest
# Benchmark mode (features/benchmark.md): the Benchmark autoload's config
# override/restore lifecycle, the toggle → GameConfig mapping, the stats
# summariser, and the runner's pure driving math. UI coverage (settings page,
# results panel) lives in test_benchmark_ui.gd.

# Preloaded at parse time so the scene's script compiles (and their pre-existing
# engine warnings, e.g. billboard_field's shadowed `basis`) happen outside any
# test — GUT otherwise attributes them to whichever test loads main.tscn first.
const MAIN_SCENE := preload("res://main.tscn")


func before_each() -> void:
	Config.reset()
	_reset_benchmark()


func after_each() -> void:
	_reset_benchmark()
	Config.reset()


# Put the autoload back to its boot state so toggles / snapshots can't leak
# between tests (it's session-scoped by design).
func _reset_benchmark() -> void:
	Benchmark.active = false
	Benchmark.results = {}
	Benchmark._saved = {}
	for t in Benchmark.TOGGLES:
		Benchmark.set_option(String(t["key"]), true)


# --- Toggle registry -----------------------------------------------------------

func test_every_toggle_has_a_default_on_option() -> void:
	for t in Benchmark.TOGGLES:
		var key := String(t["key"])
		assert_true(Benchmark.get_option(key), "toggle '%s' defaults ON" % key)
		assert_true(String(t["name"]).length() > 0, "toggle '%s' has a display name" % key)


func test_set_option_flips_and_reads_back() -> void:
	Benchmark.set_option("vegetation", false)
	assert_false(Benchmark.get_option("vegetation"), "a toggled-off option reads back off")
	Benchmark.set_option("vegetation", true)
	assert_true(Benchmark.get_option("vegetation"), "and flips back on")


# --- Config overrides ----------------------------------------------------------

func test_apply_overrides_sets_up_the_benchmark_stage() -> void:
	var cfg: GameConfig = Config.data
	Benchmark.apply_overrides(cfg)
	assert_eq(cfg.track_seed, Benchmark.TRACK_SEED, "the fixed benchmark seed is applied")
	assert_eq(cfg.track_turn_count, Benchmark.TRACK_TURN_COUNT, "the long benchmark stage is applied")
	assert_false(cfg.hud_enabled, "the HUD is off during a benchmark (the perf overlay is the UI)")


func test_apply_overrides_with_everything_on_keeps_features_enabled() -> void:
	var cfg: GameConfig = Config.data
	Benchmark.apply_overrides(cfg)
	for field in ["vegetation_enabled", "spectators_enabled", "signs_enabled",
			"distant_terrain_enabled", "road_markings_enabled", "tire_marks_enabled",
			"wheel_particles_enabled", "engine_smoke_enabled"]:
		assert_true(bool(cfg.get(field)), "%s stays on with all toggles on" % field)


func test_toggles_off_disable_their_config_switches() -> void:
	var cfg: GameConfig = Config.data
	for t in Benchmark.TOGGLES:
		Benchmark.set_option(String(t["key"]), false)
	Benchmark.apply_overrides(cfg)
	for field in ["vegetation_enabled", "spectators_enabled", "signs_enabled",
			"distant_terrain_enabled", "road_markings_enabled", "tire_marks_enabled",
			"wheel_particles_enabled", "engine_smoke_enabled"]:
		assert_false(bool(cfg.get(field)), "%s is off when its toggle is off" % field)


func test_render_distance_toggle_halves_foliage_distance() -> void:
	var cfg: GameConfig = Config.data
	var full: float = cfg.tree_render_distance_m
	Benchmark.set_option("full_render_distance", false)
	Benchmark.apply_overrides(cfg)
	assert_almost_eq(cfg.tree_render_distance_m, full * 0.5, 0.001,
		"render distance is halved when the toggle is off")


func test_uncap_fps_toggle_clears_the_frame_cap() -> void:
	var cfg: GameConfig = Config.data
	cfg.target_fps = 60
	cfg.target_fps_mobile = 30
	Benchmark.apply_overrides(cfg)
	# Both caps cleared so target_fps_for() returns 0 on every target.
	assert_eq(cfg.target_fps, 0, "uncap on: the desktop frame cap is cleared")
	assert_eq(cfg.target_fps_mobile, 0, "uncap on: the mobile/web frame cap is cleared")

	Benchmark.restore(cfg)
	Benchmark.set_option("uncap_fps", false)
	Benchmark.apply_overrides(cfg)
	assert_eq(cfg.target_fps, 60, "uncap off: the desktop cap is left alone")
	assert_eq(cfg.target_fps_mobile, 30, "uncap off: the mobile/web cap is left alone")


func test_restore_returns_every_overridden_field() -> void:
	var cfg: GameConfig = Config.data
	# Give the fields recognisable pre-benchmark values.
	cfg.track_seed = 777
	cfg.track_turn_count = 9
	cfg.tree_render_distance_m = 123.0
	cfg.spectators_enabled = true
	cfg.hud_enabled = true
	var originals := {}
	for field in Benchmark._OVERRIDDEN_FIELDS:
		originals[field] = cfg.get(field)

	for t in Benchmark.TOGGLES:
		Benchmark.set_option(String(t["key"]), false)
	Benchmark.apply_overrides(cfg)
	Benchmark.restore(cfg)
	for field in originals:
		assert_eq(cfg.get(field), originals[field], "restore() puts %s back" % field)
	assert_true(Benchmark._saved.is_empty(), "the snapshot is cleared after restore")


func test_reapplying_overrides_keeps_the_original_snapshot() -> void:
	# A re-start from inside a running benchmark (pause menu → Settings → Start)
	# re-applies over the live snapshot: the pre-benchmark values must survive and
	# relative overrides (the render-distance halving) must not compound.
	var cfg: GameConfig = Config.data
	var original_distance: float = cfg.tree_render_distance_m
	var original_hud: bool = cfg.hud_enabled
	Benchmark.set_option("full_render_distance", false)
	Benchmark.apply_overrides(cfg)
	Benchmark.apply_overrides(cfg)  # second run without an exit in between
	assert_almost_eq(cfg.tree_render_distance_m, original_distance * 0.5, 0.001,
		"the render-distance halving does not compound across re-applies")
	Benchmark.restore(cfg)
	assert_almost_eq(cfg.tree_render_distance_m, original_distance, 0.001,
		"restore returns the true pre-benchmark render distance")
	assert_eq(cfg.hud_enabled, original_hud,
		"restore returns the true pre-benchmark HUD state")


func test_restore_without_a_snapshot_is_a_noop() -> void:
	var cfg: GameConfig = Config.data
	var seed_before: int = cfg.track_seed
	Benchmark.restore(cfg)
	assert_eq(cfg.track_seed, seed_before, "restore with no snapshot changes nothing")


# --- Stats summariser (BenchmarkStats) ------------------------------------------

func test_summarise_frame_stats() -> void:
	# 9 smooth frames + 1 spike: avg 12.6ms, max 40, one frame >= 28ms.
	var frames := [10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 40.0]
	var s := BenchmarkStats.summarise({"frame_ms": frames})
	assert_eq(s["frames"], 10, "frame count")
	assert_almost_eq(float(s["duration_s"]), 0.13, 0.0001, "duration is the summed intervals")
	assert_almost_eq(float(s["frame_avg_ms"]), 13.0, 0.0001, "average frame time")
	assert_eq(float(s["frame_max_ms"]), 40.0, "max frame time")
	assert_eq(int(s["spikes"]), 1, "one frame over the spike threshold")
	assert_almost_eq(float(s["fps_avg"]), 10 * 1000.0 / 130.0, 0.01,
		"avg fps is frames over wall time")
	assert_true(float(s["frame_p99_ms"]) >= float(s["frame_p95_ms"]),
		"p99 is at least p95")
	assert_almost_eq(float(s["fps_1pct_low"]), 1000.0 / float(s["frame_p99_ms"]), 0.01,
		"1% low is the inverse of the p99 frame time")


func test_summarise_handles_missing_and_empty_streams() -> void:
	var s := BenchmarkStats.summarise({})
	assert_eq(s["frames"], 0, "no frames")
	assert_eq(float(s["fps_avg"]), 0.0, "no divide-by-zero on an empty run")
	assert_eq(float(s["draws_avg"]), 0.0, "missing streams summarise to zero")


func test_summarise_covers_the_monitor_streams() -> void:
	var s := BenchmarkStats.summarise({
		"frame_ms": [16.0, 16.0],
		"draws": [100.0, 200.0],
		"render_cpu_ms": [2.0, 4.0],
	})
	assert_almost_eq(float(s["draws_avg"]), 150.0, 0.001, "draw calls average")
	assert_eq(float(s["draws_max"]), 200.0, "draw calls max")
	assert_almost_eq(float(s["render_cpu_ms_avg"]), 3.0, 0.001, "render cpu average")


func test_percentile_nearest_rank() -> void:
	var vals := [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
	assert_eq(BenchmarkStats.percentile(vals, 0.0), 1.0, "p0 is the min")
	assert_eq(BenchmarkStats.percentile(vals, 1.0), 10.0, "p100 is the max")
	assert_eq(BenchmarkStats.percentile(vals, 0.5), 6.0, "median by nearest rank")
	assert_eq(BenchmarkStats.percentile([], 0.5), 0.0, "empty input reads 0")


# --- Run-scene wiring ------------------------------------------------------------

# Boot main.tscn in benchmark mode (trimmed to the cheapest 1-turn track, like
# SceneTestHelpers.minimal_world, so this stays inside the runtime budget) and
# check the world honours the mode: gates applied, stage flow skipped, the
# runner armed — and actually driving the car down the road.
func test_benchmark_scene_boots_gated_and_drives() -> void:
	Benchmark.set_option("vegetation", false)
	Benchmark.set_option("signs", false)
	Benchmark.set_option("spectators", false)
	Benchmark.apply_overrides(Config.data)
	Config.data.track_turn_count = 1  # keep the build cheap; the toggles are the point
	Benchmark.active = true
	var scene: Node3D = MAIN_SCENE.instantiate()
	add_child_autofree(scene)  # headless: world._ready builds synchronously

	assert_not_null(scene.get_node_or_null("BenchmarkRunner"), "the runner is spawned")
	assert_false(scene.get_node("HUD").visible, "the HUD is hidden (cfg.hud_enabled off)")
	assert_false(scene.get_node("MobileControls").visible, "touch controls are hidden")
	var overlay_on := false
	for child in scene.get_children():
		if child is PerfOverlay:
			overlay_on = child.visible
	assert_true(overlay_on, "the perf overlay is forced on for the run")
	assert_false(scene.get_node("StageManager")._armed,
		"the stage flow (countdown/lock) is skipped — the runner drives instead")
	for child in scene.get_children():
		assert_false(child is TreeMeshField, "vegetation off: no foliage fields built")
		assert_false(child is SignField, "signs off: no sign field built")

	# The runner is really driving: the car is AI-controlled and, after a few
	# seconds of sim, is moving forward along the road with progress accruing.
	var car := scene.get_node("Car")
	assert_true(car.ai_controlled, "the car is handed to the AI")
	var progress: TrackProgress = scene.get_node("TrackProgress")
	var start_offset := progress.progress_offset()
	for _i in 240:
		await get_tree().physics_frame
	assert_gt((car as RigidBody3D).linear_velocity.length(), 3.0,
		"the car is up to speed after a few seconds")
	assert_gt(progress.progress_offset() - start_offset, 5.0,
		"track progress accrues as the runner drives")

	# Finish flow: pin progress to 100% (the dev-cheat hook) — the runner's next
	# physics tick must summarise the run and show the results panel.
	progress.jump_to_finish()
	await get_tree().physics_frame
	await get_tree().process_frame
	assert_false(Benchmark.results.is_empty(), "the finish hands the summary to Benchmark")
	assert_gt(int(Benchmark.results.get("frames", 0)), 0, "the summary carries frame samples")
	var results_panel: Node = null
	for child in scene.get_node("BenchmarkRunner").get_children():
		if child is BenchmarkResults:
			results_panel = child
	assert_not_null(results_panel, "the results breakdown is shown at the finish")


# --- Runner driving math (BenchmarkRunner statics) -------------------------------

func test_steer_toward_turns_toward_the_target() -> void:
	# A car at the origin facing -Z (a Node3D's forward).
	var xform := Transform3D.IDENTITY
	assert_almost_eq(BenchmarkRunner.steer_toward(xform, Vector2(0.0, -10.0)), 0.0, 0.001,
		"a target dead ahead needs no steering")
	assert_gt(BenchmarkRunner.steer_toward(xform, Vector2(-5.0, -10.0)), 0.0,
		"a target to the left steers left (positive)")
	assert_lt(BenchmarkRunner.steer_toward(xform, Vector2(5.0, -10.0)), 0.0,
		"a target to the right steers right (negative)")
	assert_almost_eq(BenchmarkRunner.steer_toward(xform, Vector2(-100.0, -1.0)), 1.0, 0.001,
		"a hard-left target saturates at full lock")


func test_steer_toward_respects_the_car_heading() -> void:
	# The same world-space target reads differently once the car has turned:
	# facing +X (yawed -90°), a target further along +X is now dead ahead.
	var facing_px := Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3.ZERO)
	assert_almost_eq(BenchmarkRunner.steer_toward(facing_px, Vector2(10.0, 0.0)), 0.0, 0.001,
		"heading is measured in the car's local frame")


func test_throttle_for_holds_the_target_speed() -> void:
	var target := BenchmarkRunner.TARGET_SPEED_MPS
	assert_eq(BenchmarkRunner.throttle_for(0.0, target), 1.0,
		"well below target: full throttle")
	assert_almost_eq(BenchmarkRunner.throttle_for(target, target), 0.0, 0.001,
		"at target: coast")
	assert_lt(BenchmarkRunner.throttle_for(target + 5.0, target), 0.0,
		"above target: brake")

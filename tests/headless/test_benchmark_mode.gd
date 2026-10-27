extends GutTest
# Benchmark mode (features/benchmark.md): the Benchmark autoload's config and profile
# override/restore lifecycle, the toggle → GameConfig mapping, the stats summariser,
# the straight benchmark road, and the runner's pure driving math. UI coverage
# (settings page, results panel) lives in test_benchmark_ui.gd.

const TEST_PATH := "user://test_benchmark_mode_profile.json"


func before_all() -> void:
	Save.profile_path = TEST_PATH
	Save.save_disabled = false
	Save.load_or_new()


func after_all() -> void:
	Save.profile_path = Save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


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
	assert_gt(Benchmark.TOGGLES.size(), 0, "Benchmark.TOGGLES is non-empty (else this test asserts nothing)")
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

func test_apply_overrides_turns_the_hud_off() -> void:
	var cfg: GameConfig = Config.data
	Benchmark.apply_overrides(cfg)
	assert_false(cfg.hud_enabled, "the HUD is off during a benchmark (the perf overlay is the UI)")


func test_apply_overrides_with_everything_on_keeps_features_enabled() -> void:
	var cfg: GameConfig = Config.data
	Benchmark.apply_overrides(cfg)
	for field in ["vegetation_enabled", "spectators_enabled",
			"road_markings_enabled", "tire_marks_enabled",
			"wheel_particles_enabled", "engine_smoke_enabled"]:
		assert_true(bool(cfg.get(field)), "%s stays on with all toggles on" % field)


func test_toggles_off_disable_their_config_switches() -> void:
	assert_gt(Benchmark.TOGGLES.size(), 0, "Benchmark.TOGGLES is non-empty (else this test asserts nothing)")
	var cfg: GameConfig = Config.data
	for t in Benchmark.TOGGLES:
		Benchmark.set_option(String(t["key"]), false)
	Benchmark.apply_overrides(cfg)
	for field in ["vegetation_enabled", "spectators_enabled",
			"road_markings_enabled", "tire_marks_enabled",
			"wheel_particles_enabled", "engine_smoke_enabled"]:
		assert_false(bool(cfg.get(field)), "%s is off when its toggle is off" % field)


func test_render_distance_toggle_halves_foliage_distance() -> void:
	var cfg: GameConfig = Config.data
	var full: float = cfg.tree_render_distance_m
	var phone: float = cfg.tree_render_distance_web_touch_m
	Benchmark.set_option("full_render_distance", false)
	Benchmark.apply_overrides(cfg)
	assert_almost_eq(cfg.tree_render_distance_m, full * 0.5, 0.001,
		"render distance is halved when the toggle is off")
	assert_almost_eq(cfg.tree_render_distance_web_touch_m, phone * 0.5, 0.001,
		"and the phone's own distance with it")


func test_uncap_fps_toggle_clears_the_frame_cap() -> void:
	var cfg: GameConfig = Config.data
	cfg.target_fps = 60
	cfg.target_fps_mobile = 45
	cfg.target_fps_web = 30
	Benchmark.apply_overrides(cfg)
	# All caps cleared so target_fps_for() returns 0 on every target.
	assert_eq(cfg.target_fps, 0, "uncap on: the desktop frame cap is cleared")
	assert_eq(cfg.target_fps_mobile, 0, "uncap on: the mobile frame cap is cleared")
	assert_eq(cfg.target_fps_web, 0, "uncap on: the web frame cap is cleared")

	Benchmark.restore(cfg)
	Benchmark.set_option("uncap_fps", false)
	Benchmark.apply_overrides(cfg)
	assert_eq(cfg.target_fps, 60, "uncap off: the desktop cap is left alone")
	assert_eq(cfg.target_fps_mobile, 45, "uncap off: the mobile cap is left alone")
	assert_eq(cfg.target_fps_web, 30, "uncap off: the web cap is left alone")


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


# --- Throwaway world + run-scene wiring -------------------------------------------

func test_a_run_drives_a_throwaway_world_and_hands_back_the_players_profile() -> void:
	Save.save_disabled = false
	var before := Save.profile.duplicate(true)
	Benchmark.begin()
	assert_eq(WorldSession.world_seed(), Benchmark.WORLD_SEED, "the benchmark world is seeded")
	assert_true(Save.save_disabled, "nothing is written while it runs")
	Benchmark.end()
	assert_eq(Save.profile, before, "the player's profile comes back untouched")
	assert_false(Save.save_disabled, "saving is switched back on")


# The pause menu's Quit during a run ends the benchmark (the real profile comes back) and goes to
# the title; and the world the run scene held is marked replaced, so its exit save writes nothing.
func test_quitting_a_run_from_the_pause_menu_ends_the_benchmark() -> void:
	Save.save_disabled = false
	var before := Save.profile.duplicate(true)
	Benchmark.begin()
	var g := WorldSession.generation
	var pause: PauseMenu = autofree(PauseMenu.new())
	add_child(pause)
	pause.quit_to_title()
	assert_false(Benchmark.active)
	assert_eq(Save.profile, before)
	assert_eq(Scenes.last_blocked_path, Scenes.TITLE)
	assert_gt(WorldSession.generation, g)


func test_a_sweep_config_switches_off_the_toggles_it_names_and_resets_the_rest() -> void:
	var first := String(Benchmark.TOGGLES[0]["key"])
	Benchmark.apply_sweep({"disabled": [first], "two_pass": true, "render_height": 720, "tree_mode": 2})
	assert_false(Benchmark.get_option(first), "a named toggle is switched off")
	for t in Benchmark.TOGGLES.slice(1):
		assert_true(Benchmark.get_option(String(t["key"])), "the others stay on")
	assert_true(Benchmark.two_pass)
	assert_eq(Benchmark.render_height, 720)
	assert_eq(Benchmark.tree_mode, 2)
	Benchmark.apply_overrides(Config.data)
	assert_eq(Config.data.tree_cutout_mode, 2, "the run draws its trees that way")
	Benchmark.restore(Config.data)
	Benchmark.apply_sweep({})
	assert_true(Benchmark.get_option(first), "an empty config is the full baseline")
	assert_false(Benchmark.two_pass)
	assert_eq(Benchmark.render_height, 0)
	assert_eq(Benchmark.tree_mode, -1, "an empty config keeps the game's own tree drawing")


func test_the_straight_road_option_builds_one_straight_link() -> void:
	var s := FreeRoamSettings.new()
	s.straight_road_m = 1500.0
	var net := RoadNetwork.new()
	var terrain := RoadTerrain.new()
	terrain.setup(s, net)
	net.build(s, terrain)
	assert_eq(net.edges.size(), 1, "one road")
	assert_almost_eq(net.total_length_m, 1500.0, 0.01, "dead straight: as long as the line it follows")


func test_the_benchmark_boots_free_roam_and_drives_down_the_road() -> void:
	Benchmark.begin()
	var scene: Node3D = load(Scenes.FREE_ROAM).instantiate()
	var s := FreeRoamSettings.new()
	s.island_radius_m = 3000.0
	s.mid_radius = 1
	s.far_radius = 3
	(scene.get_node("Terrain") as TerrainStreamer).settings = s
	add_child_autofree(scene)
	await get_tree().physics_frame
	var streamer: TerrainStreamer = scene.get_node("Terrain")
	assert_eq(streamer.network.edges.size(), 1, "the benchmark island has the one straight road")
	assert_eq(s.straight_road_m, 0.0, "the shared settings resource is left alone")
	assert_not_null(scene.get_node_or_null("BenchmarkRunner"), "the runner is spawned")
	var car: VehicleBody3D = scene.get_node("Car")
	assert_true(car.ai_controlled, "the car is handed to the auto-driver")
	assert_true(car.damage.invulnerable, "the car can't be wrecked mid-run")
	for _i in 240:
		await get_tree().physics_frame
	assert_gt(car.linear_velocity.length(), 3.0, "the car is up to speed after a few seconds")
	assert_gt((scene.get_node("AutoDriver") as AutoDriver).driven_m, 5.0, "and covering ground")
	scene.get_node("BenchmarkRunner")._finish()
	await get_tree().process_frame
	assert_false(Benchmark.results.is_empty(), "the end of the run hands the summary to Benchmark")
	assert_gt(int(Benchmark.results.get("frames", 0)), 0, "the summary carries frame samples")
	Benchmark.end()


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
	var target := 10.0
	assert_eq(BenchmarkRunner.throttle_for(0.0, target), 1.0,
		"well below target: full throttle")
	assert_almost_eq(BenchmarkRunner.throttle_for(target, target), 0.0, 0.001,
		"at target: coast")
	assert_lt(BenchmarkRunner.throttle_for(target + 5.0, target), 0.0,
		"above target: brake")


# --- Frame-time measurement source ---------------------------------------------
# The runner must time frames off the monotonic wall clock, NOT _process's delta:
# Godot's delta smoothing snaps delta to refresh-rate divisors and flattens exactly
# the hitches the benchmark exists to catch (it silently held spikes>28ms at 0 through
# genuine 40 ms frames). No timing THRESHOLD is asserted here — only that the source
# is a real elapsed-time clock that advances between calls.
func test_frame_interval_measures_elapsed_wall_time() -> void:
	var runner := BenchmarkRunner.new()
	add_child_autofree(runner)
	runner._frame_interval_ms()  # baseline the clock
	var before := Time.get_ticks_usec()
	while Time.get_ticks_usec() - before < 2000:
		pass  # burn a measurable, smoothing-independent amount of wall time
	var first := runner._frame_interval_ms()
	assert_gt(first, 0.0, "the interval is a real elapsed time, not a fixed delta")
	# Called again immediately, the baseline has advanced, so the second interval is
	# far shorter than the burnt one — proving each call measures the gap since the
	# LAST call rather than since some fixed origin.
	var second := runner._frame_interval_ms()
	assert_lt(second, first, "each call re-baselines to now")

extends Node
# Autoload "Benchmark": the in-game performance benchmark mode
# (features/benchmark.md). Launched from Settings → Benchmark, it loads a fresh
# run scene with a LONG seeded stage, has BenchmarkRunner auto-drive the car the
# whole way at a steady moderate speed with the PerfOverlay forced on, and shows
# a stats breakdown (BenchmarkResults) at the finish.
#
# This autoload owns:
#   • the TOGGLES the player sets before a run (disable vegetation, spectators,
#     render distance, …) so individual features' cost can be isolated A/B-style;
#   • the config override/restore lifecycle: start() snapshots the live
#     GameConfig fields it touches, writes the benchmark stage + toggle values,
#     and exit_to_hq() restores the snapshot — so a benchmark can never leak a
#     disabled feature (or its fixed seed) into normal play;
#   • the frame cap / vsync override (uncapped fps is what exposes headroom);
#   • the last run's results, for anything that wants to read them back.
#
# Like RallySession it survives scene changes, which is what lets "Run again"
# simply reload main.tscn with the overrides still in place. The scene-side
# work (skipping the stage flow, spawning the runner) keys off `active`.

# The benchmark stage: one fixed seed + a long turn count, so every run drives
# the SAME track and numbers are comparable run-to-run and machine-to-machine.
const TRACK_SEED := 90210
# Fixed seed for the per-car engine RNG (damage misfires) so a benchmark run is
# reproducible end-to-end, not just in its track geometry. Engine._init reads this
# instead of randomising while `active`, so successive runs stumble identically.
const RNG_SEED := 90210
const TRACK_TURN_COUNT := 30   # a long stage — more varied content to stress; the run is
                               # time-boxed by BenchmarkRunner.MAX_RUN_SECONDS, not by finishing it
const NEUTRAL_FRACTION := 0.5  # straightness / forestiness / tarmac mid-point

# The pre-run feature toggles, in the order the Settings page lists them. Each is
# ON by default (the full game as shipped); turning one OFF removes that cost
# from the run so its share of the frame can be measured by comparison.
const TOGGLES: Array[Dictionary] = [
	{"key": "vegetation", "name": "Trees & bushes"},
	{"key": "spectators", "name": "Spectators"},
	{"key": "signs", "name": "Roadside signs"},
	{"key": "distant_terrain", "name": "Distant terrain"},
	{"key": "road_markings", "name": "Road markings"},
	{"key": "surface_fx", "name": "Tire marks & dust FX"},
	{"key": "full_render_distance", "name": "Full render distance"},
	{"key": "uncap_fps", "name": "Uncap FPS (vsync off)"},
]

# True from start() until exit_to_hq() — the run scene keys benchmark behaviour
# (skip the stage flow, spawn the runner, force the perf overlay) off this.
var active := false

# Toggle states, keyed by TOGGLES key. Session-scoped (reset each boot).
var options: Dictionary = {}

# Dev spike-diagnosis mode: when set (via the ?bench sweep config), the runner
# drives the stage twice in ONE page load — pass 0 (cold WebGL shader cache), then
# reset + drive again as pass 1 (warm) WITHOUT a page reload, so the GL context and
# compiled shaders persist. Comparing the two passes' spikes confirms whether the
# hitches are first-use shader/texture compilation. `pass_index` is the live pass.
var two_pass := false
var pass_index := 0

# The last completed run's summary (BenchmarkStats.summarise output), kept so
# the results survive the scene while the player reads them / runs again.
var results: Dictionary = {}

# Snapshot of every GameConfig field apply_overrides() touches, written back by
# restore(). Empty when no overrides are applied.
var _saved: Dictionary = {}
# Engine frame cap + vsync mode as they were before the run, restored on exit.
var _saved_max_fps := 0
var _saved_vsync := DisplayServer.VSYNC_ENABLED


func _init() -> void:
	for t in TOGGLES:
		options[t["key"]] = true


func get_option(key: String) -> bool:
	return bool(options.get(key, true))


func set_option(key: String, on: bool) -> void:
	options[key] = on


# --- Run lifecycle -------------------------------------------------------------

# Launch the benchmark: leave any paused menu / active rally cleanly, write the
# benchmark stage + toggles into the live config (snapshotting first), uncap the
# frame rate, and load the run scene. world.gd sees `active` and wires the rest.
func start() -> void:
	get_tree().paused = false  # reachable from the pause menu's Settings
	if RallySession.is_active():
		RallySession.abandon()  # its scene change is superseded by ours below
	RallySession.free_roam_instance_id = -1
	# Capture the frame pacing only on first entry — a re-start from inside a
	# running benchmark (pause menu → Settings → Start) must keep the ORIGINAL
	# cap/vsync so exit_to_hq restores the pre-benchmark state, not our override.
	if not active:
		_saved_max_fps = Engine.max_fps
		if not Platform.is_headless():
			_saved_vsync = DisplayServer.window_get_vsync_mode(0)
	apply_overrides(Config.data)
	results = {}
	active = true
	pass_index = 0  # two_pass is set by the caller (hq sweep config) before start()
	# Uncap the frame rate so the run exposes real headroom instead of pinning to
	# the refresh rate / cfg.target_fps; with the toggle off, (re)apply the saved
	# pacing so flipping it between runs takes effect. Headless has no window.
	if get_option("uncap_fps"):
		Engine.max_fps = 0
		if not Platform.is_headless():
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	else:
		Engine.max_fps = _saved_max_fps
		if not Platform.is_headless():
			DisplayServer.window_set_vsync_mode(_saved_vsync)
	get_tree().change_scene_to_file("res://main.tscn")


# Called by BenchmarkRunner when the car crosses the finish.
func finish(stats: Dictionary) -> void:
	results = stats


# Leave benchmark mode: restore the config snapshot + frame pacing and return to
# HQ. Also the pause menu's quit path during a benchmark (pause_menu.gd).
func exit_to_hq() -> void:
	active = false
	restore(Config.data)
	Engine.max_fps = _saved_max_fps
	if not Platform.is_headless():
		DisplayServer.window_set_vsync_mode(_saved_vsync)
	get_tree().change_scene_to_file("res://hq.tscn")


# --- Config overrides (pure, testable) -----------------------------------------

# Every GameConfig field the benchmark may rewrite. One list so the snapshot and
# the restore can never drift apart.
const _OVERRIDDEN_FIELDS: Array[String] = [
	"track_seed", "track_turn_count", "track_straightness", "track_forestiness",
	"track_tarmac_fraction", "target_fps", "target_fps_mobile", "target_fps_web", "hud_enabled",
	"vegetation_enabled", "spectators_enabled", "signs_enabled",
	"distant_terrain_enabled", "road_markings_enabled",
	"tire_marks_enabled", "wheel_particles_enabled", "engine_smoke_enabled",
	"tree_render_distance_m",
]


# Snapshot the touched fields and write the benchmark values: the fixed long
# stage, the HUD off (the perf overlay is the benchmark's UI), and each toggle
# mapped onto the feature switch(es) it controls. Re-applying over a live
# snapshot (a re-start from inside a benchmark) first restores the baseline, so
# the snapshot keeps the true pre-benchmark values and relative overrides (the
# render-distance halving) can't compound.
func apply_overrides(cfg: GameConfig) -> void:
	restore(cfg)  # no-op when no snapshot is held
	for field in _OVERRIDDEN_FIELDS:
		_saved[field] = cfg.get(field)

	cfg.track_seed = TRACK_SEED
	cfg.track_turn_count = TRACK_TURN_COUNT
	cfg.track_straightness = NEUTRAL_FRACTION
	cfg.track_forestiness = NEUTRAL_FRACTION
	cfg.track_tarmac_fraction = NEUTRAL_FRACTION
	cfg.hud_enabled = false

	cfg.vegetation_enabled = get_option("vegetation")
	cfg.spectators_enabled = get_option("spectators")
	cfg.signs_enabled = get_option("signs")
	cfg.distant_terrain_enabled = get_option("distant_terrain")
	cfg.road_markings_enabled = get_option("road_markings")
	cfg.tire_marks_enabled = get_option("surface_fx")
	cfg.wheel_particles_enabled = get_option("surface_fx")
	cfg.engine_smoke_enabled = get_option("surface_fx")
	if not get_option("full_render_distance"):
		cfg.tree_render_distance_m *= 0.5
	if get_option("uncap_fps"):
		# Zero all caps so world.gd's target_fps_for() picks 0 on every target
		# (web reads target_fps_web, native mobile target_fps_mobile, desktop target_fps).
		cfg.target_fps = 0  # world.gd otherwise re-applies the cap at _ready
		cfg.target_fps_mobile = 0
		cfg.target_fps_web = 0


# Write the snapshot back, undoing apply_overrides. Safe to call when no
# snapshot is held (a no-op).
func restore(cfg: GameConfig) -> void:
	for field in _saved:
		cfg.set(field, _saved[field])
	_saved = {}

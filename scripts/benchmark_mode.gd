extends Node
# Docs: features/benchmark.md — update in the same change as this file.
# Tests: tests/headless/test_benchmark_mode.gd, tests/headless/test_benchmark_report.gd, tests/headless/test_benchmark_ui.gd — extend in the same change.
# Autoload "Benchmark": the in-game performance benchmark mode
# (features/benchmark.md). Launched from Settings → Benchmark, it boots free roam on a
# throwaway world with a fixed seed, has an AutoDriver drive a route across the island
# while BenchmarkRunner samples every frame, and shows a stats breakdown
# (BenchmarkResults) at the end.
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
# It survives scene changes, which is what lets "Run again"
# simply reload the scene with the overrides still in place. The scene-side
# work (skipping the stage flow, spawning the runner) keys off `active`.

# The benchmark island: one fixed seed, so every run drives the SAME roads and numbers
# are comparable run-to-run and machine-to-machine.
const WORLD_SEED := 90210
# The benchmark island has one straight road this long, so the auto-driver can't fail on it.
const ROAD_M := 3000.0
# Fixed seed for the per-car engine RNG (damage misfires) so a benchmark run is
# reproducible end-to-end, not just in its track geometry. Engine._init reads this
# instead of randomising while `active`, so successive runs stumble identically.
const RNG_SEED := 90210

# The pre-run feature toggles, in the order the Settings page lists them. Each is
# ON by default (the full game as shipped); turning one OFF removes that cost
# from the run so its share of the frame can be measured by comparison.
const TOGGLES: Array[Dictionary] = [
	{"key": "vegetation", "name": "Trees & bushes"},
	{"key": "spectators", "name": "Spectators"},
	{"key": "signs", "name": "Roadside signs"},
	{"key": "barriers", "name": "Corner barriers"},
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

# Dev resolution-sweep knob (via the ?bench sweep config): when > 0, DisplayStretch
# lays the benchmark frame out at THIS logical height instead of DESIGN_HEIGHT, so
# a remote sweep can measure fill/GPU cost at several render resolutions up to the
# device's native height with no shippable config change. 0 = authored default.
var render_height := 0

# Dev knob (via the ?bench sweep config): how trees are cut out of their texture for this run,
# GameConfig.tree_cutout_mode (0 opaque silhouette, 1 alpha cutout, 2 alpha blend); -1 keeps the
# game's own setting.
var tree_mode := -1

# The last completed run's summary (BenchmarkStats.summarise output), kept so
# the results survive the scene while the player reads them / runs again.
var results: Dictionary = {}

# Snapshot of every GameConfig field apply_overrides() touches, written back by
# restore(). Empty when no overrides are applied.
var _saved: Dictionary = {}
# Engine frame cap + vsync mode as they were before the run, restored on exit.
var _saved_max_fps := 0
var _saved_vsync := DisplayServer.VSYNC_ENABLED
# The player's profile and save switch as they were before the run. The benchmark drives a
# throwaway world in memory and must never write it over the real one.
var _saved_profile: Dictionary = {}
var _saved_save_disabled := false


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
# frame rate, and load free roam. free_roam.gd sees `active` and wires the rest.
func start() -> void:
	begin()
	Scenes.change_to(get_tree(), Scenes.FREE_ROAM)


# Everything start() does except the scene change, for a harness that hosts the scene itself
# (benchmark/perf_benchmark.gd).
func begin() -> void:
	get_tree().paused = false  # reachable from the pause menu's Settings
	# Capture the frame pacing only on first entry — a re-start from inside a
	# running benchmark (pause menu → Settings → Start) must keep the ORIGINAL
	# cap/vsync so exit_to_hq restores the pre-benchmark state, not our override.
	if not active:
		_saved_max_fps = Engine.max_fps
		if not Platform.is_headless():
			_saved_vsync = DisplayServer.window_get_vsync_mode(0)
		_saved_profile = Save.profile.duplicate(true)
		_saved_save_disabled = Save.save_disabled
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
	seat_world()


# A fresh benchmark world in the in-memory profile, with saving off. Called before every
# (re)load of the scene, because free roam writes the car's pose back into the world as it drives.
func seat_world() -> void:
	Save.save_disabled = true
	var car_id := FreeRoamSettings.new().car_id
	var idx := maxi(0, CarLibrary.index_of(car_id))
	WorldSession.new_world(WORLD_SEED, String(CarLibrary.all()[idx]["id"]))


# The phone profiling loop (features/benchmark.md → "Dev auto-profiling loop"): a web page
# opened with ?bench=1 boots straight into a benchmark. Never true off the web build.
func autostart_requested() -> bool:
	if not Platform.is_web() or Platform.is_headless() or active:
		return false
	return str(JavaScriptBridge.eval("window.location.search", true)).find("bench=1") != -1


# The sweep settings the LAN collector serves at /bench-config, or {} when there are none.
# A synchronous request is fine here: it runs once, at boot.
func fetch_sweep_config() -> Dictionary:
	var raw := str(JavaScriptBridge.eval(
		"(function(){try{var x=new XMLHttpRequest();x.open('GET','/bench-config?t='+Date.now(),false);x.send();return x.status==200?x.responseText:'';}catch(e){return '';}})()",
		true))
	var data: Variant = JSON.parse_string(raw) if raw.strip_edges() != "" else null
	return data if data is Dictionary else {}


# Apply a sweep config: {"disabled": [toggle keys], "two_pass": bool, "render_height": int,
# "tree_mode": int}.
# Anything it leaves out goes back to the default.
func apply_sweep(data: Dictionary) -> void:
	var disabled: Array = data.get("disabled", [])
	for t in TOGGLES:
		set_option(String(t["key"]), not (String(t["key"]) in disabled))
	two_pass = bool(data.get("two_pass", false))
	render_height = int(data.get("render_height", 0))
	tree_mode = int(data.get("tree_mode", -1))


# Called by BenchmarkRunner when the run ends.
func finish(stats: Dictionary) -> void:
	results = stats


# Leave benchmark mode: restore the config snapshot + frame pacing and return to
# HQ. Also the pause menu's quit path during a benchmark (pause_menu.gd).
func exit_to_hq() -> void:
	end()
	Scenes.change_to(get_tree(), Scenes.hub_path())


# Everything exit_to_hq() does except the scene change.
func end() -> void:
	if active:
		Save.profile = _saved_profile
		Save.save_disabled = _saved_save_disabled
	active = false
	restore(Config.data)
	Engine.max_fps = _saved_max_fps
	if not Platform.is_headless():
		DisplayServer.window_set_vsync_mode(_saved_vsync)


# --- Config overrides (pure, testable) -----------------------------------------

# The fields apply_overrides writes (the toggles and frame pacing). The snapshot itself
# covers every GameConfig field — see _snapshot_fields.
const _OVERRIDDEN_FIELDS: Array[String] = [
	"target_fps", "target_fps_mobile", "target_fps_web", "hud_enabled",
	"vegetation_enabled", "spectators_enabled", "signs_enabled", "barriers_enabled",
	"distant_terrain_enabled", "road_markings_enabled",
	"tire_marks_enabled", "wheel_particles_enabled", "engine_smoke_enabled",
	"tree_render_distance_m", "tree_render_distance_web_touch_m", "tree_cutout_mode",
]


# Snapshot the config and write the benchmark values: the HUD off (the perf overlay
# is the benchmark's UI) and each toggle mapped onto the feature switch(es) it
# controls. Re-applying over a live snapshot (a re-start from inside a benchmark)
# first restores the baseline, so the snapshot keeps the true pre-benchmark values
# and relative overrides (the render-distance halving) can't compound.
func apply_overrides(cfg: GameConfig) -> void:
	restore(cfg)  # no-op when no snapshot is held
	for field in _snapshot_fields(cfg):
		_saved[field] = cfg.get(field)
	cfg.hud_enabled = false

	cfg.vegetation_enabled = get_option("vegetation")
	cfg.spectators_enabled = get_option("spectators")
	cfg.signs_enabled = get_option("signs")
	cfg.barriers_enabled = get_option("barriers")
	cfg.distant_terrain_enabled = get_option("distant_terrain")
	cfg.road_markings_enabled = get_option("road_markings")
	cfg.tire_marks_enabled = get_option("surface_fx")
	cfg.wheel_particles_enabled = get_option("surface_fx")
	cfg.engine_smoke_enabled = get_option("surface_fx")
	if not get_option("full_render_distance"):
		cfg.tree_render_distance_m *= 0.5
		cfg.tree_render_distance_web_touch_m *= 0.5
	if tree_mode >= 0:
		cfg.tree_cutout_mode = tree_mode
	if get_option("uncap_fps"):
		# Zero all caps so world.gd's target_fps_for() picks 0 on every target
		# (web reads target_fps_web, native mobile target_fps_mobile, desktop target_fps).
		cfg.target_fps = 0  # world.gd otherwise re-applies the cap at _ready
		cfg.target_fps_mobile = 0
		cfg.target_fps_web = 0


# Which fields to snapshot before overriding: EVERY scripted GameConfig property,
# not a hand-maintained list, so "the snapshot missed a field the override wrote"
# can't happen.
static func _snapshot_fields(cfg: GameConfig) -> Array[String]:
	var out: Array[String] = []
	for prop in cfg.get_property_list():
		if int(prop.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out.append(String(prop["name"]))
	return out


# Write the snapshot back, undoing apply_overrides. Safe to call when no
# snapshot is held (a no-op).
func restore(cfg: GameConfig) -> void:
	for field in _saved:
		cfg.set(field, _saved[field])
	_saved = {}

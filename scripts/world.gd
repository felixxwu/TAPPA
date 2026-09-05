extends Node3D
# Docs: features/benchmark.md, features/lakes.md, features/start-line.md — update in the same change as this file.
# Tests: tests/headless/test_benchmark_ui.gd, tests/headless/test_lake_field.gd, tests/headless/test_start_line.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'world' tests/headless/` and read the assertions that pin what you are about to change (8 test files touch this script).
# Applies the central GameConfig to scene-owned resources at startup.
# Car handling is applied by car.gd; camera follow by chase_camera.gd.

const BUSH_SEED_OFFSET := 1013
# Rocks get their own scatter seed so their lattice interleaves with the trees' and the
# bushes' instead of landing on the same jittered grid points (see TreeScatter._grid_phase).
# Distinct from BUSH_SEED_OFFSET for the same reason; the value is arbitrary, only its
# difference matters.
const ROCK_SEED_OFFSET := 2027
# Coins get their own offset for the same reason — CoinLayout.plan is seeded off
# `cfg.track_seed + COIN_SEED_OFFSET` (see _build_coins), so coin placement never
# lands on the same RNG draws as trees/bushes/rocks despite sharing the one
# per-stage seed. Arbitrary; only its difference from the others matters.
const COIN_SEED_OFFSET := 3041

# The two terrain shaders the floor material swaps between per stage, and the loading-window
# frame caps, both now shared with overworld.gd via WorldRuntime (scripts/world_runtime.gd) —
# they were byte-for-byte duplicated in the two world hosts. The reasoning for each lives on
# the consts there; WorldRuntime also carries the TODO about moving the caps into GameConfig.

# Headless (test) runs build the world synchronously — see _yield_frame(). Cached
# so the staged-loading awaits collapse to no-ops and tests see a fully-built
# world the instant main.tscn is instantiated, exactly as before this overlay.
var _headless := false

# Per-stage load timing. Each _stage() boundary closes the previous stage and
# logs its wall-clock cost, so the real load-time split (track search vs carve vs
# chunk precompute vs foliage) is visible in the console. Silent under headless.
var _stage_t0 := 0
var _stage_label := ""
var _load_t0 := 0

# Latches once _on_load_finished() has fired, so a later regeneration can't emit
# load_finished twice and double-free load-only data.
var _load_finished := false

# Every frame cap _ready has applied, in order: [loading cap, post-load cap]. Recorded
# even under headless (where the real Engine.max_fps write is suppressed so the
# frame-awaiting test runner isn't throttled), so tests can assert the INTENT — that a
# loading cap was applied at all, and that the post-load cap is whatever the resolver
# chose for that mode — without reading Engine.max_fps.
var applied_fps_caps: Array[int] = []


# Apply a frame cap and record the intent. The Engine write is suppressed under
# --headless (nothing to pace, and it would throttle the test runner). Shared with
# overworld.gd — see WorldRuntime.apply_fps_cap.
# Platform.is_headless() rather than the cached `_headless`: this can be called from
# _ready BEFORE that flag is seated.
func _apply_fps_cap(cap: int) -> void:
	WorldRuntime.apply_fps_cap(applied_fps_caps, cap, Platform.is_headless())


func _ready() -> void:
	_headless = Platform.is_headless()
	# Cover the screen before any heavy generation so the player sees staged
	# progress instead of a frozen frame between Godot's boot bar finishing and
	# the first playable frame. Freed by _generate_track() once the world is up.
	var loading := LoadingScreen.new()
	add_child(loading)

	# Seat the active session's stage/event track parameters into the live config
	# BEFORE anything reads it. Pulling here (instead of every producer pushing
	# before its scene load) is the single point where a stage's config reaches
	# the run — session-less entries (free roam, benchmark, dev boot) no-op and
	# keep whatever the caller wrote. See DrivingContext.apply_stage_config.
	DrivingContext.apply_stage_config(Config.data)
	var cfg: GameConfig = Config.data
	# A one-shot notice from the Start gate (today: the free upgrade restore) replaces
	# the loading tip for this one load — it is about the car the player is sitting in,
	# which beats a generic tip, and taking it here clears it so the remaining stages
	# go back to tips.
	# Tell the player which stage of the run is loading (no-op for a session-less drive).
	# Replaced the weather tell that used to own this line.
	if RunSession.is_active():
		loading.set_stage(RunSession.events_completed(), RunSession.stage_count())
	# Resolve the per-target render quality ONCE, before apply_terrain_lod() and any
	# scatter run: a web TOUCH device (the low-end / 30fps target) gets the shorter
	# foliage cull distance and tighter terrain LOD bands, every other target the
	# higher-quality set. Written back onto cfg so all downstream readers (foliage,
	# signs, spectators, arches, apply_terrain_lod) pick it up unchanged.
	var _web := Platform.is_web()
	var _touch := Platform.is_touch()
	cfg.tree_render_distance_m = cfg.tree_render_distance_for(_web, _touch)
	cfg.terrain_lod_bands_m = cfg.terrain_lod_bands_for(_web, _touch)
	# Frame cap: the player's Settings -> Display choice (FpsSetting), which defaults
	# to the platform's natural cap when unset — a web TOUCH device 30 (audio-bounded),
	# desktop/native 60 (see FpsSetting.default_cap / GameConfig.target_fps_for). 0 =
	# uncapped. During a benchmark the config-driven cap wins (the benchmark's uncap
	# toggle zeroes it), ignoring the user setting. Set unconditionally (0 actively
	# uncaps if the player switched away from a cap) except under --headless (no
	# rendering to pace) so it can't throttle the frame-awaiting test runner. Physics
	# stays at the project physics tick.
	var fps_cap := FpsSetting.default_cap() if Benchmark.active else FpsSetting.resolve()
	# ...but NOT yet during generation. A 30 fps cap paces every
	# `await process_frame` the load performs (verified on the web export: 33.4 ms per
	# awaited frame at cap 30 vs 8.3 ms uncapped), so the hundreds of yields world
	# generation makes idle away most of their frame budget. Raise the cap for the
	# duration of the load and apply the real one after (see the _end_load_timing call
	# in this function). Skipped under a benchmark: benchmark_mode.gd snapshots
	# Engine.max_fps to restore later, and a transient loading cap must never be what
	# it captures. See todo/mobile-web-performance.md §1.1.
	if not Benchmark.active:
		_apply_fps_cap(WorldRuntime.loading_cap(_touch))
	else:
		_apply_fps_cap(fps_cap)

	# Phase: push the config onto every scene-owned resource (environment, floor, car
	# materials, post-process) — all of it BEFORE any generation, so the first chunks bake
	# with the final lighting.
	_apply_scene_config(cfg)

	# Phase: lock and field the player's car.
	_field_player_car()

	await _generate_track(cfg, loading)
	_end_load_timing()
	# The real frame cap lands HERE, not inside _end_load_timing() — that function
	# early-returns on headless / no recorded stage, which would leave the loading cap
	# (possibly uncapped) in place for the whole session. See todo/mobile-web-performance.md §1.1.
	_apply_fps_cap(fps_cap)
	# Everything the load needed but the running game does not is freed here. MUST be
	# a separate unconditional call, NOT folded into _end_load_timing() — that function
	# early-returns under headless / with no recorded stage, so a hook inside it would
	# silently never fire for the test runner (and for any path that skipped _stage).
	# See todo/mobile-web-performance.md (shared "load finished" hook).
	_on_load_finished()

	# Phase: post-generation wiring — session signals, the pre-event start line, and the
	# between-event pit-repair popup. The only phase that still awaits.
	await _wire_session_and_stage(loading)

	# Phase: the diagnostic overlay, the pause menu arm, and benchmark mode.
	_build_overlays_and_benchmark()


# _ready phase: apply the central GameConfig to every scene-owned resource — environment,
# floor/terrain, the car materials, the post-process pass. Ordering inside here is
# load-bearing and commented at each step; nothing in it awaits.
func _apply_scene_config(cfg: GameConfig) -> void:
	var env: Environment = $WorldEnvironment.environment
	env.fog_density = cfg.fog_density
	env.background_color = cfg.background_color
	env.fog_light_color = cfg.background_color
	# How much the (now reduced) fog tints the sky. Low so the skybox reads clearly
	# above the distant haze; the panorama's own horizon + the fog colour (matched
	# to the sky horizon, see background_color) blend the terrain edge into the sky.
	env.fog_sky_affect = cfg.fog_sky_affect
	_apply_region_look()

	# Setting this property triggers a full terrain regeneration; skip when equal.
	if $Floor.texture_tile_per_meter != cfg.terrain_tile_per_meter:
		$Floor.texture_tile_per_meter = cfg.terrain_tile_per_meter
	# Road texture tiling, relative to the ground tiling baked into the UVs. The
	# shader samples the road texture at UV * road_uv_scale, so this is the ratio
	# of the two per-metre densities. Guard against a zero ground tiling.
	var road_uv_scale := 1.0
	if cfg.terrain_tile_per_meter > 0.0:
		road_uv_scale = cfg.road_tile_per_meter / cfg.terrain_tile_per_meter
	($Floor.chunk_material as ShaderMaterial).set_shader_parameter("road_uv_scale", road_uv_scale)
	# Flat tarmac fill colour (TODO: a real tarmac texture — todo/tarmac-texture.md). A
	# region may override it (Greece runs a brighter, sun-bleached tarmac); home / free
	# roam fall back to the GameConfig value.
	var tarmac_col: Color = _current_region_look().get("tarmac_color", cfg.tarmac_color)
	($Floor.chunk_material as ShaderMaterial).set_shader_parameter("tarmac_color", tarmac_col)
	# Ground albedo multiplier — RE-SEEDED from the authored baseline on every stage
	# boot, exactly as tarmac_color above is. This is load-bearing, not tidiness:
	# _apply_weather_look's _tint_road does a read-modify-write on this parameter, and
	# the material is a SHARED sub-resource of main.tscn (no resource_local_to_scene),
	# so without this line a wet stage's darkening would COMPOUND across stages
	# (0.75 → 0.56 → …) and leak into later dry ones. Re-seeding makes the tint
	# idempotent: every stage tints a clean base exactly once. Regression-tested by
	# test_render_smoke.gd::test_road_tint_is_idempotent_across_stages.
	($Floor.chunk_material as ShaderMaterial).set_shader_parameter(
		"albedo_color", _current_region_look().get("terrain_tint", cfg.terrain_tint))
	_apply_deep_snow_ground(cfg)
	# Terrain seed follows the per-event track_seed so each event has its own
	# landscape (and lake layout). The road DFS doesn't read terrain when water is
	# off, so this changes only the visible elevation for water-off events, not the
	# road shape or opponent times. (Setter invalidates the noise cache + rebuilds.)
	if $Floor.noise_seed != cfg.track_seed:
		$Floor.noise_seed = cfg.track_seed
	# Assigning layers triggers a full terrain regeneration; skip when equal.
	if not WorldRuntime.layers_match($Floor.layers, cfg.terrain_layers()):
		var layers: Array[TerrainLayer] = []
		for params in cfg.terrain_layers():
			var layer := TerrainLayer.new()
			layer.wavelength_m = params.x
			layer.amplitude_m = params.y
			layers.append(layer)
		$Floor.layers = layers
	# Baked terrain shading — push the sun/ambient + terrain amount BEFORE the
	# initial build (below) so it's folded into the first chunks' vertex colours.
	cfg.apply_terrain_light(_floor())
	# Weather look override (no-op on a dry stage). Layered AFTER _apply_region_look()
	# so rain wins over the region's clear-day palette, and after apply_terrain_light()
	# / the tarmac_color push above so it gets the last word on the ground shading —
	# still well before the initial terrain build in _generate_track(), so the darker
	# sun/ambient is what gets baked into the first chunks' vertex colours.
	_apply_weather_look(cfg)
	# Seed the headlight cone for the first frame (a no-op reset on a condition that
	# authors none), so the opening frame is already correct rather than dark for a tick.
	HeadlightCone.push(cfg, $Car.global_transform, $Car.half_width() * 2.0)
	# Terrain LOD tunables — also before the precompute (LOD meshes + skirt are
	# prebaked in cache_chunk) and the initial build.
	cfg.apply_terrain_lod(_floor())
	_mat($Car/Chassis).set_shader_parameter("albedo_color", cfg.chassis_color)
	_mat($Car/Cabin).set_shader_parameter("albedo_color", cfg.cabin_color)
	# Wheel materials are shared resources; setting each once covers all four.
	_mat($Car/WheelFL/Visual/Tire).set_shader_parameter("albedo_color", cfg.wheel_color)
	# Fake per-vertex lighting (PS1-style) on the car meshes, computed live in the
	# car shader because the car rotates (the terrain bakes the same look above).
	# The MX-5 body model is lit in car.gd's _apply_model_material when built.
	for car_mesh in [$Car/Chassis, $Car/Cabin, $Car/WheelFL/Visual/Tire]:
		cfg.apply_car_light(_mat(car_mesh))
	# PS1 dither/quantise grid + the colour grade, both pushed by apply_post_process
	# (shared with hq.gd, the other host of this pass, so the two can't grade the
	# game differently). Every target renders at the same authored resolution, so
	# the grid is pushed raw.
	cfg.apply_post_process($PostProcess.material as ShaderMaterial)


# _ready phase: hold the car still for the boot and field the right car for this mode
# (challenge / rally / free roam / dev boot). Nothing here awaits.
func _field_player_car() -> void:
	# Hold the car still for the entire boot. Generation below spans many awaited
	# frames with the loading overlay up (non-headless); the car is already in the
	# tree and physics-processing, so without this lock the player could press W and
	# drive off behind the loading screen. Set BEFORE the car is fielded so it's
	# inert the instant it exists (no fielding→lock gap). Every spawn path resets
	# controls_locked at the end of generation — StageManager.setup (locked for a
	# staged start line, unlocked otherwise) and BenchmarkRunner.setup — so this only
	# governs the loading window itself.
	$Car.controls_locked = true

	# Field the car. With an active RunSession this event runs the player's
	# OwnedCar (baseline + upgrades + saved HP); a plain dev boot keeps the first
	# library car (the Mazda MX-5). The career-rally session and free-roam handoff
	# that used to field a car here were deleted with RallySession
	# (todo/roguelike-pivot.md) — the roguelike run session (stage 3) is their
	# replacement.
	_car_spawn = $Car.transform  # authored spawn, reused so swaps don't drift
	if RunSession.is_active():
		_field_car(RunSession.car_instance_id())
	else:
		$Car.apply_car(0)
	# The bonnet camera is a scene child of $Car (not re-parented at boot), so
	# apply the newly-fielded car's per-car bonnet offset now — retarget() only
	# runs on a later car swap.
	($CameraManager as CameraManager).refresh_bonnet_offset()


# _ready phase, after generation: wire the stage/session signals, build the pre-event start
# line (staged runs only) and show the between-event pit-repair popup. Awaits, so the caller
# must await it — the frame it yields is the one that lets the fresh terrain render before the
# start-line queue is laid out, exactly as when this ran inline.
func _wire_session_and_stage(loading: LoadingScreen) -> void:
	# The stage finish is handled in EVERY mode: a session run reports the event to
	# the orchestrator; free roam / a dev boot has no session, so the finish panel's
	# Next returns to HQ instead (_on_session_event_completed's no-session branch).
	if _stage_manager != null and not _stage_manager.stage_completed.is_connected(_on_session_event_completed):
		_stage_manager.stage_completed.connect(_on_session_event_completed)
	# A session run additionally routes the run's finish onward. Only RunSession
	# survives as a session caller now — the career RallySession that used to share
	# this path is deleted (todo/roguelike-pivot.md); the roguelike RunSession (stage
	# 3) is the eventual second caller.
	if RunSession.is_active():
		_wire_session_signals()
		# Pre-event start-line scene: briefing + presence cars before the countdown
		# (todo/menus.md location 2). Only when staged (start_line_enabled + a real
		# challenge stage); the StageManager is already waiting in STAGING for
		# its launch.
		if _should_stage():
			# Let the freshly-built terrain render one frame before laying out the
			# start-line queue, so the cars are placed against the settled ground (and
			# the fielded car has dropped onto it) rather than mid-build. Skipped under
			# headless, where generation is synchronous and tests run within _ready.
			# The loading overlay (kept up by _generate_track for staged runs) hides
			# this frame, so the car is never seen at its pre-staged position.
			if not _headless:
				await get_tree().process_frame
			_build_start_line()
			loading.finish()
		# Between-event pit-repair popup: at the start of every event after the first,
		# the engineers have patched the fielded car up (Save.field_repair, already
		# applied before this reload). Shown AFTER the loading overlay is gone — staged
		# runs keep it up until _build_start_line + loading.finish() just above,
		# non-staged runs drop it inside _generate_track — so the popup sits over the
		# ready world / start-line reveal, not a frozen loading screen. Headless just
		# drains the summary so it can't replay on a later scene rebuild.
		# Only pop up for a repair that moved health by at least the min threshold — a
		# smaller touch-up (e.g. wheels-only on a near-full car) still applied to the
		# save, it just doesn't interrupt the player (RepairReveal.worth_showing).
		var repair: Dictionary = RunSession.take_pending_repair()
		if RepairReveal.worth_showing(repair) and not _headless:
			await _show_repair_popup(repair)


# _ready phase: the in-game diagnostic overlay, arming the pause menu now the world is ready,
# and benchmark mode's takeover. Nothing here awaits.
func _build_overlays_and_benchmark() -> void:
	# Diagnostic frame-profiler overlay (toggle with P). Created in code like the
	# wheel-force debug overlay; harmless and idle until toggled on. Render times
	# are measured on the PostProcess SubViewport — the viewport that actually
	# does the 3D work while main.tscn is up (the root's 3D pass is disabled).
	var perf := PerfOverlay.new(_floor())
	perf.measure_viewport = get_node_or_null("PostProcess/View") as Viewport
	perf.engine_audio = $Car.get_node_or_null("EngineAudio")  # live audio-overrun readout
	add_child(perf)

	# Pause-menu "Reset to track" delegates the reset up here (it has no car ref).
	var pause_menu := _pause_menu()
	if pause_menu != null:
		if not pause_menu.reset_to_track_requested.is_connected(_on_reset_to_track_requested):
			pause_menu.reset_to_track_requested.connect(_on_reset_to_track_requested)
		# Arm the pause menu now the world is generated — it's default-inert
		# (fail-closed) so the Pause button / Esc can't open it during the awaited
		# generation above, where pausing would freeze the tree mid-build and let the
		# player quit/resume into a half-built world. This block runs after
		# _generate_track in every mode (staged / free-roam / session; a regeneration
		# re-runs _ready), so it's the single "world is ready" chokepoint for pause.
		#
		# EXCEPT while the pre-countdown start line owns the screen. It is built ABOVE
		# (_build_start_line), so arming unconditionally here re-enabled the Pause button
		# it had just switched off — which is how a pause overlay ended up stacked over
		# the start line's own menu, the two fighting for the same taps. The start line's
		# own Exit is the way out until StartLine.sequence_finished re-arms pause at the
		# hand-off (_on_start_line_finished).
		pause_menu.set_input_enabled(not _start_line_is_staging())

	# Benchmark mode (features/benchmark.md): force the profiler on, hide the
	# touch controls (the HUD is already off via cfg.hud_enabled), and hand the
	# car to the auto-driving runner for the whole stage.
	if Benchmark.active:
		perf.activate()
		($MobileControls as CanvasLayer).visible = false
		var runner := BenchmarkRunner.new()
		runner.name = "BenchmarkRunner"
		add_child(runner)
		runner.setup($Car, _track_progress, _road_centerline,
			get_node_or_null("PostProcess/View") as Viewport, _floor())


# Yield a frame so a freshly-set LoadingScreen step actually paints before the
# next blocking generation call. A no-op under headless, where the await would
# otherwise spread world generation across frames and break tests that inspect
# the world right after instantiating main.tscn — there the whole _ready chain
# runs synchronously within add_child(), as it did before staged loading.
# Shared with overworld.gd — see WorldRuntime.yield_frame.
func _yield_frame() -> void:
	await WorldRuntime.yield_frame(get_tree(), _headless)


# Open a stage (closing the previous one into the perf log) and yield a frame so whatever
# just painted (the track preview, mainly) actually shows before the next blocking
# generation call. `label` is perf-log-only now — it is never shown to the player. The
# loading screen's visible line is a random LoadingTips pick, fixed for the whole load
# (see loading_screen.gd); the player doesn't need to know the game is "Placing signs…".
# Collapses to a synchronous no-op under headless (via _yield_frame), so tests still see a
# fully-built world.
func _stage(label: String) -> void:
	if not _headless:
		var now := Time.get_ticks_msec()
		if _stage_label != "":
			print("load stage: %-26s %5d ms" % [_stage_label, now - _stage_t0])
		else:
			_load_t0 = now
		_stage_label = label
		_stage_t0 = now
	await _yield_frame()


## Emitted once, after generation has finished and the final stage timing is closed.
## Subscribers free load-only data (baked terrain light, the road/cliff bake
## dictionaries) that nothing reads during play. Fires on EVERY path including
## headless, so tests can assert against it.
signal load_finished

# Emitted the moment the between-stage interstitial (RunPickPanel, or the plain
# Continue it falls back to) is dismissed — the player pressed a pick row or
# Continue. Only meaningful right after the run's FINAL stage: _on_run_finished
# awaits it (when the overlay was actually built — never headless) before returning
# to the hub, so the player has a chance to read the result rather than being
# ejected the instant report_event_result finishes. A no-op signal for every other
# beat (mid-run, nobody awaits it).
signal run_interstitial_dismissed


# Fire the shared "load finished" hook. Guarded so a second generation pass (a
# programmatic regeneration) can't double-free: subscribers may drop data that is
# expensive or impossible to rebuild mid-run.
func _on_load_finished() -> void:
	if _load_finished:
		return
	_load_finished = true
	load_finished.emit()


# Close the final stage and print the total. Called once generation is done.
func _end_load_timing() -> void:
	if _headless or _stage_label == "":
		return
	var now := Time.get_ticks_msec()
	print("load stage: %-26s %5d ms" % [_stage_label, now - _stage_t0])
	print("load total: %d ms" % (now - _load_t0))
	_stage_label = ""


# Shader/texture pre-warm (see the call site in _ready). Flies a throwaway camera
# along the whole built corridor while the loading cover is up, so every material's
# first-use GL program compile + texture upload happens now, not mid-drive. The
# SubViewport (PostProcessView) mirrors whatever camera is current, so making this
# one current renders each corridor view; the compiles are the slow frames we
# deliberately absorb here. Restores the gameplay camera when done. Runs on every
# platform (the stalls are worst on web but real on any GL-Compat first render); the
# call site already gates it behind the loading cover + non-headless, so it never
# runs in tests or where it could be seen.
func _prewarm_corridor() -> void:
	if _headless or _road_centerline == null:
		return
	var length := _road_centerline.get_baked_length()
	if length <= 0.0:
		return
	var floor_tm := _floor()
	var cam := Camera3D.new()
	cam.far = 400.0
	add_child(cam)
	var prev := get_viewport().get_camera_3d()
	cam.make_current()
	const STEPS := 14
	for s in STEPS + 1:
		var off := length * float(s) / float(STEPS)
		var p := _road_centerline.sample_baked(off)
		var ahead := _road_centerline.sample_baked(minf(off + 10.0, length))
		var y := (floor_tm.height_at(p.x, p.y) if floor_tm != null else 0.0) + 2.0
		var eye := Vector3(p.x, y, p.y)
		var look := Vector3(ahead.x, y, ahead.y)
		if eye.distance_to(look) > 0.05:
			cam.look_at_from_position(eye, look, Vector3.UP)
		# Two frames per waypoint so the SubViewport actually renders this view (the
		# first-use compiles land on these frames, behind the loading cover).
		await get_tree().process_frame
		await get_tree().process_frame
	cam.queue_free()
	# Restore the gameplay camera (CameraManager re-asserts the correct one).
	if has_node("CameraManager"):
		($CameraManager as CameraManager).activate_current()
	elif is_instance_valid(prev):
		prev.make_current()


# Get-or-create a named child: return the existing node with `node_name` if one is
# already present (so regenerating the world — entering a new event — reuses the
# node instead of stacking duplicates or colliding on name), otherwise build one
# via `factory`, name it, and add it. `factory` is a Callable returning a Node.
func _ensure_child(node_name: String, factory: Callable) -> Node:
	var existing := get_node_or_null(node_name)
	if existing != null:
		return existing
	var node: Node = factory.call()
	node.name = node_name
	add_child(node)
	return node


# Remove-and-free an existing child by name so an in-place regeneration REPLACES
# rather than stacks it. Unlike _ensure_child (which reuses the node), the caller
# then builds a fresh one — for nodes whose contents fully rebuild each event
# (spectator groups, the opponent wreck, the start/finish arches).
func _replace_named_child(node_name: String) -> void:
	var existing := get_node_or_null(node_name)
	if existing != null:
		remove_child(existing)
		existing.free()


# A point roughly 2 m in front of the active camera — where a warm-up instance is
# guaranteed to sit inside the frustum (so it actually draws and compiles its
# shader). The camera part is shared with overworld.gd (WorldRuntime.warm_up_point);
# the FALLBACK is deliberately kept here because the two hosts diverge — this scene
# owns an authored $Car, the overworld looks its car up by name.
func _warm_up_point() -> Vector3:
	var fallback := ($Car as Node3D).global_position if has_node("Car") else Vector3.ZERO
	return WorldRuntime.warm_up_point(get_viewport().get_camera_3d(), fallback)


# Paint the loading overlay's water preview for `bounds`, first expanding the rect to the
# preview's aspect so the cells aren't distorted. Returns the EXPANDED rect, which the
# caller must keep: the later refinement pass repaints into the same frame, and using a
# different rect would make the water visibly jump. Shared by the rough origin-box pass
# and the refined track-bounds pass, which were otherwise byte-identical.
func _paint_water_preview(loading: LoadingScreen, params: TrackGenParams,
		bounds: Rect2) -> Rect2:
	var rect := LoadingScreen.expand_to_aspect(bounds,
		LoadingScreen.aspect_of(loading.preview_size()))
	var cells: Array = LakeField.preview_cells(params, rect)
	loading.update_water(cells[0], cells[1], rect)
	return rect


# Is this an INTERACTIVE load — an overlay is up AND we're not headless? The one predicate
# the whole generation sequence keys off, defined ONCE here (it used to be re-spelled at each
# of eight sites, under three different local names) so the interactive and headless paths
# cannot drift apart. Headless keeps generation effectively synchronous, so tests still build
# the world within _ready.
func _interactive(loading: LoadingScreen) -> bool:
	return loading != null and not _headless


# Build the track from the car's spawn pose, bake road heights, and build the
# (deferred) terrain ring with flattening + colouring already applied — so no
# chunk is ever rebuilt at startup. Each heavy step sets the loading label and
# yields a frame first (outside headless) so the message paints before the
# blocking work runs; `loading` is freed once the world is ready.
#
# This function is the PHASE SEQUENCE only; each phase is a private coroutine below, named
# after the load-stage label it opens. Every phase is awaited in the order it used to run
# inline, and the car freeze/unfreeze straddles them exactly where it did before — the
# ordering and awaiting semantics are unchanged, only the nesting is.
func _generate_track(cfg: GameConfig, loading: LoadingScreen = null) -> void:
	# Suspend the car's physics for the whole generation window. controls_locked (set in
	# _ready) stops the PLAYER driving off, but the body itself is still simulating across
	# the hundreds of awaited frames below — and from here until build_initial() there is
	# deliberately NO terrain under it (TerrainManager._initial_pending keeps the ring out
	# of the loading frames so it can be built once, from the corridor cache). Frozen, the
	# car simply waits at its spawn pose and drops onto carved, flattened ground when the
	# ring exists. Previously it slid down UNFLATTENED on-demand terrain during the carve,
	# far enough to drag a whole extra chunk column into the ring.
	# Restore rather than hard-clear: a regeneration must not silently unfreeze a car some
	# other system parked.
	var car_body := $Car as RigidBody3D
	var was_frozen := car_body.freeze
	car_body.freeze = true

	# Phase 1 — "Generating track…": the road shape, the start pose, and the loading
	# screen's track/water preview.
	var shape := await _generate_centerline(cfg, loading)
	var result: Dictionary = shape["result"]
	var road_centerline := shape["road_centerline"] as Curve2D
	var finish_len: float = shape["finish_len"]
	var start_pos: Vector2 = shape["start_pos"]
	var start_heading: Vector2 = shape["start_heading"]
	var staged: bool = shape["staged"]

	# Phase 2 — "Carving road into terrain…": the road bake (flatten + surface split +
	# cliffs) and the final waterline pass it makes possible.
	await _carve_road_into_terrain(cfg, loading, road_centerline, shape["water_bounds"])

	# Phase 3 — "Precomputing chunks…" / "Building terrain…": every chunk the play area
	# realistically requests, then the initial ring built once from that cache.
	await _build_terrain_ring(loading, road_centerline)

	# Ground exists (carved, coloured, cache-built) — hand the car back to the physics
	# engine. Everything after this point still runs behind the loading cover, so it has
	# many frames to settle onto its wheels before the player or the start line sees it.
	car_body.freeze = was_frozen

	# Phase 4 — "Placing props…": everything that stands ON the built world (backdrop,
	# foliage, lakes, signs, barriers, spectators, arches, the wreck, the managers).
	await _place_world_props(cfg, result, road_centerline, finish_len,
		start_pos, start_heading, staged)

	# Phase 5 — "Warming shaders…": first-use shader compilation, absorbed behind the
	# loading cover. Interactive path only (see the function).
	await _warm_shaders_behind_cover(loading)

	# World is ready — drop the loading overlay (absent for direct/programmatic
	# regeneration, e.g. entering a rally event). Staged runs keep it up a moment
	# longer: _ready drops it only AFTER the start-line queue is laid out, so the
	# black overlay hides the car at its pre-staged spot instead of flashing it.
	if loading != null and not staged:
		loading.finish()


# Phase 1 of _generate_track. Generates the road centerline from the car's spawn pose and
# returns the shape contract the later phases read:
#   result, road_centerline, finish_len, start_pos, start_heading, staged, water_bounds.
func _generate_centerline(cfg: GameConfig, loading: LoadingScreen) -> Dictionary:
	await _stage("Generating track…")
	var xform: Transform3D = $Car.global_transform
	var start_pos := Vector2(xform.origin.x, xform.origin.z)
	# A Node3D's forward is -Z; project it onto the XZ plane.
	var fwd := -xform.basis.z
	var start_heading := Vector2(fwd.x, fwd.z).normalized()
	# Staged runs (the start-line sequence) force a straight lead-in around the start
	# line: generate the track from a point AHEAD so the leader has straight road to
	# drive off down, and prepend a straight stub BEHIND for the trailing car. The
	# lead-in corridor is RESERVED in the generator (reserve_behind_m below) so the
	# search can't loop the track back across it. Track SHAPE stays a function of
	# (seed, turn_count, width, reserve) only, so the opponents' target times — which
	# pass the same reserve at a canonical pose (RallySession._compute_event_targets)
	# — stay in sync.
	var staged := _should_stage()
	# The staged lead-in origin + reserved corridor now live in TrackGenParams
	# (seated from cfg.start_line_enabled), so both the run scene and the target
	# derivation get the identical origin. `staged` still gates the lead-in prepend.
	# Live preview: only when an overlay is up and we're not headless. Headless keeps
	# generation effectively synchronous (empty Callable -> the search never yields a
	# frame) so tests still build the world within _ready and test runtime is unchanged.
	# `interactive` is the one predicate the whole generation sequence keys off: an overlay
	# is up AND we're not headless. Resolved through the single _interactive() definition so
	# the interactive and headless paths cannot drift apart across the phases.
	var interactive := _interactive(loading)
	var on_progress := Callable()
	if interactive:
		on_progress = loading.update_track_preview
	# Build the shape contract. A challenge stage uses RunSession's rolled
	# TrackGenParams-shaped stage dict (spec §1/§4 — the seed comes from the period
	# hash, not a RallyLibrary event, but the dict shape TrackGenParams.for_event
	# reads is identical); a session-less run (dev boot, free roam) uses the live
	# cfg. The factory seats the staged origin from cfg and relocates it onto dry
	# ground if the start would be underwater. The career-rally arm that used to
	# read RallySession.current_event() here is deleted (todo/roguelike-pivot.md);
	# the roguelike run session (stage 3) is its replacement.
	var event := RunSession.current_stage_params() if RunSession.is_active() \
		else {}
	var params: TrackGenParams = TrackGenParams.for_event(event, cfg) if not event.is_empty() \
		else TrackGenParams.for_config(cfg)
	# The dry-start search may relocate the generation origin onto dry ground. Derive
	# the start-LINE pose from params (absolute, idempotent — never accumulates across
	# re-generation on a reused car) and seat the car + start_pos there. For a staged
	# run the start line sits one lead-in ahead behind the generation origin.
	var relocate := params.origin - params.base_origin
	if relocate != Vector2.ZERO:
		var start_line := params.origin
		if staged:
			start_line = params.origin - params.heading.normalized() * cfg.start_lead_in_ahead_m
		start_pos = start_line
		var car := $Car as Node3D
		car.global_position = Vector3(start_line.x, car.global_position.y, start_line.y)
	# Paint the waterline into the preview BEFORE generation — it's a pure function
	# of (seed, water_level), so it can show first and the road animates over it. This
	# early pass covers a rough box around the origin (the track extent isn't known
	# yet); it's refined to the true track bounds once generation completes (below).
	if cfg.water_enabled and interactive:
		var reach := clampf(float(params.turn_count) * 12.0, 200.0, 600.0)
		var box := Rect2(params.origin - Vector2(reach, reach), Vector2(reach, reach) * 2.0)
		_paint_water_preview(loading, params, box)
	# Rally events read the committed lockfile (falling back to live generation on a
	# miss, loudly — every event key IS baked). The for_config path (benchmark boot,
	# default-config boot, free roam) consults the same lockfile but treats a miss as
	# normal: free roam randomises seed/water/relief per entry, so it always misses and
	# live-generates exactly as before. See todo/mobile-web-performance.md §2.6.
	var result: Dictionary
	if not event.is_empty():
		result = await TrackGenerator.generate_cached(params, cfg, on_progress)
	else:
		result = await TrackGenerator.generate_optional_cached(params, cfg, on_progress)
	# A challenge stage's seed is rolled blind (ChallengeLibrary.stages_for), unlike a
	# rally's — every authored RALLIES seed is hand-verified to route before it ships,
	# via the committed lockfile. TrackGenerator.generate already retries MAX_RESTARTS
	# times internally with strided seeds, but a genuinely hard (turn_count, reserved-
	# corridor) combination can still exhaust all of them and return an INCOMPLETE
	# (near-empty) result — the empty-terrain bug this guards against. Deterministically
	# bump the seed and regenerate a few more times: every client hits the exact same
	# failure on the exact same period key, so retrying with the SAME bumped-seed
	# sequence keeps the "identical stage for every player" contract intact — it just
	# means the odd unlucky roll silently becomes a different (still period-deterministic)
	# seed instead of an unplayable stage. A REGION RUN's stages are excluded: they are
	# AUTHORED events whose seeds are already lockfile-verified, so a genuine live
	# miss/incomplete there is a data bug worth surfacing loudly, not routing around.
	if RunSession.is_active() and RunSession.mode_id() == RunMode.CHALLENGE \
			and not bool(result.get("complete", false)):
		var retry_event := event.duplicate()
		var base_seed := int(event.get("seed", params.seed))
		for attempt in range(1, 4):
			retry_event["seed"] = base_seed + attempt * 104729  # a large prime stride
			var retry_params := TrackGenParams.for_event(retry_event, cfg)
			var retry_result: Dictionary = await TrackGenerator.generate(retry_params, on_progress)
			if bool(retry_result.get("complete", false)):
				result = retry_result
				params = retry_params
				break
		if not bool(result.get("complete", false)):
			push_error("Challenge stage generation failed after retries (period=%s stage seed=%d turn_count=%d) — falling back to whatever partial track was found" \
				% [RunSession.period_key(), base_seed, params.turn_count])
	# Same gradient profile the rival grid was solved against (RallySession
	# ._generate_event_tracks). It must be attached HERE too, because this live result —
	# not the one the grid used — is what feeds the "vs P1" split table and the rival
	# ghost's pace solve. Attach it in one place only and the ghost would be re-solving a
	# flat road to hit a time that was set on a hilly one, and drift.
	#
	# Keyed off `cfg`, matching $Floor above (seeded from cfg.track_seed), so this is the
	# terrain the player actually drives even on a challenge stage whose seed was bumped.
	result["road_height"] = TerrainNoise.make_sampler(cfg.track_seed, cfg.terrain_layers())
	# THE STAGE'S CLOCK (todo/roguelike-pivot.md decisions 4 and 11). The target is a
	# LapTimeModel solve over the track that was ACTUALLY generated — including the
	# gradient sampler attached on the line above, so the clock is set on the same hilly
	# road the player drives — against CarPerformance.REFERENCE_CAR, so it is a property
	# of the STAGE and identical for every player and every car. This is the only place
	# it can be seated: the result dict exists nowhere else. A challenge stage gets 0
	# back (no target, nothing to fail).
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(result)
	# Reconcile the live config to the waterline generation ACTUALLY used. `params` is
	# the single source of truth for water: TrackGenParams.recompute_origin can clamp
	# water_level down (or switch water_enabled off entirely) when no dry start exists
	# within budget, and that adjustment never reaches cfg on its own. Everything
	# downstream reads cfg — the rendered/collided lake (_build_lakes), the chase
	# camera's ground seat, the submersion reset in track_progress.gd — so without this
	# they'd all use a waterline the terrain doesn't have: the lake and the loading
	# preview disagree, and the camera detaches from the chase view over a basin it
	# wrongly believes is flooded. Must sit after the challenge retry above, which can
	# swap in a differently-clamped `params`.
	cfg.water_enabled = params.water_enabled
	cfg.track_water_level_m = params.water_level
	# Lock the finished shape so the held line is exact (not a mid-backtrack snapshot);
	# it stays drawn through the remaining stages until finish().
	if interactive:
		loading.update_track_preview((result["centerline"] as Curve2D).tessellate())
	# Road/progress centerline (with the lead-in for staged runs). The raw generated
	# centerline still feeds the signs, so the start gate sits ahead of the launch
	# point — the cars cross it as they pull away.
	var road_centerline := result["centerline"] as Curve2D
	# Refine the preview water to the ACTUAL track bounds now they're known, so it
	# spans the whole stage instead of the rough origin box (no more box-edge clip).
	# Held for the FINAL water pass after the bake (below) so it reuses the exact same
	# frame — repainting into a different rect would make the water jump.
	var water_bounds := Rect2()
	if cfg.water_enabled and interactive:
		var tb := LoadingScreen.bounds_of((result["centerline"] as Curve2D).tessellate()).grow(80.0)
		water_bounds = _paint_water_preview(loading, params, tb)
	if staged:
		road_centerline = _with_start_lead_in(road_centerline, start_pos, start_heading, cfg)
	# The FINISH is the END of the generated track (plus lead-in) — capture its arc
	# length BEFORE appending the runoff, so the arch and 100% progress anchor here.
	var finish_len := road_centerline.get_baked_length()
	# Append the post-finish runoff straight (features/track.md) to the RENDERED road so
	# the car has room to skid to a stop past the arch. It's baked into the terrain +
	# road-marked like the rest; the finish stays at finish_len (see below).
	road_centerline = _with_finish_runoff(road_centerline, result["runoff"])
	return {
		"result": result,
		"road_centerline": road_centerline,
		"finish_len": finish_len,
		"start_pos": start_pos,
		"start_heading": start_heading,
		"staged": staged,
		"water_bounds": water_bounds,
	}


# Phase 2 of _generate_track: bake the road into the terrain (flatten + surface split +
# cliffs) — the heaviest single step — then repaint the loading preview's waterline now that
# the bake makes a correct one possible.
func _carve_road_into_terrain(cfg: GameConfig, loading: LoadingScreen,
		road_centerline: Curve2D, water_bounds: Rect2) -> void:
	var interactive := _interactive(loading)
	# Road band + surface split, derived in the one place every baker shares
	# (TerrainManager.bake_args) so the Seed Lab's preview bake can't drift from this
	# one. Surface split: the track runs gravel + tarmac with one switch, the tarmac
	# share = track_tarmac_fraction (set per rally event). Which surface it opens on
	# is seeded off track_seed so it's deterministic but varied across events.
	var bake_args := TerrainManager.bake_args(cfg)
	# Cliff params onto the terrain before the bake reads them (mirrors the Lighting
	# group applied earlier); the cliff pass runs inside set_track → bake_track.
	cfg.apply_cliffs(_floor())
	# Baking the road into the terrain (flatten + surface split + cliffs) is the heaviest
	# single step; give it its own label and let it yield frames (interactive path only —
	# should_yield stays false under headless) so the overlay keeps painting, not freezing.
	await _stage("Carving road into terrain…")
	# Interactive path: the grey track-preview line fills white as the bake walks the
	# centerline (carve progress); headless passes empty callbacks and stays synchronous.
	var carve_progress := loading.set_carve_progress if interactive else Callable()
	await $Floor.set_track(road_centerline, bake_args[0], bake_args[1],
		bake_args[2], bake_args[3], bake_args[4],
		interactive, carve_progress)
	if interactive:
		loading.set_carve_progress(1.0)  # snap to fully-white once carving is done
	# FINAL water pass — the only one that can be right, and it lands HERE, straight
	# after the carve and before the long chunk precompute, so the true waterline is
	# on screen for most of the load rather than flashing up at the end.
	#
	# The two passes above sample params.water_sampler (pure noise), because that is
	# all that exists before set_track → bake_track: the road flatten and the CLIFF
	# offsets are baked by it. Cliff offsets are signed, so a stage with real
	# cliffiness drops far more ground below the waterline than the noise predicts
	# (worst where a high coastal waterline meets high cliffiness — the Sh*tbox Cup
	# shows it plainly), and the preview read far drier than the driven world.
	#
	# Samples baked_height_at, NOT height_at: the chunk cache is still empty at this
	# point, so height_at would fall back to pure noise and repaint the same wrong
	# picture. baked_height_at reads the bake fields directly and is the same height
	# the real lake is built against in _build_lakes.
	if cfg.water_enabled and interactive and water_bounds.has_area():
		var baked: Array = LakeField.preview_cells_for(
			_floor().baked_height_at, cfg.track_water_level_m, water_bounds)
		loading.update_water(baked[0], baked[1], water_bounds)
	# Retained for post-build consumers outside this call (the benchmark runner
	# follows the same road the progress manager measures).
	_road_centerline = road_centerline


# Phase 3 of _generate_track: precompute the corridor chunks, then build the initial terrain
# ring once from that cache (so no chunk is ever rebuilt at startup).
func _build_terrain_ring(loading: LoadingScreen,
		road_centerline: Curve2D) -> void:
	var interactive := _interactive(loading)
	# Precompute every chunk the play area realistically requests (the track-progress
	# leash sizes it), so in-run chunk loads are instant cache pulls and
	# height_at/light_at serve the flattened, collidable terrain. Batched with
	# frame awaits so the loading label paints and (on web) the tab stays alive.
	await _stage("Precomputing chunks…")
	var floor_tm := _floor()
	floor_tm.set_corridor(floor_tm.corridor_coords(
		road_centerline, Config.data.track_progress_max_dist_m))
	# Feed loaded chunks to the loading preview (interactive path only): each cached
	# chunk becomes a dark square behind the track line, drawn in the same world-XZ
	# frame (coord * CHUNK_M = its world min-corner). Batched on the existing yield.
	if interactive:
		loading.set_chunk_size(TerrainManager.CHUNK_M)
	var chunk_corners := PackedVector2Array()
	var precompute_done := 0
	for coord in floor_tm.corridor():
		floor_tm.cache_chunk(coord)
		if interactive:
			chunk_corners.append(Vector2(coord.x, coord.y) * TerrainManager.CHUNK_M)
		precompute_done += 1
		if precompute_done % 8 == 0:
			if interactive:
				loading.update_loaded_chunks(chunk_corners)
			await _yield_frame()
	if interactive:
		loading.update_loaded_chunks(chunk_corners)  # final batch (loop count not a multiple of 8)
	# PEAK, not resident: this prints while generation is still running, so it counts the
	# baked `lights` array that TerrainManager.free_load_only_data() drops moments later on
	# world's load_finished signal. The resident figure after that free is substantially
	# lower — see features/terrain.md -> "What the cache keeps — and what is freed".
	# cache_size_mb() also sums only Packed*Array values, so it excludes the prebaked
	# lod_meshes (GPU-side) entirely.
	print("terrain precompute: %d chunks, %.1f MB cached (peak, pre-free)"
		% [precompute_done, floor_tm.cache_size_mb()])

	await _stage("Building terrain…")
	$Floor.build_initial()
	# The car is handed back to the physics engine by the caller, immediately after this
	# phase returns — the freeze is owned by _generate_track, which took it.


# Phase 4 of _generate_track ("Placing props…"): everything that stands ON the finished
# terrain. Runs in the same order it ran inline — backdrop, foliage, lakes, signs, barriers,
# then the props stage (spectators, arches, the opponent wreck, the persistent managers).
func _place_world_props(cfg: GameConfig, result: Dictionary, road_centerline: Curve2D,
		finish_len: float, start_pos: Vector2, start_heading: Vector2, staged: bool) -> void:
	var floor_tm := _floor()
	# Static coarse backdrop over the whole reachable play area + margin, so the
	# reduced fog reveals a horizon instead of the detail ring's edge. Built ONCE
	# behind the loading screen; never rebuilds (the play area is bounded).
	if cfg.distant_terrain_enabled and _distant_terrain == null:
		_distant_terrain = DistantTerrain.new()
		_distant_terrain.name = "DistantTerrain"
		_distant_terrain.cell_m = cfg.distant_terrain_cell_m
		_distant_terrain.sink_m = cfg.distant_terrain_sink_m
		add_child(_distant_terrain)
		_distant_terrain.build_static(floor_tm,
			floor_tm.corridor_bounds().grow(cfg.distant_terrain_radius_m))

	# Trees + ground-cover bushes (+ the pass-through bush hit volume). Returns the
	# tree points and road-margin cells the spectator layout reuses.
	var foliage := await _build_foliage(cfg, result, road_centerline)

	# Lakes: flood the natural basins beside the road below the water level. The
	# track DFS already routed the road above water; road cells are excluded here
	# too as a coarse guard. The car gets soft-hazard drag over any lake.
	if cfg.water_enabled:
		await _build_lakes(cfg)

	# Roadside turn-arrow signs along the stage.
	if cfg.signs_enabled:
		await _build_signs(cfg, result)

	# Solid crash barriers along the outside of the sharp corners. After the road
	# bake, which is what makes the surface split (gravel vs tarmac) readable — the
	# barrier style follows it.
	if cfg.barriers_enabled:
		_build_barriers(cfg, result)

	# Stage coins (decisions 13, 35, 36, 50) — a REGION-RUN mechanic only. Placed
	# off the road so a pickup costs time against the clock; see _build_coins.
	if cfg.coins_enabled:
		_build_coins(cfg, road_centerline, finish_len)

	# Everything from here to the pre-warm used to be billed to the PREVIOUS stage
	# label ("Placing signs"), because _stage() only closes a stage when the NEXT one
	# opens and _end_load_timing() runs after _generate_track returns. That made signs
	# look like a 6-second stage when a stage has only ~16-22 of them; the real cost
	# was the props + shader pre-warm below. See todo/mobile-web-performance.md item 1.2.
	await _stage("Placing props…")

	# Roadside spectators: crowds that react to the car (todo/roadside-spectators.md).
	# One group at the start, one at the end, and one at a seeded mid-stage point.
	# Built after trees so members can avoid spawning inside foliage; reuses the
	# centerline, road_cells and terrain built above.
	if cfg.spectators_enabled and cfg.spectator_group_size > 0:
		_spawn_spectators(road_centerline, foliage["road_cells"], foliage["trees"],
			start_pos, start_heading, cfg, _floor(), finish_len)

	# Finish + start inflatable arches straddling the road.
	_build_arches(road_centerline, finish_len, start_pos, start_heading, cfg)

	# The roadside opponent wreck used to be staged here — deleted with the rival
	# field it dramatized (todo/roguelike-pivot.md decision 5).

	# Persistent per-stage managers (progress, tire marks, road paint, wheel dust,
	# engine smoke, stage flow).
	_build_persistent_managers(cfg, result, road_centerline, finish_len, staged)


# Phase 5 of _generate_track ("Warming shaders…"): absorb first-use shader compilation while
# the loading overlay still covers the view.
func _warm_shaders_behind_cover(loading: LoadingScreen) -> void:
	var interactive := _interactive(loading)
	# Prime the surface-effect shaders while the loading overlay still covers the
	# view. Under gl_compatibility a material's shader variant compiles on its first
	# VISIBLE draw; the particle pools sit off-screen (HIDE_Y) and the tyre-mark
	# ribbons are empty until first used, so without this the first gravel wheelspin
	# (or first skid / misfire) pays a one-frame compile hitch. Draw one throwaway
	# instance of each in front of the camera for a rendered frame, then clear it.
	# Only when a loading screen is up: on a bare regeneration the variants are
	# already cached (identical renderer settings) and there's no overlay to hide
	# the flash.
	if interactive:
		# Own stage label: the pre-warm is 30 rendered frames of first-use shader
		# compilation and is a real multi-second cost on web, but it was previously
		# invisible — folded into whichever label happened to be open. Item 1.2.
		await _stage("Warming shaders…")
		var wp := _warm_up_point()
		# Auto-discover every node implementing the warm_up()/clear_warm_up() contract
		# (surface-FX pools, tyre marks, the spectator ragdoll variant, and anything
		# added later) instead of a hardcoded list — so a new effect is primed for free
		# just by implementing the contract, never silently omitted. Each warm_up(pos)
		# draws one throwaway instance THROUGH ITS REAL DRAW PATH (so the correct
		# gl_compatibility program variant compiles), cleared after the rendered frame.
		# See features/rendering.md → "Shader pre-warm".
		var warmers := find_children("*", "Node", true, false).filter(
			func(n: Node) -> bool: return n.has_method("warm_up") and n.has_method("clear_warm_up"))
		for n in warmers:
			n.warm_up(wp)
		await get_tree().process_frame
		for n in warmers:
			n.clear_warm_up()
		# Corridor pre-warm: fly a throwaway camera along the whole built road so every
		# static material along it compiles its gl_compatibility program now. MUST run
		# here — behind the loading cover — not after _generate_track returns: non-staged
		# runs (benchmark / free-roam) drop the overlay below, so a later fly would be
		# visible as the camera jumping around. See features/rendering.md.
		await _prewarm_corridor()


# Below-water cell CENTRES + the sample step, over `bounds` (world XZ), for the
# loading preview. Uses the params' pure water sampler (no track/terrain needed).
# The step adapts so a large region stays ~cheap and the drawn squares still tile.
# Returns [PackedVector2Array cells, float step].
# Drop any XZ points whose terrain sits at/below the water level, so scattered
# props (trees, bushes, spectators) never spawn in a lake. No-op when water is off.
func _drop_submerged(points: PackedVector2Array, cfg: GameConfig) -> PackedVector2Array:
	if not cfg.water_enabled:
		return points
	var tm := _floor()
	var out := PackedVector2Array()
	for p in points:
		if tm.height_at(p.x, p.y) > cfg.track_water_level_m:
			out.append(p)
	return out


func _build_lakes(cfg: GameConfig) -> void:
	await _stage("Filling lakes…")
	var floor_tm := _floor()
	# One big flat plane at the water level; terrain above it occludes it via the
	# depth test, so no per-lake geometry or flood-fill is needed (features/lakes.md).
	var lake := LakeField.new()
	lake.name = "LakeField"
	add_child(lake)
	lake.build(cfg.track_water_level_m, cfg)
	# Soft-hazard query: the car is in water wherever the ground under it is
	# submerged (terrain below the water level).
	var wl := cfg.track_water_level_m
	if has_node("Car"):
		# NOT wired on a frozen stage: the water query exists to apply water_drag, and
		# a car sliding across ice is not wading through anything. The ice is a solid
		# surface with its own (very low) grip instead — LakeField._add_ice_collider and
		# Drivetrain.surface_tire_params. Leaving it wired would drag the car down on a
		# surface it is supposed to slide across, which is the opposite of the feature.
		if cfg.frozen_water_grip > 0.0:
			($Car as Node).call("set_water_query", Callable())
		else:
			($Car as Node).call("set_water_query",
				func(p: Vector3) -> bool: return floor_tm.height_at(p.x, p.z) < wl)
	# The loading preview already painted the waterline up-front (before generation,
	# see _generate_track → LakeField.preview_cells), so nothing to feed here.


# Scatter trees + ground-cover bushes around the stage and render both as binned
# MultiMesh fields (TreeMeshField), plus the pass-through bush hit volume. Takes the
# already-generated track `result` + rendered `road_centerline`; owns the two
# loading steps. Returns {"trees", "road_cells"} — the tree points and road-margin
# cells the spectator layout reuses.
# The road-rejection cell set every scatter pass rejects against: the VISIBLE road
# footprint (track_width) widened by tree_road_margin_m, plus `mesh_radius` for a pass
# whose prop is wide enough to overhang its own centre point (bushes, rocks). Rasterised
# from `road_poly`, the ONCE-tessellated centreline — each pass used to re-tessellate the
# whole curve for itself, which is a stage-length polyline built and thrown away per pass.
#
# Deliberately NOT the clearance-inflated result["cells"] (track_width + 2*track_clearance),
# which would push every prop metres back from the real road edge.
func _road_cells(cfg: GameConfig, road_poly: PackedVector2Array,
		mesh_radius := 0.0) -> Dictionary:
	return TrackGenerator.rasterize_cells(
		road_poly, cfg.track_width + 2.0 * (cfg.tree_road_margin_m + mesh_radius))


func _build_foliage(cfg: GameConfig, result: Dictionary, road_centerline: Curve2D) -> Dictionary:
	if not cfg.vegetation_enabled:
		# Foliage off (the benchmark's vegetation toggle): skip the scatter and the
		# fields entirely, but still hand the spectator layout the road-margin cells
		# it needs to keep crowds off the carriageway.
		var bare_cells := _road_cells(cfg, road_centerline.tessellate())
		return {"trees": PackedVector2Array(), "road_cells": bare_cells}
	await _stage("Scattering trees…")
	# Tessellated ONCE and shared by every pass below (trees, bushes, rocks).
	var road_poly := road_centerline.tessellate()
	# Scatter trees around each turn, then render them as solid low-poly meshes
	# binned into per-cell MultiMeshes (TreeMeshField) so the engine LOD-/cull-s
	# far bins. height_at needs the terrain noise cache, which build_initial() has
	# warmed. Reject trees on the visible road inflated by tree_road_margin_m —
	# NOT the clearance-inflated result["cells"], which is track_width +
	# 2*track_clearance wide and would push every tree metres back from the real
	# road edge. The margin keeps a small, tunable gap between trees and the road.
	var road_cells := _road_cells(cfg, road_poly)
	# Trees are gated by the per-event forest noise (cfg.track_forestiness): they only
	# spawn inside the forest patches, breaking up the otherwise-continuous tree line.
	var trees := TreeScatter.scatter(result["pieces"], road_cells, cfg.tree_params(),
		cfg.track_seed, cfg.track_forestiness, cfg.forest_wavelength_m)
	trees = _drop_submerged(trees, cfg)  # keep trees out of the lakes
	# Trees render as opaque billboards — the shared mesh/material lives in Foliage so
	# every scene matches. Stage trees collide (they're obstacles). The region defines
	# its tree species SPLIT (tree_mix: weighted {texture, profile} entries); we split
	# the scattered points by weight and spawn one billboard field per species, each at
	# its own sizing profile. Home is 100% tree.png; Greece is 70/30 (see regions.md).
	var region_look := _current_region_look()
	var mix := RegionLibrary.tree_mix(region_look)
	var weights: Array = []
	for entry in mix:
		weights.append(entry.get("weight", 1.0))
	var tree_groups := TreeScatter.partition_by_weight(trees, weights, cfg.track_seed)
	for i in range(mix.size()):
		var entry: Dictionary = mix[i]
		Foliage.spawn_trees(self, tree_groups[i], _floor(), true,
			cfg.tree_render_distance_m, cfg.tree_render_fade_m,
			load(entry["texture"]), String(entry.get("profile", "home")) == "region",
			entry.get("size_scale", Vector2.ONE))

	await _build_rocks(cfg, result, road_poly, region_look)

	# The region also defines whether the 3D ground-cover bushes spawn (spawn_bush_mesh —
	# e.g. Greece's arid map has no lush undergrowth); skip the whole bush pass if off.
	#
	# NOTE the rock pass runs ABOVE this early return, not below it. The two regions that
	# switch bushes off (Greece, the Alps) are exactly the two that author a non-default
	# rock density, and Greece wants the MOST rocks in the game — folding rocks in below
	# here would silently give both of them none.
	if not RegionLibrary.spawns_bush_mesh(region_look):
		return {"trees": trees, "road_cells": road_cells}

	await _stage("Scattering bushes…")
	# Bushes: same scatter as trees (offset seed so they interleave; NOT forest-gated,
	# default forestiness 1.0 so undergrowth covers the whole stage) and the SAME
	# renderer (TreeMeshField) — the low-poly ground-cover mesh, binned with per-bin
	# LOD/visibility cull like the trees, but with NO collision and per-instance baked
	# terrain light so it matches the ground. See features/trees.md.
	#
	# The bush mesh is a WIDE patch, so reject it on a road footprint inflated by the
	# bush's own world-space radius (on top of tree_road_margin_m) — that keeps the
	# bush CENTRE far enough out that no part of the scaled mesh spills onto the road,
	# at any per-instance yaw.
	var bush_radius := TreeMeshField.xz_radius(Foliage.bush_mesh(), cfg.bush_height_m)
	var bush_road_cells := _road_cells(cfg, road_poly, bush_radius)
	var bushes := TreeScatter.scatter(result["pieces"], bush_road_cells, cfg.tree_params(),
		cfg.track_seed + BUSH_SEED_OFFSET)
	bushes = _drop_submerged(bushes, cfg)  # keep bushes out of the lakes
	Foliage.spawn_bushes(self, bushes, _floor(),
		cfg.tree_render_distance_m, cfg.tree_render_fade_m)

	# Bushes are pass-through (no collider), so a separate proximity node makes
	# brushing one cost HP + apply a drag torque. Hit radius is slightly under the
	# bush's visual width (bush_hit_radius_frac) so clipping the edge is forgiven.
	var bush_interaction := BushField.new()
	bush_interaction.name = "BushInteraction"
	add_child(bush_interaction)
	bush_interaction.setup(bushes, $Car,
		bush_radius * cfg.bush_hit_radius_frac,
		cfg.bush_drag_strength, cfg.bush_drag_torque,
		cfg.bush_min_speed_kmh / DamageModel.MPS_TO_KMH)

	return {"trees": trees, "road_cells": road_cells}


# Roadside boulders: low-poly Kenney meshes scattered like the bushes but WITH
# collision, so hitting one costs the car. Density is the one thing the region varies
# (RegionLibrary.rock_density — Greece stoniest, the Alps sparsest, everywhere else the
# middle); the models, colours and hitboxes are shared, so a boulder reads the same
# wherever you meet it. See features/rocks.md.
#
# Rocks are NOT forest-gated (no forestiness argument): stone is not vegetation, and
# gating it on the tree noise would put boulders only where the trees are.
func _build_rocks(cfg: GameConfig, result: Dictionary, road_poly: PackedVector2Array,
		region_look: Dictionary) -> void:
	var density := RegionLibrary.rock_density(region_look)
	if not cfg.rocks_enabled or density <= 0.0 or cfg.rock_groups_per_turn <= 0.0:
		return
	await _stage("Scattering rocks…")
	# Widest species' radius sets the road margin for ALL of them — one rejection pass,
	# and no species can spill onto the carriageway at any per-instance yaw. Same
	# reasoning as the bush footprint above, which is why it reuses tree_road_margin_m.
	var widest := 0.0
	for i in range(Foliage.ROCK_SCENES.size()):
		widest = maxf(widest, TreeMeshField.xz_radius(
			Foliage.rock_mesh(i), Foliage.rock_height(i)))
	var rock_road_cells := _road_cells(cfg, road_poly, widest)
	# The scatter places GROUP ANCHORS, not rocks: boulders read as outcrops that shed a
	# few stones together rather than as evenly-spaced individuals, so each anchor is
	# fanned out into a small cluster below.
	var anchors := TreeScatter.scatter(result["pieces"], rock_road_cells,
		cfg.rock_params(density), cfg.track_seed + ROCK_SEED_OFFSET)
	# cluster() re-rejects the companions against the same road cells: only the ANCHORS
	# were tested above, and fanning out can push a companion back onto the carriageway.
	var rocks := TreeScatter.cluster(anchors, cfg.rock_group_min, cfg.rock_group_max,
		cfg.rock_group_radius_m, cfg.track_seed + ROCK_SEED_OFFSET, rock_road_cells)
	rocks = _drop_submerged(rocks, cfg)  # keep rocks out of the lakes
	if rocks.is_empty():
		return
	# One field per species, splitting the scattered points evenly between them — the
	# same shape as the tree mix, but with equal weights, because the three rocks are
	# variety rather than a designed ratio. Each field is its own binned MultiMesh, so
	# this is three draw calls per bin rather than one; that is affordable precisely
	# because rock_groups_per_turn is a fraction of trees_per_turn.
	var weights: Array = []
	weights.resize(Foliage.ROCK_SCENES.size())
	weights.fill(1.0)
	var groups := TreeScatter.partition_by_weight(rocks, weights,
		cfg.track_seed + ROCK_SEED_OFFSET)
	for i in range(Foliage.ROCK_SCENES.size()):
		# A species can legitimately draw no points — a sparse region, a short stage, or
		# the road/lake rejection taking the few it had. Skip it rather than adding an
		# empty field: a bin-less foliage field is what test_smoke's "each foliage field
		# has at least one bin" invariant exists to catch, and an empty node is pure cost.
		if groups[i].is_empty():
			continue
		var field := Foliage.spawn_rocks(self, groups[i], _floor(), i, true,
			cfg.tree_render_distance_m, cfg.tree_render_fade_m)
		field.name = "Rocks%d" % i


# Roadside turn-arrow signs along the stage (todo/roadside-signs.md). Few per stage,
# so individual nodes (not a MultiMesh); knockable cosmetic props that deal no HP
# damage. Start/finish are the inflatable arches, not signs. Owns its loading step.
func _build_signs(cfg: GameConfig, result: Dictionary) -> void:
	await _stage("Placing signs…")
	var sign_layout := SignLayout.plan(result["centerline"], result["pieces"])
	var sign_field := SignField.new()
	add_child(sign_field)
	sign_field.build(sign_layout, _floor(), cfg.sign_render_params())


# Solid crash barriers along the OUTSIDE of the stage's sharp corners
# (features/barriers.md). Runs of 2 m modules, stitched end to end; the look follows
# the road surface under each module — armco on gravel, concrete jersey on tarmac —
# which is why this runs after the road bake, the pass that fills in the surface
# split. Shares the "Placing signs…" step (a handful of runs; no yield needed).
func _build_barriers(cfg: GameConfig, result: Dictionary) -> void:
	var terrain := _floor()
	# The road's tarmac-ness at a centerline point, straight off the baked terrain, so
	# the barrier can't drift from the surface the player actually drives on.
	var tarmac_at := func(p: Vector2) -> float:
		return terrain.surface_at(p.x, p.y).y
	# The carved terrain the player actually drives on and collides with (road flatten
	# and cliff offsets included). The planner reads it to tell a drop from a bank, and
	# the builder to pitch each module onto the slope.
	var ground_at := func(p: Vector2) -> float:
		return terrain.height_at(p.x, p.y)
	var params := cfg.barrier_render_params()
	var layout := BarrierLayout.plan(result["centerline"], result["pieces"], params,
		tarmac_at, ground_at)
	if layout.is_empty():
		return
	# Replace rather than stack, like the arches — the barriers rebuild wholesale for
	# whatever track is current.
	_replace_named_child("BarrierField")
	var field := BarrierField.new()
	field.name = "BarrierField"
	add_child(field)
	field.build(layout, params, ground_at)


# Stage coins (features/collectables.md, todo/roguelike-pivot.md decisions 13, 35,
# 36, 50). A REGION-RUN mechanic only — mirrors the RunMode.CHALLENGE check above
# (_generate_centerline) for the opposite case: a challenge has no per-stage money to
# boost and no fail state to gamble against, so nothing is placed for it.
#
# Seeded off `cfg.track_seed + COIN_SEED_OFFSET` — the SAME per-stage seed every
# other scattered prop derives from, which is what makes a resumed run reproduce the
# identical layout (a resume redraws the same event from RegionStagePool, which
# carries the same authored `seed`, which becomes track_seed again).
func _build_coins(cfg: GameConfig, road_centerline: Curve2D, finish_len: float) -> void:
	_coin_field = null
	if not RunSession.is_active() or RunSession.mode_id() != RunMode.REGION:
		return
	var seed_value := cfg.track_seed + COIN_SEED_OFFSET
	var layout := CoinLayout.plan(road_centerline, finish_len, cfg.track_width,
		seed_value, cfg.coin_layout_params())
	if layout.is_empty():
		return
	_replace_named_child("CoinField")
	var field := CoinField.new()
	field.name = "CoinField"
	add_child(field)
	field.build(layout, _floor(), $Car, cfg.coin_render_params())
	field.coin_collected.connect(_on_coin_collected)
	_coin_field = field
	var hud_node := $HUD
	hud_node.set_coin_count(0)


# Live "coins taken this stage" HUD readout, on every pickup (CoinField.coin_collected).
func _on_coin_collected(_index: int, total_collected: int) -> void:
	var hud_node := $HUD
	hud_node.set_coin_count(total_collected)


# Finish + start arches: the inflatable gates straddling the road
# (features/finish-arch.md). The FINISH gate sits at the END of the progress
# centerline — i.e. exactly 100% track progress — so crossing it ends the stage
# immediately; the START gate sits at the start line where the car actually spawns.
# Each opening is sized to the road width plus a margin so the legs stand clear, and
# each is turned so its banner face meets the driver.
func _build_arches(road_centerline: Curve2D, finish_len: float,
		start_pos: Vector2, start_heading: Vector2, cfg: GameConfig) -> void:
	var arch_terrain := _floor()
	var arch_info := _arch_event_info()
	if cfg.finish_arch_enabled:
		if finish_len > 0.0:
			var fin_pos := road_centerline.sample_baked(finish_len)
			var fin_tan := fin_pos - road_centerline.sample_baked(maxf(0.0, finish_len - 0.5))
			_place_arch("FinishArch", fin_pos, fin_tan, false, arch_info, cfg, arch_terrain)
	if cfg.start_arch_enabled:
		# start_pos / start_heading is the car's real spawn pose (the start line).
		_place_arch("StartArch", start_pos, start_heading, true, arch_info, cfg, arch_terrain)


# Create-or-reuse the persistent per-stage managers and wire the stage splits. Each
# node is reused across regenerations (entering a new event) via _ensure_child, so
# managers don't accumulate or collide on name.
func _build_persistent_managers(cfg: GameConfig, result: Dictionary,
		road_centerline: Curve2D, finish_len: float, staged: bool) -> void:
	# Retain the centerline in a TrackProgress manager: tracks how far the car has
	# driven and snaps it back onto the road if it strays too far (the Curve2D is
	# otherwise discarded after set_track).
	_track_progress = _ensure_child("TrackProgress",
		func() -> Node: return TrackProgress.new()) as TrackProgress
	_track_progress.setup(road_centerline, $Car, _floor(), finish_len)

	# Tire marks: gravel ruts laid behind the wheels while on the road
	# (features/tire-marks.md); gated to the road half-width, so it needs the
	# centerline + terrain.
	_tire_marks = _ensure_child("TireMarks",
		func() -> Node: return TireMarks.new()) as TireMarks
	_tire_marks.setup(road_centerline, $Car, _floor(), cfg.track_width * 0.5)

	# Road paint: solid edge lines + a dashed centre line along the tarmac sections,
	# so tarmac reads as tarmac (features/track.md). A static mesh built once from the
	# centerline + surface split; rebuilt on a regeneration.
	_road_markings = _ensure_child("RoadMarkings",
		func() -> Node: return RoadMarkings.new()) as RoadMarkings
	# A region may recolour the lane paint (Greece paints yellow lines); home / free
	# roam keep the GameConfig off-white.
	var marking_params := cfg.road_marking_params()
	var region_look := _current_region_look()
	if region_look.has("road_marking_color"):
		marking_params["color"] = region_look["road_marking_color"]
	_road_markings.build(road_centerline, _floor(), marking_params)

	# Wheel dust: cheap gravel spray flung from the driven wheels under wheelspin
	# (features/wheel-dust.md); the surface under each wheel (gravel vs grass/tarmac)
	# is read live off the car's drivetrain terrain, so it only needs the car here.
	_wheel_particles = _ensure_child("WheelParticles",
		func() -> Node: return WheelParticles.new()) as WheelParticles
	_wheel_particles.setup($Car)
	# Region grass-blade colour override (e.g. Greece's dry olive vs. home's
	# green) — falls back to GameConfig when the region authors none.
	_wheel_particles.set_grass_color_override(region_look.get("grass_particle_color", Color(0, 0, 0, 0)))
	# ...and its shape: snow throws square clods of powder, not slim grass blades.
	_wheel_particles.set_grass_square_override(bool(region_look.get("grass_particle_square", false)))

	# Grey smoke puffed from the bonnet each time a damaged engine misfires. Its own
	# small MultiMesh pool; reads the car's engine misfire counter live. See
	# features/engine-smoke.md.
	_engine_smoke = _ensure_child("EngineSmoke",
		func() -> Node: return EngineSmoke.new()) as EngineSmoke
	_engine_smoke.setup($Car)

	# Backfire flame spat from each exhaust pipe on a rev-limiter bang and while nitrous
	# is delivering. Its own small additive MultiMesh pool; reads the car's limiter cut
	# counter and nitrous delivery state live. See features/exhaust-flames.md.
	_exhaust_flames = _ensure_child("ExhaustFlames",
		func() -> Node: return ExhaustFlames.new()) as ExhaustFlames
	_exhaust_flames.setup($Car)

	# Records the car's transform each frame during a stage run, so it can be
	# played back as a cinematic replay behind the between-event standings
	# overlay (features/event-replay.md).
	_replay_recorder = _ensure_child("ReplayRecorder",
		func() -> Node: return ReplayRecorder.new()) as ReplayRecorder
	_replay_recorder.setup($Car)

	# Per-stage start/end flow: lock the car, count down, time the run, and signal
	# completion when progress reaches the finish (todo/stage-start-and-end.md).
	# A benchmark run skips the whole stage flow — the manager is left un-armed
	# (no countdown, no control lock) and BenchmarkRunner drives instead.
	_stage_manager = _ensure_child("StageManager",
		func() -> Node: return StageManager.new()) as StageManager
	if not Benchmark.active:
		# Staged runs hold the car in the start-line sequence until the player launches;
		# otherwise the countdown arms immediately, as before.
		_stage_manager.setup($Car, $HUD as CanvasLayer, _track_progress, staged)
		# Route the finish panel's NEXT button to advance the stage into the results flow
		# (both nodes persist across regenerations, so guard the connection).
		var hud_node := $HUD
		if not hud_node.finish_next_pressed.is_connected(_stage_manager.proceed_to_results):
			hud_node.finish_next_pressed.connect(_stage_manager.proceed_to_results)
		# Rally pacenote strip along the top of the HUD (features/hud.md): the current
		# turn + the upcoming turns queued to its right. Wired on every run (no rival
		# needed), so the strip reads the track whether or not a session is active.
		_setup_pacenotes(result, staged, cfg)


# Place the three spectator crowds: one at the start line, one at the finish, and
# one at a seeded fraction of the way along (todo/roadside-spectators.md). Builds a
# shared tree-point grid once so members can avoid spawning inside foliage.
func _spawn_spectators(centerline: Curve2D, road_cells: Dictionary, trees: PackedVector2Array,
		start_pos: Vector2, start_heading: Vector2, cfg: GameConfig, terrain: TerrainManager,
		finish_len := -1.0) -> void:
	var baked := centerline.get_baked_length()
	if baked <= 0.0:
		return
	# End/mid crowds anchor to the FINISH (end of the timed track), not the rendered
	# end — the runoff road past the finish should read as empty.
	var end_len := baked if finish_len < 0.0 else minf(finish_len, baked)
	var tree_cell: float = maxf(cfg.spectator_tree_avoid_m, 0.5)
	var tree_grid := SpectatorScatter.build_point_grid(trees, tree_cell)

	# Start: at the car's spawn pose.
	_spawn_spectator_group("SpectatorStart", start_pos, start_heading,
		road_cells, tree_grid, cfg, terrain, cfg.track_seed + 101)

	# Mid: a seeded fraction of the way along the centerline.
	var mid_off := SpectatorScatter.mid_offset(end_len,
		cfg.spectator_mid_progress_min, cfg.spectator_mid_progress_max, cfg.track_seed)
	var mid_pt := centerline.sample_baked(mid_off)
	var mid_tan := centerline.sample_baked(minf(mid_off + 1.0, end_len)) - mid_pt
	_spawn_spectator_group("SpectatorMid", mid_pt, mid_tan,
		road_cells, tree_grid, cfg, terrain, cfg.track_seed + 202)

	# End: at the finish (end of the centerline).
	var end_pt := centerline.sample_baked(end_len)
	var end_tan := end_pt - centerline.sample_baked(maxf(0.0, end_len - 1.0))
	_spawn_spectator_group("SpectatorEnd", end_pt, end_tan,
		road_cells, tree_grid, cfg, terrain, cfg.track_seed + 303)


# Build one crowd: a band centred on the road at `anchor`, running along `heading` and
# straddling the carriageway so members line BOTH verges (the road cells in the middle
# are rejected). Named so an in-place regeneration replaces rather than stacks groups
# (cf. _place_arch).
func _spawn_spectator_group(node_name: String, anchor: Vector2, heading: Vector2,
		road_cells: Dictionary, tree_grid: Dictionary, cfg: GameConfig,
		terrain: TerrainManager, seed_value: int) -> void:
	_replace_named_child(node_name)
	var dir := heading
	if dir.length() < 1e-5:
		dir = Vector2(0.0, 1.0)
	dir = dir.normalized()
	var tree_cell: float = maxf(cfg.spectator_tree_avoid_m, 0.5)
	var members := SpectatorScatter.members(anchor, dir,
		cfg.spectator_area_length_m * 0.5, cfg.spectator_area_width_m * 0.5,
		cfg.spectator_group_size, cfg.spectator_separation_m, road_cells,
		tree_grid, tree_cell, cfg.spectator_tree_avoid_m, seed_value)
	members = _drop_submerged(members, cfg)  # no spectators standing in a lake
	if members.is_empty():
		return
	var group := SpectatorGroup.new()
	group.name = node_name
	add_child(group)
	var params := cfg.spectator_params()
	params["seed"] = seed_value
	group.setup(members, $Car, terrain, road_cells, tree_grid, params)


# The live event framing — the event's name, which stage of how many, and the
# time-to-beat. Single source for BOTH the arch banners and the start-line header
# (_build_start_line), so a challenge stage reads its framing in exactly one place.
# The rally's difficulty tier is a hidden value, so it's deliberately not surfaced
# here. When no session is active (a dev boot / direct play) the fields stay
# empty/zero and the gate shows just its START / FINISH wordmark.
#
# `target_ms` is whatever RunSession.stage_target_ms() holds for the stage being
# driven — the fixed reference-car clock a region run must beat (decision 11), and 0
# for a challenge stage, which has no target. FinishArch omits the time row for a
# non-positive target, the same graceful empty state a session-less boot gets.
func _arch_event_info() -> Dictionary:
	var info := {"rally_name": "", "stage_index": 0, "stage_count": 0, "target_ms": -1}
	if RunSession.is_active():
		info["rally_name"] = RunSession.display_name()
		info["stage_index"] = RunSession.events_completed()
		info["stage_count"] = RunSession.stage_count()
		# The one clock in the game (decision 4/11). 0 for a challenge stage, which has
		# no target — FinishArch already omits the time row for a non-positive target.
		info["target_ms"] = RunSession.stage_target_ms()
	return info


# Build and position one inflatable arch straddling the road at `pos`, facing along
# `heading` (the road direction there). The arch stands in its local XY plane and is
# extruded along its local Z (depth), so Basis.looking_at(heading) points the node's
# -Z down-track, leaving +Z (the banner face) toward the driver. The base sits at the
# centerline (road-surface) height, like the signs. `is_start` picks the START vs
# FINISH wording; `info` is the event data the banners display.
func _place_arch(node_name: String, pos: Vector2, heading: Vector2,
		is_start: bool, info: Dictionary,
		cfg: GameConfig, terrain: TerrainManager) -> void:
	if heading.length() < 1e-5:
		heading = Vector2(0.0, 1.0)
	heading = heading.normalized()
	# Replace any arch from a previous in-place regeneration (entering a new event)
	# so gates don't stack up — freed immediately so the new one keeps the name.
	_replace_named_child(node_name)
	var arch := FinishArch.new()
	arch.name = node_name
	# Clear opening spans the full road width plus a margin on each side, so the
	# legs stand clear of the road and the car drives through the gap.
	arch.span = cfg.track_width + 2.0 * cfg.finish_arch_road_margin_m
	arch.is_start = is_start
	arch.info = info
	add_child(arch)  # _ready() -> build() runs here, after the params are set
	var fwd3 := Vector3(heading.x, 0.0, heading.y).normalized()
	var ground_y := terrain.height_at(pos.x, pos.y)
	arch.transform = Transform3D(Basis.looking_at(fwd3, Vector3.UP),
		Vector3(pos.x, ground_y, pos.y))
	# Cull the whole arch (structure, banners, ropes) at the shared world-prop render
	# distance so it pops in with the foliage/signs/spectators rather than floating in
	# the far fog. build() has already run (add_child -> _ready), so the subtree is complete.
	MeshUtil.apply_visibility_range(arch, cfg.tree_render_distance_m, cfg.tree_render_fade_m)


# The authored car spawn transform, captured at boot so each car swap spawns in
# the same place rather than wherever the previous car drove to.
var _car_spawn: Transform3D

# Tracks track progress + off-track reset for the current car (re-targeted on a
# car swap, since the fresh car respawns at the start).
var _track_progress: TrackProgress

# The rendered road/progress centerline from the latest generation (lead-in +
# runoff included) — kept for the benchmark runner's pursuit line.
var _road_centerline: Curve2D

# This stage's coins (features/collectables.md), null when none were built — not a
# region run (RunSession.mode_id() != RunMode.REGION), coins_enabled is off, or
# coins_per_stage rolled an empty layout. Read at stage end for
# RunSession.report_event_result's coins_collected argument.
var _coin_field: CoinField = null

# Owns the per-stage countdown -> run timer -> completion flow for the current
# stage (recreated on each track regeneration).
var _stage_manager: StageManager

# Lays gravel tire-mark ribbons behind the wheels (re-targeted on a car swap).
var _tire_marks: TireMarks
var _road_markings: RoadMarkings

# Flings cheap gravel dust off the driven wheels under wheelspin (re-targeted on
# a car swap).
var _wheel_particles: WheelParticles
var _engine_smoke: EngineSmoke
var _exhaust_flames: ExhaustFlames

# Cinematic replay behind the between-event standings overlay (features/event-replay.md).
var _replay_recorder: ReplayRecorder
# The rival ghost + its pace-solve wiring (_setup_stage_splits, _solve_rival_pace,
# _wire_stage_splits, _setup_rival_ghost, _on_opponent_field_changed) used to live
# here — deleted with the rival field it raced (todo/roguelike-pivot.md decision 5).
var _replay_camera: ReplayCamera
# The live between-stage interstitial (RunPickPanel), when one is up. Non-null only
# while the player has not yet dismissed it; _on_run_finished awaits
# run_interstitial_dismissed while this is valid so the player dismisses the FINAL
# stage's result themselves rather than being ejected to the hub the instant
# report_event_result finishes. Null headless (no overlay is built), where the run
# end stays immediate.
var _interstitial_page: MenuPage = null

# Coarse far-terrain backdrop that gives the sky a horizon (distant_terrain.gd).
var _distant_terrain: DistantTerrain

# The pre-event start-line scene (briefing + presence cars); built for staged
# session runs and freed with the scene on the next event reload.
var _start_line: StartLine

# Working HP the fielded car started this event with, so the event's HP loss can
# be reported back to the session at completion. Set when fielding a session car.
var _event_start_hp := 0.0
# HP + wheel-toe captured at the finish CROSSING (_on_finish_reached), used at
# report time so the post-finish runoff coast can't alter the event's damage.
var _event_hp_at_finish := 0.0
var _event_toe_at_finish: Array = []
# Along-track metres at the finish crossing, for LifetimeStats.DISTANCE_DRIVEN_M.
# TrackProgress.progress_offset() is a BEST-offset odometer: it counts forward progress
# down the centreline and never rewards reversing or wandering off it, which is what makes
# it the honest reading of "metres driven" rather than a raw path length. Snapshotted at
# the crossing for the same reason HP is — the post-finish coast down the runoff is not
# part of the stage.
var _event_distance_at_finish := 0.0


# Build the HUD pacenote strip for this stage (features/hud.md) and wire the strip's
# per-corner progress thresholds into the StageManager. Runs on every non-benchmark
# run — pacenotes are track reading, not a rival comparison — so it needs no session.
# The progress fractions line up with TrackProgress.progress_percent(): a staged
# run's lead-in ahead of the generated track is added to both the corner offset
# and the span.
func _setup_pacenotes(track_result: Dictionary, staged: bool, cfg: GameConfig) -> void:
	var centerline := track_result.get("centerline") as Curve2D
	if centerline == null:
		return
	var notes := Pacenotes.build(centerline, track_result.get("pieces", []))
	var hud_node := $HUD
	if hud_node != null and hud_node.has_method("set_pacenotes"):
		hud_node.set_pacenotes(notes)
	if _stage_manager == null:
		return
	var ahead := cfg.start_lead_in_ahead_m if staged else 0.0
	var span := ahead + centerline.get_baked_length()
	_stage_manager.setup_pacenotes(Pacenotes.notes_to_fracs(notes, ahead, span))


# --- Session run-scene integration ------------------------------------------

# Dev cheat (F key, features/debug-tools.md): skip straight to the finish of the
# current stage. Debug-build only (release/web ignore it) and only inside an active
# run — Rally Challenge today, the roguelike run session once it lands — with a live
# StageManager. Teleports the car onto the finish line and force-completes the
# stage, so the whole completion → reward → progression flow fires exactly as it
# would on a real finish.
#
# Gated on DrivingContext.session_active(), not any one session's is_active(): a
# check tied to a single session type silently excludes every other one.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("skip_to_finish"):
		return
	if not SettingsMenu.dev_tools_enabled() or not DrivingContext.session_active():
		return
	if _stage_manager == null or _track_progress == null:
		return
	if _stage_manager.phase() == StageManager.Phase.COMPLETE:
		return
	# Mark handled BEFORE completing: force_complete() emits stage_completed, whose
	# handler can transition the scene and detach this node, making a later
	# get_viewport() call return null.
	get_viewport().set_input_as_handled()
	$Car.reset_to(_track_progress.jump_to_finish())
	_stage_manager.force_complete()


# Pause-menu "Reset to track": snap the live car onto the centerline beside its
# CURRENT position ("the middle of the road, regardless of where the car is right
# now") — TrackProgress.manual_reset_pose() does a fresh nearest-point query, so it
# works even when the car has strayed off the leash (where recovery_pose() would be
# frozen at the furthest progress reached and no longer beside the car). reset_to
# zeroes motion and suppresses the impact damage the teleport would otherwise
# register, so the reset is free. No-op before the track exists (TrackProgress is
# built during generation).
func _on_reset_to_track_requested() -> void:
	if _track_progress == null or not has_node("Car"):
		return
	$Car.reset_to(_track_progress.manual_reset_pose())


# Whether this run should open with the pre-event start-line scene: a session run
# with the feature enabled AND a resolvable stage (so a run that has no stage left
# never strands the car in STAGING with no StartLine to launch it). Rivals are
# gone (todo/roguelike-pivot.md decision 5), so there is no field to reveal — the
# StartLine's existing empty-leaders path covers that; see _build_start_line.
func _should_stage() -> bool:
	if not Config.data.start_line_enabled:
		return false
	return RunSession.is_active() \
		and not RunSession.current_stage_params().is_empty()


# Show the between-event pit-repair popup and block until the player dismisses it.
# Shown BEFORE the start-line is built, so it sits above even the loading overlay
# (LoadingScreen._LAYER = 100, still up on staged runs until the start-line queue is
# laid out) — the black loading backdrop reads as the modal's background. Torn down
# once dismissed, so the start-line briefing owns the screen (and its focus) next.
func _show_repair_popup(summary: Dictionary) -> void:
	var layer := CanvasLayer.new()
	layer.name = "RepairPopup"
	layer.layer = 101  # above the loading overlay (100) and start-line overlay (5)
	add_child(layer)
	var card := RepairReveal.new()
	layer.add_child(card)
	card.reveal(summary)
	await card.finished
	layer.queue_free()
	# Freeing the popup's focused Continue button clears the viewport's focus owner
	# outright (Godot does not auto-migrate focus off a freed Control), and nothing
	# re-grabs it afterwards: the start-line overlay was already built + MenuNav-attached
	# before the popup ever showed, so its own visibility_changed re-grab never fires.
	# Release explicitly, then hand it straight back to Start for staged runs — the
	# hq.gd pattern (CLAUDE.md), applied on the way OUT of an overlay instead of in.
	get_viewport().gui_release_focus()
	if is_instance_valid(_start_line):
		_start_line.grab_start_focus()


# Build the pre-event start-line sequence around the fielded car (the times-to-beat
# reveal + orbit camera + start queue). The StageManager is already in STAGING;
# StartLine hands the camera/UI back and launches it after its fade.
func _build_start_line() -> void:
	# The framing (name / stage index) comes from the same _arch_event_info() the
	# arch banners read, so the header and the gate can never disagree.
	#
	# _should_stage() only stages a RunSession run now (RallySession, the
	# career caller, is deleted — todo/roguelike-pivot.md decision 5 — and the
	# roguelike run session has not landed yet), so this always runs against a
	# challenge stage. A challenge has no authored rally, so synthesise just enough
	# for StartLine's header. There is no rival field left to reveal — StartLine's
	# MENU fades straight to the countdown (decision 29).
	var info := _arch_event_info()
	var rally := {"name": String(info["rally_name"])}
	_start_line = StartLine.new()
	_start_line.name = "StartLine"
	add_child(_start_line)
	# PAUSE IS OFF FOR THE WHOLE STAGED WINDOW. The start line owns the screen with its
	# own full-width action row (Exit / Upgrades / Tune Car / Start), and a pause overlay
	# stacked on top of it just fights for the same taps — the two menus overlapped and
	# neither reliably took a press. The start line's own Exit is the way out until the
	# countdown starts; sequence_finished re-arms pause at the hand-off.
	var pause_menu := _pause_menu()
	if pause_menu != null:
		pause_menu.set_input_enabled(false)
		if not _start_line.sequence_finished.is_connected(_on_start_line_finished):
			_start_line.sequence_finished.connect(_on_start_line_finished)
	_start_line.setup($Car, $Floor, _stage_manager, rally, int(info["stage_index"]),
		$CameraManager as CameraManager,
		$HUD as CanvasLayer, $MobileControls as CanvasLayer, pause_menu)


# The staged window is over (camera, HUD and player control all handed back): pause is
# meaningful again now that the start line's menu is gone. See _build_start_line.
func _on_start_line_finished() -> void:
	var pause_menu := _pause_menu()
	if pause_menu != null:
		pause_menu.set_input_enabled(true)


# The pause menu, or null in the harnesses that don't mount one. One accessor because
# three separate get_node_or_null("PauseMenu") lookups had already accumulated.
func _pause_menu() -> PauseMenu:
	return get_node_or_null("PauseMenu") as PauseMenu


# The terrain manager, cached. `$Floor as TerrainManager` was written out at 20+ call sites
# through this file; the node never changes identity after _ready, so the cast is pure noise
# and a moved node path would have to be fixed 20 times. Resolved lazily rather than in
# _ready() because several callers run during the boot sequence before _ready completes.
var _floor_tm: TerrainManager = null

func _floor() -> TerrainManager:
	if _floor_tm == null:
		_floor_tm = get_node_or_null("Floor") as TerrainManager
	return _floor_tm


# Is the pre-countdown start line still running? NOT `is_instance_valid(_start_line)` —
# the node is never freed once built, so that only ever answers "was one ever built".
func _start_line_is_staging() -> bool:
	return is_instance_valid(_start_line) and _start_line.is_staging()


# Prepend a straight lead-in to a generated centerline: a stub BEHIND the start line
# (so the trailing queue car sits on road) through the start, joining the generated
# track (which was generated start_lead_in_ahead_m AHEAD, so start→track is straight
# too). Both prepended segments are handle-free, so they're dead straight.
func _with_start_lead_in(gen: Curve2D, start_2d: Vector2, heading_2d: Vector2, cfg: GameConfig) -> Curve2D:
	var c := Curve2D.new()
	c.add_point(start_2d - heading_2d * cfg.start_lead_in_behind_m)  # behind stub
	c.add_point(start_2d)                                           # the start line
	for i in gen.point_count:
		c.add_point(gen.get_point_position(i), gen.get_point_in(i), gen.get_point_out(i))
	return c


# Append the post-finish runoff straight to a rendered centerline: one dead-straight
# (handle-free) point at the runoff's far end, so the terrain bake + road markings
# render it as real road past the finish. `runoff` is TrackGenerator's result["runoff"]
# ({} when disabled or the track didn't complete -> the curve is returned unchanged).
func _with_finish_runoff(gen: Curve2D, runoff: Dictionary) -> Curve2D:
	if runoff.is_empty():
		return gen
	var c := Curve2D.new()
	for i in gen.point_count:
		c.add_point(gen.get_point_position(i), gen.get_point_in(i), gen.get_point_out(i))
	c.add_point(runoff["end_pos"])  # dead-straight from the finish to the runoff end
	return c

# Configure the car for the fielded OwnedCar; fall back to the default car if the
# instance has vanished from the save (defensive). The rally and challenge paths
# differ ONLY in which session owns the fielded instance id, so the caller resolves
# that and this stays single-sourced (challenge path: spec §2/§3).
func _field_car(instance_id: int) -> void:
	var owned: Dictionary = Save.get_car(instance_id)
	if owned.is_empty():
		$Car.apply_car(0)
		return
	if RunSession.is_active():
		# RUN-SCOPED BOOSTS (todo/roguelike-pivot.md "Upgrades — RR's two-tier model",
		# features/region-runs.md -> "Where boosts live, and what wipes them"). Merged
		# onto a DUPLICATED copy of the owned-car dict, never the live reference
		# Save.get_car returned — writing "boosts" onto that would persist a run's
		# temporary picks straight into the profile, which must never happen (they are
		# wiped when the run ends, win or lose; see RunSession._finish_locally).
		owned = owned.duplicate(true)
		# PERKS RIDE THE SAME SEAM (todo/roguelike-pivot.md decision 51: "the seam is
		# UpgradeLibrary.EFFECTS + a car's boosts list; do not build a parallel modifier
		# path"). The two lists differ in LIFETIME, not in mechanism: a boost is run-scoped
		# and wiped when the run ends, while an equipped perk is a permanent profile
		# purchase — so perks are re-derived from the profile on every stage boot rather
		# than carried on the run object. Both land on the same duplicated dict, which is
		# what keeps either of them out of the saved profile.
		owned["boosts"] = RunSession.boosts() + PerkLibrary.equipped_effects(Save.profile)
		# THE MID-RUN DRIVETRAIN CONVERSION (same seam, same lifetime as the boosts above —
		# see RunSession.choose_drivetrain / drivetrain_override). Written onto this same
		# duplicated dict, never Save's persisted car, so UpgradeLibrary.resolve_drive_override
		# sees it for exactly as long as the run does.
		owned["drivetrain_override"] = RunSession.drivetrain_override()
	$Car.apply_owned(owned)
	_event_start_hp = $Car.damage.hp
	# Safe defaults until the finish crossing overwrites them (_on_finish_reached).
	_event_hp_at_finish = _event_start_hp
	_event_toe_at_finish = $Car.damage.toe_array()
	_event_distance_at_finish = 0.0


# Route this event's StageManager / damage signals to the session, and the run's
# finish onward. Connections on the per-event scene's nodes are dropped
# automatically when the scene reloads for the next event. RunSession is the sole
# session — RallySession, the career caller this used to branch on, is deleted
# (todo/roguelike-pivot.md decision 5); which KIND of run is live is a RunMode
# question now, not a second autoload.
func _wire_session_signals() -> void:
	# stage_completed is already connected in _ready() (every mode wires it before
	# this session-only pass runs), so it's intentionally not re-connected here.
	# ONE mode-agnostic wire for both: _on_run_finished dispatches by mode internally
	# (the challenge posts to its cloud board and awaits the interstitial's dismissal
	# before the grant reveal; a region run just waits for the same dismissal, then
	# both return to the hub) — there is no RallySession/ChallengeSession split left to
	# route between (features/rally-challenge.md).
	if RunSession.is_active():
		if not RunSession.run_finished.is_connected(_on_run_finished):
			RunSession.run_finished.connect(_on_run_finished)
		# _present_standings_overlay reads nothing session-specific (just $Car / $HUD /
		# the replay recorder), so it serves every kind of run's between-stage beat.
		if not RunSession.standings_ready.is_connected(_present_standings_overlay):
			RunSession.standings_ready.connect(_present_standings_overlay)

	if _stage_manager != null and not _stage_manager.stage_started.is_connected(_on_stage_started):
		_stage_manager.stage_started.connect(_on_stage_started)
	if _stage_manager != null and not _stage_manager.finish_reached.is_connected(_on_finish_reached):
		_stage_manager.finish_reached.connect(_on_finish_reached)


# Test seam: headless tests can't survive a real change_scene_to_file (it would
# replace the GUT runner scene), so they set this to capture the requested path
# instead. Real play leaves it unset and gets the real scene change.
var scene_change_hook: Callable = Callable()


func _change_scene(path: String) -> void:
	if scene_change_hook.is_valid():
		scene_change_hook.call(path)
		return
	Scenes.change_to(get_tree(), path)


func _on_session_event_completed(elapsed_seconds: float) -> void:
	# No active session — free roam (or a plain dev boot) reached the finish. There is
	# no session to report to (report_event_result would silently no-op, leaving the
	# finish panel's Next doing nothing), so Next returns to the hub instead — the same
	# destination as the pause menu's Quit with no session.
	if not RunSession.is_active():
		_change_scene(Scenes.hub_path())
		return
	# HP lost + persisted wheel-toe are snapshotted at the FINISH CROSSING (see
	# _on_finish_reached), NOT here: this handler fires on the NEXT button, by which time
	# the car has skidded to a stop / idled in the runoff, and any barrier clip during
	# that post-finish coast would be wrongly charged to the event's damage.
	# SIGNED, not clamped at 0: the "self_healing" perk (decision 51) can leave a stage
	# with MORE HP than it started, and clamping here would silently throw that repair
	# away at every stage boundary. RunSession.report_event_result reads the sign.
	var hp_lost: float = _event_start_hp - _event_hp_at_finish
	var iid: int = RunSession.car_instance_id()
	if iid >= 0:
		Save.set_wheel_toe(iid, _event_toe_at_finish)
	if _replay_recorder != null:
		_replay_recorder.stop()
	var elapsed_ms := int(round(elapsed_seconds * 1000.0))
	# Coins collected THIS stage (0 when none were built — a challenge, or a region
	# stage that rolled an empty layout). Banking is RunSession/RegionRunMode's call
	# (decision 36 — only on a stage that isn't missed); this just reports the count.
	var coins_collected := _coin_field.collected_count if _coin_field != null else 0
	RunSession.report_event_result(elapsed_ms, hp_lost, coins_collected,
		_event_distance_at_finish)


func _on_stage_started() -> void:
	if _replay_recorder != null:
		_replay_recorder.start()


# Fired the instant the finish is crossed (StageManager._complete), before the NEXT
# button. Two run-end snapshots are taken HERE so the post-finish coast can't affect
# them: (1) stop the recorder (else the stationary runoff tail lands in the replay);
# (2) capture HP + wheel-toe as of the crossing (the driven run's real damage).
func _on_finish_reached() -> void:
	if _replay_recorder != null:
		_replay_recorder.stop()
	_event_hp_at_finish = $Car.damage.hp
	_event_toe_at_finish = $Car.damage.toe_array()
	if _track_progress != null:
		_event_distance_at_finish = _track_progress.progress_offset()


# Hide every overlay that exists to serve the PERSON DRIVING, leaving only the world
# itself. Called when the run hands over to the cinematic replay: the player is now a
# viewer, so anything addressed to a driver is noise over the top of a film.
#
# All three are that: the HUD reads out the car you are controlling; the touch
# sticks/pedals control it; and the anime speed lines are a feedback cue that sells the
# sensation of speed to whoever is holding the controller — screen-centred streaks that
# belong to the driving camera, not to the chase and trackside shots the replay cuts
# between. Hiding the speed-line layer also stops it shading a full-screen pass behind
# the standings overlay for a car nobody is driving.
#
# One-way on purpose: this world is torn down after the replay rather than returned to.
func _hide_driving_ui() -> void:
	($HUD as CanvasLayer).visible = false
	for layer_name in ["MobileControls", "SpeedLines"]:
		var layer := get_node_or_null(NodePath(layer_name)) as CanvasLayer
		if layer != null:
			layer.visible = false


# Present the between-stage interstitial over a cinematic replay, keeping the run world
# alive behind it. Headless runs (no display) skip this — RunSession's own state (see
# pending_pick/choose_repair/choose_boost) is exercised directly by tests instead.
#
# What used to load here — standings.tscn, a per-stage GLOBAL LEADERBOARD — is deleted
# (decision 30: no more per-stage boards). RunPickPanel replaces it: the drawn boosts +
# repair + a drivetrain conversion option when RunSession has a pick pending (a region
# run's non-final, non-missed stage), or a bare Continue when it doesn't (the challenge,
# and this run's own final/failed stage — see features/region-runs.md -> "Between-stage
# pick: repair, boost, or drivetrain conversion").
func _present_standings_overlay(_event_index: int) -> void:
	if _headless or _replay_recorder == null:
		return
	if _replay_recorder.recording:
		_replay_recorder.stop()
	_hide_driving_ui()
	# Camera for the cinematic replay.
	_replay_camera = ReplayCamera.new()
	add_child(_replay_camera)
	_replay_camera.setup($Car, _replay_recorder, _floor(),
		Config.data.track_water_level_m)
	_replay_camera.current = true
	# Stand every knocked-over prop (felled trees, toppled signs) back up so the replay
	# shows the stage intact — the driver plays back against a pristine forest.
	_reset_props_for_replay()
	# Car into replay playback.
	($Car as Node).begin_replay(_replay_recorder)
	_interstitial_page = RunPickPanel.open(self, RunSession.pending_pick(),
		_on_interstitial_choice, RunSession.drivetrain_choices())
	_on_leaderboard_hidden_changed(false)   # shown -> engine muted


# The interstitial's row was pressed — "repair", a boost id, "drivetrain:<mode>", or ""
# (plain Continue, offered when RunSession had no pick to draw). Applies the choice, tears
# the overlay down, then either carries the run into the next stage or — if this was the
# run's final/failed stage, so RunSession is no longer active — signals that the player has
# seen the result.
func _on_interstitial_choice(choice: String) -> void:
	if choice == "repair":
		RunSession.choose_repair()
	elif choice.begins_with("drivetrain:"):
		RunSession.choose_drivetrain(int(choice.substr("drivetrain:".length())))
	elif choice != "":
		RunSession.choose_boost(choice)
	_teardown_interstitial()
	if RunSession.is_active():
		RunSession.continue_to_next_stage()
	else:
		run_interstitial_dismissed.emit()


func _teardown_interstitial() -> void:
	if is_instance_valid(_interstitial_page):
		var layer := _interstitial_page.get_parent()
		if is_instance_valid(layer):
			layer.queue_free()
	_interstitial_page = null
	_on_leaderboard_hidden_changed(true)   # dismissed -> engine audible again


# Restore every knocked-over prop before the replay so it plays back against an intact
# stage. The foliage fields (trees + bushes: TreeMeshField / BillboardField) and the
# SignField are direct children of the world; each carries its own reset that touches
# only the props it actually knocked over (a pristine field is a cheap early-out), so
# this is a light sweep even on a stage with hundreds of trees.
func _reset_props_for_replay() -> void:
	for child in get_children():
		if child.has_method("reset_fallen"):
			child.reset_fallen()
		elif child.has_method("reset_knocked"):
			child.reset_knocked()


func _on_leaderboard_hidden_changed(hidden: bool) -> void:
	# Engine audio: silenced while the leaderboard is shown, on while hidden (watch
	# mode). Disable the node's processing (drains the generator to silence) rather
	# than writing volume_db — the per-frame proximity attenuation in engine_audio.gd
	# would otherwise overwrite a volume_db mute every frame. See engine-audio.md.
	var ea := $Car.get_node_or_null("EngineAudio") as AudioStreamPlayer
	if ea != null:
		ea.process_mode = Node.PROCESS_MODE_INHERIT if hidden else Node.PROCESS_MODE_DISABLED


# _on_session_rally_finished (RallySession.rally_finished -> the podium, or straight
# to the hub on an abandon) used to live here. Its only wiring was in the
# RallySession arm of _wire_session_signals, deleted with RallySession
# (todo/roguelike-pivot.md decision 5), so nothing connects to it any more.

# ONE mode-agnostic handler for "the run just ended", wired for either kind
# (_wire_session_signals). Delegates entirely to _on_challenge_run_finished for a
# challenge (its own function so tests/headless/test_challenge_run_end.gd can drive
# it directly with no world-level dispatch — that file's cloud-reward coverage
# predates this stage and its call sites are unchanged); every OTHER kind of run
# (today: only the region run) just waits for the player to dismiss the final
# stage's interstitial (RunPickPanel's Continue — a region run's final/failed stage
# draws no pick, so it is always Continue) before leaving for the hub, so nobody is
# ejected mid-read the instant report_event_result finishes.
func _on_run_finished(result: Dictionary) -> void:
	if String(result.get("mode", "")) == RunMode.CHALLENGE:
		await _on_challenge_run_finished(result)
		return
	if is_instance_valid(_interstitial_page):
		await run_interstitial_dismissed
	_change_scene(Scenes.hub_path())


# A challenge run has no podium (no rival field to place against, no per-rally
# car reward). Both a clean finish and a DNF return straight to the hub — but the
# run's END is resolved here first:
#
#   CLEAN FINISH — spec §6's placement-gated completion reward. This fires while
#   the player is still IN the driving scene (RunSession._finish_locally
#   emits run_finished from report_event_result, before the hand-off to HQ), and
#   the scene change below is what ends the run, so the grant is awaited here and
#   shown on a plain ConfirmPopup card over the world — the same shape hq.gd's
#   HQ uses for a "reward, but not mid-interstitial" moment — the between-stage
#   interstitial (RunPickPanel) is already torn down by this point (see
#   run_interstitial_dismissed below).
#
#   DNF — flip the board's `dnf` field (spec §6). Best-effort and deliberately
#   NOT awaited: the house posture is that no cloud call ever costs the player
#   anything, so the return to HQ must not wait on (or surface) the network. The
#   coroutine resolves against Cloud.challenge_leaderboard, an autoload that
#   outlives this scene. Does NOT wait for the interstitial's dismissal either — a
#   DNF is only reachable on a run persisted by an older build (RunSession's own
#   header comment: nothing DNFs a challenge today), so this branch is legacy and
#   was never changed to wait, same as before this stage.
func _on_challenge_run_finished(result: Dictionary) -> void:
	if bool(result.get("dnf", false)):
		if Cloud != null and Cloud.challenge_leaderboard != null:
			@warning_ignore("return_value_discarded")
			Cloud.challenge_leaderboard.post_dnf(RunSession.period_key())
		_change_scene(Scenes.hub_path())
		return
	# ONE owner of "what happens after the last stage". The final stage's
	# interstitial is already on screen (report_event_result emits standings_ready
	# before finishing the run), so wait for the player to dismiss it instead of
	# racing it with a network round-trip and then ejecting them mid-read. Waiting
	# also means the final checkpoint has POSTED by the time
	# try_grant_completion_reward fetches the rank it gates on — previously the grant
	# was judged against a board this run had never been written to. Headless (no
	# overlay) keeps the old immediate path.
	if is_instance_valid(_interstitial_page):
		await run_interstitial_dismissed
	# try_grant_completion_reward fetches the run's final rank from Firestore — a
	# real round-trip with nothing on screen, which read as the game hanging right
	# at the moment the player is waiting to hear how they did. Cover it with the
	# shared cloud-busy state (todo/challenge-career-reuse-drift.md item 11); this
	# was the last unmigrated `await Cloud.*` site. RunSession is an autoload
	# with no screen of its own, so the covering host is this scene.
	var busy := CloudBusy.cover(self, "Scoring your run…", "Checking the leaderboard…")
	var grant: Dictionary = await ChallengeRunMode.try_grant_completion_reward(result)
	await busy.end()
	var item_id := String(grant.get("item_id", ""))
	# Money alone is a reward worth showing — a placing run's whole payout is money
	# now (todo/roguelike-pivot.md decision 21), so gating the card on item_id would
	# leave every challenge win silent.
	var won_something := item_id != "" or int(grant.get("money", 0)) > 0
	if won_something and not _headless:
		# NOT open_committing. That helper's whole point is making a mutation
		# unrepresentable without its reveal, by acquiring the modal slot BEFORE
		# calling a commit callable and skipping the callable entirely when the
		# slot is refused — the right shape for an action whose "it never happened"
		# state is true and harmless to fall back to. This grant has
		# no such fallback: try_grant_completion_reward already ran above (it has
		# to — fetch_final_rank is judged against THIS run's own posted time, so
		# it can't be deferred behind a modal check), and
		# RunSession._finish_locally recorded this period's outcome and
		# cleared challenge_run before run_finished even fired. There is no
		# "reward pending reveal" state and no way back into a finished period
		# (period_outcome is terminal — start()/resume() both refuse once it's
		# set), so skipping the reveal here would not defer the grant, it would
		# silently keep it while making it undiscoverable — worse than today's
		# bug, which never loses the stars themselves, only their reveal.
		# So: grant unconditionally (already done above), then GUARANTEE the
		# reveal instead of letting it be dropped. `allow_stack` is the existing,
		# sanctioned escape hatch for exactly this "must be seen even over
		# another modal" class — CloudBusy.report_failure uses it for the same
		# reason (a failed sync silently going invisible). A reward the player
		# already earned deserves at least the same guarantee.
		var popup := ConfirmPopup.open(self, "Challenge Complete!",
			_completion_reward_body(item_id, grant),
			[{"label": "Nice", "callback": Callable()}], 0, -1, true)
		# Only null when `self` has left the tree (host torn down mid-await) —
		# allow_stack means modal contention alone can never refuse it.
		if popup != null:
			await popup.finished
	_change_scene(Scenes.hub_path())


# Body text for the completion-reward card: what was won and where it landed.
# A placing run pays MONEY (todo/roguelike-pivot.md decision 21 — the star ledger it
# used to pay from is deleted); the amount is the flat
# GameConfig.challenge_completion_money, already banked by
# ChallengeRunMode.try_grant_completion_reward before this renders it. A car on top is
# still possible in principle, so both parts are optional and the card lists whatever
# actually landed.
func _completion_reward_body(item_id: String, grant: Dictionary) -> String:
	var rank := int(grant.get("rank", 0))
	var total := int(grant.get("total_entries", 0))
	var placing := "Finished %d of %d" % [rank, total] if total > 0 else "Finished"
	var lines: Array[String] = []
	var money := int(grant.get("money", 0))
	if money > 0:
		lines.append("$%d" % money)
	var car_entry := CarLibrary.by_id(item_id)
	if not car_entry.is_empty():
		lines.append(String(car_entry.get("name", item_id)))
	if lines.is_empty():
		return placing
	var where := "Spend it in the shop." if car_entry.is_empty() \
		else "Your new car is waiting in the car park."
	return "%s\nReward: %s\n\n%s" % [placing, ", ".join(lines), where]


func _mat(mesh_instance: MeshInstance3D) -> ShaderMaterial:
	return mesh_instance.get_surface_override_material(0) as ShaderMaterial


# The look overrides for the driven rally's region (empty for home / free-roam).
# Shared by _apply_region_look (materials/sky/fog) and the foliage spawn (tree
# billboard + bush suppression) so both read the same region. The region is fixed
# for the world's lifetime, so the result is computed once and cached.
var _region_look_cache: Dictionary = {}
var _region_look_ready := false
func _current_region_look() -> Dictionary:
	if _region_look_ready:
		return _region_look_cache
	# THE REGION RUN'S OWN REGION (stage 4 of the pivot gave this a real answer;
	# RunSession.region_id() returns "" for anything that is not a region run).
	#
	# A CHALLENGE stage is rolled from the period hash and authors no region, so it wears
	# the plain home look — as does a dev boot of main.tscn with no session at all. The
	# career-rally and free-roam arms that used to pick a region here are deleted with
	# RallySession (decision 5).
	var region_id := "home"
	if RunSession.is_active():
		var run_region := RunSession.region_id()
		if run_region != "":
			region_id = run_region
	_region_look_cache = RegionLibrary.look_of(region_id)
	_region_look_ready = true
	return _region_look_cache


# The headlight cone follows the car every frame on a stage whose weather switches the
# lights on (night, storm). This is the only per-frame work the feature does:
# three-to-seven global uniform writes, no geometry, no draw calls. Elsewhere push()
# early-outs into a reset, so the cost on every other stage is one branch.
func _process(_delta: float) -> void:
	if not HeadlightCone.has_headlights(Config.data):
		return
	HeadlightCone.push(Config.data, $Car.global_transform, $Car.half_width() * 2.0)


# Global shader parameters PERSIST ACROSS SCENE CHANGES, and the podium and HQ draw
# trees and ground with the same shaders — so a stage that lit its headlights must
# clear up after itself or it leaves a stray cone burning there. _exit_tree covers
# every exit path regardless of destination, which a per-destination reset would not.
func _exit_tree() -> void:
	HeadlightCone.reset()
	# Same reasoning, different mechanism: weather_sun_mult is a runtime value on the
	# SHARED Config.data, and nothing calls Config.reset(), so a night stage would
	# otherwise leave the HQ and podium dimmed — both spawn trees through
	# Foliage.spawn_trees, which now reads this via apply_foliage_light. The scene
	# tree frees the outgoing scene before the incoming one's _ready, so clearing it
	# here lands before anything else can read it.
	Config.data.weather_sun_mult = 1.0


# The shader swap itself is shared with overworld.gd — see WorldRuntime.apply_deep_snow,
# which carries the full reasoning (why a shader swap and not a uniform, and why calling
# it unconditionally every boot is load-bearing). This host only supplies its material.
func _apply_deep_snow_ground(cfg: GameConfig) -> void:
	WorldRuntime.apply_deep_snow($Floor.chunk_material as ShaderMaterial, cfg)


func _apply_region_look() -> void:
	var look := _current_region_look()
	if look.is_empty():
		return
	var floor_mat := $Floor.chunk_material as ShaderMaterial
	if look.has("grass_texture"):
		floor_mat.set_shader_parameter("albedo_texture", load(look["grass_texture"]))
	if look.has("gravel_texture"):
		floor_mat.set_shader_parameter("road_texture", load(look["gravel_texture"]))
	var env: Environment = $WorldEnvironment.environment
	# ALWAYS assigned, never `if look.has(...)`. The PanoramaSkyMaterial is a shared
	# sub-resource of main.tscn (no resource_local_to_scene), and home / home_coast
	# author no sky of their own — so a conditional assign let Greece's or snow's sky
	# follow the player into the next home stage and stay there. Falling back to the
	# authored default makes every stage boot seed a clean sky exactly once, the same
	# idempotence `albedo_color` and `tarmac_color` get above. Weather layers on top
	# of this afterwards, so a night sky still wins for the stage that asked for it.
	var sky_mat := env.sky.sky_material as PanoramaSkyMaterial
	if sky_mat:
		var sky_path: String = look.get("sky_panorama", Config.data.default_sky_panorama)
		if sky_path != "":
			sky_mat.panorama = load(sky_path)
	if look.has("background_color"):
		env.background_color = look["background_color"]
		env.fog_light_color = look["background_color"]
	# terrain_tint / terrain_layers overrides: apply here if authored (Greece ships
	# without them for now; leave hooks for later).


# Overcast+rain / dust+sandstorm look, layered on top of the region look. A DRY
# stage returns immediately and changes nothing — no node is built and no value is
# touched, so it carries exactly zero new per-frame cost (features/weather.md).
#
# Both looks are made ENTIRELY out of fog, not a second panorama. Normally
# fog_sky_affect is deliberately low (see _ready) so the skybox reads clearly above
# the haze; wet/sandstorm invert that — push it to cfg.*_fog_sky_affect and set the
# fog colour flat, and the fog washes the EXISTING panorama out into a featureless
# dome. No extra texture to author, import or carry in the Android bundle (download
# size gates installs on the phones this game targets) and no extra draw call, so the
# environment half of any condition is free. NOTE: the thicker fog shortens the
# VISIBLE distance but not the DRAWN one — the terrain ring radius and the shared
# tree/prop render distance are fixed and read no fog value, so hidden geometry is
# still built and submitted. See features/rendering.md → "Fog does not shorten the
# cull" for the (unclaimed) performance win that leaves on the table.
func _apply_weather_look(cfg: GameConfig) -> void:
	# No per-condition branching: everything below is driven by the condition's entry
	# in the weather table (WeatherLibrary), which names the GameConfig fields it
	# reads. A new condition is authored there, not here. DRY's entry has no "look",
	# no "road_tint" and no "particles", so all three blocks are skipped and the stage
	# is left byte-identical to a world with no weather system at all.
	var entry := WeatherLibrary.by_id(cfg.weather)
	# Re-seeded from the authored baseline every stage boot for the same reason the
	# road tint is: a condition with no look block must leave a CLEAN 1.0 behind, or
	# a dry stage would inherit the previous night/storm dimming on its car.
	cfg.weather_sun_mult = 1.0
	var look: Dictionary = entry.get("look", {})
	if not look.is_empty():
		var background: Color = cfg.get(String(look["background_color"]))
		var sky: Color = cfg.get(String(look["sky_color"]))
		_apply_overcast_look(background, sky,
			float(cfg.get(String(look["sun_energy_mult"]))),
			float(cfg.get(String(look["fog_density_mult"]))),
			float(cfg.get(String(look["fog_sky_affect"]))), cfg)
	# Sky override. Optional, and applied AFTER the region look so a condition that
	# names one wins over the region's choice; conditions that omit it (all but night)
	# leave the region's sky exactly as _apply_region_look seeded it. Safe against a
	# stale value because that seeding is now unconditional.
	var sky_field := String(entry.get("sky_panorama", ""))
	if sky_field != "":
		var sky_path := String(cfg.get(sky_field))
		var sky_mat := $WorldEnvironment.environment.sky.sky_material as PanoramaSkyMaterial
		if sky_mat and sky_path != "":
			sky_mat.panorama = load(sky_path)
	var road_tint: Dictionary = entry.get("road_tint", {})
	if not road_tint.is_empty():
		# The entry says WHAT to tint toward, never how: naming a "color" field means
		# lerp toward it, omitting one means a plain darkening multiply. No condition
		# is named here and no colour literal lives here.
		var tint_color_field := String(road_tint.get("color", ""))
		var toward: Color = cfg.get(tint_color_field) if tint_color_field != "" else Color.BLACK
		_tint_road(float(cfg.get(String(road_tint["amount"]))), toward, tint_color_field != "")
	# The particle field itself — built ONLY when the entry names a particle kind,
	# i.e. never on a dry stage (and never on a future no-particle condition).
	var particles := String(entry.get("particles", ""))
	if particles != "":
		var count := int(cfg.get(String(entry["particle_count"])))
		var wind_field := String(entry.get("wind_dir", ""))
		var wind_deg := float(cfg.get(wind_field)) if wind_field != "" else 0.0
		# Travel speed, like every other value, comes from the field the ENTRY names —
		# WeatherField never reads a condition's config field itself. 0.0 means "the
		# particle kind's own built-in speed" (rain's authored fall constant).
		var speed_field := String(entry.get("particle_speed", ""))
		var speed := float(cfg.get(speed_field)) if speed_field != "" else 0.0
		WeatherField.spawn($ChaseCamera as Camera3D, particles, count, wind_deg, speed)
	# Lightning — only when the entry authors one (storm today). Same shape as the
	# blocks above: an absent key means the feature simply does not exist here.
	var lightning: Dictionary = entry.get("lightning", {})
	if not lightning.is_empty():
		_start_lightning(cfg, lightning)


# An occasional lightning flash on a storm stage. Deliberately NOT a light node: the
# renderer is unshaded with baked vertex lighting and has no lights at all (see
# features/rendering.md), so the flash is a short tween on the two environment
# colours the weather look ALREADY drives — the fog/background colour. Nothing else
# is touched, so it costs one Timer and one brief tween, and it cannot desync the
# baked terrain shading (which would need a rebake to change).
#
# Purely cosmetic: it changes no physics and no time, so it need NOT be deterministic
# and is free to use randf(). Kept subtle and infrequent on purpose — a flash that
# blanks the screen mid-corner is a gameplay event, not an effect.
func _start_lightning(cfg: GameConfig, lightning: Dictionary) -> void:
	var env: Environment = $WorldEnvironment.environment
	var base: Color = env.fog_light_color
	var flash: float = float(cfg.get(String(lightning["flash"])))
	var duration: float = float(cfg.get(String(lightning["duration"])))
	var gap_min: float = float(cfg.get(String(lightning["interval_min"])))
	var gap_max: float = float(cfg.get(String(lightning["interval_max"])))
	var timer := Timer.new()
	timer.name = "Lightning"
	timer.one_shot = true
	add_child(timer)
	var schedule := func () -> void:
		timer.start(randf_range(gap_min, maxf(gap_min, gap_max)))
	timer.timeout.connect(func () -> void:
		var lit := Color(base.r * flash, base.g * flash, base.b * flash, base.a)
		var tween := create_tween()
		# A paused game must be visually STILL: without this the flash keeps tweening
		# behind the pause menu (TWEEN_PAUSE_STOP, not the default bound-node mode).
		tween.set_pause_mode(Tween.TWEEN_PAUSE_STOP)
		# Fast rise, slower fall — the shape of a real strike.
		tween.tween_method(_set_fog_light, base, lit, duration * 0.25)
		tween.tween_method(_set_fog_light, lit, base, duration * 0.75)
		tween.finished.connect(schedule)
	)
	schedule.call()


# Tween target for the lightning flash: the fog colour doubles as the horizon /
# background colour, so writing both keeps the sky and the haze in step.
func _set_fog_light(col: Color) -> void:
	var env: Environment = $WorldEnvironment.environment
	env.fog_light_color = col
	env.background_color = col


# Shared environment + baked-terrain-light override for both rain and sandstorm:
# a flat sky/fog colour, a knocked-back sun, thicker fog, and fog washing out the
# panorama. Written straight onto the TerrainManager (not onto cfg) so the shared
# config resource is never left dimmed/tinted for a later dry stage.
func _apply_overcast_look(background: Color, sky: Color, sun_mult: float,
		fog_density_mult: float, fog_sky_affect: float, cfg: GameConfig) -> void:
	var env: Environment = $WorldEnvironment.environment
	env.background_color = background
	env.fog_light_color = background
	env.fog_density = cfg.fog_density * fog_density_mult
	env.fog_sky_affect = fog_sky_affect
	var tm := _floor()
	var sun: Color = cfg.sun_color * sun_mult
	sun.a = cfg.sun_color.a
	tm.sun_color = sun
	tm.sky_color = sky
	# Hand the same dimming to the car materials. The terrain bakes `sun` into its
	# vertex colours below; apply_car_light reads this to match, so the car dims with
	# the world instead of staying at full sun. Set here rather than passed around
	# because the car meshes are lit later in _ready, and car.gd lights swapped-in
	# body models later still.
	cfg.weather_sun_mult = sun_mult


# Tint the road/ground albedo for a condition. Two shapes, chosen by whether the
# entry named a target COLOUR field (`blend`), never by which condition it is:
#   * no colour  — a straight multiply (a wet road is DARKER, not recoloured);
#   * a colour   — a lerp toward it (dust CAKES on the surface; snow would whiten it).
# The colour itself is authored in game_config.tres and named by the entry, so
# nothing here needs editing to add a condition that tints toward something new.
#
# This is a read-modify-write, and both parameters it touches are RE-SEEDED from the
# authored baseline in _ready (tarmac_color from the config/region look, albedo_color
# from `terrain_tint`) before this runs. That is what makes it idempotent — the
# material is a shared sub-resource of main.tscn, so tinting an already-tinted value
# would compound across stages and leak into later dry ones. Do not remove either
# re-seed. Reading the parameter back (rather than computing from the config) is
# deliberate, so the tint composes with whatever palette the region chose.
func _tint_road(amount: float, toward: Color, blend: bool) -> void:
	var floor_mat := $Floor.chunk_material as ShaderMaterial
	var tinted: PackedStringArray = ["albedo_color", "tarmac_color"]
	for param in tinted:
		var col: Color = floor_mat.get_shader_parameter(param)
		var out: Color
		if blend:
			out = col.lerp(Color(toward.r, toward.g, toward.b, col.a), amount)
		else:
			out = Color(col.r * amount, col.g * amount, col.b * amount, col.a)
		floor_mat.set_shader_parameter(param, out)

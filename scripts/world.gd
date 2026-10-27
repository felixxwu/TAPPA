extends Node3D
# Docs: features/benchmark.md, features/lakes.md — update in the same change as this file.
# Tests: tests/headless/test_benchmark_ui.gd, tests/headless/test_lake_field.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'world' tests/headless/` and read the assertions that pin what you are about to change (8 test files touch this script).
# Applies the central GameConfig to scene-owned resources at startup.
# Car handling is applied by car.gd; camera follow by chase_camera.gd.

const BUSH_SEED_OFFSET := 1013
# Rocks get their own scatter seed so their lattice interleaves with the trees' and the
# bushes' instead of landing on the same jittered grid points (see TreeScatter._grid_phase).
# Distinct from BUSH_SEED_OFFSET for the same reason; the value is arbitrary, only its
# difference matters.
const ROCK_SEED_OFFSET := 2027

# The two terrain shaders the floor material swaps between per stage, and the loading-window
# frame caps, live in WorldRuntime (scripts/world_runtime.gd); the reasoning for each is on
# the consts there.

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
# --headless (nothing to pace, and it would throttle the test runner). See WorldRuntime.apply_fps_cap.
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

	var cfg: GameConfig = Config.data
	# A one-shot notice from the Start gate (today: the free upgrade restore) replaces
	# the loading tip for this one load — it is about the car the player is sitting in,
	# which beats a generic tip, and taking it here clears it so the remaining stages
	# go back to tips.
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

	# Phase: the diagnostic overlay, the pause menu arm, and benchmark mode.
	_build_overlays_and_benchmark()


# _ready phase: apply the central GameConfig to every scene-owned resource — environment,
# floor/terrain, the car materials, the post-process pass. Ordering inside here is
# load-bearing and commented at each step; nothing in it awaits.
func _apply_scene_config(cfg: GameConfig) -> void:
	var env: Environment = $WorldEnvironment.environment
	# Fog, backdrop and glow — shared with the menu showcase (GameConfig.apply_environment).
	cfg.apply_environment(env)
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
	# region may override it (Greece runs a dark, warm asphalt); home / free
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


# _ready phase: hold the car still for the boot and field the right car for this mode
# (challenge / rally / free roam / dev boot). Nothing here awaits.
func _field_player_car() -> void:
	# Hold the car still for the entire boot. Generation below spans many awaited
	# frames with the loading overlay up (non-headless); the car is already in the
	# tree and physics-processing, so without this lock the player could press W and
	# drive off behind the loading screen. Set BEFORE the car is fielded so it's
	# inert the instant it exists (no fielding→lock gap). Every spawn path resets
	# controls_locked at the end of generation — StageManager.setup and BenchmarkRunner.setup — so this only
	# governs the loading window itself.
	$Car.controls_locked = true

	# Field the first library car. This scene is the dev stage and the physics test
	# harness now (the run loop that fielded owned cars here
	# is deleted with the free-roam pivot, todo/2026-10-19-free-roam-pivot.md stage 8).
	$Car.apply_car(0)
	# The bonnet camera is a scene child of $Car (not re-parented at boot), so
	# apply the newly-fielded car's per-car bonnet offset now — retarget() only
	# runs on a later car swap.
	($CameraManager as CameraManager).refresh_bonnet_offset()


# _ready phase: the in-game diagnostic overlay, arming the pause menu now the world is ready,
# Nothing here awaits.
func _build_overlays_and_benchmark() -> void:
	# Diagnostic frame-profiler overlay (toggle with P). Created in code like the
	# wheel-force debug overlay; harmless and idle until toggled on. Render times
	# are measured on the PostProcess SubViewport — the viewport that actually
	# does the 3D work while main.tscn is up (the root's 3D pass is disabled).
	var perf := PerfOverlay.new(_floor())
	perf.measure_viewport = get_node_or_null("PostProcess/View") as Viewport
	perf.engine_audio = $Car.get_node_or_null("EngineAudio")  # live audio-overrun readout
	add_child(perf)

	# Pause-menu "Reset to track" delegates the reset up here (it has no car ref;
	# this scene owns the car / track / stage manager).
	var pause_menu := _pause_menu()
	if pause_menu != null:
		if not pause_menu.reset_to_track_requested.is_connected(_on_reset_to_track_requested):
			pause_menu.reset_to_track_requested.connect(_on_reset_to_track_requested)
		# Pause-menu "Photo Mode" hands the frozen screen up here too — the free-fly
		# camera has to take over the viewport and hide the HUD, both of which this
		# scene owns. See features/camera.md.
		if not pause_menu.photo_mode_requested.is_connected(_on_photo_mode_requested):
			pause_menu.photo_mode_requested.connect(_on_photo_mode_requested)
		# Arm the pause menu now the world is generated — it's default-inert
		# (fail-closed) so the Pause button / Esc can't open it during the awaited
		# generation above, where pausing would freeze the tree mid-build and let the
		# player quit/resume into a half-built world. This block runs after
		# _generate_track in every mode (a regeneration re-runs _ready), so it's the
		# single "world is ready" chokepoint for pause.
		pause_menu.set_input_enabled(true)


# Yield a frame so a freshly-set LoadingScreen step actually paints before the
# next blocking generation call. A no-op under headless, where the await would
# otherwise spread world generation across frames and break tests that inspect
# the world right after instantiating main.tscn — there the whole _ready chain
# runs synchronously within add_child(), as it did before staged loading.
# See WorldRuntime.yield_frame.
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
# shader). The camera part lives in WorldRuntime.warm_up_point; the fallback
# (the authored $Car) is supplied here.
func _warm_up_point() -> Vector3:
	var fallback := ($Car as Node3D).global_position if has_node("Car") else Vector3.ZERO
	return WorldRuntime.warm_up_point(get_viewport().get_camera_3d(), fallback)


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

	# Phase 1 — "Generating track…": the road shape and the start pose.
	var shape := await _generate_centerline(cfg)
	var result: Dictionary = shape["result"]
	var road_centerline := shape["road_centerline"] as Curve2D
	var finish_len: float = shape["finish_len"]
	var start_pos: Vector2 = shape["start_pos"]
	var start_heading: Vector2 = shape["start_heading"]

	# Phase 2 — "Carving road into terrain…": the road bake (flatten + surface split +
	# cliffs) and the final waterline pass it makes possible.
	await _carve_road_into_terrain(cfg, loading, road_centerline, result.get("pieces", []))

	# Phase 3 — "Precomputing chunks…" / "Building terrain…": every chunk the play area
	# realistically requests, then the initial ring built once from that cache.
	await _build_terrain_ring(road_centerline)

	# Ground exists (carved, coloured, cache-built) — hand the car back to the physics
	# engine. Everything after this point still runs behind the loading cover, so it has
	# many frames to settle onto its wheels before the player or the start line sees it.
	car_body.freeze = was_frozen

	# Phase 4 — "Placing props…": everything that stands ON the built world (backdrop,
	# foliage, lakes, signs, barriers, spectators, arches, the wreck, the managers).
	await _place_world_props(cfg, result, road_centerline, finish_len,
		start_pos, start_heading)

	# Phase 5 — "Warming shaders…": first-use shader compilation, absorbed behind the
	# loading cover. Interactive path only (see the function).
	await _warm_shaders_behind_cover(loading)

	# World is ready — drop the loading overlay (absent for direct/programmatic
	# regeneration, e.g. entering a rally event). Staged runs keep it up a moment
	# longer: _ready drops it only AFTER the start-line queue is laid out, so the
	# black overlay hides the car at its pre-staged spot instead of flashing it.
	if loading != null:
		loading.finish()


# Phase 1 of _generate_track. Generates the road centerline from the car's spawn pose and
# returns the shape contract the later phases read:
#   result, road_centerline, finish_len, start_pos, start_heading.
func _generate_centerline(cfg: GameConfig) -> Dictionary:
	await _stage("Generating track…")
	var xform: Transform3D = $Car.global_transform
	var start_pos := Vector2(xform.origin.x, xform.origin.z)
	# A Node3D's forward is -Z; project it onto the XZ plane.
	var fwd := -xform.basis.z
	var start_heading := Vector2(fwd.x, fwd.z).normalized()
	# The track comes from the live config (seed, turn count, width, water): this scene is the
	# dev stage and the physics test harness, so whoever loads it writes the config first.
	var params := TrackGenParams.for_config(cfg)
	# The dry-start search may relocate the generation origin onto dry ground. Derive
	# the start-LINE pose from params (absolute, idempotent — never accumulates across
	# re-generation on a reused car) and seat the car + start_pos there. For a staged
	# run the start line sits one lead-in ahead behind the generation origin.
	# Seat the car on the road's actual start whenever it disagrees with the spawn.
	var start_line := params.origin
	if start_line != start_pos:
		start_pos = start_line
		# A bare global_position write is discarded by the physics server outside the
		# physics step; move_spawn_to queues it properly and updates the R-reset pose.
		$Car.move_spawn_to(start_line)
	var result: Dictionary = await TrackGenerator.generate(params)
	# The gradient profile of the terrain the player drives, attached to the result.
	#
	# Keyed off `cfg`, matching $Floor above (seeded from cfg.track_seed), so this is the
	# terrain the player actually drives even on a challenge stage whose seed was bumped.
	result["road_height"] = TerrainNoise.make_sampler(cfg.track_seed, cfg.terrain_layers())
	# Reconcile the live config to the waterline generation ACTUALLY used. `params` is
	# the single source of truth for water: TrackGenParams.recompute_origin can clamp
	# water_level down (or switch water_enabled off entirely) when no dry start exists
	# within budget, and that adjustment never reaches cfg on its own. Everything
	# downstream reads cfg — the rendered/collided lake (_build_lakes), the chase
	# camera's ground seat, the submersion reset in track_progress.gd — so without this
	# they'd all use a waterline the terrain doesn't have: the lake disagrees with the
	# terrain, and the camera detaches from the chase view over a basin it
	# wrongly believes is flooded.
	cfg.water_enabled = params.water_enabled
	cfg.track_water_level_m = params.water_level
	# Road/progress centerline (with the lead-in for staged runs). The raw generated
	# centerline still feeds the signs, so the start gate sits ahead of the launch
	# point — the cars cross it as they pull away.
	var road_centerline := result["centerline"] as Curve2D
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
	}


# Phase 2 of _generate_track: bake the road into the terrain (flatten + surface split +
# cliffs) — the heaviest single step.
func _carve_road_into_terrain(cfg: GameConfig, loading: LoadingScreen,
		road_centerline: Curve2D, pieces: Array) -> void:
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
	# Vertical channel: plan the crests against `road_centerline`, the SAME curve about
	# to be baked (already reassigned to the runoff-extended curve by the caller, past
	# _with_finish_runoff). The runoff is appended past the finish, so offsets from the
	# start are identical either way, but planning against the baked curve keeps that a
	# fact rather than a coincidence. [] when the generated track has no Jump piece —
	# TrackProfile.offset_at treats an empty plan as a free no-op.
	var jumps := TrackProfile.plan(
		road_centerline, pieces, cfg.jump_height_m, cfg.jump_span_m)
	# Baking the road into the terrain (flatten + surface split + cliffs) is the heaviest
	# single step; give it its own label and let it yield frames (interactive path only —
	# should_yield stays false under headless) so the overlay keeps painting, not freezing.
	await _stage("Carving road into terrain…")
	await $Floor.set_track(road_centerline, bake_args[0], bake_args[1],
		bake_args[2], bake_args[3], bake_args[4],
		interactive, Callable(), jumps)
	# Retained for post-build consumers outside this call (the benchmark runner
	# follows the same road the progress manager measures).
	_road_centerline = road_centerline


# Phase 3 of _generate_track: precompute the corridor chunks, then build the initial terrain
# ring once from that cache (so no chunk is ever rebuilt at startup).
func _build_terrain_ring(road_centerline: Curve2D) -> void:
	# Precompute every chunk the play area realistically requests (the track-progress
	# leash sizes it), so in-run chunk loads are instant cache pulls and
	# height_at/light_at serve the flattened, collidable terrain. Batched with
	# frame awaits so the loading label paints and (on web) the tab stays alive.
	await _stage("Precomputing chunks…")
	var floor_tm := _floor()
	floor_tm.set_corridor(floor_tm.corridor_coords(
		road_centerline, Config.data.track_progress_max_dist_m))
	var precompute_done := 0
	for coord in floor_tm.corridor():
		floor_tm.cache_chunk(coord)
		precompute_done += 1
		if precompute_done % 8 == 0:
			await _yield_frame()
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
		finish_len: float, start_pos: Vector2, start_heading: Vector2) -> void:
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

	# Solid crash barriers along the outside of the sharp corners. After the road
	# bake, which is what makes the surface split (gravel vs tarmac) readable — the
	# barrier style follows it.
	if cfg.barriers_enabled:
		_build_barriers(cfg, result)

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

	# The roadside opponent wreck used to be staged here — deleted with the rival
	# field it dramatized (todo/roguelike-pivot.md decision 5).

	# Persistent per-stage managers (progress, tire marks, road paint, wheel dust,
	# engine smoke, stage flow).
	_build_persistent_managers(cfg, result, road_centerline, finish_len)


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


# Create-or-reuse the persistent per-stage managers and wire the stage splits. Each
# node is reused across regenerations (entering a new event) via _ensure_child, so
# managers don't accumulate or collide on name.
func _build_persistent_managers(cfg: GameConfig, _result: Dictionary,
		road_centerline: Curve2D, finish_len: float) -> void:
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
	# green) and shape (snow throws square clods of powder, not slim grass blades) —
	# falls back to GameConfig when the region authors none.
	_wheel_particles.apply_region_look(region_look)

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

	# Glowing head and tail lamps at the car's authored lamp centres: headlights with the
	# night cone, tail lamps with it (dimmer) and under the foot brake. See features/car-lamps.md.
	_car_lamps = _ensure_child("CarLamps",
		func() -> Node: return CarLamps.new()) as CarLamps
	_car_lamps.setup($Car)

	# Per-stage start/end flow: lock the car, count down, time the run, and signal
	# completion when progress reaches the finish (todo/stage-start-and-end.md).
	# A benchmark run skips the whole stage flow — the manager is left un-armed
	# (no countdown, no control lock) and BenchmarkRunner drives instead.
	_stage_manager = _ensure_child("StageManager",
		func() -> Node: return StageManager.new()) as StageManager
	if not Benchmark.active:
		# Staged runs hold the car in the start-line sequence until the player launches;
		# otherwise the countdown arms immediately, as before.
		_stage_manager.setup($Car, _track_progress)


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


# Tracks track progress + off-track reset for the car.
var _track_progress: TrackProgress

# The rendered road/progress centerline from the latest generation (lead-in +
# runoff included) — kept for the benchmark runner's pursuit line.
var _road_centerline: Curve2D


# Owns the per-stage countdown -> run timer -> completion flow for the current
# stage (recreated on each track regeneration).
var _stage_manager: StageManager

# Lays gravel tire-mark ribbons behind the wheels for the car.
var _tire_marks: TireMarks
var _road_markings: RoadMarkings

# Flings cheap gravel dust off the driven wheels under wheelspin.
var _wheel_particles: WheelParticles
var _engine_smoke: EngineSmoke
var _exhaust_flames: ExhaustFlames
var _car_lamps: CarLamps


# Coarse far-terrain backdrop that gives the sky a horizon (distant_terrain.gd).
var _distant_terrain: DistantTerrain


# The free-fly PHOTO MODE camera while it's up, else null (see _on_photo_mode_requested).
var _photo_camera: PhotoModeCamera
# On-screen touch controls for photo mode, built alongside the camera ONLY on a touch
# device (Platform.is_touch()) — see _on_photo_mode_requested/_on_photo_mode_finished.
var _photo_controls: PhotoModeControls


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


# Pause-menu Photo Mode: hand the screen to a free-fly PhotoModeCamera with the tree
# still paused (the pause menu deliberately does not unpause on the way in), so the
# world is frozen and only the viewpoint moves. This scene owns the pieces the camera
# needs taken care of:
#
#  - the HUD / touch controls / speed lines are hidden, so the shot is unobstructed;
#  - PostProcess is switched to PROCESS_MODE_ALWAYS. Its _process mirrors the current
#    camera into the SubViewport that actually renders the world (see
#    post_process_view.gd) — left PAUSABLE it freezes with everything else and the
#    photo camera would move with nothing on screen changing.
#
# Every one of those is put back in _on_photo_mode_finished.
func _on_photo_mode_requested() -> void:
	if is_instance_valid(_photo_camera):
		return  # already flying (a double-press); nothing to do
	_photo_camera = PhotoModeCamera.new()
	_photo_camera.name = "PhotoModeCamera"
	_photo_camera.exited.connect(_on_photo_mode_finished)
	add_child(_photo_camera)
	_photo_camera.enter(get_viewport().get_camera_3d())
	_set_photo_mode_chrome(false)
	# Touch controls: the phone has no Esc key and MobileControls is hidden above, so
	# without these a touch player would be stuck flying with no way out. Desktop/native
	# gets none — the mouse+keyboard path above already covers it.
	if Platform.is_touch():
		_photo_controls = PhotoModeControls.new()
		_photo_controls.name = "PhotoModeControls"
		add_child(_photo_controls)
		_photo_controls.setup(_photo_camera)


# Esc in photo mode: drop the camera, restore the chrome, re-assert the player's chosen
# gameplay camera and give the (still frozen) pause menu back.
func _on_photo_mode_finished() -> void:
	if is_instance_valid(_photo_controls):
		remove_child(_photo_controls)
		_photo_controls.queue_free()
	_photo_controls = null
	if is_instance_valid(_photo_camera):
		# Detach BEFORE queue_free: the free lands at the end of the frame, so a photo
		# mode re-opened in the same frame would otherwise collide with the dying node's
		# name and land as "PhotoModeCamera2".
		remove_child(_photo_camera)
		_photo_camera.queue_free()
	_photo_camera = null
	_set_photo_mode_chrome(true)
	if has_node("CameraManager"):
		($CameraManager as CameraManager).activate_current()
	var pause_menu := _pause_menu()
	if pause_menu != null:
		pause_menu.return_from_photo_mode()


# Show (`on = true`) or hide the in-run screen furniture around the photo camera, and
# flip the post-process mirror between PAUSABLE and ALWAYS with it. One writer for both
# halves so an early return can never restore the overlays but leave the mirror running.
func _set_photo_mode_chrome(on: bool) -> void:
	for node_name in ["HUD", "MobileControls", "SpeedLines"]:
		var layer := get_node_or_null(node_name) as CanvasLayer
		if layer != null:
			layer.visible = on
	var post := get_node_or_null("PostProcess") as Node
	if post != null:
		post.process_mode = (Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_ALWAYS)


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

func _mat(mesh_instance: MeshInstance3D) -> ShaderMaterial:
	return mesh_instance.get_surface_override_material(0) as ShaderMaterial


# The look overrides the stage wears: the plain home look.
func _current_region_look() -> Dictionary:
	return RegionLibrary.look_of("home")


# The headlight cone follows the car every frame on a stage whose weather switches the
# lights on (night, storm). This is the only per-frame work the feature does:
# three-to-seven global uniform writes, no geometry, no draw calls. Elsewhere push()
# early-outs into a reset, so the cost on every other stage is one branch.
func _process(_delta: float) -> void:
	if not HeadlightCone.has_headlights(Config.data):
		return
	HeadlightCone.push(Config.data, $Car.global_transform, $Car.half_width() * 2.0)


# Global shader parameters PERSIST ACROSS SCENE CHANGES, and the free-roam world draws
# trees and ground with the same shaders — so a stage that lit its headlights must
# clear up after itself or it leaves a stray cone burning there. _exit_tree covers
# every exit path regardless of destination, which a per-destination reset would not.
func _exit_tree() -> void:
	HeadlightCone.reset()
	# Same leak the cone guards against: the podium/menu showcase render trees with
	# the same shader, so a storm-strength sway must not keep blowing after this
	# stage is exited. Unlike the cone, WindSway.reset() lands on the shared BASE
	# wind rather than 0 — off-stage foliage should still be alive.
	WindSway.reset()
	# Same reasoning, different mechanism: weather_sun_mult is a runtime value on the
	# SHARED Config.data, and nothing calls Config.reset(), so a night stage would
	# otherwise leave the HQ and podium dimmed — both spawn trees through
	# Foliage.spawn_trees, which now reads this via apply_foliage_light. The scene
	# tree frees the outgoing scene before the incoming one's _ready, so clearing it
	# here lands before anything else can read it.
	Config.data.weather_sun_mult = 1.0


# The shader swap itself lives in WorldRuntime.apply_deep_snow,
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
	# Tree wind sway is a LOOK (same reasoning as headlight_amount above: authored
	# per-condition, driven as a shader global, zero CPU per frame) so it's pushed
	# here rather than from a physics path. A no-op on a condition naming no
	# "foliage_wind" — it lands on the shared base, the same as every other condition.
	WindSway.push(cfg, cfg.weather)
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
		floor_mat.set_shader_parameter(param, WeatherLibrary.tinted(col, amount, toward, blend))

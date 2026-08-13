extends Node3D
# Applies the central GameConfig to scene-owned resources at startup.
# Car handling is applied by car.gd; camera follow by chase_camera.gd.

const BUSH_SEED_OFFSET := 1013

# car.gd has no class_name; preload it to reach its static helpers (compression_budget).
const CarScript := preload("res://scripts/car.gd")

# Assets for a staged roadside opponent wreck (features/opponent-wrecks.md). The car
# is the same scene the player drives (spawned as a frozen prop, like the podium/HQ
# display cars); the onlookers reuse the shared low-poly spectator figure.
const WRECK_CAR_SCENE := "res://car.tscn"

# Frame cap applied for the DURATION of world generation only (see _ready). Loading
# yields hundreds of frames, and a low cap makes each of those yields idle away most
# of its frame budget instead of generating. Bounded rather than uncapped on touch:
# running a phone flat-out through a long load is the thermal/battery failure this is
# meant to avoid, and a throttled phone then plays worse. 0 = uncapped. Deliberately
# NOT a GameConfig field — a transient loading-only cap is not a value anyone retunes.
const LOADING_MAX_FPS := 0         # non-touch (desktop/native): no ceiling for the load
const LOADING_TOUCH_MAX_FPS := 60  # touch/web: fast, but still a ceiling

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
# --headless (nothing to pace, and it would throttle the test runner).
func _apply_fps_cap(cap: int) -> void:
	applied_fps_caps.append(cap)
	if not Platform.is_headless():
		Engine.max_fps = cap


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
	var start_notice := RallySession.take_start_notice()
	if start_notice != "":
		loading.set_step(start_notice)
	# Tell the player which stage of the rally is loading (no-op for a one-stage rally or a
	# session-less drive). Replaced the weather tell that used to own this line.
	if RallySession.is_active():
		loading.set_stage(RallySession.event_index(), RallySession.stage_count())
	elif ChallengeSession.is_active():
		loading.set_stage(ChallengeSession.events_completed(), ChallengeSession.stage_count())
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
		_apply_fps_cap(LOADING_TOUCH_MAX_FPS if _touch else LOADING_MAX_FPS)
	else:
		_apply_fps_cap(fps_cap)
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
	# Terrain seed follows the per-event track_seed so each event has its own
	# landscape (and lake layout). The road DFS doesn't read terrain when water is
	# off, so this changes only the visible elevation for water-off events, not the
	# road shape or opponent times. (Setter invalidates the noise cache + rebuilds.)
	if $Floor.noise_seed != cfg.track_seed:
		$Floor.noise_seed = cfg.track_seed
	# Assigning layers triggers a full terrain regeneration; skip when equal.
	if not _layers_match($Floor.layers, cfg.terrain_layers()):
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

	# Hold the car still for the entire boot. Generation below spans many awaited
	# frames with the loading overlay up (non-headless); the car is already in the
	# tree and physics-processing, so without this lock the player could press W and
	# drive off behind the loading screen. Set BEFORE the car is fielded so it's
	# inert the instant it exists (no fielding→lock gap). Every spawn path resets
	# controls_locked at the end of generation — StageManager.setup (locked for a
	# staged start line, unlocked otherwise) and BenchmarkRunner.setup — so this only
	# governs the loading window itself.
	$Car.controls_locked = true

	# Field the car. With an active RallySession this event runs the player's
	# OwnedCar (baseline + upgrades + saved HP, features/rally-session.md); a plain
	# dev boot keeps the first library car (the Mazda MX-5).
	_car_spawn = $Car.transform  # authored spawn, reused so swaps don't drift
	if ChallengeSession.is_active():
		_field_car(ChallengeSession.car_instance_id())
	elif RallySession.is_active():
		_field_car(RallySession.car_instance_id())
	elif RallySession.free_roam_instance_id >= 0 or RallySession.free_roam_model_id != "":
		# Free roam (session-less): field the car the player picked in the car park.
		# An OWNED instance runs with its baseline + upgrades + saved HP; a bare catalogue
		# MODEL (a not-yet-owned car picked in Free Roam) fields the base model by id.
		# Falls back to the default library car if neither resolves.
		var owned: Dictionary = Save.get_car(RallySession.free_roam_instance_id)
		if not owned.is_empty():
			$Car.apply_owned(owned)
		else:
			var idx := CarLibrary.index_of(RallySession.free_roam_model_id)
			$Car.apply_car(idx if idx >= 0 else 0)
	else:
		$Car.apply_car(0)
	# The bonnet camera is a scene child of $Car (not re-parented at boot), so
	# apply the newly-fielded car's per-car bonnet offset now — retarget() only
	# runs on a later car swap.
	($CameraManager as CameraManager).refresh_bonnet_offset()

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

	# The stage finish is handled in EVERY mode: a session run reports the event to
	# the orchestrator; free roam / a dev boot has no session, so the finish panel's
	# Next returns to HQ instead (_on_session_event_completed's no-session branch).
	if _stage_manager != null and not _stage_manager.stage_completed.is_connected(_on_session_event_completed):
		_stage_manager.stage_completed.connect(_on_session_event_completed)
	# A session run additionally wires the wreck back to the orchestrator, and
	# routes the rally's finish to the podium.
	# A rally event and a challenge stage take the SAME path here (they're mutually
	# exclusive — only one session is ever active): wire the signals, stage the
	# start line, then drain that session's pending pit repair. The only thing that
	# differs between the two is WHICH orchestrator the repair summary comes from,
	# so this is one block with one branch rather than two near-identical ones.
	if RallySession.is_active() or ChallengeSession.is_active():
		_wire_session_signals()
		# Pre-event start-line scene: briefing + presence cars before the countdown
		# (todo/menus.md location 2). Only when staged (start_line_enabled + a real
		# rally / challenge stage); the StageManager is already waiting in STAGING for
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
		# the engineers have patched the fielded car up (RallySession._enter_event /
		# Save.field_repair, already applied before this reload). Shown AFTER the
		# loading overlay is gone — staged runs keep it up until _build_start_line +
		# loading.finish() just above, non-staged runs drop it inside _generate_track —
		# so the popup sits over the ready world / start-line reveal, not a frozen
		# loading screen. Headless just drains the summary so it can't replay on a
		# later scene rebuild.
		# Only pop up for a repair that moved health by at least the min threshold — a
		# smaller touch-up (e.g. wheels-only on a near-full car) still applied to the
		# save, it just doesn't interrupt the player (RepairReveal.worth_showing).
		var repair: Dictionary = ChallengeSession.take_pending_repair() if ChallengeSession.is_active() \
			else RallySession.take_pending_repair()
		if RepairReveal.worth_showing(repair) and not _headless:
			await _show_repair_popup(repair)

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
func _yield_frame() -> void:
	if not _headless:
		await get_tree().process_frame


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
# shader). Falls back to the car's position if no camera is up yet.
func _warm_up_point() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		return cam.global_position - cam.global_transform.basis.z * 2.0
	if has_node("Car"):
		return ($Car as Node3D).global_position
	return Vector3.ZERO


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


# Build the track from the car's spawn pose, bake road heights, and build the
# (deferred) terrain ring with flattening + colouring already applied — so no
# chunk is ever rebuilt at startup. Each heavy step sets the loading label and
# yields a frame first (outside headless) so the message paints before the
# blocking work runs; `loading` is freed once the world is ready.
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
	# `interactive` is the one predicate the rest of this function keys off: an overlay is
	# up AND we're not headless. Defined once here instead of re-spelled at each of the
	# eight sites below (it used to be, and was locally re-bound under three different
	# names), so the interactive and headless paths cannot drift apart.
	var interactive := loading != null and not _headless
	var on_progress := Callable()
	if interactive:
		on_progress = loading.update_track_preview
	# Build the shape contract. In a rally, use the current event so the shape (and
	# its water avoidance) matches the times RallySession derived; a challenge stage
	# uses ChallengeSession's rolled TrackGenParams-shaped stage dict the same way
	# (spec §1/§4 — the seed comes from the period hash, not a RallyLibrary event,
	# but the dict shape TrackGenParams.for_event reads is identical); free-roam
	# uses the live cfg. The factory seats the staged origin from cfg and relocates
	# it onto dry ground if the start would be underwater — identical logic to the
	# target derivation, so the shapes stay in sync.
	var event := ChallengeSession.current_stage_params() if ChallengeSession.is_active() \
		else RallySession.current_event()
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
	# seed instead of an unplayable stage. Rally events are excluded (their seeds are
	# already lockfile-verified; a genuine live miss/incomplete there is a data bug worth
	# surfacing loudly, not silently routing around).
	if ChallengeSession.is_active() and not bool(result.get("complete", false)):
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
			push_error("ChallengeSession stage generation failed after retries (period=%s stage seed=%d turn_count=%d) — falling back to whatever partial track was found" \
				% [ChallengeSession.period_key(), base_seed, params.turn_count])
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
	# Ground exists (carved, coloured, cache-built) — hand the car back to the physics
	# engine. Everything after this point still runs behind the loading cover, so it has
	# many frames to settle onto its wheels before the player or the start line sees it.
	car_body.freeze = was_frozen

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

	# Roadside opponent wreck: if a rival crashed out of THIS event, stage their ACTUAL
	# car by the verge — frozen (hitbox kept), smoking, with a small crowd around it
	# (features/opponent-wrecks.md). Uses the built centerline + terrain.
	_spawn_opponent_wreck(road_centerline, finish_len, _floor(), cfg)

	# Persistent per-stage managers (progress, tire marks, road paint, wheel dust,
	# engine smoke, stage flow) + the in-stage "vs P1" pace splits.
	_build_persistent_managers(cfg, result, road_centerline, finish_len, staged)

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

	# World is ready — drop the loading overlay (absent for direct/programmatic
	# regeneration, e.g. entering a rally event). Staged runs keep it up a moment
	# longer: _ready drops it only AFTER the start-line queue is laid out, so the
	# black overlay hides the car at its pre-staged spot instead of flashing it.
	if loading != null and not staged:
		loading.finish()


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
		($Car as Node).call("set_water_query",
			func(p: Vector3) -> bool: return floor_tm.height_at(p.x, p.z) < wl)
	# The loading preview already painted the waterline up-front (before generation,
	# see _generate_track → LakeField.preview_cells), so nothing to feed here.


# Scatter trees + ground-cover bushes around the stage and render both as binned
# MultiMesh fields (TreeMeshField), plus the pass-through bush hit volume. Takes the
# already-generated track `result` + rendered `road_centerline`; owns the two
# loading steps. Returns {"trees", "road_cells"} — the tree points and road-margin
# cells the spectator layout reuses.
func _build_foliage(cfg: GameConfig, result: Dictionary, road_centerline: Curve2D) -> Dictionary:
	if not cfg.vegetation_enabled:
		# Foliage off (the benchmark's vegetation toggle): skip the scatter and the
		# fields entirely, but still hand the spectator layout the road-margin cells
		# it needs to keep crowds off the carriageway.
		var bare_cells := TrackGenerator.rasterize_cells(
			road_centerline.tessellate(), cfg.track_width + 2.0 * cfg.tree_road_margin_m)
		return {"trees": PackedVector2Array(), "road_cells": bare_cells}
	await _stage("Scattering trees…")
	# Scatter trees around each turn, then render them as solid low-poly meshes
	# binned into per-cell MultiMeshes (TreeMeshField) so the engine LOD-/cull-s
	# far bins. height_at needs the terrain noise cache, which build_initial() has
	# warmed. Reject trees on the visible road inflated by tree_road_margin_m —
	# NOT the clearance-inflated result["cells"], which is track_width +
	# 2*track_clearance wide and would push every tree metres back from the real
	# road edge. The margin keeps a small, tunable gap between trees and the road.
	var road_footprint := cfg.track_width + 2.0 * cfg.tree_road_margin_m
	var road_cells := TrackGenerator.rasterize_cells(
		road_centerline.tessellate(), road_footprint)
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
			load(entry["texture"]), String(entry.get("profile", "home")) == "region")

	# The region also defines whether the 3D ground-cover bushes spawn (spawn_bush_mesh —
	# e.g. Greece's arid map has no lush undergrowth); skip the whole bush pass if off.
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
	var bush_footprint := cfg.track_width + 2.0 * (cfg.tree_road_margin_m + bush_radius)
	var bush_road_cells := TrackGenerator.rasterize_cells(
		road_centerline.tessellate(), bush_footprint)
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

	# Grey smoke puffed from the bonnet each time a damaged engine misfires. Its own
	# small MultiMesh pool; reads the car's engine misfire counter live. See
	# features/engine-smoke.md.
	_engine_smoke = _ensure_child("EngineSmoke",
		func() -> Node: return EngineSmoke.new()) as EngineSmoke
	_engine_smoke.setup($Car)

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
		# In-stage "vs P1" pace popup: every few turns the HUD shows how the player's
		# elapsed time compares to the leading rival's estimated time at that point.
		_setup_stage_splits(result, staged, cfg)
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


# --- Roadside opponent wreck (features/opponent-wrecks.md) -------------------

# Stage the crashed rival's car by the roadside for the CURRENT event, if a rival
# wrecked in it. The ACTUAL car the rival drove is spawned off the verge as a frozen
# prop (its hitbox kept, so crashing into it still bites — it just won't be shoved),
# lazy engine smoke rising from it like a damaged HQ car, and a small standing crowd
# gathered around it. Named "OpponentWreck" so entering a new event replaces rather
# than stacks it. No-op without an active session, the feature disabled, no wreck this
# event, or a car id that no longer resolves.
func _spawn_opponent_wreck(centerline: Curve2D, finish_len: float,
		terrain: TerrainManager, cfg: GameConfig) -> void:
	_replace_named_child("OpponentWreck")
	if not cfg.opponent_wrecks_enabled or not RallySession.is_active():
		return
	var wreck := RallySession.current_event_wreck()
	if wreck.is_empty():
		return
	var idx := CarLibrary.index_of(String(wreck.get("car_id", "")))
	if idx < 0:
		return
	var baked := centerline.get_baked_length()
	var span := finish_len if finish_len > 0.0 else baked
	if span <= 0.0:
		return
	# Seeded crash point (fraction along the timed track) + which verge.
	var progress := clampf(float(wreck.get("progress", 0.5)), 0.0, 1.0)
	var side := signf(float(wreck.get("side", 1.0)))
	if side == 0.0:
		side = 1.0
	# Search near the seeded point for the FLATTEST patch of verge, so the wreck rests
	# on level ground beside the road rather than buried in a slope. `half_w`/`half_len`
	# are a conservative car footprint (m) used both to sample flatness and to keep the
	# car clear of the carriageway; the near side sits opponent_wreck_road_offset_m off
	# the road edge, and the search extends outward from there.
	var half_w := cfg.opponent_wreck_footprint_half_w
	var half_len := cfg.opponent_wreck_footprint_half_len
	var edge := cfg.track_width * 0.5
	var base_lat := edge + half_w + cfg.opponent_wreck_road_offset_m
	# Gate the site on the droop budget of the ACTUAL wreck car (apply_car overwrites
	# stiffness + per-axle travel from the library entry), not the base cfg.
	var wreck_spec: Dictionary = CarLibrary.CARS[idx]
	var gate_cfg: GameConfig = cfg.duplicate() as GameConfig
	gate_cfg.suspension_stiffness = wreck_spec.get("suspension_stiffness", cfg.suspension_stiffness)
	gate_cfg.suspension_travel = wreck_spec.get("suspension_travel", cfg.suspension_travel)
	gate_cfg.suspension_travel_front = wreck_spec.get("suspension_travel_front", 0.0)
	gate_cfg.suspension_travel_rear = wreck_spec.get("suspension_travel_rear", 0.0)
	var budget: float = CarScript.compression_budget(gate_cfg)
	var spot := _flattest_wreck_spot(centerline, baked, progress * span, side,
		base_lat, half_w, half_len, terrain, budget)
	var pos2: Vector2 = spot["pos2"]
	var tan2: Vector2 = spot["tan2"]
	var top_y: float = spot["top"]  # highest ground under the footprint — seat on top, never buried
	var outward := Vector2(-tan2.y, tan2.x) * side  # away from the road

	var container := Node3D.new()
	container.name = "OpponentWreck"
	add_child(container)

	# The crashed car, skewed off the road direction so it reads as wrecked, not parked
	# (deterministic from the seeded progress so it's stable across re-attempts). Placed
	# ON the highest ground under it (top_y is the seat plane); _spawn_wreck_car lifts it
	# by the car's analytic rest ride height so its wheels sit on the ground.
	var fwd := Vector3(tan2.x, 0.0, tan2.y)
	var skew := (fmod(progress * 41.0, 1.0) - 0.5) * 2.0 * cfg.opponent_wreck_yaw_skew
	var car_basis := Basis.looking_at(fwd, Vector3.UP).rotated(Vector3.UP, skew)
	_spawn_wreck_car(idx, Transform3D(car_basis, Vector3(pos2.x, top_y, pos2.y)), container, terrain,
		String(wreck.get("engine_id", "")))

	# The small gathering of onlookers, on the verge side of the wreck (off the road).
	_spawn_wreck_crowd(container, Vector3(pos2.x, top_y, pos2.y), outward, terrain, cfg)


# Find the flattest patch of verge near the seeded crash point: a small deterministic
# search over along-track and lateral offsets on the wreck's side. Returns the chosen
# centre `pos2`, the road tangent `tan2` there, and `top` = the highest terrain height
# under the car footprint at that centre (so the car seats on top and can't spawn
# buried). No RNG, so the wreck stays stable across re-attempts.
# Choose the wreck site from ordered candidates (best-placed first, e.g. nearest shoulder).
# Prefer the first whose terrain spread fits the suspension droop budget (no wheel floats);
# if none fit, fall back to the flattest and warn. Empty in -> empty out.
static func _pick_wreck_candidate(candidates: Array, budget: float) -> Dictionary:
	var flattest := {}
	var flattest_spread := INF
	for cand in candidates:
		var spread: float = cand["spread"]
		if spread <= budget:
			return cand
		if spread < flattest_spread:
			flattest_spread = spread
			flattest = cand
	if not flattest.is_empty():
		push_warning("wreck site: no verge within suspension budget (%.2f m); using flattest spread %.2f m" % [
			budget, flattest_spread])
	return flattest


func _flattest_wreck_spot(centerline: Curve2D, baked: float, seed_offset: float,
		side: float, base_lat: float, half_w: float, half_len: float,
		terrain: TerrainManager, budget: float) -> Dictionary:
	# Candidates in PREFERENCE order: nearest-shoulder first, then step outward, then
	# widen along-track. The gate picks the first that fits the droop budget (else flattest).
	var cands: Array = []
	for extra: float in [0.0, 1.0, 2.0, 3.0, 4.0, 6.0]:            # lateral: closest first
		for d_along: float in [0.0, -6.0, 6.0, -12.0, 12.0]:       # along-track: seed first
			var off := clampf(seed_offset + d_along, 0.05 * baked, 0.95 * baked)
			var c := centerline.sample_baked(off)
			var t := centerline.sample_baked(minf(off + 1.0, baked)) - c
			if t.length() < 1e-4:
				t = Vector2(0.0, 1.0)
			t = t.normalized()
			var road_out := Vector2(-t.y, t.x) * side
			var c2 := c + road_out * (base_lat + extra)
			var fp := _footprint_terrain(terrain, c2, t, half_len, half_w)
			cands.append({"pos2": c2, "tan2": t, "top": fp["top"], "spread": fp["spread"]})
	var chosen := _pick_wreck_candidate(cands, budget)
	if chosen.is_empty():
		# Degenerate curve: fall back to the seeded point.
		var c := centerline.sample_baked(clampf(seed_offset, 0.0, baked))
		chosen = {"pos2": c, "tan2": Vector2(0.0, 1.0), "top": terrain.height_at(c.x, c.y), "spread": 0.0}
	return chosen


# The terrain under a car footprint centred at `c2` (world XZ), aligned to tangent `t`:
# the height SPREAD across a small grid (flatness — lower is flatter) and the highest
# sampled point (`top`, so the car seats on top and no corner is buried).
func _footprint_terrain(terrain: TerrainManager, c2: Vector2, t: Vector2,
		half_len: float, half_w: float) -> Dictionary:
	var right := Vector2(-t.y, t.x)
	var lo := INF
	var hi := -INF
	for a: float in [-1.0, 0.0, 1.0]:
		for b: float in [-1.0, 0.0, 1.0]:
			var p := c2 + t * (a * half_len) + right * (b * half_w)
			var h := terrain.height_at(p.x, p.y)
			lo = minf(lo, h)
			hi = maxf(hi, h)
	return {"spread": hi - lo, "top": hi}


# Spawn the wrecked rival's car as a frozen roadside prop under `parent`. Mirrors the
# podium/HQ display-car recipe: an isolated config so its reshape can't clobber the
# player car's tuning, its own mesh copies, engine silenced. `seat` places the car on
# the ground plane (origin at the highest terrain under it); the car is lifted by its
# analytic rest ride height (car.gd:settled_ride_height) so its wheels sit on the ground
# and then frozen at once — no live physics, so it can't fall through the un-streamed
# verge, roll down a slope, or re-wreck on landing (all past bugs of the old drop-and-
# settle approach). FREEZE_MODE_STATIC (the default) keeps the collider, so the frozen
# wreck is a solid, immovable obstacle. Its HP is zeroed so the smoke reads it as a wreck.
func _spawn_wreck_car(library_index: int, seat: Transform3D, parent: Node, terrain: TerrainManager,
		engine_id := "") -> Node3D:
	# Shared display-prop recipe (CarProp.spawn): instantiate + isolated config +
	# apply_car + dup meshes + silence + freeze (+ synthetic wreck smoke). The wreck's
	# own steps — seat/settle, lock controls, zero HP — run in `configure` after the
	# meshes are duplicated. freeze is FREEZE_MODE_STATIC (default): collider stays a
	# solid obstacle.
	var configure := func(c) -> void:
		# Lift the car off its ground seat by its resting ride height so the wheels sit
		# on the ground, then settle the wheel visuals.
		c.global_transform = Transform3D(seat.basis, seat.origin + Vector3.UP * c.settled_ride_height())
		# Frozen prop: droop each wheel onto the terrain under it (analytic height — the
		# same surface the collider is built from, valid over the un-streamed verge).
		c.settle_wheels_to_ground(func(p: Vector3) -> float: return terrain.height_at(p.x, p.z))
		c.controls_locked = true  # driverless prop: ignore live input, hold the handbrake
		# Read as a wreck: 0 HP drives the synthetic smoke (a wrecked car smokes hardest),
		# exactly as a damaged HQ car does.
		if c.get("damage") != null:
			c.damage.hp = 0.0
	return CarProp.spawn(parent, load(WRECK_CAR_SCENE), {
		"index": library_index,
		# The wrecked rival's FITTED engine (event_wreck carries it — RallyLibrary
		# .RIVAL_IDENTITY_KEYS). Matters here only through engine mass -> resting ride
		# height, but keeps the staged wreck the same build the standings name.
		"engine_id": engine_id,
		"configure": configure,
		"disable_process": true,
		"smoke": _add_wreck_smoke,
	})


# Give the wreck lazy engine smoke like a damaged HQ display car: the frozen prop's
# engine never runs, so EngineSmoke self-times puffs from the car's (zeroed) damage
# severity. Parented to the car so it's freed with it, PROCESS_MODE_ALWAYS so it keeps
# puffing though the car itself is frozen / process-disabled.
func _add_wreck_smoke(car: Node) -> void:
	EngineSmoke.attach_synthetic(car)


# A small standing crowd of onlookers gathered around the wreck — pure scenery in one
# MultiMesh (no steering / ragdolls, like the HQ crowd), each facing the wreck. Placed
# in a crescent on the VERGE side (`outward` points away from the road), so the crowd
# never spills onto the carriageway. `center` is the wreck's ground position. No-op
# with a zero crowd size or a missing figure mesh.
func _spawn_wreck_crowd(parent: Node, center: Vector3, outward: Vector2,
		terrain: TerrainManager, cfg: GameConfig) -> void:
	var count := cfg.opponent_wreck_crowd_size
	if count <= 0:
		return
	var base_ang := atan2(outward.y, outward.x)  # away from the road
	var positions := PackedVector2Array()
	var yaws := PackedFloat32Array()
	for i in count:
		# A crescent spanning ±~115° about 'outward' — the verge side + flanks, never the
		# road-ward hemisphere between the wreck and the carriageway.
		var frac := 0.0 if count <= 1 else float(i) / float(count - 1)
		var ang := base_ang + lerpf(-cfg.opponent_wreck_crowd_arc_half, cfg.opponent_wreck_crowd_arc_half, frac)
		var r: float = cfg.opponent_wreck_crowd_radius_m
		var px := center.x + cos(ang) * r
		var pz := center.z + sin(ang) * r
		positions.append(Vector2(px, pz))
		# Face the wreck at the centre (the figure's default facing is +Z).
		yaws.append(atan2(center.x - px, center.z - pz))
	# The shared Crowd helper owns the figure mesh + foot offset + MultiMesh build
	# (and the `positions` meta tests read); it seats each figure on the terrain.
	var crowd := Crowd.multimesh_instance("WreckCrowd", positions, yaws, terrain.height_at, cfg)
	if crowd != null:
		parent.add_child(crowd)


# The live event framing — the event's name, which stage of how many, and the
# time-to-beat. Single source for BOTH the arch banners and the start-line header
# (_build_start_line), so a challenge stage reads its framing in exactly one place.
# The rally's difficulty tier is a hidden value, so it's deliberately not surfaced
# here. When no session is active (a dev boot / direct play) the fields stay
# empty/zero and the gate shows just its START / FINISH wordmark.
#
# A challenge has no rival field at all (spec §3), so `target_ms` stays -1 for it —
# FinishArch already omits the time row for a non-positive target, the same graceful
# empty state a session-less boot gets.
func _arch_event_info() -> Dictionary:
	var info := {"rally_name": "", "stage_index": 0, "stage_count": 0, "target_ms": -1}
	if ChallengeSession.is_active():
		info["rally_name"] = "%s Challenge" % ChallengeSession.kind().capitalize()
		info["stage_index"] = ChallengeSession.events_completed()
		info["stage_count"] = ChallengeSession.stage_count()
	elif RallySession.is_active():
		var rally := RallyLibrary.by_id(RallySession.rally_id())
		info["rally_name"] = String(rally.get("name", ""))
		info["stage_index"] = RallySession.event_index()
		info["stage_count"] = RallySession.stage_count()
		info["target_ms"] = RallySession.current_event_target_ms()
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

# Cinematic replay behind the between-event standings overlay (features/event-replay.md).
var _replay_recorder: ReplayRecorder
# Rival ghost (features/rival-ghost.md). The pace object is built for EVERY session run
# (the "vs P1" popup depends on it); the ghost node is additionally gated on the display
# config. Both are solved at GO, not at generation — see _solve_rival_pace.
var _rival_pace: RivalPace = null
var _ghost: GhostCar = null
# Captured at generation, consumed at GO: the P1 snapshot, the raw turn boundaries, and
# whether this run is staged (which decides the raw->profile offset shift).
var _p1_snapshot: Dictionary = {}
var _split_boundaries: Array = []
var _splits_staged := false
var _replay_camera: ReplayCamera
var _standings_overlay: CanvasLayer
# The live challenge interstitial, when one is up. Non-null only for a challenge
# stage; _on_challenge_run_finished waits on its run_completed signal so the
# player dismisses the final standings themselves. Null headless (no overlay is
# built), where the run end stays immediate.
var _challenge_standings_panel: Node = null

# Coarse far-terrain backdrop that gives the sky a horizon (distant_terrain.gd).
var _distant_terrain: DistantTerrain

# The pre-event start-line scene (briefing + presence cars); built for staged
# session runs and freed with the scene on the next event reload.
var _start_line: StartLine

# The mid-event wreck menu (orbit camera + Return to HQ); built when the fielded
# car is wrecked, freed with the scene when the rally resolves to the podium.
var _wreck_screen: WreckScreen

# Working HP the fielded car started this event with, so the event's HP loss can
# be reported back to the session at completion. Set when fielding a session car.
var _event_start_hp := 0.0
# HP + wheel-toe captured at the finish CROSSING (_on_finish_reached), used at
# report time so the post-finish runoff coast can't alter the event's damage.
var _event_hp_at_finish := 0.0
var _event_toe_at_finish: Array = []


# Wire the StageManager's in-stage "vs P1" pace popup for a session run. Builds the
# per-turn split table from the generated track (RallyLibrary.derive_turn_splits) and
# the leading rival's event time, converting each turn's arc offset to a progress
# fraction (matching TrackProgress.progress_percent) and its par time to a fraction of
# the stage total. No-op without an active session, a classified P1 rival, or pieces.
# Phase 1 of the rival-pace wiring: capture what the solve will need, and build the
# ghost node. No solving here — see _solve_rival_pace for why.
#
# The per-turn BOUNDARIES still come from RallyLibrary.derive_turn_splits: it is the only
# thing that knows where each placed piece ends, and the popup needs those. Only the
# TIMES move to RivalPace, so the ghost in the windscreen and the delta on the HUD are
# describing one rival with one pace model.
func _setup_stage_splits(track_result: Dictionary, staged: bool, _cfg: GameConfig) -> void:
	_rival_pace = null
	_p1_snapshot = {}
	_split_boundaries = []
	_splits_staged = staged
	if _stage_manager == null or not RallySession.is_active():
		return
	# ONE snapshot: the time, the car id, the engine id and the meta all come from the
	# same leaders[0] row, so the ghost cannot show a car the standings never mention.
	var p1 := RallySession.current_event_p1()
	if p1.is_empty() or int(p1.get("time_ms", -1)) <= 0:
		return
	var meta: Dictionary = p1.get("meta", {})
	if meta.is_empty():
		return
	_p1_snapshot = p1
	var splits := RallyLibrary.derive_turn_splits(track_result, meta, RallySession.current_event())
	for sp in splits:
		_split_boundaries.append(float(sp["end_offset_m"]))
	_setup_rival_ghost()


# Phase 2, at GO: solve the pace over the span the player is actually timed on, then feed
# BOTH consumers from it — the ghost and the "vs P1" popup.
func _solve_rival_pace() -> void:
	if _p1_snapshot.is_empty() or _track_progress == null or _road_centerline == null:
		return
	var target_ms := int(_p1_snapshot.get("time_ms", -1))
	if target_ms <= 0:
		return
	# The timed span, read from the LIVE anchor rather than reconstructed from the
	# lead-in config fields (that arithmetic already exists twice in this file; a third
	# copy would drift, and origin_offset() is not the start line anyway — the player is
	# staged several queue gaps behind it).
	var span_track := RivalPace.timed_span_track(_road_centerline,
			_track_progress.origin_offset(), _track_progress.finish_offset())
	_rival_pace = RivalPace.solve(span_track, _p1_snapshot.get("meta", {}),
			RallySession.current_event(), target_ms,
			float(_p1_snapshot.get("skill_k", -1.0)))
	if _rival_pace.is_degenerate():
		_rival_pace = null
		return
	_wire_stage_splits(target_ms)
	if _ghost != null:
		_ghost.pace = _rival_pace
		_ghost.elapsed_source = Callable(_stage_manager, "elapsed")
		_ghost.start()


# Feed the in-stage "vs P1" popup: boundaries from derive_turn_splits, times from the
# shared pace object.
func _wire_stage_splits(target_ms: int) -> void:
	if _stage_manager == null or _split_boundaries.is_empty() or _rival_pace == null:
		return
	var cfg: GameConfig = Config.data
	# derive_turn_splits measures offsets on the RAW generated curve; the pace profile
	# starts at the timing origin, which sits a lead-in earlier on a staged run. Without
	# this shift every turn would be read one lead-in early and the final boundary would
	# no longer land on the profile total (breaking the popup's cum/total -> 1.0 tail).
	var shift := cfg.start_lead_in_ahead_m if _splits_staged else 0.0
	var span := _track_progress.finish_offset() - _track_progress.origin_offset()
	if span <= 0.0:
		return
	var total_s := float(target_ms) / 1000.0
	if total_s <= 0.0:
		return
	var turn_progress: Array[float] = []
	var turn_time_frac: Array[float] = []
	for end_offset in _split_boundaries:
		var profile_off: float = float(end_offset) + shift
		turn_progress.append(clampf(profile_off / span, 0.0, 1.0))
		turn_time_frac.append(clampf(_rival_pace.time_at_offset(profile_off) / total_s, 0.0, 1.0))
	_stage_manager.setup_splits(turn_progress, turn_time_frac, target_ms)


# Build the ghost node + its car. Construction only: it is hidden and clockless until
# _solve_rival_pace hands it a pace at GO.
#
# NOT gated on _headless — the test runner is always headless, so gating construction
# there would make the whole feature untestable. GhostCar gates only VISIBILITY.
func _setup_rival_ghost() -> void:
	# Replaced, not reused: an _ensure_child would carry the previous event's pace object
	# and car build into the next stage.
	_replace_named_child("RivalGhost")
	_ghost = null
	var cfg: GameConfig = Config.data
	if not cfg.rival_ghost_enabled or Benchmark.active or _p1_snapshot.is_empty():
		return
	if _track_progress == null:
		return
	var ghost := GhostCar.new()
	ghost.name = "RivalGhost"
	add_child(ghost)
	_ghost = ghost
	_ghost.player = $Car
	# Pace is null here on purpose — it arrives at GO, once the timing origin is anchored.
	_ghost.setup(null, _track_progress, _floor(), _p1_snapshot,
			load(WRECK_CAR_SCENE), RallySession.current_event())


# Build the HUD pacenote strip for this stage (features/hud.md) and wire the strip's
# per-corner progress thresholds into the StageManager. Runs on every non-benchmark
# run — pacenotes are track reading, not a rival comparison — so it needs no session.
# The progress fractions use the same start-line span as _setup_stage_splits so they
# line up with TrackProgress.progress_percent(): a staged run's lead-in ahead of the
# generated track is added to both the corner offset and the span.
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


# --- RallySession run-scene integration (features/rally-session.md) ------------

# Dev cheat (F key, features/debug-tools.md): skip straight to the finish of the
# current stage. Debug-build only (release/web ignore it) and only inside an active
# run — career rally OR Rally Challenge — with a live StageManager. Teleports the car
# onto the finish line and force-completes the stage, so the whole completion →
# reward → progression flow fires exactly as it would on a real finish.
#
# Gated on DrivingContext.session_active(), NOT RallySession.is_active(): the latter
# silently excluded challenge runs, leaving the cheat dead in exactly the mode whose
# multi-stage flow is slowest to exercise by hand.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("skip_to_finish"):
		return
	if not OS.is_debug_build() or not DrivingContext.session_active():
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
# with the feature enabled AND a resolvable event (so a missing rally / a run that
# has no stage left never strands the car in STAGING with no StartLine to launch
# it). A challenge stage stages exactly like a rally event — same countdown screen,
# same pre-race Upgrades/Tuning menus — it just has no rival field to reveal (the
# StartLine's existing empty-leaders path covers that; see _build_start_line).
func _should_stage() -> bool:
	if not Config.data.start_line_enabled:
		return false
	if ChallengeSession.is_active():
		return not ChallengeSession.current_stage_params().is_empty()
	return RallySession.is_active() \
		and not RallyLibrary.by_id(RallySession.rally_id()).is_empty()


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
	var info := _arch_event_info()
	var rally := RallyLibrary.by_id(RallySession.rally_id())
	var leaders: Array = RallySession.current_event_leaders(3) if RallySession.is_active() else []
	if ChallengeSession.is_active():
		# A challenge has no authored rally. StartLine reads a display name and the
		# power-to-weight restriction off this dict, so hand it the SAME synthetic
		# {"restriction": {"pw_max": ceiling}} shape hq.gd's challenge car park and
		# ChallengeSession.eligible_cars already judge the car against — the gate is
		# then literally the same code path a rally's p/w-capped class takes.
		# The `restriction` key is NOT redundant with DrivingContext.pw_limit(): the
		# Upgrades cap now goes through DrivingContext, but start_line.gd's launch
		# eligibility gate (RallyLibrary.ineligibility_reason) and its Tune Car
		# detune cap (_rally_qualifying_detune -> RallyLibrary.qualifying_detune)
		# both take the whole rally dict and read `restriction` themselves.
		# `leaders` stays empty: no rival field (spec §3), so StartLine's existing
		# empty-leaders path skips the reveal and fades straight to the countdown.
		rally = {
			"name": String(info["rally_name"]),
			"restriction": {"pw_max": ChallengeLibrary.ceiling_for(ChallengeSession.period_key())},
		}
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
		leaders, $CameraManager as CameraManager,
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
	$Car.apply_owned(owned)
	_event_start_hp = $Car.damage.hp
	# Safe defaults until the finish crossing overwrites them (_on_finish_reached).
	_event_hp_at_finish = _event_start_hp
	_event_toe_at_finish = $Car.damage.toe_array()


# Route this event's StageManager / damage signals to the session, and the rally's
# finish to the podium. Connections on the per-event scene's nodes are dropped
# automatically when the scene reloads for the next event. Called for BOTH a
# RallySession run and a ChallengeSession run (mutually exclusive — only one is
# ever active at a time), branching only where the two sessions' APIs differ.
func _wire_session_signals() -> void:
	# stage_completed is already connected in _ready() (every mode wires it before
	# this session-only pass runs), so it's intentionally not re-connected here.
	if not ($Car as Node).wrecked.is_connected(_on_session_car_wrecked):
		($Car as Node).wrecked.connect(_on_session_car_wrecked)
	if RallySession.is_active():
		if not RallySession.rally_finished.is_connected(_on_session_rally_finished):
			RallySession.rally_finished.connect(_on_session_rally_finished)
		# Live (non-headless) runs own the standings presentation as an in-world
		# overlay, keeping this run world alive behind it for the cinematic replay;
		# RallySession then skips its own scene-change path (see rally_session.gd).
		RallySession.standings_overlay_host = not _headless
		if not RallySession.standings_ready.is_connected(_present_standings_overlay):
			RallySession.standings_ready.connect(_present_standings_overlay)
	elif ChallengeSession.is_active():
		if not ChallengeSession.run_finished.is_connected(_on_challenge_run_finished):
			ChallengeSession.run_finished.connect(_on_challenge_run_finished)
		# _present_standings_overlay reads nothing session-specific (just $Car / $HUD /
		# the replay recorder), so it's reused verbatim for a challenge stage.
		if not ChallengeSession.standings_ready.is_connected(_present_standings_overlay):
			ChallengeSession.standings_ready.connect(_present_standings_overlay)

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
	get_tree().change_scene_to_file(path)


func _on_session_event_completed(elapsed_seconds: float) -> void:
	# No active session — free roam (or a plain dev boot) reached the finish. There is
	# no session to report to (report_event_result would silently no-op, leaving the
	# finish panel's Next doing nothing), so Next returns to HQ instead — the same
	# destination as the pause menu's Quit with no session.
	if not RallySession.is_active() and not ChallengeSession.is_active():
		_change_scene("res://hq.tscn")
		return
	# HP lost + persisted wheel-toe are snapshotted at the FINISH CROSSING (see
	# _on_finish_reached), NOT here: this handler fires on the NEXT button, by which time
	# the car has skidded to a stop / idled in the runoff, and any barrier clip during
	# that post-finish coast would be wrongly charged to the event's damage.
	var hp_lost: float = maxf(0.0, _event_start_hp - _event_hp_at_finish)
	# A challenge run routes to ChallengeSession instead of RallySession — the two
	# sessions are mutually exclusive, and this is the single call site the spec
	# (§3) calls out for the mode branch.
	var challenge_active := ChallengeSession.is_active()
	var iid: int = ChallengeSession.car_instance_id() if challenge_active else RallySession.car_instance_id()
	if iid >= 0:
		Save.set_wheel_toe(iid, _event_toe_at_finish)
	if _replay_recorder != null:
		_replay_recorder.stop()
	var elapsed_ms := int(round(elapsed_seconds * 1000.0))
	if challenge_active:
		ChallengeSession.report_event_result(elapsed_ms, hp_lost)
	else:
		RallySession.report_event_result(elapsed_ms, hp_lost)


func _on_stage_started() -> void:
	if _replay_recorder != null:
		_replay_recorder.start()
	# The pace solve MUST happen here, not during generation: it spans
	# TrackProgress.origin_offset() -> finish_offset(), and mark_start() only anchors the
	# origin once the player has been reset_to their grid slot and the countdown has run.
	# Solving earlier measures a span the ghost is never posed over.
	_solve_rival_pace()


# Fired the instant the finish is crossed (StageManager._complete), before the NEXT
# button. Two run-end snapshots are taken HERE so the post-finish coast can't affect
# them: (1) stop the recorder (else the stationary runoff tail lands in the replay);
# (2) capture HP + wheel-toe as of the crossing (the driven run's real damage).
func _on_finish_reached() -> void:
	if _replay_recorder != null:
		_replay_recorder.stop()
	# The ghost's own clock ends at P1's time, but stop it here too so it can't keep
	# posing while the finish panel is up (and so the post-event replay owns the world).
	if _ghost != null:
		_ghost.stop()
	_event_hp_at_finish = $Car.damage.hp
	_event_toe_at_finish = $Car.damage.toe_array()


# Present the standings as an in-world CanvasLayer overlay and start the replay,
# keeping the run world alive behind it. Headless runs (no display) skip this;
# RallySession then falls back to its scene-change path.
func _present_standings_overlay(_event_index: int) -> void:
	if _headless or _replay_recorder == null:
		return
	if _replay_recorder.recording:
		_replay_recorder.stop()
	($HUD as CanvasLayer).visible = false
	# Hide the on-screen driving controls — the replay isn't drivable, and the
	# touch sticks/pedals would just clutter the cinematic on a touch device.
	var mobile := get_node_or_null("MobileControls") as CanvasLayer
	if mobile != null:
		mobile.visible = false
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
	# Standings overlay Control on its own CanvasLayer.
	_standings_overlay = CanvasLayer.new()
	_standings_overlay.name = "StandingsOverlay"
	var panel: Control = load("res://standings.tscn").instantiate()
	panel.overlay_mode = true
	# Pin the session BEFORE the panel enters the tree. On a challenge's final stage
	# ChallengeSession clears itself between this signal and the panel's own _ready
	# latch running would still be fine (standings_ready is emitted while the run is
	# active), but stating it here removes the ordering dependency entirely.
	panel.set_challenge_mode(ChallengeSession.is_active())
	panel.leaderboard_hidden_changed.connect(_on_leaderboard_hidden_changed)
	if ChallengeSession.is_active():
		# THIS panel owns the end of a challenge run: _on_challenge_run_finished
		# waits on its run_completed rather than ejecting the player to the HQ while
		# they are still reading the final standings.
		_challenge_standings_panel = panel
	_standings_overlay.add_child(panel)
	add_child(_standings_overlay)
	_on_leaderboard_hidden_changed(false)   # shown -> engine muted


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


func _on_session_car_wrecked() -> void:
	# Don't cut straight to the podium — that's too sudden. Let the crash play out,
	# then show the wreck menu (orbit camera + Return to HQ); reporting the wreck
	# (the DNF) is deferred until the player chooses to leave. Headless runs (no
	# display, e.g. tests) skip the cinematic and report immediately.
	# A challenge run has no rival field / podium, but a wreck ends it the same
	# way — no-retry DNF (spec §3) — so it routes to ChallengeSession instead of
	# RallySession whenever a challenge is the active session.
	var report_wreck: Callable = ChallengeSession.report_wreck if ChallengeSession.is_active() \
		else RallySession.report_wreck
	if _headless or _wreck_screen != null:
		report_wreck.call()
		return
	_wreck_screen = WreckScreen.new()
	_wreck_screen.name = "WreckScreen"
	add_child(_wreck_screen)
	_wreck_screen.return_requested.connect(report_wreck)
	_wreck_screen.setup($Car, $ChaseCamera as Camera3D, $HUD as CanvasLayer,
		$MobileControls as CanvasLayer)


# Rally over (or DNF): show the podium. Loads under the (placeholder) transition.
# Exception: a rally ABANDONED from the pause menu has no result to celebrate, so it
# skips the podium and returns straight to HQ (opening on the garage view).
func _on_session_rally_finished(result: Dictionary) -> void:
	if result.get("abandoned", false):
		RallySession.return_to_garage = true
		_change_scene("res://hq.tscn")
	else:
		_change_scene("res://podium.tscn")


# A challenge run has no podium (no rival field to place against, no per-rally
# car reward). Both a clean finish and a DNF return straight to HQ — but the
# run's END is resolved here first, the challenge's counterpart to
# RallySession._resolve_results:
#
#   CLEAN FINISH — spec §6's placement-gated completion reward. This fires while
#   the player is still IN the driving scene (ChallengeSession._finish_locally
#   emits run_finished from report_event_result, before the hand-off to HQ), and
#   the scene change below is what ends the run, so the grant is awaited here and
#   shown on a plain ConfirmPopup card over the world — the same shape hq.gd's
#   mystery box uses for a "reward, but not mid-interstitial" moment. A full
#   UpgradeReveal page belongs to the per-stage interstitial (standings.gd),
#   which is not up at this point.
#
#   DNF — flip the board's `dnf` field (spec §6). Best-effort and deliberately
#   NOT awaited: the house posture is that no cloud call ever costs the player
#   anything, so the return to HQ must not wait on (or surface) the network. The
#   coroutine resolves against Cloud.challenge_leaderboard, an autoload that
#   outlives this scene.
func _on_challenge_run_finished(result: Dictionary) -> void:
	if bool(result.get("dnf", false)):
		if Cloud != null and Cloud.challenge_leaderboard != null:
			@warning_ignore("return_value_discarded")
			Cloud.challenge_leaderboard.post_dnf(ChallengeSession.period_key())
	else:
		# ONE owner of "what happens after the last stage". The final stage's
		# interstitial is already on screen (report_event_result emits
		# standings_ready before finishing the run), so wait for the player to press
		# through it instead of racing it with a network round-trip and then ejecting
		# them mid-read. Waiting also means the final checkpoint has POSTED by the
		# time try_grant_completion_reward fetches the rank it gates on — previously
		# the grant was judged against a board this run had never been written to.
		# Headless (no overlay) keeps the old immediate path.
		if is_instance_valid(_challenge_standings_panel):
			await _challenge_standings_panel.run_completed
		# try_grant_completion_reward fetches the run's final rank from Firestore — a
		# real round-trip with nothing on screen, which read as the game hanging right
		# at the moment the player is waiting to hear how they did. Cover it with the
		# shared cloud-busy state (todo/challenge-career-reuse-drift.md item 11); this
		# was the last unmigrated `await Cloud.*` site. ChallengeSession is an autoload
		# with no screen of its own, so the covering host is this scene.
		var busy := CloudBusy.cover(self, "Scoring your run…", "Checking the leaderboard…")
		var grant: Dictionary = await ChallengeSession.try_grant_completion_reward(result)
		await busy.end()
		var item_id := String(grant.get("item_id", ""))
		# Boxes alone are a reward worth showing — a Daily grants no car at all, so
		# gating the card on item_id would leave every Daily win silent.
		var won_something := item_id != "" or int(grant.get("boxes", 0)) > 0
		if won_something and not _headless:
			# NOT open_committing. That helper's whole point is making a mutation
			# unrepresentable without its reveal, by acquiring the modal slot BEFORE
			# calling a commit callable and skipping the callable entirely when the
			# slot is refused — the right shape for a mystery box, where "the box was
			# never opened" is a true, harmless state to fall back to. This grant has
			# no such fallback: try_grant_completion_reward already ran above (it has
			# to — fetch_final_rank is judged against THIS run's own posted time, so
			# it can't be deferred behind a modal check), and
			# ChallengeSession._finish_locally recorded this period's outcome and
			# cleared challenge_run before run_finished even fired. There is no
			# "reward pending reveal" state and no way back into a finished period
			# (period_outcome is terminal — start()/resume() both refuse once it's
			# set), so skipping the reveal here would not defer the grant, it would
			# silently keep it while making it undiscoverable — worse than today's
			# bug, which never loses the boxes/car themselves, only their reveal.
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
	RallySession.return_to_garage = true
	_change_scene("res://hq.tscn")


# Body text for the completion-reward card: what was won and where it landed.
# Every kind grants mystery boxes; Weekly and Monthly add a car on top, which may
# be absent if the draw found nothing left to unlock — so both parts are optional
# and the card lists whatever actually landed.
func _completion_reward_body(item_id: String, grant: Dictionary) -> String:
	var rank := int(grant.get("rank", 0))
	var total := int(grant.get("total_entries", 0))
	var placing := "Finished %d of %d" % [rank, total] if total > 0 else "Finished"
	var lines: Array[String] = []
	var boxes := int(grant.get("boxes", 0))
	if boxes > 0:
		lines.append("%d Mystery %s" % [boxes, "Box" if boxes == 1 else "Boxes"])
	var car_entry := CarLibrary.by_id(item_id)
	if not car_entry.is_empty():
		lines.append(String(car_entry.get("name", item_id)))
	if lines.is_empty():
		return placing
	var where := "They're waiting in your garage." if car_entry.is_empty() \
		else "Your new car is waiting in the car park."
	return "%s\nReward: %s\n\n%s" % [placing, ", ".join(lines), where]


func _layers_match(layers: Array[TerrainLayer], params: Array[Vector2]) -> bool:
	if layers.size() != params.size():
		return false
	for i in layers.size():
		if layers[i] == null or layers[i].wavelength_m != params[i].x or layers[i].amplitude_m != params[i].y:
			return false
	return true


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
	var region_id := "home"
	if ChallengeSession.is_active():
		# A challenge stage is rolled from the period hash and authors no region, so
		# it wears the plain home look — explicitly, so a leftover free-roam pick
		# can't drop through to the branch below and dress the stage in the last
		# free-roam drive's sky/ground/tree mix. (ChallengeSession.start/resume also
		# clear the handoff now; this arm is the belt to that's braces, and it is
		# what makes "a challenge has no region" a stated rule rather than an
		# accident of ordering.) See todo/challenge-career-reuse-drift.md item 9.
		region_id = "home"
	elif RallySession.is_active():
		region_id = String(RegionLibrary.region_for_rally(RallySession.rally_id()).get("id", "home"))
	elif (RallySession.free_roam_instance_id >= 0 or RallySession.free_roam_model_id != "") \
			and RallySession.free_roam_region_id != "":
		region_id = RallySession.free_roam_region_id
	_region_look_cache = RegionLibrary.look_of(region_id)
	_region_look_ready = true
	return _region_look_cache


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
	if look.has("sky_panorama"):
		var sky_mat := env.sky.sky_material as PanoramaSkyMaterial
		if sky_mat:
			sky_mat.panorama = load(look["sky_panorama"])
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
	var look: Dictionary = entry.get("look", {})
	if not look.is_empty():
		var background: Color = cfg.get(String(look["background_color"]))
		var sky: Color = cfg.get(String(look["sky_color"]))
		_apply_overcast_look(background, sky,
			float(cfg.get(String(look["sun_energy_mult"]))),
			float(cfg.get(String(look["fog_density_mult"]))),
			float(cfg.get(String(look["fog_sky_affect"]))), cfg)
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

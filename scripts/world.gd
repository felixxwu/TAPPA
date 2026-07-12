extends Node3D
# Applies the central GameConfig to scene-owned resources at startup.
# Car handling is applied by car.gd; camera follow by chase_camera.gd.

const BUSH_SEED_OFFSET := 1013

# Assets for a staged roadside opponent wreck (features/opponent-wrecks.md). The car
# is the same scene the player drives (spawned as a frozen prop, like the podium/HQ
# display cars); the onlookers reuse the shared low-poly spectator figure.
const WRECK_CAR_SCENE := "res://car.tscn"
const WRECK_SPECTATOR_SCENE := "res://blender/spectator/spectator.glb"

# Headless (test) runs build the world synchronously — see _yield_frame(). Cached
# so the staged-loading awaits collapse to no-ops and tests see a fully-built
# world the instant main.tscn is instantiated, exactly as before this overlay.
var _headless := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	# Cover the screen before any heavy generation so the player sees staged
	# progress instead of a frozen frame between Godot's boot bar finishing and
	# the first playable frame. Freed by _generate_track() once the world is up.
	var loading := LoadingScreen.new()
	add_child(loading)

	var cfg: GameConfig = Config.data
	# Frame cap: a steady ceiling keeps phones cool (avoids thermal throttling).
	# 0 = uncapped for desktop dev. Physics stays at the project physics tick.
	# Skipped under --headless (no rendering to pace) so it can't throttle the
	# frame-awaiting test runner.
	if cfg.target_fps > 0 and DisplayServer.get_name() != "headless":
		Engine.max_fps = cfg.target_fps
	var env: Environment = $WorldEnvironment.environment
	env.fog_density = cfg.fog_density
	env.background_color = cfg.background_color
	env.fog_light_color = cfg.background_color
	# How much the (now reduced) fog tints the sky. Low so the skybox reads clearly
	# above the distant haze; the panorama's own horizon + the fog colour (matched
	# to the sky horizon, see background_color) blend the terrain edge into the sky.
	env.fog_sky_affect = cfg.fog_sky_affect

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
	# Flat tarmac fill colour (TODO: a real tarmac texture — todo/tarmac-texture.md).
	($Floor.chunk_material as ShaderMaterial).set_shader_parameter("tarmac_color", cfg.tarmac_color)
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
	cfg.apply_terrain_light($Floor as TerrainManager)
	_mat($Car/Chassis).set_shader_parameter("albedo_color", cfg.chassis_color)
	_mat($Car/Cabin).set_shader_parameter("albedo_color", cfg.cabin_color)
	# Wheel materials are shared resources; setting each once covers all four.
	_mat($Car/WheelFL/Visual/Tire).set_shader_parameter("albedo_color", cfg.wheel_color)
	_mat($Car/WheelFL/Visual/Spoke1).set_shader_parameter("albedo_color", cfg.wheel_spoke_color)
	# Fake per-vertex lighting (PS1-style) on the car meshes, computed live in the
	# car shader because the car rotates (the terrain bakes the same look above).
	# The MX-5 body model is lit in car.gd's _apply_model_material when built.
	for car_mesh in [$Car/Chassis, $Car/Cabin, $Car/WheelFL/Visual/Tire, $Car/WheelFL/Visual/Spoke1]:
		cfg.apply_car_light(_mat(car_mesh))
	($PostProcess.material as ShaderMaterial).set_shader_parameter("virtual_resolution", cfg.virtual_resolution)

	# Field the car. With an active RallySession this event runs the player's
	# OwnedCar (baseline + upgrades + saved HP, features/rally-session.md); a plain
	# dev boot keeps the first library car (the Mazda MX-5).
	_car_spawn = $Car.transform  # authored spawn, reused so swaps don't drift
	if RallySession.is_active():
		_field_session_car()
	elif RallySession.free_roam_instance_id >= 0:
		# Free roam (session-less): field the owned car the player picked in the car
		# park (baseline + upgrades + saved HP), falling back to the default library
		# car if the instance has since vanished.
		var owned: Dictionary = Save.get_car(RallySession.free_roam_instance_id)
		if owned.is_empty():
			$Car.apply_car(0)
		else:
			$Car.apply_owned(owned)
	else:
		$Car.apply_car(0)
	# The bonnet camera is a scene child of $Car (not re-parented at boot), so
	# apply the newly-fielded car's per-car bonnet offset now — retarget() only
	# runs on a later car swap.
	($CameraManager as CameraManager).refresh_bonnet_offset()

	await _generate_track(cfg, loading)

	# The stage finish is handled in EVERY mode: a session run reports the event to
	# the orchestrator; free roam / a dev boot has no session, so the finish panel's
	# Next returns to HQ instead (_on_session_event_completed's no-session branch).
	if _stage_manager != null and not _stage_manager.stage_completed.is_connected(_on_session_event_completed):
		_stage_manager.stage_completed.connect(_on_session_event_completed)
	# A session run additionally wires the wreck back to the orchestrator, and
	# routes the rally's finish to the podium.
	if RallySession.is_active():
		_wire_session_signals()
		# Pre-event start-line scene: briefing + presence cars before the countdown
		# (todo/menus.md location 2). Only when staged (start_line_enabled + a real
		# rally); the StageManager is already waiting in STAGING for its launch.
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

	# Diagnostic frame-profiler overlay (toggle with P). Created in code like the
	# wheel-force debug overlay; harmless and idle until toggled on. Render times
	# are measured on the PostProcess SubViewport — the viewport that actually
	# does the 3D work while main.tscn is up (the root's 3D pass is disabled).
	var perf := PerfOverlay.new($Floor as TerrainManager)
	perf.measure_viewport = get_node_or_null("PostProcess/View") as Viewport
	add_child(perf)

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
			get_node_or_null("PostProcess/View") as Viewport)


# Yield a frame so a freshly-set LoadingScreen step actually paints before the
# next blocking generation call. A no-op under headless, where the await would
# otherwise spread world generation across frames and break tests that inspect
# the world right after instantiating main.tscn — there the whole _ready chain
# runs synchronously within add_child(), as it did before staged loading.
func _yield_frame() -> void:
	if not _headless:
		await get_tree().process_frame


# Set a loading-screen step label (when an overlay is up) and yield a frame so it
# paints before the next blocking generation call. Collapses to a synchronous
# no-op under headless (via _yield_frame), so tests still see a fully-built world.
func _stage(loading: LoadingScreen, label: String) -> void:
	if loading != null:
		loading.set_step(label)
	await _yield_frame()


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


# Build the track from the car's spawn pose, bake road heights, and build the
# (deferred) terrain ring with flattening + colouring already applied — so no
# chunk is ever rebuilt at startup. Each heavy step sets the loading label and
# yields a frame first (outside headless) so the message paints before the
# blocking work runs; `loading` is freed once the world is ready.
func _generate_track(cfg: GameConfig, loading: LoadingScreen = null) -> void:
	await _stage(loading, "Generating track…")
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
	var gen_start := start_pos
	# Corridor reserved behind the generation start = the whole lead-in (the ahead
	# straight start→gen_start plus the behind stub). 0 when not staged.
	var reserve_behind := 0.0
	if staged:
		gen_start = start_pos + start_heading * cfg.start_lead_in_ahead_m
		reserve_behind = cfg.start_lead_in_ahead_m + cfg.start_lead_in_behind_m
	var result := TrackGenerator.generate(
		gen_start, start_heading, cfg.track_seed, cfg.track_turn_count, cfg.track_width,
		cfg.track_clearance, reserve_behind, cfg.track_straightness, cfg.track_runoff_m)
	# Road/progress centerline (with the lead-in for staged runs). The raw generated
	# centerline still feeds the signs, so the start gate sits ahead of the launch
	# point — the cars cross it as they pull away.
	var road_centerline := result["centerline"] as Curve2D
	if staged:
		road_centerline = _with_start_lead_in(road_centerline, start_pos, start_heading, cfg)
	# The FINISH is the END of the generated track (plus lead-in) — capture its arc
	# length BEFORE appending the runoff, so the arch and 100% progress anchor here.
	var finish_len := road_centerline.get_baked_length()
	# Append the post-finish runoff straight (features/track.md) to the RENDERED road so
	# the car has room to skid to a stop past the arch. It's baked into the terrain +
	# road-marked like the rest; the finish stays at finish_len (see below).
	road_centerline = _with_finish_runoff(road_centerline, result["runoff"])
	var transition_m := cfg.track_transition_cells * TerrainManager.CELL_M
	# Surface split: the track runs gravel + tarmac with one switch, the tarmac
	# share = track_tarmac_fraction (set per rally event). Which surface it opens on
	# is seeded off track_seed so it's deterministic but varied across events.
	var tarmac_first := TrackSurface.orientation_tarmac_first(cfg.track_seed)
	# Cliff params onto the terrain before the bake reads them (mirrors the Lighting
	# group applied earlier); the cliff pass runs inside set_track → bake_track.
	cfg.apply_cliffs($Floor as TerrainManager)
	$Floor.set_track(road_centerline, cfg.track_width, transition_m,
		cfg.track_tarmac_fraction, tarmac_first, cfg.track_surface_transition_m)
	# Retained for post-build consumers outside this call (the benchmark runner
	# follows the same road the progress manager measures).
	_road_centerline = road_centerline

	# Precompute every chunk the bounded play area can request (the off-track
	# reset leash bounds it), so in-run chunk loads are instant cache pulls and
	# height_at/light_at serve the flattened, collidable terrain. Batched with
	# frame awaits so the loading label paints and (on web) the tab stays alive.
	await _stage(loading, "Precomputing terrain…")
	var floor_tm := $Floor as TerrainManager
	floor_tm.set_corridor(floor_tm.corridor_coords(
		road_centerline, Config.data.track_progress_max_dist_m))
	var precompute_done := 0
	for coord in floor_tm.corridor():
		floor_tm.cache_chunk(coord)
		precompute_done += 1
		if precompute_done % 8 == 0:
			await _yield_frame()
	print("terrain precompute: %d chunks, %.1f MB cached"
		% [precompute_done, floor_tm.cache_size_mb()])

	await _stage(loading, "Building terrain…")
	$Floor.build_initial()

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
	var foliage := await _build_foliage(cfg, result, road_centerline, loading)

	# Roadside turn-arrow signs along the stage.
	if cfg.signs_enabled:
		await _build_signs(cfg, result, loading)

	# Roadside spectators: crowds that react to the car (todo/roadside-spectators.md).
	# One group at the start, one at the end, and one at a seeded mid-stage point.
	# Built after trees so members can avoid spawning inside foliage; reuses the
	# centerline, road_cells and terrain built above.
	if cfg.spectators_enabled and cfg.spectator_group_size > 0:
		_spawn_spectators(road_centerline, foliage["road_cells"], foliage["trees"],
			start_pos, start_heading, cfg, $Floor as TerrainManager, finish_len)

	# Finish + start inflatable arches straddling the road.
	_build_arches(road_centerline, finish_len, start_pos, start_heading, cfg)

	# Roadside opponent wreck: if a rival crashed out of THIS event, stage their ACTUAL
	# car by the verge — frozen (hitbox kept), smoking, with a small crowd around it
	# (features/opponent-wrecks.md). Uses the built centerline + terrain.
	_spawn_opponent_wreck(road_centerline, finish_len, $Floor as TerrainManager, cfg)

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
	if loading != null and not _headless:
		var wp := _warm_up_point()
		_tire_marks.warm_up(wp)
		_wheel_particles.warm_up(wp)
		_engine_smoke.warm_up(wp)
		await get_tree().process_frame
		_tire_marks.clear_warm_up()
		_wheel_particles.clear_warm_up()
		_engine_smoke.clear_warm_up()

	# World is ready — drop the loading overlay (absent for direct/programmatic
	# regeneration, e.g. entering a rally event). Staged runs keep it up a moment
	# longer: _ready drops it only AFTER the start-line queue is laid out, so the
	# black overlay hides the car at its pre-staged spot instead of flashing it.
	if loading != null and not staged:
		loading.finish()


# Scatter trees + ground-cover bushes around the stage and render both as binned
# MultiMesh fields (TreeMeshField), plus the pass-through bush hit volume. Takes the
# already-generated track `result` + rendered `road_centerline`; owns the two
# loading steps. Returns {"trees", "road_cells"} — the tree points and road-margin
# cells the spectator layout reuses.
func _build_foliage(cfg: GameConfig, result: Dictionary, road_centerline: Curve2D,
		loading: LoadingScreen = null) -> Dictionary:
	if not cfg.vegetation_enabled:
		# Foliage off (the benchmark's vegetation toggle): skip the scatter and the
		# fields entirely, but still hand the spectator layout the road-margin cells
		# it needs to keep crowds off the carriageway.
		var bare_cells := TrackGenerator.rasterize_cells(
			road_centerline.tessellate(), cfg.track_width + 2.0 * cfg.tree_road_margin_m)
		return {"trees": PackedVector2Array(), "road_cells": bare_cells}
	await _stage(loading, "Scattering trees…")
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
	# Trees render as billboards or 3D meshes per cfg.use_billboard_trees — the
	# choice (and the shared mesh/material) live in Foliage so every scene matches.
	# Stage trees collide (they're obstacles).
	Foliage.spawn_trees(self, trees, $Floor as TerrainManager, true,
		cfg.tree_render_distance_m, cfg.tree_render_fade_m)

	await _stage(loading, "Scattering bushes…")
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
	Foliage.spawn_bushes(self, bushes, $Floor as TerrainManager,
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
func _build_signs(cfg: GameConfig, result: Dictionary, loading: LoadingScreen = null) -> void:
	await _stage(loading, "Placing signs…")
	var sign_layout := SignLayout.plan(result["centerline"], result["pieces"])
	var sign_field := SignField.new()
	add_child(sign_field)
	sign_field.build(sign_layout, $Floor as TerrainManager, cfg.sign_render_params())


# Finish + start arches: the inflatable gates straddling the road
# (features/finish-arch.md). The FINISH gate sits at the END of the progress
# centerline — i.e. exactly 100% track progress — so crossing it ends the stage
# immediately; the START gate sits at the start line where the car actually spawns.
# Each opening is sized to the road width plus a margin so the legs stand clear, and
# each is turned so its banner face meets the driver.
func _build_arches(road_centerline: Curve2D, finish_len: float,
		start_pos: Vector2, start_heading: Vector2, cfg: GameConfig) -> void:
	var arch_terrain := $Floor as TerrainManager
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
	_track_progress.setup(road_centerline, $Car, $Floor as TerrainManager, finish_len)

	# Tire marks: gravel ruts laid behind the wheels while on the road
	# (features/tire-marks.md); gated to the road half-width, so it needs the
	# centerline + terrain.
	_tire_marks = _ensure_child("TireMarks",
		func() -> Node: return TireMarks.new()) as TireMarks
	_tire_marks.setup(road_centerline, $Car, $Floor as TerrainManager, cfg.track_width * 0.5)

	# Road paint: solid edge lines + a dashed centre line along the tarmac sections,
	# so tarmac reads as tarmac (features/track.md). A static mesh built once from the
	# centerline + surface split; rebuilt on a regeneration.
	_road_markings = _ensure_child("RoadMarkings",
		func() -> Node: return RoadMarkings.new()) as RoadMarkings
	_road_markings.build(road_centerline, $Floor as TerrainManager, cfg.road_marking_params())

	# Wheel dust: cheap gravel spray flung from the driven wheels under wheelspin
	# (features/wheel-dust.md); the surface under each wheel (gravel vs grass/tarmac)
	# is read live off the car's drivetrain terrain, so it only needs the car here.
	_wheel_particles = _ensure_child("WheelParticles",
		func() -> Node: return WheelParticles.new()) as WheelParticles
	_wheel_particles.setup($Car)

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
	var existing := get_node_or_null(node_name)
	if existing != null:
		remove_child(existing)
		existing.free()
	var dir := heading
	if dir.length() < 1e-5:
		dir = Vector2(0.0, 1.0)
	dir = dir.normalized()
	var tree_cell: float = maxf(cfg.spectator_tree_avoid_m, 0.5)
	var members := SpectatorScatter.members(anchor, dir,
		cfg.spectator_area_length_m * 0.5, cfg.spectator_area_width_m * 0.5,
		cfg.spectator_group_size, cfg.spectator_separation_m, road_cells,
		tree_grid, tree_cell, cfg.spectator_tree_avoid_m, seed_value)
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
	var existing := get_node_or_null("OpponentWreck")
	if existing != null:
		remove_child(existing)
		existing.free()
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
	var half_w := 1.1
	var half_len := 2.0
	var edge := cfg.track_width * 0.5
	var base_lat := edge + half_w + cfg.opponent_wreck_road_offset_m
	var spot := _flattest_wreck_spot(centerline, baked, progress * span, side,
		base_lat, half_w, half_len, terrain)
	var pos2: Vector2 = spot["pos2"]
	var tan2: Vector2 = spot["tan2"]
	var top_y: float = spot["top"]  # highest ground under the footprint — seat on top, never buried
	var outward := Vector2(-tan2.y, tan2.x) * side  # away from the road

	var container := Node3D.new()
	container.name = "OpponentWreck"
	add_child(container)

	# The crashed car, skewed off the road direction so it reads as wrecked, not parked
	# (deterministic from the seeded progress so it's stable across re-attempts). Seated
	# just above the highest ground under it, so it can't spawn buried; it then settles.
	var fwd := Vector3(tan2.x, 0.0, tan2.y)
	var skew := (fmod(progress * 41.0, 1.0) - 0.5) * 2.0 * cfg.opponent_wreck_yaw_skew
	var car_basis := Basis.looking_at(fwd, Vector3.UP).rotated(Vector3.UP, skew)
	var car_pos := Vector3(pos2.x, top_y + cfg.opponent_wreck_drop_height_m, pos2.y)
	_spawn_wreck_car(idx, Transform3D(car_basis, car_pos), container, cfg)

	# The small gathering of onlookers, on the verge side of the wreck (off the road).
	_spawn_wreck_crowd(container, Vector3(pos2.x, top_y, pos2.y), outward, terrain, cfg)


# Find the flattest patch of verge near the seeded crash point: a small deterministic
# search over along-track and lateral offsets on the wreck's side. Returns the chosen
# centre `pos2`, the road tangent `tan2` there, and `top` = the highest terrain height
# under the car footprint at that centre (so the car seats on top and can't spawn
# buried). No RNG, so the wreck stays stable across re-attempts.
func _flattest_wreck_spot(centerline: Curve2D, baked: float, seed_offset: float,
		side: float, base_lat: float, half_w: float, half_len: float,
		terrain: TerrainManager) -> Dictionary:
	var best := {}
	var best_spread := INF
	for d_along: float in [-12.0, -6.0, 0.0, 6.0, 12.0]:
		var off := clampf(seed_offset + d_along, 0.05 * baked, 0.95 * baked)
		var c := centerline.sample_baked(off)
		var t := centerline.sample_baked(minf(off + 1.0, baked)) - c
		if t.length() < 1e-4:
			t = Vector2(0.0, 1.0)
		t = t.normalized()
		var road_out := Vector2(-t.y, t.x) * side
		# Prefer the shoulder (closest, usually flattest); step outward for flatter ground.
		for extra: float in [0.0, 1.0, 2.0, 3.0]:
			var c2 := c + road_out * (base_lat + extra)
			var fp := _footprint_terrain(terrain, c2, t, half_len, half_w)
			if fp["spread"] < best_spread:
				best_spread = fp["spread"]
				best = {"pos2": c2, "tan2": t, "top": fp["top"]}
	if best.is_empty():
		# Degenerate curve: fall back to the seeded point.
		var c := centerline.sample_baked(clampf(seed_offset, 0.0, baked))
		best = {"pos2": c, "tan2": Vector2(0.0, 1.0), "top": terrain.height_at(c.x, c.y)}
	return best


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
# player car's tuning, its own mesh copies, engine silenced. It spawns live so it
# settles onto its wheels on the (possibly sloped) verge, then freezes — FREEZE_MODE_STATIC
# (the default) keeps the collider, so the frozen wreck is a solid, immovable obstacle.
# Its HP is zeroed so the synthetic engine smoke reads it as a wreck and puffs hardest.
func _spawn_wreck_car(library_index: int, xform: Transform3D, parent: Node, cfg: GameConfig) -> Node3D:
	# Variant (not :=) so the dynamic car-script calls don't depend on the analyzer
	# resolving car.tscn's root script type at parse time (see podium.gd._spawn_car).
	var car: Variant = load(WRECK_CAR_SCENE).instantiate()
	parent.add_child(car)
	car.use_isolated_config()
	car.apply_car(library_index)
	for mi in car.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh != null:
			m.mesh = m.mesh.duplicate()
	car.global_transform = xform
	# Lock its controls: it's a driverless prop, so it must ignore live driving input
	# during its settle (the player may be holding throttle at the start line) — and the
	# lock also engages its handbrake, so it can't roll downhill before it freezes.
	car.controls_locked = true
	# Read as a wreck: 0 HP drives the synthetic smoke below (a wrecked car smokes
	# hardest), exactly as a damaged HQ car does.
	if car.get("damage") != null:
		car.damage.hp = 0.0
	# A wreck makes no engine noise.
	var audio: Variant = car.get_node_or_null("EngineAudio")
	if audio != null:
		audio.process_mode = Node.PROCESS_MODE_DISABLED
		if audio is AudioStreamPlayer:
			audio.playing = false
			audio.volume_db = -80.0
	if _headless:
		_freeze_wreck_car(car)
	else:
		car.freeze = false  # live so it settles onto its wheels, then frozen below
		var settle: float = maxf(cfg.opponent_wreck_settle_seconds, 0.0)
		if settle > 0.0:
			get_tree().create_timer(settle).timeout.connect(
				func() -> void: _freeze_wreck_car(car))
		else:
			_freeze_wreck_car(car)
	_add_wreck_smoke(car)
	return car


# Freeze a settled wreck car into a static, immovable obstacle. FREEZE_MODE_STATIC (the
# default) keeps its collider live, so crashing into it still bites — it just won't move.
func _freeze_wreck_car(car: Variant) -> void:
	if not is_instance_valid(car):
		return
	car.freeze = true
	car.process_mode = Node.PROCESS_MODE_DISABLED


# Give the wreck lazy engine smoke like a damaged HQ display car: the frozen prop's
# engine never runs, so EngineSmoke self-times puffs from the car's (zeroed) damage
# severity. Parented to the car so it's freed with it, PROCESS_MODE_ALWAYS so it keeps
# puffing though the car itself is frozen / process-disabled.
func _add_wreck_smoke(car: Node) -> void:
	if not Config.data.engine_smoke_enabled:
		return
	var smoke := EngineSmoke.new()
	car.add_child(smoke)
	smoke.process_mode = Node.PROCESS_MODE_ALWAYS
	smoke.setup_synthetic(car)


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
	var mesh := MeshUtil.first_mesh(load(WRECK_SPECTATOR_SCENE))
	if mesh == null:
		return
	var foot := -mesh.get_aabb().position.y  # feet on the ground, as SpectatorGroup does
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = count
	var base_ang := atan2(outward.y, outward.x)  # away from the road
	var positions: Array = []
	for i in count:
		# A crescent spanning ±~115° about 'outward' — the verge side + flanks, never the
		# road-ward hemisphere between the wreck and the carriageway.
		var frac := 0.0 if count <= 1 else float(i) / float(count - 1)
		var ang := base_ang + lerpf(-2.0, 2.0, frac)
		var r: float = cfg.opponent_wreck_crowd_radius_m
		var px := center.x + cos(ang) * r
		var pz := center.z + sin(ang) * r
		var py := terrain.height_at(px, pz)
		# Face the wreck at the centre (the figure's default facing is +Z).
		var to_center := Vector2(center.x - px, center.z - pz)
		var yaw := atan2(to_center.x, to_center.y)
		mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, yaw),
			Vector3(px, py + foot, pz)))
		positions.append(Vector2(px, pz))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "WreckCrowd"
	mmi.multimesh = mm
	# The scatter, readable by tests: headless MultiMesh transform buffers are
	# RenderingServer no-op stubs and can't be read back (see hq_environment.gd).
	mmi.set_meta("positions", positions)
	parent.add_child(mmi)


# The live event data the arch banners display (rally name, which stage and the
# time-to-beat), read off RallySession. The rally's difficulty tier is a hidden
# value, so it's deliberately not surfaced here. When no rally is active (a dev boot
# / direct play) the fields stay empty/zero and the gate shows just its START /
# FINISH wordmark.
func _arch_event_info() -> Dictionary:
	var info := {"rally_name": "", "stage_index": 0, "stage_count": 0, "target_ms": -1}
	if RallySession.is_active():
		var rally := RallyLibrary.by_id(RallySession.rally_id())
		info["rally_name"] = String(rally.get("name", ""))
		info["stage_index"] = RallySession.event_index()
		info["stage_count"] = RallySession.EVENTS_PER_RALLY
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
	var existing := get_node_or_null(node_name)
	if existing != null:
		remove_child(existing)
		existing.free()
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
var _replay_camera: ReplayCamera
var _standings_overlay: CanvasLayer

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
func _setup_stage_splits(track_result: Dictionary, staged: bool, cfg: GameConfig) -> void:
	if _stage_manager == null or not RallySession.is_active():
		return
	var p1_ms := RallySession.current_event_target_ms()
	if p1_ms <= 0:
		return
	var p1_car := RallySession.current_event_p1_car()
	if p1_car.is_empty():
		return
	var splits := RallyLibrary.derive_turn_splits(track_result, p1_car, RallySession.current_event())
	if splits.is_empty():
		return
	var total_ms := int(splits[splits.size() - 1]["cum_ms"])
	if total_ms <= 0:
		return
	# Progress is measured from the start line to the finish. A staged run prepends a
	# straight lead-in of start_lead_in_ahead_m ahead of the generated track, so the
	# drivable span (and thus the progress denominator) is that plus the track length.
	var ahead := cfg.start_lead_in_ahead_m if staged else 0.0
	var raw_len: float = (track_result.get("centerline") as Curve2D).get_baked_length()
	var span := ahead + raw_len
	if span <= 0.0:
		return
	var turn_progress: Array[float] = []
	var turn_time_frac: Array[float] = []
	for s in splits:
		turn_progress.append(clampf((ahead + float(s["end_offset_m"])) / span, 0.0, 1.0))
		turn_time_frac.append(clampf(float(s["cum_ms"]) / float(total_ms), 0.0, 1.0))
	_stage_manager.setup_splits(turn_progress, turn_time_frac, p1_ms)


# --- RallySession run-scene integration (features/rally-session.md) ------------

# Dev cheat (F key, features/debug-tools.md): skip straight to the finish of the
# current event. Debug-build only (release/web ignore it) and only inside an active
# rally event with a live StageManager. Teleports the car onto the finish line and
# force-completes the stage, so the whole completion → reward → progression flow
# fires exactly as it would on a real finish.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("skip_to_finish"):
		return
	if not OS.is_debug_build() or not RallySession.is_active():
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


# Whether this run should open with the pre-event start-line scene: a session run
# with the feature enabled AND a resolvable rally (so a missing rally never strands
# the car in STAGING with no StartLine to launch it).
func _should_stage() -> bool:
	return RallySession.is_active() and Config.data.start_line_enabled \
		and not RallyLibrary.by_id(RallySession.rally_id()).is_empty()


# Build the pre-event start-line sequence around the fielded car (the times-to-beat
# reveal + orbit camera + start queue). The StageManager is already in STAGING;
# StartLine hands the camera/UI back and launches it after its fade.
func _build_start_line() -> void:
	var rally := RallyLibrary.by_id(RallySession.rally_id())
	_start_line = StartLine.new()
	_start_line.name = "StartLine"
	add_child(_start_line)
	_start_line.setup($Car, $Floor, _stage_manager, rally, RallySession.event_index(),
		RallySession.current_event_leaders(3), $CameraManager as CameraManager,
		$HUD as CanvasLayer, $MobileControls as CanvasLayer)


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

# Configure the car for the session's fielded OwnedCar; fall back to the default
# car if the instance has vanished from the save (defensive).
func _field_session_car() -> void:
	var owned: Dictionary = Save.get_car(RallySession.car_instance_id())
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
# automatically when the scene reloads for the next event.
func _wire_session_signals() -> void:
	if _stage_manager != null and not _stage_manager.stage_completed.is_connected(_on_session_event_completed):
		_stage_manager.stage_completed.connect(_on_session_event_completed)
	if not ($Car as Node).wrecked.is_connected(_on_session_car_wrecked):
		($Car as Node).wrecked.connect(_on_session_car_wrecked)
	if not RallySession.rally_finished.is_connected(_on_session_rally_finished):
		RallySession.rally_finished.connect(_on_session_rally_finished)

	# Live (non-headless) runs own the standings presentation as an in-world
	# overlay, keeping this run world alive behind it for the cinematic replay;
	# RallySession then skips its own scene-change path (see rally_session.gd).
	RallySession.standings_overlay_host = not _headless
	if _stage_manager != null and not _stage_manager.stage_started.is_connected(_on_stage_started):
		_stage_manager.stage_started.connect(_on_stage_started)
	if _stage_manager != null and not _stage_manager.finish_reached.is_connected(_on_finish_reached):
		_stage_manager.finish_reached.connect(_on_finish_reached)
	if not RallySession.standings_ready.is_connected(_present_standings_overlay):
		RallySession.standings_ready.connect(_present_standings_overlay)


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
	# No active rally — free roam (or a plain dev boot) reached the finish. There is
	# no session to report to (report_event_result would silently no-op, leaving the
	# finish panel's Next doing nothing), so Next returns to HQ instead — the same
	# destination as the pause menu's Quit with no session.
	if not RallySession.is_active():
		_change_scene("res://hq.tscn")
		return
	# HP lost + persisted wheel-toe are snapshotted at the FINISH CROSSING (see
	# _on_finish_reached), NOT here: this handler fires on the NEXT button, by which time
	# the car has skidded to a stop / idled in the runoff, and any barrier clip during
	# that post-finish coast would be wrongly charged to the event's damage.
	var hp_lost: float = maxf(0.0, _event_start_hp - _event_hp_at_finish)
	var iid: int = RallySession.car_instance_id()
	if iid >= 0:
		Save.set_wheel_toe(iid, _event_toe_at_finish)
	if _replay_recorder != null:
		_replay_recorder.stop()
	RallySession.report_event_result(int(round(elapsed_seconds * 1000.0)), hp_lost)


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
	_replay_camera.setup($Car, _replay_recorder)
	_replay_camera.current = true
	# Car into replay playback.
	($Car as Node).begin_replay(_replay_recorder)
	# Standings overlay Control on its own CanvasLayer.
	_standings_overlay = CanvasLayer.new()
	_standings_overlay.name = "StandingsOverlay"
	var panel: Control = load("res://standings.tscn").instantiate()
	panel.overlay_mode = true
	panel.leaderboard_hidden_changed.connect(_on_leaderboard_hidden_changed)
	_standings_overlay.add_child(panel)
	add_child(_standings_overlay)
	_on_leaderboard_hidden_changed(false)   # shown -> engine muted


func _on_leaderboard_hidden_changed(hidden: bool) -> void:
	# Engine audio: muted while the leaderboard is shown, on while hidden (watch mode).
	var ea := $Car.get_node_or_null("EngineAudio") as AudioStreamPlayer
	if ea != null:
		ea.volume_db = 0.0 if hidden else -60.0


func _on_session_car_wrecked() -> void:
	# Don't cut straight to the podium — that's too sudden. Let the crash play out,
	# then show the wreck menu (orbit camera + Return to HQ); reporting the wreck
	# (the DNF) is deferred until the player chooses to leave. Headless runs (no
	# display, e.g. tests) skip the cinematic and report immediately.
	if _headless or _wreck_screen != null:
		RallySession.report_wreck()
		return
	_wreck_screen = WreckScreen.new()
	_wreck_screen.name = "WreckScreen"
	add_child(_wreck_screen)
	_wreck_screen.return_requested.connect(RallySession.report_wreck)
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


# Swap to the next car in the library: re-instantiate a fresh car (see
# Car.respawn for why) and re-point the camera and HUD at it.
func cycle_car() -> void:
	var car: Node = $Car
	# Move the bonnet camera off the outgoing car before it is freed, so it
	# survives the swap and can be re-parented onto the fresh car.
	var mgr := $CameraManager
	var bonnet: Camera3D = mgr.bonnet_camera
	if bonnet.get_parent() == car:
		car.remove_child(bonnet)
		add_child(bonnet)  # park on the world root during the swap
	var fresh: Node = car.respawn(car, car.next_car_index(), _car_spawn)
	mgr.retarget(fresh)
	($HUD as CanvasLayer).car = fresh
	# Re-point the speed-lines overlay at the fresh car too (it reads the car's
	# velocity each frame), so it doesn't keep the freed outgoing node.
	var lines := get_node_or_null("SpeedLines")
	if lines != null:
		lines.car = fresh
	# Re-point progress tracking at the fresh car (it respawns at the start, so
	# progress resets to the spawn offset too).
	if _track_progress != null:
		_track_progress.retarget(fresh, $Floor as TerrainManager)
	# Re-point tire marks at the fresh car and clear the outgoing car's ribbons.
	if _tire_marks != null:
		_tire_marks.retarget(fresh)
	# Re-point wheel dust at the fresh car and clear the outgoing car's clods.
	if _wheel_particles != null:
		_wheel_particles.retarget(fresh)
	if _engine_smoke != null:
		_engine_smoke.retarget(fresh)
	# Re-arm the stage on the fresh car (it spawns at the start), so the countdown
	# restarts and the manager doesn't keep a freed car reference.
	if _stage_manager != null:
		_stage_manager.setup(fresh, $HUD as CanvasLayer, _track_progress)


func _layers_match(layers: Array[TerrainLayer], params: Array[Vector2]) -> bool:
	if layers.size() != params.size():
		return false
	for i in layers.size():
		if layers[i] == null or layers[i].wavelength_m != params[i].x or layers[i].amplitude_m != params[i].y:
			return false
	return true


func _mat(mesh_instance: MeshInstance3D) -> ShaderMaterial:
	return mesh_instance.get_surface_override_material(0) as ShaderMaterial

extends Node3D
# Applies the central GameConfig to scene-owned resources at startup.
# Car handling is applied by car.gd; camera follow by chase_camera.gd.

const TREE_MODEL := preload("res://models/low_poly_tree.glb")
const BUSH_SEED_OFFSET := 1013
# Ground-cover bush: low-poly mesh (replaces the old bush.webp billboards),
# instanced via TreeMeshField (same renderer as trees, no collision). See features/trees.md.
const GROUNDCOVER_SCENE := preload("res://models/vegetation/groundcover_opaque.glb")
# Near-camera dither dissolve applied to the tree canopy so trees don't block the
# chase camera when it pushes inside them (see shaders/tree_canopy.gdshader).
const TREE_CANOPY_SHADER := preload("res://shaders/tree_canopy.gdshader")

# Headless (test) runs build the world synchronously — see _yield_frame(). Cached
# so the staged-loading awaits collapse to no-ops and tests see a fully-built
# world the instant main.tscn is instantiated, exactly as before this overlay.
var _headless := false

# The tree ArrayMesh, extracted once from TREE_MODEL (a PackedScene) and shared
# by every per-bin MultiMesh in the TreeMeshField.
var _tree_mesh_cache: Mesh


# Extracts (and caches) the tree mesh from the imported .glb scene.
func _tree_mesh() -> Mesh:
	if _tree_mesh_cache != null:
		return _tree_mesh_cache
	var scene := TREE_MODEL.instantiate()
	var stack: Array[Node] = [scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			_tree_mesh_cache = (n as MeshInstance3D).mesh
			break
		for c in n.get_children():
			stack.append(c)
	scene.queue_free()
	if _tree_mesh_cache != null:
		var cfg: GameConfig = Config.data
		for s in _tree_mesh_cache.get_surface_count():
			var sm := _tree_mesh_cache.surface_get_material(s) as BaseMaterial3D
			if sm == null:
				continue
			# The GLB's baked StandardMaterials import with linear filtering, which
			# blurs the leaf texture; force nearest (keeping mipmaps) for the flat
			# PS1 look.
			sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
			# The canopy is the textured (leaf-mapped) surface; the trunk has no
			# texture. Swap the canopy to a ShaderMaterial that keeps the unshaded,
			# double-sided, vertex-colour-tinted look but dither-dissolves near the
			# camera so a tree the chase camera enters stops blocking the view.
			if sm.albedo_texture != null:
				var canopy := ShaderMaterial.new()
				canopy.shader = TREE_CANOPY_SHADER
				canopy.set_shader_parameter("albedo", sm.albedo_texture)
				canopy.set_shader_parameter("near_fade_start", cfg.tree_near_fade_start_m)
				canopy.set_shader_parameter("near_fade_end", cfg.tree_near_fade_end_m)
				_tree_mesh_cache.surface_set_material(s, canopy)
	return _tree_mesh_cache


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
	($PostProcess/ColorRect.material as ShaderMaterial).set_shader_parameter("virtual_resolution", cfg.virtual_resolution)

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

	# A session run wires this event's completion / wreck back to the orchestrator,
	# and routes the rally's finish to the podium.
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
	# wheel-force debug overlay; harmless and idle until toggled on.
	add_child(PerfOverlay.new($Floor as TerrainManager))


# Yield a frame so a freshly-set LoadingScreen step actually paints before the
# next blocking generation call. A no-op under headless, where the await would
# otherwise spread world generation across frames and break tests that inspect
# the world right after instantiating main.tscn — there the whole _ready chain
# runs synchronously within add_child(), as it did before staged loading.
func _yield_frame() -> void:
	if not _headless:
		await get_tree().process_frame


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
	if loading != null:
		loading.set_step("Generating track…")
	await _yield_frame()
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
		cfg.track_clearance, reserve_behind, cfg.track_straightness)
	# Road/progress centerline (with the lead-in for staged runs). The raw generated
	# centerline still feeds the signs, so the start gate sits ahead of the launch
	# point — the cars cross it as they pull away.
	var road_centerline := result["centerline"] as Curve2D
	if staged:
		road_centerline = _with_start_lead_in(road_centerline, start_pos, start_heading, cfg)
	var transition_m := cfg.track_transition_cells * TerrainManager.CELL_M
	# Surface split: the track runs gravel + tarmac with one switch, the tarmac
	# share = track_tarmac_fraction (set per rally event). Which surface it opens on
	# is seeded off track_seed so it's deterministic but varied across events.
	var tarmac_first := TrackSurface.orientation_tarmac_first(cfg.track_seed)
	$Floor.set_track(road_centerline, cfg.track_width, transition_m,
		cfg.track_tarmac_fraction, tarmac_first, cfg.track_surface_transition_m)

	if loading != null:
		loading.set_step("Building terrain…")
	await _yield_frame()
	$Floor.build_initial()

	# Coarse distant backdrop so the reduced fog reveals a horizon (for the sky)
	# instead of the hard edge where the detailed 3x3 ring ends (~75 m). Pure
	# scenery: no collision, re-centres on the car. Built after build_initial() has
	# warmed the noise cache height_at/light_at read. See distant_terrain.gd.
	if cfg.distant_terrain_enabled and _distant_terrain == null:
		_distant_terrain = DistantTerrain.new()
		_distant_terrain.name = "DistantTerrain"
		_distant_terrain.radius_m = cfg.distant_terrain_radius_m
		_distant_terrain.cell_m = cfg.distant_terrain_cell_m
		_distant_terrain.sink_m = cfg.distant_terrain_sink_m
		add_child(_distant_terrain)
		_distant_terrain.setup($Floor as TerrainManager, $Car)

	if loading != null:
		loading.set_step("Scattering trees…")
	await _yield_frame()
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
	var tree_field := TreeMeshField.new()
	add_child(tree_field)
	tree_field.build(trees, $Floor as TerrainManager, _tree_mesh(),
		cfg.tree_size_m.y, cfg.tree_collision_radius_m, cfg.tree_collision_height_m,
		cfg.tree_render_distance_m, cfg.tree_render_fade_m, cfg.tree_bin_size_m)

	if loading != null:
		loading.set_step("Scattering bushes…")
	await _yield_frame()
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
	var bush_mesh := _bush_mesh(cfg)
	var bush_radius := TreeMeshField.xz_radius(bush_mesh, cfg.bush_height_m)
	var bush_footprint := cfg.track_width + 2.0 * (cfg.tree_road_margin_m + bush_radius)
	var bush_road_cells := TrackGenerator.rasterize_cells(
		road_centerline.tessellate(), bush_footprint)
	var bushes := TreeScatter.scatter(result["pieces"], bush_road_cells, cfg.tree_params(),
		cfg.track_seed + BUSH_SEED_OFFSET)
	var bush_field := TreeMeshField.new()
	add_child(bush_field)
	bush_field.build(bushes, $Floor as TerrainManager, bush_mesh,
		cfg.bush_height_m, 0.0, 0.0,
		cfg.tree_render_distance_m, cfg.tree_render_fade_m, cfg.tree_bin_size_m,
		false, true)

	# Bushes are pass-through (no collider), so a separate proximity node makes
	# brushing one cost HP + apply a drag torque. Hit radius is slightly under the
	# bush's visual width (bush_hit_radius_frac) so clipping the edge is forgiven.
	var bush_interaction := BushField.new()
	bush_interaction.name = "BushInteraction"
	add_child(bush_interaction)
	bush_interaction.setup(bushes, $Car,
		bush_radius * cfg.bush_hit_radius_frac,
		cfg.bush_hp_loss, cfg.bush_drag_torque,
		cfg.bush_min_speed_kmh / DamageModel.MPS_TO_KMH, cfg.soft_hit_cooldown_s)

	if loading != null:
		loading.set_step("Placing signs…")
	await _yield_frame()
	# Roadside turn-arrow signs along the stage (todo/roadside-signs.md). Few per
	# stage, so individual nodes (not a MultiMesh); knockable cosmetic props that
	# deal no HP damage. Start/finish are the inflatable arches, not signs.
	var sign_layout := SignLayout.plan(result["centerline"], result["pieces"])
	var sign_field := SignField.new()
	add_child(sign_field)
	sign_field.build(sign_layout, $Floor as TerrainManager, cfg.sign_render_params())

	# Roadside spectators: crowds that react to the car (todo/roadside-spectators.md).
	# One group at the start, one at the end, and one at a seeded mid-stage point.
	# Built after trees so members can avoid spawning inside foliage; reuses the
	# centerline, road_cells and terrain already in scope.
	if cfg.spectators_enabled and cfg.spectator_group_size > 0:
		_spawn_spectators(road_centerline, road_cells, trees, start_pos, start_heading,
			cfg, $Floor as TerrainManager)

	# Finish + start arches: the inflatable gates straddling the road
	# (features/finish-arch.md). The FINISH gate sits at the END of the progress
	# centerline — i.e. exactly 100% track progress — so crossing it ends the stage
	# immediately; the START gate sits at the start line where the car actually
	# spawns. Each opening is sized to the road width plus a margin so the legs stand
	# clear, and each is turned so its banner face meets the driver.
	var arch_terrain := $Floor as TerrainManager
	var arch_info := _arch_event_info()
	if cfg.finish_arch_enabled:
		var fin_len := road_centerline.get_baked_length()
		if fin_len > 0.0:
			var fin_pos := road_centerline.sample_baked(fin_len)
			var fin_tan := fin_pos - road_centerline.sample_baked(maxf(0.0, fin_len - 0.5))
			_place_arch("FinishArch", fin_pos, fin_tan, false, arch_info, cfg, arch_terrain)
	if cfg.start_arch_enabled:
		# start_pos / start_heading is the car's real spawn pose (the start line).
		_place_arch("StartArch", start_pos, start_heading, true, arch_info, cfg, arch_terrain)

	# Retain the centerline in a TrackProgress manager: tracks how far the car has
	# driven and snaps it back onto the road if it strays too far (the Curve2D is
	# otherwise discarded after set_track). Reuse the node across regenerations
	# (entering a new event) so managers don't accumulate or collide on name.
	if _track_progress == null:
		_track_progress = TrackProgress.new()
		_track_progress.name = "TrackProgress"
		add_child(_track_progress)
	_track_progress.setup(road_centerline, $Car, $Floor as TerrainManager)

	# Tire marks: gravel ruts laid behind the wheels while on the road
	# (features/tire-marks.md). Reuse the node across regenerations like the managers
	# above; gated to the road half-width, so it needs the centerline + terrain.
	if _tire_marks == null:
		_tire_marks = TireMarks.new()
		_tire_marks.name = "TireMarks"
		add_child(_tire_marks)
	_tire_marks.setup(road_centerline, $Car, $Floor as TerrainManager, cfg.track_width * 0.5)

	# Road paint: solid edge lines + a dashed centre line along the tarmac sections,
	# so tarmac reads as tarmac (features/track.md). A static mesh built once from the
	# centerline + surface split; rebuilt on a regeneration like the managers above.
	if _road_markings == null:
		_road_markings = RoadMarkings.new()
		_road_markings.name = "RoadMarkings"
		add_child(_road_markings)
	_road_markings.build(road_centerline, $Floor as TerrainManager, cfg.road_marking_params())

	# Wheel dust: cheap gravel spray flung from the driven wheels under wheelspin
	# (features/wheel-dust.md). Reused across regenerations like the managers above;
	# the surface under each wheel (gravel vs grass/tarmac) is read live off the
	# car's drivetrain terrain, so it only needs the car here.
	if _wheel_particles == null:
		_wheel_particles = WheelParticles.new()
		_wheel_particles.name = "WheelParticles"
		add_child(_wheel_particles)
	_wheel_particles.setup($Car)

	# Grey smoke puffed from the bonnet each time a damaged engine misfires. Its own
	# small MultiMesh pool; reads the car's engine misfire counter live. See
	# features/engine-smoke.md.
	if _engine_smoke == null:
		_engine_smoke = EngineSmoke.new()
		_engine_smoke.name = "EngineSmoke"
		add_child(_engine_smoke)
	_engine_smoke.setup($Car)

	# Per-stage start/end flow: lock the car, count down, time the run, and signal
	# completion when progress reaches the finish (todo/stage-start-and-end.md).
	# Reuse the node across regenerations so only one ticks.
	if _stage_manager == null:
		_stage_manager = StageManager.new()
		_stage_manager.name = "StageManager"
		add_child(_stage_manager)
	# Staged runs hold the car in the start-line sequence until the player launches;
	# otherwise the countdown arms immediately, as before. (`staged` computed above.)
	_stage_manager.setup($Car, $HUD as CanvasLayer, _track_progress, staged)
	# In-stage "vs P1" pace popup: every few turns the HUD shows how the player's
	# elapsed time compares to the leading rival's estimated time at that point.
	_setup_stage_splits(result, staged, cfg)

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


# Build the ground-cover bush mesh from the groundcover_opaque GLB. Keeps the
# imported (tone-matched) foliage texture, but makes the material UNSHADED — the
# flat PS1 look the rest of the world uses — and enables vertex_color_use_as_albedo
# so the per-instance baked terrain light TreeMeshField writes into the MultiMesh
# COLOR multiplies the albedo (matching the ground tint everywhere, as the old
# foliage shader did). Duplicated so the cached scene resource is not mutated.
func _bush_mesh(cfg: GameConfig) -> Mesh:
	var inst := GROUNDCOVER_SCENE.instantiate()
	var src := inst.find_children("*", "MeshInstance3D", true, false)[0] as MeshInstance3D
	var mesh: Mesh = src.mesh.duplicate()
	inst.free()
	var base := mesh.surface_get_material(0)
	var mat: StandardMaterial3D = base.duplicate() if base is StandardMaterial3D else StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	# Lifted tint so the tone-matched ground cover reads a bit more against the grass.
	mat.albedo_color = cfg.bush_tint
	# Nearest filter (keep mipmaps) for the flat PS1 look, like the rest of the world.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mesh.surface_set_material(0, mat)
	return mesh


# Place the three spectator crowds: one at the start line, one at the finish, and
# one at a seeded fraction of the way along (todo/roadside-spectators.md). Builds a
# shared tree-point grid once so members can avoid spawning inside foliage.
func _spawn_spectators(centerline: Curve2D, road_cells: Dictionary, trees: PackedVector2Array,
		start_pos: Vector2, start_heading: Vector2, cfg: GameConfig, terrain: TerrainManager) -> void:
	var baked := centerline.get_baked_length()
	if baked <= 0.0:
		return
	var tree_cell: float = maxf(cfg.spectator_tree_avoid_m, 0.5)
	var tree_grid := SpectatorScatter.build_point_grid(trees, tree_cell)

	# Start: at the car's spawn pose.
	_spawn_spectator_group("SpectatorStart", start_pos, start_heading,
		road_cells, tree_grid, cfg, terrain, cfg.track_seed + 101)

	# Mid: a seeded fraction of the way along the centerline.
	var mid_off := SpectatorScatter.mid_offset(baked,
		cfg.spectator_mid_progress_min, cfg.spectator_mid_progress_max, cfg.track_seed)
	var mid_pt := centerline.sample_baked(mid_off)
	var mid_tan := centerline.sample_baked(minf(mid_off + 1.0, baked)) - mid_pt
	_spawn_spectator_group("SpectatorMid", mid_pt, mid_tan,
		road_cells, tree_grid, cfg, terrain, cfg.track_seed + 202)

	# End: at the finish (end of the centerline).
	var end_pt := centerline.sample_baked(baked)
	var end_tan := end_pt - centerline.sample_baked(maxf(0.0, baked - 1.0))
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

# Configure the car for the session's fielded OwnedCar; fall back to the default
# car if the instance has vanished from the save (defensive).
func _field_session_car() -> void:
	var owned: Dictionary = Save.get_car(RallySession.car_instance_id())
	if owned.is_empty():
		$Car.apply_car(0)
		return
	$Car.apply_owned(owned)
	_event_start_hp = $Car.damage.hp


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


func _on_session_event_completed(elapsed_seconds: float) -> void:
	var hp_lost: float = maxf(0.0, _event_start_hp - $Car.damage.hp)
	# Persist the wheels bent this event so the car carries its misalignment forward.
	var iid: int = RallySession.car_instance_id()
	if iid >= 0:
		Save.set_wheel_toe(iid, $Car.damage.toe_array())
	RallySession.report_event_result(int(round(elapsed_seconds * 1000.0)), hp_lost)


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
		get_tree().change_scene_to_file("res://hq.tscn")
	else:
		get_tree().change_scene_to_file("res://podium.tscn")


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

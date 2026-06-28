extends Node3D
# Applies the central GameConfig to scene-owned resources at startup.
# Car handling is applied by car.gd; camera follow by chase_camera.gd.

const TREE_TEXTURE := preload("res://textures/tree.png")
const BUSH_TEXTURE := preload("res://textures/bush.webp")
const BUSH_SEED_OFFSET := 1013

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
	($PostProcess/ColorRect.material as ShaderMaterial).set_shader_parameter("virtual_resolution", cfg.virtual_resolution)

	# Field the car. With an active RallySession this event runs the player's
	# OwnedCar (baseline + upgrades + saved HP, features/rally-session.md); a plain
	# dev boot keeps the first library car (the Mazda MX-5).
	_car_spawn = $Car.transform  # authored spawn, reused so swaps don't drift
	if RallySession.is_active():
		_field_session_car()
	else:
		$Car.apply_car(0)

	await _generate_track(cfg, loading)

	# A session run wires this event's completion / wreck back to the orchestrator,
	# and routes the rally's finish to the podium.
	if RallySession.is_active():
		_wire_session_signals()
		# Pre-event start-line scene: briefing + presence cars before the countdown
		# (todo/menus.md location 2). Only when staged (start_line_enabled + a real
		# rally); the StageManager is already waiting in STAGING for its launch.
		if _should_stage():
			_build_start_line()

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
		cfg.track_clearance, reserve_behind)
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
		add_child(_distant_terrain)
		_distant_terrain.setup($Floor as TerrainManager, $Car)

	if loading != null:
		loading.set_step("Scattering trees…")
	await _yield_frame()
	# Scatter billboard trees around each turn, then render them in one MultiMesh.
	# height_at needs the terrain noise cache, which build_initial() has warmed.
	# Reject trees on the visible road inflated by tree_road_margin_m — NOT the
	# clearance-inflated result["cells"], which is track_width + 2*track_clearance
	# wide and would push every tree metres back from the real road edge. The
	# margin keeps a small, tunable gap between the nearest trees and the road.
	var road_footprint := cfg.track_width + 2.0 * cfg.tree_road_margin_m
	var road_cells := TrackGenerator.rasterize_cells(
		road_centerline.tessellate(), road_footprint)
	# Trees are gated by the per-event forest noise (cfg.track_forestiness): they only
	# spawn inside the forest patches, breaking up the otherwise-continuous tree line.
	var trees := TreeScatter.scatter(result["pieces"], road_cells, cfg.tree_params(),
		cfg.track_seed, cfg.track_forestiness, cfg.forest_wavelength_m)
	var tree_field := BillboardField.new()
	add_child(tree_field)
	tree_field.build(trees, $Floor as TerrainManager, cfg.tree_size_m, TREE_TEXTURE,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m, true,
		cfg.tree_render_distance_m, cfg.tree_render_fade_m)

	if loading != null:
		loading.set_step("Scattering bushes…")
	await _yield_frame()
	# Bushes: same scatter + render as trees, but bush.webp, no collision, and an
	# offset seed so they interleave with the trees. They are NOT forest-gated (default
	# forestiness 1.0), so undergrowth covers the whole stage, not just the forest.
	var bushes := TreeScatter.scatter(result["pieces"], road_cells, cfg.tree_params(),
		cfg.track_seed + BUSH_SEED_OFFSET)
	var bush_field := BillboardField.new()
	add_child(bush_field)
	bush_field.build(bushes, $Floor as TerrainManager, cfg.bush_size_m, BUSH_TEXTURE,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m, false,
		cfg.tree_render_distance_m, cfg.tree_render_fade_m, -cfg.bush_sink_m)

	if loading != null:
		loading.set_step("Placing signs…")
	await _yield_frame()
	# Roadside signs: sector boards, turn arrows, and start/finish gates along the
	# stage (todo/roadside-signs.md). Few per stage, so individual nodes (not a
	# MultiMesh); their collision bodies are obstacles, so clipping one costs HP.
	var sign_layout := SignLayout.plan(result["centerline"], result["pieces"], cfg.sign_params())
	var sign_field := SignField.new()
	add_child(sign_field)
	sign_field.build(sign_layout, $Floor as TerrainManager, cfg.sign_render_params())

	# Retain the centerline in a TrackProgress manager: tracks how far the car has
	# driven and snaps it back onto the road if it strays too far (the Curve2D is
	# otherwise discarded after set_track). Reuse the node across regenerations
	# (entering a new event) so managers don't accumulate or collide on name.
	if _track_progress == null:
		_track_progress = TrackProgress.new()
		_track_progress.name = "TrackProgress"
		add_child(_track_progress)
	_track_progress.setup(road_centerline, $Car, $Floor as TerrainManager)
	($HUD as CanvasLayer).track_progress = _track_progress

	# Tire marks: gravel ruts laid behind the wheels while on the road
	# (features/tire-marks.md). Reuse the node across regenerations like the managers
	# above; gated to the road half-width, so it needs the centerline + terrain.
	if _tire_marks == null:
		_tire_marks = TireMarks.new()
		_tire_marks.name = "TireMarks"
		add_child(_tire_marks)
	_tire_marks.setup(road_centerline, $Car, $Floor as TerrainManager, cfg.track_width * 0.5)

	# Wheel dust: cheap gravel spray flung from the driven wheels under wheelspin
	# (features/wheel-dust.md). Reused across regenerations like the managers above;
	# gated to the road half-width so it only sprays on the gravel, not the grass.
	if _wheel_particles == null:
		_wheel_particles = WheelParticles.new()
		_wheel_particles.name = "WheelParticles"
		add_child(_wheel_particles)
	_wheel_particles.setup(road_centerline, $Car, cfg.track_width * 0.5)

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

	# World is ready — drop the loading overlay (absent for direct/programmatic
	# regeneration, e.g. entering a rally event).
	if loading != null:
		loading.finish()


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

# Flings cheap gravel dust off the driven wheels under wheelspin (re-targeted on
# a car swap).
var _wheel_particles: WheelParticles

# Coarse far-terrain backdrop that gives the sky a horizon (distant_terrain.gd).
var _distant_terrain: DistantTerrain

# The pre-event start-line scene (briefing + presence cars); built for staged
# session runs and freed with the scene on the next event reload.
var _start_line: StartLine

# Working HP the fielded car started this event with, so the event's HP loss can
# be reported back to the session at completion. Set when fielding a session car.
var _event_start_hp := 0.0


# --- RallySession run-scene integration (features/rally-session.md) ------------

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
		RallySession.current_event_leaders(3), $ChaseCamera as Camera3D,
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
	RallySession.report_event_result(int(round(elapsed_seconds * 1000.0)), hp_lost)


func _on_session_car_wrecked() -> void:
	RallySession.report_wreck()


# Rally over (or DNF): show the podium. Loads under the (placeholder) transition.
func _on_session_rally_finished(_result: Dictionary) -> void:
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

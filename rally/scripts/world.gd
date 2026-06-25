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
	# Assigning layers triggers a full terrain regeneration; skip when equal.
	if not _layers_match($Floor.layers, cfg.terrain_layers()):
		var layers: Array[TerrainLayer] = []
		for params in cfg.terrain_layers():
			var layer := TerrainLayer.new()
			layer.wavelength_m = params.x
			layer.amplitude_m = params.y
			layers.append(layer)
		$Floor.layers = layers
	_mat($Car/Chassis).set_shader_parameter("albedo_color", cfg.chassis_color)
	_mat($Car/Cabin).set_shader_parameter("albedo_color", cfg.cabin_color)
	# Wheel materials are shared resources; setting each once covers all four.
	_mat($Car/WheelFL/Visual/Tire).set_shader_parameter("albedo_color", cfg.wheel_color)
	_mat($Car/WheelFL/Visual/Spoke1).set_shader_parameter("albedo_color", cfg.wheel_spoke_color)
	($PostProcess/ColorRect.material as ShaderMaterial).set_shader_parameter("virtual_resolution", cfg.virtual_resolution)

	# Boot the playable scene with the first library car (the Mazda MX-5)
	# selected; the HUD's car button cycles through the rest at runtime.
	_car_spawn = $Car.transform  # authored spawn, reused so swaps don't drift
	$Car.apply_car(0)

	await _generate_track(cfg, loading)

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
func _generate_track(cfg: GameConfig, loading: LoadingScreen) -> void:
	loading.set_step("Generating track…")
	await _yield_frame()
	var xform: Transform3D = $Car.global_transform
	var start_pos := Vector2(xform.origin.x, xform.origin.z)
	# A Node3D's forward is -Z; project it onto the XZ plane.
	var fwd := -xform.basis.z
	var start_heading := Vector2(fwd.x, fwd.z).normalized()
	var result := TrackGenerator.generate(
		start_pos, start_heading, cfg.track_seed, cfg.track_turn_count, cfg.track_width,
		cfg.track_clearance)
	var transition_m := cfg.track_transition_cells * TerrainManager.CELL_M
	$Floor.set_track(result["centerline"], cfg.track_width, transition_m)

	loading.set_step("Building terrain…")
	await _yield_frame()
	$Floor.build_initial()

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
		(result["centerline"] as Curve2D).tessellate(), road_footprint)
	var trees := TreeScatter.scatter(result["pieces"], road_cells, cfg.tree_params(), cfg.track_seed)
	var tree_field := BillboardField.new()
	add_child(tree_field)
	tree_field.build(trees, $Floor as TerrainManager, cfg.tree_size_m, TREE_TEXTURE,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m, true,
		cfg.tree_render_distance_m, cfg.tree_render_fade_m)

	loading.set_step("Scattering bushes…")
	await _yield_frame()
	# Bushes: same scatter + render as trees, but bush.webp, no collision, and an
	# offset seed so they don't land on the same spots as the trees.
	var bushes := TreeScatter.scatter(result["pieces"], road_cells, cfg.tree_params(),
		cfg.track_seed + BUSH_SEED_OFFSET)
	var bush_field := BillboardField.new()
	add_child(bush_field)
	bush_field.build(bushes, $Floor as TerrainManager, cfg.bush_size_m, BUSH_TEXTURE,
		cfg.tree_collision_radius_m, cfg.tree_collision_height_m, false,
		cfg.tree_render_distance_m, cfg.tree_render_fade_m, -cfg.bush_sink_m)

	# Retain the centerline in a TrackProgress manager: tracks how far the car has
	# driven and snaps it back onto the road if it strays too far (the Curve2D is
	# otherwise discarded after set_track).
	_track_progress = TrackProgress.new()
	_track_progress.name = "TrackProgress"
	add_child(_track_progress)
	_track_progress.setup(result["centerline"], $Car, $Floor as TerrainManager)
	($HUD as CanvasLayer).track_progress = _track_progress

	# World is ready — drop the loading overlay.
	loading.finish()


# The authored car spawn transform, captured at boot so each car swap spawns in
# the same place rather than wherever the previous car drove to.
var _car_spawn: Transform3D

# Tracks track progress + off-track reset for the current car (re-targeted on a
# car swap, since the fresh car respawns at the start).
var _track_progress: TrackProgress


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


func _layers_match(layers: Array[TerrainLayer], params: Array[Vector2]) -> bool:
	if layers.size() != params.size():
		return false
	for i in layers.size():
		if layers[i] == null or layers[i].wavelength_m != params[i].x or layers[i].amplitude_m != params[i].y:
			return false
	return true


func _mat(mesh_instance: MeshInstance3D) -> ShaderMaterial:
	return mesh_instance.get_surface_override_material(0) as ShaderMaterial

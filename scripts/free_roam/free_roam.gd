extends Node3D
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Free roam: the streamed road-first island, driven in the world session's car from where it was
# left (WorldSession). Press R to put the car back on the nearest road.
# See todo/2026-10-19-free-roam-pivot.md.
#
# `-- --auto-drive` on the command line hands the car to an AutoDriver, which drives a route
# across the island, prints its streaming report and quits:
#   godot --headless --path . -- --auto-drive

@onready var _streamer: TerrainStreamer = $Terrain
@onready var _car: VehicleBody3D = $Car
@onready var _stats: Label = $DebugStats/Stats
@onready var _water: MeshInstance3D = $Water
@onready var _recovery: RoadRecovery = $RoadRecovery
@onready var _pause: PauseMenu = $PauseMenu
@onready var _rest_stops: RestStops = $RestStops
@onready var _rest_page: RestStopPage = $RestStopPage

# The active car's owned-car dict (WorldSession → Save.KEY_CARS), the fielding pipeline's input,
# so tuning edits persist on it.
var owned: Dictionary = {}

# How often the car's pose and condition are written to the world session, in seconds.
const SAVE_EVERY_S := 5.0
const MAP_EVERY_S := 0.25
var _save_t := SAVE_EVERY_S
var _map_t := 0.0
var _odometer_m := 0.0
var _last_xz := Vector2.ZERO


# The island's seed comes from the saved world, and must be set before the streamer builds its
# network in its own _ready (children are readied before this node).
func _enter_tree() -> void:
	var st: TerrainStreamer = get_node("Terrain")
	if st.settings == null:
		st.settings = FreeRoamSettings.new()
	if WorldSession.has_world():
		st.settings.world_seed = WorldSession.world_seed()


func _ready() -> void:
	# A dev boot straight into this scene with no world yet makes one, with the configured car.
	if not WorldSession.has_world():
		var idx := maxi(0, CarLibrary.index_of(_streamer.settings.car_id))
		WorldSession.new_world(_streamer.settings.world_seed, String(CarLibrary.all()[idx]["id"]))
	owned = WorldSession.active_car()
	# Fitted parts reach the car only through the fielding funnel's own keys (LootLibrary.fielded).
	_car.apply_owned(LootLibrary.fielded(owned))
	# The free-roam damage chain: cooling failure, overheating, and giving up at 0 HP.
	_car.damage.thermal = true
	_car.damage.repair(Config.data)
	WorldSession.restore_car_state(_car.damage)
	_streamer.focus = _car
	_rest_stops.restore(WorldSession.lit_sites(), WorldSession.last_site())
	_streamer.rest_lit_query = _rest_stops.is_lit
	_rest_stops.lit.connect(WorldSession.light)
	_rest_stops.respawn_point_changed.connect(WorldSession.set_last_site)
	_rest_stops.respawned.connect(func(_site: int, wreck: Vector3) -> void:
		$LootDirector.drop_at(wreck)
		Save.add_lifetime_stat(LifetimeStats.TIMES_GAVE_UP))
	_rest_page.car_changed.connect(_reload_car)
	_rest_page.owned = owned
	_rest_stops.opened.connect(_rest_page.open)
	$BiomeDirector.drive_time = WorldSession.drive_time()
	# The streaming readout is a dev diagnostic: shown in debug builds, toggled with H.
	$DebugStats.visible = OS.is_debug_build()
	_pause.reset_to_track_requested.connect(_recovery.reset_now)
	_pause.extra_requested.connect(_on_pause_extra)
	_pause.quitting.connect(save_world)
	tree_exiting.connect(save_world)  # before the children leave, so the car is still readable
	_rest_page.map_requested.connect(func(site: int) -> void:
		$WorldPages.show_map(_rest_page.return_from_map, site))
	var spawn: Transform3D = RoadRecovery.road_pose(_streamer, Vector2.ZERO, Vector3.FORWARD)
	var saved: Variant = WorldSession.pose_transform()
	if saved != null:
		spawn = saved
	_car.global_transform = spawn
	var t0 := Time.get_ticks_msec()
	_streamer.prefill()
	print("free roam: prefill %d ms" % (Time.get_ticks_msec() - t0))
	if saved != null:
		# Re-seat on the built ground, so a pose saved mid-air or on a since-retuned surface
		# can't drop the car through it.
		spawn.origin.y = _streamer.height_at(spawn.origin.x, spawn.origin.z) + 1.0
	_car.reset_to(spawn)
	_last_xz = Vector2(spawn.origin.x, spawn.origin.z)
	_water.position.y = _streamer.settings.water_level_m
	_pause.set_input_enabled(true)
	_streamer.warm_up_materials($ChaseCamera)
	if "--auto-drive" in OS.get_cmdline_user_args():
		start_auto_drive()


# Parts or the active car changed at a rest stop: save and reload the scene, so the car is fielded
# afresh through the full pipeline (re-staging a live body is what Car.apply_owned must never do).
# The reload is the rest stop's one acceptable load.
func _reload_car() -> void:
	save_world()
	Scenes.change_to(get_tree(), Scenes.FREE_ROAM)


# The pause menu's Map / Stats rows: the page covers the frozen game and hands back on Back.
func _on_pause_extra(label: String) -> void:
	match label:
		"Map":
			$WorldPages.show_map(_pause.return_from_extra)
		"Stats":
			$WorldPages.show_stats(_pause.return_from_extra)
		_:
			_pause.return_from_extra()


# Write the car's place, condition and the drive clock to the world session.
func save_world() -> void:
	if not _car.is_inside_tree() or not WorldSession.has_world():
		return
	WorldSession.save_pose(_car.global_transform)
	WorldSession.save_car_state(_car.damage)
	WorldSession.set_drive_time($BiomeDirector.drive_time)
	if _odometer_m >= 1.0:
		Save.add_lifetime_stat(LifetimeStats.DISTANCE_DRIVEN_M, int(_odometer_m))
		_odometer_m -= floorf(_odometer_m)


func _physics_process(delta: float) -> void:
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	var step := p.distance_to(_last_xz)
	if step < 30.0:  # a teleport is not driving
		_odometer_m += step
	_last_xz = p
	_map_t -= delta
	if _map_t <= 0.0:
		_map_t = MAP_EVERY_S
		WorldSession.mark_driven(p.x, p.y)
		WorldSession.reach_ring(_streamer.terrain.ring_index(p.x, p.y))
	_save_t -= delta
	if _save_t <= 0.0:
		_save_t = SAVE_EVERY_S
		save_world()


func start_auto_drive() -> AutoDriver:
	var driver := AutoDriver.new()
	driver.name = "AutoDriver"
	if "--auto-drive" in OS.get_cmdline_user_args():
		driver.log_every_ticks = 300
	add_child(driver)
	driver.start(_car, _streamer)
	driver.finished.connect(func(r: Dictionary) -> void:
		print("auto drive: ", r)
		if "--auto-drive" in OS.get_cmdline_user_args():
			get_tree().quit())
	return driver


func _process(_delta: float) -> void:
	if not $DebugStats.visible:
		_place_water()
		return
	_place_water()
	_update_stats()


func _place_water() -> void:
	_water.position.x = snappedf(_car.global_position.x, 64.0)
	_water.position.z = snappedf(_car.global_position.z, 64.0)


func _update_stats() -> void:
	var counts := _streamer.chunk_counts()
	var s := _streamer
	_stats.text = "%d km/h\n" % roundi(_car.linear_velocity.length() * 3.6) \
		+ "terrain  %.2f ms this frame (budget %.2f)\n" % [s.stat_used_us / 1000.0, s.settings.budget_us / 1000.0] \
		+ "worst    %.2f ms   over budget %d / %d frames   spikes %d\n" % [s.stat_worst_us / 1000.0, s.stat_overruns, s.stat_frames, s.stat_spikes] \
		+ "queue    %d jobs\n" % s.queued() \
		+ "chunks   %d near  %d far  %d collision\n" % [counts.x, counts.y, counts.z] \
		+ "sample   %.1f µs\n" % s.stat_us_per_sample \
		+ "network  %d nodes  %d links  %.0f km (%d ms)\n" % [
			s.network.nodes.size(), s.network.edges.size(), s.network.total_length_m / 1000.0, s.stat_build_ms] \
		+ "R = back to road"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_recovery.reset_now()
	elif OS.is_debug_build() and event.is_action_pressed("toggle_debug_arrows"):
		$DebugStats.visible = not $DebugStats.visible


func _exit_tree() -> void:
	var s := _streamer
	print("free roam: %d frames, %d over budget, worst %.2f ms, %.1f us/sample, %d jobs queued" % [
		s.stat_frames, s.stat_overruns, s.stat_worst_us / 1000.0, s.stat_us_per_sample, s.queued()])
	print("free roam: unit costs (us) ", s._est)

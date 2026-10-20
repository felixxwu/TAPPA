extends Node3D
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Free-roam prototype: boots straight onto the streamed road-first island with the first
# library car. Press R to put the car back on the nearest road.
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

# The car as an owned-car dict (the fielding pipeline's input), so tuning has something to edit.
# Transient until the world session keeps a garage (stage 6).
var owned: Dictionary = {}


func _ready() -> void:
	var idx := maxi(0, CarLibrary.index_of(_streamer.settings.car_id))
	owned = {"model_id": String(CarLibrary.all()[idx]["id"]), "instance_id": -1, "tuning": {}}
	_car.apply_owned(owned)
	# The free-roam damage chain: cooling failure, overheating, and giving up at 0 HP.
	_car.damage.thermal = true
	_car.damage.repair(Config.data)
	_streamer.focus = _car
	_streamer.rest_lit_query = _rest_stops.is_lit
	_rest_page.owned = owned
	_rest_stops.opened.connect(_rest_page.open)
	# The streaming readout is a dev diagnostic: shown in debug builds, toggled with H.
	$DebugStats.visible = OS.is_debug_build()
	_pause.reset_to_track_requested.connect(_recovery.reset_now)
	var spawn := RoadRecovery.road_pose(_streamer, Vector2.ZERO, Vector3.FORWARD)
	_car.global_transform = spawn
	var t0 := Time.get_ticks_msec()
	_streamer.prefill()
	print("free roam: prefill %d ms" % (Time.get_ticks_msec() - t0))
	_car.reset_to(spawn)
	_water.position.y = _streamer.settings.water_level_m
	_pause.set_input_enabled(true)
	_streamer.warm_up_materials($ChaseCamera)
	if "--auto-drive" in OS.get_cmdline_user_args():
		start_auto_drive()


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

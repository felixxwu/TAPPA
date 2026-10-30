extends Node3D
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam.gd — extend in the same change.
# Free roam: the streamed road-first island, driven in the world session's car from where it was
# left (WorldSession). Press R to put the car back on the nearest road.
# See todo/2026-10-19-free-roam-pivot.md.
#
# `-- --auto-drive` on the command line hands the car to an AutoDriver, which drives a route
# across the island, prints its streaming report and quits (Benchmark.active does the same
# drive with the benchmark's sampling instead):
#   godot --headless --path . -- --auto-drive

@onready var _streamer: TerrainStreamer = $Terrain
@onready var _car: VehicleBody3D = $Car
@onready var _stats: Label = $DebugStats/Stats
@onready var _water: MeshInstance3D = $Water
@onready var _recovery: RoadRecovery = $RoadRecovery
@onready var _pause: PauseMenu = $PauseMenu
@onready var _rest_stops: RestStops = $RestStops
@onready var _rest_page: RestStopPage = $RestStopPage
@onready var _minimap: MiniMap = $MiniMapLayer/MiniMap

# The active car's owned-car dict (WorldSession → Save.KEY_CARS), the fielding pipeline's input,
# so tuning edits persist on it.
var owned: Dictionary = {}

# Debris flung from spinning driven wheels: grass blades off the road, gravel clods on it. The
# surface under each wheel comes from the streamer's surface_at, the same query the tyres' grip
# reads. Made here exactly as world.gd makes the stage's (features/wheel-dust.md).
var wheel_particles: WheelParticles
var dust_puffs: DustPuffs
var region_banner: RegionBanner

# How often the car's pose and condition are written to the world session, in seconds.
var _save_t := 0.0
var _map_t := 0.0
var _odometer_m := 0.0
var _last_xz := Vector2.ZERO
var _last_pose := Transform3D.IDENTITY  # the car's pose as of the last physics tick (see save_world)
var _has_pose := false
# The world this scene was built on (WorldSession.generation). Once the profile's world is replaced
# (a new world, a cloud download, the benchmark ending) this scene writes nothing more.
var _generation := -1
var _conflict_due := false  # a cloud sync conflict is waiting to be put to the player


# The island's seed comes from the saved world, and must be set before the streamer builds its
# network in its own _ready (children are readied before this node).
func _enter_tree() -> void:
	# A phone browser draws foliage a shorter way out (the low-end target), set before any planting.
	var cfg: GameConfig = Config.data
	cfg.tree_render_distance_m = cfg.tree_render_distance_for(Platform.is_web(), Platform.is_touch())
	var st: TerrainStreamer = get_node("Terrain")
	if st.settings == null:
		st.settings = cfg.free_roam.duplicate()
	_save_t = st.settings.save_every_s
	if WorldSession.has_world():
		st.settings.world_seed = WorldSession.world_seed()
	# Straight after the streamer builds its sites, before the rest stops and loot read their ids.
	st.ready.connect(func() -> void: WorldSession.check_sites(WorldSession.sites_fingerprint(st.sites)),
		CONNECT_ONE_SHOT)
	if Benchmark.active:
		st.settings = st.settings.duplicate()
		st.settings.straight_road_m = Benchmark.ROAD_M


func _ready() -> void:
	for vp in _measured_viewports():
		RenderingServer.viewport_set_measure_render_time(vp, true)
	# A dev boot straight into this scene with no world yet makes one, with the configured car.
	if not WorldSession.has_world():
		var idx := maxi(0, CarLibrary.index_of(_streamer.settings.car_id))
		WorldSession.new_world(_streamer.settings.world_seed, String(CarLibrary.all()[idx]["id"]))
	_generation = WorldSession.generation
	WorldSession.adopt_old_stash()
	owned = WorldSession.active_car()
	# Fitted parts reach the car only through the fielding funnel's own keys (LootRules.fielded).
	_car.apply_owned(LootRules.fielded(owned))
	($CameraManager as CameraManager).refresh_bonnet_offset()
	# The free-roam damage chain: cooling failure, overheating, and giving up at 0 HP.
	_car.damage.thermal = true
	_car.damage.invulnerable = Benchmark.active
	_car.damage.repair(Config.data)
	WorldSession.restore_car_state(_car.damage)
	# Quit while wrecked: come back as the wreck page's Respawn would, at the last rest stop.
	var respawn_now: bool = _car.damage.hp <= 0.0
	if respawn_now:
		_car.damage.repair(Config.data)
		_car.damage.engine_temp = 0.0
		Save.add_lifetime_stat(LifetimeStats.TIMES_GAVE_UP)  # the Respawn that quitting skipped
	_streamer.focus = _car
	wheel_particles = WheelParticles.new()
	wheel_particles.name = "WheelParticles"
	add_child(wheel_particles)
	wheel_particles.setup(_car)
	$BiomeDirector.wheel_particles = wheel_particles  # re-seats the region's blade per ring
	# Opaque blocky dust clouds behind the rear wheels on gravel (features/dust-puffs.md).
	dust_puffs = DustPuffs.new()
	dust_puffs.name = "DustPuffs"
	add_child(dust_puffs)
	dust_puffs.setup(_car)
	$BiomeDirector.dust_puffs = dust_puffs  # re-seats the region's dust colour per ring
	# The region's name across the screen the first time the car drives into each biome ring.
	region_banner = RegionBanner.new()
	region_banner.name = "RegionBanner"
	region_banner.checkpoint_banner = $CheckpointBanner
	add_child(region_banner)
	# Smoke from the bonnet when a damaged (overheating) engine misfires, and backfire flames
	# from the exhausts on a limiter bang or under nitrous — the stage's own effects, as in world.gd.
	var smoke := EngineSmoke.new()
	smoke.name = "EngineSmoke"
	add_child(smoke)
	smoke.setup(_car)
	# Gravel ruts behind the wheels on the road. Free roam has no single centreline, so the marks
	# run UNGATED: the streamer's surface answer (road weight) alone decides where they're laid.
	var marks := TireMarks.new()
	marks.name = "TireMarks"
	add_child(marks)
	marks.setup(null, _car, _streamer, _streamer.settings.road_half_width_m)
	var flames := ExhaustFlames.new()
	flames.name = "ExhaustFlames"
	add_child(flames)
	flames.setup(_car)
	var lamps := CarLamps.new()
	lamps.name = "CarLamps"
	add_child(lamps)
	lamps.setup(_car)
	_rest_stops.restore(WorldSession.lit_sites(), WorldSession.last_site())
	_streamer.rest_lit_query = _rest_stops.is_lit
	_rest_stops.lit.connect($LootDirector.site_lit)
	for site: int in _rest_stops.lit_sites:
		$LootDirector.site_lit(site)  # a saved world's stock follows what is lit
	_rest_stops.lit.connect(WorldSession.light)
	_rest_stops.respawn_point_changed.connect(WorldSession.set_last_site)
	_rest_stops.respawned.connect(func(_site: int, _wreck: Vector3) -> void:
		Save.add_lifetime_stat(LifetimeStats.TIMES_GAVE_UP))
	_rest_stops.car_teleported_to.connect($LootDirector.car_teleported)
	_rest_stops.respawned.connect($LootDirector.respawned)
	$LootDirector.said.connect(_minimap.toast)
	_recovery.reset_done.connect($LootDirector.car_teleported)
	_recovery.reset_done.connect(_rest_stops.car_teleported)
	_recovery.reset_done.connect(_on_car_teleported)
	_rest_stops.car_teleported_to.connect(_on_car_teleported)
	_rest_stops.car_teleported_to.connect($TireMarks.break_ribbons)
	_recovery.reset_done.connect($TireMarks.break_ribbons)
	_rest_page.car_changed.connect(_reload_car)
	_rest_page.tuned.connect($BiomeDirector.reapply)
	_rest_page.owned = owned
	_rest_stops.opened.connect(_rest_page.open)
	_rest_stops.wrecked.connect(_rest_page.open_wrecked)
	$BiomeDirector.drive_time = WorldSession.drive_time()
	# The streaming readout is a dev diagnostic: hidden until P toggles it, in debug builds only.
	$DebugStats.visible = false
	_pause.reset_to_track_requested.connect(_recovery.reset_now)
	_pause.extra_requested.connect(_on_pause_extra)
	_pause.quitting.connect(save_world)
	# Every other exit (a scene change, the window closing). The children leave the tree before this
	# node's tree_exiting fires, so the car's transform is unreadable by then: save_world falls back
	# on the pose cached each physics tick.
	tree_exiting.connect(save_world)
	Save.flushing.connect(save_world)  # window close, app pause, browser tab hidden
	Cloud.profile_replaced.connect(_on_profile_replaced)
	Cloud.conflict_detected.connect(_on_conflict_detected)
	_conflict_due = ConflictPrompt.is_blocked()  # one raised before this scene loaded, or left for Later
	_rest_page.map_requested.connect(func(site: int) -> void:
		$WorldPages.show_map(_rest_page.return_from_map, site))
	_minimap.open_requested.connect(open_full_map)
	var spawn: Transform3D = _rest_stops.pose_at(_rest_stops.last_site if respawn_now else 0)  # facing down the road, the cabin behind
	var saved: Variant = null if respawn_now else WorldSession.pose_transform()
	if saved != null:
		spawn = saved
	_car.global_transform = spawn
	var t0 := Time.get_ticks_msec()
	if Platform.is_headless():
		_streamer.prefill()
	else:
		var cover := _loading_cover()
		cover.set_title("Building the island…")
		_car.freeze = true
		_car.controls_locked = true
		_rest_stops.input_enabled = false
		await _streamer.prefill_async()
		_car.freeze = false
	print("free roam: prefill %d ms" % (Time.get_ticks_msec() - t0))
	if saved != null:
		# Re-seat on the built ground, so a pose saved mid-air or on a since-retuned surface
		# can't drop the car through it.
		spawn.origin.y = _streamer.height_at(spawn.origin.x, spawn.origin.z) + 1.0
	_car.reset_to(spawn)
	_last_xz = Vector2(spawn.origin.x, spawn.origin.z)
	_water.position.y = _streamer.settings.water_level_m
	if Platform.is_headless():
		_hand_over()  # nothing renders, so there is nothing to compile
	else:
		_warm_up()


# Compile every first-use shader before the player gets control, as the stage's load did
# (world.gd._warm_shaders_behind_cover): the effects, the ground of every ring, one of every plant,
# rock and marker, and a look round the loaded ground, all behind a loading cover with the car held.
func _warm_up() -> void:
	_car.controls_locked = true
	_rest_stops.input_enabled = false
	var cover := _loading_cover()
	cover.set_title("Warming shaders…")
	var cam := get_viewport().get_camera_3d()
	# Every node with the warm_up()/clear_warm_up() pair (debris, tyre marks, flames, crowds, …).
	var warmers := find_children("*", "Node", true, false).filter(
		func(n: Node) -> bool: return n.has_method("warm_up") and n.has_method("clear_warm_up"))
	for n in warmers:
		n.warm_up(WorldRuntime.warm_up_point(cam, _car.global_position))
	await _streamer.warm_up_materials(cam)
	for n in warmers:
		if is_instance_valid(n):
			n.clear_warm_up()
	await _streamer.warm_up_spawns(cam)
	await _look_around()
	cover.finish()
	_car.controls_locked = false
	_hand_over()


func _loading_cover() -> LoadingScreen:
	var cover := get_tree().get_first_node_in_group("loading_screen") as LoadingScreen
	if cover == null:
		cover = LoadingScreen.new()
		add_child(cover)
	return cover


# A throwaway camera turns full circle above the car, then looks down from high up, so everything
# loaded around the spawn (trees, water, barriers, cabins, crowds) draws once.
func _look_around() -> void:
	var cam := Camera3D.new()
	cam.far = 400.0
	add_child(cam)
	cam.make_current()
	var c := _car.global_position
	for k in 9:
		var eye := c + Vector3(0.0, 3.0, 0.0)
		var dir := Vector3(sin(k * TAU / 8.0), -0.1, cos(k * TAU / 8.0)) if k < 8 else Vector3(0.0, -1.0, 0.01)
		if k == 8:
			eye = c + Vector3(0.0, 120.0, 0.0)
		cam.look_at_from_position(eye, eye + dir, Vector3.UP)
		await get_tree().process_frame
		await get_tree().process_frame
	cam.queue_free()
	$CameraManager.activate_current()


# Boot is done: the pause menu, then the auto-driver or the title menu if either is due.
func _hand_over() -> void:
	_rest_stops.input_enabled = true
	_pause.set_input_enabled(true)
	if Benchmark.active:
		start_benchmark()
	elif "--auto-drive" in OS.get_cmdline_user_args():
		start_auto_drive()
	elif WorldSession.title_pending:
		WorldSession.title_pending = false
		show_title()


# The title menu over the paused world, as the game boots, with a camera circling the car. Continue
# just closes it; a new world reloads the scene (and save_world, seeing the world replaced, writes
# nothing into it on the way out).
func show_title() -> TitleScreen:
	get_tree().paused = true
	_pause.set_input_enabled(false)
	var orbit := _start_title_orbit()
	var layer := CanvasLayer.new()
	layer.name = "TitleLayer"
	layer.layer = 10
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var title := TitleScreen.new()
	title.close = func() -> void:
		layer.queue_free()
		orbit.queue_free()
		$CameraManager.activate_current()
		$MobileControls.set_scheme(int(Save.get_setting(MobileControls.SETTING_KEY, MobileControls.DEFAULT_SCHEME)))
		get_tree().paused = false
		_pause.set_input_enabled(true)
	layer.add_child(title)
	add_child(layer)
	return title


# A camera circling the car at the start line's orbit radius and height, kept above the ground
# all the way round. Its tween runs while the tree is paused behind the menu.
func _start_title_orbit() -> Camera3D:
	var cfg: GameConfig = Config.data
	var cam := Camera3D.new()
	cam.name = "TitleOrbitCamera"
	add_child(cam)
	cam.make_current()
	var centre := _car.global_position
	var place := func(angle: float) -> void:
		var p := centre + Vector3(cos(angle), 0.0, sin(angle)) * cfg.start_orbit_radius
		p.y = maxf(centre.y, _streamer.height_at(p.x, p.z)) + cfg.start_orbit_height
		cam.look_at_from_position(p, centre)
	place.call(0.0)
	var tween := cam.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS).set_loops()
	tween.tween_method(place, 0.0, TAU, TAU / maxf(cfg.start_orbit_speed, 0.01))
	return cam


# Parts or the active car changed at a rest stop: save and reload the scene, so the car is fielded
# afresh through the full pipeline (re-staging a live body is what Car.apply_owned must never do).
# The reload is the rest stop's one acceptable load.
func _reload_car() -> void:
	save_world()
	Scenes.change_to(get_tree(), Scenes.FREE_ROAM)


# A cloud download replaced the save: boot again onto it (save_world leaves the new world alone).
func _on_profile_replaced() -> void:
	WorldSession.fresh = false
	Scenes.change_to(get_tree(), Scenes.TITLE)


# A sync conflict found in the background (at boot, or on coming back to the app) is put to the
# player as soon as nothing else is on screen: not under the title, a page or another modal.
func _on_conflict_detected(_summary: Dictionary) -> void:
	_conflict_due = true


func _offer_conflict() -> void:
	if get_tree().paused or not _pause.is_armed() or ConfirmPopup.any_open(get_tree()) != null:
		return
	_conflict_due = false
	get_tree().paused = true
	_pause.set_input_enabled(false)
	var done := func() -> void:
		get_tree().paused = false
		_pause.set_input_enabled(true)
	if ConflictPrompt.open(_pause, done) == null:
		done.call()


# The pause menu's Map / Stats rows: the page covers the frozen game and hands back on Back.
func _on_pause_extra(label: String) -> void:
	match label:
		"Map":
			$WorldPages.show_map(func() -> void:
				if $WorldPages.travelled:  # quick-travelled: straight back to driving, not the menu
					_pause.set_input_enabled(true)
					_pause.resume()
				else:
					_pause.return_from_extra())
		"Stats":
			$WorldPages.show_stats(_pause.return_from_extra)
		_:
			_pause.return_from_extra()


# The minimap was tapped (or M / gamepad Back): the whole map over the frozen game, and closing it
# goes straight back to driving rather than to the pause menu.
func open_full_map() -> void:
	if get_tree().paused or $WorldPages.is_open() or _rest_stops.is_wrecked or not _pause.is_armed():
		return
	get_tree().paused = true
	_pause.set_input_enabled(false)  # Esc / B belong to the map page while it's up
	$WorldPages.show_map(_close_full_map)


func _close_full_map() -> void:
	get_tree().paused = false
	_pause.set_input_enabled(true)


# Write the car's place, condition and the drive clock to the world session, and to disk (not the
# cloud: none of it is progress). The pose is read live while the car is in the tree, else from the
# per-tick cache (on exit paths).
func save_world() -> void:
	if not WorldSession.has_world() or WorldSession.generation != _generation:
		return
	if _car.is_inside_tree():
		_last_pose = _car.global_transform
		_has_pose = true
	if _has_pose:
		WorldSession.save_pose(_last_pose)
	# After a swap at a rest stop this car is no longer the active one; its damage isn't the new car's.
	if int(owned.get("instance_id", -1)) == int(WorldSession.active_car().get("instance_id", -2)):
		WorldSession.save_car_state(_car.damage)
	WorldSession.set_drive_time($BiomeDirector.drive_time)
	if _odometer_m >= 1.0:
		Save.add_lifetime_stat(LifetimeStats.DISTANCE_DRIVEN_M, int(_odometer_m), false)
		_odometer_m -= floorf(_odometer_m)
	Save.save(false)


# Dev shortcut: every rest stop lit, every biome reached and every road on the map, so travel can go anywhere.
func unlock_map() -> void:
	_rest_stops.light_all()
	WorldSession.reach_ring(_streamer.settings.ring_count - 1)
	var net := _streamer.network
	for si in net.seg_ax.size():
		WorldSession.mark_driven((net.seg_ax[si] + net.seg_bx[si]) * 0.5, (net.seg_ay[si] + net.seg_by[si]) * 0.5)


func _on_car_teleported(p: Vector2) -> void:
	_last_xz = p


func _physics_process(delta: float) -> void:
	if WorldSession.generation != _generation:
		return
	_last_pose = _car.global_transform
	_has_pose = true
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	var step := p.distance_to(_last_xz)
	if step < RoadSites.TELEPORT_M:
		_odometer_m += step
	_last_xz = p
	_map_t -= delta
	if _map_t <= 0.0:
		_map_t = _streamer.settings.map_every_s
		WorldSession.mark_driven(p.x, p.y)
		var ring := _streamer.terrain.ring_index(p.x, p.y)
		if WorldSession.reach_ring(ring):
			region_banner.announce(RegionBanner.name_for(_streamer.settings, ring))
		if MiniMap.mark_seen_near(_streamer.sites, p, Config.data.minimap_seen_radius_m) > 0:
			_minimap.refresh_markers()
	_save_t -= delta
	if _save_t <= 0.0:
		_save_t = _streamer.settings.save_every_s
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


# The benchmark (features/benchmark.md): the auto-driver drives, the runner samples every frame.
func start_benchmark() -> BenchmarkRunner:
	WorldSession.title_pending = false
	$DebugStats.visible = true
	$CameraManager.set_mode(CameraManager.Mode.CHASE)
	var runner := BenchmarkRunner.new()
	runner.name = "BenchmarkRunner"
	add_child(runner)
	runner.setup(_car, start_auto_drive(), get_node_or_null("PostProcess/View") as Viewport, _streamer)
	return runner


func _process(_delta: float) -> void:
	if _conflict_due:
		_offer_conflict()
	_track_spare_time()
	_place_water()
	if $DebugStats.visible:
		_update_stats()


# Last frame's cpu / gpu load, with terrain's own share taken out of the cpu side, gives the
# time terrain could have had; smoothed so one odd frame doesn't swing the streaming budget.
func _track_spare_time() -> void:
	var load_ms := _frame_load_ms()
	var cpu := maxf(0.0, load_ms.x - _streamer.stat_used_us / 1000.0)
	var spare := maxf(0.0, _frame_budget_ms() - maxf(cpu, load_ms.y)) * 1000.0
	_streamer.spare_us = lerpf(_streamer.spare_us, spare, 0.1)


func _place_water() -> void:
	_water.position.x = snappedf(_car.global_position.x, 64.0)
	_water.position.z = snappedf(_car.global_position.z, 64.0)


func _update_stats() -> void:
	var counts := _streamer.chunk_counts()
	var s := _streamer
	_stats.text = "%d km/h\n" % roundi(_car.linear_velocity.length() * 3.6) \
		+ "terrain  %.2f ms this frame (budget %.2f)\n" % [s.stat_used_us / 1000.0, s.budget_us(get_process_delta_time()) / 1000.0] \
		+ "         avg %.2f ms/frame (%d%% of the frame)   total %.1f s\n" % [
			s.stat_total_us / 1000.0 / maxi(1, s.stat_frames), roundi(s.stat_total_us / 1000.0 / maxi(1, s.stat_frames) / _frame_budget_ms() * 100.0), s.stat_total_us / 1e6] \
		+ "worst    %.2f ms   over budget %d / %d frames   spikes %d   rushes %d\n" % [s.stat_worst_us / 1000.0, s.stat_overruns, s.stat_frames, s.stat_spikes, s.stat_rushes] \
		+ "queue    %d jobs\n" % s.queued() \
		+ "chunks   %d mid  %d far  %d collision tiles\n" % [counts.x, counts.y, counts.z] \
		+ "sample   %.1f µs\n" % s.stat_us_per_sample \
		+ "network  %d nodes  %d links  %.0f km (%d ms)\n" % [
			s.network.node_x.size(), s.network.edges.size(), s.network.total_length_m / 1000.0, s.stat_build_ms] \
		+ _headroom_line() + "\n" \
		+ "R = back to road"


# The frame's budget is the frame cap, else the display's refresh rate (what vsync paces to).
func _frame_budget_ms() -> float:
	var fps := float(Engine.max_fps)
	if fps <= 0.0:
		fps = DisplayServer.screen_get_refresh_rate()
	return 1000.0 / (fps if fps > 0.0 else 60.0)


# Rough share of the frame budget still free. The CPU side is script + physics + the render
# thread's submit; the GPU works in parallel, so whichever side is busier sets the frame.
static func frame_headroom(budget_ms: float, cpu_ms: float, gpu_ms: float) -> float:
	return 1.0 - maxf(cpu_ms, gpu_ms) / budget_ms


# (cpu, gpu) milliseconds of the last frame.
func _frame_load_ms() -> Vector2:
	var cpu := (Performance.get_monitor(Performance.TIME_PROCESS) \
		+ Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	var gpu := 0.0
	for vp in _measured_viewports():
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return Vector2(cpu, gpu)


func _headroom_line() -> String:
	var load_ms := _frame_load_ms()
	var cpu := load_ms.x
	var gpu := load_ms.y
	var budget := _frame_budget_ms()
	return "frame    %d%% free of %.1f ms   (cpu %.1f  gpu %.1f%s)" % [
		roundi(frame_headroom(budget, cpu, gpu) * 100.0), budget, cpu, gpu,
		"" if gpu > 0.0 else " n/a"]


# The island renders in the post-process SubViewport; the root draws the HUD over it.
func _measured_viewports() -> Array[RID]:
	var out: Array[RID] = [get_viewport().get_viewport_rid()]
	var view := get_node_or_null("PostProcess/View") as Viewport
	if view != null:
		out.append(view.get_viewport_rid())
	return out


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset_to_road") and not event.is_echo():
		_recovery.reset_now()
	elif event.is_action_pressed("toggle_perf_overlay") and OS.is_debug_build():
		$DebugStats.visible = not $DebugStats.visible


func _exit_tree() -> void:
	var s := _streamer
	print("free roam: %d frames, %d over budget, worst %.2f ms, %.1f us/sample, %d jobs queued" % [
		s.stat_frames, s.stat_overruns, s.stat_worst_us / 1000.0, s.stat_us_per_sample, s.queued()])
	print("free roam: unit costs (us) ", s._est)

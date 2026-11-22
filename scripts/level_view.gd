class_name LevelView
extends Node3D
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_level_view.gd — extend in the same change.
# A level saved by tools/level_editor_lab.html, built as drivable ground: the lab's terrain and road
# rebuilt at a finer grid with collision, its trees as the game's 6-card stars, and the car parked on
# the road's first node. THIS IS THE GAME WORLD (Scenes.WORLD, the default mode): the Hafren level,
# GameConfig.level_path. The old procedural island (free_roam.tscn) is legacy reference code.
# Trees come from the bake (LevelTrees): tiles near the camera, culled by what the bake saw from this stretch of road.

const GROUND_SHADER := preload("res://shaders/level_ground.gdshader")

signal loaded

@export var level_path := ""
@export var material: Material  # the ground shader (level_ground.gdshader)

var level: Dictionary
var data := LevelData.new()
var _bake: LevelBake
var _spawn_nodes: Array[Vector2] = []
var _save_path := ""
var _streamer: LevelStreamer
var _trees: LevelTrees
var _spectators: LevelSpectators
var garage: MenuPage
static var _next_pose: Variant = null  # where the car stands after a car-change reload
static var owned: Dictionary = {}  # the level's car with every shop part unlocked, kept across reloads
const SAVED_CAR_KEY := "level_car"
const SAVED_POSE_KEY := "level_pose"
const POSE_SAVE_SEC := 5.0
var shop: RestStopPage
var _car: VehicleBody3D
var _particles: WeatherField
var _recovery: RoadRecovery
var _dust: DustPuffs
var _dust_base: Color  # the gravel's dust colour outside the snow
var _pause: Node
var map: LevelMap
var off_road_label: Label
var applied_fps_caps: Array[int] = []
var _driving := false  # true once loaded, so a half-built level never overwrites the saved spot


func _ready() -> void:
	var path := level_path if not level_path.is_empty() else Config.data.level_path
	var t_parse := Time.get_ticks_msec()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	print("level view: parse %d ms" % (Time.get_ticks_msec() - t_parse))
	if not parsed is Dictionary:
		push_error("LevelView: couldn't read %s" % path)
		# Say so on the loading cover rather than leave it spinning forever (an export that left
		# tools/levels out hung here on Android with no message).
		var cover := get_tree().get_first_node_in_group("loading_screen") as LoadingScreen
		if cover == null and not Platform.is_headless():
			cover = LoadingScreen.new()
			add_child(cover)
		if cover != null:
			cover.set_title("The level file is missing from this build.")
		return
	WorldRuntime.apply_fps_cap(applied_fps_caps, WorldRuntime.loading_cap(Platform.is_touch()), Platform.is_headless())
	_save_path = path
	var t0 := Time.get_ticks_msec()
	await load_level(parsed)
	parsed = null  # the raw save is large and this function waits below
	if _bake == null:
		return
	print("level view: %s built in %d ms" % [path, Time.get_ticks_msec() - t0])
	var env := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env != null:
		env.environment.fog_depth_end = Config.data.level_tree_draw_m
	var car := get_parent().get_node_or_null("Car") as VehicleBody3D
	if car == null:
		return
	if not car.is_node_ready():
		await car.ready  # this node sits before the car, so builds first and fields the car once it exists
	if owned.is_empty():
		restore_saved_car()
	if String(owned.get("model_id", "")) != Config.data.level_car_id:
		owned = {"model_id": Config.data.level_car_id, "tuning": {}, "parts": LootRules.parts_for({"model_id": Config.data.level_car_id}).map(
			func(p: Dictionary) -> Dictionary: return p.merged({"on": false}))}
	Save.set_setting(SAVED_CAR_KEY, owned.duplicate(true))
	car.apply_owned(LootRules.fielded(owned))
	get_parent().get_node("CameraManager").refresh_bonnet_offset()
	car.reset_to(_next_pose if _next_pose != null else saved_pose(Save.get_setting(SAVED_POSE_KEY), _save_path, spawn_pose()))
	_next_pose = null
	_pause = get_parent().get_node_or_null("PauseMenu")
	# The pause menu offers Photo Mode here too; without a host its pick hid the menu and left the
	# player stuck on a frozen frame with no controls and no way back.
	if _pause != null:
		PhotoModeHost.attach.call_deferred(get_parent())  # deferred: the scene is still adding its children
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	off_road_label = UITheme.label("")  # styled as free roam's prompt box (MiniMap.prompt_label)
	off_road_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(4)))
	off_road_label.visible = false
	layer.add_child(off_road_label)
	map = LevelMap.new()
	map.view = self
	map.process_mode = Node.PROCESS_MODE_DISABLED  # painting starts now, but M stays dead until the level has loaded
	layer.add_child(map)
	map.closed.connect(_on_map_closed)
	if _streamer != null:
		_streamer.focus = car
		var t_fill := Time.get_ticks_msec()
		await _streamer.prefill_async()
		print("level view: prefill %d ms" % (Time.get_ticks_msec() - t_fill))
	await get_tree().process_frame  # the parent is still adding its children
	var marks := _add_effects(car)
	_recovery = RoadRecovery.new()
	_recovery.name = "RoadRecovery"
	_recovery.car = car
	_recovery.streamer = self
	get_parent().add_child(_recovery)
	_recovery.reset_done.connect(func(_p: Vector2) -> void: marks.break_ribbons())
	if _pause != null:
		_pause.reset_to_track_requested.connect(_recovery.reset_now)
		_pause.extra_requested.connect(_on_extra)
	if not Platform.is_headless():  # nothing renders, so there is nothing to compile
		var t_warm := Time.get_ticks_msec()
		await _warm_up(car)
		print("level view: warm-up %d ms" % (Time.get_ticks_msec() - t_warm))
	WorldRuntime.apply_fps_cap(applied_fps_caps, FpsSetting.resolve(), Platform.is_headless())
	if _pause != null:
		_pause.set_input_enabled(true)  # the menu stays inert until its world says it has finished loading
	map.process_mode = Node.PROCESS_MODE_ALWAYS
	_driving = true
	Save.flushing.connect(save_pose)  # window close, app pause, browser tab hidden
	var timer := Timer.new()
	timer.wait_time = POSE_SAVE_SEC  # also on a timer: stopping the game from the editor sends no close
	timer.timeout.connect(save_pose)
	add_child(timer)
	timer.start()
	loaded.emit()


func _unhandled_input(event: InputEvent) -> void:
	if _recovery != null and _pause != null and event.is_action_pressed("reset_to_road") and not event.is_echo() and _pause.is_armed():
		_recovery.reset_now()


func _on_extra(label: String) -> void:
	match label:
		"Map": map.open_over_pause()
		"Shop": open_shop()
		"Garage": open_garage()
		"Repair":
			_car.damage.repair()
			_pause.return_from_extra()


# The map opened from the pause menu closed: Back returns to the menu; a teleport goes straight back to driving.
func _on_map_closed(teleported: bool, over_pause: bool) -> void:
	if not over_pause or _pause == null:
		return
	if teleported:
		_pause.set_input_enabled(true)
	else:
		_pause.return_from_extra()


# The pause menu's Garage: a card per catalogue car, stock; picking one reloads the level with it.
func open_garage() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	garage = CardUI.card_page(layer, {"title": "Garage", "dim": true})
	var entries: Array = []
	var selected := 0
	for i in CarLibrary.all().size():
		var id := String(CarLibrary.all()[i]["id"])
		var stats := LootRules.fitted_stats({"model_id": id})
		var driving := id == Config.data.level_car_id
		if driving:
			selected = i
		entries.append({"title": String(CarLibrary.all()[i].get("name", id)), "car": i,
			"desc": CardUI.stats_line(stats["hp"], stats["mass"], stats["drive_mode"]),
			"extra": "Driving" if driving else "", "action": _drive.bind(id)})
	var cards := CardUI.card_list(garage, entries, [], selected)
	garage.add_action(UITheme.row_button("< Back", _close_garage))
	MenuNav.attach(garage, {first = cards, on_back = _close_garage})


# The pause menu's Shop: free roam's rest-stop shop with every part free and unlocked; a change reloads the level.
func open_shop() -> void:
	shop = RestStopPage.new()
	shop.free = true
	shop.owned = owned
	add_child(shop)
	shop.car_changed.connect(func() -> void: _reload("Applying parts to your car"))
	shop.closed.connect(_close_shop)
	shop.open_shop()


func _close_shop() -> void:
	shop.queue_free()
	shop = null
	if _next_pose == null:  # set when the shop's change is reloading the level
		_pause.return_from_extra()


func _close_garage() -> void:
	CardUI.park_previews(garage)
	garage.get_parent().queue_free()
	garage = null
	_pause.return_from_extra()


# The car and parts last driven here, from a previous launch; a car since dropped from the roster is ignored.
static func restore_saved_car() -> void:
	var saved: Variant = Save.get_setting(SAVED_CAR_KEY, {})
	if saved is Dictionary and CarLibrary.index_of(String(saved.get("model_id", ""))) >= 0:
		owned = saved.duplicate(true)
		Config.data.level_car_id = String(owned["model_id"])


# Remembers where the car stands on this level, so the next launch starts there.
func save_pose() -> void:
	if _driving and is_instance_valid(_car):
		var p := _car.position  # local: on leaving the level the car may already be out of the tree
		Save.set_setting(SAVED_POSE_KEY, {"level": _save_path, "x": p.x, "z": p.z, "yaw": _car.rotation.y})
		if map != null:
			map.save_discovery()


# The saved spot as an upright pose just above the ground, or `fallback` if it was saved on another level.
func saved_pose(saved: Variant, level: String, fallback: Transform3D) -> Transform3D:
	if not saved is Dictionary or saved.get("level") != level:
		return fallback
	var x := float(saved.get("x", 0.0))
	var z := float(saved.get("z", 0.0))
	return Transform3D(Basis(Vector3.UP, float(saved.get("yaw", 0.0))), Vector3(x, height_at(x, z) + 1.0, z))


func _drive(id: String) -> void:
	Config.data.level_car_id = id
	_reload("Changing cars")


func _reload(title: String) -> void:
	_next_pose = _car.global_transform
	Scenes.change_to(get_tree(), Scenes.WORLD, title)


# Free roam's driving effects, set up the way free_roam.gd does; returns the tyre marks.
func _add_effects(car: VehicleBody3D) -> TireMarks:
	var look := RegionLibrary.look_of("home")
	var wheels := WheelParticles.new()
	wheels.name = "WheelParticles"
	get_parent().add_child(wheels)
	wheels.setup(car)
	wheels.apply_region_look(look)
	var dust := DustPuffs.new()
	dust.name = "DustPuffs"
	get_parent().add_child(dust)
	dust.setup(car)
	dust.apply_region_look(look)
	_dust = dust
	_dust_base = dust.dust_color()
	var smoke := EngineSmoke.new()
	smoke.name = "EngineSmoke"
	get_parent().add_child(smoke)
	smoke.setup(car)
	var marks := TireMarks.new()
	marks.name = "TireMarks"
	get_parent().add_child(marks)
	marks.setup(null, car, self, 0.0)  # no centreline: the marks follow surface_at's road weight, not a width
	var flames := ExhaustFlames.new()
	flames.name = "ExhaustFlames"
	get_parent().add_child(flames)
	flames.setup(car)
	var lamps := CarLamps.new()
	lamps.name = "CarLamps"
	get_parent().add_child(lamps)
	lamps.setup(car)
	var shadow := CarShadow.new()
	shadow.name = "CarShadow"
	get_parent().add_child(shadow)
	shadow.setup(car)
	_car = car
	if _spectators != null:
		_spectators.car = car
	apply_weather(Config.data.level_weather)
	return marks


# The weather's particles on the chase camera and its wind; no road tint or environment look.
func apply_weather(id: String) -> void:
	var cfg: GameConfig = Config.data
	cfg.weather = id
	WindSway.push(cfg, id)
	if is_instance_valid(_particles):
		_particles.queue_free()
	_particles = null
	var entry := WeatherLibrary.by_id(id)
	var kind := String(entry.get("particles", ""))
	var cam := get_parent().get_node_or_null("ChaseCamera") as Camera3D
	if kind != "" and cam != null:
		var wind_field := String(entry.get("wind_dir", ""))
		var speed_field := String(entry.get("particle_speed", ""))
		_particles = WeatherField.spawn(cam, kind, int(cfg.get(String(entry["particle_count"]))),
			float(cfg.get(wind_field)) if wind_field != "" else 0.0,
			float(cfg.get(speed_field)) if speed_field != "" else 0.0)
	if HeadlightCone.has_headlights(cfg):
		set_process(true)
	else:
		HeadlightCone.reset()


# Compiles every effect's first-use shader (and each weather's particles) before the car can be driven.
func _warm_up(car: VehicleBody3D) -> void:
	var cover := get_tree().get_first_node_in_group("loading_screen") as LoadingScreen
	if cover == null and not Platform.is_headless():
		cover = LoadingScreen.new()
		add_child(cover)
	if cover != null:
		cover.set_title("Warming shaders…")
	car.controls_locked = true
	var cam := get_viewport().get_camera_3d()
	var point := WorldRuntime.warm_up_point(cam, car.global_position)
	var warmers := get_parent().find_children("*", "Node", true, false).filter(
		func(n: Node) -> bool: return n.has_method("warm_up") and n.has_method("clear_warm_up"))
	var fields: Array[Node] = []
	var kinds := {}
	for entry in WeatherLibrary.CONDITIONS:
		kinds[String(entry.get("particles", ""))] = true
	for kind: String in kinds:
		var field := WeatherField.spawn(cam, kind, 64, 0.0) if cam != null else null
		if field != null:
			fields.append(field)
	for n in warmers:
		n.warm_up(point)
	await get_tree().process_frame
	await get_tree().process_frame
	for n in warmers:
		if is_instance_valid(n):
			n.clear_warm_up()
	for f in fields:
		if is_instance_valid(f):
			f.queue_free()
	await WorldRuntime.look_around(self, car.global_position)
	get_parent().get_node("CameraManager").activate_current()
	car.controls_locked = false
	map.build()
	if cover != null:
		cover.finish()


static var _base: GameConfig  # the untouched grip values the snow blends away from


# The snow biome's handling follows the ground under the car, as free roam's snow ring does (BiomeDirector.apply_handling):
# snow grip, deep-snow drag (car.gd feathers it per wheel off the road), and the snow side of the tyre compound rule.
func _physics_process(_dt: float) -> void:
	if _car != null and _streamer != null:
		var snow := _streamer.snow_at(_car.global_position.x, _car.global_position.z)
		set_snow(Config.data, snow)
		if _dust != null:
			_dust.apply_region_look({"dust_color": snow_dust(_dust_base, snow, Config.data.level_snow_road_lighten)})


# The dust off the snow road, lightened toward white as level_ground.gdshader lightens the road under it.
static func snow_dust(base: Color, snow: float, lighten: float) -> Color:
	return base.lerp(Color(1.0, 1.0, 1.0, base.a), lighten * snow)


static func set_snow(cfg: GameConfig, snow: float) -> void:
	if _base == null:
		_base = GameConfig.new()
	cfg.grass_grip = lerpf(_base.grass_grip, cfg.snow_grass_grip, snow)
	cfg.gravel_grip = lerpf(_base.gravel_grip, cfg.snow_gravel_grip, snow)
	cfg.tarmac_grip = lerpf(_base.tarmac_grip, cfg.snow_tarmac_grip, snow)
	cfg.deep_snow_drag = cfg.level_snow_drag * snow
	cfg.deep_snow_depth_m = cfg.snow_visual_depth_m if snow >= 0.5 else 0.0


func _exit_tree() -> void:
	save_pose()
	set_snow(Config.data, 0.0)
	HeadlightCone.reset()
	WindSway.reset()
	Config.data.weather = WeatherLibrary.DEFAULT_ID


func load_level(d: Dictionary) -> void:
	var t0 := Time.get_ticks_msec()
	_bake = LevelBake.load_fresh(_save_path)
	var t1 := Time.get_ticks_msec()
	data = LevelData.new()
	data.load_save(d, _bake == null, _bake == null)
	level = data.level
	_spawn_nodes = spawn_override(d.get("roads", []), Config.data.level_spawn)
	if _bake == null:
		if not _save_path.is_empty() and not OS.has_feature("web") and not Platform.is_headless():
			var baking := get_tree().get_first_node_in_group("loading_screen") as LoadingScreen
			if baking == null:
				baking = LoadingScreen.new()
				add_child(baking)
			baking.set_title("Baking the level…")
			var worker := Thread.new()
			worker.start(LevelBake.load_or_bake.bind(_save_path, data))
			while worker.is_alive():
				baking.set_step("%d%%" % roundi(LevelBake.progress * 100.0))
				await get_tree().process_frame
			_bake = worker.wait_to_finish()
			baking.set_step("")
		else:
			_bake = LevelBake.load_or_bake(_save_path, data)
	print("level view: bake load %d ms, decode %d ms" % [t1 - t0, Time.get_ticks_msec() - t1])
	if _bake == null:
		push_error("LevelView: %s" % LevelBake.last_error)
		var cover := LoadingScreen.new()
		add_child(cover)
		cover.set_title(LevelBake.last_error)
		return
	_build_streamer()
	_trees = LevelTrees.new()
	_trees.name = "Trees"
	var t_trees := Time.get_ticks_msec()
	_trees.setup(_bake)
	add_child(_trees)
	print("level view: tree setup %d ms" % (Time.get_ticks_msec() - t_trees))
	var buildings := LevelBuildings.new()
	buildings.name = "Buildings"
	add_child(buildings)
	buildings.setup(_save_path, height_at)
	var ao := LevelAO.new(_bake.size, _bake.frame_n)
	var cfg: GameConfig = Config.data
	ao.stamp_trees(_bake.tree_xf, cfg.level_ao_tree_radius_scale)
	for b: Dictionary in buildings.boxes:
		ao.stamp_box(b.centre, b.axis, b.half, cfg.level_ao_building_reach_m, cfg.level_ao_building_ground)
	for i in d.get("logPiles", []).size():
		var pile := _log_pile(d["logPiles"][i], i)
		add_child(pile)
		var box := (pile.get_child(1) as CollisionShape3D).shape as BoxShape3D
		var axis := Vector2(pile.transform.basis.x.x, pile.transform.basis.x.z).normalized()
		ao.stamp_box(Vector2(pile.position.x, pile.position.z), axis, Vector2(box.size.x, box.size.z) * 0.5, cfg.level_ao_log_reach_m, cfg.level_ao_log_ground)
	ao.apply_to(material as ShaderMaterial)
	_spectators = LevelSpectators.new()
	_spectators.name = "Spectators"
	add_child(_spectators)
	_spectators.setup(d.get("spectators", []), self, _bake, buildings)

# A roadside timber pile from the save's `logPiles` ({x, z}), sawn ends facing the nearest road, kept clear of its surface.
func _log_pile(p: Dictionary, seed: int) -> StaticBody3D:
	var at := Vector2(p.x, p.z)
	var road := road_pose(at, Vector3.FORWARD)
	var rows := 4 + seed % 3
	var base := 7 + seed % 4
	var sections := 1 + seed % 2
	var away := at - Vector2(road.origin.x, road.origin.z)
	var clear := 7.0
	if away.length() < clear:
		at = Vector2(road.origin.x, road.origin.z) + away.normalized() * clear
	var radius := 0.16
	var mesh := LogPile.build(seed + 1, seed % 2, rows, base, 4.0, radius, sections)
	var body := StaticBody3D.new()
	body.name = "LogPile%d" % seed
	body.transform = Transform3D(road.basis.orthonormalized().rotated(Vector3.UP, PI / 2.0), Vector3(at.x, height_at(at.x, at.y) - 0.1, at.y))
	body.add_child(mesh)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(sections * LogPile.section_width(base, radius), radius * (2.0 + (rows - 1) * 1.75), 4.15)
	shape.shape = box
	shape.position.y = box.size.y / 2
	body.add_child(shape)
	return body


func _build_streamer() -> void:
	_streamer = LevelStreamer.new()
	_streamer.name = "Ground"
	if material == null:
		material = ShaderMaterial.new()
		(material as ShaderMaterial).shader = GROUND_SHADER
	_streamer.setup(data, _bake, material)
	add_child(_streamer)


func _process(_dt: float) -> void:
	if _recovery != null:
		off_road_label.text = off_road_text(_recovery.off_road_seconds())
		off_road_label.visible = not off_road_label.text.is_empty()
		off_road_label.size = Vector2.ZERO
		off_road_label.position = Vector2(roundf((get_viewport().get_visible_rect().size.x - off_road_label.size.x) * 0.5), UITheme.FONT_SIZE)
	if _car != null and HeadlightCone.has_headlights(Config.data):
		HeadlightCone.push(Config.data, _car.global_transform, _car.half_width() * 2.0 if _car.has_method("half_width") else 1.8)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		if _trees != null:
			_trees.update(cam.global_position, _car.global_position if _car != null else cam.global_position)
		if _streamer != null:
			_streamer.cover.update_centre(cam.global_position)



# Zero until the bake exists: the car asks for its spawn height while a stale level is still rebaking, and is moved to the spawn once loading ends.
func height_at(x: float, z: float) -> float:
	if _streamer != null:
		return _streamer.height_at(x, z)
	return _bake.height(x, z) if _bake != null else 0.0


# The top-of-screen warning while the off-road clock runs: empty until off_road_warning_after_s, then the seconds left.
static func off_road_text(off_s: float) -> String:
	var cfg: GameConfig = Config.data
	if off_s < cfg.off_road_warning_after_s:
		return ""
	return "OFF ROAD - RESET IN %.1f" % maxf(cfg.off_road_reset_timeout_s - off_s, 0.0)


# Past the road edge, and any gravel patch's, plus GameConfig.off_road_margin_m; RoadRecovery's off-road clock runs while this holds.
func is_off_road(p: Vector2) -> bool:
	if _bake == null:
		return false
	var near := _bake.road_nearest(p.x, p.y)
	return near.x > near.z + Config.data.off_road_margin_m and _bake.patch_distance(p.x, p.y) > Config.data.off_road_margin_m


# Where RoadRecovery puts the car: the nearest road point to `p`, facing along the road the way nearest `facing`.
func road_pose(p: Vector2, facing: Vector3) -> Transform3D:
	return _bake.road_pose(p, facing, height_at)


# The two road nodes (spawn, then the one to face) picked by `level_spawn`, or none when it is unset or out of range.
static func spawn_override(roads: Array, pick: Vector3i) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if pick.x == -1:
		return out
	if pick.x < 0 or pick.x >= roads.size() or pick.y < 0 or pick.y >= roads[pick.x].size() or roads[pick.x].size() < 2 \
			or pick.z >= roads[pick.x].size() or pick.z == pick.y:
		push_warning("LevelView: level_spawn %s is not a road node; using the default spawn" % pick)
		return out
	var road: Array = roads[pick.x]
	var other: int = pick.z if pick.z >= 0 else (pick.y + 1 if pick.y + 1 < road.size() else pick.y - 1)
	out.append(Vector2(road[pick.y].x, road[pick.y].z))
	out.append(Vector2(road[other].x, road[other].z))
	return out


func spawn_pose() -> Transform3D:
	if _spawn_nodes.size() == 2:
		var a := Vector3(_spawn_nodes[0].x, 0, _spawn_nodes[0].y)
		var b := Vector3(_spawn_nodes[1].x, 0, _spawn_nodes[1].y)
		a.y = height_at(a.x, a.z) + 1.0
		return Transform3D(Basis.looking_at((b - a) * Vector3(1, 0, 1)), a)
	return _bake.spawn_pose(height_at)


func surface_at(x: float, z: float) -> Vector2:
	return _bake.surface_at(x, z) if _bake != null else Vector2.ZERO

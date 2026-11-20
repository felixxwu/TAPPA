class_name LevelView
extends Node3D
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_level_view.gd — extend in the same change.
# A level saved by tools/level_editor_lab.html, built as drivable ground: the lab's terrain and road
# rebuilt at a finer grid with collision, its trees as the game's 6-card stars, and the car parked on
# the road's first node. A dev stand-in for free roam (GameConfig.dev_level_instead_of_free_roam).
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
var shop: RestStopPage
var _car: VehicleBody3D
var _particles: WeatherField
var _recovery: RoadRecovery
var _pause: Node
var map: LevelMap
var applied_fps_caps: Array[int] = []


func _ready() -> void:
	var path := level_path if not level_path.is_empty() else Config.data.dev_level_path
	var t_parse := Time.get_ticks_msec()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	print("level view: parse %d ms" % (Time.get_ticks_msec() - t_parse))
	if not parsed is Dictionary:
		push_error("LevelView: couldn't read %s" % path)
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
	if String(owned.get("model_id", "")) != Config.data.dev_level_car_id:
		owned = {"model_id": Config.data.dev_level_car_id, "tuning": {}, "parts": LootRules.parts_for({"model_id": Config.data.dev_level_car_id}).map(
			func(p: Dictionary) -> Dictionary: return p.merged({"on": false}))}
	car.apply_owned(LootRules.fielded(owned))
	get_parent().get_node("CameraManager").refresh_bonnet_offset()
	car.damage.invulnerable = true
	car.reset_to(_next_pose if _next_pose != null else spawn_pose())
	_next_pose = null
	_pause = get_parent().get_node_or_null("PauseMenu")
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
		_pause.extra_requested.connect(func(label: String) -> void: open_shop() if label == "Shop" else open_garage())
	if not Platform.is_headless():  # nothing renders, so there is nothing to compile
		var t_warm := Time.get_ticks_msec()
		await _warm_up(car)
		print("level view: warm-up %d ms" % (Time.get_ticks_msec() - t_warm))
	WorldRuntime.apply_fps_cap(applied_fps_caps, FpsSetting.resolve(), Platform.is_headless())
	if _pause != null:
		_pause.set_input_enabled(true)  # the menu stays inert until its world says it has finished loading
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	map = LevelMap.new()
	map.view = self
	layer.add_child(map)
	loaded.emit()


func _unhandled_input(event: InputEvent) -> void:
	if _recovery != null and _pause != null and event.is_action_pressed("reset_to_road") and not event.is_echo() and _pause.is_armed():
		_recovery.reset_now()


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
		var driving := id == Config.data.dev_level_car_id
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


func _drive(id: String) -> void:
	Config.data.dev_level_car_id = id
	_reload("Changing cars")


func _reload(title: String) -> void:
	_next_pose = _car.global_transform
	Scenes.change_to(get_tree(), Scenes.LEVEL_VIEW, title)


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
	apply_weather(Config.data.dev_level_weather)
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
	if cover != null:
		cover.finish()


func _exit_tree() -> void:
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
	_spawn_nodes = spawn_override(d.get("roads", []), Config.data.dev_level_spawn)
	if _bake == null:
		if not _save_path.is_empty() and not OS.has_feature("web") and not Platform.is_headless():
			var baking := LoadingScreen.new()
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
	if _car != null and HeadlightCone.has_headlights(Config.data):
		HeadlightCone.push(Config.data, _car.global_transform, _car.half_width() * 2.0 if _car.has_method("half_width") else 1.8)
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		if _trees != null:
			_trees.update(cam.global_position, _car.global_position if _car != null else cam.global_position)
		if _streamer != null:
			_streamer.cover.update_centre(cam.global_position)



func height_at(x: float, z: float) -> float:
	return _streamer.height_at(x, z) if _streamer != null else _bake.height(x, z)


# Where RoadRecovery puts the car: the nearest road point to `p`, facing along the road the way nearest `facing`.
func road_pose(p: Vector2, facing: Vector3) -> Transform3D:
	return _bake.road_pose(p, facing, height_at)


# The two road nodes (spawn, then the one to face) picked by `dev_level_spawn`, or none when it is unset or out of range.
static func spawn_override(roads: Array, pick: Vector2i) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if pick == Vector2i(-1, -1):
		return out
	if pick.x < 0 or pick.x >= roads.size() or pick.y < 0 or pick.y >= roads[pick.x].size() or roads[pick.x].size() < 2:
		push_warning("LevelView: dev_level_spawn %s is not a road node; using the default spawn" % pick)
		return out
	var road: Array = roads[pick.x]
	var other: int = pick.y + 1 if pick.y + 1 < road.size() else pick.y - 1
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
	return _bake.surface_at(x, z)

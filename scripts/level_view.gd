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
signal render_started  # photo mode's render is on: everything built and showing
signal render_finished  # and it's off again, back to the normal draw distances

@export var level_path := ""
@export var material: Material  # the ground shader (level_ground.gdshader)

var level: Dictionary
var data := LevelData.new()
var _bake: LevelBake
var _spawn_nodes: Array[Vector2] = []
var _save_path := ""
var _streamer: LevelStreamer
var _rendering := false  # photo mode's render is on (photo_render toggles it)
var _render_busy := false  # building it behind the loading screen
var _render_cam: PhotoModeCamera
var _render_far0 := 0.0  # the photo camera's far plane before the render pushed it out
var _photo_cam: PhotoModeCamera  # while photo mode is up: the viewpoint trees, cover and ground follow
var _trees: LevelTrees
var _spectators: LevelSpectators
var garage: MenuPage
var missions_page: MenuPage
static var _next_pose: Variant = null  # where the car stands after a car-change reload
static var owned: Dictionary = {}  # the level's car with every shop part unlocked, kept across reloads
const SAVED_CAR_KEY := "level_car"
const CARS_KEY := "level_cars"
static var mission: Dictionary = {}  # the drive in progress: {from, to, car}; kept across the reloads a car or parts change does
const SAVED_POSE_KEY := "level_pose"
const POSE_SAVE_SEC := 5.0
var shop: RestStopPage
var beacons: TeleportBeacons
var service: MenuPage  # the menu a teleport point opens: repair, upgrade, swap cars
var service_prompt: Button
static var last_point := -1  # the teleport point last visited, where a wreck respawns; kept across the reloads a car change does
var wreck_page: MenuPage
var _wrecked := false
var _missions_overview := false  # the missions page is the pause menu's overview, not a teleport point's pick
var service_name := ""  # the teleport point's name, the service menu's title
var _from_service := false  # the service menu is open, or its Shop / Garage, which return to it
var _car: VehicleBody3D
var _particles: WeatherField
var _recovery: RoadRecovery
var _dust: DustPuffs
var _dust_base: Color  # the gravel's dust colour outside the snow
var _pause: Node
var map: LevelMap
var minimap: LevelMinimap
var off_road_label: Label
var mission_label: Label
var _service_point := -1
var _service_notice := ""
var applied_fps_caps: Array[int] = []
var perf_stats := LevelStats.new()
var _driving := false  # true once loaded, so a half-built level never overwrites the saved spot
const GROUP := &"level_view"


func _ready() -> void:
	add_to_group(GROUP)
	if not Benchmark.active:
		GraphicsSettings.apply(Config.data)
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
		env.environment.fog_depth_end = Config.data.level_fog_end_m
		env.environment.fog_depth_curve = Config.data.level_fog_curve
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
	Save.set_setting(CARS_KEY, owned_cars())
	car.apply_owned(LootRules.fielded(owned))
	get_parent().get_node("CameraManager").refresh_bonnet_offset()
	car.reset_to(_next_pose if _next_pose != null else saved_pose(Save.get_setting(SAVED_POSE_KEY), _save_path, spawn_pose()))
	_next_pose = null
	_pause = get_parent().get_node_or_null("PauseMenu")
	# The pause menu offers Photo Mode here too; without a host its pick hid the menu and left the
	# player stuck on a frozen frame with no controls and no way back.
	if _pause != null:
		_attach_photo_mode.call_deferred()  # deferred: the scene is still adding its children
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	off_road_label = UITheme.label("")  # styled as free roam's prompt box (MiniMap.prompt_label)
	off_road_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(4)))
	off_road_label.visible = false
	layer.add_child(off_road_label)
	mission_label = UITheme.label("")
	mission_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(4)))
	mission_label.visible = false
	layer.add_child(mission_label)
	map = LevelMap.new()
	map.view = self
	map.process_mode = Node.PROCESS_MODE_DISABLED  # painting starts now, but M stays dead until the level has loaded
	layer.add_child(map)
	map.closed.connect(_on_map_closed)
	minimap = LevelMinimap.new()
	minimap.view = self
	minimap.map = map
	layer.add_child(minimap)
	if _streamer != null:
		_streamer.focus = car
		_streamer.brush = car
		var t_fill := Time.get_ticks_msec()
		await _streamer.prefill_async()
		print("level view: prefill %d ms" % (Time.get_ticks_msec() - t_fill))
	beacons = TeleportBeacons.new()
	beacons.setup(teleport_points(), height_at)
	add_child(beacons)
	var arrow := RouteArrow.new()
	arrow.view = self
	add_child(arrow)
	service_prompt = UITheme.row_button(UITheme.caps("Tap" if Platform.is_touch() else "Enter / A"), open_service)
	service_prompt.visible = false
	layer.add_child(service_prompt)
	get_tree().process_frame.connect(_place_service_prompt)  # fires while paused too, so menus hide it
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
	car.damage.thermal = true  # not sooner: an overheating car would lose health behind the loading cover
	car.damage.gave_up.connect(_on_gave_up)
	Save.flushing.connect(save_pose)  # window close, app pause, browser tab hidden
	var timer := Timer.new()
	timer.wait_time = POSE_SAVE_SEC  # also on a timer: stopping the game from the editor sends no close
	timer.timeout.connect(save_pose)
	add_child(timer)
	timer.start()
	perf_stats.view = self
	add_child(perf_stats)
	loaded.emit()
	_open_service_on_arrival()


func _unhandled_input(event: InputEvent) -> void:
	if _recovery != null and _pause != null and event.is_action_pressed("reset_to_road") and not event.is_echo() and _pause.is_armed():
		_recovery.reset_now()
	elif event.is_action_pressed("menu_select") and not event.is_echo() and service_at() >= 0:
		get_viewport().set_input_as_handled()
		open_service()
	elif event.is_action_pressed("toggle_perf_overlay") and not event.is_echo():
		perf_stats.toggle()


func _on_extra(label: String) -> void:
	if label == "Map":
		map.open_over_pause()
	elif label == "Missions":
		open_missions(true)


# The map closed. Opened from the pause menu, Back returns to the menu; a teleport goes back to driving, on the point's service menu.
func _on_map_closed(teleported: bool, over_pause: bool) -> void:
	if over_pause and _pause != null:
		if teleported:
			_pause.set_input_enabled(true)
		else:
			_pause.return_from_extra()
	if teleported:
		mission = {}
		_open_service_on_arrival()


# Arriving on a teleport point (launching there, or a map teleport) opens its service menu.
func _open_service_on_arrival() -> void:
	for i in 2:  # Car.reset_to moves the car on the next physics step
		await get_tree().physics_frame
	if is_inside_tree() and service_at() >= 0:
		open_service()


# The service menu's Swap car: a card per catalogue car, stock; picking one reloads the level with it.
func open_garage() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	garage = CardUI.card_page(layer, {"title": "Garage", "dim": true})
	var entries: Array = []
	var selected := 0
	var have := owned_cars()
	for i in CarLibrary.all().size():
		var id := String(CarLibrary.all()[i]["id"])
		if not id in have:
			continue
		var stats := LootRules.fitted_stats({"model_id": id})
		var driving := id == Config.data.level_car_id
		if driving:
			selected = entries.size()
		entries.append({"title": String(CarLibrary.all()[i].get("name", id)), "car": i,
			"desc": CardUI.stats_line(stats["hp"], stats["mass"], stats["drive_mode"]),
			"extra": "Driving" if driving else "", "action": _drive.bind(id)})
	var cards := CardUI.card_list(garage, entries, [], selected)
	garage.add_action(UITheme.row_button("< Back", _close_garage))
	MenuNav.attach(garage, {first = cards, on_back = _close_garage})


# The service menu's Upgrade: free roam's rest-stop shop with every part free and unlocked; a change reloads the level.
func open_shop() -> void:
	_rest_page().open_shop()


# The service menu's Tune car: the rest-stop page's tuning sliders, applied to the car as they move and saved.
func open_tune() -> void:
	_rest_page().open_tune()


func _rest_page() -> RestStopPage:
	shop = RestStopPage.new()
	shop.free = true
	shop.engine_cars = owned_cars()
	shop.owned = owned
	shop.car = _car
	add_child(shop)
	shop.car_changed.connect(func() -> void: _reload("Applying parts to your car"))
	shop.tuned.connect(func() -> void: Save.set_setting(SAVED_CAR_KEY, owned.duplicate(true)))
	shop.closed.connect(_close_shop)
	return shop


func _close_shop() -> void:
	shop.queue_free()
	shop = null
	if _next_pose == null:  # set when the shop's change is reloading the level
		open_service()


func _close_garage() -> void:
	CardUI.park_previews(garage)
	garage.get_parent().queue_free()
	garage = null
	open_service()


# Whether the driving HUD (the minimap) shows: not under a menu, the map, the service menu or photo mode.
func hud_visible() -> bool:
	return _driving and is_instance_valid(_car) and not get_tree().paused and not map.visible and not _from_service and _photo_cam == null


func _place_service_prompt() -> void:
	if not is_inside_tree():  # the tree's frame signal still fires while a scene change is removing the level
		return
	service_prompt.visible = service_at() >= 0
	service_prompt.size = Vector2.ZERO
	service_prompt.position = ((get_viewport().get_visible_rect().size - service_prompt.size) * 0.5).round()


func teleport_points() -> Array:
	return level.get("teleports", []).map(func(t: Dictionary) -> Vector2: return Vector2(float(t["x"]), float(t["z"])))


# Near any teleport point the car heals, level_service_heal_hp_s a second; reaching full HP finishes the repair (cooling, wheels).
# The point becomes the one a wreck respawns at, and a wreck that rolls onto one is mended there.
func heal_at_points(dt: float) -> void:
	if not _driving or not is_instance_valid(_car):
		return
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	var points := teleport_points()
	for i in points.size():
		if p.distance_to(points[i]) <= Config.data.level_service_radius_m:
			last_point = i
			if _wrecked:
				_end_wreck()
			var dmg: DamageModel = _car.damage
			if dmg.hp < dmg.max_hp:
				dmg.hp = minf(dmg.max_hp, dmg.hp + Config.data.level_service_heal_hp_s * dt)
				if dmg.hp >= dmg.max_hp:
					dmg.repair()
			return


# Puts the car on point `p` (LevelMap.teleport, a wreck's respawn), loading the ground there first so it doesn't fall through.
func place_car_on(p: Vector2) -> void:
	var pose := teleport_pose(p, -_car.global_basis.z)
	if _streamer != null:
		var marker := Node3D.new()
		add_child(marker)
		marker.global_position = pose.origin
		_streamer.focus = marker
		_streamer.process_mode = PROCESS_MODE_ALWAYS
		await _streamer.prefill_async()
		_streamer.process_mode = PROCESS_MODE_INHERIT
		_streamer.focus = _car
		marker.queue_free()
		pose = teleport_pose(p, -_car.global_basis.z)  # the streamed ground's height
	_car.reset_to(pose)


# The engine overheated to 0 HP: it cuts out, the car coasts, and a moment later the wreck page offers a respawn.
func _on_gave_up() -> void:
	_wrecked = true
	_pause.set_input_enabled(false)
	map.process_mode = Node.PROCESS_MODE_DISABLED  # no teleporting away from a wreck
	_set_engine_killed(true)
	await get_tree().create_timer(Config.data.wreck_page_delay_s, false).timeout
	if _wrecked and wreck_page == null and is_inside_tree():
		_set_driverless(true)
		open_wreck_page()


func open_wreck_page() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	wreck_page = CardUI.card_page(layer, {"title": "Wrecked", "dim": true})
	var points: Array = level.get("teleports", [])
	var at := String(points[last_point].get("name", "")) if last_point >= 0 and last_point < points.size() else ""
	var cards := CardUI.card_list(wreck_page, [{"title": "Respawn", "icon": "resume_run", "action": respawn}],
		["The engine gave up. Back to " + at] if not at.is_empty() else ["The engine gave up"])
	MenuNav.attach(wreck_page, {first = cards, on_back = respawn})


# Back at the last teleport point visited (or the spawn before any), mended and cold.
func respawn() -> void:
	_end_wreck()
	var points := teleport_points()
	if last_point >= 0 and last_point < points.size():
		await place_car_on(points[last_point])
	else:
		_car.reset_to(spawn_pose())
	_car.damage.repair()
	_car.damage.engine_temp = 0.0


func _end_wreck() -> void:
	_wrecked = false
	if wreck_page != null:
		wreck_page.get_parent().queue_free()
		wreck_page = null
	_set_driverless(false)
	_set_engine_killed(false)
	_pause.set_input_enabled(true)
	map.process_mode = Node.PROCESS_MODE_ALWAYS


# Scripted control with every input at zero, so the wreck page's menu keys don't steer the car.
func _set_driverless(on: bool) -> void:
	_car.set("ai_throttle", 0.0)
	_car.set("ai_steer", 0.0)
	_car.set("ai_handbrake", false)
	_car.set("ai_controlled", on)


# The engine cuts out completely: no drive, no sound.
func _set_engine_killed(on: bool) -> void:
	var dt = _car.get("drivetrain")
	if dt != null and dt.engine != null:
		dt.engine.killed = on


# The teleport point the car has stopped beside, so can open its service menu; -1 when none.
func service_at() -> int:
	if not _driving or not is_instance_valid(_car) or get_tree().paused or _pause == null or not _pause.is_armed() \
			or _car.linear_velocity.length() > Config.data.level_service_max_speed:
		return -1
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	var points := teleport_points()
	for i in points.size():
		if p.distance_to(points[i]) <= Config.data.level_service_radius_m:
			return i
	return -1


# A teleport point's menu: repair, the Shop or the Garage, which come back here when they close.
func open_service() -> void:
	var at := service_at()
	if at < 0 and not _from_service:
		return
	if not _from_service:
		service_name = String(level["teleports"][at].get("name", ""))
		_service_point = at
	_from_service = true
	get_tree().paused = true
	_pause.set_input_enabled(false)
	var layer := CanvasLayer.new()
	layer.layer = 50
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	service = CardUI.card_page(layer, {"title": service_name if not service_name.is_empty() else "Service", "dim": true})
	var missions := _missions_here()
	var cards := CardUI.card_list(service, [
		{"title": "Missions", "icon": "travel", "disabled": missions.is_empty(), "action": _service_open.bind(open_missions)},
		{"title": "Upgrade", "icon": "shop", "action": _service_open.bind(open_shop)},
		{"title": "Swap car", "icon": "car", "action": _service_open.bind(open_garage)},
		{"title": "Tune car", "icon": "tune", "action": _service_open.bind(open_tune)},
	], [_service_notice] if not _service_notice.is_empty() else [])
	_service_notice = ""
	service.add_action(UITheme.row_button("< Back", close_service))
	MenuNav.attach(service, {first = cards, on_back = close_service})


func _missions_here() -> Array:
	if _service_point < 0 or _service_point >= level.get("teleports", []).size():
		return []
	return level["teleports"][_service_point].get("missions", [])


func _car_name(id: String) -> String:
	return String(CarLibrary.by_id(id).get("name", id))


# The service menu's Missions: a drive to another teleport point wins a car; picking one starts it.
# The missions to pick from at this teleport point, or with `overview` (the pause menu's Missions) every mission
# from the teleport points found so far, where picking one teleports the car to its start first.
func open_missions(overview := false) -> void:
	_missions_overview = overview
	var layer := CanvasLayer.new()
	layer.layer = 50
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	missions_page = CardUI.card_page(layer, {"title": "Missions", "dim": true})
	var have := owned_cars()
	var active := String(mission.get("from", "")) + ">" + String(mission.get("to", ""))
	var entries: Array = []
	var points: Array = map.known_teleports() if overview else [{"name": service_name, "missions": _missions_here()}]
	for t: Dictionary in points:
		for m: Dictionary in t.get("missions", []):
			var id := String(m.get("car", ""))
			var idx := CarLibrary.index_of(id)
			if idx < 0:
				continue
			var e := {"title": "To " + String(m.get("to", "")), "car": idx, "desc": _car_name(id),
				"extra": "Won" if id in have else "", "action": _start_mission_from.bind(t, m) if overview else _start_mission.bind(m)}
			if overview:
				e["subtitle"] = "From " + String(t.get("name", ""))
				if String(t.get("name", "")) + ">" + String(m.get("to", "")) == active:
					e["extra"] = "Driving"
			entries.append(e)
	var header: Array = ["Find teleport points to see their missions"] if overview and entries.is_empty() else []
	var cards := CardUI.card_list(missions_page, entries, header)
	missions_page.add_action(UITheme.row_button("< Back", _close_missions))
	MenuNav.attach(missions_page, {first = cards, on_back = _close_missions})


func _close_missions() -> void:
	CardUI.park_previews(missions_page)
	missions_page.get_parent().queue_free()
	missions_page = null
	if _missions_overview:
		_pause.return_from_extra()
	else:
		open_service()


func _start_mission(m: Dictionary) -> void:
	mission = {"from": service_name, "to": String(m.get("to", "")), "car": String(m.get("car", ""))}
	CardUI.park_previews(missions_page)
	missions_page.get_parent().queue_free()
	missions_page = null
	close_service_state()


# A mission picked from the pause menu: start it, then put the car on its start point and resume driving.
func _start_mission_from(t: Dictionary, m: Dictionary) -> void:
	service_name = String(t.get("name", ""))
	mission = {"from": service_name, "to": String(m.get("to", "")), "car": String(m.get("car", ""))}
	CardUI.park_previews(missions_page)
	missions_page.get_parent().queue_free()
	missions_page = null
	await place_car_on(Vector2(float(t["x"]), float(t["z"])))
	close_service_state()


func close_service_state() -> void:
	_from_service = false
	get_tree().paused = false
	_pause.set_input_enabled(true)


func _check_mission() -> void:
	if mission.is_empty() or not _driving or _from_service or get_tree().paused or not is_instance_valid(_car):
		return
	var points := teleport_points()
	var tps: Array = level.get("teleports", [])
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	for i in points.size():
		if String(tps[i].get("name", "")) == mission["to"] and p.distance_to(points[i]) <= Config.data.level_service_radius_m:
			_complete_mission(i)
			return


func _complete_mission(at: int) -> void:
	var id := String(mission["car"])
	var have := owned_cars()
	var fresh := not id in have
	if fresh:
		have.append(id)
		Save.set_setting(CARS_KEY, have)
	mission = {}
	service_name = String(level["teleports"][at].get("name", ""))
	_service_point = at
	_service_notice = "Mission complete: %s is %s" % [_car_name(id), "yours" if fresh else "already yours"]
	_from_service = true
	open_service()


# The cars the player may drive: the saved list, or the authored start car and the current one for a save without it.
static func sanitise_cars(saved: Variant, authored: String, current: String) -> Array:
	var out: Array = []
	for id: Variant in (saved if saved is Array else [authored, current]):
		if CarLibrary.index_of(String(id)) >= 0 and not String(id) in out:
			out.append(String(id))
	if out.is_empty() and CarLibrary.index_of(current) >= 0:
		out.append(current)
	return out


static func owned_cars() -> Array:
	return sanitise_cars(Save.get_setting(CARS_KEY), String(Config.authored_value("level_car_id", Config.data.level_car_id)), Config.data.level_car_id)


func close_service() -> void:
	_free_service()
	close_service_state()


func _free_service() -> void:
	service.get_parent().queue_free()
	service = null


func _service_open(page: Callable) -> void:
	_free_service()
	page.call()


# Settings → Dev → Unlock everything: the whole map revealed, every teleport point found, every car owned.
func unlock_everything() -> void:
	map.reveal_all()
	Save.set_setting(CARS_KEY, CarLibrary.all().map(func(c: Dictionary) -> String: return String(c["id"])))


# Wipe all progress: forget the level's car, parts, parked spot and explored map, which live in the
# save's device settings (kept by Save.reset_new_game), and stop a running level saving them again as it closes.
static func forget_progress() -> void:
	for key in [SAVED_CAR_KEY, SAVED_POSE_KEY, LevelMap.SEEN_KEY, CARS_KEY]:
		Save.erase_setting(key)
	owned = {}
	mission = {}
	_next_pose = null
	Config.data.level_car_id = Config.authored_value("level_car_id", Config.data.level_car_id)
	for view: LevelView in (Engine.get_main_loop() as SceneTree).get_nodes_in_group(GROUP):
		view._driving = false


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


# Settings → Graphics changed while driving: most of it is read while the level builds, so rebuild it here.
func reload_for_graphics() -> void:
	if _driving and is_instance_valid(_car):
		_reload("Applying graphics settings")


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
func _physics_process(dt: float) -> void:
	heal_at_points(dt)
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
	var fences := LevelFences.new()
	fences.name = "Fences"
	add_child(fences)
	fences.setup(d.get("fences", []), _bake._roads(), _bake.height)
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
	_check_mission()
	if mission_label != null:
		mission_label.text = "Drive to %s" % mission["to"] if not mission.is_empty() else ""
		mission_label.visible = not mission.is_empty()
		mission_label.size = Vector2.ZERO
		var y := float(UITheme.FONT_SIZE)
		if off_road_label != null and off_road_label.visible:
			y += off_road_label.size.y + UITheme.FONT_SIZE * 0.5
		mission_label.position = Vector2(roundf((get_viewport().get_visible_rect().size.x - mission_label.size.x) * 0.5), roundf(y))
	if _recovery != null:
		off_road_label.text = off_road_text(_recovery.off_road_seconds())
		off_road_label.visible = not off_road_label.text.is_empty()
		off_road_label.size = Vector2.ZERO
		off_road_label.position = Vector2(roundf((get_viewport().get_visible_rect().size.x - off_road_label.size.x) * 0.5), UITheme.FONT_SIZE)
	if _car != null and HeadlightCone.has_headlights(Config.data):
		HeadlightCone.push(Config.data, _car.global_transform, _car.half_width() * 2.0 if _car.has_method("half_width") else 1.8)
	if _photo_cam == null:
		_update_view(get_viewport().get_camera_3d(), false)


# Trees and ground cover round `cam`. `free_view` (photo mode) shows every tree in reach rather than
# the set baked as visible from the nearest stretch of road, since the camera can be anywhere.
func _update_view(cam: Camera3D, free_view: bool) -> void:
	if cam == null:
		return
	if _trees != null:
		_trees.update(cam.global_position, _car.global_position if _car != null else cam.global_position, free_view)
	if _streamer != null:
		_streamer.cover.update_centre(cam.global_position)


func _attach_photo_mode() -> void:
	var host := PhotoModeHost.attach(get_parent())
	host.render = photo_render
	if not host.opened.is_connected(_on_photo_opened):
		host.opened.connect(_on_photo_opened)
		host.closed.connect(_on_photo_closed)


# Photo mode freezes the tree, but the camera flies: the ground, cover and trees follow it instead
# of the car, and keep streaming while paused, so flying off doesn't leave bare, treeless ground.
func _on_photo_opened(cam: PhotoModeCamera) -> void:
	_photo_cam = cam
	if _streamer != null:
		_streamer.focus = cam
		_streamer.process_mode = Node.PROCESS_MODE_ALWAYS
	if not get_tree().process_frame.is_connected(_follow_photo_cam):
		get_tree().process_frame.connect(_follow_photo_cam)


func _follow_photo_cam() -> void:
	if is_instance_valid(_photo_cam):
		_update_view(_photo_cam, true)


# Photo mode's RENDER, a toggle: on, trees draw out to photo_render_tree_m and ground cover out to
# photo_render_cover_m (photo_render_cover_touch_m on a phone) round `cam`, and stay that way as it flies;
# off (or leaving photo mode) puts the normal distances back. Building that much at once can stall for
# a while, so a loading screen covers the first build.
func photo_render(cam: PhotoModeCamera) -> void:
	if _render_busy or _trees == null or _streamer == null or not is_instance_valid(cam):
		return
	if _rendering:
		_render_off()
		return
	_render_busy = true
	var cfg: GameConfig = Config.data
	var screen: LoadingScreen = null
	if not Platform.is_headless():
		screen = LoadingScreen.new()
		screen.process_mode = Node.PROCESS_MODE_ALWAYS
		screen.set_title("Rendering…")
		add_child(screen)
		for _i in 2:  # let it reach the screen before the stall
			await get_tree().process_frame
	if not is_instance_valid(cam) or not cam.is_active():  # photo mode closed under the loading screen
		if screen != null:
			screen.finish()
		_render_busy = false
		return
	var env := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	_render_cam = cam
	_render_far0 = cam.far
	cam.far = maxf(_render_far0, cfg.photo_render_tree_m + LevelBake.TREE_TILE_M)
	if env != null:
		env.environment.fog_depth_end = maxf(cfg.level_fog_end_m, cfg.photo_render_tree_m)
	_trees.set_draw_override(cfg.photo_render_tree_m)
	_streamer.cover.set_reach_override(cfg.photo_render_cover_touch_m if Platform.is_touch() else cfg.photo_render_cover_m)
	_trees.update(cam.global_position, _car.global_position if _car != null else cam.global_position, true)
	_trees.settle()
	for t in _streamer.cover.missing(Vector2(cam.global_position.x, cam.global_position.z)):
		_streamer.cover.build_tile(t, _car)
	if screen != null:
		screen.finish()
	_rendering = true
	_render_busy = false
	cam.render_active = true
	render_started.emit()


# Back to the normal draw distances (RENDER pressed again, or photo mode closing).
func _render_off() -> void:
	if not _rendering:
		return
	_rendering = false
	var cfg: GameConfig = Config.data
	_trees.set_draw_override(0.0)
	_streamer.cover.set_reach_override(0.0)
	var env := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env != null:
		env.environment.fog_depth_end = cfg.level_fog_end_m
	if is_instance_valid(_render_cam):
		_render_cam.far = _render_far0
		_render_cam.render_active = false
	_render_cam = null
	render_finished.emit()


func is_rendering() -> bool:
	return _rendering


func _on_photo_closed() -> void:
	_render_off()
	_photo_cam = null
	if get_tree().process_frame.is_connected(_follow_photo_cam):
		get_tree().process_frame.disconnect(_follow_photo_cam)
	if _streamer != null:
		_streamer.focus = _car
		_streamer.process_mode = Node.PROCESS_MODE_INHERIT



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


# Where a teleport to point `p` leaves the car: right on it, facing its `heading` (compass degrees: 0 = north, -z; 90 = east, +x),
# or, for a point with none, `car_facing` turned along the road there if that road is a dead end one way.
func teleport_pose(p: Vector2, car_facing: Vector3) -> Transform3D:
	var facing := _bake._roads().away_from_dead_end(p, car_facing)
	for t: Dictionary in level.get("teleports", []):
		if Vector2(float(t["x"]), float(t["z"])) == p and t.has("heading"):
			var h := deg_to_rad(float(t["heading"]))
			facing = Vector3(sin(h), 0.0, -cos(h))
	facing.y = 0.0
	return Transform3D(Basis.looking_at(facing.normalized(), Vector3.UP), Vector3(p.x, height_at(p.x, p.y) + 1.0, p.y))


# Where a new player starts: the teleport point named `level_spawn_teleport`, else `level_spawn`'s road node (the benchmark's recorded start).
func spawn_pose() -> Transform3D:
	for t: Dictionary in level.get("teleports", []):
		if not Benchmark.active and not Config.data.level_spawn_teleport.is_empty() and String(t.get("name", "")) == Config.data.level_spawn_teleport:
			return teleport_pose(Vector2(float(t["x"]), float(t["z"])), Vector3.FORWARD)
	if _spawn_nodes.size() == 2:
		var a := Vector3(_spawn_nodes[0].x, 0, _spawn_nodes[0].y)
		var b := Vector3(_spawn_nodes[1].x, 0, _spawn_nodes[1].y)
		a.y = height_at(a.x, a.z) + 1.0
		return Transform3D(Basis.looking_at((b - a) * Vector3(1, 0, 1)), a)
	return _bake.spawn_pose(height_at)


func surface_at(x: float, z: float) -> Vector2:
	return _bake.surface_at(x, z) if _bake != null else Vector2.ZERO

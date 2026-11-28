class_name LevelView
extends Node3D
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_level_view.gd — extend in the same change.
# A level saved by tools/level_editor_lab.html, built as drivable ground: the lab's terrain and road
# rebuilt at a finer grid with collision, its trees as the game's 6-card stars, and the car parked on
# the road's first node. THIS IS THE GAME WORLD (Scenes.WORLD, the default mode): the Hafren level,
# GameConfig.level_path.
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
var rallies: LevelRallies
var garage: MenuPage
var deliveries_page: MenuPage
static var load_ms: Dictionary = {}  # how long each load stage took, in ms; the benchmark report carries it
var _swap_car_on_close := ""  # a car bought from the map is driven once its shop closes
static var _next_pose: Variant = null  # where the car stands after a car-change reload
var _store_selected := 0
var _store_rebuilt := false
static var owned: Dictionary = {}  # the level's car and the parts bought for it, kept across reloads
const TUTOR := "res://textures/npc/tutorial.webp"  # the tutorial guy's portrait, from tools/render_npc.sh tutorial 7578
const DISPATCHER := "res://textures/npc/dispatcher.webp"  # who hands out deliveries at the first pick-up point (seed 9042)
const RECIPIENT := "res://textures/npc/recipient.webp"  # who takes the first delivery (seed 20288)
const SAVED_CAR_KEY := "level_car"
const CARS_KEY := "level_cars"
const MONEY_KEY := "level_money"
const DONE_KEY := "level_deliveries_done"  # the keys (delivery_key) of the deliveries already completed
const PARTS_KEY := "level_parts"  # car id -> the part ids (upgrades, tires, kits) bought at shops for that car; only these can go on it
# What a delivery can carry and its weight in kg, which rides in the car until it's dropped off.
const CARGO := {"Post": 10.0, "Parcels": 20.0, "Medicine": 5.0, "Seed packets": 8.0, "Welsh cakes": 6.0,
	"Fishing tackle": 12.0, "Honey jars": 15.0, "Newspapers": 18.0, "Camera kit": 10.0, "Wool": 12.0,
	"Spare fuses": 3.0, "Tea and biscuits": 5.0}
static var _tutor_on_drive := false  # the tutorial guy points a new player to their first delivery once they drive off
static var _shopped_since_drive := false  # the player has entered a shop since driving off, which the dispatcher waits for
static var _greet_at_pickup := false  # and the dispatcher greets them when they get there
static var _greet_at_drop := false  # and whoever takes their first delivery thanks them
static var delivery: Dictionary = {}  # the drive in progress: {from, to, pay, cargo, kg, cargo_hp}; kept across the reloads a car or parts change does
const SAVED_POSE_KEY := "level_pose"
const POSE_SAVE_SEC := 5.0
var shop: RestStopPage
var beacons: TeleportBeacons
var shop_beacons: TeleportBeacons
var nav_beam: MeshInstance3D  # the sat nav destination, seen from afar as a tall faint column of light
var store: MenuPage  # a shop's page: its stock to buy
var orbit_camera: Camera3D  # circles a shop or teleport point while its menu is open (and the start shop while the player has no car)
var _orbit_centre := Vector3.INF
var _orbit_a0 := 0.0
var _orbit_t0 := 0
var _orbit_prev: Camera3D  # the driving camera to hand back to
var _menu_point := Vector2.INF  # the teleport point or shop whose menu is open: leaving it puts the car there, facing its way
var _first_buy_at := -1  # the start shop, once a new player has bought their first car there and is still shopping
var _buildings: LevelBuildings  # the level's houses and shops, one merged mesh
var shop_cars: Dictionary = {}  # car id -> the display cars parked at the shops that sell it
var _shop_return := Callable()  # what a rest-stop page opened from a shop does on closing, instead of reopening the service menu
var _store_dirty := false  # a part was bought, so the car is re-fielded when the shop closes
var _store_remote := false  # the open shop was picked on the map, so the car isn't there and isn't moved to it
var service: MenuPage  # the menu a teleport point opens: repair, upgrade, swap cars
var service_prompt: PanelContainer  # the centred card over a shop or point the car has stopped at
var _prompt_title: Label
var _prompt_kind: Label
var _respawning := false  # a respawn is loading the ground; a second press must not start another
var _prompt_wanted := false
var _prompt_slide := float(UITheme.FONT_SIZE)
var _prompt_tween: Tween
static var last_point := -1  # the teleport point last visited, where a wreck respawns; kept across the reloads a car change does
var wreck_page: MenuPage
var _wrecked := false
var service_name := ""  # the teleport point's name, the service menu's title
var _from_service := false  # the service menu is open, or its Shop / Garage, which return to it
var _car: VehicleBody3D
var _cargo: CarCargo  # the boxes strapped to the car, shown while a delivery's cargo is aboard
var _particles: WeatherField
var _recovery: RoadRecovery
var _dust: DustPuffs
var _dust_base: Color  # the gravel's dust colour outside the snow
var _pause: Node
var map: LevelMap
var minimap: LevelMinimap
var off_road_label: Label
var delivery_label: Label
var cargo_label: Label  # bottom middle while carrying cargo: its health, knocked down by the same hits the car takes
var money_label: Label  # the player's money, top right over the pause menu and the map
var banner := LevelBanner.new()
var _service_point := -1
var applied_fps_caps: Array[int] = []
var perf_stats := LevelStats.new()
var weather_ratio := 1.0  # share of each weather's particles drawn (adaptive graphics)
var adaptive: AdaptiveGraphics
var _driving := false  # true once loaded, so a half-built level never overwrites the saved spot
var _conflict_due := false  # a cloud sync conflict is waiting to be put to the player
const GROUP := &"level_view"


func _ready() -> void:
	add_to_group(GROUP)
	var path := level_path if not level_path.is_empty() else Config.data.level_path
	var t_parse := Time.get_ticks_msec()
	load_ms = {"engine_to_ready": t_parse}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	load_ms["parse"] = Time.get_ticks_msec() - t_parse
	print("level view: parse %d ms" % load_ms.parse)
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
	load_ms["built"] = Time.get_ticks_msec() - t0
	print("level view: %s built in %d ms" % [path, load_ms.built])
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
	if Save.get_setting(PARTS_KEY) is Array:  # an older save's parts were shared by every car: they stay on the one being driven
		Save.set_setting(PARTS_KEY, {Config.data.level_car_id: Save.get_setting(PARTS_KEY)})
	if String(owned.get("model_id", "")) != Config.data.level_car_id:
		owned = swapped_in(Config.data.level_car_id)
	var bought := bought_parts()
	owned["parts"] = owned.get("parts", []).filter(func(p: Dictionary) -> bool: return String(p["id"]) in bought)
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
	off_road_label = UITheme.label("")
	off_road_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(4)))
	off_road_label.visible = false
	layer.add_child(off_road_label)
	delivery_label = UITheme.label("")
	delivery_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(4)))
	delivery_label.visible = false
	layer.add_child(delivery_label)
	cargo_label = UITheme.label("")
	cargo_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(4)))
	cargo_label.visible = false
	layer.add_child(cargo_label)
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
		load_ms["prefill"] = Time.get_ticks_msec() - t_fill
		print("level view: prefill %d ms" % load_ms.prefill)
	beacons = TeleportBeacons.new()
	beacons.setup(teleport_points(), height_at)
	add_child(beacons)
	shop_beacons = TeleportBeacons.new()
	shop_beacons.setup(shop_points(), height_at, TeleportBeacons.SHOP_TINT, TeleportBeacons.SHOP_ICON, Color.WHITE)
	add_child(shop_beacons)
	nav_beam = _nav_beam()
	add_child(nav_beam)
	var shop_list: Array = level.get("shops", [])
	for i in shop_list.size():
		var built: Dictionary = _buildings.shops.get(i, {})
		if not built.is_empty():
			shop_list[i]["model"]["box"] = built.box
			park_stock(built.body, shop_list[i])
	var arrow := RouteArrow.new()
	arrow.view = self
	add_child(arrow)
	service_prompt = _build_service_prompt()
	layer.add_child(service_prompt)
	get_tree().process_frame.connect(_sync_mouse)
	get_tree().process_frame.connect(_place_service_prompt)  # fires while paused too, so menus hide it
	var money_layer := CanvasLayer.new()
	money_layer.layer = 60  # over the pause menu's and the map's dimming
	add_child(money_layer)
	money_label = UITheme.money("")
	money_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(4)))
	money_label.visible = false
	money_layer.add_child(money_label)
	get_tree().process_frame.connect(_place_money)
	add_child(banner)
	await get_tree().process_frame  # the parent is still adding its children
	var marks := _add_effects(car)
	_recovery = RoadRecovery.new()
	_recovery.name = "RoadRecovery"
	_recovery.car = car
	_recovery.streamer = self
	get_parent().add_child(_recovery)
	_recovery.reset_done.connect(func(_p: Vector2) -> void: marks.break_ribbons())
	if _pause != null:
		_pause.reset_to_track_requested.connect(func() -> void:
			if has_car() and not _wrecked:
				_recovery.reset_now())
		_pause.closed.connect(_on_pause_closed)
		_pause.extra_requested.connect(_on_extra)
	Cloud.conflict_detected.connect(func(_summary: Dictionary) -> void: _conflict_due = true)
	Cloud.profile_replaced.connect(_on_profile_replaced)
	_conflict_due = ConflictPrompt.is_blocked()  # raised before the level loaded, or left for later
	if not Platform.is_headless():  # nothing renders, so there is nothing to compile
		var t_warm := Time.get_ticks_msec()
		await _warm_up(car)
		load_ms["warm_up"] = Time.get_ticks_msec() - t_warm
		print("level view: warm-up %d ms" % load_ms.warm_up)
	load_ms["ready_at"] = Time.get_ticks_msec()  # engine-clock time the level finished loading; minus engine_to_ready is the whole load
	WorldRuntime.apply_fps_cap(applied_fps_caps, FpsSetting.resolve(), Platform.is_headless())
	if not has_car():
		_start_without_car(car)
		loaded.emit()
		return
	if _pause != null:
		_pause.set_input_enabled(true)  # the menu stays inert until its world says it has finished loading
	map.process_mode = Node.PROCESS_MODE_ALWAYS
	_driving = true
	car.damage.thermal = true  # not sooner: an overheating car would lose health behind the loading cover
	car.damage.gave_up.connect(_on_gave_up)
	car.damage.damaged.connect(_on_car_damaged)
	Save.flushing.connect(save_pose)  # window close, app pause, browser tab hidden
	var timer := Timer.new()
	timer.wait_time = POSE_SAVE_SEC  # also on a timer: stopping the game from the editor sends no close
	timer.timeout.connect(save_pose)
	add_child(timer)
	timer.start()
	adaptive = AdaptiveGraphics.new()
	add_child(adaptive)
	adaptive.setup(self)
	perf_stats.view = self
	add_child(perf_stats)
	loaded.emit()
	if _tutor_on_drive:
		_tutor_on_drive = false
		_shopped_since_drive = false
		_talk(TUTOR, NpcLines.FIRST_DRIVE)


# A character talks over the paused game; driving resumes once they're dismissed.
func _talk(portrait: String, pages: Array) -> void:
	if _pause == null:
		return
	get_tree().paused = true
	_pause.set_input_enabled(false)
	await NpcDialogue.open(self, portrait, pages).finished
	get_tree().paused = false
	_pause.set_input_enabled(true)


# Esc / Start with a shop or point menu up opens the pause menu in its place: one menu at a time.
func _input(event: InputEvent) -> void:
	if _pause == null or not _from_service or _pause.is_open() or wreck_page != null or not event.is_action_pressed("pause") or event.is_echo():
		return
	if ConfirmPopup.any_open(get_tree()) != null or not find_children("*", "NpcDialogue", false, false).is_empty():
		return
	get_viewport().set_input_as_handled()
	if store != null:
		if not has_car() or _first_buy_at >= 0:
			_pause_over_intro()
			return
		var reload := _store_dirty
		close_store()
		if reload:
			return
	else:
		_close_open_pages()
		close_service_state()
	_pause.open()


func _close_open_pages() -> void:
	for page: MenuPage in [garage, deliveries_page, service]:
		if page != null:
			CardUI.park_previews(page)
			page.get_parent().queue_free()
	garage = null
	deliveries_page = null
	service = null
	if shop != null:
		shop.queue_free()
		shop = null
		_shop_return = Callable()


func _unhandled_input(event: InputEvent) -> void:
	if _recovery != null and _pause != null and event.is_action_pressed("reset_to_road") and not event.is_echo() and _pause.is_armed() and not _wrecked:
		_recovery.reset_now()
	elif event.is_action_pressed("menu_select") and not event.is_echo() and service_at() >= 0:
		get_viewport().set_input_as_handled()
		open_service()
	elif event.is_action_pressed("menu_select") and not event.is_echo() and shop_at() >= 0:
		get_viewport().set_input_as_handled()
		open_store(shop_at())
	elif event.is_action_pressed("toggle_perf_overlay") and not event.is_echo():
		perf_stats.cycle()


func _on_extra(label: String) -> void:
	if label == "Map":
		map.open_over_pause()
	elif label in CAR_PAGES:
		if has_car():
			call(CAR_PAGES[label])
		else:
			_pause.return_from_extra()


# The map closed. Opened from the pause menu, Back returns to the menu; a teleport goes back to driving.
func _on_map_closed(teleported: bool, over_pause: bool) -> void:
	if over_pause and _pause != null:
		if teleported:
			_pause.set_input_enabled(true)
		else:
			_pause.return_from_extra()
	if teleported:
		delivery = {}


# The pause menu's Garage rows open these pages.
const CAR_PAGES := {"Garage": "open_garage", "Parts": "open_parts", "Tune car": "open_tune"}


# The pause menu's Garage: a card per owned car; picking one reloads the level with it.
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
		var driving := id == Config.data.level_car_id
		var stats := LootRules.fitted_stats(owned if driving and String(owned.get("model_id", "")) == id else swapped_in(id))  # with the parts it drives with
		if driving:
			selected = entries.size()
		entries.append({"title": String(CarLibrary.all()[i].get("name", id)), "car": i,
			"desc": CardUI.stats_line(stats["hp"], stats["mass"], stats["drive_mode"]),
			"extra": "Driving" if driving else "", "action": _drive.bind(id)})
	var cards := CardUI.card_list(garage, entries, [], selected)
	garage.add_action(UITheme.row_button("< Back", _close_garage))
	MenuNav.attach(garage, {first = cards, on_back = _close_garage})


# The service menu's Tune car: the rest-stop page's tuning sliders, applied to the car as they move and saved.
func open_tune() -> void:
	_rest_page().open_tune()


# The service menu's Parts: the upgrades, tires and drivetrain kits bought for this car, switched on or off.
func open_parts() -> void:
	var page := _rest_page()
	page.engine_cars = []
	page.open_shop()


# A shop's Engine swap: any owned car's engine fitted to the one being driven, free; Back returns to the shop.
func open_engine_swap(at: int) -> void:
	_free_store()
	_shop_return = open_store.bind(at)
	_rest_page().open_engines()


func _rest_page() -> RestStopPage:
	shop = RestStopPage.new()
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
	var back := _shop_return
	_shop_return = Callable()
	if _next_pose == null:  # set when the shop's change is reloading the level
		if back.is_valid():
			back.call()
		else:
			_pause.return_from_extra()


func _close_garage() -> void:
	CardUI.park_previews(garage)
	garage.get_parent().queue_free()
	garage = null
	_pause.return_from_extra()


# Whether the driving HUD (the minimap) shows: not under a menu, the map, the service menu or photo mode.
func hud_visible() -> bool:
	return _driving and has_car() and is_instance_valid(_car) and not get_tree().paused and not map.visible and not _from_service and _photo_cam == null


# The pointer hides while driving (as photo mode does) and shows over any menu or the map.
func pointer_hidden() -> bool:
	return hud_visible() and wreck_page == null and not Platform.is_touch()


func _sync_mouse() -> void:
	if not is_inside_tree() or _photo_cam != null:
		return
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if pointer_hidden() else Input.MOUSE_MODE_VISIBLE


func _build_service_prompt() -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UITheme.panel_box(1.0, UITheme.PANEL_PAD * 2))
	card.visible = false
	card.modulate.a = 0.0
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			_unhandled_input(_enter_press()))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_child(box)
	card.custom_minimum_size = Vector2(UITheme.FONT_SIZE * 20, UITheme.FONT_SIZE * 7)
	_prompt_kind = UITheme.label("", "dim")
	_prompt_kind.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_prompt_kind)
	_prompt_title = UITheme.label("")
	_prompt_title.add_theme_font_size_override("font_size", UITheme.FONT_SIZE * 2)
	_prompt_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_prompt_title)
	var hint := UITheme.label("Tap" if Platform.is_touch() else "Press Enter / A", "dim")
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(hint)
	return card


func _enter_press() -> InputEventAction:
	var e := InputEventAction.new()
	e.action = "menu_select"
	e.pressed = true
	return e


func _place_service_prompt() -> void:
	if not is_inside_tree():  # the tree's frame signal still fires while a scene change is removing the level
		return
	var at_shop := shop_at()
	var point := service_at()
	var want := at_shop >= 0 or point >= 0
	if want != _prompt_wanted:
		_prompt_wanted = want
		if _prompt_tween != null:
			_prompt_tween.kill()
		if want:
			service_prompt.visible = true
		_prompt_tween = create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS).set_parallel()
		_prompt_tween.tween_property(service_prompt, "modulate:a", 1.0 if want else 0.0, 0.2)
		_prompt_tween.tween_property(self, "_prompt_slide", 0.0 if want else float(UITheme.FONT_SIZE), 0.2)
		if not want:
			_prompt_tween.chain().tween_callback(func() -> void: service_prompt.visible = false)
	if want:
		_prompt_kind.text = UITheme.caps("Shop" if at_shop >= 0 else "Delivery point")
		_prompt_title.text = UITheme.caps(String(level["shops"][at_shop].get("name", "Shop")) if at_shop >= 0 else String(level["teleports"][point].get("name", "")))
	service_prompt.size = Vector2.ZERO
	service_prompt.position = ((get_viewport().get_visible_rect().size - service_prompt.size) * 0.5 + Vector2(0.0, _prompt_slide)).round()


func _place_money() -> void:
	if not is_inside_tree():
		return
	money_label.visible = map.visible or (_pause != null and _pause.is_open())
	money_label.text = "£%d" % money()
	money_label.size = Vector2.ZERO
	money_label.position = Vector2(get_viewport().get_visible_rect().size.x - money_label.size.x - UITheme.FONT_SIZE, UITheme.FONT_SIZE).round()


static func money() -> int:
	return int(Save.get_setting(MONEY_KEY, Config.data.level_start_money))


# A player owns a car once they've bought one; until then the level opens on the start shop instead of driving.
static var recording := false  # the level replay is recording a drive: always field a car

static func has_car() -> bool:
	return Benchmark.active or recording or not owned_cars().is_empty()


# What delivery `m` from teleport point `t` carries, how far it drives along the roads, and what it pays.
func delivery_info(t: Dictionary, m: Dictionary) -> Dictionary:
	return delivery_info_on(level, _bake._roads(), t, m)


# The road line delivery `m` drives, from teleport point `t` to its drop-off; empty when the drop-off isn't in the level.
static func delivery_route(lvl: Dictionary, roads: LevelData, t: Dictionary, m: Dictionary) -> PackedVector2Array:
	for o: Dictionary in lvl.get("teleports", []):
		if String(o.get("name", "")) == String(m.get("to", "")):
			return roads.route(Vector2(float(t["x"]), float(t["z"])), Vector2(float(o["x"]), float(o["z"])))
	return PackedVector2Array()


static func delivery_info_on(lvl: Dictionary, roads: LevelData, t: Dictionary, m: Dictionary) -> Dictionary:
	var line := delivery_route(lvl, roads, t, m)
	var km := 0.0
	for i in range(1, line.size()):
		km += line[i - 1].distance_to(line[i]) / 1000.0
	var cargo := cargo_of(t, m)
	var kg := float(m["kg"]) if float(m.get("kg", 0)) > 0.0 else float(CARGO.get(cargo, 0.0))
	var pay := int(m["pay"]) if float(m.get("pay", 0)) > 0.0 else roundi(km * Config.data.level_delivery_pay_per_km / 10.0) * 10
	return {"cargo": cargo, "kg": kg, "km": km, "pay": pay}


# Parks a frozen display copy of every car the shop sells, and the player doesn't own, in rows on the yard in front of it.
func park_stock(body: Node3D, sh: Dictionary) -> void:
	var have := owned_cars()
	var cars: Array[Node3D] = []
	var ids: Array[String] = []
	for it: Dictionary in sh.get("stock", []):
		var id := String(it.get("car", ""))
		var idx := CarLibrary.index_of(id)
		if idx < 0 or id in have:
			continue
		var car := CarProp.spawn(body, Scenes.car_scene(), {"index": idx, "stop_physics": true, "disable_process": true})
		car.rotation.y = PI  # a car faces -z; the road is +z
		cars.append(car)
		ids.append(id)
	var sizes: Array[Vector2] = []
	for car in cars:
		var s := CarCardPreview._visible_mesh_aabb(car, body).size
		sizes.append(Vector2(s.x, s.z))
	var spots := yard_layout(sizes, sh["model"].get("box", []))
	for i in cars.size():
		var car := cars[i]
		car.position = Vector3(spots[i].x, 0.0, spots[i].y)
		car.position.y -= CarCardPreview._visible_mesh_aabb(car, body).position.y  # wheels on the ground
		MeshUtil.merge_static(car)
		if not shop_cars.has(ids[i]):
			shop_cars[ids[i]] = []
		shop_cars[ids[i]].append(car)


# Centres (x, z) for cars of the given (width, length) sizes: rows of up to four, nose to the road, on the yard in front
# of a building `box` ([x0, x1, z0, z1, height], front = +z).
static func yard_layout(sizes: Array[Vector2], box: Array) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var cx := 0.0
	var z := 3.0
	if box.size() == 5:
		cx = (float(box[0]) + float(box[1])) * 0.5
		z = float(box[3]) + 3.0
	var gap := 0.5
	var i := 0
	while i < sizes.size():
		var row := sizes.slice(i, mini(i + 4, sizes.size()))
		var width := gap * (row.size() - 1)
		var depth := 0.0
		for sz in row:
			width += sz.x
			depth = maxf(depth, sz.y)
		var x := cx - width * 0.5
		for sz in row:
			out.append(Vector2(x + sz.x * 0.5, z + depth * 0.5))
			x += sz.x + gap
		z += depth + 1.8
		i += row.size()
	return out


# A shop building's footprint on the map, for the ground's ambient occlusion: centre, its x axis and half extents.
static func shop_box(m: Dictionary) -> Dictionary:
	var b: Array = m.get("box", [])
	if b.size() != 5:
		return {}
	var yaw := float(m.get("yaw", 0.0))
	var axis := Vector2(cos(yaw), -sin(yaw))
	var side := Vector2(sin(yaw), cos(yaw))
	var local := Vector2((b[0] + b[1]) * 0.5, (b[2] + b[3]) * 0.5)
	return {"centre": Vector2(float(m["x"]), float(m["z"])) + axis * local.x + side * local.y, "axis": axis,
		"half": Vector2((b[1] - b[0]) * 0.5, (b[3] - b[2]) * 0.5)}


func shop_points() -> Array:
	return level.get("shops", []).map(func(t: Dictionary) -> Vector2: return Vector2(float(t["x"]), float(t["z"])))


# Car `id` as it is fielded when swapped to: every part bought for it switched on.
static func swapped_in(id: String) -> Dictionary:
	var parts: Array = LootRules.parts_for({"model_id": id}).map(func(p: Dictionary) -> Dictionary: return p.merged({"on": false}))
	var bought := bought_parts(id)
	for part_id: String in bought:  # the last one bought in a slot (tires, turbo) is the one left on
		var i := parts.find_custom(func(p: Dictionary) -> bool: return String(p["id"]) == part_id)
		if i >= 0 and not LootRules.is_on(parts[i]):
			parts = LootRules.toggled(parts, i)
	return {"model_id": id, "tuning": {}, "parts": parts.filter(func(p: Dictionary) -> bool: return String(p["id"]) in bought)}


# The upgrade parts bought for car `id` (the one being driven by default): each car's parts are its own.
static func bought_parts(id: String = Config.data.level_car_id) -> Array:
	var saved: Variant = Save.get_setting(PARTS_KEY, {})
	return saved.get(id, []) if saved is Dictionary else []


# A shop's page: a card per car or part it sells, with its price; picking one buys it after a yes / no.
# `remote` is a shop picked on the map: bought there, a car waits in the garage instead of being driven away.
func open_store(i: int, remote := false) -> void:
	var s: Dictionary = level["shops"][i]
	_store_remote = remote
	_shopped_since_drive = _shopped_since_drive or not remote
	if not remote:
		_from_service = true
		get_tree().paused = true
		_pause.set_input_enabled(not has_car())  # the intro keeps Esc for the pause menu
	var layer := CanvasLayer.new()
	layer.layer = 50
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	store = CardUI.card_page(layer, {"title": String(s.get("name", "Shop")), "dim": true})
	if not remote:
		_start_orbit(shop_centre(i))
		_menu_point = Vector2(float(s["x"]), float(s["z"]))
	var have := owned_cars()
	var parts := bought_parts()
	var entries: Array = []
	for item: Dictionary in s.get("stock", []):
		var price := int(item.get("price", 0))
		if item.has("car"):
			var id := String(item["car"])
			var idx := CarLibrary.index_of(id)
			if idx < 0:
				continue
			var got := id in have
			entries.append({"title": _car_name(id), "car": idx, "desc": "£%d" % price,
				"extra": ("DRIVING" if id == Config.data.level_car_id else "OWNED") if got else "", "extra_variant": "green",
				"action": Callable() if got else _buy.bind(_car_name(id), price, _got_car.bind(id, i))})
		elif item.get("engine_swap", false):
			if has_car() and not remote:
				entries.append({"title": "Engine swap", "icon": "engine_swap", "subtitle": "Fit an owned car's engine.",
					"action": open_engine_swap.bind(i)})
		elif item.has("part") and not BoostLibrary.CATALOGUE.has(String(item["part"])):
			var fit := {"kind": "part", "id": String(item["part"])}
			if not _sellable(fit):
				continue
			var text := LootRules.card_text(fit)
			var got := String(fit["id"]) in parts
			entries.append({"title": text[0], "icon": LootRules.icon(fit), "desc": "£%d" % price, "subtitle": text[1],
				"extra": "Owned" if got else "", "extra_variant": "green",
				"action": Callable() if got else _buy.bind(text[0], price, _got_part.bind(String(fit["id"]), i))})
		elif BoostLibrary.CATALOGUE.has(String(item.get("part", ""))):
			var id := String(item["part"])
			var spec: Dictionary = BoostLibrary.CATALOGUE[id]
			var got := id in parts
			entries.append({"title": String(spec.get("label", id)), "icon": String(spec.get("icon", id)), "desc": "£%d" % price,
				"subtitle": String(spec.get("blurb", "")), "extra": "Owned" if got else "", "extra_variant": "green",
				"action": Callable() if got else _buy.bind(String(spec.get("label", id)), price, _got_part.bind(id, i))})
	var cards := CardUI.card_list(store, entries, ["£%d" % money()] if not entries.is_empty() else ["Nothing for sale"], _store_selected, not _store_rebuilt)
	_store_selected = 0
	_store_rebuilt = false
	if has_car():
		store.add_action(UITheme.row_button("Drive >" if _first_buy_at >= 0 else "< Back", close_store))
	MenuNav.attach(store, {first = cards, on_back = close_store if has_car() else _pause_over_intro})


# The intro's shop has nowhere to go back to, so Back opens the pause menu in its place, which hides the shop until it closes.
func _pause_over_intro() -> void:
	if _pause == null or store == null:
		return
	store.get_parent().visible = false
	_pause.open()


func _on_pause_closed() -> void:
	if store != null and (not has_car() or _first_buy_at >= 0):
		store.get_parent().visible = true
		get_tree().paused = true


# A tire or drivetrain kit a shop may list: a real one, and not the kit for the car's own layout.
func _sellable(part: Dictionary) -> bool:
	var pool: Array = LootRules.parts_for(owned) if has_car() else LootRules.catalogue()
	return pool.any(func(p: Dictionary) -> bool: return p["id"] == part["id"] and (LootRules.is_tire(p) or LootRules.is_drivetrain(p)))


func _car_name(id: String) -> String:
	return String(CarLibrary.by_id(id).get("name", id))


func _buy(what: String, price: int, got: Callable) -> void:
	_confirm_spend("Buy %s for £%d?" % [what, price], price, got)


func _got_car(id: String, at: int) -> void:
	for car: Node in shop_cars.get(id, []):
		car.queue_free()
	shop_cars.erase(id)
	var first := not has_car()
	var have := owned_cars()
	have.append(id)
	Save.set_setting(CARS_KEY, have)
	if _store_remote and not first:
		Config.data.level_car_id = id
		_swap_car_on_close = id
		_reopen_store(at)
		return
	if _store_remote:
		_reopen_store(at)
		return
	if first and not Config.data.level_spawn_teleport.is_empty():
		delivery = {"from": "", "to": Config.data.level_spawn_teleport}  # the sat nav leads a new player to their first delivery job
		_tutor_on_drive = true
		_greet_at_pickup = true
	if first or _first_buy_at >= 0:  # a new player keeps shopping (parts, say) and drives off when they leave the shop
		_first_buy_at = at
		Config.data.level_car_id = id
		_reopen_store(at)
		return
	_drive_bought_car(id, at)


# A bought part goes straight on the car the player is driving, and on any other car they drive later.
func _got_part(id: String, at: int) -> void:
	var all: Variant = Save.get_setting(PARTS_KEY, {})
	all = all if all is Dictionary else {}
	all[Config.data.level_car_id] = bought_parts() + [id]
	Save.set_setting(PARTS_KEY, all)
	for item: Dictionary in LootRules.parts_for(owned) if has_car() and _swap_car_on_close == "" else []:  # without a car, or with another car about to be driven, it waits for the next one
		if String(item["id"]) == id:
			owned["parts"].append(item.merged({"on": false}))
			owned["parts"] = LootRules.toggled(owned["parts"], owned["parts"].size() - 1)
			_store_dirty = true
	_reopen_store(at)


# The start with no car: the car is parked out of sight, a camera circles the start shop and its stock is open.
func _start_without_car(car: VehicleBody3D) -> void:
	car.visible = false
	car.freeze = true
	car.process_mode = Node.PROCESS_MODE_DISABLED
	if _recovery != null:
		_recovery.process_mode = Node.PROCESS_MODE_DISABLED  # it would put the parked car back on the road
	for n in ["HUD", "MobileControls", "SpeedLines"]:
		var layer := get_parent().get_node_or_null(n) as CanvasLayer
		if layer != null:
			layer.visible = false
	var at := start_shop()
	if at < 0:
		return
	car.global_position = shop_centre(at) + Vector3.DOWN * 50.0  # below the ground, so nothing streams round a car the player can't see
	_start_orbit(shop_centre(at))
	_pause.set_input_enabled(true)  # Esc opens the pause menu (and Settings) in the intro too
	await NpcDialogue.open(self, TUTOR, NpcLines.fill(NpcLines.WELCOME, money())).finished
	open_store(at)


func shop_centre(i: int) -> Vector3:
	var sh: Dictionary = level["shops"][i]
	var m: Dictionary = sh["model"] if sh.get("model") is Dictionary else sh
	return Vector3(float(m["x"]), height_at(float(m["x"]), float(m["z"])) + 2.0, float(m["z"]))


# Circle the camera slowly round `centre` (a shop, a teleport point) while its menu is up, starting from where the camera is.
func _start_orbit(centre: Vector3) -> void:
	if is_instance_valid(orbit_camera) and centre.is_equal_approx(_orbit_centre):
		return  # already circling it: a menu rebuilt over the same place keeps turning smoothly
	var cam := get_viewport().get_camera_3d()
	if cam != orbit_camera:
		_orbit_prev = cam
	if not is_instance_valid(orbit_camera):
		orbit_camera = Camera3D.new()
		orbit_camera.far = 2000.0
		add_child(orbit_camera)
		get_tree().process_frame.connect(_orbit_step)  # fires while the menu pauses the tree
	var from := cam.global_position - centre if cam != null else Vector3.BACK
	_orbit_a0 = atan2(from.x, from.z)
	_orbit_t0 = Time.get_ticks_msec()
	_orbit_centre = centre
	_orbit_step()
	orbit_camera.make_current()


func _orbit_step() -> void:
	if not is_instance_valid(orbit_camera):
		return
	var a := _orbit_a0 + (Time.get_ticks_msec() - _orbit_t0) / 1000.0 * Config.data.level_shop_orbit_rad_s
	var r: float = Config.data.level_shop_orbit_m
	orbit_camera.global_position = _orbit_centre + Vector3(sin(a), 0.4, cos(a)) * r
	orbit_camera.look_at(_orbit_centre)


func _stop_orbit() -> void:
	if not is_instance_valid(orbit_camera):
		return
	get_tree().process_frame.disconnect(_orbit_step)
	orbit_camera.queue_free()
	orbit_camera = null
	_orbit_centre = Vector3.INF
	if is_instance_valid(_orbit_prev):
		_orbit_prev.make_current()


# The shop a player with no car starts at: GameConfig.level_start_shop, else the first; -1 with no shops.
func start_shop() -> int:
	var shops: Array = level.get("shops", [])
	for i in shops.size():
		if String(shops[i].get("name", "")) == Config.data.level_start_shop:
			return i
	return 0 if not shops.is_empty() else -1


# A car just bought is driven away at once: the level reloads with it on the road by the shop, facing out of its yard.
func _drive_bought_car(id: String, at: int) -> void:
	var sh: Dictionary = level["shops"][at]
	var facing := Vector3.BACK.rotated(Vector3.UP, float(sh["model"].get("yaw", 0.0))) if sh.get("model") is Dictionary else Vector3.FORWARD
	Config.data.level_car_id = id  # the reload sees `owned` is another car and fields this one (emptying it would restore the saved old car)
	_next_pose = null
	if _bake != null:
		_next_pose = teleport_pose(Vector2(float(sh["x"]), float(sh["z"])), facing)  # right on the obelisk, facing its heading
	_free_store()
	close_service_state()
	Scenes.change_to(get_tree(), Scenes.WORLD, "Fetching your car")


func _reopen_store(at: int) -> void:
	var carousels := store.find_children("*", "CardCarousel", true, false)
	_store_selected = (carousels[0] as CardCarousel).selected_index() if not carousels.is_empty() else 0
	_store_rebuilt = true
	_free_store()
	open_store(at, _store_remote)


func _free_store() -> void:
	CardUI.park_previews(store)
	store.get_parent().queue_free()
	store = null


func close_store() -> void:
	if _first_buy_at >= 0:
		var at := _first_buy_at
		_first_buy_at = -1
		_store_dirty = false
		_drive_bought_car(Config.data.level_car_id, at)
		return
	_free_store()
	if _store_remote:
		_store_remote = false
		var swap := _swap_car_on_close
		_swap_car_on_close = ""
		if swap != "":
			_store_dirty = false
			_reload("Changing cars")
			return
	else:
		close_service_state()
	if _store_dirty:
		_store_dirty = false
		Save.set_setting(SAVED_CAR_KEY, owned.duplicate(true))
		_reload("Fitting parts")


# What a delivery carries: the level editor may name it (and set its weight and pay); otherwise it's derived from the two point names.
static func cargo_of(t: Dictionary, m: Dictionary) -> String:
	var cargo := String(m.get("cargo", ""))
	if cargo.is_empty():
		cargo = CARGO.keys()[posmod(hash(String(t.get("name", "")) + ">" + String(m.get("to", ""))), CARGO.size())]
	return cargo


# Deliveries are one-off: a finished one is remembered by this key and never offered again.
static func delivery_key(t: Dictionary, m: Dictionary) -> String:
	return "%s>%s>%s" % [t.get("name", ""), m.get("to", ""), cargo_of(t, m)]


static func done_deliveries() -> Array:
	var saved: Variant = Save.get_setting(DONE_KEY, [])
	return saved if saved is Array else []


# The deliveries still on offer at teleport point `t`.
static func offered_deliveries(t: Dictionary) -> Array:
	var done := done_deliveries()
	return t.get("deliveries", []).filter(func(m: Dictionary) -> bool: return not delivery_key(t, m) in done)


# The deliveries offered at `points`, as {t, m, km}, ordered by new_ends_first.
func _sorted_jobs(points: Array) -> Array:
	var jobs: Array = []
	for t: Dictionary in points:
		for m: Dictionary in offered_deliveries(t):
			jobs.append({"t": t, "m": m, "km": float(delivery_info(t, m)["km"])})
	return new_ends_first(jobs, map.known_teleports().map(func(o: Dictionary) -> String: return String(o.get("name", ""))))


# Deliveries ending at a teleport point not yet found (`known` holds the found names) lead the list, shortest first,
# so the list points the player at new ground; the rest keep their order.
static func new_ends_first(jobs: Array, known: Array) -> Array:
	var fresh := jobs.filter(func(j: Dictionary) -> bool: return not String(j["m"].get("to", "")) in known)
	fresh.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["km"]) < float(b["km"]))
	return fresh + jobs.filter(func(j: Dictionary) -> bool: return String(j["m"].get("to", "")) in known)


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
	if _respawning:
		return
	if _wrecked:
		_respawning = true
		var points := teleport_points()
		_car.freeze = true  # the wreck stays put while the ground at the point loads, so it can't fall as its own ground streams out
		if last_point >= 0 and last_point < points.size():
			await place_car_on(points[last_point])
		else:
			_car.reset_to(spawn_pose())
		_car.freeze = false
		_end_wreck()
		_respawning = false
	_car.damage.repair()
	_car.damage.engine_temp = 0.0
	if delivery.has("cargo_hp"):
		delivery["cargo_hp"] = 100.0


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
	return _stopped_at(teleport_points())


# The shop the car has stopped beside; -1 when none.
func shop_at() -> int:
	return _stopped_at(shop_points())


func _stopped_at(points: Array) -> int:
	if not _driving or not is_instance_valid(_car) or get_tree().paused or _pause == null or not _pause.is_armed() \
			or _car.linear_velocity.length() > Config.data.level_service_max_speed:
		return -1
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	for i in points.size():
		if p.distance_to(points[i]) <= Config.data.level_service_radius_m:
			return i
	return -1


# A delivery point's menu: its delivery jobs, started here; Back leaves.
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
	var tp: Dictionary = level["teleports"][_service_point]
	_menu_point = Vector2(float(tp["x"]), float(tp["z"]))
	_start_orbit(Vector3(float(tp["x"]), height_at(float(tp["x"]), float(tp["z"])) + 2.0, float(tp["z"])))
	var layer := CanvasLayer.new()
	layer.layer = 50
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	service = CardUI.card_page(layer, {"title": "Delivery Jobs", "dim": true})
	var t: Dictionary = level["teleports"][_service_point]
	var entries: Array = []
	for job: Dictionary in _sorted_jobs([t]):
		entries.append(_delivery_card(t, job["m"], _start_delivery_here.bind(t, job["m"])))
	var cards := CardUI.card_list(service, entries)
	service.add_action(UITheme.row_button("< Back", close_service))
	MenuNav.attach(service, {first = cards, on_back = close_service})


# The map's Deliveries button: every delivery from the teleport points found so far.
func open_deliveries() -> void:
	_open_deliveries_page("All Delivery Jobs", map.known_teleports())


func _open_deliveries_page(title: String, points: Array) -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	deliveries_page = CardUI.card_page(layer, {"title": title, "dim": true})
	var entries: Array = []
	for job: Dictionary in _sorted_jobs(points):
		entries.append(_delivery_card(job["t"], job["m"], _start_delivery_from.bind(job["t"], job["m"])))
	var header: Array = ["Find teleport points to see their deliveries"] if entries.is_empty() else []
	var cards := CardUI.card_list(deliveries_page, entries, header)
	deliveries_page.add_action(UITheme.row_button("< Back", _close_deliveries))
	MenuNav.attach(deliveries_page, {first = cards, on_back = _close_deliveries})


func _delivery_card(t: Dictionary, m: Dictionary, action: Callable) -> Dictionary:
	var info := delivery_info(t, m)
	var driving := String(delivery.get("from", "")) == String(t.get("name", "")) and String(delivery.get("to", "")) == String(m.get("to", ""))
	return {"title": String(info["cargo"]), "icon": "delivery", "desc": "£%d" % info["pay"], "subtitle": "%.1f km · %d kg" % [info["km"], info["kg"]],
		"extra": "Driving" if driving else "", "extra_variant": "gold", "action": _preview_delivery.bind(t, m, action)}


# Before a delivery starts, the map shows its route for the player to confirm: Start runs `start`, Back returns to the page.
func _preview_delivery(t: Dictionary, m: Dictionary, start: Callable) -> void:
	var page := deliveries_page if deliveries_page != null else service
	page.visible = false
	map.preview(delivery_route(level, _bake._roads(), t, m), start, func() -> void: page.visible = true)


func _free_deliveries_page() -> void:
	CardUI.park_previews(deliveries_page)
	deliveries_page.get_parent().queue_free()
	deliveries_page = null


func _close_deliveries() -> void:
	_free_deliveries_page()


# Ask before spending `cost`, then pay and run `go`; just say so when the player can't afford it.
func _confirm_spend(title: String, cost: int, go: Callable) -> void:
	var popup: ConfirmPopup
	if money() < cost:
		popup = ConfirmPopup.open(self, "Can't afford it", "That costs £%d. You have £%d." % [cost, money()], [{"label": "OK", "callback": Callable()}])
	else:
		popup = ConfirmPopup.open(self, title, "You have £%d." % money(), [{"label": "No", "callback": Callable()},
			{"label": "Yes", "callback": func() -> void:
				Save.set_setting(MONEY_KEY, money() - cost)
				go.call()}], 1, 0)
	if popup != null:
		popup.process_mode = Node.PROCESS_MODE_ALWAYS  # the map and its pages run paused


# Starts the delivery picked on the map: the car is put on its pick-up point (free), which counts as picking up, and driving resumes.
func _start_delivery_from(t: Dictionary, m: Dictionary) -> void:
	var info := delivery_info(t, m)
	delivery = {"from": String(t.get("name", "")), "to": String(m.get("to", "")), "key": delivery_key(t, m),
		"pay": int(info["pay"]), "cargo": String(info["cargo"]), "kg": float(info["kg"])}
	_free_deliveries_page()
	map.hide_for_delivery()
	await place_car_on(Vector2(float(t["x"]), float(t["z"])))
	_picked_up()
	close_service_state()


# A delivery picked at its own pick-up point's service menu: the car is already there, so it starts picked up.
func _start_delivery_here(t: Dictionary, m: Dictionary) -> void:
	var info := delivery_info(t, m)
	delivery = {"from": String(t.get("name", "")), "to": String(m.get("to", "")), "key": delivery_key(t, m), "pay": int(info["pay"]), "cargo": String(info["cargo"]), "kg": float(info["kg"])}
	close_service()
	_picked_up()


func _picked_up() -> void:
	delivery["cargo_hp"] = 100.0
	banner.show_band("Delivery started", "Take the %s to %s" % [String(delivery["cargo"]).to_lower(), delivery["to"]])


# The cargo loses the same share of its health as the car does of its HP; at 0 the delivery fails, though it can be taken again.
func _on_car_damaged(loss: float, _at: Vector3) -> void:
	if delivery.has("cargo_hp") and is_instance_valid(_car):
		delivery["cargo_hp"] = maxf(0.0, float(delivery["cargo_hp"]) - loss / _car.damage.max_hp * 100.0)
		if delivery["cargo_hp"] <= 0.0:
			banner.show_band("Cargo destroyed", "The %s didn't make it" % String(delivery["cargo"]).to_lower())
			delivery = {}


# The teleport point the sat nav leads to: the active delivery's drop-off.
static func nav_target() -> String:
	return String(delivery.get("to", ""))


func _nav_beam() -> MeshInstance3D:
	var cfg: GameConfig = Config.data
	var tube := CylinderMesh.new()
	tube.top_radius = cfg.level_nav_beam_radius_m
	tube.bottom_radius = cfg.level_nav_beam_radius_m
	tube.height = cfg.level_nav_beam_height_m
	tube.cap_top = false
	tube.cap_bottom = false
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(1.0, 0.95, 0.7, cfg.level_nav_beam_alpha)
	tube.material = mat
	var beam := MeshInstance3D.new()
	beam.mesh = tube
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.visible = false
	return beam


func _place_nav_beam() -> void:
	if nav_beam == null:
		return
	var to := nav_target()
	nav_beam.visible = false
	if to.is_empty():
		return
	var points := teleport_points()
	var tps: Array = level.get("teleports", [])
	for i in points.size():
		if String(tps[i].get("name", "")) == to:
			var p: Vector2 = points[i]
			nav_beam.position = Vector3(p.x, height_at(p.x, p.y) + Config.data.level_nav_beam_height_m * 0.5, p.y)
			nav_beam.visible = true
			return


func close_service_state() -> void:
	_stop_orbit()
	# Back on the road the car stands on the point facing its heading, so driving in nose first turns it round for free;
	# not when a reload (a car bought or swapped) places it anyway.
	if _menu_point != Vector2.INF and _next_pose == null and is_instance_valid(_car) and has_car():
		_car.reset_to(teleport_pose(_menu_point, -_car.global_transform.basis.z))
	_menu_point = Vector2.INF
	_from_service = false
	get_tree().paused = false
	_pause.set_input_enabled(true)


func _check_delivery() -> void:
	if delivery.is_empty() or not _driving or _from_service or get_tree().paused or not is_instance_valid(_car):
		return
	var points := teleport_points()
	var tps: Array = level.get("teleports", [])
	var p := Vector2(_car.global_position.x, _car.global_position.z)
	for i in points.size():
		if String(tps[i].get("name", "")) == nav_target() and p.distance_to(points[i]) <= Config.data.level_service_radius_m:
			if _greet_at_pickup and not delivery.has("cargo") and (service_at() != i or not _shopped_since_drive):
				return  # the dispatcher waits until the car has stopped there and the player has been in a shop
			_complete_delivery()
			return


func _complete_delivery() -> void:
	if not delivery.has("cargo"):
		if _greet_at_pickup:
			_greet_at_pickup = false
			_greet_at_drop = true
			_talk(DISPATCHER, NpcLines.fill(NpcLines.DISPATCHER_GREETING, _offered_at(delivery["to"])))
		delivery = {}
		return
	var pay := int(delivery.get("pay", 0))
	Save.set_setting(MONEY_KEY, money() + pay)
	if delivery.has("key"):
		Save.set_setting(DONE_KEY, done_deliveries() + [delivery["key"]])
	if _greet_at_drop:
		_greet_at_drop = false
		_talk(RECIPIENT, NpcLines.fill(NpcLines.RECIPIENT_THANKS, _offered_at(delivery["to"])))
	delivery = {}
	banner.show_band("Delivery complete", "+£%d" % pay)


# How many deliveries the teleport point called `point` still has on offer.
func _offered_at(point: String) -> int:
	var here: Array = level.get("teleports", []).filter(func(t: Dictionary) -> bool: return t.get("name", "") == point)
	return offered_deliveries(here[0]).size() if not here.is_empty() else 0


# The cars the player may drive: the saved list, or the authored start car and the current one for a save without it.
static func sanitise_cars(saved: Variant) -> Array:
	var out: Array = []
	if not saved is Array:
		return out  # a new player owns no car
	for id: Variant in saved:
		if CarLibrary.index_of(String(id)) >= 0 and not String(id) in out:
			out.append(String(id))
	return out


static func owned_cars() -> Array:
	return sanitise_cars(Save.get_setting(CARS_KEY))


func close_service() -> void:
	_free_service()
	close_service_state()


func _free_service() -> void:
	service.get_parent().queue_free()
	service = null


# Wipe all progress: forget the level's car, parts, parked spot and explored map, which live in the
# save's device settings (kept by Save.reset_new_game), and stop a running level saving them again as it closes.
static func forget_progress() -> void:
	for key in [SAVED_CAR_KEY, SAVED_POSE_KEY, LevelMap.SEEN_KEY, CARS_KEY, MONEY_KEY, PARTS_KEY, DONE_KEY]:
		Save.erase_setting(key)
	owned = {}
	delivery = {}
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
func saved_pose(saved: Variant, level_file: String, fallback: Transform3D) -> Transform3D:
	if not saved is Dictionary or saved.get("level") != level_file:
		return fallback
	var x := float(saved.get("x", 0.0))
	var z := float(saved.get("z", 0.0))
	return Transform3D(Basis(Vector3.UP, float(saved.get("yaw", 0.0))), Vector3(x, height_at(x, z) + 1.0, z))


func _drive(id: String) -> void:
	Config.data.level_car_id = id
	_reload("Changing cars")


func _reload(title: String) -> void:
	if adaptive != null and adaptive.controller.enabled:
		adaptive.save()
		adaptive.controller.enabled = false  # loading hitches aren't this device's normal frames
	_next_pose = _car.global_transform
	Scenes.change_to(get_tree(), Scenes.WORLD, title)


# The car's driving effects (tyre marks, dust, lamps, flames); returns the tyre marks.
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
	marks.setup(car, self)
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
	_cargo = CarCargo.build(Config.data.level_car_id)
	if _cargo != null:
		car.add_child(_cargo)
	if _spectators != null:
		_spectators.car = car
	LevelWeather.attach(self, func() -> float: return _streamer.snow_at(car.global_position.x, car.global_position.z) if _streamer != null else 0.0)
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
		if _particles != null:
			_particles.amount_ratio = weather_ratio
	if adaptive != null:
		adaptive.disturbed()
	if HeadlightCone.has_headlights(cfg):
		set_process(true)
	else:
		HeadlightCone.reset()


## A node beside the level in its scene (the effects, the post-process view), or null.
func effect(path: String) -> Node:
	return get_parent().get_node_or_null(path) if get_parent() != null else null


## How far the fog lets the camera see right now, in metres (0 when there is no fog).
func fog_end_m() -> float:
	var env := effect("WorldEnvironment") as WorldEnvironment
	return env.environment.fog_depth_end if env != null and env.environment != null and env.environment.fog_enabled else 0.0


func set_weather_ratio(f: float) -> void:
	weather_ratio = clampf(f, 0.0, 1.0)
	if is_instance_valid(_particles):
		_particles.amount_ratio = weather_ratio


## Renders the 3D world at this share of the screen's resolution (the UI stays sharp).
func set_render_scale(f: float) -> void:
	var view := effect("PostProcess/View") as SubViewport
	if view != null:
		view.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		view.scaling_3d_scale = f


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


# The snow biome's handling follows the ground under the car:
# snow grip, deep-snow drag (car.gd feathers it per wheel off the road), and the snow side of the tyre compound rule.
func _physics_process(dt: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(dt)
	PerfLog.track(&"level_view_physics", Time.get_ticks_usec() - __t)


func _timed_physics_process(dt: float) -> void:
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
	if Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	save_pose()
	set_snow(Config.data, 0.0)
	HeadlightCone.reset()
	LevelWeather.reset()
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
		if not _save_path.is_empty() and OS.has_feature("threads") and not Platform.is_headless():
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
	load_ms["bake_load"] = t1 - t0
	load_ms["decode"] = Time.get_ticks_msec() - t1
	print("level view: bake load %d ms, decode %d ms" % [load_ms.bake_load, load_ms.decode])
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
	load_ms["tree_setup"] = Time.get_ticks_msec() - t_trees
	print("level view: tree setup %d ms" % load_ms.tree_setup)
	_buildings = LevelBuildings.new()
	_buildings.name = "Buildings"
	add_child(_buildings)
	_buildings.setup(_save_path, height_at)
	var fences := LevelFences.new()
	fences.name = "Fences"
	add_child(fences)
	fences.setup(d.get("fences", []), _bake._roads(), _bake.height)
	var ao := LevelAO.new(_bake.size, _bake.frame_n)
	var cfg: GameConfig = Config.data
	ao.stamp_trees(_bake.tree_xf, cfg.level_ao_tree_radius_scale)
	for b: Dictionary in _buildings.boxes:
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
	_spectators.setup(d.get("spectators", []), self, _bake, _buildings)
	rallies = LevelRallies.new()
	rallies.name = "Rallies"
	add_child(rallies)
	rallies.setup(d.get("rallies", []), height_at, _spectators, _buildings)

# A roadside timber pile from the save's `logPiles` ({x, z}), sawn ends facing the nearest road, kept clear of its surface.
func _log_pile(p: Dictionary, pile_seed: int) -> StaticBody3D:
	var at := Vector2(p.x, p.z)
	var road := road_pose(at, Vector3.FORWARD)
	var rows := 4 + pile_seed % 3
	var base := 7 + pile_seed % 4
	var sections := 1 + pile_seed % 2
	var away := at - Vector2(road.origin.x, road.origin.z)
	var clear := 7.0
	if away.length() < clear:
		at = Vector2(road.origin.x, road.origin.z) + away.normalized() * clear
	var radius := 0.16
	var mesh := LogPile.build(pile_seed + 1, pile_seed % 2, rows, base, 4.0, radius, sections)
	var body := StaticBody3D.new()
	body.name = "LogPile%d" % pile_seed
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


# A sync conflict found in the background (at boot, or on coming back to the app) is put to the
# player as soon as they are driving with nothing else on screen.
func _offer_conflict() -> void:
	if not _driving or _pause == null or get_tree().paused or not _pause.is_armed() \
			or ConfirmPopup.any_open(get_tree()) != null:
		return
	_conflict_due = false
	get_tree().paused = true
	_pause.set_input_enabled(false)
	var done := func() -> void:
		if not is_inside_tree():
			return  # taking the cloud copy reloaded the level
		get_tree().paused = false
		_pause.set_input_enabled(true)
	if ConflictPrompt.open(_pause, done) == null:
		done.call()


# A cloud download replaced the save (the player chose the cloud copy, or signed in on a new
# device): load the level again on it.
func _on_profile_replaced() -> void:
	_driving = false  # so leaving doesn't write this device's spot over the downloaded one
	Scenes.change_to(get_tree(), Scenes.WORLD)


func _process(_dt: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(_dt)
	PerfLog.track(&"level_view", Time.get_ticks_usec() - __t)


func _timed_process(_dt: float) -> void:
	if _conflict_due and not Benchmark.active:  # the benchmark's profile is a throwaway
		_offer_conflict()
	var __t := Time.get_ticks_usec()
	_check_delivery()
	PerfLog.track(&"level_view_delivery", Time.get_ticks_usec() - __t)
	__t = Time.get_ticks_usec()
	_place_nav_beam()
	PerfLog.track(&"level_view_nav_beam", Time.get_ticks_usec() - __t)
	if delivery_label != null:
		delivery_label.text = "" if delivery.is_empty() else "Deliver %s to %s" % [delivery["cargo"], nav_target()] \
			if delivery.has("cargo") else "Drive to %s" % nav_target()
		delivery_label.visible = not delivery.is_empty()
		delivery_label.size = Vector2.ZERO
		var y := float(UITheme.FONT_SIZE)
		if off_road_label != null and off_road_label.visible:
			y += off_road_label.size.y + UITheme.FONT_SIZE * 0.5
		delivery_label.position = Vector2(roundf((get_viewport().get_visible_rect().size.x - delivery_label.size.x) * 0.5), roundf(y))
	if is_instance_valid(_car):
		_car.mass = _car.config.mass + (float(delivery.get("kg", 0.0)) if delivery.has("cargo_hp") else 0.0)
	if is_instance_valid(_cargo):
		_cargo.visible = delivery.has("cargo_hp")
	if cargo_label != null:
		cargo_label.visible = delivery.has("cargo_hp")
		cargo_label.text = "Cargo %d%%" % ceili(float(delivery.get("cargo_hp", 0.0)))
		cargo_label.size = Vector2.ZERO
		var screen := get_viewport().get_visible_rect().size
		var r := Rect2(roundf((screen.x - cargo_label.size.x) * 0.5), screen.y - UITheme.FONT_SIZE - cargo_label.size.y, cargo_label.size.x, cargo_label.size.y)
		var controls := get_parent().get_node_or_null("MobileControls") as MobileControls
		if controls != null:
			for b in controls.button_rects():
				if b.intersects(r.grow(UITheme.FONT_SIZE)):
					r.position.y = minf(r.position.y, b.position.y - UITheme.FONT_SIZE - r.size.y)
		cargo_label.position = (r.position + DisplayStretch.safe_shift(Vector2(0.5, 1.0))).round()
	if _recovery != null:
		off_road_label.text = off_road_text(_recovery.off_road_seconds())
		off_road_label.visible = not off_road_label.text.is_empty()
		off_road_label.size = Vector2.ZERO
		off_road_label.position = Vector2(roundf((get_viewport().get_visible_rect().size.x - off_road_label.size.x) * 0.5), UITheme.FONT_SIZE)
	if _car != null and HeadlightCone.has_headlights(Config.data):
		HeadlightCone.push(Config.data, _car.global_transform, _car.half_width() * 2.0 if _car.has_method("half_width") else 1.8)
	if _photo_cam == null:
		__t = Time.get_ticks_usec()
		_update_view(get_viewport().get_camera_3d(), false)
		PerfLog.track(&"level_view_update_view", Time.get_ticks_usec() - __t)


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
	var weather := get_parent().get_node_or_null("LevelWeather") as LevelWeather
	# Only dry weather's haze is pushed out to the render distance; every other weather keeps its fog.
	if env != null and (weather == null or weather.shown() in ["", WeatherLibrary.DEFAULT_ID]):
		env.environment.fog_depth_end = maxf(cfg.level_fog_end_m, cfg.photo_render_tree_m)
	_trees.set_draw_override(cfg.photo_render_tree_m)
	_streamer.cover.set_reach_override(cfg.photo_render_cover_touch_m if Platform.is_touch() else cfg.photo_render_cover_m)
	_streamer.full_detail = true
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
	_streamer.full_detail = false
	var env := get_parent().get_node_or_null("WorldEnvironment") as WorldEnvironment
	if env != null:
		var weather := get_parent().get_node_or_null("LevelWeather") as LevelWeather
		env.environment.fog_depth_end = weather.fog_end() if weather != null else cfg.level_fog_end_m
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
	for t: Dictionary in level.get("teleports", []) + level.get("shops", []):
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

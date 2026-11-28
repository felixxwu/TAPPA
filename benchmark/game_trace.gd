class_name GameTrace
extends RefCounted
# Docs: features/benchmark.md ("Game-state event log") — update in the same change as this file.
# Tests: tests/headless/test_game_trace.gd — extend in the same change.
# The replay's game-state event log: each tick `read` takes a cheap snapshot of the game's state, `diff`
# turns two snapshots into events ({tick, kind, ...}), and two runs (or Godot and Rust) compare the events exactly.

const WALL_CLOCK_KEYS := ["created_utc", "updated_utc"]  # stamped from the real clock, so they differ every run

static var _beeps: Array = []


# Starts logging every Audio.play_beep; the beeps land in the next `read`.
static func listen() -> void:
	_beeps.clear()
	AudioManager.on_beep = func(f: float, d: float, v: float) -> void: _beeps.append({"hz": f, "sec": d, "db": v})


static func stop() -> void:
	AudioManager.on_beep = Callable()
	_beeps.clear()


# The game state `diff` compares, read from the level view and the driven car.
static func read(view: LevelView, car: Node) -> Dictionary:
	var weather := view.get_parent().get_node_or_null("LevelWeather") as LevelWeather
	var grid := view.map.discovery.grid if view.map != null and view.map.discovery != null else PackedByteArray()
	var md5 := HashingContext.new()
	md5.start(HashingContext.HASH_MD5)
	if not grid.is_empty():
		md5.update(grid)
	var parts: Variant = Save.get_setting(LevelView.PARTS_KEY, {})
	var now := {
		"money": LevelView.money(),
		"delivery": LevelView.delivery.duplicate(),
		"done": LevelView.done_deliveries().duplicate(),
		"cars": LevelView.owned_cars(),
		"parts": parts.duplicate(true) if parts is Dictionary else {},
		"weather": weather.shown() if weather != null else "",
		"weather_setting": str(Config.data.weather),
		"discovered": grid.size() - grid.count(0),
		"discovery_hash": md5.finish().hex_encode(),
		"rally": LevelRallies.active,
		"beeps": _beeps.duplicate(),
	}
	_beeps.clear()
	if is_instance_valid(car) and car.get("damage") != null:
		var engine: Variant = car.drivetrain.engine
		now.merge({
			"hp": car.damage.hp,
			"engine_temp": car.damage.engine_temp,
			"wrecked": car.damage._gave_up,
			"engine_sfx": {"bov": engine.bov_event, "nitrous": engine.nitrous_event, "emptied": engine.nitrous_emptied,
				"misfires": engine.misfire_count, "limiter_cuts": engine.limiter_cut_count},
		})
	return now


# The events between snapshot `prev` and `now`, in a fixed order so two runs list them identically.
static func diff(prev: Dictionary, now: Dictionary, tick: int) -> Array:
	var out: Array = []
	var add := func(kind: String, data: Dictionary) -> void: out.append({"tick": tick, "kind": kind}.merged(data))
	if now.get("money") != prev.get("money"):
		add.call("money", {"from": prev.get("money"), "to": now.get("money")})
	var d0: Dictionary = prev.get("delivery", {})
	var d1: Dictionary = now.get("delivery", {})
	if d1.get("key", d1.get("to")) != d0.get("key", d0.get("to")) and not d1.is_empty():
		add.call("delivery_started", {"to": d1.get("to", ""), "key": d1.get("key", ""), "pay": d1.get("pay", 0)})
	if d1.has("cargo_hp") and (not d0.has("cargo_hp") or d1.get("key") != d0.get("key")):
		add.call("picked_up", {"key": d1.get("key", "")})
	var delivered := _added(prev.get("done", []), now.get("done", []))
	for key: Variant in delivered:
		add.call("delivered", {"key": key})
	if d1.is_empty() and not d0.is_empty() and delivered.is_empty():
		add.call("delivery_dropped", {"key": d0.get("key", "")})
	for id: Variant in _added(prev.get("cars", []), now.get("cars", [])):
		add.call("bought_car", {"id": id})
	var p0: Dictionary = prev.get("parts", {})
	var p1: Dictionary = now.get("parts", {})
	var car_ids := p1.keys()
	car_ids.sort()
	for car_id: Variant in car_ids:
		for id: Variant in _added(p0.get(car_id, []), p1[car_id]):
			add.call("bought_part", {"car": car_id, "id": id})
	if now.get("weather") != prev.get("weather") or now.get("weather_setting") != prev.get("weather_setting"):
		add.call("weather", {"shown": now.get("weather"), "setting": now.get("weather_setting")})
	if now.get("discovery_hash") != prev.get("discovery_hash"):
		add.call("discovered", {"count": now.get("discovered"), "hash": now.get("discovery_hash")})
	if now.get("rally") != prev.get("rally"):
		add.call("rally", {"name": now.get("rally")})
	if now.get("hp") != prev.get("hp"):
		add.call("hp", {"hp": now.get("hp")})
	if now.get("engine_temp") != prev.get("engine_temp"):
		add.call("engine_temp", {"c": now.get("engine_temp")})
	if now.get("wrecked", false) and not prev.get("wrecked", false):
		add.call("wrecked", {})
	for beep: Dictionary in now.get("beeps", []):
		add.call("beep", beep)
	var s0: Dictionary = prev.get("engine_sfx", {})
	var s1: Dictionary = now.get("engine_sfx", {})
	if s1.get("bov", false) or s1.get("nitrous", false) or s1.get("emptied", false) \
			or s1.get("misfires") != s0.get("misfires") or s1.get("limiter_cuts") != s0.get("limiter_cuts"):
		add.call("engine_sfx", s1)
	return out


# The tick's audio row: the music director's state and every bus's volume (null for a bus not created yet).
static func audio_row(tick: int) -> Dictionary:
	var buses := {}
	for bus: StringName in [AudioBuses.MASTER, AudioBuses.MUSIC, AudioBuses.ENGINE, AudioBuses.SFX]:
		var idx := AudioServer.get_bus_index(bus)
		buses[String(bus)] = AudioServer.get_bus_volume_db(idx) if idx >= 0 else null
	var music := (Engine.get_main_loop() as SceneTree).root.get_node_or_null("Music") as MusicDirector
	return {"tick": tick, "music": music.trace_state() if music != null else {}, "buses": buses}


# The save at the end of a run, minus the keys stamped from the real clock.
static func final_save(profile: Dictionary = Save.profile) -> Dictionary:
	var out := profile.duplicate(true)
	for key: String in WALL_CLOCK_KEYS:
		out.erase(key)
	return out


# Runs one scripted step ({tick, do, args}) through the function the matching menu button calls.
# Shop items and deliveries are named by their index in the level file, not by catalogue id, so the catalogue can change.
static func act(view: LevelView, car: Node, step: Dictionary) -> void:
	var args: Dictionary = step.get("args", {})
	match String(step.get("do", "")):
		"start_delivery":
			# The handler closes the jobs page it was pressed on, so open it; no _menu_point, so the car stays put.
			view._service_point = int(args["teleport"])
			view._from_service = true
			view.open_service()
			view._menu_point = Vector2.INF
			var t: Dictionary = view.level["teleports"][int(args["teleport"])]
			view._start_delivery_here(t, t["deliveries"][int(args["delivery"])])
		"buy_part":
			var at := int(args["shop"])
			_open_store(view, at)
			view._got_part(String(view.level["shops"][at]["stock"][int(args["item"])]["part"]), at)
		"buy_car":
			var at := int(args["shop"])
			_open_store(view, at)
			view._got_car(String(view.level["shops"][at]["stock"][int(args["item"])]["car"]), at)
		"set_rally":
			LevelRallies.active = String(args["name"])
			view.rallies.show_active()
		"money":
			Save.set_setting(LevelView.MONEY_KEY, int(args["amount"]))
		"wreck":
			car.damage.apply_loss(float(args["hp"]))
		var other:
			push_error("GameTrace: unknown scripted action '%s'" % other)


# The buy handlers rebuild the open shop page, so one must be open: the map's remote shop, which doesn't pause the
# game; it stays open, since closing it after a car purchase reloads the level.
static func _open_store(view: LevelView, at: int) -> void:
	if view.store == null:
		view.open_store(at, true)


static func _added(before: Array, after: Array) -> Array:
	return after.filter(func(x: Variant) -> bool: return not x in before)

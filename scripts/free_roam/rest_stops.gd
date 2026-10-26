class_name RestStops
extends Node
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd — extend in the same change.
# The rest stops as gameplay: Dark Souls bonfires (todo/2026-10-19-free-roam-pivot.md decision 9).
#   * Driving past a rest stop — onto its pad or just along the road beside it, at any speed —
#     LIGHTS it, makes it the respawn point and fully HEALS the car (`healed`).
#   * Pressing menu_select (Enter / gamepad A) there, at any speed, opens the rest-stop
#     page (`opened`); the minimap shows the prompt (`prompt_site`), which a touch player taps.
#   * When the car gives up (DamageModel.gave_up: 0 HP), the engine cuts out (EngineSim.killed: silent,
#     no drive) and the car rolls on with no controls; wreck_page_delay_s later `wrecked` opens the wreck page. its Respawn puts the car back at the last lit rest stop, fully repaired with a cold engine (`respawned`, carrying where the wreck was).
#   * Travel teleports to any lit rest stop. Both moves stream the destination in first
#     (TerrainStreamer.prefill_at): the one acceptable "load".
# Rest stop i is site i of TerrainStreamer.sites (RoadSites, kind REST); spawn is site 0, lit
# from the start.

signal lit(site: int)
signal opened(site: int)
# The car gave up (0 HP): the host shows the wreck page, whose Continue calls respawn().
signal wrecked
signal respawned(site: int, wreck_pos: Vector3)
signal travelled(site: int)
signal respawn_point_changed(site: int)
# The car was moved by a travel or a respawn, to this XZ (listeners reset their swept checks).
signal car_teleported_to(p: Vector2)
# The car drove past rest stop `site` and was fully healed.
signal healed(site: int)

@export var streamer: TerrainStreamer
@export var car: VehicleBody3D
# Disarmed while the rest-stop page or a respawn is on screen, so pause can't stack over it.
@export var pause_menu: PauseMenu

var lit_sites := {}  # site -> true
var last_site := 0:
	set(v):
		if v != last_site:
			last_site = v
			respawn_point_changed.emit(v)

var _on_site := -1
var _last_p := Vector2(INF, INF)  # the car's position last step, for the swept check
var _primed := false  # false until the first step has noted where the car was spawned
# Between giving up and the respawn: the car coasts on with no controls and rest stops ignore it.
var is_wrecked := false
var _wreck_page_in := -1.0  # seconds until `wrecked` fires; < 0 once it has (or with no wreck)


func _ready() -> void:
	lit_sites[0] = true
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).gave_up.connect(_on_gave_up)


# Seed from a saved world (WorldSession): which stops are lit and where to respawn.
func restore(lit_list: Array, last: int) -> void:
	lit_sites = {0: true}
	for site in lit_list:
		lit_sites[int(site)] = true
	last_site = last if lit_sites.has(last) else 0


func is_lit(site: int) -> bool:
	return lit_sites.has(site)


# The rest stop the car is at — on its pad or on the road beside it — or -1.
func rest_at(p: Vector2) -> int:
	return rest_reached(p, p)


# The rest stop the car's travel from `a` to `b` passed, or -1 (swept, so speed can't skip one).
func rest_reached(a: Vector2, b: Vector2) -> int:
	var sites := streamer.sites
	return sites.reached(a, b, RoadSites.road_margin(streamer.settings),
		func(i: int) -> bool: return sites.kind[i] == RoadSites.Kind.REST)


# The car was moved to `p` by something other than driving (a respawn, travel, R reset): the next
# step must not sweep from where it was. (Car.reset_to is queued, so the position is passed in.)
func car_teleported(p: Vector2) -> void:
	_last_p = p


func _physics_process(delta: float) -> void:
	if car == null or streamer == null:
		return
	step(delta)


# Driving past a rest stop (on its pad or the road beside it, at any speed) lights it, makes it
# the respawn point and fully heals the car.
func step(delta: float) -> void:
	if is_wrecked:
		if _wreck_page_in >= 0.0:
			_wreck_page_in -= delta
			if _wreck_page_in <= 0.0:
				_wreck_page_in = -1.0
				wrecked.emit()
		return
	var p := Vector2(car.global_position.x, car.global_position.z)
	if not _primed:
		# The first step after the scene loads (a new game, Continue, or the reload after a parts or
		# car change) finds the car wherever it was spawned: it has already arrived there, not passed.
		_primed = true
		_last_p = p
		_on_site = rest_at(p)
		return
	var from := _last_p if _last_p.distance_to(p) < 100.0 else p  # a teleport isn't a drive past
	_last_p = p
	var i := rest_reached(from, p)
	if i != _on_site:
		_on_site = i
		if i >= 0:
			_pass(i)
	if i >= 0:
		last_site = i


# The rest stop whose page menu_select would open now, or -1.
func prompt_site() -> int:
	if is_wrecked or car == null:
		return -1
	return _on_site


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu_select") and open_here():
		get_viewport().set_input_as_handled()


# Opens the page of the rest stop the car is at (menu_select, or a tap on the minimap's prompt).
func open_here() -> bool:
	if prompt_site() < 0:
		return false
	opened.emit(_on_site)
	return true


# The car reached rest stop `i`: light it (the first time) and heal the car fully.
func _pass(i: int) -> void:
	if not lit_sites.has(i):
		lit_sites[i] = true
		streamer.refresh_site_marker(i)
		lit.emit(i)
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).repair(Config.data)
	healed.emit(i)


# Where the car is put at rest stop `site`: on its road beside the pad, facing along the road.
# At spawn that is a little way down the road out, facing away from the cabin behind it.
func pose_at(site: int) -> Transform3D:
	var sites := streamer.sites
	var a := sites.anchor[site]
	var d := sites.dir[site]
	if site == 0:
		return RoadRecovery.road_pose(streamer, a + d * Config.data.spawn_ahead_m, Vector3(d.x, 0.0, d.y))
	if d == Vector2.ZERO:
		return RoadRecovery.road_pose(streamer, a, Vector3.FORWARD)
	var y := streamer.height_at(a.x, a.y) + 1.0
	return Transform3D(Basis.looking_at(Vector3(d.x, 0.0, d.y), Vector3.UP), Vector3(a.x, y, a.y))


# Move the car to rest stop `site` (lit or not — callers check), streaming its ground in first.
func move_car_to(site: int) -> void:
	var pose := pose_at(site)
	streamer.prefill_at(Vector2(pose.origin.x, pose.origin.z))
	pose = pose_at(site)  # the ground is loaded now, so the height is the drawn one
	car.reset_to(pose)
	_last_p = Vector2(pose.origin.x, pose.origin.z)
	car_teleported_to.emit(_last_p)  # the loot director's sweep too
	last_site = site
	_on_site = site


func travel_to(site: int) -> bool:
	if is_wrecked or not lit_sites.has(site):
		return false
	move_car_to(site)
	(car.damage as DamageModel).repair(Config.data)
	travelled.emit(site)
	return true


func _on_gave_up() -> void:
	is_wrecked = true
	_set_driverless(true)
	_set_engine_killed(true)
	_wreck_page_in = Config.data.wreck_page_delay_s


# Scripted control with every input at zero: the car rolls on where it was heading.
func _set_driverless(on: bool) -> void:
	car.set("ai_throttle", 0.0)
	car.set("ai_steer", 0.0)
	car.set("ai_handbrake", false)
	car.set("ai_controlled", on)


# The engine cuts out completely: no drive, no sound (EngineSim.killed).
func _set_engine_killed(on: bool) -> void:
	var dt = car.get("drivetrain")
	if dt != null and dt.engine != null:
		dt.engine.killed = on


func respawn() -> void:
	if is_wrecked:
		is_wrecked = false
		_wreck_page_in = -1.0
		_set_driverless(false)
		_set_engine_killed(false)
	var wreck := car.global_position
	move_car_to(last_site)
	var dmg := car.damage as DamageModel
	dmg.repair(Config.data)
	# A respawn is a fresh car, so it starts cold; a rest-stop repair (_pass) keeps the heat.
	dmg.engine_temp = 0.0
	respawned.emit(last_site, wreck)


# Lit rest stops other than `here`, nearest first: what the travel list offers.
func travel_targets(here: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for k: int in lit_sites.keys():
		if k != here:
			out.append(k)
	var origin := streamer.sites.pos[here] if here >= 0 else Vector2(car.global_position.x, car.global_position.z)
	var arr := Array(out)
	arr.sort_custom(func(a: int, b: int) -> bool:
		return streamer.sites.pos[a].distance_squared_to(origin) < streamer.sites.pos[b].distance_squared_to(origin))
	return PackedInt32Array(arr)


# A rest stop's display name: its number and its biome.
func name_of(site: int) -> String:
	if site == 0:
		return "Home"
	var region := RegionLibrary.by_id(BiomeDirector.region_of(streamer.settings, streamer.sites.ring[site]))
	return "Checkpoint %d · %s" % [site, String(region.get("name", ""))]

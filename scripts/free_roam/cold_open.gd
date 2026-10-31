class_name ColdOpen
extends Node
# Docs: features/free-roam.md (Cold open) — update in the same change as this file.
# Tests: tests/headless/test_cold_open.gd — extend in the same change.
# A first-time player's first minute (todo/2026-10-30-cold-open.md): no title screen. They start
# mid-drive at night, in the chase camera, a couple of hundred metres before the rest stop nearest
# spawn (pick_start), with the cooling already gone and the engine cold (its gauge climbs on the way). The cabin's lamp
# post marks the goal, and past it the road carries on. A health floor (DamageModel.min_hp) means
# the car limps but never gives up. Reaching the cabin lights it as usual, clears the night to dry
# weather, and then opens the camera and control options (free_roam.gd → show_options). The world
# starts with enough money to buy any other starter car there (`new_world`; Felix chose money up front
# over a coin trail, 2026-10-31).
#
# free_roam.gd adds this node only when `due()`, calls `begin()` before the car is placed (it returns
# the start pose) and `start()` when the player gets control. Nothing else grows a cold-open branch.

signal finished

var streamer: TerrainStreamer
var car: VehicleBody3D
var rest_stops: RestStops
var biome: BiomeDirector
var minimap: MiniMap
var mobile: MobileControls
var checkpoint_banner: CheckpointBanner
# Called once the "Checkpoint reached" band is gone: opens the camera and control options.
var show_options := func() -> void: pass

var start_spot: Dictionary = {}  # pick_start's answer
var running := false
var done := false
var _hinting := false
var _dry_slot := -1
var _options_in := -1.0


# Whether this boot is a first-time player's cold open.
static func due() -> bool:
	return WorldSession.cold_open_pending() and not Benchmark.active \
		and not "--auto-drive" in OS.get_cmdline_user_args()


# The car a first-time world starts with: FreeRoamSettings.cold_open_car_id, or the first starter car
# if that id isn't in the catalogue.
static func car_id(s: FreeRoamSettings) -> String:
	if s != null and CarLibrary.index_of(s.cold_open_car_id) >= 0:
		return s.cold_open_car_id
	return LootRules.starter_cars()[0]


# A first-time player's world (title_boot.gd): the cold-open car, pending, and
# FreeRoamSettings.cold_open_start_money (with the road coin on the way, about enough to swap it for
# another starter car at the first cabin).
static func new_world(world_seed: int, s: FreeRoamSettings) -> void:
	var model := car_id(s)
	WorldSession.new_world(world_seed, model)
	WorldSession.fresh = true
	WorldSession.set_cold_open_pending(true)
	WorldSession.set_money(WorldSession.money() + s.cold_open_start_money)


# The cold open's opening lines (FreeRoamSettings.cold_open_story), with the active car's name in.
static func story_lines(s: FreeRoamSettings) -> PackedStringArray:
	var car_name := String(CarLibrary.by_id(String(WorldSession.active_car().get("model_id", ""))).get("name", "car"))
	var out := PackedStringArray()
	for line in s.cold_open_story:
		out.append(line % car_name if "%s" in line else line)
	return out


# Where the cold open starts, and which cabin it drives to. The goal is the roadside rest stop
# nearest spawn (not spawn's own cabin, which stands across the road's end, so arriving there meant
# turning round to carry on; Felix, 2026-10-31) whose road leaves room for the drive before it. The
# start is on that road, back from the cabin (towards spawn when there's room that way), as far
# out (up to cold_open_max_distance_m) as the lamp post (`lantern(site)`) is still in view, but never
# nearer than cold_open_min_distance_m: past the cabin the road just carries on. In view means the
# road from the start to the cabin keeps within cold_open_view_corridor_m of the straight line
# between them (so no bend or roadside tree hides it) and the ground stays under the sight line. The
# roads wiggle, so that's often short; the lamp then comes into view on the last stretch, and
# the road itself leads the way. The start is also always at least cold_open_coin_lead_m before a
# road coin (a LOOT site on the way), so the player picks one up before the cabin (Felix,
# 2026-10-31): a road with a coin on it is preferred, and the start moves back past the coin when
# the lamp's view alone would put it nearer. `height(x, z)` is the ground height.
# Returns {"site": int, "pos": Vector2, "dist": float, "path": PackedVector2Array from the start to
# the cabin's road point}, or {} when the island has no roadside rest stop.
static func pick_start(net: RoadNetwork, sites: RoadSites, height: Callable, lantern: Callable, s: FreeRoamSettings) -> Dictionary:
	var goals: Array[int] = []
	for g: int in sites.of_kind(RoadSites.Kind.REST):
		if g != 0 and sites.anchor[g] != sites.pos[g] and sites.edge[g] >= 0:
			goals.append(g)
	goals.sort_custom(func(a: int, b: int) -> bool: return sites.anchor[a].length() < sites.anchor[b].length())
	var roomiest: Dictionary = {}
	var roomy: Dictionary = {}  # the first with room for the drive, coin or not
	for g in goals:
		for back in _roads_back(net, sites, g):
			var room := _length(back)
			if roomiest.is_empty() or room > float(roomiest["room"]):
				roomiest = {"site": g, "back": back, "room": room}
			if room < s.cold_open_min_distance_m:
				continue
			if roomy.is_empty():
				roomy = {"site": g, "back": back}
			var need := first_coin(back, sites, sites.edge[g]) + s.cold_open_coin_lead_m
			if need <= room - 1.0:
				return _start_on(back, g, height, lantern.call(g), s, need)
	var pick := roomy if not roomy.is_empty() else roomiest
	if pick.is_empty():
		return {}
	return _start_on(pick["back"], int(pick["site"]), height, lantern.call(int(pick["site"])), s)


# How far along `back` (from the cabin's road point) the nearest road coin on road `edge` is; INF
# when there's none.
static func first_coin(back: PackedVector2Array, sites: RoadSites, edge: int) -> float:
	var best := INF
	for i: int in sites.of_kind(RoadSites.Kind.LOOT):
		if sites.edge[i] != edge:
			continue
		var p := sites.pos[i]
		var walked := 0.0
		for k in back.size() - 1:
			var q := Geometry2D.get_closest_point_to_segment(p, back[k], back[k + 1])
			if p.distance_to(q) < 1.0:
				best = minf(best, walked + back[k].distance_to(q))
				break
			walked += back[k].distance_to(back[k + 1])
	return best


# Rest stop `g`'s road walked back from its road point both ways, the way towards spawn first.
static func _roads_back(net: RoadNetwork, sites: RoadSites, g: int) -> Array[PackedVector2Array]:
	var pl := net.polyline(sites.edge[g])
	var a := sites.anchor[g]
	var j := 0
	var best := INF
	for k in pl.size() - 1:
		var d := a.distance_to(Geometry2D.get_closest_point_to_segment(a, pl[k], pl[k + 1]))
		if d < best:
			best = d
			j = k
	var to_start := PackedVector2Array([a])
	for k in range(j, -1, -1):
		to_start.append(pl[k])
	var to_end := PackedVector2Array([a])
	for k in range(j + 1, pl.size()):
		to_end.append(pl[k])
	if pl[pl.size() - 1].length() < pl[0].length():
		return [to_end, to_start]
	return [to_start, to_end]


static func _length(pl: PackedVector2Array) -> float:
	var out := 0.0
	for k in pl.size() - 1:
		out += pl[k].distance_to(pl[k + 1])
	return out


# The start on road `back` (walked back from goal `g`'s road point): as far as the lamp stays in view,
# at least the minimum (or the whole road when it's shorter), and at least `need` (past a coin).
static func _start_on(back: PackedVector2Array, g: int, height: Callable, target: Vector3, s: FreeRoamSettings,
		need := 0.0) -> Dictionary:
	var found := _furthest_in_view(back, height, target, s)
	var least := maxf(s.cold_open_min_distance_m, need)
	if float(found.get("dist", 0.0)) < least:
		found = _spot(back, minf(least, _length(back) - 1.0))
	if found.is_empty():
		return {}
	found["site"] = g
	return found


const _STEP_M := 5.0
const _EYE_M := 1.4


static func _furthest_in_view(pl: PackedVector2Array, height: Callable, target: Vector3, s: FreeRoamSettings) -> Dictionary:
	var answer: Dictionary = {}
	var d := _STEP_M
	while d <= s.cold_open_max_distance_m:
		var spot := _spot(pl, d)
		if spot.is_empty():
			break
		if _straight_back(pl, int(spot["seg"]), spot["pos"], s.cold_open_view_corridor_m) \
				and _sight_clear(spot["pos"], height, target):
			answer = spot
		d += _STEP_M
	return answer


# The point `d` along polyline `pl` (walked back from the cabin's road point), with the road from it
# to the cabin; {} past the end.
static func _spot(pl: PackedVector2Array, d: float) -> Dictionary:
	var walked := 0.0
	for i in pl.size() - 1:
		var seg := pl[i].distance_to(pl[i + 1])
		if walked + seg >= d:
			var c := pl[i].lerp(pl[i + 1], (d - walked) / maxf(seg, 0.001))
			var path := PackedVector2Array([c])
			for k in range(i, -1, -1):
				path.append(pl[k])
			return {"pos": c, "dist": d, "path": path, "seg": i}
		walked += seg
	return {}


# Every road point between the cabin's road point (pl[0]) and `c` (just past pl[i]) lies within
# `corridor` of the straight line between them.
static func _straight_back(pl: PackedVector2Array, i: int, c: Vector2, corridor: float) -> bool:
	for k in range(1, i + 1):
		if pl[k].distance_to(Geometry2D.get_closest_point_to_segment(pl[k], c, pl[0])) > corridor:
			return false
	return true


# The ground stays below the line from a driver's eye over `c` to `target`.
static func _sight_clear(c: Vector2, height: Callable, target: Vector3) -> bool:
	var eye := Vector3(c.x, float(height.call(c.x, c.y)) + _EYE_M, c.y)
	var n := maxi(2, int(eye.distance_to(target) / 10.0))
	for k in range(1, n):
		var p := eye.lerp(target, float(k) / n)
		if float(height.call(p.x, p.z)) > p.y:
			return false
	return true


# Before the car is placed (free_roam.gd → _ready): pick the start, put the night and the chase
# camera on, and return the start pose, facing along the road towards the cabin.
func begin(camera: CameraManager) -> Transform3D:
	var s := streamer.settings
	var t := streamer.terrain
	start_spot = pick_start(streamer.network, streamer.sites,
		func(x: float, z: float) -> float: return t.height(x, z, PackedInt32Array(), false),
		streamer.lantern_position, s)
	biome.forced_weather = "night"
	if camera != null:
		camera.set_mode(CameraManager.Mode.CHASE)
	if start_spot.is_empty():
		return rest_stops.pose_at(0)
	var path: PackedVector2Array = start_spot["path"]
	var towards := path[1] - path[0] if path.size() > 1 else streamer.sites.dir[goal()]
	return RoadRecovery.road_pose(streamer, start_spot["pos"], Vector3(towards.x, 0.0, towards.y))


# The player has control (free_roam.gd → _hand_over): break the car, raise the floor and show the
# throttle hint.
func start() -> void:
	var s := streamer.settings
	var dmg := car.get("damage") as DamageModel
	if dmg != null:
		dmg.hp = dmg.max_hp * s.cold_open_start_hp_frac
		dmg.cooling_broken = true
		dmg.engine_temp = Config.data.overheat_temp_threshold_c * s.cold_open_start_temp_frac
		dmg.min_hp = dmg.max_hp * s.cold_open_hp_floor_frac
	rest_stops.lit.connect(_on_lit)
	_set_hint(true)
	running = true


static func _along(path: PackedVector2Array, d: float) -> Vector2:
	var walked := 0.0
	for k in path.size() - 1:
		var seg := path[k].distance_to(path[k + 1])
		if walked + seg >= d:
			return path[k].lerp(path[k + 1], (d - walked) / maxf(seg, 0.001))
		walked += seg
	return path[path.size() - 1]


func _physics_process(_delta: float) -> void:
	if running:
		step()


# One tick: drop the throttle hint once the player has pressed it.
func step() -> void:
	if _hinting and Input.is_action_pressed("accelerate"):
		_set_hint(false)


func _set_hint(on: bool) -> void:
	_hinting = on
	if minimap != null:
		minimap.hint = throttle_hint() if on and not Platform.is_touch() else ""
	if mobile != null:
		mobile.hint_gas = on


# The throttle's bindings, keyboard and controller ("W / RIGHT TRIGGER"), as the hint shows them.
static func throttle_hint() -> String:
	var parts: Array[String] = []
	for slot in [InputRemap.SLOT_KEYBOARD, InputRemap.SLOT_CONTROLLER]:
		var e := InputRemap.current_event("accelerate", slot)
		if e != null:
			parts.append(InputRemap.describe(e))
	return UITheme.caps(" / ".join(parts))


# The rest stop the cold open drives to (spawn's, if the island has no roadside one).
func goal() -> int:
	return int(start_spot.get("site", 0))


func _on_lit(site: int) -> void:
	if site == goal() and running:
		finish()


# The car reached the cabin: the floor goes, the night clears to dry weather
# (held until the weather's next slot, then the rings' draw takes over), the world stops being a
# first-time one, and the options open once the "Checkpoint reached" band has gone.
func finish() -> void:
	running = false
	done = true
	_set_hint(false)
	var dmg := car.get("damage") as DamageModel
	if dmg != null:
		dmg.min_hp = 0.0
	biome.forced_weather = "dry"
	_dry_slot = _slot()
	WorldSession.set_cold_open_pending(false)
	WorldSession.fresh = false
	_options_in = streamer.settings.cold_open_options_delay_s
	finished.emit()


func _slot() -> int:
	return floori(biome.drive_time / maxf(streamer.settings.weather_hold_s, 1.0))


func _process(delta: float) -> void:
	if not done:
		return
	if _options_in >= 0.0 and (checkpoint_banner == null or not checkpoint_banner.is_showing_banner()):
		_options_in -= delta
		if _options_in < 0.0:
			show_options.call()
	if _dry_slot >= 0 and _slot() != _dry_slot:
		_dry_slot = -1
		biome.forced_weather = ""
	if _options_in < 0.0 and _dry_slot < 0:
		set_process(false)

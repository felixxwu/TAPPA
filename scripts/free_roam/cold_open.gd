class_name ColdOpen
extends Node
# Docs: features/free-roam.md (Cold open) — update in the same change as this file.
# Tests: tests/headless/test_cold_open.gd — extend in the same change.
# A first-time player's first minute (todo/2026-10-30-cold-open.md): no title screen. They start
# mid-drive at night, in the chase camera, a few hundred metres down the spawn cabin's road and
# facing it, with the cooling already gone and the engine near overheating. The cabin's lamp post is
# in view down the road and a trail of coins leads to it. A health floor (DamageModel.min_hp) means
# the car limps but never gives up. Reaching the cabin lights it as usual, clears the night to dry
# weather, and then opens the camera and control options (free_roam.gd → show_options). The trail
# pays enough to buy any other starter car there.
#
# free_roam.gd adds this node only when `due()`, calls `begin()` before the car is placed (it returns
# the start pose) and `start()` when the player gets control. Nothing else grows a cold-open branch.

signal finished

var streamer: TerrainStreamer
var car: VehicleBody3D
var rest_stops: RestStops
var biome: BiomeDirector
var loot: LootDirector
var minimap: MiniMap
var mobile: MobileControls
var checkpoint_banner: CheckpointBanner
# Called once the "Checkpoint reached" band is gone: opens the camera and control options.
var show_options := func() -> void: pass

var start_spot: Dictionary = {}  # pick_start's answer
var running := false
var done := false
var _trail: Array[Dictionary] = []  # {"node": MeshInstance3D, "xz": Vector2, "value": int}
var _last_p := Vector2.ZERO
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


# What the coin trail pays in all: the dearest starter car other than `car_model`, so the player
# can swap at the first cabin. 0 when there is no other starter car.
static func trail_total(car_model: String) -> int:
	var best := 0
	for id in LootRules.starter_cars():
		if id != car_model:
			best = maxi(best, LootRules.price({"kind": "car", "id": id}))
	return best


# `total` split over `count` coins, the last one taking the rounding.
static func split(total: int, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if count <= 0 or total <= 0:
		return out
	var each := floori(float(total) / count)
	for i in count:
		out.append(each if i < count - 1 else total - each * (count - 1))
	return out


# Where the cold open starts: on a road leaving spawn (network node 0) on the cabin's door side
# (`facing`, site 0's road out), as far out (up to cold_open_max_distance_m) as the lamp post at
# `target` is still in view. In view means the road back to spawn keeps within
# cold_open_view_corridor_m of the straight line to it (so no bend or roadside tree hides the cabin)
# and the ground doesn't rise into the sight line. The roads near spawn wiggle, so that is often
# short: the start is never nearer than cold_open_min_distance_m (then the lamp comes into view on
# the last stretch, and the coin trail leads the way to it). `height(x, z)` is the ground height.
# Returns {"pos": Vector2, "dist": float, "path": PackedVector2Array from the start to spawn}, or {}
# when no road leaves spawn on that side.
static func pick_start(net: RoadNetwork, height: Callable, target: Vector3, facing: Vector2, s: FreeRoamSettings) -> Dictionary:
	var best: Dictionary = {}
	for ei in net.edges.size():
		var e := net.edges[ei]
		if e.x != 0 and e.y != 0:
			continue
		var pl := net.polyline(ei)
		if e.x != 0:
			pl.reverse()  # from spawn outward
		if pl.size() < 2 or (pl[1] - pl[0]).dot(facing) <= 0.0:
			continue  # behind the cabin, whose own walls would hide the lamp post
		var found := _furthest_in_view(pl, height, target, s)
		var d := float(found.get("dist", 0.0))
		if d < s.cold_open_min_distance_m:
			var nearest := _spot(pl, s.cold_open_min_distance_m)
			found = nearest if not nearest.is_empty() else found
		# The furthest wins; the first road out (the one site 0's cabin faces) wins a tie.
		if not found.is_empty() and (best.is_empty() or float(found["dist"]) > float(best["dist"])):
			best = found
	return best


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


# The point `d` along polyline `pl` (from spawn outward), with the road from it back to spawn;
# {} past the end.
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


# Every road point between spawn (pl[0]) and `c` (just past pl[i]) lies within `corridor` of the
# straight line from `c` to spawn.
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
	start_spot = pick_start(streamer.network, func(x: float, z: float) -> float: return t.height(x, z, PackedInt32Array(), false),
		streamer.lantern_position(0), streamer.sites.dir[0], s)
	biome.forced_weather = "night"
	if camera != null:
		camera.set_mode(CameraManager.Mode.CHASE)
	if start_spot.is_empty():
		return rest_stops.pose_at(0)
	var path: PackedVector2Array = start_spot["path"]
	var towards := path[1] - path[0] if path.size() > 1 else -streamer.sites.dir[0]
	return RoadRecovery.road_pose(streamer, start_spot["pos"], Vector3(towards.x, 0.0, towards.y))


# The player has control (free_roam.gd → _hand_over): break the car, raise the floor, lay the coins
# and show the throttle hint.
func start() -> void:
	var s := streamer.settings
	var dmg := car.get("damage") as DamageModel
	if dmg != null:
		dmg.hp = dmg.max_hp * s.cold_open_start_hp_frac
		dmg.cooling_broken = true
		dmg.engine_temp = Config.data.overheat_temp_threshold_c * s.cold_open_start_temp_frac
		dmg.min_hp = dmg.max_hp * s.cold_open_hp_floor_frac
	_lay_trail()
	_last_p = Vector2(car.global_position.x, car.global_position.z)
	rest_stops.lit.connect(_on_lit)
	_set_hint(true)
	running = true


func _lay_trail() -> void:
	if start_spot.is_empty():
		return
	var s := streamer.settings
	var path: PackedVector2Array = start_spot["path"]
	var model := String(WorldSession.active_car().get("model_id", ""))
	var values := split(trail_total(model), s.cold_open_trail_coins)
	if values.is_empty():
		return
	# Evenly from a little way ahead of the car to the edge of the cabin's pad.
	var length := 0.0
	for k in path.size() - 1:
		length += path[k].distance_to(path[k + 1])
	var from := minf(15.0, length * 0.2)
	var to := maxf(from, length - streamer.sites.radius[0] - 4.0)
	for n in values.size():
		var at := lerpf(from, to, float(n) / maxf(values.size() - 1, 1))
		var p := _along(path, at)
		var coin := TerrainStreamer.coin_mesh(float(n) * 0.7)
		coin.name = "TrailCoin%d" % n
		add_child(coin)
		coin.global_position = Vector3(p.x, streamer.terrain.height(p.x, p.y, PackedInt32Array(), false) + TerrainStreamer.COIN_FLOAT_M, p.y)
		_trail.append({"node": coin, "xz": p, "value": values[n]})


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


# One tick: pick up trail coins the car drove past (swept, like road coins), and drop the throttle
# hint once the player has pressed it.
func step() -> void:
	var p := Vector2(car.global_position.x, car.global_position.z)
	var from := _last_p if _last_p.distance_to(p) < RoadSites.TELEPORT_M else p
	_last_p = p
	var reach := streamer.settings.road_half_width_m + 1.5
	for k in range(_trail.size() - 1, -1, -1):
		var coin: Dictionary = _trail[k]
		var xz: Vector2 = coin["xz"]
		if xz.distance_to(Geometry2D.get_closest_point_to_segment(xz, from, p)) <= reach:
			_trail.remove_at(k)
			(coin["node"] as Node).queue_free()
			if loot != null:
				loot.pay_coin(int(coin["value"]))
			else:
				WorldSession.set_money(WorldSession.money() + int(coin["value"]))
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


func _on_lit(site: int) -> void:
	if site == 0 and running:
		finish()


# The car reached the cabin: the floor and the leftover coins go, the night clears to dry weather
# (held until the weather's next slot, then the rings' draw takes over), the world stops being a
# first-time one, and the options open once the "Checkpoint reached" band has gone.
func finish() -> void:
	running = false
	done = true
	_set_hint(false)
	var dmg := car.get("damage") as DamageModel
	if dmg != null:
		dmg.min_hp = 0.0
	for coin in _trail:
		(coin["node"] as Node).queue_free()
	_trail.clear()
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

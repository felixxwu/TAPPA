class_name RestStops
extends Node
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd — extend in the same change.
# The rest stops as gameplay: Dark Souls bonfires (todo/2026-10-19-free-roam-pivot.md decision 9).
#   * Driving onto a rest stop's pad LIGHTS it and makes it the respawn point.
#   * Stopping on it (below rest_stop_speed_kmh for rest_stop_hold_s) opens the rest-stop page
#     (`opened`), once per visit: leave the pad to be offered it again.
#   * When the car gives up (DamageModel.gave_up: 0 HP), it respawns at the last lit rest stop,
#     fully repaired (`respawned`, carrying where the wreck was, for the dropped loot later).
#   * Travel teleports to any lit rest stop. Both moves stream the destination in first
#     (TerrainStreamer.prefill_at): the one acceptable "load".
# Rest stop i is site i of TerrainStreamer.sites (RoadSites, kind REST); spawn is site 0, lit
# from the start.

signal lit(site: int)
signal opened(site: int)
signal respawned(site: int, wreck_pos: Vector3)
signal travelled(site: int)

@export var streamer: TerrainStreamer
@export var car: VehicleBody3D
# Disarmed while the rest-stop page or a respawn is on screen, so pause can't stack over it.
@export var pause_menu: PauseMenu

var lit_sites := {}  # site -> true
var last_site := 0

var _on_site := -1
var _slow_t := 0.0
var _offered := -1  # the site whose page was already offered this visit


func _ready() -> void:
	lit_sites[0] = true
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).gave_up.connect(_on_gave_up)


func is_lit(site: int) -> bool:
	return lit_sites.has(site)


# The rest stop whose pad `p` is on, or -1.
func rest_at(p: Vector2) -> int:
	var sites := streamer.sites
	var i := sites.pad_at(p.x, p.y)
	if i < 0 or sites.kind[i] != RoadSites.Kind.REST or sites.outside(i, p.x, p.y) > 0.0:
		return -1
	return i


func _physics_process(delta: float) -> void:
	if car == null or streamer == null:
		return
	step(delta)


func step(delta: float) -> void:
	var p := Vector2(car.global_position.x, car.global_position.z)
	var i := rest_at(p)
	if i != _on_site:
		_on_site = i
		_slow_t = 0.0
		if i < 0:
			_offered = -1
	if i < 0:
		return
	if not lit_sites.has(i):
		lit_sites[i] = true
		streamer.refresh_site_marker(i)
		lit.emit(i)
	last_site = i
	var cfg: GameConfig = Config.data
	if car.linear_velocity.length() * 3.6 < cfg.rest_stop_speed_kmh:
		_slow_t += delta
		if _slow_t >= cfg.rest_stop_hold_s and _offered != i:
			_offered = i
			opened.emit(i)
	else:
		_slow_t = 0.0


# Where the car is put at rest stop `site`: on its road beside the pad, facing along the road.
func pose_at(site: int) -> Transform3D:
	var sites := streamer.sites
	var a := sites.anchor[site]
	var d := sites.dir[site]
	if site == 0 or d == Vector2.ZERO:
		return RoadRecovery.road_pose(streamer, a, Vector3.FORWARD)
	var y := streamer.height_at(a.x, a.y) + 1.0
	return Transform3D(Basis.looking_at(Vector3(d.x, 0.0, d.y), Vector3.UP), Vector3(a.x, y, a.y))


# Move the car to rest stop `site` (lit or not — callers check), streaming its ground in first.
func move_car_to(site: int) -> void:
	var pose := pose_at(site)
	streamer.prefill_at(Vector2(pose.origin.x, pose.origin.z))
	pose = pose_at(site)  # the ground is loaded now, so the height is the drawn one
	car.reset_to(pose)
	last_site = site
	_on_site = site
	_offered = site  # arriving isn't a fresh stop: no page until you leave and come back


func travel_to(site: int) -> bool:
	if not lit_sites.has(site):
		return false
	move_car_to(site)
	(car.damage as DamageModel).repair(Config.data)
	travelled.emit(site)
	return true


func _on_gave_up() -> void:
	respawn.call_deferred()


func respawn() -> void:
	var wreck := car.global_position
	move_car_to(last_site)
	(car.damage as DamageModel).repair(Config.data)
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
	return "Rest stop %d · %s" % [site, String(region.get("name", ""))]

class_name ParkedCars
extends Node3D
# Docs: features/loot.md — update in the same change as this file.
# Tests: tests/headless/test_found_cars.gd — extend in the same change.
# The cars to be found: each waits on the pad at the end of its side road (RoadSites.Kind.CAR),
# facing back up the road. Driving onto it puts it in the garage (`found`), and while the car stays
# on that pad, Enter / A (or a tap on the minimap's prompt) drives it (`switch_requested`). A found
# car stays on its pad, and is offered again on coming back, until the world next loads, when only
# cars still to be found are parked. All of them are built once, behind the loading screen, and stay
# put: a car prop is too dear to build while driving.

signal found(owned: Dictionary)
signal switch_requested(owned: Dictionary)

var streamer: TerrainStreamer
var car: Node3D  # the player's car
var rest_stops: RestStops  # a wrecked car can't switch, or it would skip the respawn
var show_props := not Platform.is_headless()  # the models only; finding a car works without them
var _here := {}  # CAR sites with a car parked on them this load
var _props := {}  # CAR site -> its pivot on the pad
var _last_p := Vector2(INF, INF)
var _from := Vector2.ZERO  # where this step's sweep starts
var _offer := {}  # the car parked where the car is, while it stays on the pad
var _offer_site := -1


func _ready() -> void:
	for i in streamer.sites.of_kind(RoadSites.Kind.CAR):
		if waiting(i):
			_here[i] = true
			if show_props:
				_props[i] = _park(i)


# Whether the car parked at `site` is still there to be found (nobody owns one of that model yet).
func waiting(site: int) -> bool:
	var id := String(streamer.sites.car_id.get(site, ""))
	return id != "" and not model_owned(id)


static func model_owned(id: String) -> bool:
	return not owned_of_model(id).is_empty()


static func owned_of_model(id: String) -> Dictionary:
	for c: Dictionary in Save.profile.get(Save.KEY_CARS, []):
		if String(c.get("model_id", "")) == id:
			return c
	return {}


# Whether a car stands on `site`'s pad this load (found or not).
func parked(site: int) -> bool:
	return _here.has(site)


func is_parked(site: int) -> bool:
	return _props.has(site)


# A car is reached by driving onto its pad from off it, so leaving the pad doesn't count as arriving.
func _parked_car(site: int) -> bool:
	return _here.has(site) and streamer.sites.outside(site, _from.x, _from.y) > 0.0


func _park(i: int) -> Node3D:
	var sites := streamer.sites
	var pivot := Node3D.new()
	pivot.name = "Parked%d" % i
	add_child(pivot)
	var d := sites.dir[i]
	pivot.global_transform = Transform3D(Basis.looking_at(Vector3(d.x, 0.0, d.y), Vector3.UP),
		Vector3(sites.pos[i].x, sites.pad_h[i], sites.pos[i].y))
	var prop := CarProp.spawn(pivot, Scenes.car_scene(), {"index": CarLibrary.index_of(String(sites.car_id[i])),
		"stop_physics": true, "disable_process": true})
	prop.disable_mode = CollisionObject3D.DISABLE_MODE_KEEP_ACTIVE  # a disabled body otherwise leaves the physics world, so nothing could hit it
	var box := CarCardPreview._visible_mesh_aabb(prop, pivot)
	prop.position -= Vector3(box.get_center().x, box.position.y, box.get_center().z)
	return pivot


func _physics_process(_delta: float) -> void:
	if car == null:
		return
	var p := Vector2(car.global_position.x, car.global_position.z)
	var from := _last_p if _last_p.distance_to(p) < RoadSites.TELEPORT_M else p
	_last_p = p
	if _offer_site >= 0 and streamer.sites.outside(_offer_site, p.x, p.y) > 0.0:
		_offer = {}
		_offer_site = -1
	if ColdOpen.due() or _offer_site >= 0:
		return  # nothing interrupts the cold open, and an offer stands until the car leaves its pad
	_from = from
	var i := streamer.sites.reached(from, p, 0.0, _parked_car)
	if i >= 0:
		take(i)


# The car drove onto `site`'s pad: the first time, its car joins the garage; either way the car
# parked there is offered while the car stays on the pad. Returns that owned car.
func take(site: int) -> Dictionary:
	if not _here.has(site):
		return {}
	var id := String(streamer.sites.car_id[site])
	var owned := owned_of_model(id)
	if owned.is_empty():
		owned = Save.grant_car(id)
		found.emit(owned)
	_offer = owned
	_offer_site = site
	return owned


# The car parked where the car is, which the prompt offers to drive; {} when there's none.
func offer() -> Dictionary:
	if rest_stops != null and (rest_stops.is_wrecked or not rest_stops.input_enabled):
		return {}
	return _offer


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("menu_select") and not offer().is_empty():
		get_viewport().set_input_as_handled()  # first: switching reloads the scene, leaving the tree
		switch_here()


# Drive the car parked here (Enter / A, or a tap on the minimap's prompt). False when there's none.
func switch_here() -> bool:
	var owned := offer()
	if owned.is_empty():
		return false
	_offer = {}
	_offer_site = -1
	switch_requested.emit(owned)
	return true


# The boot's shader warm-up: every parked car stands in a row in front of the camera (whole, past
# its near plane) for a few frames, so the first one met on the road doesn't stall compiling its
# materials. Their collision is off meanwhile, so none of them can knock the player's car.
func warm_up(at: Vector3) -> void:
	var cam := get_viewport().get_camera_3d()
	var ahead := at
	var across := Vector3.RIGHT
	if cam != null:
		ahead = cam.global_position - cam.global_basis.z * WARM_UP_AHEAD_M
		across = cam.global_basis.x
	var k := 0
	for i: int in _props:
		var pivot: Node3D = _props[i]
		pivot.set_meta("pad", pivot.global_transform)
		pivot.global_position = ahead + across * (k - (_props.size() - 1) * 0.5) * WARM_UP_GAP_M
		k += 1
		for body: CollisionObject3D in pivot.find_children("*", "CollisionObject3D", true, false):
			body.set_meta("layers", Vector2i(body.collision_layer, body.collision_mask))
			body.collision_layer = 0
			body.collision_mask = 0


func clear_warm_up() -> void:
	for i: int in _props:
		var pivot: Node3D = _props[i]
		if pivot.has_meta("pad"):
			pivot.global_transform = pivot.get_meta("pad")
			pivot.remove_meta("pad")
		for body: CollisionObject3D in pivot.find_children("*", "CollisionObject3D", true, false):
			if body.has_meta("layers"):
				var l: Vector2i = body.get_meta("layers")
				body.collision_layer = l.x
				body.collision_mask = l.y
				body.remove_meta("layers")


const WARM_UP_AHEAD_M := 14.0
const WARM_UP_GAP_M := 6.0

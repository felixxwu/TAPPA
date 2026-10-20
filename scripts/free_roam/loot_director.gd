class_name LootDirector
extends Node
# Docs: features/loot.md — update in the same change as this file.
# Tests: tests/headless/test_loot.gd — extend in the same change.
# Loot as gameplay (todo/2026-10-19-free-roam-pivot.md decisions 10–18). The world's loot is placed
# once from the seed (LootLibrary.place) on the loot slots and dead ends; this node:
#   * COLLECTS what the car drives near: it joins `carried`, which is not yours yet (decision 10).
#     A rumour is read on the spot: it reveals its ring's loot in the journal (decision 18).
#   * BANKS carried loot at a rest stop (bank()): parts go to the shared stash, car titles join
#     the garage (Save.grant_car).
#   * DROPS carried loot at the wreck when the car gives up (decision 11). Driving back picks it up;
#     giving up again first loses it for good, because the new drop replaces it.
# All state lives in the world session (WorldSession: carried, stash, dropped, collected, revealed).

signal collected(item: Dictionary)
signal recovered(items: Array)

const PICKUP_REACH_M := 3.0
const DROPPED_REACH_M := 6.0

@export var streamer: TerrainStreamer
@export var car: Node3D

var placement := {}  # site -> item
var _dropped_node: Node3D
var _toast: Label
var _toast_t := 0.0


func _ready() -> void:
	if streamer == null:
		return
	placement = LootLibrary.place(streamer.sites, streamer.settings.ring_count, streamer.settings.world_seed)
	streamer.loot_query = loot_at
	print("free roam: loot ", pacing_report())
	if WorldSession.list("revealed").is_empty():
		WorldSession.set_list("revealed", [0])
	var layer := CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_left = -200
	_toast.offset_right = 200
	_toast.offset_top = 56
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false
	layer.add_child(_toast)
	_sync_dropped_node()


# Per ring: how many loot sites it has and how many items its table holds — the numbers the
# pacing pass (decision 3) balances.
func pacing_report() -> Array:
	var tables := LootLibrary.ring_tables(streamer.settings.ring_count)
	var out: Array = []
	for r in streamer.settings.ring_count:
		var site_count := 0
		var placed := 0
		for i in streamer.sites.count():
			if streamer.sites.kind[i] != RoadSites.Kind.REST and streamer.sites.ring[i] == r:
				site_count += 1
				placed += int(placement.has(i))
		out.append({"ring": r, "sites": site_count, "items": (tables[r] as Array).size(), "placed": placed})
	return out


# The item still lying at `site`, or {} when there is none or it was taken.
func loot_at(site: int) -> Dictionary:
	if not placement.has(site) or is_collected(site):
		return {}
	return placement[site]


func is_collected(site: int) -> bool:
	for s in WorldSession.list("collected"):
		if int(s) == site:
			return true
	return false


func _physics_process(delta: float) -> void:
	if car == null or streamer == null:
		return
	step()
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast.visible = false


func step() -> void:
	var p := Vector2(car.global_position.x, car.global_position.z)
	var i := streamer.sites.pad_at(p.x, p.y)
	if i >= 0 and placement.has(i) and not is_collected(i) \
			and p.distance_to(streamer.sites.pos[i]) <= streamer.sites.radius[i] + PICKUP_REACH_M:
		collect(i)
	var d := WorldSession.dropped()
	if not d.is_empty():
		var at: Array = d.get("pos", [])
		if at.size() >= 3 and p.distance_to(Vector2(float(at[0]), float(at[2]))) <= DROPPED_REACH_M:
			recover_dropped()


func collect(site: int) -> void:
	var item: Dictionary = placement[site]
	var col := WorldSession.list("collected")
	col.append(site)
	WorldSession.set_list("collected", col)
	if String(item["kind"]) == "rumour":
		reveal(int(item["ring"]))
		_say("Rumour: the %s's loot is in your journal" % _ring_name(int(item["ring"])))
	else:
		var carried := WorldSession.list("carried")
		var held := item.duplicate()
		held["site"] = site
		carried.append(held)
		WorldSession.set_list("carried", carried)
		_say("Found %s. Bank it at a rest stop" % LootLibrary.label(item))
	streamer.refresh_loot_marker(site)
	collected.emit(item)


func reveal(ring: int) -> void:
	var revealed := WorldSession.list("revealed")
	if not revealed.has(ring) and not revealed.has(float(ring)):
		revealed.append(ring)
		WorldSession.set_list("revealed", revealed)


func is_revealed(ring: int) -> bool:
	for r in WorldSession.list("revealed"):
		if int(r) == ring:
			return true
	return false


# Move everything carried into the stash (parts) or the garage (car titles). Returns the items.
func bank() -> Array:
	var carried := WorldSession.list("carried")
	if carried.is_empty():
		return []
	var stash := WorldSession.list("stash")
	for item: Dictionary in carried:
		if String(item["kind"]) == "car":
			Save.grant_car(String(item["id"]))
		else:
			var part := item.duplicate()
			part.erase("site")
			stash.append(part)
	WorldSession.set_list("stash", stash)
	WorldSession.set_list("carried", [])
	return carried


# The car gave up at `wreck`: whatever it carried is left there, replacing any earlier drop.
func drop_at(wreck: Vector3) -> void:
	var carried := WorldSession.list("carried")
	if carried.is_empty():
		return
	WorldSession.set_dropped({"pos": [wreck.x, wreck.y, wreck.z], "items": carried})
	WorldSession.set_list("carried", [])
	_sync_dropped_node()


func recover_dropped() -> void:
	var d := WorldSession.dropped()
	var items: Array = d.get("items", [])
	var carried := WorldSession.list("carried")
	carried.append_array(items)
	WorldSession.set_list("carried", carried)
	WorldSession.set_dropped({})
	_sync_dropped_node()
	_say("Recovered %d item%s" % [items.size(), "" if items.size() == 1 else "s"])
	recovered.emit(items)


# A tall red beacon where the dropped loot lies, so it can be found again.
func _sync_dropped_node() -> void:
	if is_instance_valid(_dropped_node):
		_dropped_node.queue_free()
		_dropped_node = null
	var d := WorldSession.dropped()
	var at: Array = d.get("pos", [])
	if at.size() < 3:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.35
	mesh.bottom_radius = 0.35
	mesh.height = 12.0
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.2, 0.15)
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.name = "DroppedLoot"
	mi.mesh = mesh
	add_child(mi)
	mi.global_position = Vector3(float(at[0]), float(at[1]) + 6.0, float(at[2]))
	_dropped_node = mi


func _say(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast.visible = true
	_toast_t = 3.0


func _ring_name(ring: int) -> String:
	return String(RegionLibrary.by_id(BiomeDirector.region_of(streamer.settings, ring)).get("name", "next biome"))


# The journal: for every revealed ring, its loot and whether each piece was found.
func journal() -> Array:
	var rings: Array = []
	var tables := LootLibrary.ring_tables(streamer.settings.ring_count)
	var found := {}
	for site in WorldSession.list("collected"):
		if placement.has(int(site)):
			found[LootLibrary.item_key(placement[int(site)])] = true
	for r in streamer.settings.ring_count:
		if not is_revealed(r):
			continue
		var rows: Array = []
		for item: Dictionary in tables[r]:
			if String(item["kind"]) == "rumour":
				continue
			rows.append({"label": LootLibrary.label(item), "item": item, "found": found.has(LootLibrary.item_key(item))})
		rings.append({"ring": r, "name": _ring_name(r), "items": rows})
	return rings

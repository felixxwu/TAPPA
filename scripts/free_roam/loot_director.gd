class_name LootDirector
extends Node
# Docs: features/loot.md — update in the same change as this file.
# Tests: tests/headless/test_loot.gd — extend in the same change.
# Loot as gameplay (todo/2026-10-19-free-roam-pivot.md decisions 10–18). What each loot slot and
# dead end shows comes from the POOL (LootRules.assign): every car and part exists once, and is
# gone from every site the moment the player has it. `placement` is the current {site: item},
# recomputed whenever what the player holds changes (`pool_changed`). This node:
#   * COLLECTS what the car drives near: it joins `carried`, which is not yours yet (decision 10).
#     A rumour is read on the spot: it reveals its ring's loot in the journal (decision 18).
#   * BANKS carried loot the moment the car reaches a checkpoint (bank_at_checkpoint): parts go to
#     the shared stash, car titles join the garage (Save.grant_car).
#   * DROPS carried loot at the wreck when the car gives up (decision 11). Driving back picks it up;
#     giving up again first loses it: the new drop replaces it, and what it held goes back into
#     the pool to be found again.
# All state lives in the world session (WorldSession: carried, stash, dropped, collected, revealed).

signal collected(item: Dictionary)
signal recovered(items: Array)
# What the sites show may have changed (something was picked up, dropped or lost).
signal pool_changed

const DROPPED_REACH_M := 6.0

@export var streamer: TerrainStreamer
@export var car: Node3D

var placement := {}  # site -> item, as the sites show it now
var _last_p := Vector2(INF, INF)  # the car's position last step, for the swept pickup check
var beacons: SiteBeacons
var _dropped_node: Node3D
var _toast: Label
var _toast_t := 0.0


func _ready() -> void:
	if streamer == null:
		return
	streamer.loot_query = loot_at
	if WorldSession.list("revealed").is_empty():
		WorldSession.set_list("revealed", [0])
	beacons = SiteBeacons.new()
	beacons.name = "SiteBeacons"
	add_child(beacons)
	_reassign()
	beacons.setup(streamer, self)
	print("free roam: loot ", pacing_report())
	var layer := CanvasLayer.new()
	layer.layer = 3
	add_child(layer)
	_toast = Label.new()
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_left = -200
	_toast.offset_right = 200
	# Below the minimap (top-centre, minimap_top_px + minimap_height_frac of the screen).
	_toast.anchor_top = Config.data.minimap_height_frac + 0.03
	_toast.anchor_bottom = _toast.anchor_top
	_toast.offset_top = Config.data.minimap_top_px
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.visible = false
	layer.add_child(_toast)
	_sync_dropped_node()


# Per ring: how many loot sites it has, how many items its table holds, how many are still to
# find, and how many sites show something now — the numbers the pacing pass (decision 3) balances.
func pacing_report() -> Array:
	var tables := LootRules.ring_tables(streamer.settings.ring_count)
	var taken := taken_keys()
	var out: Array = []
	for r in streamer.settings.ring_count:
		var site_count := 0
		var showing := 0
		for i in streamer.sites.count():
			if streamer.sites.kind[i] != RoadSites.Kind.REST and streamer.sites.ring[i] == r:
				site_count += 1
				showing += int(placement.has(i))
		out.append({"ring": r, "sites": site_count, "items": (tables[r] as Array).size(),
			"left": LootRules.remaining(tables[r], taken).size(), "showing": showing})
	return out


# The item lying at `site` now, or {} when it shows nothing.
func loot_at(site: int) -> Dictionary:
	return placement.get(site, {})


# Whether the player emptied `site` (it may still fill again — see LootRules.assign).
func is_collected(site: int) -> bool:
	for s in WorldSession.list("collected"):
		if int(s) == site:
			return true
	return false


# The item_key of everything the player has: owned cars, fitted parts, the stash, what's carried,
# what's lying in the dropped pile, and the rumours of rings already revealed. None of it is in the
# pool any more.
func taken_keys() -> Dictionary:
	var out := {}
	for c: Dictionary in Save.profile.get(Save.KEY_CARS, []):
		out[LootRules.item_key({"kind": "car", "id": String(c.get("model_id", ""))})] = true
		for p: Dictionary in c.get("parts", []):
			out[LootRules.item_key(p)] = true
	var held: Array = WorldSession.list("stash") + WorldSession.list("carried")
	held.append_array(WorldSession.dropped().get("items", []))
	for item: Dictionary in held:
		out[LootRules.item_key(item)] = true
	for r in WorldSession.list("revealed"):
		out[LootRules.item_key({"kind": "rumour", "ring": int(r)})] = true
	return out


# Recompute what every site shows, and tell whoever draws them.
func _reassign() -> void:
	placement = LootRules.assign(streamer.sites, streamer.settings.ring_count, streamer.settings.world_seed,
		taken_keys(), WorldSession.list("collected"), streamer.settings.loot_item_weight)
	streamer.refresh_loot_markers()
	if beacons != null and beacons.streamer != null:
		beacons.refresh_loot()
	pool_changed.emit()


func _physics_process(delta: float) -> void:
	if car == null or streamer == null:
		return
	step()
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast.visible = false


# Pick up what the car drives past — no need to stop, or even to leave the road: anywhere on the
# road around a loot spot counts (RoadSites.reached, swept over this step's travel).
func step() -> void:
	var p := Vector2(car.global_position.x, car.global_position.z)
	var from := _last_p if _last_p.distance_to(p) < 100.0 else p  # a teleport isn't a drive past
	_last_p = p
	var i := streamer.sites.reached(from, p, RoadSites.road_margin(streamer.settings),
		func(site: int) -> bool: return placement.has(site))
	if i >= 0:
		collect(i)
	var d := WorldSession.dropped()
	if not d.is_empty():
		var at: Array = d.get("pos", [])
		if at.size() >= 3 and p.distance_to(Vector2(float(at[0]), float(at[2]))) <= DROPPED_REACH_M:
			recover_dropped()


# The car was teleported (respawn, travel, R reset) to `p`: the next step must not sweep from where
# it was, or the straight line through the terrain would count as a drive past.
func car_teleported(p: Vector2) -> void:
	_last_p = p


func collect(site: int) -> void:
	var item: Dictionary = placement[site]
	var col := WorldSession.list("collected")
	col.erase(site)
	col.erase(float(site))
	col.append(site)  # emptied sites stay in order, oldest first
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
		_say("Found %s. Bank it at a checkpoint" % LootRules.label(item))
	_reassign()
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


func bank_at_checkpoint(_site: int) -> void:
	var items := bank()
	if not items.is_empty():
		_say("Banked: " + ", ".join(items.map(LootRules.label)))


# The car gave up at `wreck`: whatever it carried is left there, replacing any earlier drop.
func drop_at(wreck: Vector3) -> void:
	var carried := WorldSession.list("carried")
	if carried.is_empty():
		return
	WorldSession.set_dropped({"pos": [wreck.x, wreck.y, wreck.z], "items": carried})
	WorldSession.set_list("carried", [])
	_sync_dropped_node()
	_reassign()  # an earlier drop it replaced is lost: those items go back into the pool


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


# The journal: for every revealed ring, its loot and whether each piece was found (the player has it).
func journal() -> Array:
	var rings: Array = []
	var tables := LootRules.ring_tables(streamer.settings.ring_count)
	var found := taken_keys()
	for r in streamer.settings.ring_count:
		if not is_revealed(r):
			continue
		var rows: Array = []
		for item: Dictionary in tables[r]:
			if String(item["kind"]) == "rumour":
				continue
			rows.append({"label": LootRules.label(item), "item": item, "found": found.has(LootRules.item_key(item))})
		rings.append({"ring": r, "name": _ring_name(r), "items": rows})
	return rings

class_name LootDirector
extends Node
# Docs: features/loot.md — update in the same change as this file.
# Tests: tests/headless/test_loot.gd — extend in the same change.
# The coin economy in the world: every loot slot and dead end holds a coin until the car drives past
# it, and coins are money to spend at checkpoints. Money is only safe once it's spent: when the car
# gives up, all of it is dropped at the wreck (under a floating crystal) and every coin comes back.
# Driving back to the wreck picks the money up again; giving up again first loses it for good.
# A biome ring's stock goes on sale once one of its checkpoints is lit (`unlock`).
# Money, coins taken and rings on sale live in the world session (WorldSession). Parts belong to the
# one car they were unlocked for: the shop sells the car being driven what it hasn't unlocked and can
# use, and another car has to unlock its own.

signal collected(site: int, value: int)
signal recovered(value: int)

const DROPPED_REACH_M := 6.0
const DROP_CRYSTAL := preload("res://shaders/crystal.gdshader")
# Which coins show may have changed (one was picked up, or they all came back).
signal pool_changed

@export var streamer: TerrainStreamer
@export var car: Node3D

var _last_p := Vector2(INF, INF)  # the car's position last step, for the swept pickup check
var _spent := {}  # collected sites, as a set
# What the last wreck dropped, for the wreck page.
var lost := 0
var _dropped_node: Node3D
var _wrecked := false  # from giving up until the respawn
var _toast: Label
var money_label: Label  # the counter in the top-left corner while driving
var _toast_t := 0.0


func _ready() -> void:
	if streamer == null:
		return
	streamer.loot_query = loot_at
	if WorldSession.list("revealed").is_empty():
		WorldSession.set_list("revealed", [0])
	_sync_spent()
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).gave_up.connect(wreck)
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
	money_label = UITheme.label("")
	money_label.name = "MoneyLabel"
	money_label.position = Vector2(UITheme.px(12), UITheme.px(8))
	money_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# On the HUD's layer, so it hides under paused pages with the gauges (features/hud.md).
	var hud := get_parent().get_node_or_null("HUD")
	(hud if hud != null else layer).add_child(money_label)


# The coin at `site` now ({"kind": "coin", "value": n}), or {} when it's been taken or isn't a coin spot.
func loot_at(site: int) -> Dictionary:
	if site < 0 or site >= streamer.sites.count() or streamer.sites.kind[site] == RoadSites.Kind.REST \
			or _spent.has(site):
		return {}
	return {"kind": "coin", "value": LootRules.coin_value(streamer.settings, streamer.sites.ring[site])}


func is_collected(site: int) -> bool:
	return _spent.has(site)


func _sync_spent() -> void:
	_spent.clear()
	for s in WorldSession.list("collected"):
		_spent[int(s)] = true
	streamer.refresh_loot_markers()
	pool_changed.emit()


func _physics_process(delta: float) -> void:
	if car == null or streamer == null:
		return
	step()
	money_label.text = "$%d" % WorldSession.money()
	if _toast_t > 0.0:
		_toast_t -= delta
		if _toast_t <= 0.0:
			_toast.visible = false


# Pick up the coins the car drives past — anywhere on the road around one counts
# (RoadSites.reached, swept over this step's travel). A wrecked car collects nothing.
func step() -> void:
	var p := Vector2(car.global_position.x, car.global_position.z)
	var from := _last_p if _last_p.distance_to(p) < 100.0 else p  # a teleport isn't a drive past
	_last_p = p
	if _wrecked:
		return
	var d := WorldSession.dropped()
	var at: Array = d.get("pos", [])
	if at.size() >= 3 and int(d.get("money", 0)) > 0 and p.distance_to(Vector2(float(at[0]), float(at[2]))) <= DROPPED_REACH_M:
		recover_dropped()
	var i := streamer.sites.reached(from, p, RoadSites.road_margin(streamer.settings),
		func(site: int) -> bool: return not loot_at(site).is_empty())
	if i >= 0:
		collect(i)


# The car was teleported (respawn, travel, R reset) to `p`: the next step must not sweep from where
# it was, or the straight line through the terrain would count as a drive past.
func car_teleported(p: Vector2) -> void:
	_last_p = p


func respawned(_site: int, _wreck: Vector3) -> void:
	_wrecked = false


func collect(site: int) -> void:
	var value := int(loot_at(site).get("value", 0))
	var col := WorldSession.list("collected")
	col.append(site)
	WorldSession.set_list("collected", col)
	_spent[site] = true
	WorldSession.set_money(WorldSession.money() + value)
	streamer.refresh_loot_marker(site)
	Audio.play_beep(Config.data.coin_pickup_sfx_freq_hz, Config.data.coin_pickup_sfx_duration_sec)
	_say("+$%d" % value)
	collected.emit(site, value)


# The car gave up: its money is left at the wreck, replacing (and losing) any earlier drop, and every
# coin comes back.
func wreck() -> void:
	_wrecked = true
	lost = drop_money()
	WorldSession.set_list("collected", [])
	_sync_spent()


# Leave all the money where the car is (replacing, and so losing, any earlier drop). Returns how much.
func drop_money() -> int:
	var money := WorldSession.money()
	var p := car.global_position
	WorldSession.set_dropped({"pos": [p.x, p.y, p.z], "money": money} if money > 0 else {})
	WorldSession.set_money(0)
	_sync_dropped_node()
	return money


func recover_dropped() -> void:
	var value := int(WorldSession.dropped().get("money", 0))
	WorldSession.set_dropped({})
	WorldSession.set_money(WorldSession.money() + value)
	_sync_dropped_node()
	_say("Recovered $%d" % value)
	recovered.emit(value)


# The crystal floating over the dropped money, so it can be found again.
func _sync_dropped_node() -> void:
	if is_instance_valid(_dropped_node):
		_dropped_node.queue_free()
		_dropped_node = null
	var at: Array = WorldSession.dropped().get("pos", [])
	if at.size() < 3 or int(WorldSession.dropped().get("money", 0)) <= 0:
		return
	var mat := ShaderMaterial.new()
	mat.shader = DROP_CRYSTAL
	mat.set_shader_parameter("color", Color(1.0, 0.8, 0.2))
	var root := Node3D.new()
	root.name = "DroppedMoney"
	for up in [1.0, -1.0]:
		var half := CylinderMesh.new()  # a 4-sided cone: one half of the crystal
		half.top_radius = 0.0 if up > 0.0 else 0.3
		half.bottom_radius = 0.3 if up > 0.0 else 0.0
		half.height = 0.9 if up > 0.0 else 0.6
		half.radial_segments = 4
		half.rings = 1
		half.cap_top = false
		half.cap_bottom = false
		half.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = half
		mi.position.y = 1.4 + up * half.height * 0.5
		root.add_child(mi)
	add_child(root)
	root.global_position = Vector3(float(at[0]), float(at[1]), float(at[2]))
	_dropped_node = root


# Lighting a checkpoint in `ring` puts the ring's stock on sale.
func unlock(ring: int) -> void:
	var revealed := WorldSession.list("revealed")
	if not revealed.has(ring) and not revealed.has(float(ring)):
		revealed.append(ring)
		WorldSession.set_list("revealed", revealed)


func is_unlocked(ring: int) -> bool:
	for r in WorldSession.list("revealed"):
		if int(r) == ring:
			return true
	return false


# The item_key of everything the player has, as far as `owned` (a car) is concerned: every car in
# the garage, and the parts unlocked for that car.
func owned_keys(owned: Dictionary) -> Dictionary:
	var out := {}
	for c: Dictionary in Save.profile.get(Save.KEY_CARS, []):
		out[LootRules.item_key({"kind": "car", "id": String(c.get("model_id", ""))})] = true
	for p: Dictionary in owned.get("parts", []):
		out[LootRules.item_key(p)] = true
	return out


# Per ring, what its checkpoints sell: its own stock, plus that of any ring the road network gave
# no rest stop (LootRules.pool_rings).
func ring_stock() -> Array:
	var n := streamer.settings.ring_count
	var tables := LootRules.ring_tables(n)
	var rests := PackedInt32Array()
	rests.resize(n)
	for i in streamer.sites.count():
		if streamer.sites.kind[i] == RoadSites.Kind.REST:
			rests[clampi(streamer.sites.ring[i], 0, n - 1)] += 1
	var out: Array = []
	for hosted: Array in LootRules.pool_rings(rests):
		var stock: Array = []
		for r: int in hosted:
			stock.append_array(tables[r])
		out.append(stock)
	return out


# What the shops sell now: everything from unlocked rings the player doesn't have yet, with parts
# for the car being driven.
func for_sale() -> Array:
	var have := owned_keys(WorldSession.active_car())
	var out: Array = []
	var stock := ring_stock()
	for r in stock.size():
		if not is_unlocked(r):
			continue
		for item: Dictionary in stock[r]:
			if not have.has(LootRules.item_key(item)):
				out.append(item)
	return out


# Spend money on `item`: a car joins the garage (returns the new owned car); a part is paid for and
# returned for the caller to unlock on the car being driven. {} when it isn't for sale, that car
# can't use it, or the player can't afford it.
func buy(item: Dictionary) -> Dictionary:
	var cost := LootRules.price(item)
	if cost > WorldSession.money() or not for_sale().any(func(i: Dictionary) -> bool: return LootRules.item_key(i) == LootRules.item_key(item)):
		return {}
	var is_car := String(item["kind"]) == "car"
	if not is_car and not LootRules.can_fit(WorldSession.active_car(), item):
		return {}
	WorldSession.set_money(WorldSession.money() - cost)
	if is_car:
		return Save.grant_car(String(item["id"]))
	return item


func _say(text: String) -> void:
	if _toast == null:
		return
	_toast.text = text
	_toast.visible = true
	_toast_t = 3.0

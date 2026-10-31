class_name LootDirector
extends Node
# Docs: features/loot.md — update in the same change as this file.
# Tests: tests/headless/test_loot.gd — extend in the same change.
# The coin economy in the world: every loot slot and dead end holds a coin until the car drives past
# it, and coins are money to spend at checkpoints. Money is only safe once it's spent: when the car
# gives up, all of it is dropped at the wreck (under a floating crystal) and every coin comes back.
# Driving back to the wreck picks the money up again; giving up again first loses it for good.
# Risky driving pays too: a long drift, a stretch flat out, a jump, or a tree passed close (`stunt_step`).
# A biome ring's stock goes on sale once one of its checkpoints is lit (`unlock`).
# Money, coins taken and rings on sale live in the world session (WorldSession). Parts belong to the
# one car they were unlocked for: the shop sells the car being driven what it hasn't unlocked and can
# use, and another car has to unlock its own.

signal collected(site: int, value: int)
signal recovered(value: int)
signal said(text: String, seconds: float)  # a money message, for the line under the minimap

const DROP_CRYSTAL := preload("res://shaders/crystal.gdshader")

@export var streamer: TerrainStreamer
@export var car: Node3D

var _last_p := Vector2(INF, INF)  # the car's position last step, for the swept pickup check
var _spent := {}  # collected sites, as a set
# What the last wreck dropped, for the wreck page.
var lost := 0
var _dropped_node: Node3D
var _warm_crystal: Node3D
var _wrecked := false  # from giving up until the respawn
var money_label: Label  # the counter in the top-left corner while driving
var _money_shown := -1
var _streaks := {"Drift": [0.0, 0.0], "Speed": [0.0, 0.0], "Jump": [0.0, 0.0]}  # [seconds held, seconds since it dropped out]
var _settled := false  # on its wheels since the last spawn, so dropping in isn't a jump
var _near := {}  # trees inside the near-miss radius -> whether passing them still pays
var _near_query: PhysicsShapeQueryParameters3D


func _ready() -> void:
	if streamer == null:
		return
	streamer.loot_query = loot_at
	if WorldSession.list("revealed").is_empty():
		WorldSession.set_list("revealed", [0])
	_sync_spent()
	if car != null and car.get("damage") != null:
		(car.damage as DamageModel).gave_up.connect(wreck)
		(car.damage as DamageModel).damaged.connect(func(_loss: float, _at: Vector3) -> void: _void_stunts())
	_sync_dropped_node()
	money_label = UITheme.label("")
	money_label.name = "MoneyLabel"
	money_label.position = Vector2(UITheme.px(12), UITheme.px(8))
	money_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	money_label.add_theme_stylebox_override("normal", UITheme.panel_box(1.0, UITheme.px(6)))
	# On the HUD's layer, so it hides under paused pages with the gauges (features/hud.md).
	var hud := get_parent().get_node_or_null("HUD")
	(hud if hud != null else self).add_child(money_label)


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


func _physics_process(delta: float) -> void:
	if car == null or streamer == null:
		return
	step()
	if car is VehicleBody3D:
		stunt_step(delta, car.chassis_slip_angle(), car.linear_velocity.length(), car.wheels_in_contact(), _trees_near())
	var money := WorldSession.money()
	if money != _money_shown:
		_money_shown = money
		money_label.text = "$%d" % money


# Pick up the coins the car drives past — anywhere on the road around one counts
# (RoadSites.reached, swept over this step's travel). A wrecked car collects nothing.
func step() -> void:
	var p := Vector2(car.global_position.x, car.global_position.z)
	var from := _last_p if _last_p.distance_to(p) < RoadSites.TELEPORT_M else p
	_last_p = p
	if _wrecked:
		return
	var d := WorldSession.dropped()
	var at: Array = d.get("pos", [])
	if at.size() >= 3 and int(d.get("money", 0)) > 0 and p.distance_to(Vector2(float(at[0]), float(at[2]))) <= streamer.settings.dropped_reach_m:
		recover_dropped()
	var i := streamer.sites.reached(from, p, RoadSites.road_margin(streamer.settings), _has_loot)
	if i >= 0:
		collect(i)


func _has_loot(site: int) -> bool:
	return not loot_at(site).is_empty()


# The car was teleported (respawn, travel, R reset) to `p`: the next step must not sweep from where
# it was, or the straight line through the terrain would count as a drive past.
func car_teleported(p: Vector2) -> void:
	_last_p = p
	_reset_stunts()


func respawned(_site: int, _wreck: Vector3) -> void:
	_wrecked = false
	_reset_stunts()


# Pay for risky driving: a drift, fast stretch or jump pays for its length once it ends, and a tree in
# `near` (ids from _trees_near) pays once it's passed. Taking a hit voids whatever is under way.
func stunt_step(dt: float, slip: float, speed: float, wheels_down: int, near: Array) -> void:
	if _wrecked:
		return
	var s := streamer.settings
	_settled = _settled or wheels_down >= 3
	_streak("Drift", dt, wheels_down >= 3 and speed >= s.drift_min_speed_mps and absf(slip) >= deg_to_rad(s.drift_min_angle_deg), s.drift_money_per_s, s.stunt_min_s)
	_streak("Speed", dt, speed >= s.fast_speed_mps, s.fast_money_per_s, s.stunt_min_s)
	_streak("Jump", dt, _settled and wheels_down == 0, s.jump_money_per_s, s.jump_min_s)
	var still := {}
	for id in near:
		still[id] = _near.get(id, speed >= s.near_miss_min_speed_mps)
	for id in _near:
		if _near[id] and not still.has(id):
			_pay("Near miss", s.near_miss_money)
	_near = still


func _streak(label: String, dt: float, on: bool, per_s: float, min_s: float) -> void:
	var st: Array = _streaks[label]
	if on:
		st[0] += dt
		st[1] = 0.0
	elif st[0] > 0.0:
		st[1] += dt
		if st[1] >= streamer.settings.stunt_grace_s:
			if st[0] >= min_s:
				_pay(label, roundi(st[0] * per_s))
			st[0] = 0.0
			st[1] = 0.0


# Trees near the car, one id per tree: every tree of a field shares one collision body, told apart
# by shape index.
func _trees_near() -> Array:
	if _near_query == null:
		_near_query = PhysicsShapeQueryParameters3D.new()
		_near_query.shape = SphereShape3D.new()
		_near_query.exclude = [(car as CollisionObject3D).get_rid()]
	(_near_query.shape as SphereShape3D).radius = streamer.settings.near_miss_radius_m
	_near_query.transform = Transform3D(Basis.IDENTITY, car.global_position)
	var out := []
	for hit in car.get_world_3d().direct_space_state.intersect_shape(_near_query, 16):
		var body: Node = hit["collider"]
		if body != null and body.get_parent() is BillboardField:
			out.append("%d:%d" % [body.get_instance_id(), hit["shape"]])
	return out


func _pay(label: String, value: int) -> void:
	WorldSession.set_money(WorldSession.money() + value)
	Audio.play_beep(Config.data.coin_pickup_sfx_freq_hz, Config.data.coin_pickup_sfx_duration_sec)
	_say("%s +$%d" % [label, value])


func _void_stunts() -> void:
	for label in _streaks:
		if label == "Jump":
			continue  # every landing jolts the car enough to count as a hit
		_streaks[label][0] = 0.0
		_streaks[label][1] = 0.0
	for id in _near:
		_near[id] = false


func _reset_stunts() -> void:
	for st: Array in _streaks.values():
		st[0] = 0.0
		st[1] = 0.0
	_near.clear()
	_settled = false


func collect(site: int) -> void:
	var value := int(loot_at(site).get("value", 0))
	var col := WorldSession.list("collected")
	col.append(site)
	WorldSession.set_list("collected", col)
	_spent[site] = true
	streamer.refresh_loot_marker(site)
	pay_coin(value)
	collected.emit(site, value)


# A coin's money into the wallet, with its beep and "+$N" (a road coin, or a cold-open trail coin).
func pay_coin(value: int) -> void:
	WorldSession.set_money(WorldSession.money() + value)
	Audio.play_beep(Config.data.coin_pickup_sfx_freq_hz, Config.data.coin_pickup_sfx_duration_sec)
	_say("+$%d" % value)


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
	_dropped_node = _crystal(Vector3(float(at[0]), float(at[1]), float(at[2])))


func _crystal(pos: Vector3) -> Node3D:
	var mat := ShaderMaterial.new()
	var s := streamer.settings
	mat.shader = DROP_CRYSTAL
	mat.set_shader_parameter("color", s.drop_crystal_color)
	var root := Node3D.new()
	root.name = "DroppedMoney"
	for up in [1.0, -1.0]:
		var half := CylinderMesh.new()  # a 4-sided cone: one half of the crystal
		half.top_radius = 0.0 if up > 0.0 else s.drop_crystal_radius_m
		half.bottom_radius = s.drop_crystal_radius_m if up > 0.0 else 0.0
		half.height = s.drop_crystal_top_m if up > 0.0 else s.drop_crystal_bottom_m
		half.radial_segments = 4
		half.rings = 1
		half.cap_top = false
		half.cap_bottom = false
		half.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = half
		mi.position.y = s.drop_crystal_float_m + up * half.height * 0.5
		root.add_child(mi)
	add_child(root)
	root.global_position = pos
	return root


# Show a crystal at `pos` during the boot so its shader compiles then, not on the first wreck.
func warm_up(pos: Vector3) -> void:
	clear_warm_up()
	_warm_crystal = _crystal(pos)
	_warm_crystal.name = "CrystalWarmUp"


func clear_warm_up() -> void:
	if is_instance_valid(_warm_crystal):
		_warm_crystal.queue_free()
	_warm_crystal = null


# Rest stop `site` is lit: its biome ring's stock goes on sale.
func site_lit(site: int) -> void:
	unlock(clampi(streamer.sites.ring[site], 0, streamer.settings.ring_count - 1))


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
	said.emit(text, streamer.settings.toast_s)
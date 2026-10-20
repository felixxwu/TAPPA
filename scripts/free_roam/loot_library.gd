class_name LootLibrary
extends RefCounted
# Docs: features/loot.md — update in the same change as this file.
# Tests: tests/headless/test_loot.gd — extend in the same change.
# What can be found in the free-roam world, and where (todo/2026-10-19-free-roam-pivot.md,
# decisions 13–18). Pure and seeded: the same world seed and catalogue always place the same loot.
#
# An ITEM is a small dict:
#   {"kind": "car",    "id": <CarLibrary id>}                         — a car title
#   {"kind": "part",   "id": <BoostLibrary id>, "level": <int>}       — a part (a former boost)
#   {"kind": "part",   "id": "engine_swap:<EngineLibrary id>"}         — an engine
#   {"kind": "part",   "id": "drivetrain:<Drivetrain.DriveMode int>"}  — a drivetrain kit
#   {"kind": "rumour", "ring": <int>}                                  — reveals that ring's loot
#
# THE PACING SPLIT (decision 3: cars and parts should run out with the biomes). Ring r's table:
#   * cars: the catalogue sorted by cost, cut into ring_count even runs, cheapest innermost;
#   * parts: every BoostLibrary part at level r, so the same part is better further out;
#   * engines: the swap-tier engines sorted by power, cut the same way from ring 1 outward;
#   * drivetrain kits: one per drive mode, from ring 1 outward;
#   * a rumour of ring r + 1 (none in the last ring).
# Fitted parts reach the car ONLY through the owned-car funnel keys (`fielded`): boosts,
# swapped_engine and drivetrain_override, which UpgradeLibrary / Car.apply_owned already read
# (decision 51 — no parallel modifier path).

static func item_key(item: Dictionary) -> String:
	match String(item.get("kind", "")):
		"rumour":
			return "rumour:%d" % int(item.get("ring", 0))
		"part":
			return "part:%s:%d" % [String(item["id"]), int(item.get("level", 0))]
	return "%s:%s" % [String(item.get("kind", "")), String(item.get("id", ""))]


static func is_engine(item: Dictionary) -> bool:
	return String(item.get("id", "")).begins_with("engine_swap:")


static func is_drivetrain(item: Dictionary) -> bool:
	return String(item.get("id", "")).begins_with("drivetrain:")


# The loot table for every ring, index = ring.
static func ring_tables(ring_count: int) -> Array:
	var tables: Array = []
	for r in ring_count:
		tables.append([])
	if ring_count <= 0:
		return tables
	var cars: Array = CarLibrary.all().duplicate()
	cars.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("cost", 0)) < int(b.get("cost", 0)))
	for i in cars.size():
		tables[mini(i * ring_count / maxi(cars.size(), 1), ring_count - 1)].append({"kind": "car", "id": String(cars[i]["id"])})
	for r in ring_count:
		for id in BoostLibrary.CATALOGUE.keys():
			tables[r].append({"kind": "part", "id": String(id), "level": r})
	var outer := maxi(ring_count - 1, 1)
	var engines: Array = []
	for e in EngineLibrary.all():
		if bool((e as Dictionary).get("swap_tier", false)):
			engines.append(e)
	engines.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("peak_torque", 0.0)) * float(a.get("redline_rpm", 0.0)) \
			< float(b.get("peak_torque", 0.0)) * float(b.get("redline_rpm", 0.0)))
	for i in engines.size():
		var r: int = mini(1 + i * outer / maxi(engines.size(), 1), ring_count - 1) if ring_count > 1 else 0
		tables[r].append({"kind": "part", "id": "engine_swap:%s" % String(engines[i]["id"])})
	var modes: Array = Drivetrain.DriveMode.values()
	for i in modes.size():
		var r: int = mini(1 + i * outer / maxi(modes.size(), 1), ring_count - 1) if ring_count > 1 else 0
		tables[r].append({"kind": "part", "id": "drivetrain:%d" % int(modes[i])})
	for r in ring_count - 1:
		tables[r].append({"kind": "rumour", "ring": r + 1})
	return tables


# How much an item is worth putting at the end of a dead end: cars, then engines, then rumours,
# then drivetrain kits, then ordinary parts. Dead ends are offered the best first (decision 30).
static func _rank(item: Dictionary) -> int:
	if String(item["kind"]) == "car":
		return 0
	if is_engine(item):
		return 1
	if String(item["kind"]) == "rumour":
		return 2
	if is_drivetrain(item):
		return 3
	return 4


# --- the pool: which site shows what, right now ----------------------------------------------------
#
# Every car and part exists ONCE (decision 17, tightened): it is in the pool until the player has it
# (owned, fitted, in the stash, carried, or lying in the dropped pile) — then it is gone from every
# site at once. A ring's sites show its remaining pool: dead ends first with the best items, then
# loot slots, in a seeded order; with more sites than items each item shows at several sites (all
# of them empty out together when it's taken). A site the player has emptied is SPENT: nothing
# ever shows there again. A ring with more items than free sites keeps its best and moves the rest
# to the nearest ring with sites to spare (if no ring has any, those items show nowhere — the world
# has more things left than free sites; loot_slot_spacing_m keeps sites plentiful),
# and a ring with no loot sites at all (the road network never reached it) folds its table into
# the nearest ring that has some.

# For each ring, the rings whose tables its sites carry. `site_counts[r]` = loot sites in ring r.
static func pool_rings(site_counts: PackedInt32Array) -> Array:
	var n := site_counts.size()
	var out: Array = []
	for r in n:
		out.append([])
	for r in n:
		var host := -1
		for d in n:
			for c in [r - d, r + d]:
				if host < 0 and c >= 0 and c < n and site_counts[c] > 0:
					host = c
		if host >= 0:
			(out[host] as Array).append(r)
	return out


# The remaining pool of `table`: the items whose item_key is not in `taken`, best first.
static func remaining(table: Array, taken: Dictionary) -> Array:
	var out: Array = []
	for item: Dictionary in table:
		if not taken.has(item_key(item)):
			out.append(item)
	var ranked := out.duplicate()
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra := _rank(a)
		var rb := _rank(b)
		return ra < rb or (ra == rb and out.find(a) < out.find(b)))
	return ranked


# What every loot site shows now: {site: item}. `used` is the spent (emptied) sites.
static func assign(sites: RoadSites, ring_count: int, world_seed: int, taken: Dictionary, used: Array) -> Dictionary:
	var tables := ring_tables(ring_count)
	var order: Array = []  # per ring: its loot sites, dead ends first, each group seeded
	var counts := PackedInt32Array()
	counts.resize(ring_count)
	var dead: Array = []
	var slots: Array = []
	for r in ring_count:
		dead.append([])
		slots.append([])
	for i in sites.count():
		if sites.kind[i] == RoadSites.Kind.REST:
			continue
		var r := clampi(sites.ring[i], 0, ring_count - 1)
		(dead[r] if sites.kind[i] == RoadSites.Kind.DEAD_END else slots[r]).append(i)
		counts[r] += 1
	for r in ring_count:
		order.append(_shuffled(dead[r], world_seed, r * 2 + 1) + _shuffled(slots[r], world_seed, r * 2 + 2))
	var used_ids: Array = []
	for u in used:
		used_ids.append(int(u))
	var hosts := pool_rings(counts)
	# Each ring's free sites (never emptied) and its remaining pool, best first.
	var free: Array = []
	var pools: Array = []
	for r in ring_count:
		var f: Array = []
		for site: int in order[r]:
			if not used_ids.has(site):
				f.append(site)
		free.append(f)
		var table: Array = []
		for t: int in hosts[r]:
			table.append_array(tables[t])
		pools.append(remaining(table, taken))
	# A ring with more items than free sites keeps its best ones and moves the rest to the nearest
	# ring with sites to spare (inward first), so nothing is ever stuck with nowhere to show.
	var overflow: Array = []  # [item, from ring]
	for r in ring_count:
		var pool: Array = pools[r]
		while pool.size() > (free[r] as Array).size():
			overflow.append([pool.pop_back(), r])
	for o: Array in overflow:
		var host := -1
		for d in range(1, ring_count):
			for c in [int(o[1]) - d, int(o[1]) + d]:
				if host < 0 and c >= 0 and c < ring_count and (free[c] as Array).size() > (pools[c] as Array).size():
					host = c
		if host >= 0:
			(pools[host] as Array).append(o[0])
	var out := {}
	for r in ring_count:
		var pool: Array = pools[r]
		if pool.is_empty():
			continue
		var j := 0
		for site: int in free[r]:
			out[site] = pool[j % pool.size()]
			j += 1
	return out


static func _shuffled(ids: Array, world_seed: int, salt: int) -> Array:
	var a := ids.duplicate()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(world_seed, salt))
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t = a[i]
		a[i] = a[j]
		a[j] = t
	return a


# --- parts on a car -------------------------------------------------------------------------------

# Whether `part` can go on `owned` alongside what it already has. One of each part id, one engine,
# and one drivetrain kit (a kit for the car's own layout does nothing, so it isn't offered).
static func can_fit(owned: Dictionary, part: Dictionary) -> bool:
	if String(part.get("kind", "")) != "part":
		return false
	if is_drivetrain(part):
		var mode := int(String(part["id"]).substr("drivetrain:".length()))
		if mode == UpgradeLibrary.stock_drive_mode(owned):
			return false
	for p: Dictionary in owned.get("parts", []):
		if String(p["id"]) == String(part["id"]):
			return false
	return true


# The part already in the slot `part` would take (an engine for an engine, a kit for a kit), or {}.
static func occupant(owned: Dictionary, part: Dictionary) -> Dictionary:
	for p: Dictionary in owned.get("parts", []):
		if (is_engine(part) and is_engine(p)) or (is_drivetrain(part) and is_drivetrain(p)):
			return p
	return {}


# The owned-car dict the fielding pipeline should see: the car's fitted `parts` written onto the
# funnel's own keys. Car.apply_owned does the rest.
static func fielded(owned: Dictionary) -> Dictionary:
	var out := owned.duplicate(true)
	var boosts: Array = []
	out.erase("swapped_engine")
	out.erase("drivetrain_override")
	for p: Dictionary in owned.get("parts", []):
		var id := String(p["id"])
		if is_engine(p):
			out["swapped_engine"] = id.substr("engine_swap:".length())
		elif is_drivetrain(p):
			out["drivetrain_override"] = int(id.substr("drivetrain:".length()))
		else:
			var effect := BoostLibrary.magnitude_for(id, int(p.get("level", 0)))
			if not effect.is_empty():
				boosts.append({"id": id, "effect": effect})
	out["boosts"] = boosts
	return out


# --- names ---------------------------------------------------------------------------------------

static func label(item: Dictionary) -> String:
	match String(item.get("kind", "")):
		"car":
			return "Car: %s" % String(CarLibrary.by_id(String(item["id"])).get("name", item["id"]))
		"rumour":
			return "Rumour of the next biome"
	var id := String(item.get("id", ""))
	if is_engine(item):
		return "Engine: %s" % String(EngineLibrary.by_id(id.substr("engine_swap:".length())).get("name", id))
	if is_drivetrain(item):
		var mode := int(id.substr("drivetrain:".length()))
		return "%s conversion" % String(Drivetrain.DriveMode.keys()[mode] if mode < Drivetrain.DriveMode.size() else str(mode))
	return "%s (level %d)" % [BoostLibrary.label_for(id), int(item.get("level", 0)) + 1]


# The card icon (icons/cards/<name>.svg) an item shows on a card list.
static func icon(item: Dictionary) -> String:
	match String(item.get("kind", "")):
		"car":
			return "car"
		"rumour":
			return "rumour"
	if is_engine(item):
		return "engine_swap"
	if is_drivetrain(item):
		return "drivetrain"
	return String(item.get("id", "generic"))


# An item's card text, short enough for a card: [title, subtitle] — the name, then what it is.
static func card_text(item: Dictionary) -> PackedStringArray:
	var id := String(item.get("id", ""))
	match String(item.get("kind", "")):
		"car":
			return PackedStringArray([String(CarLibrary.by_id(id).get("name", id)), "Car"])
		"rumour":
			return PackedStringArray(["Rumour", "Of the next biome"])
	if is_engine(item):
		return PackedStringArray([String(EngineLibrary.by_id(id.substr("engine_swap:".length())).get("name", id)), "Engine"])
	if is_drivetrain(item):
		var mode := int(id.substr("drivetrain:".length()))
		return PackedStringArray([CarLibrary.drive_text(mode) + " kit", "Drivetrain conversion"])
	return PackedStringArray([BoostLibrary.label_for(id), "Level %d" % (int(item.get("level", 0)) + 1)])


# An item's colour on the ground, its beam and the minimap: gold a car title, orange an engine,
# green a drivetrain kit, cyan a part, white a rumour.
static func colour(item: Dictionary) -> Color:
	match String(item.get("kind", "")):
		"car":
			return Color(1.0, 0.8, 0.2)
		"rumour":
			return Color(0.95, 0.95, 0.95)
	if is_engine(item):
		return Color(1.0, 0.45, 0.15)
	if is_drivetrain(item):
		return Color(0.4, 1.0, 0.45)
	return Color(0.3, 0.85, 1.0)


# The floating name over an item on the ground: what it is, not which one.
static func ground_label(item: Dictionary) -> String:
	match String(item.get("kind", "")):
		"car":
			return "New car"
		"rumour":
			return "Rumour"
	if is_engine(item):
		return "New engine"
	if is_drivetrain(item):
		return "Drivetrain kit"
	return "New upgrade"

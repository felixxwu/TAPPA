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


# Place every ring's table on its sites. Returns {site id: item}. Dead ends take the best items
# first, then loot slots take the rest in a seeded order. A ring with more items than sites
# spills the leftovers into the next ring out (and the last ring into earlier ones); sites left
# over stay empty (a dead end with nothing is a lookout).
static func place(sites: RoadSites, ring_count: int, world_seed: int) -> Dictionary:
	var tables := ring_tables(ring_count)
	var by_ring: Array = []
	for r in ring_count:
		by_ring.append({"dead": [], "slots": []})
	for i in sites.count():
		var k := sites.kind[i]
		if k == RoadSites.Kind.REST:
			continue
		var r := clampi(sites.ring[i], 0, ring_count - 1)
		by_ring[r]["dead" if k == RoadSites.Kind.DEAD_END else "slots"].append(i)
	var out := {}
	var spill: Array = []
	var order := range(ring_count)
	for r in order:
		var items: Array = (tables[r] as Array) + spill
		spill = []
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _rank(a) < _rank(b))
		var dead: Array = _shuffled(by_ring[r]["dead"], world_seed, r * 2 + 1)
		var slots: Array = _shuffled(by_ring[r]["slots"], world_seed, r * 2 + 2)
		var free: Array = dead + slots
		for j in items.size():
			if j < free.size():
				out[free[j]] = items[j]
			else:
				spill.append(items[j])
	# Leftovers past the last ring go back inward to any empty site.
	if not spill.is_empty():
		for r in range(ring_count - 1, -1, -1):
			for i in (by_ring[r]["dead"] as Array) + (by_ring[r]["slots"] as Array):
				if spill.is_empty():
					break
				if not out.has(i):
					out[i] = spill.pop_front()
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

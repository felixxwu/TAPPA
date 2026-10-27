class_name LootRules
extends RefCounted
# Docs: features/loot.md — update in the same change as this file.
# Tests: tests/headless/test_loot.gd — extend in the same change.
# What the free-roam shops sell, and what it costs (todo/2026-10-19-free-roam-pivot.md, decision 3
# and the coin economy). Pure: the same catalogue always gives the same stock.
#
# An ITEM is a small dict:
#   {"kind": "car",    "id": <CarLibrary id>}                         — a car
#   {"kind": "part",   "id": <BoostLibrary id>, "level": <int>}       — a part (a former boost)
#   {"kind": "part",   "id": "engine_swap:<EngineLibrary id>"}         — an engine
#   {"kind": "part",   "id": "drivetrain:<Drivetrain.DriveMode int>"}  — a drivetrain kit
#
# THE PACING SPLIT (decision 3: cars and parts should run out with the biomes): every car, swap-tier
# engine and boost part names its own biome `ring` and `price` in its library entry, and drivetrain
# kits in KITS. A ring's stock goes on sale once a checkpoint in it is lit. Ring 0's cars are the
# starter choice.
# Fitted parts reach the car ONLY through the owned-car funnel keys (`fielded`): boosts,
# swapped_engine and drivetrain_override, which UpgradeLibrary / Car.apply_owned already read
# (decision 51 — no parallel modifier path).

static func item_key(item: Dictionary) -> String:
	if String(item.get("kind", "")) == "part":
		return "part:%s:%d" % [String(item["id"]), int(item.get("level", 0))]
	return "%s:%s" % [String(item.get("kind", "")), String(item.get("id", ""))]


static func is_engine(item: Dictionary) -> bool:
	return String(item.get("id", "")).begins_with("engine_swap:")


static func is_drivetrain(item: Dictionary) -> bool:
	return String(item.get("id", "")).begins_with("drivetrain:")


const KITS := {
	Drivetrain.DriveMode.RWD: {"ring": 1, "price": 2500},
	Drivetrain.DriveMode.AWD: {"ring": 2, "price": 5000},
	Drivetrain.DriveMode.FWD: {"ring": 3, "price": 3000},
}


static func starter_cars() -> PackedStringArray:
	var out := PackedStringArray()
	for car: Dictionary in CarLibrary.all():
		if int(car.get("ring", 0)) == 0:
			out.append(String(car["id"]))
	return out


# What every ring sells, index = ring. A ring past ring_count folds into the last.
static func ring_tables(ring_count: int) -> Array:
	var tables: Array = []
	for r in ring_count:
		tables.append([])
	if ring_count <= 0:
		return tables
	var last := ring_count - 1
	for car: Dictionary in CarLibrary.all():
		tables[mini(int(car.get("ring", 0)), last)].append({"kind": "car", "id": String(car["id"])})
	for id in BoostLibrary.CATALOGUE.keys():
		var r := mini(int(BoostLibrary.CATALOGUE[id].get("ring", 0)), last)
		tables[r].append({"kind": "part", "id": String(id), "level": r})
	for e: Dictionary in EngineLibrary.all():
		if bool(e.get("swap_tier", false)):
			tables[mini(int(e.get("ring", 0)), last)].append({"kind": "part", "id": "engine_swap:%s" % String(e["id"])})
	for mode in KITS:
		tables[mini(int(KITS[mode]["ring"]), last)].append({"kind": "part", "id": "drivetrain:%d" % int(mode)})
	return tables


# What `item` costs in a shop, from its catalogue entry.
static func price(item: Dictionary) -> int:
	var id := String(item.get("id", ""))
	if String(item.get("kind", "")) == "car":
		return int(CarLibrary.by_id(id).get("price", 0))
	if is_engine(item):
		return int(EngineLibrary.by_id(id.substr("engine_swap:".length())).get("price", 0))
	if is_drivetrain(item):
		return int(KITS.get(int(id.substr("drivetrain:".length())), {}).get("price", 0))
	return int(BoostLibrary.CATALOGUE.get(id, {}).get("price", 0))


# For each ring, the rings whose stock its checkpoints sell. `site_counts[r]` = rest stops in ring r:
# a ring the road network gave no rest stop folds into the nearest ring that has one, or its stock
# could never go on sale.
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


# The coins a coin spot in `ring` is worth.
static func coin_value(settings: FreeRoamSettings, ring: int) -> int:
	return settings.coin_value + settings.coin_value_per_ring * maxi(ring, 0)


# --- parts on a car -------------------------------------------------------------------------------
# A car's `parts` are the parts unlocked for it, each switched on or off (`on`, true when missing).
# A part belongs to the car it was unlocked for. Engines and drivetrain kits share a slot: only one
# of each can be on, and switching one on switches the other off.

static func is_on(part: Dictionary) -> bool:
	return bool(part.get("on", true))


# Whether `part` can be unlocked for `owned`.
static func can_fit(owned: Dictionary, part: Dictionary) -> bool:
	return fit_block_reason(owned, part).is_empty()


# Why `part` can't be unlocked for `owned`, as a short card label ("Already RWD"), or "" when it can.
# A kit for the car's own layout would do nothing: switching its other kit off changes it back.
static func fit_block_reason(owned: Dictionary, part: Dictionary) -> String:
	if String(part.get("kind", "")) != "part":
		return "Can't fit"
	if is_drivetrain(part):
		var mode := int(String(part["id"]).substr("drivetrain:".length()))
		if mode == UpgradeLibrary.stock_drive_mode(owned):
			return "Already " + CarLibrary.drive_text(mode)
	for p: Dictionary in owned.get("parts", []):
		if String(p["id"]) == String(part["id"]):
			return "Already unlocked"
	return ""


# Every part the shops can ever sell `owned`: the whole catalogue, less a drivetrain kit for its
# own stock layout (which it can never fit). Includes the parts it has already unlocked.
static func parts_for(owned: Dictionary) -> Array:
	var out: Array = []
	for item: Dictionary in ring_tables(1)[0]:
		if String(item["kind"]) != "part":
			continue
		if is_drivetrain(item) and int(String(item["id"]).substr("drivetrain:".length())) == UpgradeLibrary.stock_drive_mode(owned):
			continue
		out.append(item)
	return out


# The garage card's "x / y upgrades" line: parts unlocked for `owned` (on or off) out of every
# part it could have.
static func upgrades_text(owned: Dictionary) -> String:
	return "%d / %d upgrades" % [(owned.get("parts", []) as Array).size(), parts_for(owned).size()]


# `parts` with the one at `index` switched on or off. Switching an engine or kit on switches off
# whichever other one of its kind was on.
static func toggled(parts: Array, index: int) -> Array:
	var out := parts.duplicate(true)
	var part: Dictionary = out[index]
	var on := not is_on(part)
	part["on"] = on
	if on:
		for i in out.size():
			var p: Dictionary = out[i]
			if i != index and ((is_engine(part) and is_engine(p)) or (is_drivetrain(part) and is_drivetrain(p))):
				p["on"] = false
	return out


# The owned-car dict the fielding pipeline should see: the car's switched-on `parts` written onto the
# funnel's own keys. Car.apply_owned does the rest.
static func fielded(owned: Dictionary) -> Dictionary:
	var out := owned.duplicate(true)
	var boosts: Array = []
	out.erase("swapped_engine")
	out.erase("drivetrain_override")
	for p: Dictionary in owned.get("parts", []):
		if not is_on(p):
			continue
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

# The card icon (icons/cards/<name>.png) an item shows on a card list.
static func icon(item: Dictionary) -> String:
	match String(item.get("kind", "")):
		"car":
			return "car"
	if is_engine(item):
		return "engine_swap"
	if is_drivetrain(item):
		return "drivetrain"
	return String(item.get("id", "generic"))


# An item's card text, short enough for a card: [title, desc] — the name, then what it does.
static func card_text(item: Dictionary) -> PackedStringArray:
	var id := String(item.get("id", ""))
	match String(item.get("kind", "")):
		"car":
			return PackedStringArray([String(CarLibrary.by_id(id).get("name", id)), ""])
	if is_engine(item):
		var engine_id := id.substr("engine_swap:".length())
		var layout := String(EngineLibrary.by_id(engine_id).get("layout", "")).to_upper()
		return PackedStringArray([layout + " engine",
			"A %d hp engine swap." % roundi(CarLibrary.horsepower({"engine": engine_id}))])
	if is_drivetrain(item):
		var mode := int(id.substr("drivetrain:".length()))
		return PackedStringArray([CarLibrary.drive_text(mode) + " kit", "Changes driven wheels."])
	return PackedStringArray([BoostLibrary.label_for(id), BoostLibrary.blurb_for(id)])

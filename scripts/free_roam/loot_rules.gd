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
#   {"kind": "part",   "id": "drivetrain:<Drivetrain.DriveMode int>"}  — a drivetrain kit
#   {"kind": "part",   "id": "tire:<TIRES key>"}                       — a set of tires
#
# THE PACING SPLIT (decision 3: cars and parts should run out with the biomes): every car and boost
# part names its own biome `ring` and `price` in its library entry, and drivetrain
# kits and tires in KITS and TIRES. A ring's stock goes on sale once a checkpoint in it is lit. Ring 0's
# cars are the starter choice.
# Fitted parts reach the car ONLY through the owned-car funnel keys (`fielded`): boosts,
# swapped_engine and drivetrain_override, which UpgradeLibrary / Car.apply_owned already read. Engines
# aren't sold: cars swap them between each other (`engine_from`, Save.swap_engines).
# (decision 51 — no parallel modifier path).

static func item_key(item: Dictionary) -> String:
	if String(item.get("kind", "")) == "part":
		return "part:%s:%d" % [String(item["id"]), int(item.get("level", 0))]
	return "%s:%s" % [String(item.get("kind", "")), String(item.get("id", ""))]


# An engine bought back when the shops sold them. Older saves can still hold one; it does nothing now.
static func is_engine(item: Dictionary) -> bool:
	return String(item.get("id", "")).begins_with("engine_swap:")


static func is_drivetrain(item: Dictionary) -> bool:
	return String(item.get("id", "")).begins_with("drivetrain:")


static func is_tire(item: Dictionary) -> bool:
	return String(item.get("id", "")).begins_with("tire:")


# What the Shop's Upgrades page holds: every part without a page of its own.
static func is_upgrade(item: Dictionary) -> bool:
	return String(item.get("kind", "")) == "part" and not is_tire(item) and not is_engine(item) and not is_drivetrain(item)


# `mass_kg` is what the layout's driveline weighs over a front-drive car's: a kit adds the difference
# from the car's stock layout, so going from AWD to RWD makes it lighter.
const KITS := {
	Drivetrain.DriveMode.RWD: {"ring": 1, "price": 2500, "mass_kg": 30},
	Drivetrain.DriveMode.AWD: {"ring": 2, "price": 5000, "mass_kg": 90},
	Drivetrain.DriveMode.FWD: {"ring": 3, "price": 3000, "mass_kg": 0},
}

# The tires on sale; a car with none switched on runs its stock tires. `effect_fields` maps each
# UpgradeLibrary.EFFECTS key to the GameConfig field holding its strength. They don't scale with
# level, so they stay out of BoostLibrary.
const TIRES := {
	"gravel": {
		"ring": 0, "price": 800,
		"mass_kg": 8, "label": "Gravel tires", "blurb": "Best on loose roads.",
		"effect_fields": {
			"tire_grip_mult": "shop_tire_gravel_flat",
			"tire_tarmac_grip_mult": "shop_tire_gravel_tarmac",
			"tire_snow_grip_mult": "shop_tire_gravel_snow",
		},
	},
	"road": {
		"ring": 1, "price": 1500,
		"mass_kg": 4, "label": "Road tires", "blurb": "Best on tarmac.",
		"effect_fields": {
			"tire_grip_mult": "shop_tire_road_flat",
			"tire_tarmac_grip_mult": "shop_tire_road_tarmac",
			"tire_snow_grip_mult": "shop_tire_road_snow",
		},
	},
	"snow": {
		"ring": 3, "price": 3000,
		"mass_kg": 6, "label": "Snow tires", "blurb": "Best on snow and ice.",
		"effect_fields": {
			"tire_grip_mult": "shop_tire_snow_flat",
			"tire_tarmac_grip_mult": "shop_tire_snow_tarmac",
			"tire_snow_grip_mult": "shop_tire_snow_snow",
		},
	},
}


static func _tire_entry(item: Dictionary) -> Dictionary:
	return TIRES.get(String(item.get("id", "")).substr("tire:".length()), {})


# The effect dict a tire resolves to, read live off the config like BoostLibrary.magnitude_for.
static func _tire_effect(item: Dictionary) -> Dictionary:
	var effect := {}
	var fields: Dictionary = _tire_entry(item).get("effect_fields", {})
	for key in fields:
		effect[key] = float(Config.data.get(String(fields[key])))
	return effect


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
	for mode in KITS:
		tables[mini(int(KITS[mode]["ring"]), last)].append({"kind": "part", "id": "drivetrain:%d" % int(mode)})
	for id in TIRES:
		tables[mini(int(TIRES[id]["ring"]), last)].append({"kind": "part", "id": "tire:%s" % String(id)})
	return tables


# What `item` costs in a shop, from its catalogue entry.
static func price(item: Dictionary) -> int:
	var id := String(item.get("id", ""))
	if String(item.get("kind", "")) == "car":
		return int(CarLibrary.by_id(id).get("price", 0))
	if is_drivetrain(item):
		return int(KITS.get(int(id.substr("drivetrain:".length())), {}).get("price", 0))
	if is_tire(item):
		return int(_tire_entry(item).get("price", 0))
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
# A part belongs to the car it was unlocked for. Drivetrain kits, tires and turbos each share a slot: only one of each can be on, and switching one on switches the other off.

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
	var unlocked := (owned.get("parts", []) as Array).filter(func(p: Dictionary) -> bool: return not is_engine(p))
	return "%d / %d upgrades" % [unlocked.size(), parts_for(owned).size()]


# Which slot a part shares with others of its kind, or "" if it can be on alongside anything.
static func _slot(part: Dictionary) -> String:
	if is_drivetrain(part):
		return "drivetrain"
	if is_tire(part):
		return "tire"
	return String(BoostLibrary.CATALOGUE.get(String(part.get("id", "")), {}).get("slot", ""))


# Which owned model's engine `owned` is running: its own until a swap (Save.swap_engines).
static func engine_owner(owned: Dictionary) -> String:
	return String(owned.get("engine_from", owned.get("model_id", "")))


# The engine swap card's line naming that engine, like "Fjord F-15 engine".
static func engine_name(owned: Dictionary) -> String:
	var model := engine_owner(owned)
	return "%s engine" % String(CarLibrary.by_id(model).get("name", model))


# `parts` with the one at `index` switched on or off. Switching on a part with a slot switches off
# whichever other part in that slot was on.
static func toggled(parts: Array, index: int) -> Array:
	var out := parts.duplicate(true)
	var part: Dictionary = out[index]
	var on := not is_on(part)
	part["on"] = on
	if on:
		for i in out.size():
			var p: Dictionary = out[i]
			if i != index and not _slot(part).is_empty() and _slot(p) == _slot(part):
				p["on"] = false
	return out


# `parts` with every tire switched off, which puts the car back on its stock tires.
static func on_stock_tires(parts: Array) -> Array:
	var out := parts.duplicate(true)
	for p: Dictionary in out:
		if is_tire(p):
			p["on"] = false
	return out


# What a fitted part adds to `owned`'s weight.
static func _part_mass_kg(owned: Dictionary, part: Dictionary) -> float:
	var id := String(part.get("id", ""))
	if is_tire(part):
		return float(_tire_entry(part).get("mass_kg", 0.0))
	if is_drivetrain(part):
		var mode := int(id.substr("drivetrain:".length()))
		return float(KITS.get(mode, {}).get("mass_kg", 0.0)) - float(KITS.get(UpgradeLibrary.stock_drive_mode(owned), {}).get("mass_kg", 0.0))
	return float(BoostLibrary.CATALOGUE.get(id, {}).get("mass_kg", 0.0))


# The owned-car dict the fielding pipeline should see: the car's switched-on `parts` written onto the
# funnel's own keys. Car.apply_owned does the rest.
static func fielded(owned: Dictionary) -> Dictionary:
	var out := owned.duplicate(true)
	var boosts: Array = []
	var added_kg := 0.0
	out.erase("swapped_engine")
	if owned.has("engine_from"):
		out["swapped_engine"] = String(CarLibrary.by_id(engine_owner(owned)).get("engine", ""))
	out.erase("drivetrain_override")
	for p: Dictionary in owned.get("parts", []):
		if not is_on(p) or is_engine(p):
			continue
		var id := String(p["id"])
		added_kg += _part_mass_kg(owned, p)
		if is_drivetrain(p):
			out["drivetrain_override"] = int(id.substr("drivetrain:".length()))
		elif is_tire(p):
			var tire := _tire_effect(p)
			if not tire.is_empty():
				boosts.append({"id": id, "effect": tire})
		else:
			var effect := BoostLibrary.magnitude_for(id, int(p.get("level", 0)))
			if not effect.is_empty():
				boosts.append({"id": id, "effect": effect})
	# First in the list, so a weight-saving part scales it whatever order the parts were bought in.
	if added_kg != 0.0:
		boosts.push_front({"id": "part_weight", "effect": {"mass_add": added_kg}})
	out["boosts"] = boosts
	return out


# What `owned` weighs and makes with its switched-on parts, worked out through the same funnel that
# fields the real car. Power is at full boost; nitrous isn't counted, as it's only on while held.
static func fitted_stats(owned: Dictionary) -> Dictionary:
	var car := fielded(owned)
	var spec := CarLibrary.for_owned(owned)
	var stock_id := String(spec.get("engine", ""))
	var engine_id := EngineSwap.current_engine_id(car, stock_id)
	var engine := EngineLibrary.by_id(engine_id)
	var mode := int(car.get("drivetrain_override", spec.get("drive_mode", -1)))
	if engine.is_empty():
		return {"mass": float(spec.get("mass", 0.0)), "hp": 0.0, "drive_mode": mode, "max_hp": float(spec.get("max_hp", 0.0))}
	var cfg := GameConfig.new()
	EngineLibrary.apply(engine, cfg)
	cfg.mass = EngineSwap.recompute_mass(float(spec.get("mass", 0.0)),
		float(EngineLibrary.by_id(stock_id).get("mass", 0.0)), float(engine.get("mass", 0.0)))
	# A stock boosted engine's rated power already includes its boost, so only a change to it counts.
	var engine_boost := _full_boost_factor(cfg)
	UpgradeLibrary.apply(car, cfg)
	return {"mass": cfg.mass, "hp": CarLibrary.horsepower({"engine": engine_id}) * _full_boost_factor(cfg) / engine_boost,
		"drive_mode": mode, "max_hp": float(spec.get("max_hp", 0.0)) * cfg.max_hp_mult}


static func _full_boost_factor(cfg: GameConfig) -> float:
	var turbo := 1.0 + cfg.turbo_boost_gain if cfg.turbo_enabled else 1.0
	return turbo * (1.0 + cfg.supercharger_boost_gain if cfg.has_supercharger_physics() else 1.0)


# The Shop's header line: the car, then its weight, power, driven wheels and health with the parts on it.
static func shop_header(owned: Dictionary) -> String:
	var stats := fitted_stats(owned)
	return "%s · %d kg · %d hp · %s · %d health" % [String(CarLibrary.for_owned(owned).get("name", owned.get("model_id", ""))),
		roundi(stats["mass"]), roundi(stats["hp"]), CarLibrary.drive_text(stats["drive_mode"]), roundi(stats["max_hp"])]


# --- names ---------------------------------------------------------------------------------------

# The card icon (icons/cards/<name>.png) an item shows on a card list.
static func icon(item: Dictionary) -> String:
	match String(item.get("kind", "")):
		"car":
			return "car"
	if is_drivetrain(item):
		return "drivetrain"
	if is_tire(item):
		return "tire"
	var id := String(item.get("id", "generic"))
	return String(BoostLibrary.CATALOGUE.get(id, {}).get("icon", id))


# An item's card text, short enough for a card: [title, desc] — the name, then what it does.
static func card_text(item: Dictionary) -> PackedStringArray:
	var id := String(item.get("id", ""))
	match String(item.get("kind", "")):
		"car":
			return PackedStringArray([String(CarLibrary.by_id(id).get("name", id)), ""])
	if is_drivetrain(item):
		var mode := int(id.substr("drivetrain:".length()))
		return PackedStringArray([CarLibrary.drive_text(mode) + " kit", "Changes driven wheels."])
	if is_tire(item):
		var tire := _tire_entry(item)
		return PackedStringArray([String(tire.get("label", id)), String(tire.get("blurb", ""))])
	return PackedStringArray([BoostLibrary.label_for(id), BoostLibrary.blurb_for(id)])

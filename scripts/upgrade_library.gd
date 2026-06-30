class_name UpgradeLibrary
extends RefCounted
# The catalogue of upgrade ITEMS — authored content (like CarLibrary /
# RallyLibrary), not player state. The save profile holds the player side
# (inventory counts + each OwnedCar's installed_upgrades, keyed by the stable
# `id` here); this library defines what those ids mean and what each one DOES to
# a fielded car's config. See todo/upgrade-catalogue.md.
#
# Distinguish from TUNING: tuning (features/tuning.md, the lift) is free, reversible
# per-car config nudges. Upgrades are consumable items that change a car's baseline
# and are FULLY CONSUMED when applied — fitting a part uses it up for good; it never
# returns to inventory (not on swap, and not when the car is wrecked).

# The one consumable's id, referenced by Save when a repair kit is used.
const REPAIR_KIT_ID := "repair_kit"

# The valid non-consumable slots. A car holds at most one upgrade per slot;
# installing into an occupied slot replaces the incumbent (Save.install_upgrade).
const SLOTS := ["engine", "aero", "chassis", "brakes"]


# Each entry is an UpgradeDef. `effect` maps to GameConfig fields applied in
# pipeline step 2 (baseline → UPGRADES → tuning → damage). `*_mult` keys multiply
# the baseline; additive keys add; `unlocks_*` are flags that gate tuning sliders
# (features/tuning.md), not numeric config. The concrete part list + exact numbers
# are a balance pass (deferred); these are legible single-purpose defaults.
const UPGRADES: Array[Dictionary] = [
	{
		"id": "engine_stage1", "name": "Stage 1 Engine Kit", "slot": "engine",
		"tier": 1, "consumable": false, "effect": {"peak_torque_mult": 1.10},
	},
	{
		"id": "engine_stage2", "name": "Stage 2 Engine Kit", "slot": "engine",
		"tier": 3, "consumable": false, "effect": {"peak_torque_mult": 1.25},
	},
	{
		"id": "aero_kit", "name": "Aero Kit", "slot": "aero",
		"tier": 2, "consumable": false,
		"effect": {"unlocks_aero_tuning": true, "downforce_front": 0.2, "downforce_rear": 0.2},
	},
	{
		"id": "weight_reduction", "name": "Weight Reduction", "slot": "chassis",
		"tier": 2, "consumable": false, "effect": {"mass_mult": 0.90},
	},
	{
		"id": "brake_kit", "name": "Big Brake Kit", "slot": "brakes",
		"tier": 2, "consumable": false,
		"effect": {"brake_torque_mult": 1.20, "unlocks_brake_bias": true},
	},
	{
		"id": REPAIR_KIT_ID, "name": "Repair Kit", "slot": "",
		"tier": 1, "consumable": true, "effect": {},
	},
]


# --- Lookups -----------------------------------------------------------------

static func index_of(id: String) -> int:
	for i in UPGRADES.size():
		if UPGRADES[i]["id"] == id:
			return i
	return -1


static func by_id(id: String) -> Dictionary:
	var i := index_of(id)
	return UPGRADES[i] if i >= 0 else {}


# The slot an item occupies, or "" for consumables / unknown ids.
static func slot_of(id: String) -> String:
	return String(by_id(id).get("slot", ""))


static func is_consumable(id: String) -> bool:
	return bool(by_id(id).get("consumable", false))


# --- Effect application (pipeline step 2) ------------------------------------

# Apply every installed upgrade's effect on top of the CarLibrary baseline that
# apply_car already wrote into `cfg` (step 1). Pure: mutates the passed-in live
# `cfg` only, never the authored .tres. Unknown ids and flag-only effects
# (`unlocks_*`) are skipped here — flags gate the tuning sliders, not config.
static func apply(owned_car: Dictionary, cfg: GameConfig) -> void:
	for item_id in owned_car.get("installed_upgrades", []):
		var effect: Dictionary = by_id(item_id).get("effect", {})
		for key in effect:
			var val: Variant = effect[key]
			match key:
				"peak_torque_mult":
					cfg.peak_torque *= float(val)
				"brake_torque_mult":
					cfg.brake_torque *= float(val)
				"mass_mult":
					cfg.mass *= float(val)
				"downforce_front":
					cfg.downforce_front += float(val)
				"downforce_rear":
					cfg.downforce_rear += float(val)
				"unlocks_aero_tuning", "unlocks_brake_bias":
					pass  # flags gate tuning sliders (features/tuning.md), not cfg


# --- Effective car stats (display + eligibility) -----------------------------

# A copy of the CarLibrary entry `meta` with the stats that drive the power-to-
# weight figure (peak_torque, mass) adjusted by the car's installed upgrades, so
# a fitted engine kit or weight reduction shifts the displayed kW/kg AND can
# qualify / disqualify the car for a rally's pw band (RallyLibrary.is_eligible).
# Pure: returns a fresh dict, never touches the authored CARS entry. Only the
# meta-level numeric stats are adjusted here; downforce / brake / tuning gates
# don't feed power-to-weight, so they're left to the live-config `apply` above.
static func effective_meta(owned_car: Dictionary, meta: Dictionary) -> Dictionary:
	if meta.is_empty():
		return meta
	var out := meta.duplicate()
	for item_id in owned_car.get("installed_upgrades", []):
		var effect: Dictionary = by_id(item_id).get("effect", {})
		for key in effect:
			match key:
				"peak_torque_mult":
					out["peak_torque"] = float(out.get("peak_torque", 0.0)) * float(effect[key])
				"mass_mult":
					out["mass"] = float(out.get("mass", 0.0)) * float(effect[key])
	return out


# --- Tuning gates ------------------------------------------------------------
# Aero / brake-bias tuning is only live when the matching upgrade is installed
# (todo/menus.md › tuning-lift knobs). These read the car's installed items.

static func aero_tuning_unlocked(owned_car: Dictionary) -> bool:
	return _has_flag(owned_car, "unlocks_aero_tuning")


static func brake_bias_unlocked(owned_car: Dictionary) -> bool:
	return _has_flag(owned_car, "unlocks_brake_bias")


static func _has_flag(owned_car: Dictionary, flag: String) -> bool:
	for item_id in owned_car.get("installed_upgrades", []):
		if bool(by_id(item_id).get("effect", {}).get(flag, false)):
			return true
	return false

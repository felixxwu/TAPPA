class_name UpgradeLibrary
extends RefCounted
# The catalogue of upgrade ITEMS — authored content (like CarLibrary /
# RallyLibrary), not player state. The save profile holds the player side
# (inventory counts + each OwnedCar's installed_upgrades, keyed by the stable
# `id` here); this library defines what those ids mean and what each one DOES to
# a fielded car's config. See todo/upgrade-catalogue.md.
#
# Distinguish from TUNING: tuning (features/tuning.md, the lift) is free, reversible
# per-car config nudges. Upgrades are items that change a car's baseline: applying
# one consumes it from the unlocked pool and fits it to that car FOR GOOD (it never
# returns to the pool — not on swap, and not when the car is wrecked), but a fitted
# part can be toggled on/off in the upgrades menu (OwnedCar.disabled_upgrades). Only
# ENABLED parts contribute effects; a car keeps at most one enabled per slot
# (Save.install_upgrade / set_upgrade_enabled).

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
		"tier": 1, "consumable": false,
		"effect": {"unlocks_aero_tuning": true, "downforce_front": 0.2, "downforce_rear": 0.2},
	},
	{
		"id": "weight_reduction", "name": "Weight Reduction", "slot": "chassis",
		"tier": 1, "consumable": false, "effect": {"mass_mult": 0.90},
	},
	{
		"id": "brake_kit", "name": "Big Brake Kit", "slot": "brakes",
		"tier": 1, "consumable": false,
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


# The applied upgrades that currently take effect on a car: installed minus the
# ones toggled off in the upgrades menu. Every effect/gate reader below (and any
# eligibility caller) goes through this, so a disabled part is inert everywhere.
static func enabled_upgrades(owned_car: Dictionary) -> Array:
	var disabled: Array = owned_car.get("disabled_upgrades", [])
	var out: Array = []
	for item_id in owned_car.get("installed_upgrades", []):
		if not disabled.has(item_id):
			out.append(item_id)
	return out


static func is_enabled(owned_car: Dictionary, item_id: String) -> bool:
	return not (owned_car.get("disabled_upgrades", []) as Array).has(item_id)


# --- Effect application (pipeline step 2) ------------------------------------

# Apply every ENABLED upgrade's effect on top of the CarLibrary baseline that
# apply_car already wrote into `cfg` (step 1); disabled parts stay fitted but
# inert. Pure: mutates the passed-in live `cfg` only, never the authored .tres.
# Unknown ids and flag-only effects (`unlocks_*`) are skipped here — flags gate
# the tuning sliders, not config.
static func apply(owned_car: Dictionary, cfg: GameConfig) -> void:
	for item_id in enabled_upgrades(owned_car):
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
# a fitted engine kit or weight reduction shifts the displayed HP/kg AND can
# qualify / disqualify the car for a rally's pw band (RallyLibrary.is_eligible).
# Pure: returns a fresh dict, never touches the authored CARS entry. Only the
# meta-level numeric stats are adjusted here; downforce / brake / tuning gates
# don't feed power-to-weight, so they're left to the live-config `apply` above.
static func effective_meta(owned_car: Dictionary, meta: Dictionary) -> Dictionary:
	if meta.is_empty():
		return meta
	var out := meta.duplicate()
	# The CarLibrary entry no longer carries peak_torque/redline — they live in
	# EngineLibrary. Seed the power-to-weight inputs from the referenced engine so
	# the upgrade multipliers below compound on the real base (and power_to_weight
	# reads the adjusted values off this dict). Only fill what's absent, so a meta
	# that already carries explicit peak_torque/redline (e.g. a synthetic fixture)
	# keeps its own values.
	# Resolve the CURRENT engine (swapped or stock) so a swapped car's torque/redline
	# drive its power-to-weight (features/engine-swap.md). Seed mass off the swap too.
	var stock_id := String(out.get("engine", ""))
	var current_id := EngineSwap.current_engine_id(owned_car, stock_id)
	var eng := EngineLibrary.by_id(current_id)
	if not out.has("peak_torque"):
		out["peak_torque"] = eng.get("peak_torque", 0.0)
	if not out.has("redline"):
		out["redline"] = eng.get("redline_rpm", 0.0)
	if current_id != stock_id and out.has("mass"):
		var stock_eng := EngineLibrary.by_id(stock_id)
		out["mass"] = EngineSwap.recompute_mass(
			float(out["mass"]), float(stock_eng.get("mass", 0.0)), float(eng.get("mass", 0.0)))
	for item_id in enabled_upgrades(owned_car):
		var effect: Dictionary = by_id(item_id).get("effect", {})
		for key in effect:
			match key:
				"peak_torque_mult":
					out["peak_torque"] = float(out.get("peak_torque", 0.0)) * float(effect[key])
				"mass_mult":
					out["mass"] = float(out.get("mass", 0.0)) * float(effect[key])
	# Detune scales the torque feeding power-to-weight, after the engine kits.
	var detune := clampf(float(owned_car.get("tuning", {}).get("engine_detune", 1.0)), 0.0, 1.0)
	out["peak_torque"] = float(out.get("peak_torque", 0.0)) * detune
	return out


# --- Tuning gates ------------------------------------------------------------
# Aero / brake-bias tuning is only live when the matching upgrade is installed
# (todo/menus.md › tuning-lift knobs). These read the car's installed items.

static func aero_tuning_unlocked(owned_car: Dictionary) -> bool:
	return _has_flag(owned_car, "unlocks_aero_tuning")


static func brake_bias_unlocked(owned_car: Dictionary) -> bool:
	return _has_flag(owned_car, "unlocks_brake_bias")


static func _has_flag(owned_car: Dictionary, flag: String) -> bool:
	for item_id in enabled_upgrades(owned_car):
		if bool(by_id(item_id).get("effect", {}).get(flag, false)):
			return true
	return false

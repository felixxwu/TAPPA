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

# The repair-kit consumable's id, referenced by Save when a repair kit is used.
const REPAIR_KIT_ID := "repair_kit"

# The engine-swap consumable's id, spent by Save.swap_engines. Earned like the
# repair kit (a low-weight reward-pool drop) and held in the shared inventory.
const ENGINE_SWAP_TOKEN_ID := "engine_swap_token"

# The valid non-consumable slots. A car holds at most one upgrade per slot;
# installing into an occupied slot replaces the incumbent (Save.install_upgrade).
const SLOTS := ["turbo", "aero", "weight", "brakes", "drivetrain"]


# Each entry is an UpgradeDef. `effect` maps to GameConfig fields applied in
# pipeline step 2 (baseline → UPGRADES → tuning → damage). `*_mult` keys multiply
# the baseline; additive keys add; `unlocks_*` are flags that gate tuning sliders
# (features/tuning.md), not numeric config. The concrete part list + exact numbers
# are a balance pass (deferred); these are legible single-purpose defaults.
const UPGRADES: Array[Dictionary] = [
	{
		"id": "turbo_small", "name": "Small Turbo", "menu_label": "Small", "slot": "turbo", "tier": 1, "consumable": false,
		"effect": {"install_turbo": {
			"turbo_boost_gain": 0.35, "turbo_inertia": 6.0e-3, "turbo_omega_ref": 10000.0,
			"turbo_drive_gain": 0.03, "turbo_drag_coef": 1.0e-6, "turbo_parasitic_friction": 5.0,
			"engine_turbo_whistle_gain": 0.015, "engine_turbo_bov_gain": 0.005,
		}},
	},
	{
		"id": "turbo_large", "name": "Big Turbo", "menu_label": "Big", "slot": "turbo", "tier": 2, "consumable": false,
		"effect": {"install_turbo": {
			"turbo_boost_gain": 0.8, "turbo_inertia": 2.0e-2, "turbo_omega_ref": 14000.0,
			"turbo_drive_gain": 0.028, "turbo_drag_coef": 6.5e-7, "turbo_parasitic_friction": 18.0,
			"engine_turbo_whistle_gain": 0.025, "engine_turbo_bov_gain": 0.008,
		}},
	},
	{
		"id": "aero_kit", "name": "Aero Kit", "slot": "aero",
		"tier": 1, "consumable": false,
		"effect": {"unlocks_aero_tuning": true, "downforce_front": 3, "downforce_rear": 3},
	},
	# The "weight" slot is a p/w lever, not an earn-gated part row. The two BALLAST
	# options add weight and are `free` (always selectable on every car, never drawn as
	# a reward — see reward_system) so the player can shed p/w to enter a lower class;
	# the LIGHTWEIGHT option removes weight and is the one earned reward-pool drop. The
	# menu shows each as a rounded kg delta off the car's base mass (upgrades_menu).
	{
		"id": "ballast_large", "name": "Heavy Ballast", "slot": "weight",
		"tier": 1, "consumable": false, "free": true, "effect": {"mass_mult": 1.5},
	},
	{
		"id": "ballast_small", "name": "Light Ballast", "slot": "weight",
		"tier": 1, "consumable": false, "free": true, "effect": {"mass_mult": 1.2},
	},
	{
		"id": "weight_reduction", "name": "Weight Reduction", "slot": "weight",
		"tier": 1, "consumable": false, "effect": {"mass_mult": 0.80},
	},
	{
		"id": "brake_kit", "name": "Big Brake Kit", "slot": "brakes",
		"tier": 1, "consumable": false,
		"effect": {"brake_torque_mult": 1.20, "unlocks_brake_bias": true},
	},
	{
		"id": "drivetrain_swap", "name": "Drivetrain Swap", "slot": "drivetrain",
		"tier": 2, "consumable": false, "effect": {"unlocks_drivetrain_swap": true},
	},
	{
		"id": REPAIR_KIT_ID, "name": "Repair Kit", "slot": "",
		"tier": 1, "consumable": true, "effect": {},
	},
	{
		"id": ENGINE_SWAP_TOKEN_ID, "name": "Engine Swap Token", "slot": "",
		"tier": 1, "consumable": true, "effect": {},
	},
]


# --- Lookups -----------------------------------------------------------------
# Test seam + stable-id lookups via the shared Registry helper (scripts/registry.gd),
# matching CarLibrary/EngineLibrary. An empty override means "use the shipped
# UPGRADES"; tests call override_for_test()/reset() to run against a synthetic list.
static var _seam := Registry.Seam.new(UPGRADES)

static func all() -> Array[Dictionary]:
	return _seam.all()

static func override_for_test(upgrades: Array[Dictionary]) -> void:
	_seam.override_for_test(upgrades)

static func reset() -> void:
	_seam.reset()


static func index_of(id: String) -> int:
	return Registry.index_of(all(), id)


static func by_id(id: String) -> Dictionary:
	return Registry.by_id(all(), id)


# The slot an item occupies, or "" for consumables / unknown ids.
static func slot_of(id: String) -> String:
	return String(by_id(id).get("slot", ""))


static func is_consumable(id: String) -> bool:
	return bool(by_id(id).get("consumable", false))


# A `free` part is always selectable on every car (no earning) and is never drawn as
# a reward — the ballast weight options. Everything else must be won and fitted first.
static func is_free(id: String) -> bool:
	return bool(by_id(id).get("free", false))


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


# --- Effect descriptor table -------------------------------------------------
# The single source of truth for what each `effect` key DOES, so apply() (live cfg)
# and effective_meta() (power-to-weight inputs) can't silently drift — adding an
# effect means adding one row here. Each row:
#   field    — the target GameConfig / meta field ("" for turbo / flag-only)
#   op       — "mult" (field *= val), "add" (field += val), "install_turbo"
#              (special: enable + splat the sub-dict), or "flag" (gates a tuning
#              slider, no config effect)
#   feeds_pw — whether it changes a power-to-weight input (mass / torque), so
#              effective_meta must mirror it; the rest are cfg-only.
const EFFECTS := {
	"install_turbo":       {"field": "", "op": "install_turbo", "feeds_pw": true},
	"brake_torque_mult":   {"field": "brake_torque", "op": "mult", "feeds_pw": false},
	"mass_mult":           {"field": "mass", "op": "mult", "feeds_pw": true},
	"downforce_front":     {"field": "downforce_front", "op": "add", "feeds_pw": false},
	"downforce_rear":      {"field": "downforce_rear", "op": "add", "feeds_pw": false},
	"unlocks_aero_tuning": {"field": "", "op": "flag", "feeds_pw": false},
	"unlocks_brake_bias":  {"field": "", "op": "flag", "feeds_pw": false},
	"unlocks_drivetrain_swap": {"field": "", "op": "flag", "feeds_pw": false},
}


# --- Effect application (pipeline step 2) ------------------------------------

# Apply every ENABLED upgrade's effect on top of the CarLibrary baseline that
# apply_car already wrote into `cfg` (step 1); disabled parts stay fitted but
# inert. Pure: mutates the passed-in live `cfg` only, never the authored .tres.
# Unknown ids and flag-only effects (`unlocks_*`) are skipped here — flags gate
# the tuning sliders, not config. Driven by the EFFECTS table above.
static func apply(owned_car: Dictionary, cfg: GameConfig) -> void:
	for item_id in enabled_upgrades(owned_car):
		var effect: Dictionary = by_id(item_id).get("effect", {})
		for key in effect:
			var val: Variant = effect[key]
			var desc: Dictionary = EFFECTS.get(key, {})
			match desc.get("op", ""):
				"install_turbo":
					cfg.turbo_enabled = true
					for tkey in (val as Dictionary):
						cfg.set(tkey, (val as Dictionary)[tkey])
				"mult":
					var f: String = desc["field"]
					cfg.set(f, float(cfg.get(f)) * float(val))
				"add":
					var f: String = desc["field"]
					cfg.set(f, float(cfg.get(f)) + float(val))
				_:
					pass  # "flag" (gates tuning sliders) + unknown ids: no cfg effect


# --- Effective car stats (display + eligibility) -----------------------------

# A copy of the CarLibrary entry `meta` with the stats that drive the power-to-
# weight figure (peak_torque, mass) adjusted by the car's installed upgrades, so
# a fitted engine kit or weight reduction shifts the displayed hp/tonne AND can
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
	if not eng.is_empty():
		# Point the meta at the CURRENT engine so power_to_weight derives from the
		# fitted engine (not the stock one) after a swap.
		out["engine"] = current_id
	if not out.has("peak_torque"):
		out["peak_torque"] = eng.get("peak_torque", 0.0)
	if not out.has("redline"):
		out["redline"] = eng.get("redline_rpm", 0.0)
	if current_id != stock_id and out.has("mass"):
		var stock_eng := EngineLibrary.by_id(stock_id)
		out["mass"] = EngineSwap.recompute_mass(
			float(out["mass"]), float(stock_eng.get("mass", 0.0)), float(eng.get("mass", 0.0)))
	# Resolve the turbo boost gain: the stock engine's, overridden by an installed
	# turbo upgrade. Rated "at peak boost" — the displayed HP + power-to-weight
	# eligibility reflect the full boosted torque (features/forced-induction.md).
	var boost_gain := float(eng.get("turbo_boost_gain", 0.0))
	# Mirror only the power-to-weight-feeding effects (EFFECTS[*].feeds_pw), from the
	# same table apply() uses, so the two can't drift.
	for item_id in enabled_upgrades(owned_car):
		var effect: Dictionary = by_id(item_id).get("effect", {})
		for key in effect:
			var desc: Dictionary = EFFECTS.get(key, {})
			if not bool(desc.get("feeds_pw", false)):
				continue
			match desc["op"]:
				"mult":
					var f: String = desc["field"]
					out[f] = float(out.get(f, 0.0)) * float(effect[key])
				"install_turbo":
					boost_gain = float((effect[key] as Dictionary).get("turbo_boost_gain", boost_gain))
	out["peak_torque"] = float(out.get("peak_torque", 0.0)) * (1.0 + boost_gain)
	# Detune scales the torque feeding power-to-weight, after the boost rating.
	var detune := clampf(float(owned_car.get("tuning", {}).get("engine_detune", 1.0)), 0.0, 1.0)
	out["peak_torque"] = float(out.get("peak_torque", 0.0)) * detune
	# Report the player's chosen drivetrain (gated by the swap kit) so the stats panel
	# and RallyLibrary.is_eligible both see the swapped mode. -1 leaves stock in place.
	var drive_override := resolve_drive_override(owned_car)
	if drive_override >= 0:
		out["drive_mode"] = drive_override
	return out


# The effective meta at the car's MAXIMUM ACHIEVABLE power-to-weight — the ceiling the
# player can reach for FREE with what's already fitted: (1) engine tune forced to 100%
# (undo any detune), (2) every installed upgrade enabled (a part toggled off is turned
# back on), and (3) mass-ADDING ballast dropped (a `free` part the player can always
# remove, so it never counts against the car's potential). It does NOT fit parts the
# player hasn't installed. This is the meta a rally's pw_MIN floor is judged against
# (RallyLibrary.is_eligible's `floor_meta`): a car detuned or ballasted to fit a LOWER
# rally isn't "too weak" for a higher one if maxing it out clears the floor — the player
# will always tune up to enter (mirrors how an over-cap car detunes DOWN to duck the
# ceiling). Pure: builds a fresh owned-car dict, never mutates the input.
static func max_potential_meta(owned_car: Dictionary, meta: Dictionary) -> Dictionary:
	if meta.is_empty():
		return meta
	var maxed := owned_car.duplicate(true)
	var tuning: Dictionary = (maxed.get("tuning", {}) as Dictionary).duplicate()
	tuning["engine_detune"] = 1.0  # full power
	maxed["tuning"] = tuning
	maxed["disabled_upgrades"] = []  # enable every installed part...
	var kept: Array = []
	for item_id in maxed.get("installed_upgrades", []):
		# ...except mass-adding ballast (baseline is lighter and always available).
		if float(by_id(item_id).get("effect", {}).get("mass_mult", 1.0)) > 1.0:
			continue
		kept.append(item_id)
	maxed["installed_upgrades"] = kept
	return effective_meta(maxed, meta)


# --- Tuning gates ------------------------------------------------------------
# Aero / brake-bias tuning is only live when the matching upgrade is installed
# (todo/menus.md › tuning-lift knobs). These read the car's installed items.

static func aero_tuning_unlocked(owned_car: Dictionary) -> bool:
	return _has_flag(owned_car, "unlocks_aero_tuning")


static func brake_bias_unlocked(owned_car: Dictionary) -> bool:
	return _has_flag(owned_car, "unlocks_brake_bias")


static func drivetrain_swap_unlocked(owned_car: Dictionary) -> bool:
	# Unlike the aero / brake gates, the drivetrain kit has NO enable/disable — owning
	# it IS the unlock, and the selector's stock choice plays the "off" role (disabling
	# would just re-select the original drive mode). So this checks INSTALLED, not
	# enabled: a won-but-not-yet-podium-applied kit is usable immediately, not stranded.
	for item_id in owned_car.get("installed_upgrades", []):
		if bool(by_id(item_id).get("effect", {}).get("unlocks_drivetrain_swap", false)):
			return true
	return false


# The drive mode the player chose for this car (0/1/2), or -1 meaning "use the car's
# authored stock drive_mode". Gated: a stored override is inert unless the swap kit is
# fitted AND enabled, so removing/disabling the kit reverts the car to stock. The single
# resolver used by physics (car.gd), display/eligibility (effective_meta) and the garage.
static func resolve_drive_override(owned_car: Dictionary) -> int:
	if not drivetrain_swap_unlocked(owned_car):
		return -1
	return int(owned_car.get("drivetrain_override", -1))


static func _has_flag(owned_car: Dictionary, flag: String) -> bool:
	for item_id in enabled_upgrades(owned_car):
		if bool(by_id(item_id).get("effect", {}).get(flag, false)):
			return true
	return false

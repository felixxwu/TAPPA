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

# THERE IS NO REPAIR KIT. Damage is one-way: a car's HP only ever climbs back via
# the free between-event pit repair (Save.field_repair), and a WRECKED car is gone
# for good. The old `repair_kit` consumable — already unearnable, its drop weight
# pinned at 0 and its garage button hidden — is fully removed; wrecking out is now
# rescued by the Mystery Box granting a fresh car instead. See features/damage.md.

# The engine-swap consumable's id, spent by Save.swap_engines. Earned as a
# low-weight reward-pool drop and held in the shared inventory.
const ENGINE_SWAP_TOKEN_ID := "engine_swap_token"

# The mystery-box consumable's id. Granted instead of a normal reward draw when
# the driven car has nothing left to gain and the player is swap-token-rich
# (see RewardSystem.draw_upgrade), and as the wrecked-out safety net
# (Save.ensure_wreck_safety_net). Opened from the HQ garage row to gift a random
# upgrade to an owned car — or a whole new car when every car is wrecked.
const MYSTERY_BOX_ID := "mystery_box"

# The valid non-consumable slot ids. A car holds at most one ENABLED upgrade per slot
# (Save._enable_exclusive), so parts sharing a slot are alternatives, not stackables.
const SLOTS := ["turbo", "aero", "weight", "drivetrain", "nitrous"]

# Slots that are HIDDEN from the garage (upgrades_menu skips their rows) and whose parts
# are therefore fitted ENABLED whenever they are installed — enforced centrally in
# Save.install_upgrade, NOT at each award site.
#
# The two properties travel together on purpose: everywhere else, a won part is installed
# DISABLED and the reveal overlay enables the player's pick, which would leave a part in a
# hidden slot permanently dead — there is no row to switch it on from. Keeping the rule in
# Save.install_upgrade is what makes it hold for EVERY route a part can arrive by (the
# per-event draw, the challenge draw, and a mystery box), rather than only the ones someone
# remembered to special-case.
const HIDDEN_SLOTS := ["nitrous"]


static func is_hidden_slot(slot: String) -> bool:
	return HIDDEN_SLOTS.has(slot)


# Whether a part must be fitted enabled the moment it is installed, because its slot has no
# garage row to enable it from. See HIDDEN_SLOTS.
static func installs_enabled(item_id: String) -> bool:
	return is_hidden_slot(slot_of(item_id))


# Each entry is an UpgradeDef. `effect` maps to GameConfig fields applied in
# pipeline step 2 (baseline → UPGRADES → tuning → damage). `*_mult` keys multiply
# the baseline; additive keys add; `unlocks_*` are flags that gate tuning sliders
# (features/tuning.md), not numeric config. The concrete part list + exact numbers
# are a balance pass (deferred); these are legible single-purpose defaults.
const UPGRADES: Array[Dictionary] = [
	{
		"id": "turbo_small", "name": "Small Turbo", "menu_label": "Small", "slot": "turbo", "consumable": false,
		"effect": {"install_turbo": {
			"turbo_boost_gain": 0.35, "turbo_inertia": 6.0e-3, "turbo_omega_ref": 10000.0,
			"turbo_drive_gain": 0.03, "turbo_drag_coef": 1.0e-6, "turbo_parasitic_friction": 5.0,
			"engine_turbo_whistle_gain": 0.015, "engine_turbo_bov_gain": 0.005,
		}},
	},
	{
		# Doubly gated. PREREQUISITE (per-car): only drawable for a car that already has
		# a Small Turbo fitted — see requires_upgrade_id / prerequisite_met. And STAR-GATED
		# (garage-wide): absent from the reward pool entirely until the 8-star special
		# event is won — see unlocked_by_rally / rally_gate_met.
		"id": "turbo_large", "name": "Big Turbo", "menu_label": "Big", "slot": "turbo",
		"requires_upgrade_id": "turbo_small", "unlocked_by_rally": "sp_dust_trial",
		"consumable": false,
		"effect": {"install_turbo": {
			"turbo_boost_gain": 0.8, "turbo_inertia": 2.0e-2, "turbo_omega_ref": 14000.0,
			"turbo_drive_gain": 0.028, "turbo_drag_coef": 6.5e-7, "turbo_parasitic_friction": 18.0,
			"engine_turbo_whistle_gain": 0.025, "engine_turbo_bov_gain": 0.008,
		}},
	},
	{
		# Top of the forced-induction ladder, prerequisite-gated behind Big Turbo the
		# same way Big Turbo sits behind Small (per-car). Its peak gain is only a LITTLE
		# above Big Turbo's — the real advantage is that there's nothing to spool, so
		# belt boost is linear in rpm and arrives instantly
		# (EngineSim.supercharger_boost_fraction) — paid for with drag that GROWS with
		# revs (supercharger_parasitic_coef, N·m per 1000 rpm) rather than the turbo's
		# constant backpressure. Whistle/BOV gains are left alone: apply() clears
		# turbo_enabled so neither layer can fire.
		"id": "supercharger", "name": "Supercharger", "menu_label": "Supercharger", "slot": "turbo",
		"requires_upgrade_id": "turbo_large", "unlocked_by_rally": "sp_archipelago_trial",
		"consumable": false,
		"effect": {"install_supercharger": {
			"supercharger_boost_gain": 0.9, "supercharger_rpm_ref": 4200.0,
			"supercharger_parasitic_coef": 9.0,
			# Louder than the turbos' whistle gains: the blower whine is the signature
			# sound of the part, and it's the only forced-induction layer a blown car has.
			"engine_supercharger_whine_gain": 0.06,
		}},
	},
	{
		"id": "aero_kit", "name": "Aero Kit", "slot": "aero",
		"consumable": false,
		"effect": {"unlocks_aero_tuning": true, "downforce_front": 3, "downforce_rear": 3},
	},
	# The "weight" slot is a p/w lever, not an earn-gated part row. The two BALLAST
	# options add weight and are `free` (always selectable on every car, never drawn as
	# a reward — see reward_system) so the player can shed p/w to enter a lower class;
	# the LIGHTWEIGHT option removes weight and is the one earned reward-pool drop. The
	# menu shows each as a rounded kg delta off the car's base mass (upgrades_menu).
	{
		"id": "ballast_large", "name": "Heavy Ballast", "slot": "weight",
		"consumable": false, "free": true, "effect": {"mass_mult": 1.5},
	},
	{
		"id": "ballast_small", "name": "Light Ballast", "slot": "weight",
		"consumable": false, "free": true, "effect": {"mass_mult": 1.2},
	},
	{
		"id": "weight_reduction", "name": "Weight Reduction", "slot": "weight",
		"consumable": false, "effect": {"mass_mult": 0.80},
	},
	{
		# Star-gated behind the 16-star special. The strongest early unlock because it
		# rewrites the car's drive_mode, which changes which rallies the car is ELIGIBLE
		# for (RallyLibrary.is_eligible / hq._entry_plan) — so it visibly opens pins on the
		# map rather than just adding speed.
		"id": "drivetrain_swap", "name": "Drivetrain Conversion", "slot": "drivetrain",
		"unlocked_by_rally": "sp_lakeshore_trial",
		"consumable": false, "effect": {"unlocks_drivetrain_swap": true},
	},
	# --- Nitrous (features/nitrous.md) -----------------------------------------
	# Its own slot, invisible in the garage, auto-fitted enabled on award. A chained
	# ladder: each rung REPLACES the last (one enabled part per slot) and mixes the two
	# levers — tank seconds ("longer") and torque gain ("harder") — so the escalation
	# never reads as the same number three times. Deliberately absent from
	# effective_meta, so none of these can move a car's power-to-weight or eligibility.
	{
		"id": "nitrous", "name": "Nitrous", "slot": "nitrous",
		"unlocked_by_rally": "the_showdown", "consumable": false,
		"effect": {"install_nitrous": {"nitrous_boost_gain": 0.22, "nitrous_tank_seconds": 3.0}},
	},
	{
		"id": "nitrous_tank", "name": "Nitrous — Big Tank", "slot": "nitrous",
		"requires_upgrade_id": "nitrous", "unlocked_by_rally": "hc_showdown",
		"consumable": false,
		"effect": {"install_nitrous": {"nitrous_boost_gain": 0.24, "nitrous_tank_seconds": 5.0}},
	},
	{
		"id": "nitrous_shot", "name": "Nitrous — Big Shot", "slot": "nitrous",
		"requires_upgrade_id": "nitrous_tank", "unlocked_by_rally": "gr_showdown",
		"consumable": false,
		"effect": {"install_nitrous": {"nitrous_boost_gain": 0.38, "nitrous_tank_seconds": 5.0}},
	},
	{
		"id": "nitrous_race", "name": "Nitrous — Race Kit", "slot": "nitrous",
		"requires_upgrade_id": "nitrous_shot", "unlocked_by_rally": "gc_showdown",
		"consumable": false,
		"effect": {"install_nitrous": {"nitrous_boost_gain": 0.45, "nitrous_tank_seconds": 7.0}},
	},
	{
		"id": ENGINE_SWAP_TOKEN_ID, "name": "Engine Swap Token", "slot": "",
		"consumable": true, "effect": {},
	},
	{
		"id": MYSTERY_BOX_ID, "name": "Mystery Box", "slot": "",
		"consumable": true, "effect": {},
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


# --- Reward-pool weight -------------------------------------------------------
# Relative likelihood of an item when it's drawn from the reward pool. Optional, defaulting
# to 1.0 — and NOTHING authors one yet, so the pool is currently uniform. It exists because
# retiring `tier` removed the only rarity lever, and weights are the direct replacement (the
# pool already spoke in them — see ENGINE_SWAP_TOKEN_DROP_WEIGHT); authoring the actual
# values is the deferred balance pass. Tier gated by DIFFICULTY and had gone vestigial
# (everything sat at tier 1); the star gate now handles availability over time, and weight
# handles rarity within what is available.

static func pool_weight(id: String) -> float:
	return float(by_id(id).get("weight", 1.0))


# --- Star gate ----------------------------------------------------------------
# Availability over TIME, garage-wide: an item may be withheld from the reward pool
# entirely until a particular special event has been WON. "" / absent (the default)
# means ungated. Keyed on the RALLY, not on a raw star total, so reaching the star
# threshold isn't enough — the event has to actually be driven.
#
# Note `completed` in the profile already means a TOP-3 finish (Save.complete_rally is
# "Record a top-3 rally finish"), so this genuinely reads "was the event won".
#
# This gate is about EARNING a part, never about keeping one: a part already in
# installed_upgrades keeps applying (apply() walks installed_upgrades and never consults
# this), so a gate closing behind the player can't retroactively uninstall anything.

static func unlocked_by_rally(id: String) -> String:
	return String(by_id(id).get("unlocked_by_rally", ""))


# The item a given special unlocks, or {} if it gates none — the REVERSE of
# unlocked_by_rally. Lives here, next to the field it indexes, so any surface that wants to
# advertise "what does this event unlock" (the map pin today; a reveal banner or podium line
# tomorrow) shares one walk instead of growing its own.
static func unlocked_by(rally_id: String) -> Dictionary:
	if rally_id == "":
		return {}
	for item in all():
		if unlocked_by_rally(String(item["id"])) == rally_id:
			return item
	return {}


static func rally_gate_met(item_id: String, profile: Dictionary) -> bool:
	var rid := unlocked_by_rally(item_id)
	if rid == "":
		return true
	return bool((profile.get("rallies", {}) as Dictionary).get(rid, {}).get("completed", false))


# --- Prerequisite gate --------------------------------------------------------
# The per-CAR counterpart to the star gate above: some items (e.g. Big Turbo) only
# become winnable once THIS car already has another item (Small Turbo) fitted. "" (the
# default) means no prerequisite. Both gates must pass for an item to enter the pool.

static func requires_upgrade_id(id: String) -> String:
	return String(by_id(id).get("requires_upgrade_id", ""))


# Whether `item_id` is currently eligible to be drawn/won as a reward for
# `owned_car` on prerequisite grounds: true when it has none, or the
# prerequisite is already fitted TO THAT CAR. The gate is deliberately per-car,
# not garage-wide — upgrades are car-bound (installed_upgrades lives per
# OwnedCar), so each car has to earn its way up its own turbo ladder.
# Used by RewardSystem._parts_at_or_below.
static func prerequisite_met(item_id: String, owned_car: Dictionary) -> bool:
	var req := requires_upgrade_id(item_id)
	return req == "" or (owned_car.get("installed_upgrades", []) as Array).has(req)


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
#   field    — the target GameConfig / meta field ("" for induction / flag-only)
#   op       — "mult" (field *= val), "add" (field += val), "install_induction"
#              (special: enable one flag, clear the rival's, splat the sub-dict), or
#              "flag" (gates a tuning slider, no config effect)
#   feeds_pw — whether it changes a power-to-weight input (mass / torque), so
#              effective_meta must mirror it; the rest are cfg-only.
#
# FORCED-INDUCTION rows carry three more keys so the two parts share ONE op rather than a
# copied match arm each (a third induction type would then be a row, not more branches):
#   enable    — the cfg flag this part switches ON
#   clears    — {field: value} the RIVAL part's state is reset to. Turbo and supercharger
#               share the "turbo" slot, so fitting one must un-fit the other. Slot
#               exclusivity in Save._enable_exclusive already means only one can be
#               ENABLED, and the baseline may carry the other from the stock engine — but
#               making the clear SYMMETRIC here keeps it structural rather than resting on
#               that convention, so a future stock engine authoring a real
#               supercharger_boost_gain can't stack both multipliers under a fitted turbo.
#               Values are written as authored (typed), not coerced from a bare `false`.
#   gain_key  — the sub-dict key effective_meta reads to rate the car at peak boost.
const EFFECTS := {
	"install_turbo": {
		"field": "", "op": "install_induction", "feeds_pw": true,
		"enable": "turbo_enabled", "gain_key": "turbo_boost_gain",
		# A turbo cancels the blower BOTH ways: the audio flag and the belt gain that
		# switches its physics on (game_config.has_supercharger_physics).
		"clears": {"supercharger_enabled": false, "supercharger_boost_gain": 0.0},
	},
	"install_supercharger": {
		"field": "", "op": "install_induction", "feeds_pw": true,
		"enable": "supercharger_enabled", "gain_key": "supercharger_boost_gain",
		"clears": {"turbo_enabled": false},
	},
	# Nitrous writes its config fields and NOTHING else. feeds_pw is deliberately FALSE:
	# nitrous is a per-stage resource, not a permanent power level, so it must never reach
	# effective_meta's power-to-weight — otherwise fitting the reward could shove a car
	# over a rally's pw_max and lock it out of events it could previously enter.
	"install_nitrous": {"field": "", "op": "write_fields", "feeds_pw": false},
	"mass_mult":           {"field": "mass", "op": "mult", "feeds_pw": true},
	"downforce_front":     {"field": "downforce_front", "op": "add", "feeds_pw": false},
	"downforce_rear":      {"field": "downforce_rear", "op": "add", "feeds_pw": false},
	"unlocks_aero_tuning": {"field": "", "op": "flag", "feeds_pw": false},
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
				"install_induction":
					# Turn this part on, turn its slot rival off, then stamp the authored
					# fields. Order matters only in that `clears` runs BEFORE the splat, so
					# a part is free to author the very field it nominally clears.
					cfg.set(String(desc["enable"]), true)
					for ckey in (desc["clears"] as Dictionary):
						cfg.set(ckey, (desc["clears"] as Dictionary)[ckey])
					for tkey in (val as Dictionary):
						cfg.set(tkey, (val as Dictionary)[tkey])
				"write_fields":
					# Straight splat of the authored fields onto the config — no enable
					# flag, no slot rival to clear (has_nitrous() reads the values
					# themselves, so a zero gain/tank IS "not fitted").
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
# meta-level numeric stats are adjusted here; downforce / tuning gates
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
	# Resolve the forced-induction boost gain: the stock engine's turbo, overridden by an
	# installed induction upgrade (turbo OR supercharger). Rated "at peak boost" — the
	# displayed HP + power-to-weight eligibility reflect the full boosted torque
	# (features/forced-induction.md).
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
				"install_induction":
					# Whichever induction part is fitted REPLACES the other (same slot, and
					# apply() clears the rival), so its authored gain supersedes the stock
					# engine's. Which sub-key holds that gain comes from the descriptor, so
					# this arm never needs to know which part it is looking at.
					boost_gain = float((effect[key] as Dictionary).get(
						String(desc["gain_key"]), boost_gain))
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


# The effective meta at the car's MAXIMUM ACHIEVABLE power-to-weight — its true ceiling:
# (1) engine tune forced to 100% (undo any detune), (2) mass-ADDING ballast dropped (a
# `free` part the player can always remove, so it never counts against potential), and
# (3) the BEST part fitted in every slot, drawn from the whole catalogue — including parts
# the car does not own and parts whose star gate has not opened yet.
#
# That last point is the important one. With the best parts star-gated, what a car
# currently carries is a poor measure of what it can become — most of the time the good
# parts are still locked — so judging the floor on fitted hardware would lock players out
# of rallies they will comfortably grow into.
#
# This is the meta a rally's pw_MIN floor is judged against (RallyLibrary.is_eligible's
# `floor_meta`). pw_MAX still uses the car's REAL current stats, so a player can't sandbag
# into a class they'd dominate — the ceiling only ever makes a car eligible, never
# ineligible. The consequence, accepted deliberately: the floor is now very permissive
# (almost any car could eventually be turbo'd and lightened), so its remaining job is
# soft-lock prevention rather than class balance. pw_max is where balance lives.
#
# Per-slot maximisation is EXACT here, not a heuristic: only one part per slot can be
# enabled (Save._enable_exclusive) and the slots' effects are independent (turbo → torque,
# weight → mass, aero → downforce, drivetrain → a flag, nitrous → excluded from pw
# entirely), so the best combination is the best choice in each slot taken separately.
#
# Pure: builds a fresh owned-car dict, never mutates the input.
# `profile` selects WHICH ceiling — and the distinction is load-bearing:
#
#   {} (default)  ASPIRATIONAL: the whole catalogue, star gates ignored. "Could this car
#                 EVER do it?" Used for entry eligibility and the displayed ceiling, so a
#                 player is never locked out of a rally for lacking a part they will
#                 obviously grow into.
#   a profile     REACHABLE: only parts whose star gate is already open. "Can this player
#                 get there NOW?" Used by the SOFT-LOCK rescue check
#                 (RewardSystem._unlock_candidates) — judging that on the aspirational
#                 ceiling would conclude nobody is ever stuck, because every car could in
#                 principle be turbo'd, even when the turbo is locked behind an event the
#                 player cannot yet reach. That would silently disable the rescue grant.
static func max_potential_meta(owned_car: Dictionary, meta: Dictionary,
		profile: Dictionary = {}) -> Dictionary:
	if meta.is_empty():
		return meta
	var maxed := owned_car.duplicate(true)
	var tuning: Dictionary = (maxed.get("tuning", {}) as Dictionary).duplicate()
	tuning["engine_detune"] = 1.0  # full power
	maxed["tuning"] = tuning
	maxed["disabled_upgrades"] = []  # nothing parked
	maxed["installed_upgrades"] = _best_part_per_slot(maxed, meta, profile)
	return effective_meta(maxed, meta)


# The highest-power-to-weight part in each slot. Skips consumables (not slotted) and any
# part that ADDS mass (ballast is always removable, so it can't be part of a ceiling).
# Scores each candidate on its own — see the note above on why per-slot independence makes
# this exact. A non-empty `profile` restricts candidates to parts whose star gate is open.
static func _best_part_per_slot(base_car: Dictionary, meta: Dictionary,
		profile: Dictionary = {}) -> Array:
	var probe := base_car.duplicate(true)
	probe["disabled_upgrades"] = []
	# ONE pass over the catalogue, dispatching each candidate onto its own slot, rather than
	# re-scanning the whole table once per slot.
	var best_id := {}   # slot -> winning item id
	var best_pw := {}   # slot -> that item's power-to-weight
	for item in all():
		var slot := String(item.get("slot", ""))
		if slot == "" or bool(item.get("consumable", false)):
			continue
		if float((item.get("effect", {}) as Dictionary).get("mass_mult", 1.0)) > 1.0:
			continue
		var item_id := String(item["id"])
		if not profile.is_empty() and not rally_gate_met(item_id, profile):
			continue
		probe["installed_upgrades"] = [item_id]
		var pw := CarLibrary.power_to_weight(effective_meta(probe, meta))
		if pw > float(best_pw.get(slot, -1.0)):
			best_pw[slot] = pw
			best_id[slot] = item_id
	# Iterate SLOTS (not the dict) so the result order is the authored slot order, stable
	# regardless of catalogue order.
	var out: Array = []
	for slot in SLOTS:
		if best_id.has(slot):
			out.append(best_id[slot])
	return out


# --- Tuning gates ------------------------------------------------------------
# Aero tuning is only live when the aero kit is installed (todo/menus.md ›
# tuning-lift knobs). Brake bias is NOT gated — it's a free axis on every car.

static func aero_tuning_unlocked(owned_car: Dictionary) -> bool:
	return _has_flag(owned_car, "unlocks_aero_tuning")


static func drivetrain_swap_unlocked(owned_car: Dictionary) -> bool:
	# Unlike the aero gate, the drivetrain kit has NO enable/disable — owning
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

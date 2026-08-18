class_name UpgradeLibrary
extends RefCounted
# Docs: features/engine-swap.md, features/forced-induction.md, features/upgrade-catalogue.md — update in the same change as this file.
# Tests: tests/headless/test_engine.gd, tests/headless/test_turbo.gd, tests/headless/test_upgrade_library.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'UpgradeLibrary' tests/headless/` and read the assertions that pin what you are about to change (10 test files touch this script).
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

# THERE ARE NO CONSUMABLES LEFT. Every entry below is a PART fitted to a car. Three
# consumables have been retired in turn — the repair kit (damage is one-way; HP climbs
# back via the free between-event pit repair, Save.field_repair), the mystery box (parts
# are bought with stars whenever the player likes, so a random one had nothing to offer)
# and the engine swap token (swapping is free and unlimited once its rally unlocks it).
# The `consumable` flag itself survives because the code paths that respect it do — see
# Save.install_upgrade — but nothing shipped claims it. See features/damage.md.

# The valid non-consumable slot ids. A car holds at most one ENABLED upgrade per slot
# (Save._enable_exclusive), so parts sharing a slot are alternatives, not stackables.
#
# Order is the GARAGE TILE ORDER (UpgradeOptions.grid_slots walks this list), so a slot sits next to the
# one it is read alongside: `gearbox` follows `turbo` (both are Speed levers) and `tires`
# follows `aero` (both are Grip). It is also the order _best_part_per_slot reports in.
const SLOTS := ["turbo", "gearbox", "aero", "tires", "weight", "drivetrain", "nitrous"]
# The tyre slot by name. Named rather than spelled inline because the rival field mirrors
# the player's tyre through it (RallyLibrary.player_tire_id), and a typo there would fail
# silently as "the player has no tyre fitted".
const TIRE_SLOT := "tires"

# Slots that are HIDDEN from the garage (they get no grid tile) and whose parts
# are therefore fitted ENABLED whenever they are installed — enforced centrally in
# Save.install_upgrade, NOT at each award site.
#
# The two properties travel together on purpose: everywhere else, a won part is installed
# DISABLED and the reveal overlay enables the player's pick, which would leave a part in a
# hidden slot permanently dead — there is no row to switch it on from. Keeping the rule in
# Save.install_upgrade is what makes it hold for EVERY route a part can arrive by (the
# winning it at its prize rally, or buying a copy with stars), rather than only the ones
# someone remembered to special-case.
#
# CURRENTLY EMPTY. `nitrous` was the only member: it was hidden because a four-rung ladder
# auto-fitting its highest rung left the player nothing to decide. Now that it is a single
# part (see the Nitrous section below) it gets an ordinary garage row like every other
# slot, so the player can actually fit and unfit it — without a row, a won NOS could only
# ever be installed by the award path.
#
# Kept rather than deleted: the rule is real, is exercised by the test fixtures, and is
# what any future hidden slot would rely on. An empty list simply means nothing claims it.
const HIDDEN_SLOTS: Array[String] = []


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
		# menu_label "Super" — the turbo row carries FOUR options (Stock / Small / Big /
		# this) sharing one flow row that wraps when they do not fit, and "Supercharger" was
		# long enough to push itself onto a second line on its own. "Super" is the plain
		# short form of the full name above it, so the row still reads as the same part;
		# it also matches "Small" for length.
		"id": "supercharger", "name": "Supercharger", "menu_label": "Super", "slot": "turbo",
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
		# The `gearbox` slot's one part: a dog-ring sequential shift in place of the car's
		# H-pattern. It SETS shift_time outright rather than scaling the car's own — the kit
		# IS a specific piece of hardware, so it shifts at its own rate whatever it replaces,
		# and one authored number is what a designer tunes.
		#
		# NOTE the consequence, which is deliberate: this is an absolute figure, not a
		# guaranteed improvement. shift_time is per-ENGINE (EngineLibrary owns gear_ratios /
		# final_drive / shift_time, and an engine swap carries its whole gearbox with it — see
		# features/engine-swap.md), and any engine whose own gearbox is already quicker than
		# this gets SLOWER by fitting the kit. On the shipped roster that is the 7-speed
		# S tronic at 0.08 s; every other transmission sits at 0.22-0.35 s and gains. Fitting
		# is the player's choice and the part is never auto-fitted, so a car that would lose
		# out simply leaves it on Stock — but if that ever wants to be impossible, the fix is
		# a "take the better of the two" op here, NOT a per-engine table of exceptions.
		#
		# menu_label "Sequential" — the slot label already says "Gearbox", so the full name
		# would read "Gearbox   Stock  Sequential Gearbox".
		"id": "sequential_gearbox", "name": "Sequential Gearbox", "menu_label": "Sequential",
		"slot": "gearbox", "unlocked_by_rally": "sp_summit_trial",
		"consumable": false,
		"effect": {"shift_time_set": 0.1},
	},
	{
		"id": "aero_kit", "name": "Aero Kit", "slot": "aero",
		"consumable": false,
		"effect": {"unlocks_aero_tuning": true, "downforce_front": 3, "downforce_rear": 3},
	},
	{
		# The `tires` slot's top part: competition rubber, a flat multiplier on the car's
		# tyre μ. Its OWN slot rather than sharing `aero`, because grip from rubber and grip
		# from downforce are not alternatives — a car wants both, and one enabled part per
		# slot would have made them mutually exclusive.
		#
		# Deliberately NOT a power-to-weight input (see EFFECTS below): it must never move a
		# car's rally eligibility, the same rule the aero kit follows. It does show on the
		# Simple page's GRIP row, via grip_meta.
		#
		# menu_label "Race" — the slot label already says "Tires".
		# Won at The Foothills Trial, the gateway pin into the Alps, so the player has
		# winter rubber before the frozen corner rather than after it.
		#
		# A SPECIALISED compound, not a smaller Race Tire. It used to be exactly that —
		# one flat multiplier, a strictly-weaker rung of the same ladder — which made the
		# choice between the two trivial the moment both were owned, and meant a part
		# called "Snow Tires" behaved identically on snow and on dry asphalt. It now
		# carries three figures: the flat term below is what it is worth on GRAVEL (the
		# neutral surface, unchanged), and the two surface terms buy a large bonus on snow
		# ground back for a penalty on tarmac. Net on asphalt it is WORSE than the car's
		# own rubber — that is the trade, and it is what makes the slot a real decision
		# per rally rather than a permanent upgrade. See features/drivetrain-and-tires.md.
		# ADDING A PART IS A THREE-PART CHANGE — the row, the docs, the tests. This note is
		# here rather than only in the file header ~170 lines up, because that is where an
		# agent editing a table entry actually is. Docs: features/upgrade-catalogue.md AND
		# features/drivetrain-and-tires.md (which also narrates what the tyre slot holds —
		# two docs describe this slot and only one is usually updated). Sibling tyre parts
		# are rally-gated via unlocked_by_rally; leaving a new one ungated is a choice, so
		# say why in a comment if you make it.
		"id": "snow_tires", "name": "Snow Tires", "menu_label": "Snow",
		"slot": "tires", "unlocked_by_rally": "sp_woodland_trial",
		"consumable": false,
		"effect": {
			"tire_grip_mult": 1.08,
			"tire_snow_grip_mult": 1.20,
			"tire_tarmac_grip_mult": 0.85,
		},
	},
	{
		"id": "race_tires", "name": "Race Tires", "menu_label": "Race",
		"slot": "tires", "unlocked_by_rally": "sn_showdown",
		"consumable": false,
		"effect": {"tire_grip_mult": 1.15},
	},
	# The "weight" slot holds ONE part: the lightweight kit. It used to also carry two free
	# BALLAST options that ADDED mass, so a player could shed power-to-weight to drop into a
	# lower class. Entry is categorical now, so there is nothing to duck under by getting
	# slower, and an option whose whole effect is "make your car worse" is a row every
	# player scrolls past. Removed; a profile still carrying one is cleaned up on load by
	# Save._prune_unknown_upgrades, which drops any installed id the catalogue no longer has.
	#
	# The `free` and `mass_mult > 1.0` BRANCHES survive (Auto still refuses to fit anything
	# that adds mass, and a free part still installs without a purchase), so the synthetic
	# fx_ballast in tests/headless/upgrade_fixtures.gd keeps covering them.
	{
		"id": "weight_reduction", "name": "Weight Reduction", "slot": "weight",
		"consumable": false, "effect": {"mass_mult": 0.80},
	},
	{
		# Star-gated behind the 16-star special. The strongest early unlock because it
		# rewrites the car's drive_mode, which changes which rallies the car is ELIGIBLE
		# for (RallyLibrary.is_eligible / hq._entry_plan) — so it visibly opens pins on the
		# map rather than just adding speed.
		# NO SLOT. This is a CAPABILITY MARKER, not a fittable part: what it grants is the
		# garage-wide right to convert (drivetrain_swap_unlocked reads its rally gate), and
		# the drivetrain slot's picker lists drive MODES, which are bought per car and per
		# layout. It sat in slot "drivetrain" for a long time, which was a lie with teeth —
		# a part claiming a slot whose picker could never offer it, so no second car could
		# acquire it by any means. "" is the established "not in any slot" value (the solver
		# and the pickers both skip it), so the entry now says what it is.
		"id": "drivetrain_swap", "name": "Drivetrain Conversion", "slot": "",
		"unlocked_by_rally": "sp_lakeshore_trial",
		"consumable": false, "effect": {"unlocks_drivetrain_swap": true},
	},
	# --- Nitrous (features/nitrous.md) -----------------------------------------
	# Its own slot, invisible in the garage, auto-fitted enabled on award. Deliberately
	# absent from effective_meta, so it cannot move a car's power-to-weight or eligibility.
	#
	# ONE PART, not a ladder. This was four chained rungs (NOS stage 1-4), each replacing
	# the last and each gated on a different showdown special. Collapsed to a single part
	# carrying the TOP rung's numbers: the intermediate rungs were a long climb whose
	# individual steps the player could not feel — 0.22 to 0.24 boost between the first two
	# — and every one of them occupied a special's entire prize slot to deliver it.
	#
	# Gated on the FIRST showdown the map reaches, not the last one stage 4 used to sit
	# behind. The endgame is completing every special, so a part gated on the final one is a
	# reward with no game left to spend it in.
	{
		"id": "nitrous", "name": "NOS", "slot": "nitrous",
		"unlocked_by_rally": "the_showdown", "consumable": false,
		"effect": {"install_nitrous": {"nitrous_boost_gain": 0.6, "nitrous_tank_seconds": 20.0}},
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
	CarStatBounds.invalidate()  # the roster-wide stat scale is derived from BOTH catalogues

static func reset() -> void:
	_seam.reset()
	CarStatBounds.invalidate()


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
# retiring `tier` removed the only rarity lever, and weights are the direct replacement;
# authoring the actual values is the deferred balance pass. Tier gated by DIFFICULTY and had gone vestigial
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
	# An id that is not in the catalogue FAILS CLOSED. It used to fail open: by_id returned
	# {}, so unlocked_by_rally returned "", so "no authored gate" and the caller was told
	# UNLOCKED. Every caller was then one rename away from silently granting a capability to
	# everyone — which is exactly what happened when the drivetrain gate was keyed on a
	# hard-coded "drivetrain_swap" literal and that id was absent from the synthetic test
	# catalogue. A gate asked about something that does not exist must deny.
	if by_id(item_id).is_empty():
		return false
	var rid := unlocked_by_rally(item_id)
	if rid == "":
		return true
	# Parts whose unlock rally MOVED are granted directly to players who won them where
	# they used to live (Save.KEY_LEGACY_PART_UNLOCKS, written by the 4 -> 5 migration).
	# Checked before the rally so a re-sited part is never taken back; empty for every
	# career that started after the move. See features/snow-region.md.
	if (profile.get(Save.KEY_LEGACY_PART_UNLOCKS, []) as Array).has(item_id):
		return true
	return bool((profile.get(Save.KEY_RALLIES, {}) as Dictionary).get(rid, {}).get("completed", false))


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
	# Fails CLOSED on an unknown id, for the same reason rally_gate_met does: requires_
	# upgrade_id would return "" for a missing entry, which reads as "no prerequisite" and
	# waves the item through. The two gates are asked together at every call site, so a
	# permissive answer here undoes a strict answer there.
	if by_id(item_id).is_empty():
		return false
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


# The id of the currently-ENABLED nitrous-slot item on this car ("" if none).
#
# There is only ONE nitrous part now (features/nitrous.md), so in practice this returns it
# or nothing. Kept as a slot QUERY rather than a check for that id, because the answer the
# callers want is "what is this car running in the nitrous slot" — which stays correct if
# a second nitrous part is ever authored, where a hardcoded id would not. It also still
# reads correctly for a save made against the old four-rung ladder: only the highest rung
# was ever enabled, and the retired ids are pruned on load anyway
# (Save._prune_unknown_upgrades).
static func fitted_nitrous_id(owned_car: Dictionary) -> String:
	for item_id in enabled_upgrades(owned_car):
		if slot_of(item_id) == "nitrous":
			return item_id
	return ""


# --- Effect descriptor table -------------------------------------------------
# The single source of truth for what each `effect` key DOES, so apply() (live cfg)
# and effective_meta() (power-to-weight inputs) can't silently drift — adding an
# effect means adding one row here. Each row:
#   field    — the target GameConfig / meta field ("" for induction / flag-only)
#   op       — "mult" (field *= val), "add" (field += val), "set" (field = val — an
#              ABSOLUTE figure that replaces the baseline rather than scaling it),
#              "install_induction" (special: enable one flag, clear the rival's, splat the
#              sub-dict), "write_fields" (splat a sub-dict, no flag), or "flag" (gates a
#              tuning slider, no config effect)
#   feeds_pw — whether it changes a power-to-weight input (mass / torque), so
#              effective_meta must mirror it; the rest are cfg-only.
#   feeds_grip — whether it changes a MAX-LATERAL-G input (tyre μ / downforce), so
#              grip_meta must mirror it. Separate from feeds_pw because grip does NOT
#              move a car's class: eligibility is judged on power-to-weight alone, and
#              folding grip into effective_meta would let a set of tyres re-gate which
#              rallies a car may enter (see grip_meta).
#
# A "mult"/"add" row may also carry `cfg_fields` — see _cfg_fields — for the case where the
# live config spells the same quantity differently from the meta.
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
#
#   Every name here must EXIST somewhere, and nothing enforces that at runtime:
#   an effect naming something nobody declares applies silently and does nothing —
#   the part reads as fitted and no gameplay test fails. Note the two namespaces:
#   `field` is the CAR META spelling (a key on the car dict, e.g. `tire_compound`),
#   while `cfg_fields`, `clears` and `enable` are LIVE CONFIG spellings and must be
#   `@export`s on GameConfig (scripts/game_config.gd). If you add an effect here,
#   add its target in the same change. `test_upgrade_library.gd` →
#   `test_every_effect_target_name_exists` is the guard.
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
	# effective_meta's power-to-weight — a bottle the player empties in one stage must not
	# read as a permanent power level anywhere a build is compared or displayed.
	"install_nitrous": {"field": "", "op": "write_fields", "feeds_pw": false},
	"mass_mult":           {"field": "mass", "op": "mult", "feeds_pw": true},
	# Race tyres. `field` names the META spelling (a car's rubber is ONE `tire_compound`
	# coefficient) while `cfg_fields` names the live-config spelling (a PER-AXLE pair, seeded
	# from that same compound by car.gd::_apply_physics_spec and then shifted apart by the
	# grip_balance tuning slider). Multiplying both axles here — before TuningLibrary runs —
	# leaves the player's front/rear balance intact and just scales it.
	"tire_grip_mult": {
		"field": "tire_compound", "op": "mult", "feeds_pw": false, "feeds_grip": true,
		"cfg_fields": ["wheel_friction_slip_front", "wheel_friction_slip_rear"],
	},
	# The SURFACE-DEPENDENT half of the tyre model, and the only pair of effects in this
	# table whose value depends on where the car is (GameConfig.tire_surface_mult applies
	# them; see features/drivetrain-and-tires.md). Meta and config spell them the same, so
	# no cfg_fields override is needed.
	#
	# `mult` rather than `set` deliberately: it makes 1.0 the identity on BOTH sides, so a
	# car with no such compound fitted needs no entry anywhere — the meta key is simply
	# absent (readers default it to 1.0) and the config field is the 1.0 car.gd re-seeds.
	#
	# feeds_grip so grip_meta carries them to the lap-time model; feeds_pw stays FALSE for
	# the same reason the flat compound's does — rubber must never move rally eligibility.
	# Note this does NOT move the menu's GRIP row, which reads `tire_compound` alone: a
	# single headline number cannot honestly state a figure that changes with the surface.
	"tire_snow_grip_mult": {
		"field": "tire_snow_grip_mult", "op": "mult", "feeds_pw": false, "feeds_grip": true,
	},
	"tire_tarmac_grip_mult": {
		"field": "tire_tarmac_grip_mult", "op": "mult", "feeds_pw": false, "feeds_grip": true,
	},
	# Sequential gearbox: an ABSOLUTE shift time, not a scaling of the car's own. "set" is
	# order-independent and idempotent, so unlike "mult" it needs no argument about
	# re-fielding compounding it (shift_time is re-seeded from the fitted engine by
	# EngineLibrary.apply in step 1 either way).
	"shift_time_set":      {"field": "shift_time", "op": "set", "feeds_pw": false},
	"downforce_front":     {"field": "downforce_front", "op": "add", "feeds_pw": false, "feeds_grip": true},
	"downforce_rear":      {"field": "downforce_rear", "op": "add", "feeds_pw": false, "feeds_grip": true},
	"unlocks_aero_tuning": {"field": "", "op": "flag", "feeds_pw": false},
	"unlocks_drivetrain_swap": {"field": "", "op": "flag", "feeds_pw": false},
}


# The LIVE-CONFIG fields a "mult"/"add" row writes. Usually just `field`: the meta and the
# config call the quantity by the same name (`mass`, `downforce_front`), so one name serves
# both. `cfg_fields` overrides for a row whose two vocabularies diverge — race tyres are one
# `tire_compound` on a car's meta and two per-axle `wheel_friction_slip_*` fields on the live
# config — which keeps that mapping DATA in the table above rather than a branch in apply().
static func _cfg_fields(desc: Dictionary) -> Array:
	return desc.get("cfg_fields", [String(desc.get("field", ""))])


# --- Effect application (pipeline step 2) ------------------------------------

# Apply every ENABLED upgrade's effect on top of the CarLibrary baseline that
# apply_car already wrote into `cfg` (step 1); disabled parts stay fitted but
# inert. Pure: mutates the passed-in live `cfg` only, never the authored .tres.
# Unknown ids and flag-only effects (`unlocks_*`) are skipped here — flags gate
# the tuning sliders, not config. Driven by the EFFECTS table above.
# Loud write for the apply path. `Object.set()` on a name the config does not
# declare is a SILENT no-op — the part reads as fitted and does nothing, and no
# gameplay test fails (see the EFFECTS header; found by the small-model-readiness
# loop, round 001). This turns that into an error the editor shows immediately.
static func _cfg_set(cfg: GameConfig, field: String, value: Variant) -> void:
	if not (field in cfg):
		push_error("UpgradeLibrary: effect writes GameConfig.%s, which does not exist — write ignored" % field)
		return
	cfg.set(field, value)


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
					_cfg_set(cfg, String(desc["enable"]), true)
					for ckey in (desc["clears"] as Dictionary):
						_cfg_set(cfg, ckey, (desc["clears"] as Dictionary)[ckey])
					for tkey in (val as Dictionary):
						_cfg_set(cfg, tkey, (val as Dictionary)[tkey])
				"write_fields":
					# Straight splat of the authored fields onto the config — no enable
					# flag, no slot rival to clear (has_nitrous() reads the values
					# themselves, so a zero gain/tank IS "not fitted").
					for tkey in (val as Dictionary):
						_cfg_set(cfg, tkey, (val as Dictionary)[tkey])
				"mult":
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, float(cfg.get(f)) * float(val))
				"add":
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, float(cfg.get(f)) + float(val))
				"set":
					# Replaces the baseline outright: the authored figure IS the value, so
					# what the car brought to the slot does not enter into it.
					for f in _cfg_fields(desc):
						_cfg_set(cfg, f, float(val))
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
# It no longer feeds ELIGIBILITY at all: rally entry became purely categorical with the
# car-performance rating rework, so nothing about a car's power can admit or exclude it.
# What remains is the calibration/reporting question "what could this car become?" —
# tools/calibrate_benchmark.gd is the one caller left in the repo.
#
# Per-slot maximisation is EXACT here, not a heuristic: only one part per slot can be
# enabled (Save._enable_exclusive) and the slots' effects are independent (turbo → torque,
# weight → mass, aero → downforce, tires → μ, gearbox → shift time, drivetrain → a flag,
# nitrous → excluded from pw entirely), so the best combination is the best choice in each
# slot taken separately.
#
# Pure: builds a fresh owned-car dict, never mutates the input.
#
# ASPIRATIONAL by construction: the whole catalogue counts, star gates ignored — "could
# this car EVER do it?". There used to be a second, REACHABLE mode (a `profile` argument
# restricting candidates to parts whose gate was already open) for the soft-lock rescue
# draw; the rescue is gone, and with it the only caller that wanted it.
static func max_potential_meta(owned_car: Dictionary, meta: Dictionary) -> Dictionary:
	if meta.is_empty():
		return meta
	var maxed := owned_car.duplicate(true)
	var tuning: Dictionary = (maxed.get("tuning", {}) as Dictionary).duplicate()
	tuning["engine_detune"] = 1.0  # full power
	maxed["tuning"] = tuning
	maxed["disabled_upgrades"] = []  # nothing parked
	maxed["installed_upgrades"] = _best_part_per_slot(maxed, meta)
	return effective_meta(maxed, meta)


# The highest-power-to-weight part in each slot. Skips consumables (not slotted) and any
# part that ADDS mass (ballast is always removable, so it can't be part of a ceiling).
# Scores each candidate on its own — see the note above on why per-slot independence makes
# this exact. Star gates are ignored: this is the aspirational ceiling.
static func _best_part_per_slot(base_car: Dictionary, meta: Dictionary) -> Array:
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



# `effective_meta` plus the GRIP-feeding fields (EFFECTS[*].feeds_grip) — the aero kit's
# downforce and the race tyres' compound multiplier — for a max-lateral-G readout.
#
# effective_meta deliberately mirrors only the power-to-weight-feeding effects, because that
# is what ELIGIBILITY is judged on, and grip doesn't move a car's class: a wing or a set of
# tyres must never quietly change which rallies a car may enter. But the Simple page's Grip
# row has to show what those parts bought, and CarLibrary.max_lateral_g reads both downforce
# and `tire_compound` off the meta it is handed — so they are folded in HERE rather than by
# widening effective_meta's contract. Keeping the two calls apart is the whole safeguard.
#
# (Was `aero_meta`, when downforce was the only thing it folded in.)
static func grip_meta(owned_car: Dictionary, meta: Dictionary) -> Dictionary:
	var out := effective_meta(owned_car, meta)
	if out.is_empty():
		return out
	out = out.duplicate()
	for item_id in enabled_upgrades(owned_car):
		var effect: Dictionary = by_id(item_id).get("effect", {})
		for key in effect:
			var desc: Dictionary = EFFECTS.get(key, {})
			if not bool(desc.get("feeds_grip", false)):
				continue
			var f: String = desc["field"]
			match String(desc["op"]):
				"add":
					out[f] = float(out.get(f, 0.0)) + float(effect[key])
				"mult":
					# 1.0 is the neutral identity a missing compound reads as — the same
					# default CarLibrary.max_lateral_g falls back to.
					out[f] = float(out.get(f, 1.0)) * float(effect[key])
	return out

# --- Auto-Upgrade solver ------------------------------------------------------
#
# "Give me the best build this car can have right now" as a PURE function over its
# inputs, so the three things that want it — the Auto-Upgrade button, the free
# restore at the Start gate, and the tests — all share one rule instead of three
# copies (todo/simplified-upgrade-menu.md §6 warns specifically against widening
# the hq.gd / start_line.gd duplication).
#
# Returns a PLAN, never a mutation:
#   {buy: [id], enable: [id], strip: [id], detune: float, drivetrain: int,
#    cost: int, blocked: String, changed: bool}
# `strip`/`enable` are toggles on parts the car already owns, `buy` is a purchase
# (fitted enabled), `detune` is the absolute slider setting to write, `drivetrain`
# is a drive-mode override or -1 for "leave alone", and `blocked` is a non-empty
# reason when the car simply cannot enter (wrong car type, wrong country …) —
# something no build can fix, and which the solver must NAME rather than silently
# hand back a plan that doesn't work.
#
# `restriction` is a rally restriction dict (`RallyLibrary` shape) and is entirely
# CATEGORICAL — car type, country, drive mode. It carries no performance ceiling: a
# Rally Challenge ceiling is an eligibility line its own host enforces against the
# finished plan's rating, never a numeric key smuggled in here.
# Passing the real restriction is what lets `blocked` distinguish "wrong build" (a
# drivetrain conversion fixes it) from "wrong car" (nothing does).
#
# `free_only` forbids spending, and is a FLAG rather than a `stars = 0` call on
# purpose: `star_cost_per_part` is an exported range that a designer may set to 0,
# which would silently turn a free-only restore into a shopping spree.
static func auto_build_plan(owned_car: Dictionary, meta: Dictionary, profile: Dictionary,
		stars: int, restriction: Dictionary = {}, free_only := false) -> Dictionary:
	var plan := {"buy": [], "enable": [], "strip": [], "detune": 1.0,
		"drivetrain": -1, "cost": 0, "blocked": "", "changed": false}
	if meta.is_empty():
		return plan
	var budget := 0 if free_only else maxi(stars, 0)
	# Priced through Save.part_price, NOT off Config directly. part_price exists so rarity
	# pricing can land later without every caller changing (see its own comment), and the
	# COMMIT spends through it — so reading the flat config value here would make the plan
	# quote a cost the commit does not spend the moment prices stop being uniform. The
	# drivetrain half of this plan already prices through Save.drive_mode_price().
	var enabled_now := enabled_upgrades(owned_car)
	var owned: Array = owned_car.get("installed_upgrades", [])

	# --- Candidates per slot.
	# Only parts that feed power-to-weight take part in the SEARCH below; the rest
	# (aero, tires, gearbox, drivetrain kit, nitrous) Auto never BUYS — it only switches on
	# ones the car already owns and left parked. They do reach the rating now (the benchmark
	# lap sees tyres and downforce), so widening the search to them is a real option — but it
	# would let Auto spend the player's stars on handling parts they never asked for, which
	# is a design change, not a scorer change.
	# Ballast is excluded everywhere: it is a p/w lever that also destroys grip, and
	# detune buys the same reduction for free (§4 → "Auto never fits ballast").
	var pw_slots: Array = []
	var candidates := {}      # slot -> [id or ""], "" meaning "nothing in this slot"
	for slot in SLOTS:
		var opts: Array = [""]
		for item in all():
			var item_id := String(item.get("id", ""))
			if String(item.get("slot", "")) != slot or bool(item.get("consumable", false)):
				continue
			if float((item.get("effect", {}) as Dictionary).get("mass_mult", 1.0)) > 1.0:
				continue  # ballast: never fitted by Auto, in any mode
			var have := owned.has(item_id)
			if not have:
				if free_only or budget < Save.part_price(item_id):
					continue
				if not rally_gate_met(item_id, profile) or not prerequisite_met(item_id, owned_car):
					continue
			opts.append(item_id)
		candidates[slot] = opts
		if _slot_feeds_pw(slot):
			pw_slots.append(slot)

	# --- Search the p/w-feeding slots.
	# Exhaustive over the product of their candidate lists (a handful of parts across
	# two slots today) rather than greedy, because the objective is scored on the WHOLE
	# build at once (CarPerformance simulates a benchmark lap), not summed per part.
	# Per-slot independence makes each combination's score exact, the same property
	# _best_part_per_slot leans on.
	#
	# The objective is the performance RATING, not power-to-weight: p/w was the old
	# eligibility currency, and a solver still maximising it would happily pick a build
	# the game now calls slower. There is no ceiling term here — a Rally Challenge
	# ceiling is an ELIGIBILITY line, not something to optimise towards, and its host
	# withholds a plan that would breach it.
	var current_rating := CarPerformance.rating(CarPerformance.merged_meta(owned_car, meta))
	var best: Array = []
	var best_rating := -1
	var best_cost := 0
	for combo in _slot_combinations(pw_slots, candidates):
		var cost := 0
		for item_id in combo:
			# "" is the "leave this slot empty" pick, not a part — it costs nothing.
			if item_id != "" and not owned.has(item_id):
				cost += Save.part_price(item_id)
		if cost > budget:
			continue
		var rating := _combo_rating(owned_car, meta, combo, pw_slots)
		if free_only and rating < current_rating:
			continue  # a free restore only ever moves the car forward, or sideways
		if not _combo_better(rating, cost, best_rating, best_cost, best.is_empty()):
			continue
		best = combo
		best_rating = rating
		best_cost = cost

	# --- Turn the winning combination into toggles.
	var keep: Array = best.duplicate()
	for slot in SLOTS:
		if pw_slots.has(slot):
			continue
		# Non-p/w slot: switch on an owned part the player left parked, since that is
		# free and is never a downgrade. Ballast can't reach here (it lives in a
		# p/w slot), so there is nothing to protect against. An already-enabled part
		# wins over a parked sibling — Auto has no way to rank two parts whose effects
		# don't reach power-to-weight, so it must not overturn the player's pick.
		var pick := ""
		for item_id in owned:
			if slot_of(item_id) != slot or is_free(item_id):
				continue
			if enabled_now.has(item_id):
				pick = item_id
				break
			if pick == "":
				pick = item_id
		if pick != "":
			keep.append(pick)
	for item_id in keep:
		if item_id == "":
			continue
		if not owned.has(item_id):
			(plan["buy"] as Array).append(item_id)
			plan["cost"] = int(plan["cost"]) + Save.part_price(item_id)
		elif not enabled_now.has(item_id):
			(plan["enable"] as Array).append(item_id)
	for item_id in enabled_now:
		if slot_of(item_id) != "" and not keep.has(item_id):
			(plan["strip"] as Array).append(item_id)

	# --- Restriction check. Entry is CATEGORICAL now, so there is no power ceiling to
	# trim under: a build either satisfies the class or it doesn't. The one categorical
	# field a build CAN change is drive_mode, via a drivetrain conversion, so that stays
	# as the single fix this solver is allowed to propose.
	var final_car := _car_with_plan(owned_car, plan)
	var full_meta := effective_meta(final_car, meta)
	if not restriction.is_empty():
		var rally := {"restriction": restriction}
		var reason := RallyLibrary.ineligibility_reason(rally, full_meta)
		if reason != "":
			# Name it rather than returning a plan that lies about qualifying.
			plan["blocked"] = reason
			var wanted := _drivetrain_fix(owned_car, restriction, full_meta, meta)
			if wanted >= 0 and RallyLibrary.is_eligible(rally, _with_drive(full_meta, wanted)):
				# A conversion the car has not already paid for is a PURCHASE, so it has to
				# clear the same two gates a part does: free-only never buys, and the
				# remaining budget has to cover it. Otherwise Auto would hand the player a
				# free layout change the picker charges them for, and the commit would spend
				# stars the plan never quoted.
				var dt_cost := 0
				if not Save.drive_mode_available(owned_car, wanted):
					dt_cost = Save.drive_mode_price()
				if dt_cost > 0 and (free_only or budget - int(plan["cost"]) < dt_cost):
					pass  # cannot afford it: leave `blocked` naming the real problem
				else:
					plan["drivetrain"] = wanted
					plan["cost"] = int(plan["cost"]) + dt_cost
					plan["blocked"] = ""
	# The detune is carried through untouched. It survives as a HANDLING lever the
	# player sets deliberately; it is no longer something a build plan reaches for,
	# because there is nothing left to duck under.
	return _finish(plan, owned_car, float(owned_car.get("tuning", {}).get("engine_detune", 1.0)))


# Stamp the chosen detune on the plan and work out whether it does anything at all.
# The predicate is PLAN DIFFERENCE, not a power-to-weight comparison: swapping the
# player's ballast for an equivalent detune lands identical p/w with measurably more
# grip, and a p/w test would call that a no-op.
static func _finish(plan: Dictionary, owned_car: Dictionary, detune: float) -> Dictionary:
	plan["detune"] = clampf(detune, 0.0, 1.0)
	var now := clampf(float(owned_car.get("tuning", {}).get("engine_detune", 1.0)), 0.0, 1.0)
	plan["changed"] = (not (plan["buy"] as Array).is_empty()
		or not (plan["enable"] as Array).is_empty()
		or not (plan["strip"] as Array).is_empty()
		or int(plan["drivetrain"]) >= 0
		or not is_equal_approx(float(plan["detune"]), now))
	return plan


# Whether any authored part in `slot` moves a power-to-weight input, read off the
# same EFFECTS table apply() and effective_meta() use so a new effect can't leave the
# solver scoring a slot it should have searched.
static func _slot_feeds_pw(slot: String) -> bool:
	for item in all():
		if String(item.get("slot", "")) != slot:
			continue
		for key in (item.get("effect", {}) as Dictionary):
			if bool((EFFECTS.get(key, {}) as Dictionary).get("feeds_pw", false)):
				return true
	return false


# The cartesian product of each slot's candidate list — every build the search has to
# consider. Small by construction (two p/w slots, a handful of parts each).
static func _slot_combinations(slots: Array, candidates: Dictionary) -> Array:
	var out: Array = [[]]
	for slot in slots:
		var grown: Array = []
		for prefix in out:
			for item_id in (candidates[slot] as Array):
				var next: Array = (prefix as Array).duplicate()
				next.append(item_id)
				grown.append(next)
		out = grown
	return out


# Performance rating of a hypothetical build: the searched-slot picks in `combo`, plus
# every owned part from the other slots left as-is. Those DO move the rating (tyres and
# aero reach the benchmark lap even though they never reached power-to-weight), so
# leaving them out would score a car nobody is proposing to build.
static func _combo_rating(owned_car: Dictionary, meta: Dictionary, combo: Array,
		pw_slots: Array) -> int:
	var probe := owned_car.duplicate(true)
	var fitted: Array = []
	for item_id in combo:
		if item_id != "":
			fitted.append(item_id)
	for item_id in owned_car.get("installed_upgrades", []):
		if not pw_slots.has(slot_of(item_id)) and slot_of(item_id) != "":
			fitted.append(item_id)
	probe["installed_upgrades"] = fitted
	probe["disabled_upgrades"] = []
	var tuning: Dictionary = (probe.get("tuning", {}) as Dictionary).duplicate()
	tuning["engine_detune"] = 1.0   # the build is judged at full tune; detune trims after
	probe["tuning"] = tuning
	return CarPerformance.rating(CarPerformance.merged_meta(probe, meta))


# Is `rating`/`cost` a better pick than the incumbent? The objective is the highest
# rating, cheapest on a tie — stars the player doesn't have to spend for the same car
# are stars kept. The ONE shared scorer: every caller of auto_build_plan ranks builds
# through here, so the restore-to-race path and the Auto button can't disagree about
# what "best" means.
static func _combo_better(rating: int, cost: int, best_rating: int, best_cost: int,
		first: bool) -> bool:
	if first:
		return true
	if rating != best_rating:
		return rating > best_rating
	return cost < best_cost


# The car as it would be once `plan`'s buys/enables/strips are applied — used to rate
# the final build before deciding the detune trim.
#
# Mirrors UpgradeOptions.build_with, including its drivetrain rule: a planned layout is
# marked PAID FOR on the probe, because resolve_drive_override ignores an unbought override
# and the probe would otherwise rate the UNCONVERTED car. Today the sole call site runs
# before plan["drivetrain"] is ever set, so the branch is unreachable — which is exactly
# why it is written down rather than left out: moving that call, or adding a second one,
# would otherwise reintroduce a bug this codebase has already had once.
static func _car_with_plan(owned_car: Dictionary, plan: Dictionary) -> Dictionary:
	var probe := owned_car.duplicate(true)
	var installed: Array = (probe.get("installed_upgrades", []) as Array).duplicate()
	for item_id in (plan["buy"] as Array):
		if not installed.has(item_id):
			installed.append(item_id)
	var disabled: Array = []
	for item_id in (probe.get("disabled_upgrades", []) as Array):
		disabled.append(item_id)
	for item_id in (plan["buy"] as Array) + (plan["enable"] as Array):
		disabled.erase(item_id)
	for item_id in (plan["strip"] as Array):
		if not disabled.has(item_id):
			disabled.append(item_id)
	probe["installed_upgrades"] = installed
	probe["disabled_upgrades"] = disabled
	var tuning: Dictionary = (probe.get("tuning", {}) as Dictionary).duplicate()
	tuning["engine_detune"] = 1.0
	probe["tuning"] = tuning
	if int(plan["drivetrain"]) >= 0:
		var mode := int(plan["drivetrain"])
		probe["drivetrain_override"] = mode
		var bought: Array = (probe.get("drivetrain_modes_bought", []) as Array).duplicate()
		if not bought.has(mode):
			bought.append(mode)
		probe["drivetrain_modes_bought"] = bought
	return probe


# The drive mode a restriction demands, when the car could actually deliver it — i.e. the
# conversion capability is unlocked garage-wide. -1 for "no drivetrain problem, or one Auto
# can't fix". This is the ONLY non-power restriction field Auto is allowed to touch; the
# rest are car identity. Whether the car can AFFORD the conversion is decided by the
# caller, which owns the budget.
static func _drivetrain_fix(owned_car: Dictionary, restriction: Dictionary,
		full_meta: Dictionary, _meta: Dictionary) -> int:
	if not restriction.has("drive_mode") or not drivetrain_swap_unlocked(Save.profile):
		return -1
	var want := int(restriction["drive_mode"])
	return -1 if int(full_meta.get("drive_mode", -1)) == want else want


static func _with_drive(meta: Dictionary, mode: int) -> Dictionary:
	var out := meta.duplicate()
	out["drive_mode"] = mode
	return out


# --- Tuning gates ------------------------------------------------------------
# Aero tuning is only live when the aero kit is installed (todo/menus.md ›
# tuning-lift knobs). Brake bias is NOT gated — it's a free axis on every car.

static func aero_tuning_unlocked(owned_car: Dictionary) -> bool:
	return _has_flag(owned_car, "unlocks_aero_tuning")


# Whether drivetrain conversion is available AT ALL — a GARAGE-WIDE capability, keyed on
# the profile's rally record, not on any one car.
#
# It used to be per-car, checking the kit in that car's `installed_upgrades`. That was a
# bug in practice: the kit is only ever handed to the single car selected when its special
# is won, and the drivetrain slot lists drive MODES rather than parts — so no other car
# could ever acquire it, by stars or otherwise, and the rest of the garage was permanently
# stuck on its stock layout with no way to see why.
#
# The unlock is therefore global (won once, applies to every car, like the engine-swap
# capability), and what is charged per car is the CONVERSION — see Save.buy_drive_mode.
static func drivetrain_swap_unlocked(profile: Dictionary) -> bool:
	# Found BY ITS EFFECT FLAG, never by a hard-coded id. Keying on the literal
	# "drivetrain_swap" made the gate fail OPEN wherever that id was absent — rally_gate_met
	# treats an unknown item as ungated — so renaming the part, or running against the
	# synthetic test catalogue, would silently hand every car free conversion. No part
	# offering conversion means there is nothing to unlock, so that reads as locked.
	var pid := drivetrain_swap_part_id()
	return pid != "" and rally_gate_met(pid, profile)


# The catalogue entry that grants drivetrain conversion, by its effect flag, or "" if the
# catalogue has none. One definition, so the gate and anything that wants to name the part
# cannot disagree.
static func drivetrain_swap_part_id() -> String:
	for def in all():
		if bool((def.get("effect", {}) as Dictionary).get("unlocks_drivetrain_swap", false)):
			return String(def.get("id", ""))
	return ""


# The layout a car was BUILT with, which it can always return to for free.
static func stock_drive_mode(owned_car: Dictionary) -> int:
	return int(CarLibrary.for_owned(owned_car).get("drive_mode", CarLibrary.RWD))


# The drive mode the player chose for this car (0/1/2), or -1 meaning "use the car's
# authored stock drive_mode". Gated: a stored override is inert unless the swap kit is
# fitted AND enabled, so removing/disabling the kit reverts the car to stock. The single
# resolver used by physics (car.gd), display/eligibility (effective_meta) and the garage.
static func resolve_drive_override(owned_car: Dictionary) -> int:
	var mode := int(owned_car.get("drivetrain_override", -1))
	if mode < 0:
		return -1
	# Gated on the mode being PAID FOR (Save.drive_mode_available: the car's own stock
	# layout, or one it has bought while the capability is unlocked). A stored override the
	# player has not paid for is inert rather than free, which is what keeps the price from
	# being bypassed by anything that writes the field directly.
	return mode if Save.drive_mode_available(owned_car, mode) else -1


static func _has_flag(owned_car: Dictionary, flag: String) -> bool:
	for item_id in enabled_upgrades(owned_car):
		if bool(by_id(item_id).get("effect", {}).get(flag, false)):
			return true
	return false

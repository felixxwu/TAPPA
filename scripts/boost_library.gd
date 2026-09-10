class_name BoostLibrary
extends RefCounted
# Docs: features/region-runs.md — update in the same change as this file.
# Tests: tests/headless/test_boost_library.gd — extend in the same change.
#
# THE IN-RUN BOOST CATALOGUE (todo/roguelike-pivot.md -> "Upgrades — RR's two-tier
# model", stage 5 of todo/roguelike-pivot-plan.md). A run-scoped, temporary boost —
# picked between stages, wiped when the run ends (RunSession.boosts() /
# _field_car in world.gd) — as opposed to a permanent car modification, which the
# pivot deletes outright.
#
# Every boost's `effect` dict uses an EXISTING `UpgradeLibrary.EFFECTS` key: this file
# invents no second effects system, it only AUTHORS entries that walk through the one
# funnel UpgradeLibrary already owns (apply() / effective_meta() / grip_meta()). Two of
# the six below (`brake_force_mult`, `drag_mult`) needed a new EFFECTS row each — added
# in upgrade_library.gd alongside the GameConfig fields they already existed as
# (`brake_torque`, `drag_coefficient`) — everything else reuses a row the old parts
# model already had (mass_mult, tire_grip_mult, shift_time_set, downforce_front/rear).
#
# RR's own set is the guide (engineForce, frictionMax, brakeForce, mass, shiftTime,
# downforce, dragCoefficient) but is not reproduced 1:1: `engineForce` maps onto
# GameConfig.global_torque_scale, which engine.gd's own comment names as a HIDDEN
# GLOBAL DE-RATE (a balance knob meant to scale every car uniformly, not a per-car
# effect target), so hooking a boost onto it would fight that field's real job. The
# engine_swap entry instead multiplies cfg.peak_torque — the per-car published figure —
# through the engine_power_mult EFFECTS row, and every other category lands on an
# ordinary per-car GameConfig field the same way.
#
# MAGNITUDES ARE TUNABLE DATA (CLAUDE.md) and live on GameConfig
# (config/game_config.tres, "Roguelike Run Boosts") — never a const here, and no test
# may pin the shipped number. This table only says WHICH GameConfig field(s) each
# catalogue entry's effect draws its value from, so `effect_for` re-reads Config.data
# live rather than baking a value in.
#
# THE META SEAM IS WIRED (stage 6): each entry also carries `level_direction` — +1 if a
# purchased level should push the magnitude UP (grip, brakes, downforce: bigger is more
# boost) or -1 if it should push it DOWN (mass, shift time, drag: smaller is more boost).
# `magnitude_for(id, level)` is the one place that applies it, via
# `GameConfig.boost_level_magnitude_step` ("Roguelike Meta Shop") — level 0 is always an
# exact no-op, so a fresh id with no purchased level still rolls the bare GameConfig
# number above unchanged.
const CATALOGUE := {
	"lightweight": {
		"label": "Lightweight parts",
		"effect_fields": {"mass_mult": "run_boost_mass_mult"},
		"level_direction": -1,  # lower mass_mult = lighter = more boost
	},
	"grip": {
		"label": "Sticky tyres",
		"effect_fields": {"tire_grip_mult": "run_boost_grip_mult"},
		"level_direction": 1,  # higher tire_grip_mult = more boost
	},
	"gearbox": {
		"label": "Quick-shift gearbox",
		"effect_fields": {"shift_time_set": "run_boost_shift_time_s"},
		"level_direction": -1,  # lower shift time = faster = more boost
		# A "set" op replaces the car's shift time outright, so the shop shows the
		# absolute seconds it sets rather than a percentage of a baseline that does not
		# exist — see current_effect_text.
		"unit": "s", "decimals": 2,
	},
	"aero": {
		"label": "Aero kit",
		"effect_fields": {
			"downforce_front": "run_boost_downforce_n",
			"downforce_rear": "run_boost_downforce_n",
		},
		"level_direction": 1,  # more downforce = more boost
		# An "add" op stacks on the car's own downforce, so likewise no percentage — the
		# authored unit is N per (m/s)², which is what the shop prints. Both axles take
		# the same number and current_effect_text de-duplicates them into one figure.
		"unit": "N", "decimals": 1,
	},
	"brakes": {
		"label": "Big brakes",
		"effect_fields": {"brake_force_mult": "run_boost_brake_mult"},
		"level_direction": 1,  # higher brake_force_mult = more boost
	},
	"streamline": {
		"label": "Streamlined body",
		"effect_fields": {"drag_mult": "run_boost_drag_mult"},
		"level_direction": -1,  # lower drag_mult = less drag = more boost
	},
	# The Engine Swap, re-homed (was the meta shop's one-time unlock; that purchase and
	# its dead mutators are deleted). A mid-run POWER boost: a stronger engine's torque
	# curve, via the engine_power_mult EFFECTS row on cfg.peak_torque.
	"engine_swap": {
		"label": "Engine swap",
		"effect_fields": {"engine_power_mult": "run_boost_engine_power_mult"},
		"level_direction": 1,  # higher peak_torque = more power = more boost
	},
}


# How far a purchased `level` pushes a magnitude from its unleveled (level 0) baseline, as
# a plain multiplier — 1.0 at level 0, always. `direction` is a catalogue entry's own
# `level_direction` (+1/-1). Floored well above 0 (never lets a magnitude cross zero or flip
# sign, however high `boost_level_magnitude_step` or `boost_level_max` are retuned) — a
# sanity guard, not a pinned value (CLAUDE.md).
static func level_scale(level: int, direction: int) -> float:
	var cfg: GameConfig = Config.data
	var raw := 1.0 + float(direction) * float(maxi(0, level)) * cfg.boost_level_magnitude_step
	return maxf(raw, 0.1)


# The `effect` dict a catalogue entry resolves to at a GIVEN `level`, read live off
# `Config.data` field by field and scaled by `level_scale` — never cached, so a designer's
# inspector edit is reflected the instant the next pick is drawn. {} for an unknown id
# (mirrors UpgradeFixtures.boost's "unknown id -> {}" contract, so a bad id degrades to
# nothing rather than erroring). Pure in its two arguments — no Save read — so the
# level-scaling relationship is testable without a profile.
static func magnitude_for(id: String, level: int) -> Dictionary:
	var entry: Dictionary = CATALOGUE.get(id, {})
	if entry.is_empty():
		return {}
	var cfg: GameConfig = Config.data
	var scale := level_scale(level, int(entry.get("level_direction", 1)))
	var out := {}
	for effect_key in (entry["effect_fields"] as Dictionary):
		var cfg_field := String((entry["effect_fields"] as Dictionary)[effect_key])
		out[effect_key] = float(cfg.get(cfg_field)) * scale
	return out


# The effect a catalogue entry resolves to RIGHT NOW, at whatever level the player has
# actually purchased (Save.boost_level) — what `draw`/`boost_for` hand to a live pick. {}
# for an unknown id, same as `magnitude_for`.
static func effect_for(id: String) -> Dictionary:
	return magnitude_for(id, Save.boost_level(id))


# Shop display text: WHAT THIS BOOST DOES TO THE CAR at `level` — the figure the shop
# card puts under the level, so "Lv 1" is never shown without what level 1 actually buys.
#
# READ THIS BEFORE CHANGING IT. The obvious implementation — `(level_scale(level,
# direction) - 1.0) * 100.0`, i.e. how far the LEVEL has pushed the magnitude — is wrong,
# and was shipped and reverted once. `level_scale` is exactly 1.0 at level 0 by design,
# so that expression renders the un-upgraded boost (the one the shop shows most often,
# and the one every fresh profile sees) as "+0%": a card reading "Lv 1, +0%" states that
# the boost does nothing, which is the opposite of true. The player does not care how far
# a level moved the number; they care what the boost gives them.
#
# So the figure is derived from the RESOLVED MAGNITUDE (`magnitude_for`, already
# level-scaled and read live off Config.data) against no-boost at all, per effect op —
# because "as a percentage" is only meaningful for one of the three ops:
#   * "mult" — the magnitude IS a ratio to no-boost, so (m - 1) as a signed %. Five of
#     the seven catalogue entries are this, including every entry the request's own
#     example named ("an upgraded weight reduction is always -8% ... upgraded once
#     it's -16%"): a mult compounds, so successive levels roughly double the swing.
#   * "add"  — added ON TOP of whatever the car already has (downforce, authored in N per
#     (m/s)²), so there is no baseline to be a percentage OF. Shown as the signed amount
#     with the entry's `unit`.
#   * "set"  — replaces the car's value outright (shift time, in seconds), so likewise no
#     baseline. Shown as the absolute value it sets, with the entry's `unit`.
# An entry with several effect keys (the aero kit drives both axles) formats each and
# joins them, de-duplicated — both axles take the same number, so that reads as one
# figure rather than the same figure twice.
#
# Pure in its two arguments (no Save read), mirroring the `magnitude_for` split so the
# relationship stays testable without a profile. "" for an unknown id.
static func current_effect_text(id: String, level: int) -> String:
	var entry: Dictionary = CATALOGUE.get(id, {})
	if entry.is_empty():
		return ""
	var magnitude := magnitude_for(id, level)
	var unit := String(entry.get("unit", ""))
	var decimals := int(entry.get("decimals", 2))
	var parts: Array[String] = []
	for effect_key in magnitude:
		var op := String((UpgradeLibrary.EFFECTS.get(effect_key, {}) as Dictionary).get("op", "mult"))
		var value := float(magnitude[effect_key])
		var text := ""
		match op:
			"add":
				text = "%+.*f" % [decimals, value]
			"set":
				text = "%.*f" % [decimals, value]
			_:
				# "mult", and the safe default for a row this file has not seen: a ratio
				# to no-boost reads as a percentage swing.
				text = "%+.0f%%" % ((value - 1.0) * 100.0)
		if not unit.is_empty() and op != "mult":
			text = "%s %s" % [text, unit]
		if not parts.has(text):
			parts.append(text)
	return " / ".join(parts)


# `current_effect_text` at whatever level the player has actually purchased
# (Save.boost_level) — what the shop card shows for a boost's current increase. "" for an
# unknown id, same as `current_effect_text`.
static func current_effect_text_for(id: String) -> String:
	return current_effect_text(id, Save.boost_level(id))


# One boost entry, in the exact shape UpgradeLibrary.active_effects reads:
# {"id": String, "effect": Dictionary}. {} for an unknown id.
static func boost_for(id: String) -> Dictionary:
	var effect := effect_for(id)
	if effect.is_empty():
		return {}
	return {"id": id, "effect": effect}


# Display text for a pick row. `id` for an unknown entry, so a stale/miskeyed id is
# visible rather than blank.
static func label_for(id: String) -> String:
	return String(CATALOGUE.get(id, {}).get("label", id))


# `count` distinct boosts, deterministic in `seed_value` — RunSession seeds it from the
# run itself (RegionRunMode._boost_seed: run_seed + stage_index, the same "big prime
# stride" convention world.gd already uses to bump a challenge stage's retry seed), so a
# resumed run re-offers the identical pick it offered before. No sort step (unlike
# RegionStagePool.draw), so there is no sort-stability tie-break to worry about: the
# order picked IS the deterministic order, nothing reorders it afterward.
#
# Draws WITHOUT replacement — the same boost never appears twice in one pick — capped at
# the catalogue's own size rather than repeating to fill `count`, since (unlike a
# region's stage pool) there is no "must fill exactly N" requirement here.
static func draw(seed_value: int, count: int) -> Array:
	var ids: Array = CATALOGUE.keys()
	if ids.is_empty() or count <= 0:
		return []
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var bag := ids.duplicate()
	var picked_ids: Array = []
	var n := mini(count, ids.size())
	while picked_ids.size() < n:
		var i := rng.randi_range(0, bag.size() - 1)
		picked_ids.append(bag[i])
		bag.remove_at(i)
	var out: Array = []
	for id in picked_ids:
		out.append(boost_for(id))
	return out

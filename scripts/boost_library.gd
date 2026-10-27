class_name BoostLibrary
extends RefCounted
# Docs: features/loot.md, features/upgrade-catalogue.md — update in the same change as this file.
# Tests: tests/headless/test_boost_library.gd — extend in the same change.
#
# THE PARTS CATALOGUE: what checkpoints sell (LootRules), as `effect` dicts for the
# UpgradeLibrary.EFFECTS funnel. This file invents no second effects system; it only
# authors entries that walk through the one funnel UpgradeLibrary owns (apply()).
#
# `engineForce` is deliberately not a boost: GameConfig.global_torque_scale is a hidden
# global de-rate (a balance knob meant to scale every car uniformly), not a per-car
# effect target. Engine swaps are a genuine EngineLibrary swap, not an EFFECTS row.
#
# MAGNITUDES ARE TUNABLE DATA (CLAUDE.md) and live on GameConfig
# (config/game_config.tres, "Loot Parts") — never a const here, and no test
# may pin the shipped number. This table only says WHICH GameConfig field(s) each
# catalogue entry's effect draws its value from, so `effect_for` re-reads Config.data
# live rather than baking a value in.
#
# Each entry also carries `level_direction` — +1 if a
# purchased level should push the magnitude UP (grip, brakes, downforce: bigger is more
# boost) or -1 if it should push it DOWN (mass, shift time, drag: smaller is more boost).
# `magnitude_for(id, level)` is the one place that applies it, via
# `GameConfig.boost_level_magnitude_step` ("Loot Part Levels") — level 0 is always an
# exact no-op, so a fresh id with no purchased level still rolls the bare GameConfig
# number above unchanged.
#
# AN `effect_fields` VALUE IS EITHER A STRING (one cfg field -> one scaled float — every
# entry above) OR A DICTIONARY (several cfg fields written at once under ONE effect key —
# "turbo"/"supercharger" below, whose EFFECTS row is `install_induction`: apply() splats
# a whole sub-dict onto the live config in one go, not one scalar). For a dict-shaped
# entry, `scaled_subfields` names which of ITS keys the purchased level actually scales
# (the part's real strength — boost gain); every other key is a FIXED characteristic of
# the part (spool inertia, saturation point, parasitic drag) that never scales with
# level. See magnitude_for for where this shape is read.
# `ring` is the free-roam biome ring whose checkpoints sell the part, at level = ring, for `price`
# (LootRules.ring_tables / price).
const CATALOGUE := {
	"lightweight": {
		"ring": 0, "price": 1200,
		"label": "Lightweight", "blurb": "Sheds weight.",
		# "mult_floor", not "mult": a proportional weight cut clamped at
		# GameConfig.min_lightweight_mass.
		"effect_fields": {"mass_mult_floor": "run_boost_mass_mult"},
		"level_direction": - 1, # lower mass_mult_floor = lighter = more boost
	},
	"turbo": {
		"ring": 0, "price": 1800,
		"label": "Turbocharger", "blurb": "Torque once it spools.",
		"effect_fields": {"install_turbo": {
			"turbo_boost_gain": "run_boost_turbo_boost_gain",
			"turbo_omega_ref": "run_boost_turbo_omega_ref",
			"turbo_inertia": "run_boost_turbo_inertia",
			"turbo_parasitic_friction": "run_boost_turbo_parasitic_friction",
			# Audio gains — fixed personality, not scaled by level (see scaled_subfields
			# below). Without these the boost enabled the turbo's physics but left the
			# audio layers silent, since a stock NA engine authors zero gain for them.
			"engine_turbo_whistle_gain": "run_boost_turbo_whistle_gain",
			"engine_turbo_bov_gain": "run_boost_turbo_bov_gain",
			"engine_turbo_antilag_bang_gain": "run_boost_turbo_antilag_bang_gain",
		}},
		"scaled_subfields": ["turbo_boost_gain"],
		"level_direction": 1, # higher turbo_boost_gain = more boost
	},
	# "grip": {
	# 	"ring": 0,
	# 	"label": "Sticky tyres",
	# 	"effect_fields": {"tire_grip_mult": "run_boost_grip_mult"},
	# 	"level_direction": 1,  # higher tire_grip_mult = more boost
	# },
	"gearbox": {
		"ring": 1, "price": 2500,
		"label": "Quick shifter", "blurb": "Faster gear changes.",
		"effect_fields": {"shift_time_set": "run_boost_shift_time_s"},
		"level_direction": - 1, # lower shift time = faster = more boost
		# A "set" op replaces the car's shift time outright, so the shop shows the
		# absolute seconds it sets rather than a percentage of a baseline that does not
		# exist.
	},
	"nitrous": {
		"ring": 1, "price": 3000,
		"label": "Nitrous", "blurb": "Hold for extra power.",
		"effect_fields": {"install_nitrous": {
			"nitrous_boost_gain": "run_boost_nitrous_boost_gain",
			"nitrous_tank_seconds": "run_boost_nitrous_tank_seconds",
		}},
		"scaled_subfields": ["nitrous_boost_gain"],
		"level_direction": 1, # higher nitrous_boost_gain = more boost
	},
	"aero": {
		"ring": 2, "price": 4000,
		"label": "Aero kit", "blurb": "Grip at high speed.",
		"effect_fields": {
			"downforce_front": "run_boost_downforce_n",
			"downforce_rear": "run_boost_downforce_n",
		},
		"level_direction": 1, # more downforce = more boost
		# An "add" op stacks on the car's own downforce, so likewise no percentage — the
		# authored unit is N per (m/s)². Both axles take
		# the same number.
	},
	"brakes": {
		"ring": 2, "price": 3500,
		"label": "Big brakes", "blurb": "Stronger braking.",
		# Fixed absolute brake_torque ("set", not a multiplier) — strong enough to push
		# ABS into play on every car in the roster, including the heaviest
		# (see run_boost_brake_torque_n and features/drivetrain-and-tires.md).
		"effect_fields": {"brake_torque_set": "run_boost_brake_torque_n"},
		"level_direction": 1, # higher brake_torque_set = more boost
		# A "set" op replaces the car's own brake_torque outright, so the shop shows the
		# absolute N·m it sets rather than a percentage of a baseline that does not
		# exist.
	},
	"supercharger": {
		"ring": 2, "price": 5000,
		"label": "Supercharger", "blurb": "Boost with no lag.",
		"effect_fields": {"install_supercharger": {
			"supercharger_boost_gain": "run_boost_supercharger_boost_gain",
			"supercharger_rpm_ref": "run_boost_supercharger_rpm_ref",
			"supercharger_parasitic_coef": "run_boost_supercharger_parasitic_coef",
			# Audio gain — fixed personality, not scaled by level. Without this the boost
			# turned on the belt physics but left the whine layer silent, since a stock NA
			# engine authors zero gain for it.
			"engine_supercharger_whine_gain": "run_boost_supercharger_whine_gain",
		}},
		"scaled_subfields": ["supercharger_boost_gain"],
		"level_direction": 1, # higher supercharger_boost_gain = more boost
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
#
# An `effect_fields` value that IS a Dictionary (turbo/supercharger — see the CATALOGUE
# header) resolves to a SUB-dict instead of a scaled float: each of ITS keys is read off
# the named cfg field and scaled ONLY if it's named in the entry's `scaled_subfields`,
# otherwise passed through unscaled (a fixed characteristic of the part). This is the one
# place that shape is handled — apply()'s install_induction arm already expects exactly
# this sub-dict, unchanged.
static func magnitude_for(id: String, level: int) -> Dictionary:
	var entry: Dictionary = CATALOGUE.get(id, {})
	if entry.is_empty():
		return {}
	var cfg: GameConfig = Config.data
	var scale := level_scale(level, int(entry.get("level_direction", 1)))
	var scaled_subfields: Array = entry.get("scaled_subfields", [])
	var out := {}
	for effect_key in (entry["effect_fields"] as Dictionary):
		var spec: Variant = (entry["effect_fields"] as Dictionary)[effect_key]
		if spec is Dictionary:
			var sub := {}
			for target_field in (spec as Dictionary):
				var cfg_field := String((spec as Dictionary)[target_field])
				var value := float(cfg.get(cfg_field))
				sub[target_field] = value * scale if scaled_subfields.has(target_field) else value
			out[effect_key] = sub
		else:
			out[effect_key] = float(cfg.get(String(spec))) * scale
	return out


# A short line saying what the part does, for its card.
static func blurb_for(id: String) -> String:
	return String(CATALOGUE.get(id, {}).get("blurb", ""))


# Display text for a pick row. `id` for an unknown entry, so a stale/miskeyed id is
# visible rather than blank.
static func label_for(id: String) -> String:
	return String(CATALOGUE.get(id, {}).get("label", id))

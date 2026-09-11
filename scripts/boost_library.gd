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
# engine-swap POWER pick lives outside this catalogue entirely — it is a genuine
# EngineLibrary swap (RunSession._pool_engine_swap_ids / features/engine-swap.md), not
# an EFFECTS row — and every other category lands on an ordinary per-car GameConfig
# field the same way.
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
#
# EACH ENTRY ALSO CARRIES A `category` — "power" or "handling" — read by the mid-run
# upgrade menu (todo/mid-run-upgrade-menu.md, run_pick_panel.gd): the player picks a
# direction first, then ONE entry from that category is rolled at random. `category_of`
# below is the one place a caller resolves a category, for a catalogue id or either
# pseudo-id family (drivetrain:/engine_swap:) alike — never re-derive it at a call site.
#
# AN `effect_fields` VALUE IS EITHER A STRING (one cfg field -> one scaled float — every
# entry above) OR A DICTIONARY (several cfg fields written at once under ONE effect key —
# "turbo"/"supercharger" below, whose EFFECTS row is `install_induction`: apply() splats
# a whole sub-dict onto the live config in one go, not one scalar). For a dict-shaped
# entry, `scaled_subfields` names which of ITS keys the purchased level actually scales
# (the part's real strength — boost gain); every other key is a FIXED characteristic of
# the part (spool inertia, saturation point, parasitic drag) that never scales with
# level. See magnitude_for and current_effect_text for where this shape is read.
const CATALOGUE := {
	"lightweight": {
		"label": "Lightweight parts",
		"effect_fields": {"mass_mult": "run_boost_mass_mult"},
		"level_direction": -1,  # lower mass_mult = lighter = more boost
		"category": "handling",
	},
	"grip": {
		"label": "Sticky tyres",
		"effect_fields": {"tire_grip_mult": "run_boost_grip_mult"},
		"level_direction": 1,  # higher tire_grip_mult = more boost
		"category": "handling",
	},
	"gearbox": {
		"label": "Quick-shift gearbox",
		"effect_fields": {"shift_time_set": "run_boost_shift_time_s"},
		"level_direction": -1,  # lower shift time = faster = more boost
		# A "set" op replaces the car's shift time outright, so the shop shows the
		# absolute seconds it sets rather than a percentage of a baseline that does not
		# exist — see current_effect_text.
		"unit": "s", "decimals": 2,
		"category": "power",
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
		"category": "handling",
	},
	"brakes": {
		"label": "Big brakes",
		"effect_fields": {"brake_force_mult": "run_boost_brake_mult"},
		"level_direction": 1,  # higher brake_force_mult = more boost
		"category": "handling",
	},
	"streamline": {
		"label": "Streamlined body",
		"effect_fields": {"drag_mult": "run_boost_drag_mult"},
		"level_direction": -1,  # lower drag_mult = less drag = more boost
		"category": "handling",
	},
	"turbo": {
		"label": "Turbocharger",
		"effect_fields": {"install_turbo": {
			"turbo_boost_gain": "run_boost_turbo_boost_gain",
			"turbo_omega_ref": "run_boost_turbo_omega_ref",
			"turbo_inertia": "run_boost_turbo_inertia",
			"turbo_parasitic_friction": "run_boost_turbo_parasitic_friction",
		}},
		"scaled_subfields": ["turbo_boost_gain"],
		"display_subfield": "turbo_boost_gain",
		"display_suffix": "torque at full boost",
		"level_direction": 1,  # higher turbo_boost_gain = more boost
		"category": "power",
	},
	"supercharger": {
		"label": "Supercharger",
		"effect_fields": {"install_supercharger": {
			"supercharger_boost_gain": "run_boost_supercharger_boost_gain",
			"supercharger_rpm_ref": "run_boost_supercharger_rpm_ref",
			"supercharger_parasitic_coef": "run_boost_supercharger_parasitic_coef",
		}},
		"scaled_subfields": ["supercharger_boost_gain"],
		"display_subfield": "supercharger_boost_gain",
		"display_suffix": "torque at full boost",
		"level_direction": 1,  # higher supercharger_boost_gain = more boost
		"category": "power",
	},
	# NOTE: the Engine Swap is NOT a CATALOGUE entry — it is a GENUINE engine swap now
	# (RunSession._pool_engine_swap_ids' "engine_swap:<EngineLibrary id>" pseudo-id,
	# folded into the SAME draw pool as this catalogue by RegionRunMode.boost_choices,
	# exactly like the AWD drivetrain conversion). It used to be a flat peak_torque
	# multiplier via the engine_power_mult EFFECTS row; that is retired — see
	# features/engine-swap.md.
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
		# A DICT-SHAPED entry (turbo/supercharger — install_induction's op, which is
		# neither mult/add/set): show the ONE scaled sub-field (`display_subfield`) as a
		# signed percentage — it IS the boost's own gain, not a ratio-to-baseline like a
		# mult row, so it skips the (value - 1.0) shift the mult branch below applies.
		if magnitude[effect_key] is Dictionary:
			var sub: Dictionary = magnitude[effect_key]
			var gain := float(sub.get(String(entry.get("display_subfield", "")), 0.0))
			var suffix := String(entry.get("display_suffix", ""))
			var dict_text := "+%.0f%% %s" % [gain * 100.0, suffix] if not suffix.is_empty() \
				else "+%.0f%%" % (gain * 100.0)
			if not parts.has(dict_text):
				parts.append(dict_text)
			continue
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


# "power" or "handling" for a catalogue id, OR either pseudo-id family the between-stage
# pick pool also carries — "drivetrain:<mode>" (the AWD conversion) reads as "handling",
# "engine_swap:<id>" (a genuine engine swap) reads as "power". "" for an unknown id. The
# ONE place a caller resolves a category — run_pick_panel.gd's category-choice screen and
# random roll both filter through this rather than re-deriving the prefix checks.
static func category_of(id: String) -> String:
	if id.begins_with("drivetrain:"):
		return "handling"
	if id.begins_with("engine_swap:"):
		return "power"
	return String(CATALOGUE.get(id, {}).get("category", ""))


# One pick-pool id, resolved to the shape RunPickPanel/UpgradeLibrary read — {"id",
# "effect"} for a catalogue id, {"id", "drivetrain_mode"} for "drivetrain:<mode>", {"id",
# "engine_id"} for "engine_swap:<id>". {} for an unknown id (mirrors boost_for's own
# contract). The ONE place a caller resolves a pool id into its display/apply shape —
# RunSession and the (now-retired) per-mode draw used to each carry their own copy of
# this mapping; this is the single version both funnel through.
static func resolve_id(id: String) -> Dictionary:
	if id.begins_with("drivetrain:"):
		return {"id": id, "drivetrain_mode": int(id.substr("drivetrain:".length()))}
	if id.begins_with("engine_swap:"):
		return {"id": id, "engine_id": id.substr("engine_swap:".length())}
	return boost_for(id)


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
#
# Thin wrapper over `draw_from_ids`, the generic primitive: this just supplies the
# catalogue's own id list and maps the picked ids through `boost_for`.
static func draw(seed_value: int, count: int) -> Array:
	var picked_ids := draw_from_ids(seed_value, count, CATALOGUE.keys())
	var out: Array = []
	for id in picked_ids:
		out.append(boost_for(id))
	return out


# THE GENERIC PRIMITIVE `draw` sits on top of: `count` distinct ids drawn WITHOUT
# replacement from an ARBITRARY `ids` list (not necessarily CATALOGUE.keys()),
# deterministic in `seed_value`, capped at `ids`' own size. Returns the picked ids
# themselves — not boost dicts — so a caller can mix ids from more than one source
# into one pool before resolving them. region_run_mode.gd uses this directly to fold
# drivetrain pseudo-ids ("drivetrain:<DriveMode int>") into the SAME draw pool as the
# boost catalogue, so the between-stage pick offers one pool of N options rather than
# boosts plus a separately-appended drivetrain list. [] for an empty pool or
# count <= 0.
static func draw_from_ids(seed_value: int, count: int, ids: Array) -> Array:
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
	return picked_ids

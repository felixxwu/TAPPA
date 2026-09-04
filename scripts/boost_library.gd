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
# other six categories all land on ordinary per-car GameConfig fields with no such
# conflict.
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
	},
	"aero": {
		"label": "Aero kit",
		"effect_fields": {
			"downforce_front": "run_boost_downforce_n",
			"downforce_rear": "run_boost_downforce_n",
		},
		"level_direction": 1,  # more downforce = more boost
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


# Shop display text (decision 42): the % swing a boost's magnitude gets pushed by across the
# WHOLE purchasable ladder (level 1 through GameConfig.boost_level_max), not a bare level
# number or the raw GameConfig magnitude — a raw multiplier means nothing to a player without
# knowing the car's own baseline stat, so this is expressed purely as "how far a level pushes
# it", which reads the same regardless of the effect's op (mult/add/set). Always shown
# ascending (the smaller-magnitude end first), signed so the direction of the swing is
# visible. "" for an unknown id.
static func effect_range_text(id: String) -> String:
	var entry: Dictionary = CATALOGUE.get(id, {})
	if entry.is_empty():
		return ""
	var direction := int(entry.get("level_direction", 1))
	var cfg: GameConfig = Config.data
	var lo := (level_scale(1, direction) - 1.0) * 100.0
	var hi := (level_scale(cfg.boost_level_max, direction) - 1.0) * 100.0
	if hi < lo:
		var t := lo
		lo = hi
		hi = t
	return "%+.0f%% to %+.0f%%" % [lo, hi]


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

class_name RallyLibrary
extends RefCounted
# The finite, curated list of rallies — authored CONTENT (like CarLibrary), not
# player state. A rally is a fixed set of 3 seeded TrackGenerator tracks plus a
# car restriction and a difficulty tier; player completion lives in the save
# profile (todo/save-persistence.md), keyed by the stable `id` here.
#
# This file is also the home of the pure functions the rest of the game needs:
#   * is_eligible(rally, car_meta)            — can this car enter?
#   * generate_opponent_field(rally, event_results, events) — the deterministic opponent field
#   * completed_count / showdown_unlocked      — progress + end-game gate
#   * incomplete_rallies_enterable_by(...)     — the anti-soft-lock query
#
# Determinism is the whole point: TrackGenerator.generate is deterministic for a
# given (seed, turn_count, width), and the opponent field is reseeded from the
# rally id, so re-attempting a rally chases the SAME fixed leaderboard (damage
# sticks; opponents never re-roll).

# Default event width when an EventDef omits one. Mirrors GameConfig.track_width
# (game_config.gd) — the authored baseline track width.
const DEFAULT_WIDTH := 6.0

# Opponent-field shape (gameplay.md): 10–15 rivals. A rival can CRASH OUT of an event
# (a wreck = a DNF; a DNF in any event disqualifies the whole rally). Wrecks are rare
# and capped so the run scene can show at most one wrecked rival by the roadside per
# event (features/opponent-wrecks.md): each event independently has an
# OPPONENT_WRECK_CHANCE of wrecking exactly ONE not-yet-wrecked rival, so on average
# about one rival wrecks every two events, and never more than one per event.
const FIELD_MIN := 10
const FIELD_MAX := 15
const OPPONENT_WRECK_CHANCE := 0.5   # per-event: probability ONE rival crashes out this event

# Rival pace, as multiples of each rival's OWN physics floor (optimum_ms for THEIR
# car on the event track). Each rival gets a PERSISTENT skill (drawn once, not per
# event): skill 0 = ace, skill 1 = backmarker. Their base pace is lerp(pace_fast,
# pace_slow, skill), so a fast rival is fast across ALL 3 events and combined times
# spread into a ranked ladder — rather than every rival's per-event draws averaging
# out to mid-pack. Each event then applies a small ±PACE_EVENT_NOISE jitter around
# that base pace so stages don't feel robotic and the odd upset can happen, without
# collapsing the ranking.
#
# The fast end of the band is fixed: the fastest rival (skill 0) runs at 1.1x the
# car's physics optimum at EVERY tier. Only the slow end scales with the rally's
# HIDDEN difficulty tier (1–4) — it tightens toward the fast end as the tier rises,
# so higher-tier rallies field a more uniformly quick pack (tier-1 backmarker is 2.0x
# their optimum; tier-4 backmarker is 1.5x). See _pace_band().
const PACE_FAST_BASE := 1.10     # fastest-rival pace (skill 0) — same at every tier
const PACE_SLOW_BASE := 2.00     # tier-1 slowest-rival pace (skill 1)
const PACE_FAST_STEP := 0.00     # fast end does not move with tier
const PACE_SLOW_STEP := 0.1667   # each tier above 1 pulls the slow end down (2.0 -> 1.5 by tier 4)
const PACE_EVENT_NOISE := 0.05   # ±5% per-event jitter around a rival's persistent base pace
const PACE_MIN_FLOOR := 1.00     # hard clamp: rivals never beat their car's physics optimum

# The rally p/w ceiling (pw_max below) is AUTHORED in hp/tonne — the same
# unit the HUD / detail panel / detune slider show (hq.gd) — so a designer tunes
# the ceilings in the numbers they see on screen. CarLibrary.power_to_weight() returns
# kW/kg, so is_eligible converts a car's figure to hp/tonne with this factor before
# comparing it against the authored ceiling. Uses CarLibrary.KW_KG_TO_HP_TONNE — the
# single source of truth for the conversion, shared with hq.gd.
const KW_KG_TO_HP_TONNE := CarLibrary.KW_KG_TO_HP_TONNE


# Rival pace band as (pace_fast, pace_slow) — the pace of the fastest (skill 0) and
# slowest (skill 1) rival for a rally of the given hidden difficulty. The fast end
# is a constant 1.1x (just off the physics optimum); only the slow end tightens up-tier.
static func _pace_band(tier: int) -> Vector2:
	var t := clampi(tier, 1, 4) - 1
	return Vector2(PACE_FAST_BASE - t * PACE_FAST_STEP, PACE_SLOW_BASE - t * PACE_SLOW_STEP)


# Each entry: a RallyDef. `restriction` is an empty Dictionary for open-class
# (every car eligible); otherwise every present field must match the car's
# CarLibrary metadata. Progression is PRIMARILY gated on power-to-weight: every
# non-showdown rally carries a `pw_max` ceiling so an over-powered car can't walk
# it. There is no hard floor — a car well under the ceiling can still enter, but
# the start line warns the player it's underpowered (see `underpower_warning`,
# fired below PW_WARN_FRACTION of `pw_max`). A rally may layer a
# secondary theme on top of its p/w ceiling (e.g. RWD Masters also wants `drive_mode`
# RWD). `difficulty` is a HIDDEN tier (never shown to the player) that drives the
# reward tier (clamped by progress) and sort order — the p/w gate is the visible
# requirement. `events` is exactly 3 EventDefs (the showdown's are longer). Each
# region (see RegionLibrary, `region` tag) has exactly one entry with
# `showdown = true`, kept open-class so the low-power starter can always finish it.
const RALLIES: Array[Dictionary] = [
	{
		"id": "shakedown", "name": "Shakedown", "region": "home", "difficulty": 1, "showdown": false,
		"map_pos": Vector2(0.18, 0.72),  # normalised pin position on the world map (hq.gd)
		"restriction": {"pw_max": 180.0},  # a low p/w ceiling — the starter's home (ceiling clears the MX-5 ~159 / XJS ~175 hp/t)
		"events": [
			{"seed": 1007, "turn_count": 10, "forestiness": 0.2, "surface_mix": 1, "straightness": 1, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 12.0, "terrain_layer2_amplitude": 3.0},
			{"seed": 1008, "turn_count": 10, "forestiness": 0.4, "surface_mix": 0, "straightness": 0.8, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 11.3, "terrain_layer2_amplitude": 3.0},
			{"seed": 1009, "turn_count": 10, "forestiness": 0.6, "surface_mix": 0.3, "straightness": 0.8, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 12.8, "terrain_layer2_amplitude": 3.0},
		],
	},
	{
		"id": "front_runners", "name": "Front Runners", "region": "home", "difficulty": 1, "showdown": false,
		"map_pos": Vector2(0.26, 0.6),
		# FWD intro rally: a low p/w ceiling that welcomes both FWD starters (Twingo ~82,
		# Focus ~114 hp/t) — the FWD home (parallels Shakedown for the MX-5).
		"restriction": {"drive_mode": CarLibrary.FWD, "pw_max": 132.0},
		"events": [
			{"seed": 1101, "turn_count": 10, "forestiness": 0.6, "surface_mix": 0.4, "straightness": 0.85, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 14.6},
			{"seed": 1102, "turn_count": 12, "forestiness": 0.5, "surface_mix": 0.6, "straightness": 0.8, "cliffiness": 0.25, "water_level": -12.0, "terrain_layer1_amplitude": 15.4},
			{"seed": 1103, "turn_count": 11, "forestiness": 0.75, "surface_mix": 0.3, "straightness": 0.8, "cliffiness": 0.3, "water_level": -12.0, "terrain_layer1_amplitude": 14.1},
		],
	},
	{
		"id": "coastal_sprint", "name": "Coastal Sprint", "region": "home", "difficulty": 2, "showdown": false,
		"map_pos": Vector2(0.34, 0.5),
		"restriction": {"pw_max": 210.0},  # a slightly higher p/w ceiling
		"events": [
			{"seed": 2004, "turn_count": 14, "forestiness": 0.6, "surface_mix": 1.0, "straightness": 0, "cliffiness": 0.55, "water_level": -5.0, "terrain_layer1_amplitude": 18.2},
			{"seed": 2005, "turn_count": 13, "forestiness": 0.6, "surface_mix": 0.7, "straightness": 0.2, "cliffiness": 0.65, "water_level": -5.0, "terrain_layer1_amplitude": 17.5},
			{"seed": 2007, "turn_count": 15, "forestiness": 0.45, "surface_mix": 1.0, "straightness": 0.3, "cliffiness": 0.5, "water_level": -5.0, "terrain_layer1_amplitude": 18.9},
		],
	},
	{
		"id": "rwd_masters", "name": "RWD Masters", "region": "home", "difficulty": 3, "showdown": false,
		"map_pos": Vector2(0.52, 0.64),
		# p/w ceiling (primary gate) + an RWD theme: a mid-power rear-driven field.
		"restriction": {"drive_mode": CarLibrary.RWD, "pw_max": 230.0},  # ceiling nudged above the Charger/911's ~216-220 hp/t
		"events": [
			{"seed": 3001, "turn_count": 13, "forestiness": 0.5, "surface_mix": 0.5, "straightness": 0.5, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 20.7},
			{"seed": 3012, "turn_count": 14, "forestiness": 0.8, "surface_mix": 1.0, "straightness": 0.45, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 21.6},
			{"seed": 3004, "turn_count": 13, "forestiness": 0.35, "surface_mix": 0.0, "straightness": 0.5, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 22.0},
		],
	},
	{
		# id kept as "rising_sun" (saves key rally progress on the stable id) even though
		# the event was reworked from a JP-only rally into an open power-band one: with
		# the real-derived p/w figures no stock JP car came near this band, so the
		# country gate went and the band alone now hosts the stock heavy hitters
		# (Charger ~216, 911 ~220, Viper ~264 hp/tonne — the Viper's only stock rally).
		"id": "rising_sun", "name": "Heavy Hitters", "region": "home", "difficulty": 3, "showdown": false,
		"map_pos": Vector2(0.82, 0.34),
		"restriction": {"pw_max": 301.0},
		"events": [
			{"seed": 4001, "turn_count": 16, "forestiness": 0.6, "surface_mix": 0.6, "straightness": 0.25, "cliffiness": 0.55, "water_level": -12.0, "terrain_layer1_amplitude": 16.4},
			{"seed": 4004, "turn_count": 15, "forestiness": 0.4, "surface_mix": 0.0, "straightness": 0.2, "cliffiness": 0.7, "water_level": -12.0, "terrain_layer1_amplitude": 15.8},
			{"seed": 3734559043, "turn_count": 17, "forestiness": 0.75, "surface_mix": 1.0, "straightness": 0.25, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 17.1},
		],
	},
	{
		"id": "grand_tour", "name": "Grand Tour", "region": "home", "difficulty": 3, "showdown": false,
		"map_pos": Vector2(0.66, 0.28),
		"restriction": {"pw_max": 378.0},  # the top non-showdown p/w ceiling (The Beast derives to ~350 hp/t)
		"events": [
			{"seed": 1003214539, "turn_count": 18, "forestiness": 0.5, "surface_mix": 1.0, "straightness": 0.5, "cliffiness": 0.75, "water_level": -12.0, "terrain_layer1_amplitude": 23.1},
			{"seed": 5004, "turn_count": 17, "forestiness": 0.3, "surface_mix": 0.4, "straightness": 0.15, "cliffiness": 0.85, "water_level": -12.0, "terrain_layer1_amplitude": 22.4},
			{"seed": 5003, "turn_count": 19, "forestiness": 0.7, "surface_mix": 0.0, "straightness": 0.1, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 24.0},
		],
	},
	{
		"id": "american_muscle", "name": "American Muscle", "region": "home", "difficulty": 2, "showdown": false,
		"map_pos": Vector2(0.42, 0.38),
		# US-built muscle only, under a mid p/w ceiling — the Charger's home turf.
		"restriction": {"country": "US", "car_type": "muscle", "pw_max": 266.0},
		"events": [
			{"seed": 6001, "turn_count": 12, "forestiness": 0.3, "surface_mix": 0.8, "straightness": 0.7, "cliffiness": 0.3, "water_level": -12.0, "terrain_layer1_amplitude": 13.5},
			{"seed": 6002, "turn_count": 13, "forestiness": 0.5, "surface_mix": 0.5, "straightness": 0.6, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 12.9},
			{"seed": 6003, "turn_count": 12, "forestiness": 0.4, "surface_mix": 1.0, "straightness": 0.65, "cliffiness": 0.35, "water_level": -12.0, "terrain_layer1_amplitude": 14.2},
		],
	},
	{
		"id": "shitbox_cup", "name": "Sh*tbox Cup", "region": "home", "difficulty": 1, "showdown": false,
		"map_pos": Vector2(0.12, 0.48),
		# Gated ONLY from above, below even Shakedown's floor: a sub-91 hp/tonne p/w
		# ceiling that only the true shitboxes (Twingo, Acty) squeeze under.
		"restriction": {"pw_max": 91.0},
		"events": [
			{"seed": 7031, "turn_count": 9, "forestiness": 0.3, "surface_mix": 0.0, "straightness": 0, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 10.6, "terrain_layer2_amplitude": 5.0},
			{"seed": 7002, "turn_count": 10, "forestiness": 0.5, "surface_mix": 0.5, "straightness": 0, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 11.4, "terrain_layer2_amplitude": 5.0},
			{"seed": 7033, "turn_count": 9, "forestiness": 0.4, "surface_mix": 0.0, "straightness": 0, "cliffiness": 0.7, "water_level": -12.0, "terrain_layer1_amplitude": 10.9, "terrain_layer2_amplitude": 5.0},
		],
	},
	{
		"id": "the_showdown", "name": "The Showdown", "region": "home", "difficulty": 4, "showdown": true,
		"map_pos": Vector2(0.5, 0.12),
		"restriction": {},  # open so the low-power starter can always finish the game
		"events": [
			{"seed": 9001, "turn_count": 22, "forestiness": 0.8, "surface_mix": 0.5, "cliffiness": 0.8, "water_level": -12.0, "terrain_layer1_amplitude": 24.3},
			{"seed": 9002, "turn_count": 24, "forestiness": 0.5, "surface_mix": 0.8, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 23.6},
			{"seed": 9003, "turn_count": 22, "forestiness": 0.65, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -12.0, "terrain_layer1_amplitude": 24.8},
		],
	},
	# --- Greece (region "greece") --------------------------------------------
	{
		"id": "gr_olive_coast", "name": "Olive Coast", "region": "greece", "difficulty": 2, "showdown": false,
		"map_pos": Vector2(0.30, 0.62),
		"restriction": {"pw_max": 230.0},
		"events": [
			{"seed": 21001, "turn_count": 13, "forestiness": 0.75, "surface_mix": 0.25, "straightness": 0.4, "cliffiness": 0.5},
			{"seed": 21002, "turn_count": 14, "forestiness": 0.65, "surface_mix": 0.15, "straightness": 0.3, "cliffiness": 0.6},
			{"seed": 21003, "turn_count": 13, "forestiness": 0.85, "surface_mix": 0.3, "straightness": 0.35, "cliffiness": 0.55},
		],
	},
	{
		"id": "gr_mountain_pass", "name": "Mountain Pass", "region": "greece", "difficulty": 3, "showdown": false,
		"map_pos": Vector2(0.52, 0.44),
		"restriction": {"pw_max": 301.0},
		"events": [
			{"seed": 22001, "turn_count": 15, "forestiness": 0.65, "surface_mix": 0.1, "straightness": 0.2, "cliffiness": 0.8},
			{"seed": 22002, "turn_count": 16, "forestiness": 0.75, "surface_mix": 0.05, "straightness": 0.15, "cliffiness": 0.9},
			{"seed": 22003, "turn_count": 15, "forestiness": 0.7, "surface_mix": 0.0, "straightness": 0.2, "cliffiness": 0.85},
		],
	},
	{
		"id": "gr_ancient_ruins", "name": "Ancient Ruins", "region": "greece", "difficulty": 3, "showdown": false,
		"map_pos": Vector2(0.70, 0.58),
		"restriction": {"pw_max": 378.0},
		"events": [
			{"seed": 23001, "turn_count": 16, "forestiness": 0.6, "surface_mix": 0.2, "straightness": 0.3, "cliffiness": 0.7},
			{"seed": 23002, "turn_count": 17, "forestiness": 0.65, "surface_mix": 0.1, "straightness": 0.2, "cliffiness": 0.85},
			{"seed": 23003, "turn_count": 16, "forestiness": 0.75, "surface_mix": 0.35, "straightness": 0.25, "cliffiness": 0.75},
		],
	},
	{
		"id": "gr_showdown", "name": "The Aegean Crown", "region": "greece", "difficulty": 4, "showdown": true,
		"map_pos": Vector2(0.50, 0.24),
		"restriction": {},  # open-class finale
		"events": [
			{"seed": 29001, "turn_count": 22, "forestiness": 0.75, "surface_mix": 0.15, "cliffiness": 0.85},
			{"seed": 29002, "turn_count": 24, "forestiness": 0.65, "surface_mix": 0.25, "cliffiness": 0.95},
			{"seed": 29003, "turn_count": 22, "forestiness": 0.85, "surface_mix": 0.1, "cliffiness": 1.0},
		],
	},
]


# --- Lookups -----------------------------------------------------------------
# Test seam + stable-id lookups via the shared Registry helper (scripts/registry.gd),
# matching CarLibrary/EngineLibrary. An empty override means "use the shipped
# RALLIES"; tests call override_for_test()/reset() to run against a synthetic list.
static var _seam := Registry.Seam.new(RALLIES)

static func all() -> Array[Dictionary]:
	return _seam.all()

static func override_for_test(rallies: Array[Dictionary]) -> void:
	_seam.override_for_test(rallies)

static func reset() -> void:
	_seam.reset()


static func index_of(id: String) -> int:
	return Registry.index_of(all(), id)


static func by_id(id: String) -> Dictionary:
	return Registry.by_id(all(), id)


# Width an event runs at — its override, else the authored default.
static func event_width(event: Dictionary) -> float:
	return float(event.get("width", DEFAULT_WIDTH))


# How forested this event is, in [0, 1]: the fraction of the area covered by trees.
# Trees only spawn where a 300 m-wavelength noise field exceeds (1 - forestiness), so
# higher = denser forest, 0 = bare, 1 = trees everywhere (the default for an event that
# omits it). Bushes ignore this. See TreeScatter / features/trees.md.
static func event_forestiness(event: Dictionary) -> float:
	return clampf(float(event.get("forestiness", 1.0)), 0.0, 1.0)


# Fraction of this event's track surfaced as tarmac, in [0, 1] (the rest gravel).
# The track switches surface exactly once along its length (TrackSurface); 0 = all
# gravel, 1 = all tarmac. The default (0) keeps an event that omits it all gravel.
static func event_tarmac_fraction(event: Dictionary) -> float:
	return clampf(float(event.get("surface_mix", 0.0)), 0.0, 1.0)


# Bias toward straighter (easier) turns when generating this event's track, in
# [0, 1]: 0 = no bias (corners chosen freely), 1 = strongly favour gentle corners
# and long straights. Earlier, lower-tier events run higher so their stages are
# gentler; the default (0) leaves generation unbiased. Fed to TrackGenerator.generate
# (it changes the track SHAPE, so the same value is used when deriving target times).
static func event_straightness(event: Dictionary) -> float:
	return clampf(float(event.get("straightness", 0.0)), 0.0, 1.0)


# How cliffy this event's stage is, in [0, 1]: 0 = flat (no cliffs/drops), 1 = the
# tallest cliffs/deepest drops (cliff_max_height_m). Scales the global height ceiling
# (GameConfig.cliff_amount); the camber wavelength stays global. Default 0 keeps an
# event that omits it flat. Cliffs don't change the centerline or the flat lengthwise
# road profile, so this does NOT feed opponent target-time derivation.
static func event_cliffiness(event: Dictionary) -> float:
	return clampf(float(event.get("cliffiness", 0.0)), 0.0, 1.0)


# --- Eligibility -------------------------------------------------------------

# Whether `car_meta` (a CarLibrary entry dict, resolved by the owned car's stable
# model_id — never array index) satisfies a rally's restriction. Open-class
# (empty restriction) always matches. For an OWNED car, callers pass the car's
# effective stats (UpgradeLibrary.effective_meta) so an installed engine kit or
# weight reduction can qualify / disqualify it via the pw_max ceiling; the
# raw CARS entry is only the right input for an unmodified roster car (rivals).
static func ineligibility_reason(rally: Dictionary, car_meta: Dictionary) -> String:
	var r: Dictionary = rally.get("restriction", {})
	if r.is_empty():
		return ""
	if r.has("drive_mode") and int(car_meta.get("drive_mode", -1)) != int(r["drive_mode"]):
		return "Wrong drivetrain for this class"
	if r.has("country") and String(car_meta.get("country", "")) != String(r["country"]):
		return "Wrong country of origin for this class"
	if r.has("car_type") and String(car_meta.get("car_type", "")) != String(r["car_type"]):
		return "Wrong car type for this class"
	var disp := float(car_meta.get("engine_displacement_l", 0.0))
	if r.has("engine_min_l") and disp < float(r["engine_min_l"]):
		return "Engine too small for this class"
	if r.has("engine_max_l") and disp > float(r["engine_max_l"]):
		return "Engine too large for this class"
	# power_to_weight is kW/kg; the authored ceiling is hp/tonne — convert before comparing.
	var pw := CarLibrary.power_to_weight(car_meta) * KW_KG_TO_HP_TONNE
	if r.has("pw_max") and pw > float(r["pw_max"]):
		return "Power-to-weight too high (%d hp/t, max %d)" % [roundi(pw), roundi(float(r["pw_max"]))]
	return ""


static func is_eligible(rally: Dictionary, car_meta: Dictionary) -> bool:
	return ineligibility_reason(rally, car_meta) == ""


# Fraction of a rally's `pw_max` ceiling below which a fielded car counts as
# underpowered. The car is still eligible (there is no hard floor); this only
# drives a non-blocking start-line warning.
const PW_WARN_FRACTION := 0.75


# A warning shown when `car_meta` may field a rally but its power-to-weight sits far
# below the class ceiling (< PW_WARN_FRACTION of `pw_max`) — the player can still
# start, they're just underpowered. Returns "" when there's no ceiling or the car is
# strong enough. `car_meta` is the effective (UpgradeLibrary.effective_meta) stats, as
# with ineligibility_reason.
static func underpower_warning(rally: Dictionary, car_meta: Dictionary) -> String:
	var r: Dictionary = rally.get("restriction", {})
	if not r.has("pw_max"):
		return ""
	var pw := CarLibrary.power_to_weight(car_meta) * KW_KG_TO_HP_TONNE
	var recommended := float(r["pw_max"]) * PW_WARN_FRACTION
	if pw >= recommended:
		return ""
	return "Underpowered for this class (%d hp/t, %d+ recommended)" % [roundi(pw), roundi(recommended)]


# The largest engine-detune fraction at which a car passes `rally`'s restriction,
# or -1.0 when no detune can qualify it (a non-power restriction field fails).
# `full_meta` is the car's effective stats at FULL
# tune (UpgradeLibrary.effective_meta with engine_detune 1.0), so the result is an
# absolute detune-slider setting, not a value relative to the current tune; a car
# already eligible at full tune returns 1.0. Torque — hence peak power and
# power-to-weight — scales linearly with the detune fraction, so the target is the
# cap/full ratio, floored to the tune slider's whole-percent steps so the value
# round-trips through the UI. The result is verified back through is_eligible.
static func qualifying_detune(rally: Dictionary, full_meta: Dictionary) -> float:
	if is_eligible(rally, full_meta):
		return 1.0
	var r: Dictionary = rally.get("restriction", {})
	var pw := CarLibrary.power_to_weight(full_meta) * KW_KG_TO_HP_TONNE
	if not r.has("pw_max") or pw <= float(r["pw_max"]):
		return -1.0  # ineligible for a reason detuning can't fix
	var frac := floorf(float(r["pw_max"]) / pw * 100.0) / 100.0
	if frac <= 0.0:
		return -1.0
	var eng := EngineLibrary.by_id(String(full_meta.get("engine", "")))
	var scaled := full_meta.duplicate()
	scaled["peak_torque"] = float(full_meta.get("peak_torque", eng.get("peak_torque", 0.0))) * frac
	return frac if is_eligible(rally, scaled) else -1.0


# The eligible car with the highest power-to-weight for a rally. Falls back to the
# best car in the whole roster when `rally` is empty (legacy/test callers).
static func _best_eligible_car(rally: Dictionary) -> Dictionary:
	var pool: Array = _eligible_cars(rally) if not rally.is_empty() else CarLibrary.all()
	var best: Dictionary = {}
	var best_pw := -1.0
	for car in pool:
		# Rank by the STOCK-boosted meta (mirrors how rivals actually drive in
		# generate_opponent_field), so the "fastest possible car" reflects the same
		# forced induction a turbo car's rival gets — not the unboosted figure.
		var meta := UpgradeLibrary.effective_meta({}, car)
		var pw := CarLibrary.power_to_weight(meta)
		if pw > best_pw:
			best_pw = pw
			best = meta
	return best


# --- In-stage turn splits (for the live "vs P1" pace popup) ------------------

# Per-turn cumulative split table off a SPECIFIC car's optimum velocity profile —
# used by the run scene's "vs P1" pace popup (so the popup tracks P1's real car).
# For each placed piece returns the arc length at the END of that turn and the
# cumulative time (ms) to there, read off LapTimeModel.optimum_profile(car). The
# final entry's cum_ms equals optimum_ms(track, car, event). An event's
# target_ms_override rescales the cumulative times to land on it, preserving the
# per-turn profile (the popup only uses fractions, so the rescale cancels there).
# Returns Array of { "end_offset_m": float, "cum_ms": int }; empty if no pieces.
static func derive_turn_splits(track_result: Dictionary, car_meta: Dictionary, event: Dictionary = {}) -> Array:
	var centerline := track_result.get("centerline") as Curve2D
	var pieces: Array = track_result.get("pieces", [])
	if centerline == null or pieces.is_empty():
		return []
	var prof := LapTimeModel.optimum_profile(track_result, car_meta, event)
	var s: PackedFloat32Array = prof["s"]
	var t: PackedFloat32Array = prof["t"]
	if s.size() < 2:
		return []
	var baked := centerline.get_baked_length()
	var splits: Array = []
	for i in pieces.size():
		var end_off := baked
		if i + 1 < pieces.size():
			var next_entry: Vector2 = pieces[i + 1].get("entry_pos", Vector2.ZERO)
			end_off = centerline.get_closest_offset(next_entry)
		var secs := _time_at_offset(s, t, end_off)
		splits.append({"end_offset_m": end_off, "cum_ms": int(round(secs * 1000.0))})
	if event.has("target_ms_override"):
		var natural_total := float(splits[splits.size() - 1]["cum_ms"])
		if natural_total > 0.0:
			var override_total := float(int(event["target_ms_override"]))
			for sp in splits:
				sp["cum_ms"] = int(round(float(sp["cum_ms"]) / natural_total * override_total))
	return splits


# Linear-interpolate the cumulative time (s) at an arc offset within the profile's
# monotonic s[] / t[] arrays.
static func _time_at_offset(s: PackedFloat32Array, t: PackedFloat32Array, off: float) -> float:
	var n := s.size()
	if off <= s[0]:
		return t[0]
	if off >= s[n - 1]:
		return t[n - 1]
	for i in range(1, n):
		if s[i] >= off:
			var span := s[i] - s[i - 1]
			var f := (off - s[i - 1]) / span if span > 0.0 else 0.0
			return lerpf(t[i - 1], t[i], f)
	return t[n - 1]


# --- Opponent field (recomputed from the rally seed, never saved) ------------

# The fixed opponent field for a rally, given each event's track result and event
# dict. Reseeded from the rally id so the leaderboard is identical across re-attempts.
# Returns an Array of opponents:
#   { name: String, car_id: String, car_name: String,
#     event_times_ms: Array[int], dnf: bool, combined_ms: int,
#     wreck_event: int, wreck_progress: float, wreck_side: float }
# Each rival is assigned a car from the rally's eligible roster (so e.g. an
# RWD-only rally fields RWD rivals), drawn from the same seeded RNG so the line-up
# is stable across re-attempts. Each rival's event time is derived from their OWN
# car's physics floor (optimum_ms) scaled by a per-rival factor in the pace band,
# so a faster car fields a faster time.
#
# Wrecks (features/opponent-wrecks.md): after the times are drawn, each event
# independently rolls OPPONENT_WRECK_CHANCE to crash ONE not-yet-wrecked rival out.
# A wrecked rival has event_times_ms[wreck_event..] = -1 and DNFs the rally
# (combined_ms = -1, doesn't rank), and carries the seeded roadside placement
# (`wreck_progress` along the track, `wreck_side` = which verge) the run scene reads
# to stage the wreck. `wreck_event` = -1 for a rival who finishes. At most one rival
# wrecks per event, so the run scene shows at most one roadside wreck per stage.
static func generate_opponent_field(rally: Dictionary, event_results: Array, events: Array) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = _rally_seed(rally)
	var car_pool := _eligible_cars(rally)
	var count := rng.randi_range(FIELD_MIN, FIELD_MAX)
	var band := _pace_band(int(rally.get("difficulty", 1)))
	var field: Array = []
	for i in count:
		var car: Dictionary = car_pool[rng.randi_range(0, car_pool.size() - 1)]
		# Boost the raw CarLibrary entry through effective_meta (with no owned-car
		# state) so the rival's pace floor reflects the car's STOCK forced induction —
		# e.g. the 911's turbo. Without this, power_to_weight falls back to the engine's
		# unboosted peak_torque and turbo cars produce artificially slow rival times,
		# out of step with the player's boosted stats and the car's real physics.
		var car_meta := UpgradeLibrary.effective_meta({}, car)
		# Persistent per-rival skill (drawn ONCE): sets a base pace held across every
		# event, so fast rivals stay fast and the field forms a ranked ladder.
		var skill := rng.randf()
		var base_pace := lerpf(band.x, band.y, skill)
		var times: Array = []
		for k in event_results.size():
			var ev: Dictionary = events[k] if k < events.size() else {}
			var floor_ms := LapTimeModel.optimum_ms(event_results[k], car_meta, ev)
			var noise := 1.0 + (rng.randf() * 2.0 - 1.0) * PACE_EVENT_NOISE
			var factor := maxf(base_pace * noise, PACE_MIN_FLOOR)
			times.append(int(round(floor_ms * factor)))
		field.append({
			"name": "Rival %d" % (i + 1),
			"car_id": String(car.get("id", "")),
			"car_name": String(car.get("name", "")),
			"event_times_ms": times,
			"dnf": false,
			"combined_ms": 0,
			"wreck_event": -1,
			"wreck_progress": 0.0,
			"wreck_side": 1.0,
		})
	# Wreck pass: each event crashes at most one still-running rival out. Drawn from the
	# SAME seeded RNG so the wreck (and its roadside placement) is stable across
	# re-attempts, exactly like the times above.
	for k in event_results.size():
		if rng.randf() >= OPPONENT_WRECK_CHANCE:
			continue
		var candidates: Array = []
		for i in field.size():
			if int(field[i]["wreck_event"]) < 0:
				candidates.append(i)
		if candidates.is_empty():
			continue
		var pick: int = candidates[rng.randi_range(0, candidates.size() - 1)]
		field[pick]["wreck_event"] = k
		# Seeded roadside placement: a fraction along the timed track (kept off the
		# start/finish) and which verge (±1). The run scene turns these into a world pose.
		field[pick]["wreck_progress"] = rng.randf_range(0.15, 0.85)
		field[pick]["wreck_side"] = 1.0 if rng.randf() < 0.5 else -1.0
		# Crashed out here: no time for this event or any after it.
		for kk in range(k, event_results.size()):
			field[pick]["event_times_ms"][kk] = -1
	# Finalise DNF + combined time now the wrecks are settled.
	for opp in field:
		var dnf: bool = int(opp["wreck_event"]) >= 0
		opp["dnf"] = dnf
		if dnf:
			opp["combined_ms"] = -1
		else:
			var combined := 0
			for tm in opp["event_times_ms"]:
				combined += int(tm)
			opp["combined_ms"] = combined
	return field


# The rival (if any) who wrecked in `event_index`, for the run scene to stage a
# roadside wreck (features/opponent-wrecks.md). Returns the crashed rival's identity,
# the ACTUAL car they drove, and the seeded placement:
#   { name, car_id, car_name, progress: float (0-1 along the track), side: float (±1) }
# or {} when no rival wrecked that event (at most one ever does). Pure read over the
# field generate_opponent_field produced.
static func event_wreck(field: Array, event_index: int) -> Dictionary:
	if event_index < 0:
		return {}
	for opp in field:
		if int(opp.get("wreck_event", -1)) == event_index:
			return {
				"name": String(opp.get("name", "Rival")),
				"car_id": String(opp.get("car_id", "")),
				"car_name": String(opp.get("car_name", "")),
				"progress": float(opp.get("wreck_progress", 0.5)),
				"side": float(opp.get("wreck_side", 1.0)),
			}
	return {}


# The CarLibrary entries a rally's restriction admits — the pool its rivals are
# drawn from. Falls back to the whole roster if a restriction somehow admits no
# car (it never should; open-class admits everything).
static func _eligible_cars(rally: Dictionary) -> Array:
	var pool: Array = []
	for entry in CarLibrary.all():
		if is_eligible(rally, entry):
			pool.append(entry)
	return pool if not pool.is_empty() else CarLibrary.all()


# CarLibrary.all() indices a rally's restriction admits — the pool an index-based
# spawner (the start-line queue props, start_line.gd) draws its cars from, so the
# cars bookending the player are always eligible for the rally. Falls back to every
# index if a restriction somehow admits none (it never should; open-class admits all).
static func eligible_car_indices(rally: Dictionary) -> Array:
	var pool: Array = []
	for i in CarLibrary.all().size():
		if is_eligible(rally, CarLibrary.all()[i]):
			pool.append(i)
	if pool.is_empty():
		for i in CarLibrary.all().size():
			pool.append(i)
	return pool


# Player's 1-based placement on combined time among the non-DNF field (the
# player counts as one entrant). A faster combined time places ahead.
static func placement(field: Array, player_combined_ms: int) -> int:
	var ahead := 0
	for opp in field:
		if not opp.get("dnf", false) and int(opp["combined_ms"]) < player_combined_ms:
			ahead += 1
	return ahead + 1


static func is_top3(field: Array, player_combined_ms: int) -> bool:
	return placement(field, player_combined_ms) <= 3


# A fully ranked standings table for the results screen (todo/menus.md overlay 7):
# the opponent field plus the player, sorted fastest-combined-first with the DNF
# entries (wrecked / disqualified) sinking to the bottom. Each entry:
#   { name:String, car_name:String, car_id:String, combined_ms:int, dnf:bool, is_player:bool, placed:int }
# `car_name` is the car that entrant drove (the leaderboard shows it); empty when
# unknown. `car_id` is that car's stable CarLibrary id (so the podium can spawn the
# top-3 cars' 3D models); empty when unknown. `placed` is the 1-based finishing position among the classified
# (non-DNF) entries; DNF entries get placed = -1. Consistent with placement() — a
# non-DNF player's `placed` equals placement(field, player_combined_ms).
static func build_standings(field: Array, player_combined_ms: int, player_dnf: bool, player_name := "You", player_car_name := "", player_car_id := "") -> Array:
	var entries: Array = []
	for opp in field:
		entries.append({
			"name": String(opp.get("name", "Rival")),
			"car_name": String(opp.get("car_name", "")),
			"car_id": String(opp.get("car_id", "")),
			"combined_ms": int(opp.get("combined_ms", -1)),
			"dnf": bool(opp.get("dnf", false)),
			"is_player": false,
		})
	entries.append({
		"name": player_name,
		"car_name": player_car_name,
		"car_id": player_car_id,
		"combined_ms": player_combined_ms,
		"dnf": player_dnf,
		"is_player": true,
	})
	# Classified entries sort by combined time ascending; DNFs always trail them.
	entries.sort_custom(func(a, b):
		if bool(a["dnf"]) != bool(b["dnf"]):
			return not bool(a["dnf"])
		if bool(a["dnf"]):
			return false
		return int(a["combined_ms"]) < int(b["combined_ms"]))
	var pos := 0
	for e in entries:
		if bool(e["dnf"]):
			e["placed"] = -1
		else:
			pos += 1
			e["placed"] = pos
	return entries


# Deterministic integer seed for a rally's opponent field: folds the stable id
# with the first event seed so two rallies never share a field by accident.
static func _rally_seed(rally: Dictionary) -> int:
	var base := int(String(rally.get("id", "")).hash())
	var events: Array = rally.get("events", [])
	if not events.is_empty():
		base = base ^ int(events[0].get("seed", 0))
	return base


# --- Progress / showdown / anti-soft-lock ------------------------------------

# Count of completed rallies in a save profile — the single progression metric
# (caps reward tier + gates the showdown).
static func completed_count(profile: Dictionary) -> int:
	var rallies: Dictionary = profile.get("rallies", {})
	var n := 0
	for rally_id in rallies:
		if rallies[rally_id].get("completed", false):
			n += 1
	return n


# The showdown is enterable only when every non-showdown rally is completed.
static func showdown_unlocked(profile: Dictionary) -> bool:
	var rallies: Dictionary = profile.get("rallies", {})
	for rally in all():
		if rally["showdown"]:
			continue
		if not rallies.get(rally["id"], {}).get("completed", false):
			return false
	return true


# Anti-soft-lock query for the reward system: the still-incomplete rallies a
# given car can currently enter (eligible, and each rally's own region's
# showdown only if THAT region's showdown is unlocked).
static func incomplete_rallies_enterable_by(car_meta: Dictionary, profile: Dictionary) -> Array:
	var rallies: Dictionary = profile.get("rallies", {})
	var out: Array = []
	for rally in all():
		if rallies.get(rally["id"], {}).get("completed", false):
			continue
		if not RegionLibrary.rally_showdown_gate_open(rally, profile):
			continue
		if is_eligible(rally, car_meta):
			out.append(rally)
	return out

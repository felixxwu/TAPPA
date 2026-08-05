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
#   * completions_required / rally_revealed     — progress + the special ladder
#   * incomplete_rallies_enterable_by(...)     — the anti-soft-lock query
#
# Determinism is the whole point: TrackGenerator.generate is deterministic for a
# given (seed, turn_count, width), and the opponent field is reseeded from the
# rally id, so re-attempting a rally chases the SAME fixed leaderboard (damage
# sticks; opponents never re-roll).

# Default event width when an EventDef omits one. Mirrors GameConfig.track_width
# (game_config.gd) — the authored baseline track width.
const DEFAULT_WIDTH := 6.0

# Authored per-event weather conditions (see event_weather below / features/weather.md).
# Enum rather than a 0..1 float so "fog"/"snow"/"night" have an obvious home later.
const WEATHER_DRY := "dry"
const WEATHER_RAIN := "rain"
# Dust storm — authored only onto region == "greece" events (see events below and
# features/weather.md); not enforced here (the funnel stays tolerant of any string),
# but asserted by test_rally_library.gd::test_sandstorm_only_authored_on_greece_events.
const WEATHER_SANDSTORM := "sandstorm"
# Fog — a VISIBILITY condition, and the only DIFFICULTY lever in the table (rivals
# have no eyes, so their times are unchanged). Authored onto FEW events, in the two
# temperate regions ("home" / "home_coast"). See features/weather.md.
const WEATHER_FOG := "fog"
# Storm — heavy rain plus a crosswind and lightning. Authored onto the two COASTAL
# regions ("home_coast" / "greece_coast"), where an exposed crosswind reads.
const WEATHER_STORM := "storm"

# Opponent-field shape (gameplay.md): 10–15 rivals. A rival can CRASH OUT of an event
# (a wreck = a DNF; a DNF in any event disqualifies the whole rally). Wrecks are rare
# and capped so the run scene can show at most one wrecked rival by the roadside per
# event (features/opponent-wrecks.md): each event independently has an
# OPPONENT_WRECK_CHANCE of wrecking exactly ONE not-yet-wrecked rival, so on average
# about one rival wrecks every two events, and never more than one per event.
const FIELD_MIN := 9
const FIELD_MAX := 9
const OPPONENT_WRECK_CHANCE := 0.5   # per-event: probability ONE rival crashes out this event
# How strongly the rival draw favours MODEST engine swaps. Each admitted car+engine combo
# is weighted exp(-|pw - pw_stock| / this), where the deltas are hp/tonne against the
# car's OWN stock engine — so a stock combo is weighted 1.0, a swap this many hp/tonne
# from stock ~0.37, twice that ~0.14. Small = near-stock fields; large = anything goes.
# NOTE: folded into OpponentCache.global_fingerprint(), so retuning it re-keys every
# cached field automatically — do not remove it from that list.
const OPPONENT_SWAP_PW_SPREAD := 25.0

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

# Opponent name pool (cosmetic). A rival is named by drawing from this fixed pool of
# 20 driver names, WITHOUT replacement within a rally, using the same rally-seeded RNG
# as the rest of the field — so the line-up carries a stable set of names across
# re-attempts, and each rival holds the SAME name across all 3 events (the field is
# generated once per rally and reused for every event). The pool is 20 names and the
# field is at most FIELD_MAX (15) rivals, so every rival in a field gets a distinct name.
const RIVAL_NAMES: Array[String] = [
	"Kaj Lindqvist", "Marco Bianchi", "Tomas Novak", "Elena Vasquez",
	"Rauno Mäkinen", "Yuki Tanaka", "Dieter Faust", "Sofia Romano",
	"Colin Brennan", "Petra Havel", "Andre Dubois", "Nikos Papadakis",
	"Ivar Solberg", "Lucia Ferrer", "Ott Rebane", "Hans Gruber",
	"Mireia Costa", "Sami Korhonen", "Bruno Alves", "Katya Orlova",
]

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
# CarLibrary metadata. Every ordinary rally carries a `pw_min`..`pw_max` BAND
# (both in hp/tonne), so a car must sit inside the band to enter — an over-powered
# car is capped out (it can duck under `pw_max` via detune, see `qualifying_detune`)
# and an under-powered one is simply ineligible (the band floor IS the power floor —
# there is no separate soft warning).
#
# The band is deliberately WIDE on most rallies, because the band is not what defines
# the class — the CLASS FIELD is (`car_type`, `country`, `doors_min`/`doors_max`,
# `cylinders_min`/`cylinders_max`, `engine_min_l`/`engine_max_l`, `drive_mode`), with
# the band only trimming the extremes off it. A narrow band picks 2-3 cars
# ARBITRARILY and silently re-picks them the moment a car is retuned; "four-cylinder,
# two-door" or "British cars" picks a group that reads as a real class and survives
# retuning. When a rally wants to group by a property the catalogue does not record,
# ADD that property to the car/engine definitions — never approximate it with a proxy
# field that happens to correlate today. `difficulty` is a HIDDEN tier (never shown to the player) that
# drives the reward tier (clamped by progress) and sort order — the p/w band is the
# visible requirement. `reveal_after` (int, default 0) is the GLOBAL reveal gate: the
# rally's pin stays hidden until the player has completed that many ordinary rallies
# ANYWHERE on the roster, so the world map reveals ~1-2 fresh rallies at a time instead of
# dumping them all at once — and a win in one corner can open a rally in another (see
# `rally_revealed`). `events` is exactly 3 EventDefs (a special's are longer).
#
# A SPECIAL event (`special: true` + `requires_completions: N`) is gated on the player's
# GLOBAL count of completed ORDINARY rallies (`rally_revealed` via `completions_required`),
# not on its region's contents — the old "exactly one showdown per region" invariant is
# RETIRED, so a corner may hold any number of specials, including none (the snow corner
# ships pin-less). Every special stays OPEN-CLASS (`restriction: {}`): a special must never
# gate on a part it or a higher rung unlocks, or the ladder can deadlock, and it keeps the
# low-power starter able to finish the game.
#
# Specials gate on COMPLETIONS rather than the old star total because stars became
# spendable — a gate reading a spendable balance would revoke a special the player had
# already qualified for as soon as they bought a car. Specials DO now award stars (via
# Save.complete_rally's ledger delta), which is only safe because they no longer gate on
# them. See todo/star-economy.md.
#
# `water_level` is authored on EVERY event, even though the region now supplies one
# (RegionLibrary.water_level_of): the resolution chain is event → region → GameConfig
# baseline, and pinning it per event keeps a corner's authored waterline from silently
# reshaping a shipped track, and lets the waterline vary WITHIN a corner by distance
# from the shore (nearer the coast = higher). Author it — never derive it from
# `map_pos`, which would couple terrain generation to pin geometry so nudging a pin for
# spacing would reshape a stage. Any event at a coastal waterline (-5) must pair it with
# `terrain_layer1_amplitude` >= 16.0 (see challenge_library.gd) or a high sea over low
# relief floods the track; an event authoring no amplitude runs the GameConfig baseline,
# which clears that bar comfortably.
const RALLIES: Array[Dictionary] = [
	# --- Rally Country: NW forest inland (region "home", waterline -12) ---------
	{
		"id": "shakedown", "name": "Shakedown", "region": "home", "difficulty": 1, "special": false,
		"map_pos": Vector2(0.290, 0.290),  # normalised pin position on the world map (hq.gd)
		"restriction": {"car_type": "roadster", "pw_min": 130.0, "pw_max": 185.0},  # band: the starter's home (Focus ~114 / MX-5 ~159 / XJS ~175 hp/t)
		"events": [
			{"seed": 1007, "turn_count": 20, "forestiness": 0.2, "surface_mix": 1, "straightness": 1, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 35.0, "terrain_layer2_amplitude": 3.0},
			{"seed": 1008, "turn_count": 20, "forestiness": 0.4, "surface_mix": 0, "straightness": 0.9, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 34.0, "terrain_layer2_amplitude": 3.0},
			{"seed": 1009, "turn_count": 20, "forestiness": 0.6, "surface_mix": 0.3, "straightness": 0.9, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 33.0, "terrain_layer2_amplitude": 3.0},
		],
	},
	{
		"id": "front_runners", "name": "Front Runners", "region": "home", "difficulty": 1, "special": false,
		"map_pos": Vector2(0.35, 0.52),
		# FWD intro rally: a band for the FWD starters (Twingo ~82, Focus ~114 hp/t) — the
		# FWD home (parallels Shakedown for the MX-5).
		"restriction": {"drive_mode": CarLibrary.FWD, "car_type": "hatch", "pw_min": 95.0, "pw_max": 140.0},
		"events": [
			{"seed": 1201, "turn_count": 20, "forestiness": 0.6, "surface_mix": 0.4, "straightness": 0.925, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 28.0, "weather": "rain"},
			{"seed": 1102, "turn_count": 20, "forestiness": 0.5, "surface_mix": 0.6, "straightness": 0.9, "cliffiness": 0.25, "water_level": -12.0, "terrain_layer1_amplitude": 27.0},
			{"seed": 1103, "turn_count": 20, "forestiness": 0.75, "surface_mix": 0.3, "straightness": 0.9, "cliffiness": 0.3, "water_level": -12.0, "terrain_layer1_amplitude": 26.0, "weather": "rain"},
		],
	},
	{
		# A hot-hatch cup: the class is the BODY, not a narrow power slice, so it keeps
		# meaning if a hatch is retuned or a new one joins the roster.
		"id": "hm_hatch_cup", "name": "Hatchback Cup", "region": "home", "difficulty": 2, "special": false,
		"map_pos": Vector2(0.360, 0.400),
		"restriction": {"car_type": "hatch", "doors_max": 3, "pw_min": 55.0, "pw_max": 100.0},
		"events": [
			{"seed": 31001, "turn_count": 22, "forestiness": 0.7, "surface_mix": 0.6, "straightness": 0.8, "cliffiness": 0.35, "water_level": -12.0, "terrain_layer1_amplitude": 30.0, "weather": "rain"},
			{"seed": 31002, "turn_count": 22, "forestiness": 0.55, "surface_mix": 0.9, "straightness": 0.775, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 29.0},
			{"seed": 31003, "turn_count": 23, "forestiness": 0.8, "surface_mix": 0.35, "straightness": 0.75, "cliffiness": 0.45, "water_level": -12.0, "terrain_layer1_amplitude": 28.0},
		],
	},
	{
		# Small-bore two-doors: four cylinders or fewer AND two doors — a class that
		# reads honestly ("light, simple, two seats") and survives a retune, unlike a
		# narrow power slice picking the same cars by accident.
		"id": "hm_timber_trophy", "name": "Timber Trophy", "region": "home", "difficulty": 2, "special": false,
		"reveal_after": 1,
		"map_pos": Vector2(0.420, 0.220),
		"restriction": {"cylinders_max": 4, "doors_max": 2, "pw_min": 90.0, "pw_max": 170.0},
		"events": [
			{"seed": 32001, "turn_count": 21, "forestiness": 0.85, "surface_mix": 0.1, "straightness": 0.75, "cliffiness": 0.45, "water_level": -13.0, "terrain_layer1_amplitude": 37.0},
			{"seed": 32002, "turn_count": 21, "forestiness": 0.9, "surface_mix": 0.0, "straightness": 0.725, "cliffiness": 0.55, "water_level": -13.0, "terrain_layer1_amplitude": 36.0, "weather": "fog"},
			{"seed": 32003, "turn_count": 22, "forestiness": 0.75, "surface_mix": 0.25, "straightness": 0.7, "cliffiness": 0.5, "water_level": -13.0, "terrain_layer1_amplitude": 35.0},
		],
	},
	{
		# A closed-roof GT class: coupes only, over a wide band so the grouping is the
		# body style rather than the exact power figure.
		"id": "hm_forest_gt", "name": "Forest GT", "region": "home", "difficulty": 3, "special": false,
		"reveal_after": 12,
		"map_pos": Vector2(0.182, 0.374),
		"restriction": {"car_type": "coupe", "pw_min": 120.0, "pw_max": 240.0},
		"events": [
			{"seed": 33001, "turn_count": 30, "forestiness": 0.65, "surface_mix": 0.7, "straightness": 0.65, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 31.0, "weather": "rain"},
			{"seed": 33002, "turn_count": 30, "forestiness": 0.5, "surface_mix": 0.9, "straightness": 0.625, "cliffiness": 0.65, "water_level": -12.0, "terrain_layer1_amplitude": 30.0, "weather": "rain"},
			{"seed": 33003, "turn_count": 31, "forestiness": 0.8, "surface_mix": 0.4, "straightness": 0.65, "cliffiness": 0.7, "water_level": -12.0, "terrain_layer1_amplitude": 29.0, "weather": "fog"},
		],
	},
	{
		"id": "grand_tour", "name": "Grand Tour", "region": "home", "difficulty": 4, "special": false,
		"reveal_after": 18,
		"map_pos": Vector2(0.220, 0.160),
		"restriction": {"pw_min": 260.0, "pw_max": 400.0},  # the top ordinary band: Viper ~264 / The Beast ~350
		"events": [
			{"seed": 5001, "turn_count": 40, "forestiness": 0.5, "surface_mix": 1.0, "straightness": 0.75, "cliffiness": 0.75, "water_level": -12.0, "terrain_layer1_amplitude": 40.0, "weather": "rain"},
			{"seed": 5004, "turn_count": 40, "forestiness": 0.3, "surface_mix": 0.4, "straightness": 0.575, "cliffiness": 0.85, "water_level": -12.0, "terrain_layer1_amplitude": 39.0},
			{"seed": 5003, "turn_count": 40, "forestiness": 0.7, "surface_mix": 0.0, "straightness": 0.55, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 38.0},
		],
	},
	{
		# --- 8-star special: unlocks the Big Turbo. The gentlest of the eight (a player is
		# only ~3 wins in), sited on `home`'s north edge — the corner they started in.
		"id": "sp_woodland_trial", "name": "The Woodland Trial", "region": "home", "difficulty": 2,
		"special": true, "requires_completions": 2,
		"map_pos": Vector2(0.318, 0.128),
		"restriction": {},  # open-class: a special must never gate on a part it unlocks
		"events": [
			{"seed": 81001, "turn_count": 28, "forestiness": 0.8, "surface_mix": 0.35, "cliffiness": 0.8, "water_level": -12.0, "terrain_layer1_amplitude": 34.0},
			{"seed": 81002, "turn_count": 30, "forestiness": 0.7, "surface_mix": 0.5, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 35.0, "weather": "fog"},
			{"seed": 81003, "turn_count": 28, "forestiness": 0.85, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -12.0, "terrain_layer1_amplitude": 36.0},
		],
	},
	{
		"id": "the_showdown", "name": "The Showdown", "region": "home", "difficulty": 4, "special": true, "requires_completions": 10,
		"map_pos": Vector2(0.130, 0.260),
		"restriction": {},  # open so the low-power starter can always finish the game
		"events": [
			{"seed": 9101, "turn_count": 46, "forestiness": 0.8, "surface_mix": 0.5, "cliffiness": 0.8, "water_level": -12.0, "terrain_layer1_amplitude": 36.0},
			{"seed": 9102, "turn_count": 46, "forestiness": 0.5, "surface_mix": 0.8, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 35.0},
			{"seed": 9003, "turn_count": 46, "forestiness": 0.65, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -12.0, "terrain_layer1_amplitude": 34.0},
		],
	},
	# --- The Lakes: SE green shore / peninsula (region "home_coast", waterline -5) ---
	# Placement is the only signal that a rally is coastal (the pin itself carries no
	# marking), so every pin stays on the GREEN shore/peninsula palette — but at a
	# DELIBERATELY VARIED distance from the waterline (an island and a headland right
	# on the water, others set back into the peninsula), so the group reads as a
	# coastal region rather than a row of pins tracing the coast. The per-event
	# water_level follows that distance (nearer the sea sits higher, toward -5; set
	# back sits lower) and is AUTHORED, never derived from map_pos. Every event pairs
	# its high waterline with terrain_layer1_amplitude >= 16 (challenge_library.gd) —
	# a high sea over low relief floods the track.
	{
		"id": "shitbox_cup", "name": "Sh*tbox Cup", "region": "home_coast", "difficulty": 1, "special": false,
		"map_pos": Vector2(0.623, 0.670),
		# The bottom band, below even Shakedown: a sub-100 hp/tonne class the true
		# shitboxes (Acty ~59, Twingo ~82) fit — a low floor keeps the Acty in-band.
		"restriction": {"pw_min": 50.0, "pw_max": 90.0},
		"events": [
			{"seed": 7031, "turn_count": 12, "forestiness": 0.3, "surface_mix": 0.0, "straightness": 0.5, "cliffiness": 0.5, "water_level": -4.0, "terrain_layer1_amplitude": 19.0, "terrain_layer2_amplitude": 3.0},
			{"seed": 7102, "turn_count": 14, "forestiness": 0.5, "surface_mix": 0.5, "straightness": 0.5, "cliffiness": 0.6, "water_level": -4.0, "terrain_layer1_amplitude": 18.0, "terrain_layer2_amplitude": 3.0},
			{"seed": 7233, "turn_count": 12, "forestiness": 0.4, "surface_mix": 0.0, "straightness": 0.5, "cliffiness": 0.7, "water_level": -4.0, "terrain_layer1_amplitude": 17.0, "terrain_layer2_amplitude": 3.0, "weather": "rain"},
		],
	},
	{
		# A national class: Japanese cars, over a deliberately wide band so it's the
		# country that picks the field rather than a power slice.
		"id": "hc_lakeside_kei", "name": "Lakeside Cup", "region": "home_coast", "difficulty": 1, "special": false, "reveal_after": 2,
		"map_pos": Vector2(0.702, 0.571),
		"restriction": {"country": "JP", "pw_min": 80.0, "pw_max": 160.0},
		"events": [
			{"seed": 34001, "turn_count": 16, "forestiness": 0.6, "surface_mix": 0.3, "straightness": 0.85, "cliffiness": 0.35, "water_level": -7.0, "terrain_layer1_amplitude": 23.0, "weather": "rain"},
			{"seed": 34002, "turn_count": 16, "forestiness": 0.7, "surface_mix": 0.1, "straightness": 0.825, "cliffiness": 0.4, "water_level": -7.0, "terrain_layer1_amplitude": 22.0, "weather": "rain"},
			{"seed": 34003, "turn_count": 17, "forestiness": 0.5, "surface_mix": 0.5, "straightness": 0.8, "cliffiness": 0.45, "water_level": -7.0, "terrain_layer1_amplitude": 21.0, "weather": "rain"},
		],
	},
	{
		"id": "coastal_sprint", "name": "Coastal Sprint", "region": "home_coast", "difficulty": 2, "special": false,
		"reveal_after": 5,
		"map_pos": Vector2(0.756, 0.685),
		"restriction": {"pw_min": 150.0, "pw_max": 230.0},  # band above Shakedown: MX-5/XJS + Charger/911
		"events": [
			{"seed": 2204, "turn_count": 24, "forestiness": 0.6, "surface_mix": 1.0, "straightness": 0.5, "cliffiness": 0.55, "water_level": -4.0, "terrain_layer1_amplitude": 18.0, "weather": "rain"},
			{"seed": 2105, "turn_count": 24, "forestiness": 0.6, "surface_mix": 0.7, "straightness": 0.6, "cliffiness": 0.65, "water_level": -4.0, "terrain_layer1_amplitude": 17.0, "weather": "rain"},
			{"seed": 2207, "turn_count": 24, "forestiness": 0.45, "surface_mix": 1.0, "straightness": 0.65, "cliffiness": 0.5, "water_level": -4.0, "terrain_layer1_amplitude": 16.0, "weather": "fog"},
		],
	},
	{
		"id": "rwd_masters", "name": "RWD Masters", "region": "home_coast", "difficulty": 3, "special": false,
		"reveal_after": 9,
		"map_pos": Vector2(0.791, 0.812),
		# p/w band (primary gate) + an RWD theme: a mid/high-power rear-driven field.
		"restriction": {"drive_mode": CarLibrary.RWD, "pw_min": 170.0, "pw_max": 270.0},  # XJS/Charger/911/Viper
		"events": [
			{"seed": 3001, "turn_count": 29, "forestiness": 0.5, "surface_mix": 0.5, "straightness": 0.75, "cliffiness": 0.4, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 3012, "turn_count": 29, "forestiness": 0.8, "surface_mix": 1.0, "straightness": 0.725, "cliffiness": 0.5, "water_level": -4.0, "terrain_layer1_amplitude": 16.0, "weather": "storm"},
			{"seed": 3004, "turn_count": 29, "forestiness": 0.35, "surface_mix": 0.0, "straightness": 0.75, "cliffiness": 0.6, "water_level": -4.0, "terrain_layer1_amplitude": 16.0, "weather": "rain"},
		],
	},
	{
		# Open-top cars only — a body class, wide on power.
		"id": "hc_headland_dash", "name": "Headland Dash", "region": "home_coast", "difficulty": 3, "special": false,
		"reveal_after": 10,
		"map_pos": Vector2(0.831, 0.593),
		"restriction": {"car_type": "roadster", "pw_min": 135.0, "pw_max": 265.0},
		"events": [
			{"seed": 35001, "turn_count": 28, "forestiness": 0.45, "surface_mix": 0.8, "straightness": 0.65, "cliffiness": 0.7, "water_level": -4.0, "terrain_layer1_amplitude": 22.0},
			{"seed": 35002, "turn_count": 28, "forestiness": 0.35, "surface_mix": 1.0, "straightness": 0.625, "cliffiness": 0.8, "water_level": -4.0, "terrain_layer1_amplitude": 21.0, "weather": "fog"},
			{"seed": 35003, "turn_count": 29, "forestiness": 0.6, "surface_mix": 0.5, "straightness": 0.6, "cliffiness": 0.75, "water_level": -4.0, "terrain_layer1_amplitude": 20.0},
		],
	},
	{
		# Twelve cylinders or more: the grand-touring exotica class, derived from the
		# fitted engine's layout, so an engine swap moves a car in or out of it.
		"id": "hc_v12_promenade", "name": "12 Cylinder Promenade", "region": "home_coast", "difficulty": 4, "special": false,
		"reveal_after": 15,
		"map_pos": Vector2(0.894, 0.691),
		"restriction": {"cylinders_min": 12, "pw_min": 170.0, "pw_max": 330.0},
		"events": [
			{"seed": 36001, "turn_count": 35, "forestiness": 0.5, "surface_mix": 1.0, "straightness": 0.6, "cliffiness": 0.75, "water_level": -7.0, "terrain_layer1_amplitude": 18.0, "weather": "storm"},
			{"seed": 36002, "turn_count": 35, "forestiness": 0.65, "surface_mix": 0.8, "straightness": 0.575, "cliffiness": 0.85, "water_level": -7.0, "terrain_layer1_amplitude": 17.0, "weather": "rain"},
			{"seed": 36003, "turn_count": 36, "forestiness": 0.4, "surface_mix": 0.6, "straightness": 0.575, "cliffiness": 0.8, "water_level": -7.0, "terrain_layer1_amplitude": 16.0, "weather": "rain"},
		],
	},
	{
		# --- 24-star special: unlocks the Supercharger. The northernmost `home_coast` pin —
		# it must NOT creep above ~0.52, since the NE corner is reserved for the snow region
		# (todo/one-map-four-corners.md). Coastal waterline, so amplitude stays >= 16.
		"id": "sp_lakeshore_trial", "name": "The Lakeshore Trial", "region": "home_coast", "difficulty": 3,
		"special": true, "requires_completions": 6,
		"map_pos": Vector2(0.772, 0.528),
		"restriction": {},  # open-class
		"events": [
			{"seed": 83001, "turn_count": 37, "forestiness": 0.7, "surface_mix": 0.5, "cliffiness": 0.85, "water_level": -7.0, "terrain_layer1_amplitude": 21.0, "weather": "rain"},
			{"seed": 83002, "turn_count": 39, "forestiness": 0.55, "surface_mix": 0.8, "cliffiness": 0.9, "water_level": -7.0, "terrain_layer1_amplitude": 20.0, "weather": "storm"},
			{"seed": 83003, "turn_count": 37, "forestiness": 0.8, "surface_mix": 0.4, "cliffiness": 1.0, "water_level": -7.0, "terrain_layer1_amplitude": 19.0},
		],
	},
	{
		"id": "hc_showdown", "name": "The Lakeland Crown", "region": "home_coast", "difficulty": 4, "special": true, "requires_completions": 12,
		"map_pos": Vector2(0.941, 0.606),
		"restriction": {},  # open-class finale
		"events": [
			{"seed": 39001, "turn_count": 48, "forestiness": 0.7, "surface_mix": 0.6, "cliffiness": 0.85, "water_level": -7.0, "terrain_layer1_amplitude": 21.0, "weather": "rain"},
			{"seed": 39002, "turn_count": 51, "forestiness": 0.55, "surface_mix": 0.9, "cliffiness": 0.9, "water_level": -7.0, "terrain_layer1_amplitude": 20.0, "weather": "rain"},
			{"seed": 39003, "turn_count": 48, "forestiness": 0.8, "surface_mix": 0.4, "cliffiness": 1.0, "water_level": -7.0, "terrain_layer1_amplitude": 19.0, "weather": "storm"},
		],
	},
	# --- Greece: SW arid inland (region "greece", waterline -12) -----------------
	# These stages' waterlines are pinned per-event at the -10 they have always
	# resolved to (the GameConfig baseline), so the region gaining its own -12 does
	# not silently reshape a shipped track.
	{
		# Small-capacity class: 2.0 L or less, resolved through the car's CURRENT
		# engine — an engine swap moves a car in or out of it.
		"id": "gr_dust_devils", "name": "Dust Devils", "region": "greece", "difficulty": 1, "special": false, "reveal_after": 6,
		"map_pos": Vector2(0.360, 0.690),
		"restriction": {"engine_max_l": 2.0, "pw_min": 100.0, "pw_max": 200.0},
		"events": [
			{"seed": 41001, "turn_count": 16, "forestiness": 0.5, "surface_mix": 0.2, "straightness": 0.85, "cliffiness": 0.35, "water_level": -10.0, "weather": "sandstorm", "terrain_layer1_amplitude": 18.0},
			{"seed": 41002, "turn_count": 16, "forestiness": 0.4, "surface_mix": 0.1, "straightness": 0.825, "cliffiness": 0.4, "water_level": -10.0, "terrain_layer1_amplitude": 17.0},
			{"seed": 41003, "turn_count": 17, "forestiness": 0.6, "surface_mix": 0.3, "straightness": 0.8, "cliffiness": 0.45, "water_level": -10.0, "weather": "rain", "terrain_layer1_amplitude": 16.0},
		],
	},
	{
		"id": "american_muscle", "name": "American Muscle", "region": "greece", "difficulty": 2, "special": false,
		"reveal_after": 7,
		"map_pos": Vector2(0.410, 0.760),
		# US-built performance, in a mid/high-power band — the home of the American V8/V10s
		# (Charger ~216, Viper ~264). Country-gated, not car_type-gated, so it fields more
		# than a single car.
		"restriction": {"country": "US", "pw_min": 150.0, "pw_max": 300.0},
		"events": [
			{"seed": 6001, "turn_count": 40, "forestiness": 0.3, "surface_mix": 0.8, "straightness": 0.85, "cliffiness": 0.3, "water_level": -12.0, "terrain_layer1_amplitude": 15.0, "weather": "sandstorm"},
			{"seed": 6102, "turn_count": 40, "forestiness": 0.5, "surface_mix": 0.5, "straightness": 0.8, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 14.0},
			{"seed": 6003, "turn_count": 40, "forestiness": 0.4, "surface_mix": 1.0, "straightness": 0.825, "cliffiness": 0.35, "water_level": -12.0, "terrain_layer1_amplitude": 13.0},
		],
	},
	{
		# Big-bore two-doors: eight cylinders or more AND two doors.
		"id": "gr_marble_quarry", "name": "Marble Quarry", "region": "greece", "difficulty": 2, "special": false,
		"reveal_after": 11,
		"map_pos": Vector2(0.100, 0.660),
		"restriction": {"cylinders_min": 8, "doors_max": 2, "pw_min": 200.0, "pw_max": 400.0},
		"events": [
			{"seed": 42001, "turn_count": 23, "forestiness": 0.45, "surface_mix": 0.15, "straightness": 0.725, "cliffiness": 0.6, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 19.0},
			{"seed": 42002, "turn_count": 23, "forestiness": 0.35, "surface_mix": 0.05, "straightness": 0.7, "cliffiness": 0.7, "water_level": -11.0, "weather": "rain", "terrain_layer1_amplitude": 18.0},
			{"seed": 42003, "turn_count": 24, "forestiness": 0.55, "surface_mix": 0.25, "straightness": 0.675, "cliffiness": 0.65, "water_level": -11.0, "weather": "rain", "terrain_layer1_amplitude": 17.0},
		],
	},
	{
		"id": "gr_mountain_pass", "name": "Mountain Pass", "region": "greece", "difficulty": 3, "special": false,
		"reveal_after": 13,
		"map_pos": Vector2(0.230, 0.630),
		"restriction": {"pw_min": 210.0, "pw_max": 320.0},
		"events": [
			{"seed": 22001, "turn_count": 20, "forestiness": 0.65, "surface_mix": 0.1, "straightness": 0.6, "cliffiness": 0.8, "water_level": -10.0, "weather": "sandstorm", "terrain_layer1_amplitude": 20.0},
			{"seed": 22102, "turn_count": 21, "forestiness": 0.75, "surface_mix": 0.05, "straightness": 0.575, "cliffiness": 0.9, "water_level": -10.0, "weather": "rain", "terrain_layer1_amplitude": 19.0},
			{"seed": 22203, "turn_count": 20, "forestiness": 0.7, "surface_mix": 0.0, "straightness": 0.6, "cliffiness": 0.85, "water_level": -10.0, "weather": "rain", "terrain_layer1_amplitude": 18.0},
		],
	},
	{
		"id": "gr_ancient_ruins", "name": "Ancient Ruins", "region": "greece", "difficulty": 3, "special": false,
		"reveal_after": 16,
		"map_pos": Vector2(0.290, 0.830),
		"restriction": {"pw_min": 260.0, "pw_max": 400.0},
		"events": [
			{"seed": 23201, "turn_count": 21, "forestiness": 0.6, "surface_mix": 0.2, "straightness": 0.65, "cliffiness": 0.7, "water_level": -10.0, "weather": "sandstorm", "terrain_layer1_amplitude": 12.0},
			{"seed": 23202, "turn_count": 23, "forestiness": 0.65, "surface_mix": 0.1, "straightness": 0.6, "cliffiness": 0.85, "water_level": -10.0, "terrain_layer1_amplitude": 11.0},
			{"seed": 23103, "turn_count": 21, "forestiness": 0.75, "surface_mix": 0.35, "straightness": 0.625, "cliffiness": 0.75, "water_level": -10.0, "terrain_layer1_amplitude": 10.0},
		],
	},
	{
		# Muscle bodies only — the class is the body style, wide open on power.
		"id": "gr_thermopylae", "name": "The Hot Gates", "region": "greece", "difficulty": 4, "special": false,
		"reveal_after": 19,
		"map_pos": Vector2(0.138, 0.501),
		"restriction": {"car_type": "muscle", "pw_min": 170.0, "pw_max": 330.0},
		"events": [
			{"seed": 43001, "turn_count": 32, "forestiness": 0.4, "surface_mix": 0.3, "straightness": 0.6, "cliffiness": 0.9, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 26.0},
			{"seed": 43002, "turn_count": 35, "forestiness": 0.3, "surface_mix": 0.1, "straightness": 0.575, "cliffiness": 0.95, "water_level": -11.0, "terrain_layer1_amplitude": 25.0},
			{"seed": 43003, "turn_count": 32, "forestiness": 0.5, "surface_mix": 0.2, "straightness": 0.575, "cliffiness": 1.0, "water_level": -11.0, "terrain_layer1_amplitude": 24.0},
		],
	},
	{
		# --- 16-star special: unlocks the Drivetrain Conversion. Far SW of `greece`, below
		# the Aegean Crown. Sandstorm is authored ONLY on greece events (test-enforced).
		"id": "sp_dust_trial", "name": "The Dust Trial", "region": "greece", "difficulty": 2,
		"special": true, "requires_completions": 4,
		"map_pos": Vector2(0.062, 0.884),
		"restriction": {},  # open-class
		"events": [
			{"seed": 82001, "turn_count": 32, "forestiness": 0.7, "surface_mix": 0.15, "cliffiness": 0.8, "water_level": -11.0, "terrain_layer1_amplitude": 24.0, "weather": "sandstorm"},
			{"seed": 82002, "turn_count": 35, "forestiness": 0.65, "surface_mix": 0.25, "cliffiness": 0.9, "water_level": -11.0, "terrain_layer1_amplitude": 25.0},
			{"seed": 82003, "turn_count": 32, "forestiness": 0.8, "surface_mix": 0.1, "cliffiness": 1.0, "water_level": -11.0, "terrain_layer1_amplitude": 26.0, "weather": "sandstorm"},
		],
	},
	{
		"id": "gr_showdown", "name": "The Aegean Crown", "region": "greece", "difficulty": 4, "special": true, "requires_completions": 14,
		"map_pos": Vector2(0.140, 0.790),
		"restriction": {},  # open-class finale
		"events": [
			{"seed": 29001, "turn_count": 51, "forestiness": 0.75, "surface_mix": 0.15, "cliffiness": 0.85, "water_level": -10.0, "weather": "sandstorm", "terrain_layer1_amplitude": 14.0},
			{"seed": 29102, "turn_count": 53, "forestiness": 0.65, "surface_mix": 0.25, "cliffiness": 0.95, "water_level": -10.0, "weather": "rain", "terrain_layer1_amplitude": 13.0},
			{"seed": 29103, "turn_count": 51, "forestiness": 0.85, "surface_mix": 0.1, "cliffiness": 1.0, "water_level": -10.0, "weather": "rain", "terrain_layer1_amplitude": 12.0},
		],
	},
	# --- The Coast: SE sandy shore (region "greece_coast", waterline -5) ---------
	# Sited down the western shore of the bay, on the sandy palette that matches the
	# arid look — placement is the only coastal signal, so these stay on the sandy
	# shore, but at VARIED distances from the water: two on outlying islands and one
	# on the beach, the rest set back to different depths so the corner reads as a
	# region rather than a line. The per-event water_level tracks that distance
	# (shore -5, set back -7) and is AUTHORED, never derived from map_pos.
	# Events author no terrain_layer1_amplitude, so they run the GameConfig baseline
	# (30 m), comfortably clear of the >= 16 pairing the -5 waterline needs.
	{
		"id": "gc_fishermens_run", "name": "Fishermen's Run", "region": "greece_coast", "difficulty": 1, "special": false, "reveal_after": 3,
		"map_pos": Vector2(0.552, 0.715),
		"restriction": {"pw_min": 60.0, "pw_max": 110.0},
		"events": [
			{"seed": 51001, "turn_count": 14, "forestiness": 0.5, "surface_mix": 0.4, "straightness": 0.875, "cliffiness": 0.3, "water_level": -4.0, "weather": "rain", "terrain_layer1_amplitude": 17.0},
			{"seed": 51002, "turn_count": 14, "forestiness": 0.4, "surface_mix": 0.6, "straightness": 0.85, "cliffiness": 0.35, "water_level": -4.0, "weather": "rain", "terrain_layer1_amplitude": 16.0},
			{"seed": 51003, "turn_count": 15, "forestiness": 0.6, "surface_mix": 0.25, "straightness": 0.85, "cliffiness": 0.4, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
		],
	},
	{
		# A two-door class: doors are a body property (a swap can't change them), so
		# this grouping is stable under retuning.
		"id": "gr_olive_coast", "name": "Olive Coast", "region": "greece_coast", "difficulty": 2, "special": false,
		"reveal_after": 4,
		"map_pos": Vector2(0.668, 0.755),
		"restriction": {"doors_max": 2, "pw_min": 120.0, "pw_max": 200.0},
		"events": [
			{"seed": 21001, "turn_count": 17, "forestiness": 0.75, "surface_mix": 0.25, "straightness": 0.7, "cliffiness": 0.5, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 21002, "turn_count": 18, "forestiness": 0.65, "surface_mix": 0.15, "straightness": 0.65, "cliffiness": 0.6, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 21003, "turn_count": 17, "forestiness": 0.85, "surface_mix": 0.3, "straightness": 0.675, "cliffiness": 0.55, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
		],
	},
	{
		# Small-engined two-doors — displacement resolved through the fitted engine.
		"id": "gc_island_hop", "name": "Island Hop", "region": "greece_coast", "difficulty": 2, "special": false,
		"reveal_after": 8,
		"map_pos": Vector2(0.432, 0.874),
		"restriction": {"engine_max_l": 3.0, "doors_max": 2, "pw_min": 120.0, "pw_max": 240.0},
		"events": [
			{"seed": 52001, "turn_count": 20, "forestiness": 0.6, "surface_mix": 0.5, "straightness": 0.75, "cliffiness": 0.5, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 52002, "turn_count": 20, "forestiness": 0.5, "surface_mix": 0.7, "straightness": 0.725, "cliffiness": 0.55, "water_level": -4.0, "weather": "rain", "terrain_layer1_amplitude": 16.0},
			{"seed": 52003, "turn_count": 21, "forestiness": 0.7, "surface_mix": 0.35, "straightness": 0.7, "cliffiness": 0.6, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
		],
	},
	{
		# id kept as "rising_sun" (saves key rally progress on the stable id) even though
		# the event was reworked from a JP-only rally into an open power-band one: with
		# the real-derived p/w figures no stock JP car came near this band, so the
		# country gate went and the band alone now hosts the stock heavy hitters
		# (Charger ~216, Viper ~264 hp/tonne — the Viper's only stock rally).
		"id": "rising_sun", "name": "Heavy Hitters", "region": "greece_coast", "difficulty": 3, "special": false,
		"reveal_after": 14,
		"map_pos": Vector2(0.615, 0.864),
		"restriction": {"pw_min": 210.0, "pw_max": 320.0},  # Charger/Viper
		"events": [
			{"seed": 4001, "turn_count": 33, "forestiness": 0.6, "surface_mix": 0.6, "straightness": 0.625, "cliffiness": 0.55, "water_level": -7.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 4004, "turn_count": 33, "forestiness": 0.4, "surface_mix": 0.0, "straightness": 0.6, "cliffiness": 0.7, "water_level": -7.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 3734559043, "turn_count": 33, "forestiness": 0.75, "surface_mix": 1.0, "straightness": 0.625, "cliffiness": 0.6, "water_level": -7.0, "terrain_layer1_amplitude": 16.0},
		],
	},
	{
		# Big-block class: 5.0 L or more, resolved through the fitted engine.
		"id": "gc_salt_flats", "name": "Salt Flats", "region": "greece_coast", "difficulty": 3, "special": false,
		"reveal_after": 17,
		"map_pos": Vector2(0.508, 0.984),
		"restriction": {"engine_min_l": 5.0, "pw_min": 185.0, "pw_max": 365.0},
		"events": [
			{"seed": 53001, "turn_count": 30, "forestiness": 0.3, "surface_mix": 0.8, "straightness": 0.775, "cliffiness": 0.4, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 53002, "turn_count": 30, "forestiness": 0.25, "surface_mix": 1.0, "straightness": 0.8, "cliffiness": 0.35, "water_level": -4.0, "weather": "storm", "terrain_layer1_amplitude": 16.0},
			{"seed": 53003, "turn_count": 31, "forestiness": 0.4, "surface_mix": 0.6, "straightness": 0.75, "cliffiness": 0.45, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
		],
	},
	{
		# A national class: British cars, wide on power.
		"id": "gc_island_gp", "name": "Island Grand Prix", "region": "greece_coast", "difficulty": 4, "special": false,
		"reveal_after": 20,
		"map_pos": Vector2(0.677, 0.938),
		"restriction": {"country": "GB", "pw_min": 170.0, "pw_max": 330.0},
		"events": [
			{"seed": 54001, "turn_count": 35, "forestiness": 0.35, "surface_mix": 1.0, "straightness": 0.65, "cliffiness": 0.7, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 54002, "turn_count": 35, "forestiness": 0.5, "surface_mix": 0.9, "straightness": 0.6, "cliffiness": 0.8, "water_level": -4.0, "weather": "storm", "terrain_layer1_amplitude": 16.0},
			{"seed": 54104, "turn_count": 36, "forestiness": 0.3, "surface_mix": 0.7, "straightness": 0.6, "cliffiness": 0.85, "water_level": -4.0, "terrain_layer1_amplitude": 16.0},
		],
	},
	{
		# --- 32-star special: unlocks ENGINE SWAPPING (the capability, not the token — see
		# RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY). South edge of `greece_coast`, east of the
		# Island GP. Coastal waterline, so amplitude stays >= 16.
		"id": "sp_archipelago_trial", "name": "The Archipelago Trial", "region": "greece_coast", "difficulty": 3,
		"special": true, "requires_completions": 8,
		"map_pos": Vector2(0.812, 0.962),
		"restriction": {},  # open-class
		"events": [
			{"seed": 84001, "turn_count": 41, "forestiness": 0.55, "surface_mix": 0.5, "cliffiness": 0.9, "water_level": -7.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 84002, "turn_count": 44, "forestiness": 0.45, "surface_mix": 0.7, "cliffiness": 0.95, "water_level": -7.0, "terrain_layer1_amplitude": 16.0, "weather": "storm"},
			{"seed": 84003, "turn_count": 41, "forestiness": 0.7, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -7.0, "terrain_layer1_amplitude": 16.0, "weather": "rain"},
		],
	},
	{
		"id": "gc_showdown", "name": "The Island Crown", "region": "greece_coast", "difficulty": 4, "special": true, "requires_completions": 16,
		"map_pos": Vector2(0.978, 0.788),
		"restriction": {},  # open-class finale
		"events": [
			{"seed": 59001, "turn_count": 53, "forestiness": 0.6, "surface_mix": 0.5, "cliffiness": 0.9, "water_level": -7.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 59002, "turn_count": 55, "forestiness": 0.45, "surface_mix": 0.7, "cliffiness": 0.95, "water_level": -7.0, "weather": "storm", "terrain_layer1_amplitude": 16.0},
			{"seed": 59003, "turn_count": 53, "forestiness": 0.7, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -7.0, "weather": "rain", "terrain_layer1_amplitude": 16.0},
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


# The weather condition this event runs in: WEATHER_DRY, WEATHER_RAIN or
# WEATHER_SANDSTORM. Authored, never random, so a stage's condition is the same
# every attempt and its leaderboard compares like with like (see features/weather.md).
# An omitted key OR any unrecognised string (a typo) resolves to WEATHER_DRY, so the
# table stays tolerant rather than crashing a stage.
static func event_weather(event: Dictionary) -> String:
	# Resolved through the weather table rather than a chain of string tests, so a
	# condition added to WeatherLibrary is authorable immediately (by_id already
	# falls back to the dry entry for an unknown string). See features/weather.md.
	return String(WeatherLibrary.by_id(String(event.get("weather", WEATHER_DRY))).get("id", WEATHER_DRY))


# The global leaderboards' board key for one stage: a track IDENTITY, not a stage
# number. Hashes the WHOLE authored per-event dict (sorted keys, so any authored
# field — not just seed/turn_count/width — retunes the board), never the real
# track-cache key (TrackGenParams.cache_key/TrackCache.key_for): those need a
# GameConfig, which would stop this being a pure static, and would fold in things
# (CACHE_VERSION, the corner library, generator constants, cfg.terrain_layers())
# that should reset EVERY board at once, not one designer's retune of one event.
# That global-reset half is handled by hand via TrackCache.BOARD_EPOCH instead —
# bump it whenever CACHE_VERSION bumps. Pure and deterministic: same rally +
# event_index → same key; changing any authored field of that event, or bumping
# BOARD_EPOCH, changes it. Result is Firestore document-id safe (no '/', far
# under the 1500-byte limit).
static func stage_key(rally: Dictionary, event_index: int) -> String:
	var events: Array = rally.get("events", [])
	var event: Dictionary = {}
	if event_index >= 0 and event_index < events.size():
		event = events[event_index]
	var keys := event.keys()
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s=%s" % [k, str(event[k])])
	var event_hash := "|".join(parts).sha256_text().substr(0, 12)
	var rally_id := String(rally.get("id", ""))
	return "%s__%d__%s__e%d" % [rally_id, event_index, event_hash, TrackCache.BOARD_EPOCH]


# --- Eligibility -------------------------------------------------------------

# Whether `car_meta` (a CarLibrary entry dict, resolved by the owned car's stable
# model_id — never array index) satisfies a rally's restriction. Open-class
# (empty restriction) always matches. For an OWNED car, callers pass the car's
# effective stats (UpgradeLibrary.effective_meta) so an installed engine kit or
# weight reduction can qualify / disqualify it via the pw_max ceiling; the
# raw CARS entry is only the right input for an unmodified roster car (rivals).
# `floor_meta` (optional) lets the caller judge the pw_MIN floor against a DIFFERENT meta
# than the ceiling / secondary fields — pass a car's MAX-potential meta
# (UpgradeLibrary.max_potential_meta) so a currently-detuned or ballasted owned car isn't
# ruled "too weak" when maxing it out would clear the floor (the player will always tune up
# to enter, just as an over-cap car detunes down to duck the ceiling). Defaults to car_meta
# — a plain point check for stock catalogue cars / rivals / synthetic tests, where current
# stats already ARE the car's potential.
static func ineligibility_reason(rally: Dictionary, car_meta: Dictionary, floor_meta: Dictionary = {}) -> String:
	var r: Dictionary = rally.get("restriction", {})
	if r.is_empty():
		return ""
	if r.has("drive_mode") and int(car_meta.get("drive_mode", -1)) != int(r["drive_mode"]):
		return "Wrong drivetrain for this class"
	if r.has("country") and String(car_meta.get("country", "")) != String(r["country"]):
		return "Wrong country of origin for this class"
	if r.has("car_type") and String(car_meta.get("car_type", "")) != String(r["car_type"]):
		return "Wrong car type for this class"
	if r.has("doors_min") and int(car_meta.get("doors", 0)) < int(r["doors_min"]):
		return "Too few doors for this class"
	if r.has("doors_max") and int(car_meta.get("doors", 0)) > int(r["doors_max"]):
		return "Too many doors for this class"
	# Engine-derived fields (displacement, cylinder count) are resolved through the car's
	# CURRENT engine, not off a flat key on the car dict — so an ENGINE SWAP moves them
	# with the engine and automatically changes which rallies the car can enter
	# (UpgradeLibrary.effective_meta re-points meta["engine"] at the fitted engine; see
	# features/engine-swap.md). If the restriction names an engine-derived field but the
	# engine id doesn't resolve (a synthetic/hand-built meta in a test or tool), the car is
	# REJECTED rather than waved through — silently accepting everything is exactly the
	# failure mode of the old dead `engine_displacement_l` lookup.
	var wants_engine := (r.has("engine_min_l") or r.has("engine_max_l")
		or r.has("cylinders_min") or r.has("cylinders_max"))
	if wants_engine:
		var eng := EngineLibrary.by_id(String(car_meta.get("engine", "")))
		if eng.is_empty():
			return "Unknown engine for this class"
		var disp := float(eng.get("displacement_l", 0.0))
		if r.has("engine_min_l") and disp < float(r["engine_min_l"]):
			return "Engine too small for this class"
		if r.has("engine_max_l") and disp > float(r["engine_max_l"]):
			return "Engine too large for this class"
		var cyl := EngineLibrary.cylinders(eng)
		if r.has("cylinders_min") and cyl < int(r["cylinders_min"]):
			return "Too few cylinders for this class"
		if r.has("cylinders_max") and cyl > int(r["cylinders_max"]):
			return "Too many cylinders for this class"
	# power_to_weight is kW/kg; the authored band edges are hp/tonne — convert before comparing.
	# Compare the ROUNDED hp/tonne figure (CarLibrary.power_to_weight_hp_tonne) — the exact
	# number the player sees on screen — not the raw float, so a car displaying e.g. "100 hp/t"
	# that's actually 99.6 isn't blocked by a 100 hp/t requirement it visually meets.
	# The requirement itself is also rounded before comparing — authored bands are already
	# whole numbers, so this is a no-op for real rally data, but it keeps BOTH sides of the
	# comparison on the same rounding rule (matters for synthetic thresholds in tests/tools).
	var pw := CarLibrary.power_to_weight_hp_tonne(car_meta)
	if r.has("pw_max") and pw > roundi(float(r["pw_max"])):
		return "Power-to-weight too high (%d hp/t, max %d)" % [pw, roundi(float(r["pw_max"]))]
	if r.has("pw_min"):
		# The floor is judged at the car's MAX potential when the caller supplies floor_meta.
		var floor_pw := pw if floor_meta.is_empty() else CarLibrary.power_to_weight_hp_tonne(floor_meta)
		if floor_pw < roundi(float(r["pw_min"])):
			return "Power-to-weight too low (%d hp/t, min %d)" % [floor_pw, roundi(float(r["pw_min"]))]
	return ""


static func is_eligible(rally: Dictionary, car_meta: Dictionary, floor_meta: Dictionary = {}) -> bool:
	return ineligibility_reason(rally, car_meta, floor_meta) == ""


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
	# Every car+engine pairing the rally admits (features/rally-roster.md), in-band
	# (the band floor is the power floor now).
	var combo_pool := _eligible_combos(rally)
	var count := rng.randi_range(FIELD_MIN, FIELD_MAX)
	var band := _pace_band(int(rally.get("difficulty", 1)))
	# Draw distinct names from the pool for this rally (stable across re-attempts via
	# the rally-seeded rng); names[i] is rival i's name, held across all 3 events.
	var names := _draw_rival_names(rng, count)
	# One distinct build per rival, same rng, so the grid is stable across re-attempts.
	var combos := _draw_distinct_combos(rng, combo_pool, count)
	var field: Array = []
	for i in count:
		var combo: Dictionary = combos[i]
		var car: Dictionary = combo["car"]
		var engine_id := String(combo["engine_id"])
		# The pairing's effective meta, computed once when the pool was built: it resolves
		# the fitted engine (so the rival's pace reflects the SWAP, not the stock engine)
		# and reflects stock forced induction — e.g. the 911's turbo. Without the
		# effective_meta pass, power_to_weight falls back to the engine's unboosted
		# peak_torque and turbo cars produce artificially slow rival times, out of step
		# with the player's boosted stats and the car's real physics. Note an engine
		# carries its whole TRANSMISSION (gear_ratios / final_drive / shift_time), so a
		# swap moves gearing as well as power.
		var car_meta: Dictionary = combo["meta"]
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
			"name": names[i],
			"car_id": String(car.get("id", "")),
			"engine_id": engine_id,
			# Layout-prefixed when the rival is running a non-stock engine ("V12 Rondel
			# Twist"), the plain car name otherwise — the same EngineSwap.display_name
			# convention the garage and the leaderboards use for the player's own car.
			"car_name": EngineSwap.display_name(car, {"swapped_engine": engine_id}),
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
		# Quantised so the value survives a JSON round-trip EXACTLY. This entry is baked
		# into data/opponent_cache.json and the cache's whole contract is that a cached
		# field equals a freshly generated one; a raw double here prints to ~14 significant
		# digits and parses back to a DIFFERENT double, so cache and live silently diverged
		# in the last bits (and test_opponent_cache's round-trip assertion failed as soon as
		# the rng happened to land on such a value). 1e-4 of track length is far below
		# anything visible in the roadside staging.
		field[pick]["wreck_progress"] = snappedf(rng.randf_range(0.15, 0.85), 0.0001)
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


# The keys that identify WHICH rival-and-build an entry refers to, as opposed to its
# result (times, placement, wreck staging). Every hop that hands a rival onwards — the
# start-line leaders, the wreck record, the standings rows — must carry all of them, or the
# receiving end silently re-resolves a DIFFERENT car: dropping `engine_id` is what made the
# start line stage rivals on their cars' stock engines (features/rally-roster.md).
#
# Declared here, beside generate_opponent_field which mints them, so adding a per-rival
# attribute is ONE edit plus this list rather than four hand-copied dict literals.
const RIVAL_IDENTITY_KEYS := ["name", "car_id", "engine_id", "car_name"]


# Copy just the identity keys out of a rival entry, defaulting each to "" so a caller can
# rely on every key being present. Use this instead of re-listing fields by hand.
static func identity_of(opp: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in RIVAL_IDENTITY_KEYS:
		out[key] = String(opp.get(key, ""))
	return out


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
			var out := identity_of(opp)
			if String(out["name"]) == "":
				out["name"] = "Rival"
			# Renamed on the way out: these are the WRECK's placement, not the rival's.
			out["progress"] = float(opp.get("wreck_progress", 0.5))
			out["side"] = float(opp.get("wreck_side", 1.0))
			return out
	return {}


# Draw `count` distinct names from RIVAL_NAMES using the (rally-seeded) rng, so the
# line-up's names are stable across re-attempts. A Fisher-Yates shuffle of a copy of
# the pool, then take the first `count`. The pool (20) always covers a field (≤15), but
# if a caller ever asks for more than the pool holds, overflow rivals fall back to a
# numbered "Rival N" so every rival still has a name.
static func _draw_rival_names(rng: RandomNumberGenerator, count: int) -> Array:
	var pool: Array = RIVAL_NAMES.duplicate()
	for i in range(pool.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = pool[i]
		pool[i] = pool[j]
		pool[j] = tmp
	var names: Array = []
	for i in count:
		names.append(String(pool[i]) if i < pool.size() else "Rival %d" % (i + 1))
	return names


# The CarLibrary entries a rally's restriction admits. Falls back to the whole roster if
# a restriction somehow admits no car (it never should; open-class admits everything).
#
# Judged on effective_meta, NOT the raw CarLibrary entry. A raw entry's power-to-weight
# falls back to the engine's UNBOOSTED peak_torque, so a stock-turbo car (the 911) used to
# be admitted on understated power and then raced on its real, boosted power — the pace
# model has always used effective_meta for exactly that reason (see
# generate_opponent_field). Both halves now agree, and this also matches the PLAYER's
# eligibility path, which goes through effective_meta too (hq_carpark.gd::_entry_plan).
static func _eligible_cars(rally: Dictionary) -> Array:
	var pool: Array = []
	for entry in CarLibrary.all():
		if is_eligible(rally, UpgradeLibrary.effective_meta({}, entry)):
			pool.append(entry)
	return pool if not pool.is_empty() else CarLibrary.all()


# Every (car, engine) pairing a rally's restriction admits, each carrying the effective
# meta that pairing produces — the pool the opponent field draws its rivals from.
#
# Opponents get ONE upgrade: the engine swap (features/rally-roster.md). That turns a
# 10-car roster into 10 x EngineLibrary.ENGINES candidates, which is what stops a field of
# nine rivals being nine near-identical stock cars.
#
# effective_meta re-points meta["engine"] at the fitted engine and runs the engine-swap
# mass model, so ineligibility_reason judges the swapped displacement, cylinder count and
# post-swap power-to-weight with no new authored data. A heavy engine in a light car
# correctly LOWERS the combo's power-to-weight rather than only raising its power.
#
# Fallback mirrors _eligible_cars: a restriction admitting nothing degrades to every car's
# STOCK combo (today's behaviour), never to the unfiltered cross product.
static func _eligible_combos(rally: Dictionary) -> Array:
	var pool: Array = []
	for entry in CarLibrary.all():
		var stock := String(entry.get("engine", ""))
		# The car's own stock power-to-weight is the reference every swap is judged
		# against, so "modest" means modest FOR THIS CAR rather than in absolute terms.
		var pw_stock := CarLibrary.power_to_weight_hp_tonne(UpgradeLibrary.effective_meta({}, entry))
		for eng in EngineLibrary.all():
			var eid := String(eng.get("id", ""))
			var owned: Dictionary = {} if eid == stock else {"swapped_engine": eid}
			var meta := UpgradeLibrary.effective_meta(owned, entry)
			if is_eligible(rally, meta):
				pool.append({
					"car": entry,
					"engine_id": eid,
					"meta": meta,
					"pw_delta": absf(CarLibrary.power_to_weight_hp_tonne(meta) - pw_stock),
				})
	if not pool.is_empty():
		return pool
	for entry in CarLibrary.all():
		pool.append({
			"car": entry,
			"engine_id": String(entry.get("engine", "")),
			"meta": UpgradeLibrary.effective_meta({}, entry),
			"pw_delta": 0.0,  # the stock combo IS the reference
		})
	return pool


# How much a combo is favoured in the draw, from how far its power-to-weight sits from
# the car's stock engine. Monotonically decreasing in `pw_delta`, always > 0 so no
# admitted combo is ever unreachable. Pure — see OPPONENT_SWAP_PW_SPREAD.
static func swap_weight(pw_delta: float) -> float:
	return exp(-absf(pw_delta) / maxf(OPPONENT_SWAP_PW_SPREAD, 0.001))


# `count` combos drawn WITHOUT replacement from `pool`, using the rally-seeded rng so the
# grid is stable across re-attempts and identical in the cache baker.
#
# The old draw picked each rival independently from the whole pool (with replacement), so
# nine rivals out of ten eligible cars were all distinct only ~0.4% of the time — and a
# restriction admitting three cars fielded nine rivals across three models. Drawing
# without replacement makes every rival a different car+engine build.
#
# The draw is WEIGHTED by swap_weight, so modest swaps are picked ahead of wild ones and a
# grid reads as a field of plausible builds rather than engine roulette. It is a bias, not
# a filter: a big swap is unlikely, never impossible, and the ordering stays fully seeded.
#
# When the pool holds fewer than `count`, CYCLE it rather than drawing random repeats: a
# three-combo rally fields 3+3+3 instead of a lopsided random multiset, so even the
# degenerate case is as varied as the pool allows.
static func _draw_distinct_combos(rng: RandomNumberGenerator, pool: Array, count: int) -> Array:
	var out: Array = []
	if pool.is_empty():
		return out
	# Weighted sampling without replacement: pick by weight, remove, repeat. The pool is
	# at most cars x engines (~110), so the linear scan per pick is irrelevant.
	var remaining: Array = pool.duplicate()
	var weights: Array = []
	for combo in remaining:
		weights.append(swap_weight(float(combo.get("pw_delta", 0.0))))
	var ordered: Array = []
	while not remaining.is_empty():
		var total := 0.0
		for w in weights:
			total += float(w)
		var pick := 0
		if total > 0.0:
			var r := rng.randf() * total
			var acc := 0.0
			for i in weights.size():
				acc += float(weights[i])
				if r <= acc:
					pick = i
					break
		else:
			pick = rng.randi_range(0, remaining.size() - 1)
		ordered.append(remaining[pick])
		remaining.remove_at(pick)
		weights.remove_at(pick)
	for i in count:
		out.append(ordered[i % ordered.size()])
	return out


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
static func build_standings(field: Array, player_combined_ms: int, player_dnf: bool, player_name := "You", player_car_name := "", player_car_id := "", player_engine_id := "") -> Array:
	var entries: Array = []
	for opp in field:
		var row := identity_of(opp)
		if String(row["name"]) == "":
			row["name"] = "Rival"
		row["combined_ms"] = int(opp.get("combined_ms", -1))
		row["dnf"] = bool(opp.get("dnf", false))
		row["is_player"] = false
		entries.append(row)
	entries.append({
		"name": player_name,
		"car_name": player_car_name,
		"car_id": player_car_id,
		# The player's fitted engine, so the podium stages their real build rather than the
		# catalogue stock car. "" when the caller doesn't know it (headless / tests).
		"engine_id": player_engine_id,
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


# --- Progress / stars / anti-soft-lock ------------------------------------

# Count of completed rallies in a save profile — the single progression metric
# (caps the car reward tier).
static func completed_count(profile: Dictionary) -> int:
	var rallies: Dictionary = profile.get("rallies", {})
	var n := 0
	for rally_id in rallies:
		if rallies[rally_id].get("completed", false):
			n += 1
	return n


# Count of completed NON-SPECIAL rallies across the WHOLE roster — the wave metric that
# drives reveal_after. A completed special doesn't count (it's gated separately, on stars).
#
# Deliberately GLOBAL, not per-region: the world map pins every region's rallies at once,
# so "complete a rally in one corner to reveal one in another corner" is the intended
# drip-feed and is only expressible with a global count. (A per-region count would also
# have silently tightened gating when the two old regions were split into four corners —
# the same authored reveal_after drawing from a smaller pool.)
static func _completed_count(profile: Dictionary) -> int:
	var rallies: Dictionary = profile.get("rallies", {})
	var n := 0
	for rally in all():
		if is_special(rally):
			continue
		if rallies.get(rally["id"], {}).get("completed", false):
			n += 1
	return n


# --- Star scoring ------------------------------------------------------------
# What a PLACEMENT is worth lives here; the running total does not. Stars are a persisted
# LEDGER on the profile now (Save.stars_earned / stars_spent — see todo/star-economy.md),
# because a derived total could not see Rally Challenge income and shrank whenever a rally
# was renamed or removed.
#
# Specials DO award stars, and no longer gate on them — the ladder counts completed ordinary
# rallies instead (see "Completion gating" below). Those two facts are linked: while specials
# were star-gated, paying them stars would have let a special bootstrap the next rung.

const MAX_STARS_PER_RALLY := 3


# Stars a finishing position is worth: 1st -> MAX, 2nd -> MAX-1, ... , off the podium -> 0.
# THE one definition — Save.complete_rally's ledger delta, the Rally Challenge award and the
# HQ's per-pin star row all go through it, so what a star is worth can never disagree
# between the surfaces that pay it and the ones that show it.
#
# NOTE stars are no longer summed from the roster: they are a PERSISTED LEDGER on the
# profile (`stars_earned` / `stars_spent`, see Save.stars_available and
# todo/star-economy.md). The old total_stars / max_total_stars are gone — a derived total
# could not see Rally Challenge income and shrank whenever a rally was renamed.
static func stars_for_placement(placed: int) -> int:
	if placed >= 1 and placed <= MAX_STARS_PER_RALLY:
		return MAX_STARS_PER_RALLY + 1 - placed
	return 0


static func is_special(rally: Dictionary) -> bool:
	return bool(rally.get("special", false))


# --- Completion gating -------------------------------------------------------
# Every rally, special or not, opens on the count of completed ORDINARY rallies. Specials
# used to gate on the star total instead, but stars became spendable — and a gate that reads
# a spendable balance would REVOKE a special the player had already qualified for the moment
# they bought a car. See todo/star-economy.md.
#
# Two field names for one mechanism, because they read differently to the player:
#   * `reveal_after`          — ordinary rallies. A drip-feed; never quoted as a requirement.
#   * `requires_completions`  — specials. Quoted on the locked pin as "N/M rallies".
# Read through completions_required rather than the raw fields so the surfaces that quote
# the requirement cannot drift from the gate that enforces it.
static func completions_required(rally: Dictionary) -> int:
	if is_special(rally):
		return int(rally.get("requires_completions", 0))
	return int(rally.get("reveal_after", 0))


# Completions still needed before `rally` opens — 0 once it is open. Drives the locked pin's
# "N/M rallies" readout.
static func completions_needed(rally: Dictionary, profile: Dictionary) -> int:
	return maxi(completions_required(rally) - _completed_count(profile), 0)


# The ONE special the player is currently working toward: the lowest rung of the ladder that
# has not opened yet ("" once every special is open). Roster order breaks a tie between two
# specials on the same rung.
#
# The map teases THIS special only (hq._make_pin). Every locked special used to hang a box
# quoting its own requirement, which put a wall of unreachable menus over the table on a
# fresh profile; the ladder is strictly ordered, so the next rung is the only requirement the
# player can actually work on. The trophies still stand at the further pins — locking hides
# availability, never the fact that something exists out there.
static func next_locked_special_id(profile: Dictionary) -> String:
	var best := ""
	var best_rung := 0
	for rally in all():
		if not is_special(rally) or rally_revealed(rally, profile):
			continue
		var rung := completions_required(rally)
		if best == "" or rung < best_rung:
			best = String(rally["id"])
			best_rung = rung
	return best


# The completion count the engine-swap CAPABILITY unlocks at — the requirement quoted by the
# garage swap row and the car-park confirm popup.
static func engine_swap_completion_requirement() -> int:
	return completions_required(by_id(ENGINE_SWAP_UNLOCK_RALLY))


# Whether the special that gates `item_id`-style capabilities has been won. Used for the
# engine-swap CAPABILITY gate: tokens drop and bank from the start, but cannot be spent
# until this opens. See features/engine-swap.md.
static func engine_swaps_unlocked(profile: Dictionary) -> bool:
	return bool((profile.get("rallies", {}) as Dictionary)
		.get(ENGINE_SWAP_UNLOCK_RALLY, {}).get("completed", false))


# The special whose win unlocks engine swapping. Authored here rather than on the rally so
# the capability has one named owner (upgrades are gated the other way round, by
# UpgradeLibrary.unlocked_by_rally).
# Engine swapping is the FIRST thing the star ladder opens (the lowest rung), because it is
# the mechanic that makes the rest of the garage interesting — a player who has it early can
# experiment with every car they win, where a turbo is just a number going up. The part
# unlocks shifted one rung later to make room; the turbo -> supercharger dependency order is
# unchanged (see UpgradeLibrary's unlocked_by_rally fields).
const ENGINE_SWAP_UNLOCK_RALLY := "sp_woodland_trial"


# Whether EVERY special on the roster is won — the win/credits beat, replacing the old
# the retired per-region gate. A roster with no specials reads as completed.
static func all_specials_completed(profile: Dictionary) -> bool:
	var rallies: Dictionary = profile.get("rallies", {})
	for rally in all():
		if is_special(rally) and not bool(rallies.get(rally["id"], {}).get("completed", false)):
			return false
	return true


# Whether a rally's pin is REVEALED (enterable) yet. An ordinary rally reveals once the
# player has completed `reveal_after` non-special rallies ANYWHERE on the roster (a GLOBAL
# wave count — keeps ~1-2 fresh rallies enterable at a time even when the garage is broad,
# and lets a win in one corner open a rally in another); a SPECIAL reveals on its star
# gate. The single reveal predicate shared by the map pins (hq.gd), the anti-soft-lock
# eligibility query, and the reward-draw walk. (Completion is a separate check the callers
# do — a revealed rally may still be incomplete or already done.)
static func rally_revealed(rally: Dictionary, profile: Dictionary) -> bool:
	var need := completions_required(rally)
	if need <= 0:
		return true
	return _completed_count(profile) >= need


# Anti-soft-lock query for the reward system: the still-incomplete rallies a
# given car can currently enter (revealed — reveal_after met and, for a special, its star
# gate open — and eligible in-band).
#
# "Can enter" INCLUDES ducking under a pw_max by detuning, exactly as the HQ's
# _entry_plan and test_every_shipped_rally_has_at_least_one_car_that_can_enter_it
# already define it — the player is always free to turn the wick down, so a rally
# they can reach that way is not a rally they are locked out of. Judging this query
# more strictly than the screen that actually gates entry made the reward system see
# phantom soft-locks and hand out rescue cars to players who were never stuck.
#
# This deliberately does NOT weaken the guarantee: qualifying_detune only ever
# rescues a car that is over the CEILING, and a genuine soft-lock is the opposite
# case — a car too weak for everything left, which no amount of detuning fixes.
static func incomplete_rallies_enterable_by(car_meta: Dictionary, profile: Dictionary, floor_meta: Dictionary = {}) -> Array:
	var rallies: Dictionary = profile.get("rallies", {})
	var out: Array = []
	for rally in all():
		if rallies.get(rally["id"], {}).get("completed", false):
			continue
		if not rally_revealed(rally, profile):
			continue
		if is_eligible(rally, car_meta, floor_meta) or qualifying_detune(rally, car_meta) > 0.0:
			out.append(rally)
	return out

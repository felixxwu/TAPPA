class_name RallyLibrary
extends RefCounted
# Docs: features/map-exploration.md, features/regions.md — update in the same change as this file.
# Tests: tests/headless/rally_fixtures.gd, tests/headless/test_menu_nav.gd, tests/headless/test_rally_library.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'RallyLibrary' tests/headless/` and read the assertions that pin what you are about to change (7 test files touch this script).
# The finite, curated list of rallies — authored CONTENT (like CarLibrary), not
# player state. A rally is a fixed set of 3 seeded TrackGenerator tracks plus a
# car restriction and a difficulty tier; player completion lives in the save
# profile (todo/save-persistence.md), keyed by the stable `id` here.
#
# This file is also the home of the pure functions the rest of the game needs:
#   * is_eligible(rally, car_meta)            — can this car enter?
#   * generate_opponent_field(rally, event_results, events) — the deterministic opponent field
#   * rally_revealed / lit_sources           — the map-exploration reveal gate
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
#
# THESE ARE FOR AUTHORING, NOT FOR BRANCHING. Do not write `weather == WEATHER_RAIN` to
# mean "wet" — WEATHER_STORM is wetter and that comparison silently skips it (it has been
# written wrong three times). Ask `WeatherLibrary.is_wet(id)` / `RallyLibrary.event_is_wet(event)`
# instead; anything else per-condition belongs as a KEY on the WeatherLibrary entry.
const WEATHER_DRY := "dry"
const WEATHER_RAIN := "rain"
# Dust storm — authored only onto region == "greece" events (see events below and
# features/weather.md); not enforced here (the funnel stays tolerant of any string),
# but asserted by test_rally_library.gd::test_sandstorm_only_authored_on_greece_events.
const WEATHER_SANDSTORM := "sandstorm"
# Fog — a VISIBILITY condition, and the only DIFFICULTY lever in the table (rivals
# have no eyes, so their times are unchanged). Authored onto FEW events, in the
# temperate regions ("home" / "home_coast" / "taiga"). See features/weather.md.
const WEATHER_FOG := "fog"
# Storm — heavy rain plus a crosswind and lightning. Authored onto the two COASTAL
# regions ("home_coast" / "greece_coast"), where an exposed crosswind reads, and onto
# the exposed northern "taiga" stages for the same reason.
const WEATHER_STORM := "storm"
# Snowfall — authored onto region == "snow" events. Unlike every other precipitation
# condition it carries NO grip multiplier: the snow region already owns grip for its
# whole corner, dry stages included, so weather must not stack a second lever on it.
# See features/snow-region.md.
const WEATHER_SNOW := "snow"
# Night — a DARKENED stage lit by a fake headlight cone in front of the player's car
# (todo/night-weather-and-headlights.md). Purely a LOOK: it carries no grip multiplier
# and no wind, so it contributes nothing to WeatherLibrary.physics_fields and never
# re-keys the opponent cache. Consequence of night being a weather VALUE rather than an
# orthogonal flag: night-and-raining is not expressible.
const WEATHER_NIGHT := "night"

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
# Retuning it reshapes every rally's grid immediately (fields are generated live).
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
# SANITY GUARD ONLY — deliberately far below anything the pace band can produce (the
# fastest rival draws 1.10 with at most -5% noise, i.e. 1.045), so it never binds in
# normal play. Its old value (1.10) and its old rationale ("rivals never beat their car's
# physics optimum") are both retired: LapTimeModel's optimum is a point-mass centreline
# REFERENCE, not a physical limit — a driver straightening a corner takes a larger radius
# than the model considers — so there was never anything to protect. What a floor still
# earns its place for is the degenerate case: an empty combo pool, a divide-by-zero or an
# absurd difficulty target must produce a SLOW field, not a negative or impossible one.
# The real upper bound on rival speed is GHOST_SOLVABLE_PACE below.
const PACE_MIN_FLOOR := 0.50
# The fastest a rival's time may be, as a multiple of that rival's own optimum, once the
# residual difficulty trim has been applied (_residual_pace_trim).
#
# This is not a physics limit either — it is what the WINDSCREEN GHOST can represent.
# RivalPace.solve bisects a skill factor over [rival_ghost_skill_min, rival_ghost_skill_max];
# with the shipped exponents the profile bottoms out at 0.976x the car's optimum at
# k_max = 1.15, and past that RivalPace warns, clamps, and the ghost visibly stops matching
# the standings. So a target quicker than this would be a time no ghost could drive.
# See features/rival-ghost.md and the adaptive-difficulty design doc.
const GHOST_SOLVABLE_PACE := 0.976

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

# Power-to-weight is no longer an entry gate (see ineligibility_reason), but it is
# still DISPLAYED in hp/tonne on the HUD and detail panel, and still exported for
# tools/fit_map_pins.py. CarLibrary.power_to_weight() returns kW/kg, so this converts.
# Uses CarLibrary.KW_KG_TO_HP_TONNE — the single source of truth, shared with hq.gd.
const KW_KG_TO_HP_TONNE := CarLibrary.KW_KG_TO_HP_TONNE


# Rival pace band as (pace_fast, pace_slow) — the pace of the fastest (skill 0) and
# slowest (skill 1) rival for a rally of the given hidden difficulty. The fast end
# is a constant 1.1x (just off the physics optimum); only the slow end tightens up-tier.
static func _pace_band(tier: int) -> Vector2:
	var t := clampi(tier, 1, 4) - 1
	return Vector2(PACE_FAST_BASE - t * PACE_FAST_STEP, PACE_SLOW_BASE - t * PACE_SLOW_STEP)


# Each entry: a RallyDef. `restriction` is an empty Dictionary for open-class
# (every car eligible); otherwise every present field must match the car's
# CarLibrary metadata.
#
# Entry requirements are PURELY CATEGORICAL — `car_type`, `country`,
# `doors_min`/`doors_max`, `cylinders_min`/`cylinders_max`,
# `engine_min_l`/`engine_max_l`, `drive_mode`. Their job is to make the player
# experience DIFFERENT CARS, never to police how fast they are: there is no
# performance band, no ceiling to upgrade into, and nothing to detune out of.
# How fast a car is instead shapes the OPPONENT FIELD, which is matched to the
# player's CarPerformance rating. See features/car-performance.md.
# two-door" or "British cars" picks a group that reads as a real class and survives
# retuning. When a rally wants to group by a property the catalogue does not record,
# ADD that property to the car/engine definitions — never approximate it with a proxy
# field that happens to correlate today. `difficulty` is a HIDDEN tier (never shown to the player) that
# drives the reward tier (clamped by progress) and sort order — the p/w band is the
# visible requirement. `events` is exactly 3 EventDefs (a special's are longer).
#
# `map_pos` IS the progression graph. A rally opens when the player has lit the map out to
# it: HQ starts lit, and every completed rally lights a circle around its own pin (see
# `rally_revealed` / `lit_sources`). So a pin's POSITION decides what it opens and what
# opens it, and moving a pin re-derives its neighbourhood for free. Optional
# `reveal_radius` (float, normalised map units) lets one rally open a wider frontier than
# the GameConfig default.
#
# DO NOT PICK A map_pos BY EYE, and do not paste one out of a comment — both go stale the
# moment a pin moves. `RallyLibrary.suggest_map_pos("<your region id>")` returns a legal,
# currently-free pin in that corner (>MIN_PIN_SEPARATION from every existing pin AND close
# enough to an authored one that the new rally is reachable); `map_pos_is_free(pos)` checks
# one you chose yourself. The last author to eyeball it landed 0.021 from an existing pin
# and turned test_map_pins_are_well_formed_and_never_stack red — that test now prints a
# suggested coordinate in its failure message, so you can paste the fix straight out of it.
#
# The retired fields are `reveal_after` and `requires_completions`,
# two global wave counters whose unlocks had no visible relationship to the rally just won.
#
# A SPECIAL event (`special: true`) is reached the same way as everything else — there is
# no ladder and no rung. It stays OPEN-CLASS (`restriction: {}`) so it can never gate on a
# part it unlocks, which keeps the low-power starter able to reach one.
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
# OPENING RALLIES RUN ONE EVENT. The three rallies that award the starter cars are each
# entered straight from the starter picker, before the player has seen the map, the garage
# or a menu (todo/opening-rally.md). A three-stage rally is a lot to ask of someone who has
# not yet driven the game once, and it delays the thing the run exists to deliver: arriving
# at the map with a rally already won. Every other rally keeps its full stage count — ask
# RallySession.stage_count(), never the EVENTS_PER_RALLY default.
# THE MAP'S GEOGRAPHY, and the rule these entries answer to.
#
# `textures/map_world.jpg` is one continent, and every rally is pinned somewhere real on
# it. Reading it as the player does:
#
#   NE            a high snow MASSIF — the Alps (region "snow"), six rallies
#   NW            boreal SPRUCE forest — the Taiga (region "taiga"), five rallies.
#                 Home's look exactly, save for the trees, which stand three times as tall
#                 (RegionLibrary "taiga"). Its rallies were home's until the corner was
#                 split off, so their `id`s still carry older prefixes — read `region`,
#                 never the id.
#   centre        dark pine FOREST, the bulk of the map — home proper
#   E             forest climbing into the mountains' foothills
#   centre-W      open plain threaded with RIVERS and lakes
#   SW / S        pale arid DESERT
#   SE            the SEA, with a bay, a shoreline and outlying islands
#
# A rally's NAME, its `region` (which picks the look and the waterline) and its per-event
# terrain must all agree with WHERE ITS PIN IS. That sounds obvious and it did not hold:
# pins are placed by a solver that optimises the progression graph (tools/fit_map_pins.py),
# so every re-fit slides them across the map while the names and terrain stay put. The
# result was a "Coastal Sprint" deep in the northern pines, an "Island Hop" in the
# forest, and "Salt Flats" in the north-west woods.
#
# So: WHEN A PIN MOVES, RE-READ ITS GEOGRAPHY. A coastal waterline (-4/-5) belongs only to
# a pin actually on the sea; a river waterline (-7) to one on the water in the central
# plain; everything inland runs the -11/-12/-13 baseline. Sandstorms are desert-only
# (test-enforced), storms are for exposed coasts, high `terrain_layer1_amplitude` is for
# the mountain foothills and low for the desert flats.
#
# The ALPS ARE THE EXCEPTION to that last rule, and deliberately so: they read as the
# highest ground on the map but are authored GENTLE (14-18, below even the desert flats
# rather than near the foothills' 34-44). Relief and grip multiply. A gradient costs a fixed
# `G*sin(theta)` out of a drive budget that the region's low grip has already shrunk, so
# the ~34-52 the corner first shipped with put its steepest pitches above what a 2WD car
# could climb at snow grip at all (FWD tops out near a 22% grade, RWD near 33%) — the car
# simply sat and spun. Altitude is carried by `cliffiness` (0.7-1.0, the highest on the
# map) instead, which drops the ground away BESIDE the road without touching the
# lengthwise profile the car has to climb. Keep it that way: if the Alps need more drama,
# reach for cliffiness, not amplitude.
#
# The table below is grouped by AUTHORING ORDER, not by geography — array order carries no
# meaning and a rally's own `region` + `map_pos` are the only truth about where it is.
#
# ADDING A REGION? It is inert until a rally here tags it, and the fix is a NEW row here,
# never re-pointing an existing rally's `region` (that restyles a stage authored for its
# old corner). A copy-pasteable minimal row lives in the note above RegionLibrary.REGIONS.
const RALLIES: Array[Dictionary] = [
	{
		"id": "shakedown", "name": "Win: Miot Roadster", "region": "home", "difficulty": 1, "special": false,
		"prize_car": "mx5",  # wave 3  — Shakedown has always been the MX-5's event
		"map_pos": Vector2(0.637, 0.485),  # normalised pin position on the world map (hq.gd)
		# NO class field. It was `car_type: roadster`, which made the MX-5 all but its own
		# prerequisite: the only other roadster in the catalogue is the Viper, itself a
		# late prize, so a Focus or Twingo player could not enter the rally standing next
		# to them and had to cross the whole map before the MX-5 became winnable. The
		# ceiling alone still puts the MX-5 at the top of the field.
		"restriction": {},  # OPEN: an opening rally must admit every starter car
		# ONE EVENT ONLY — an opening rally; see the RALLIES header.
		"events": [
			{"seed": 1007, "turn_count": 20, "forestiness": 0.70, "surface_mix": 1, "straightness": 1, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "terrain_layer2_amplitude": 3.0},
		],
	},
	{
		# Unlocks ENGINE SWAPPING (the capability, not the token — see
		# RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY). It is the lowest rung on the ladder, so it
		# sits on the difficulty-1 event right beside HQ: revealed from the very first map
		# view, so a player can go and win the garage's most interesting mechanic
		# immediately. It was The Foothills Trial, which now carries Snow Tires instead.
		"id": "front_runners", "name": "Upgrade: Engine Swap", "region": "home", "difficulty": 1,
		"special": true,
		"map_pos": Vector2(0.465, 0.615),
		# An ordinary early event beside HQ, CLASS-FREE (no body or class field, just a p/w
		# band) so it admits an RWD roadster and a FWD hatch alike.
		#
		# Being universally enterable was once a hard requirement: this was the one rally
		# every fresh profile had to be able to start, so a class field here stranded
		# whoever picked the other kind of car, and the floor was dropped to 60 to reach
		# the slowest starter. Neither holds now — each starter begins inside its OWN event
		# (RallyLibrary.opening_rally_id_for, todo/opening-rally.md) — so the floor comes
		# back up to a normal width. It stays class-free because a broad early event beside
		# HQ is good for the map whichever branch the player opened. Now that it carries the
		# engine-swap unlock it is fully OPEN — the same rule the other specials follow: a
		# capability every starter needs must never sit behind a class its car can't meet.
		"restriction": {},  # open-class: the capability specials gate on nothing
		"events": [
			{"seed": 1201, "turn_count": 20, "forestiness": 0.45, "surface_mix": 0.4, "straightness": 0.925, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 28.0},
			{"seed": 1102, "turn_count": 20, "forestiness": 0.35, "surface_mix": 0.6, "straightness": 0.9, "cliffiness": 0.25, "water_level": -12.0, "terrain_layer1_amplitude": 24.0, "weather": "storm"},
			{"seed": 1103, "turn_count": 20, "forestiness": 0.60, "surface_mix": 0.3, "straightness": 0.9, "cliffiness": 0.3, "water_level": -12.0, "terrain_layer1_amplitude": 20.0},
		],
	},
	{
		# A hot-hatch cup: the class is the BODY, not a narrow power slice, so it keeps
		# meaning if a hatch is retuned or a new one joins the roster.
		"id": "hm_hatch_cup", "name": "Win: Honcho Actus", "region": "home", "difficulty": 2, "special": false,
		"prize_car": "acty",  # wave 3  — a cheap kei runabout, the first car won
		"map_pos": Vector2(0.581, 0.590),
		"restriction": {"doors_max": 3},  # small two/three-door cars; it awards a kei, not a hatch
		"events": [
			{"seed": 31001, "turn_count": 22, "forestiness": 0.73, "surface_mix": 0.6, "straightness": 0.8, "cliffiness": 0.35, "water_level": -12.0, "terrain_layer1_amplitude": 38.0},
			{"seed": 31002, "turn_count": 22, "forestiness": 0.55, "surface_mix": 0.9, "straightness": 0.775, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "weather": "fog"},
			{"seed": 31003, "turn_count": 23, "forestiness": 0.85, "surface_mix": 0.35, "straightness": 0.75, "cliffiness": 0.45, "water_level": -12.0, "terrain_layer1_amplitude": 26.0},
		],
	},
	{
		# Small-bore four-cylinders: a class that reads honestly ("light, simple, modest
		# engine") and survives a retune, unlike a narrow power slice picking the same cars
		# by accident.
		#
		# It used to add `doors_max: 2`, which excluded the five-door hatch this very rally
		# AWARDS. That was invisible while a prize car was just something you won in
		# whatever you happened to own; it is fatal now the Focus's driver OPENS here
		# (todo/opening-rally.md), so the door clause is gone. A prize rally has to admit
		# its own prize — test_every_starter_car_opens_in_a_rally_that_admits_it.
		"id": "hm_timber_trophy", "name": "Win: Fjord Focal", "region": "home", "difficulty": 2, "special": false,
		"prize_car": "focus",  # wave 4
		"map_pos": Vector2(0.584, 0.387),
		"restriction": {"cylinders_max": 4},  # four cylinders or fewer, like the Focus it awards
		# ONE EVENT ONLY — an opening rally; see the RALLIES header.
		"events": [
			{"seed": 32001, "turn_count": 21, "forestiness": 0.70, "surface_mix": 0.1, "straightness": 0.75, "cliffiness": 0.45, "water_level": -12.0, "terrain_layer1_amplitude": 32.0},
		],
	},
	{
		# A small-hatch class, over a wide band so the grouping is the body style rather
		# than the exact power figure.
		#
		# It was `coupe` at 120-240, which excluded the little hatch this rally AWARDS —
		# the same defect the Timber Trophy carried, and the same reason it had to go: the
		# Twingo's driver OPENS here (todo/opening-rally.md), so the band has to reach down
		# to a stock city car rather than starting above one.
		"id": "hm_forest_gt", "name": "Win: Rondel Twist", "region": "home", "difficulty": 3, "special": false,
		"prize_car": "twingo",  # wave 3
		"map_pos": Vector2(0.344, 0.580),
		"restriction": {"doors_max": 3},  # small two/three-door cars, like the Twingo it awards
		# ONE EVENT ONLY — an opening rally; see the RALLIES header.
		"events": [
			{"seed": 33001, "turn_count": 30, "forestiness": 0.70, "surface_mix": 0.7, "straightness": 0.65, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 32.0},
		],
	},
	{
		"id": "grand_tour", "name": "Grand Tour", "region": "home", "difficulty": 4, "special": false,
		"map_pos": Vector2(0.613, 0.709),
		"restriction": {"cylinders_min": 8},  # a grand tourer needs a big engine
		"events": [
			{"seed": 5001, "turn_count": 40, "forestiness": 0.47, "surface_mix": 1.0, "straightness": 0.75, "cliffiness": 0.75, "water_level": -12.0, "terrain_layer1_amplitude": 28.0},
			{"seed": 5004, "turn_count": 40, "forestiness": 0.35, "surface_mix": 0.4, "straightness": 0.575, "cliffiness": 0.85, "water_level": -12.0, "terrain_layer1_amplitude": 24.0, "weather": "storm"},
			{"seed": 5003, "turn_count": 40, "forestiness": 0.60, "surface_mix": 0.0, "straightness": 0.55, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 20.0},
		],
	},
	{
		# The gentlest special (a player is only ~3 wins in), pinned east where the forest
		# climbs into the mountains' foothills — hence the relief, and the name.
		#
		# Awards SNOW TIRES (UpgradeLibrary snow_tires, gated the usual way round by
		# unlocked_by_rally). The grip part belongs at the gateway to the grip corner: this
		# pin is the only way into the Alps — sn_glacier_run sits inside ITS lit circle — so
		# the player arrives in the frozen region with the rubber for it, and the stronger
		# Race Tires still wait at the far end of that chain. It used to unlock engine
		# swapping, which has moved to the Proving Ground beside HQ.
		"id": "sp_woodland_trial", "name": "Upgrade: Snow Tires", "region": "home", "difficulty": 2,
		"special": true,
		"map_pos": Vector2(0.716, 0.409),
		"restriction": {},  # open-class: a special must never gate on a part it unlocks
		"events": [
			{"seed": 81001, "turn_count": 28, "forestiness": 0.62, "surface_mix": 0.35, "cliffiness": 0.8, "water_level": -13.0, "terrain_layer1_amplitude": 34.0, "weather": "rain"},
			{"seed": 81002, "turn_count": 30, "forestiness": 0.45, "surface_mix": 0.5, "cliffiness": 0.9, "water_level": -13.0, "terrain_layer1_amplitude": 39.0, "weather": "night"},
			{"seed": 81003, "turn_count": 28, "forestiness": 0.70, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -13.0, "terrain_layer1_amplitude": 44.0, "weather": "fog"},
		],
	},
	{
		"id": "the_showdown", "name": "Upgrade: NOS", "region": "home", "difficulty": 4, "special": true,
		"map_pos": Vector2(0.476, 0.316),
		"restriction": {},  # open so the low-power starter can always finish the game
		"events": [
			{"seed": 9101, "turn_count": 46, "forestiness": 0.85, "surface_mix": 0.5, "cliffiness": 0.8, "water_level": -12.0, "terrain_layer1_amplitude": 38.0},
			{"seed": 9102, "turn_count": 46, "forestiness": 0.55, "surface_mix": 0.8, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "weather": "storm"},
			{"seed": 9003, "turn_count": 46, "forestiness": 0.70, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -12.0, "terrain_layer1_amplitude": 26.0, "weather": "rain"},
		],
	},
	{
		"id": "shitbox_cup", "name": "Sh*tbox Cup", "region": "home", "difficulty": 1, "special": false,
		"map_pos": Vector2(0.527, 0.476),
		# The bottom band, below even Shakedown: a sub-100 hp/tonne class the true
		# shitboxes (Acty ~59, Twingo ~82) fit — a low floor keeps the Acty in-band.
		"restriction": {"engine_max_l": 1.5},  # the cheapest, smallest engines in the game
		"events": [
			{"seed": 7031, "turn_count": 12, "forestiness": 0.55, "surface_mix": 0.0, "straightness": 0.5, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 38.0, "terrain_layer2_amplitude": 3.0, "weather": "night"},
			{"seed": 7102, "turn_count": 14, "forestiness": 0.85, "surface_mix": 0.5, "straightness": 0.5, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "terrain_layer2_amplitude": 3.0, "weather": "fog"},
			{"seed": 7233, "turn_count": 12, "forestiness": 0.70, "surface_mix": 0.0, "straightness": 0.5, "cliffiness": 0.7, "water_level": -12.0, "terrain_layer1_amplitude": 26.0, "terrain_layer2_amplitude": 3.0},
		],
	},
	{
		# A national class: Japanese cars, over a deliberately wide band so it's the
		# country that picks the field rather than a power slice.
		"id": "hc_lakeside_kei", "name": "Lakeside Cup", "region": "home_coast", "difficulty": 1, "special": false,
		"map_pos": Vector2(0.361, 0.424),
		"restriction": {"country": "JP"},
		"events": [
			{"seed": 34001, "turn_count": 16, "forestiness": 0.57, "surface_mix": 0.3, "straightness": 0.85, "cliffiness": 0.35, "water_level": -7.0, "terrain_layer1_amplitude": 26.0},
			{"seed": 34002, "turn_count": 16, "forestiness": 0.70, "surface_mix": 0.1, "straightness": 0.825, "cliffiness": 0.4, "water_level": -7.0, "terrain_layer1_amplitude": 22.0, "weather": "storm"},
			{"seed": 34003, "turn_count": 17, "forestiness": 0.45, "surface_mix": 0.5, "straightness": 0.8, "cliffiness": 0.45, "water_level": -7.0, "terrain_layer1_amplitude": 18.0},
		],
	},
	{
		"id": "coastal_sprint", "name": "Pinewood Sprint", "region": "home", "difficulty": 2, "special": false,
		"map_pos": Vector2(0.599, 0.286),
		"restriction": {"doors_max": 2},  # two-door sprint: no family hatches
		"events": [
			{"seed": 2204, "turn_count": 24, "forestiness": 0.85, "surface_mix": 1.0, "straightness": 0.5, "cliffiness": 0.55, "water_level": -12.0, "terrain_layer1_amplitude": 38.0, "weather": "storm"},
			{"seed": 2105, "turn_count": 24, "forestiness": 0.85, "surface_mix": 0.7, "straightness": 0.6, "cliffiness": 0.65, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "weather": "rain"},
			{"seed": 2207, "turn_count": 24, "forestiness": 0.55, "surface_mix": 1.0, "straightness": 0.65, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 26.0, "weather": "night"},
		],
	},
	{
		"id": "rwd_masters", "name": "Win: The Beast", "region": "home_coast", "difficulty": 3, "special": false,
		"prize_car": "beast",  # wave 15 — RWD Masters awards the rear-drive monster
		"map_pos": Vector2(0.229, 0.488),
		# p/w band (primary gate) + an RWD theme: a mid/high-power rear-driven field.
		"restriction": {"drive_mode": CarLibrary.RWD},  # rear-drive only, like The Beast it awards
		"events": [
			{"seed": 3001, "turn_count": 29, "forestiness": 0.53, "surface_mix": 0.5, "straightness": 0.75, "cliffiness": 0.4, "water_level": -7.0, "terrain_layer1_amplitude": 22.0, "weather": "rain"},
			{"seed": 3012, "turn_count": 29, "forestiness": 0.70, "surface_mix": 1.0, "straightness": 0.725, "cliffiness": 0.5, "water_level": -7.0, "terrain_layer1_amplitude": 22.0, "weather": "night"},
			{"seed": 3004, "turn_count": 29, "forestiness": 0.45, "surface_mix": 0.0, "straightness": 0.75, "cliffiness": 0.6, "water_level": -7.0, "terrain_layer1_amplitude": 22.0, "weather": "fog"},
		],
	},
	{
		# Open-top cars only — a body class, wide on power.
		"id": "hc_headland_dash", "name": "Ridgeline Dash", "region": "home", "difficulty": 3, "special": false,
		"map_pos": Vector2(0.788, 0.491),
		"restriction": {"car_type": "roadster"},
		"events": [
			{"seed": 35001, "turn_count": 28, "forestiness": 0.55, "surface_mix": 0.8, "straightness": 0.65, "cliffiness": 0.7, "water_level": -13.0, "terrain_layer1_amplitude": 44.0, "weather": "fog"},
			{"seed": 35002, "turn_count": 28, "forestiness": 0.45, "surface_mix": 1.0, "straightness": 0.625, "cliffiness": 0.8, "water_level": -13.0, "terrain_layer1_amplitude": 39.0},
			{"seed": 35003, "turn_count": 29, "forestiness": 0.70, "surface_mix": 0.5, "straightness": 0.6, "cliffiness": 0.75, "water_level": -13.0, "terrain_layer1_amplitude": 34.0, "weather": "storm"},
		],
	},
	{
		# Twelve cylinders or more: the grand-touring exotica class, derived from the
		# fitted engine's layout, so an engine swap moves a car in or out of it.
		"id": "hc_v12_promenade", "name": "12 Cylinder Promenade", "region": "home_coast", "difficulty": 4, "special": false,
		"map_pos": Vector2(0.746, 0.714),
		"restriction": {"cylinders_min": 12},
		"events": [
			{"seed": 36001, "turn_count": 35, "forestiness": 0.33, "surface_mix": 1.0, "straightness": 0.6, "cliffiness": 0.75, "water_level": -4.0, "terrain_layer1_amplitude": 22.0},
			{"seed": 36002, "turn_count": 35, "forestiness": 0.45, "surface_mix": 0.8, "straightness": 0.575, "cliffiness": 0.85, "water_level": -4.0, "terrain_layer1_amplitude": 19.0, "weather": "storm"},
			{"seed": 36003, "turn_count": 36, "forestiness": 0.25, "surface_mix": 0.6, "straightness": 0.575, "cliffiness": 0.8, "water_level": -4.0, "terrain_layer1_amplitude": 16.0, "weather": "rain"},
		],
	},
	{
		# Unlocks the Supercharger. Pinned in the eastern forest, inland: despite the id it
		# is nowhere near a shore, so it runs the inland waterline. It must NOT creep north
		# of ~0.42, since the NE corner is reserved for the snow region
		# (todo/one-map-four-corners.md).
		"id": "sp_lakeshore_trial", "name": "Upgrade: Drivetrain Conversion", "region": "home", "difficulty": 3,
		"special": true,
		"map_pos": Vector2(0.781, 0.602),
		"restriction": {},  # open-class
		"events": [
			{"seed": 83001, "turn_count": 37, "forestiness": 0.60, "surface_mix": 0.5, "cliffiness": 0.85, "water_level": -12.0, "terrain_layer1_amplitude": 26.0, "weather": "rain"},
			{"seed": 83002, "turn_count": 39, "forestiness": 0.45, "surface_mix": 0.8, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 22.0, "weather": "night"},
			{"seed": 83003, "turn_count": 37, "forestiness": 0.70, "surface_mix": 0.4, "cliffiness": 1.0, "water_level": -12.0, "terrain_layer1_amplitude": 18.0, "weather": "fog"},
		],
	},	# The three region showdowns below were each demoted from special to ORDINARY when the
	# four-rung NOS ladder they used to gate collapsed to a single part
	# (features/nitrous.md), on the rule that a "special" awarding no part is only a special
	# by label — it would still claim the trophy marker, the map's locked teaser and a place
	# in the all-specials endgame while paying exactly what an ordinary rally pays.
	#
	# THEY WERE PROMOTED BACK, AND THEN DEMOTED AGAIN — and the round trip is the useful part of
	# this note, so it is recorded rather than tidied away.
	#
	# The promotion: the sequential gearbox and the race tyres each needed a part-unlock event,
	# and a long, hard, already OPEN-CLASS rally at a pin the solver had already placed was
	# exactly the shape a special takes. Promoting them beat authoring two new pins, which would
	# have re-fitted the whole map (tools/fit_map_pins.py) and moved every other rally's
	# neighbourhood with it.
	#
	# THE DEMOTION (now): both parts MOVED AWAY in the 4 -> 5 migration — Race Tires
	# gr_showdown -> sn_showdown, Sequential Gearbox hc_showdown -> sp_summit_trial, to give the
	# Alps corner something worth working toward (Save.MOVED_PART_UNLOCKS records the move and is
	# HISTORICAL: it must never be edited). The `special: true` flags were left behind, so for a
	# while the roster held two specials that awarded nothing at all — precisely what the rule at
	# the top of this note forbids. They pay stars like any other rally, so they are ordinary
	# rallies now: `special: false`, no trophy, no teaser, and no seat in the all-specials
	# endgame. Their `id` / `difficulty` / `restriction` / `events` are untouched — ids key saved
	# progress, and the other three decide the opponent field.
	#
	# WHAT A SPECIAL MUST AWARD, then, is one of exactly three things: a CAR, a PART, or a
	# CAPABILITY (engine swapping — see ENGINE_SWAP_UNLOCK_RALLY, which is gated here rather than
	# through UpgradeLibrary because a capability is not a part). That is no longer only a
	# convention in this comment: `test_rally_library.gd` asserts it against the shipped roster,
	# so the flag cannot be left behind a third time.
	#
	# `gc_showdown` stays ordinary for the same reason it always was: it gates nothing, so it
	# remains the pure star-payer the endgame finishes on.
	{
		# Gates no part any more: the Sequential Gearbox moved to sp_summit_trial in the
		# Alps, to give that corner something worth working toward. The `id` stays put
		# because it keys saved progress, so the name is what changed.
		#
		# NO LONGER A SPECIAL, and this comment used to argue the opposite ("it remains a
		# special — a long, open-class star-payer"). That reading is what the rule at the top
		# of the showdown block rejects: being long and open-class is not something a special
		# BUYS, and a special that awards nothing still claims the trophy pin, the map's locked
		# teaser and a seat in the all-specials endgame while paying exactly what this rally
		# pays. It is a hard difficulty-4 ordinary rally, which is what it now says it is.
		"id": "hc_showdown", "name": "The Northern Trial", "region": "home", "difficulty": 4,
		"special": false,
		"map_pos": Vector2(0.529, 0.205),
		"restriction": {},  # open-class: a special must never gate on a part it unlocks
		"events": [
			{"seed": 39001, "turn_count": 48, "forestiness": 0.73, "surface_mix": 0.6, "cliffiness": 0.85, "water_level": -12.0, "terrain_layer1_amplitude": 38.0},
			{"seed": 39002, "turn_count": 51, "forestiness": 0.55, "surface_mix": 0.9, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "weather": "storm"},
			{"seed": 39003, "turn_count": 48, "forestiness": 0.85, "surface_mix": 0.4, "cliffiness": 1.0, "water_level": -12.0, "terrain_layer1_amplitude": 26.0, "weather": "rain"},
		],
	},
	{
		# Small-capacity class: 2.0 L or less, resolved through the car's CURRENT
		# engine — an engine swap moves a car in or out of it.
		"id": "gr_dust_devils", "name": "Dust Devils", "region": "greece", "difficulty": 1, "special": false,
		"map_pos": Vector2(0.181, 0.792),
		"restriction": {"engine_max_l": 2.0},
		"events": [
			{"seed": 41001, "turn_count": 16, "forestiness": 0.28, "surface_mix": 0.2, "straightness": 0.85, "cliffiness": 0.35, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 19.0},
			{"seed": 41002, "turn_count": 16, "forestiness": 0.38, "surface_mix": 0.1, "straightness": 0.825, "cliffiness": 0.4, "water_level": -11.0, "terrain_layer1_amplitude": 15.5},
			{"seed": 41003, "turn_count": 17, "forestiness": 0.40, "surface_mix": 0.3, "straightness": 0.8, "cliffiness": 0.45, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 12.0},
		],
	},
	{
		"id": "american_muscle", "name": "Win: Swerve Surger R/T", "region": "taiga", "difficulty": 2, "special": false,
		"prize_car": "charger",  # wave 7  — the American Muscle event awards the Charger
		"map_pos": Vector2(0.380, 0.261),
		# US-built performance, in a mid/high-power band — the home of the American V8/V10s
		# (Charger ~216, Viper ~264). Country-gated, not car_type-gated, so it fields more
		# than a single car.
		"restriction": {"country": "US"},  # American iron, like the Charger it awards
		"events": [
			{"seed": 6001, "turn_count": 40, "forestiness": 0.55, "surface_mix": 0.8, "straightness": 0.85, "cliffiness": 0.3, "water_level": -12.0, "terrain_layer1_amplitude": 38.0, "weather": "night"},
			{"seed": 6102, "turn_count": 40, "forestiness": 0.85, "surface_mix": 0.5, "straightness": 0.8, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "weather": "fog"},
			{"seed": 6003, "turn_count": 40, "forestiness": 0.70, "surface_mix": 1.0, "straightness": 0.825, "cliffiness": 0.35, "water_level": -12.0, "terrain_layer1_amplitude": 26.0},
		],
	},
	{
		# Big-bore two-doors: eight cylinders or more AND two doors.
		"id": "gr_marble_quarry", "name": "Slate Quarry", "region": "taiga", "difficulty": 2, "special": false,
		"map_pos": Vector2(0.348, 0.157),
		"restriction": {"cylinders_min": 8, "doors_max": 2},
		"events": [
			{"seed": 42001, "turn_count": 23, "forestiness": 0.35, "surface_mix": 0.15, "straightness": 0.725, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 40.0, "weather": "storm"},
			{"seed": 42002, "turn_count": 23, "forestiness": 0.25, "surface_mix": 0.05, "straightness": 0.7, "cliffiness": 0.7, "water_level": -12.0, "weather": "rain", "terrain_layer1_amplitude": 35.0},
			{"seed": 42003, "turn_count": 24, "forestiness": 0.45, "surface_mix": 0.25, "straightness": 0.675, "cliffiness": 0.65, "water_level": -12.0, "weather": "night", "terrain_layer1_amplitude": 30.0},
		],
	},
	{
		"id": "gr_mountain_pass", "name": "Win: Panthera XJS", "region": "home_coast", "difficulty": 3, "special": false,
		"prize_car": "xjs",  # wave 6
		"map_pos": Vector2(0.185, 0.382),
		"restriction": {"country": "GB"},  # a British hill climb, and it awards a British car
		"events": [
			{"seed": 22001, "turn_count": 20, "forestiness": 0.45, "surface_mix": 0.1, "straightness": 0.6, "cliffiness": 0.8, "water_level": -7.0, "weather": "night", "terrain_layer1_amplitude": 26.0},
			{"seed": 22102, "turn_count": 21, "forestiness": 0.70, "surface_mix": 0.05, "straightness": 0.575, "cliffiness": 0.9, "water_level": -7.0, "weather": "fog", "terrain_layer1_amplitude": 22.0},
			{"seed": 22203, "turn_count": 20, "forestiness": 0.57, "surface_mix": 0.0, "straightness": 0.6, "cliffiness": 0.85, "water_level": -7.0, "terrain_layer1_amplitude": 18.0},
		],
	},
	{
		"id": "gr_ancient_ruins", "name": "Win: Porker 930 Turbo", "region": "greece", "difficulty": 3, "special": false,
		"prize_car": "porsche911",  # wave 9
		"map_pos": Vector2(0.266, 0.736),
		"restriction": {"cylinders_max": 6},  # small-capacity classics on a tight ruins stage
		"events": [
			{"seed": 23201, "turn_count": 21, "forestiness": 0.38, "surface_mix": 0.2, "straightness": 0.65, "cliffiness": 0.7, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 19.0},
			{"seed": 23202, "turn_count": 23, "forestiness": 0.23, "surface_mix": 0.1, "straightness": 0.6, "cliffiness": 0.85, "water_level": -11.0, "terrain_layer1_amplitude": 15.5},
			{"seed": 23103, "turn_count": 21, "forestiness": 0.40, "surface_mix": 0.35, "straightness": 0.625, "cliffiness": 0.75, "water_level": -11.0, "terrain_layer1_amplitude": 12.0, "weather": "sandstorm"},
		],
	},
	{
		# Muscle bodies only — the class is the body style, wide open on power.
		"id": "gr_thermopylae", "name": "The Hot Gates", "region": "greece", "difficulty": 4, "special": false,
		"map_pos": Vector2(0.072, 0.676),
		"restriction": {"car_type": "muscle"},
		"events": [
			{"seed": 43001, "turn_count": 32, "forestiness": 0.28, "surface_mix": 0.3, "straightness": 0.6, "cliffiness": 0.9, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 19.0},
			{"seed": 43002, "turn_count": 35, "forestiness": 0.38, "surface_mix": 0.1, "straightness": 0.575, "cliffiness": 0.95, "water_level": -11.0, "terrain_layer1_amplitude": 15.5, "weather": "rain"},
			{"seed": 43003, "turn_count": 32, "forestiness": 0.40, "surface_mix": 0.2, "straightness": 0.575, "cliffiness": 1.0, "water_level": -11.0, "terrain_layer1_amplitude": 12.0, "weather": "sandstorm"},
		],
	},
	{
		# Unlocks the Big Turbo. Pinned in the northern forest despite the `dust` in its id —
		# so no sandstorm here; those are authored ONLY on greece events (test-enforced).
		"id": "sp_dust_trial", "name": "Upgrade: Big Turbo", "region": "taiga", "difficulty": 2,
		"special": true,
		"map_pos": Vector2(0.274, 0.297),
		"restriction": {},  # open-class
		"events": [
			{"seed": 82001, "turn_count": 32, "forestiness": 0.65, "surface_mix": 0.15, "cliffiness": 0.8, "water_level": -12.0, "terrain_layer1_amplitude": 26.0, "weather": "fog"},
			{"seed": 82002, "turn_count": 35, "forestiness": 0.55, "surface_mix": 0.25, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 32.0},
			{"seed": 82003, "turn_count": 32, "forestiness": 0.85, "surface_mix": 0.1, "cliffiness": 1.0, "water_level": -12.0, "terrain_layer1_amplitude": 38.0, "weather": "storm"},
		],
	},
	{
		# Gates no part any more: the Race Tires moved to sn_showdown in the Alps, the
		# grip part to the grip corner. Same as hc_showdown above — the `id` keys saved
		# progress and stays; only the name changed — and demoted to ORDINARY for the same
		# reason: a special has to award a car, a part or a capability, and this awards none
		# of the three.
		"id": "gr_showdown", "name": "The Greek Showdown", "region": "greece", "difficulty": 4,
		"special": false,
		"map_pos": Vector2(0.455, 0.854),
		"restriction": {},  # open-class: a special must never gate on a part it unlocks
		"events": [
			{"seed": 29001, "turn_count": 51, "forestiness": 0.28, "surface_mix": 0.15, "cliffiness": 0.85, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 19.0},
			{"seed": 29102, "turn_count": 53, "forestiness": 0.38, "surface_mix": 0.25, "cliffiness": 0.95, "water_level": -11.0, "terrain_layer1_amplitude": 15.5},
			{"seed": 29103, "turn_count": 51, "forestiness": 0.40, "surface_mix": 0.1, "cliffiness": 1.0, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 12.0},
		],
	},
	{
		"id": "gc_fishermens_run", "name": "Dry Riverbed Run", "region": "greece", "difficulty": 1, "special": false,
		"map_pos": Vector2(0.203, 0.649),
		"restriction": {"engine_max_l": 2.0},  # a gentle riverbed run for small-engined cars
		"events": [
			{"seed": 51001, "turn_count": 14, "forestiness": 0.28, "surface_mix": 0.4, "straightness": 0.875, "cliffiness": 0.3, "water_level": -11.0, "weather": "sandstorm", "terrain_layer1_amplitude": 19.0},
			{"seed": 51002, "turn_count": 14, "forestiness": 0.38, "surface_mix": 0.6, "straightness": 0.85, "cliffiness": 0.35, "water_level": -11.0, "terrain_layer1_amplitude": 12.0, "weather": "rain"},
			{"seed": 51003, "turn_count": 15, "forestiness": 0.40, "surface_mix": 0.25, "straightness": 0.85, "cliffiness": 0.4, "water_level": -11.0, "terrain_layer1_amplitude": 12.0, "weather": "sandstorm"},
		],
	},
	{
		# A two-door class: doors are a body property (a swap can't change them), so
		# this grouping is stable under retuning.
		"id": "gr_olive_coast", "name": "Long Meadow", "region": "home", "difficulty": 2, "special": false,
		"map_pos": Vector2(0.681, 0.576),
		"restriction": {"doors_max": 2},
		"events": [
			{"seed": 21001, "turn_count": 17, "forestiness": 0.47, "surface_mix": 0.25, "straightness": 0.7, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 24.0, "weather": "rain"},
			{"seed": 21002, "turn_count": 18, "forestiness": 0.35, "surface_mix": 0.15, "straightness": 0.65, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 24.0, "weather": "night"},
			{"seed": 21003, "turn_count": 17, "forestiness": 0.60, "surface_mix": 0.3, "straightness": 0.675, "cliffiness": 0.55, "water_level": -12.0, "terrain_layer1_amplitude": 24.0, "weather": "fog"},
		],
	},
	{
		# Small-engined two-doors — displacement resolved through the fitted engine.
		"id": "gc_island_hop", "name": "Timberline Loop", "region": "taiga", "difficulty": 2, "special": false,
		"map_pos": Vector2(0.238, 0.190),
		"restriction": {"engine_max_l": 3.0, "doors_max": 2},
		"events": [
			{"seed": 52001, "turn_count": 20, "forestiness": 0.70, "surface_mix": 0.5, "straightness": 0.75, "cliffiness": 0.5, "water_level": -12.0, "terrain_layer1_amplitude": 32.0},
			{"seed": 52002, "turn_count": 20, "forestiness": 0.55, "surface_mix": 0.7, "straightness": 0.725, "cliffiness": 0.55, "water_level": -12.0, "weather": "storm", "terrain_layer1_amplitude": 32.0},
			{"seed": 52003, "turn_count": 21, "forestiness": 0.85, "surface_mix": 0.35, "straightness": 0.7, "cliffiness": 0.6, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "weather": "rain"},
		],
	},
	{
		# id kept as "rising_sun" (saves key rally progress on the stable id) even though
		# the event was reworked from a JP-only rally into an open power-band one: with
		# the real-derived p/w figures no stock JP car came near this band, so the
		# country gate went and the band alone now hosts the stock heavy hitters
		# (Charger ~216, Viper ~264 hp/tonne — the Viper's only stock rally).
		"id": "rising_sun", "name": "Heavy Hitters", "region": "greece", "difficulty": 3, "special": false,
		"map_pos": Vector2(0.508, 0.724),
		"restriction": {"engine_min_l": 4.0},  # "Heavy Hitters": big-displacement only
		"events": [
			{"seed": 4001, "turn_count": 33, "forestiness": 0.29, "surface_mix": 0.6, "straightness": 0.625, "cliffiness": 0.55, "water_level": -11.0, "terrain_layer1_amplitude": 15.5, "weather": "sandstorm"},
			{"seed": 4004, "turn_count": 33, "forestiness": 0.38, "surface_mix": 0.0, "straightness": 0.6, "cliffiness": 0.7, "water_level": -11.0, "terrain_layer1_amplitude": 15.5, "weather": "fog"},
			{"seed": 3734559043, "turn_count": 33, "forestiness": 0.40, "surface_mix": 1.0, "straightness": 0.625, "cliffiness": 0.6, "water_level": -11.0, "terrain_layer1_amplitude": 15.5},
		],
	},
	{
		# Big-block class: 5.0 L or more, resolved through the fitted engine.
		"id": "gc_salt_flats", "name": "Fernway Dash", "region": "taiga", "difficulty": 3, "special": false,
		"map_pos": Vector2(0.132, 0.289),
		"restriction": {"engine_min_l": 5.0},
		"events": [
			{"seed": 53001, "turn_count": 30, "forestiness": 0.65, "surface_mix": 0.8, "straightness": 0.775, "cliffiness": 0.4, "water_level": -12.0, "terrain_layer1_amplitude": 32.0, "weather": "night"},
			{"seed": 53002, "turn_count": 30, "forestiness": 0.55, "surface_mix": 1.0, "straightness": 0.8, "cliffiness": 0.35, "water_level": -12.0, "weather": "fog", "terrain_layer1_amplitude": 32.0},
			{"seed": 53003, "turn_count": 31, "forestiness": 0.85, "surface_mix": 0.6, "straightness": 0.75, "cliffiness": 0.45, "water_level": -12.0, "terrain_layer1_amplitude": 32.0},
		],
	},
	{
		# A national class: British cars, wide on power.
		"id": "gc_island_gp", "name": "Win: Swerve Serpent RT/10", "region": "greece_coast", "difficulty": 4, "special": false,
		"prize_car": "viper",  # wave 13
		"map_pos": Vector2(0.612, 0.840),
		# NO class field. It was `country: GB`, which excluded the US Viper this rally
		# AWARDS; making it roadster-only fixed that but made the Viper its own
		# prerequisite (the only other roadster is the MX-5, itself a prize), stranding
		# every player who did not start in one. Open class, ceilinged just over the Viper,
		# is what leaves it reachable — see tools/sim_career.gd.
		"restriction": {"cylinders_min": 10},  # a ten-cylinder-plus GP, and it awards a V10
		"events": [
			{"seed": 54001, "turn_count": 35, "forestiness": 0.30, "surface_mix": 1.0, "straightness": 0.65, "cliffiness": 0.7, "water_level": -4.0, "terrain_layer1_amplitude": 19.0, "weather": "sandstorm"},
			{"seed": 54002, "turn_count": 35, "forestiness": 0.45, "surface_mix": 0.9, "straightness": 0.6, "cliffiness": 0.8, "water_level": -4.0, "weather": "night", "terrain_layer1_amplitude": 19.0},
			{"seed": 54104, "turn_count": 36, "forestiness": 0.25, "surface_mix": 0.7, "straightness": 0.6, "cliffiness": 0.85, "water_level": -4.0, "terrain_layer1_amplitude": 19.0},
		],
	},
	{
		# Unlocks the SUPERCHARGER (UpgradeLibrary.unlocked_by_rally). Pinned on the arid
		# fringe in the west, inland: despite the id there is no archipelago here, so no
		# coastal waterline.
		"id": "sp_archipelago_trial", "name": "Upgrade: Supercharger", "region": "greece", "difficulty": 3,
		"special": true,
		"map_pos": Vector2(0.122, 0.580),
		"restriction": {},  # open-class
		"events": [
			{"seed": 84001, "turn_count": 41, "forestiness": 0.38, "surface_mix": 0.5, "cliffiness": 0.9, "water_level": -11.0, "terrain_layer1_amplitude": 20.0, "weather": "storm"},
			{"seed": 84002, "turn_count": 44, "forestiness": 0.30, "surface_mix": 0.7, "cliffiness": 0.95, "water_level": -11.0, "terrain_layer1_amplitude": 20.0, "weather": "sandstorm"},
			{"seed": 84003, "turn_count": 41, "forestiness": 0.50, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -11.0, "terrain_layer1_amplitude": 20.0, "weather": "rain"},
		],
	},
	{
		"id": "gc_showdown", "name": "The Desert Showdown", "region": "greece", "difficulty": 4, "special": false,
		"map_pos": Vector2(0.299, 0.877),
		"restriction": {},  # open-class: a long, hard star-payer with no part to gate against
		"events": [
			{"seed": 59001, "turn_count": 53, "forestiness": 0.30, "surface_mix": 0.5, "cliffiness": 0.9, "water_level": -11.0, "terrain_layer1_amplitude": 15.5, "weather": "night"},
			{"seed": 59002, "turn_count": 55, "forestiness": 0.38, "surface_mix": 0.7, "cliffiness": 0.95, "water_level": -11.0, "weather": "fog", "terrain_layer1_amplitude": 15.5},
			{"seed": 59003, "turn_count": 53, "forestiness": 0.40, "surface_mix": 0.3, "cliffiness": 1.0, "water_level": -11.0, "terrain_layer1_amplitude": 15.5},
		],
	},
	# --- THE ALPS (region "snow"), the map's NE massif -------------------------
	#
	# The corner reserved from the start and filled in later (features/snow-region.md).
	# Every stage here is frozen whether or not it is snowing: the REGION drops all
	# three surface grips, so weather is free to vary for flavour without carrying the
	# handling. Roughly half the events are authored "snow" and half dry, and snowfall
	# is authored ONLY here — the same placement convention that keeps sandstorms in
	# the desert.
	#
	# Terrain reads the pixels: this is a high massif, so amplitudes run 34-52 (the
	# highest on the map, above even the eastern foothills' 34-44), cliffiness is high
	# throughout, and forestiness falls as the pins climb — conifers thin out with
	# altitude, and the deepest two pins are near bare rock and snow.
	#
	# The pins form a CHAIN into the corner rather than a cluster: sn_glacier_run sits
	# inside The Foothills Trial's lit circle and is the only way in, and the two
	# specials are the deepest pins, so their parts genuinely have to be worked toward.
	{
		"id": "sn_glacier_run", "name": "Glacier Run", "region": "snow", "difficulty": 1,
		"special": false,
		"map_pos": Vector2(0.752, 0.302),
		# The gateway pin: reachable from The Foothills Trial (0.716, 0.409), and the ONLY
		# snow rally that is — every other Alps pin is revealed from inside the corner, so
		# this one entrance gates the whole region. Worth knowing before retuning its
		# restriction: a class nobody owns delays the whole corner rather than one rally.
		#
		# The hatch class is safe on that count because both eligible cars (Fjord Focal,
		# Rondel Twist) are prizes from difficulty-2 home rallies, long since won by the
		# time the map lights this far. Verified with sim_career: adding the Alps leaves
		# the strand rate unchanged from the pre-Alps roster.
		"restriction": {"car_type": "hatch"},
		"events": [
			{"seed": 85001, "turn_count": 24, "forestiness": 0.52, "surface_mix": 0.3, "straightness": 0.85, "cliffiness": 0.7, "water_level": -12.0, "terrain_layer1_amplitude": 14.0, "weather": "snow"},
			{"seed": 85002, "turn_count": 26, "forestiness": 0.50, "surface_mix": 0.45, "straightness": 0.8, "cliffiness": 0.75, "water_level": -12.0, "terrain_layer1_amplitude": 14.0},
			{"seed": 85003, "turn_count": 24, "forestiness": 0.60, "surface_mix": 0.25, "straightness": 0.85, "cliffiness": 0.7, "water_level": -12.0, "terrain_layer1_amplitude": 14.0, "weather": "snow"},
		],
	},
	{
		"id": "sn_powder_pass", "name": "Powder Pass", "region": "snow", "difficulty": 2,
		"special": false,
		"map_pos": Vector2(0.690, 0.196),
		"restriction": {"country": "JP"},  # the light Japanese pair, at home on a loose surface
		"events": [
			{"seed": 86001, "turn_count": 30, "forestiness": 0.48, "surface_mix": 0.2, "cliffiness": 0.85, "water_level": -12.0, "terrain_layer1_amplitude": 15.0, "weather": "snow"},
			{"seed": 86002, "turn_count": 32, "forestiness": 0.45, "surface_mix": 0.35, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 16.0, "weather": "night"},
			{"seed": 86003, "turn_count": 30, "forestiness": 0.50, "surface_mix": 0.15, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 15.0, "weather": "snow"},
		],
	},
	{
		"id": "sn_icefall_climb", "name": "Icefall Climb", "region": "snow", "difficulty": 2,
		"special": false,
		"map_pos": Vector2(0.836, 0.353),
		"restriction": {"car_type": "coupe"},  # heavier rear-drive coupes on a low-grip climb
		"events": [
			{"seed": 87001, "turn_count": 32, "forestiness": 0.46, "surface_mix": 0.4, "cliffiness": 0.85, "water_level": -12.0, "terrain_layer1_amplitude": 16.0, "weather": "snow"},
			{"seed": 87002, "turn_count": 34, "forestiness": 0.43, "surface_mix": 0.55, "cliffiness": 0.9, "water_level": -12.0, "terrain_layer1_amplitude": 16.0},
			{"seed": 87003, "turn_count": 32, "forestiness": 0.48, "surface_mix": 0.3, "cliffiness": 0.95, "water_level": -12.0, "terrain_layer1_amplitude": 17.0, "weather": "snow"},
		],
	},
	{
		"id": "sn_summit_dash", "name": "Summit Dash", "region": "snow", "difficulty": 3,
		"special": false,
		"map_pos": Vector2(0.900, 0.268),
		"restriction": {"country": "US"},
		"events": [
			{"seed": 88001, "turn_count": 38, "forestiness": 0.43, "surface_mix": 0.35, "cliffiness": 0.9, "water_level": -13.0, "terrain_layer1_amplitude": 16.0, "weather": "snow"},
			{"seed": 88002, "turn_count": 40, "forestiness": 0.41, "surface_mix": 0.5, "cliffiness": 0.95, "water_level": -13.0, "terrain_layer1_amplitude": 17.0, "weather": "storm"},
			{"seed": 88003, "turn_count": 38, "forestiness": 0.45, "surface_mix": 0.25, "cliffiness": 1.0, "water_level": -13.0, "terrain_layer1_amplitude": 16.0, "weather": "snow"},
		],
	},
	{
		# Unlocks the Race Tires, moved here from the Greek showdown: the grip part
		# belongs to the grip corner, which is the most legible pairing the map offers.
		# See features/snow-region.md for the save migration that keeps it for anyone
		# who already won it where it used to be.
		"id": "sn_showdown", "name": "Upgrade: Race Tires", "region": "snow", "difficulty": 4,
		"special": true,
		"map_pos": Vector2(0.812, 0.216),
		"restriction": {},  # open-class: a special must never gate on a part it unlocks
		"events": [
			{"seed": 89001, "turn_count": 46, "forestiness": 0.43, "surface_mix": 0.3, "cliffiness": 0.95, "water_level": -13.0, "terrain_layer1_amplitude": 17.0, "weather": "snow"},
			{"seed": 89002, "turn_count": 48, "forestiness": 0.40, "surface_mix": 0.5, "cliffiness": 1.0, "water_level": -13.0, "terrain_layer1_amplitude": 18.0, "weather": "night"},
			{"seed": 89003, "turn_count": 46, "forestiness": 0.45, "surface_mix": 0.2, "cliffiness": 1.0, "water_level": -13.0, "terrain_layer1_amplitude": 17.0, "weather": "snow"},
		],
	},
	{
		# Unlocks the Sequential Gearbox, moved here from hc_showdown. The DEEPEST pin
		# on the map: the last thing the corner gives up.
		"id": "sp_summit_trial", "name": "Upgrade: Sequential Gearbox", "region": "snow",
		"difficulty": 4, "special": true,
		"map_pos": Vector2(0.760, 0.108),
		"restriction": {},  # open-class: a special must never gate on a part it unlocks
		"events": [
			{"seed": 89101, "turn_count": 48, "forestiness": 0.41, "surface_mix": 0.35, "cliffiness": 1.0, "water_level": -13.0, "terrain_layer1_amplitude": 17.0, "weather": "snow"},
			{"seed": 89102, "turn_count": 50, "forestiness": 0.38, "surface_mix": 0.55, "cliffiness": 1.0, "water_level": -13.0, "terrain_layer1_amplitude": 18.0},
			{"seed": 89103, "turn_count": 48, "forestiness": 0.43, "surface_mix": 0.25, "cliffiness": 1.0, "water_level": -13.0, "terrain_layer1_amplitude": 17.0, "weather": "snow"},
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


# Monotonic counter bumped whenever the roster is swapped (see Registry.Seam.version).
# Memoise against this rather than hashing all() — an O(1) validity check on paths that
# run per wheel per physics tick.
static func roster_version() -> int:
	return _seam.version


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
# [0, 1]: 0 = no straightness bias (any sharpness equally welcome), 1 = strongly favour
# gentle corners and long straights. Earlier, lower-tier events run higher so their
# stages are gentler; the default is 0. Fed to TrackGenerator.generate (it changes the
# track SHAPE, so the same value is used when deriving target times). Note that 0 is not
# "every corner equally likely" — TrackGenerator.CORNER_WEIGHTS keeps the sharpest
# authored shapes rarer than the rest on every track, whatever this value is.
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


# Whether this event runs on a WET road. THE way to ask at the event layer — a rule that
# should fire "when it's raining" almost always means "when the road is wet", and there is
# more than one wet condition (see WeatherLibrary.WETNESS).
#
# `event_weather(event) == WEATHER_RAIN` is the bug this replaces: it silently excludes
# WEATHER_STORM, which is WETTER than rain. Three separate attempts at a wet-conditioned
# rule shipped that exact comparison before this predicate existed. If you are about to
# write `== WEATHER_RAIN`, you almost certainly want this instead.
static func event_is_wet(event: Dictionary) -> bool:
	return WeatherLibrary.is_wet(event_weather(event))


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
# effective stats (UpgradeLibrary.effective_meta) so a drivetrain conversion or an
# engine swap moves the categorical fields with it; the raw CARS entry is only the
# right input for an unmodified roster car (rivals).
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
	# PERFORMANCE IS NOT AN ENTRY REQUIREMENT. Rally entry is purely CATEGORICAL — its
	# job is to make the player experience different cars ("Japanese only", "hatchbacks
	# only"), never to police how fast they are. The old pw_min..pw_max band lived here
	# and went with the car-performance rating rework: how fast a car is now shapes the
	# OPPONENT FIELD (rivals are matched to the player's rating) instead of blocking
	# entry, so there are no performance walls to upgrade into and detune back out of.
	# See docs/superpowers/specs/2026-08-15-car-performance-rating-design.md.
	return ""


static func is_eligible(rally: Dictionary, car_meta: Dictionary) -> bool:
	return ineligibility_reason(rally, car_meta) == ""


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
# `player_rating` (CarPerformance.rating of the build the player is fielding; 0 to
# skip) MATCHES the grid to the player's pace — see rating_match_weight. This is why
# the field can no longer be precomputed per rally: it is a function of the player's
# car as well as the rally, so the old data/opponent_cache.json could not express it.
#
# The rally's `difficulty` therefore no longer decides how fast the CARS are — it
# decides how hard they are DRIVEN, via the pace band. Matched machinery, harder
# driving: that is what a higher tier means now.
#
# Wrecks (features/opponent-wrecks.md): after the times are drawn, each event
# independently rolls OPPONENT_WRECK_CHANCE to crash ONE not-yet-wrecked rival out.
# A wrecked rival has event_times_ms[wreck_event..] = -1 and DNFs the rally
# (combined_ms = -1, doesn't rank), and carries the seeded roadside placement
# (`wreck_progress` along the track, `wreck_side` = which verge) the run scene reads
# to stage the wreck. `wreck_event` = -1 for a rival who finishes. At most one rival
# wrecks per event, so the run scene shows at most one roadside wreck per stage.
# The tyre the PLAYER has fitted, as an upgrade id ("" = stock, nothing in the slot).
# Read by generate_opponent_field so the rival field runs the same rubber.
static func player_tire_id(player_car: Dictionary) -> String:
	for item_id in UpgradeLibrary.enabled_upgrades(player_car):
		if UpgradeLibrary.slot_of(String(item_id)) == UpgradeLibrary.TIRE_SLOT:
			return String(item_id)
	return ""


# `upgrades` with its tyre swapped for `tire_id` ("" strips the slot back to stock).
# Everything else in the rival's build is left exactly as drawn.
static func _with_tires(upgrades: Array, tire_id: String) -> Array:
	var out: Array = []
	for item_id in upgrades:
		if UpgradeLibrary.slot_of(String(item_id)) != UpgradeLibrary.TIRE_SLOT:
			out.append(item_id)
	if tire_id != "":
		out.append(tire_id)
	return out


static func generate_opponent_field(rally: Dictionary, event_results: Array, events: Array,
		player_rating := 0, player_car: Dictionary = {}) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = _rally_seed(rally)
	# Every car+engine pairing the rally's CATEGORICAL restriction admits
	# (features/rally-roster.md).
	var combo_pool := _eligible_combos(rally)
	var count := rng.randi_range(FIELD_MIN, FIELD_MAX)
	var band := _pace_band(int(rally.get("difficulty", 1)))
	# Draw distinct names from the pool for this rally (stable across re-attempts via
	# the rally-seeded rng); names[i] is rival i's name, held across all 3 events.
	var names := _draw_rival_names(rng, count)
	# Whatever slice of the difficulty target the machinery could not cover (§6 of the
	# design). 1.0 in the normal case, where the target lies inside the pool's rating range.
	var pace_trim := _residual_pace_trim(combo_pool, player_rating)
	# One distinct build per rival, same rng, so the grid is stable across re-attempts.
	var combos := _draw_distinct_combos(rng, combo_pool, count, player_rating)
	# Drawn once for the whole field: every rival runs the player's tyre (see the block
	# in the loop). Skipped entirely when no player car was supplied — the test path and
	# any caller that only wants times keeps the drawn builds untouched.
	var mirror_tires := not player_car.is_empty()
	var tire_id := player_tire_id(player_car) if mirror_tires else ""
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
		# TYRE MIRRORING. The rival runs whatever rubber the player runs.
		#
		# The rating cannot price a surface-dependent compound: CarPerformance benchmarks
		# every car at a FROZEN grip, so a snow tyre's +snow/-tarmac terms are invisible to
		# it and _part_ranking (which ranks parts by that same rating) therefore picks the
		# field's tyres blind to the surface — the same choice on snow as in the desert.
		# A player who fits snow tyres for a snow stage was taking grip the rating never
		# charged them for, and the field could not answer it.
		#
		# Mirroring is the fix rather than teaching the rating about surfaces: the tyre's
		# value genuinely DEPENDS on the stage, so there is no single number the benchmark
		# could hold. Matching the player cancels the term instead of pricing it, and it
		# stays correct for any future compound without another calibration.
		#
		# The WHOLE part is fitted, tradeoffs included — a rival on snow tyres eats the
		# tarmac penalty on a stage's tarmac fraction exactly as the player does. Per-event
		# surface variation then falls out of LapTimeModel._surface_grip for free: one
		# fitted tyre, evaluated against each stage's own snow/tarmac mix.
		var rival_upgrades: Array = combo.get("upgrades", [])
		if mirror_tires:
			rival_upgrades = _with_tires(rival_upgrades, tire_id)
			car_meta = CarPerformance.merged_meta(
				{"installed_upgrades": rival_upgrades, "disabled_upgrades": []},
				combo["car"])
		# Persistent per-rival skill (drawn ONCE): sets a base pace held across every
		# event, so fast rivals stay fast and the field forms a ranked ladder.
		var skill := rng.randf()
		var base_pace := lerpf(band.x, band.y, skill)
		var times: Array = []
		for k in event_results.size():
			var ev: Dictionary = events[k] if k < events.size() else {}
			var floor_ms := LapTimeModel.optimum_ms(event_results[k], car_meta, ev)
			var noise := 1.0 + (rng.randf() * 2.0 - 1.0) * PACE_EVENT_NOISE
			# The trim is applied AFTER the sanity floor, not before it: the fastest rival
			# sits near the bottom of the pace band at every tier, so a trim folded in
			# before a binding floor would be clamped straight back off — which is exactly
			# where hardening is needed most. The only bound on the result is what the
			# ghost can drive.
			var factor := maxf(base_pace * noise, PACE_MIN_FLOOR) * pace_trim
			times.append(int(round(floor_ms * maxf(factor, GHOST_SOLVABLE_PACE))))
		field.append({
			"name": names[i],
			"car_id": String(car.get("id", "")),
			"engine_id": engine_id,
			# Layout-prefixed when the rival is running a non-stock engine ("V12 Rondel
			# Twist"), the plain car name otherwise — the same EngineSwap.display_name
			# convention the garage and the leaderboards use for the player's own car.
			"car_name": EngineSwap.display_name(car, {"swapped_engine": engine_id}),
			# The parts this rival is running (_build_levels). Part of the rival's IDENTITY,
			# not decoration: the times below were drawn off a meta that includes them, so
			# anything re-deriving this rival's meta from car_id + engine_id alone (the
			# ghost's pace solve, most of all) would be looking at a slower car than the one
			# that set the time.
			# The MIRRORED build, not the drawn one: RallySession._effective_meta_for
			# rebuilds the rival ghost's meta from this list, so storing the pre-mirror
			# tyre would have the ghost solve a different car than the one that set the
			# time — and RivalPace would then clamp to cover the gap.
			"upgrades": rival_upgrades.duplicate(),
			"event_times_ms": times,
			"dnf": false,
			"combined_ms": 0,
			"wreck_event": -1,
			"wreck_progress": 0.0,
			"wreck_side": 1.0,
			# The build's CarPerformance rating — what the grid was MATCHED on. Carried
			# on the rival so the match can be inspected after the fact (rally_session
			# logs the whole grid against the player's own rating) rather than being a
			# number that only existed inside the draw.
			"rating": int(combo.get("rating", 0)),
			# Rival-ghost pace seed, one entry per event, -1 = "not solved"
			# (features/rival-ghost.md). Left empty HERE on purpose: solving it needs
			# RivalPace, which needs the whole per-event track, and this function is the pure
			# time-drawing pass. The offline cache bake fills it for each event's P1 — the only
			# rival a ghost is built for — so a live (cache-miss) field simply has no seed and
			# the runtime solves from scratch.
			"skill_k": [],
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
		# Quantised so the value survives a JSON round-trip EXACTLY. Quantised so the value
		# survives a JSON round-trip EXACTLY (it is persisted with the run's standings; a raw
		# double prints to ~14 significant digits and parses back to a DIFFERENT double).
		# 1e-4 of track length is far below
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
const RIVAL_IDENTITY_KEYS := ["name", "car_id", "engine_id", "car_name", "upgrades"]

# The identity keys that are NOT strings, with the empty value a missing one defaults to.
# `upgrades` is a list of fitted part ids (see _build_levels), so it cannot go through the
# String() coercion the rest take.
const RIVAL_IDENTITY_LIST_KEYS := ["upgrades"]


# Copy just the identity keys out of a rival entry, defaulting each to "" (or an empty
# list) so a caller can rely on every key being present. Use this instead of re-listing
# fields by hand.
static func identity_of(opp: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key in RIVAL_IDENTITY_KEYS:
		if RIVAL_IDENTITY_LIST_KEYS.has(key):
			out[key] = (opp.get(key, []) as Array).duplicate()
		else:
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
#
# A CAR-UNLOCK rally draws its field the SAME way as any other. It used to be a one-make
# shootout — every rival in the car on offer — which advertised the prize plainly but made
# the grid a row of identical cars and threw away the variety the combo pool exists for.
# The prize is advertised through the BAND instead: a prize rally's ceiling sits just above
# its own car, so that car is the fastest thing admitted and turns up as the one to beat.
# See prize_car_tops_its_band and features/prize-rallies.md.
static func _eligible_cars(rally: Dictionary) -> Array:
	var pool: Array = []
	for entry in CarLibrary.all():
		if is_eligible(rally, UpgradeLibrary.effective_meta({}, entry)):
			pool.append(entry)
	return pool if not pool.is_empty() else CarLibrary.all()


# The BUILD LEVELS a rival may turn up in — each a list of part ids fitted ENABLED, in
# addition to whatever engine the combo carries. Derived from the catalogue, never
# hardcoded ids, so it follows a retune / a new part / a test fixture roster.
#
# Rivals scale by the same mechanism the player does. With an engine swap as their only
# lever the pool topped out well below what an upgraded player car reaches, so exactly
# where a dominating player sits — the top of the range — the difficulty lever had no room
# to hand the matcher a rating above the player's (see the adaptive-difficulty design, §5).
#
# Four levels, from slowest to fastest:
#   * stock          — no parts at all. Keeps today's combos in the pool unchanged.
#   * ballasted      — the heaviest mass-ADDING part alone. Ballast makes a car slower, so
#                      this is headroom at the EASY end, below a car's own stock rating.
#   * lightly built  — the most modest improving part in each slot.
#   * fully built    — the best part in each slot.
# "Best" / "most modest" are measured ONCE against CarPerformance's synthetic reference car
# (_part_ranking), not per car+engine: ranking every part against every combo would multiply
# the benchmark sims by the catalogue size for an ordering that barely moves between cars.
#
# Rules a level must obey, so a rival is a car that could actually exist:
#   * at most one part per UpgradeLibrary.SLOTS entry (the same exclusivity
#     Save._enable_exclusive enforces on the player's cars)
#   * no consumables (they are not slotted parts)
#   * no ballast in a BUILT level — ballast is a p/w handicap, so fitting it to a level
#     that is meant to be quick would just make it slower
#   * no NITROUS, ever. CarPerformance deliberately excludes it from the rating (it is a
#     per-stage bottle, not a permanent power level), so a rival carrying it would be
#     faster than the rating the field was matched on claims — the one way a build level
#     could lie to the matcher.
# Star gates are deliberately NOT consulted: rivals may carry parts the player has not
# unlocked, exactly as the engine-swap pool already ignores unlock state (design D2).
static func _build_levels() -> Array:
	var key := _build_levels_key()
	if _cached_build_levels_key == key:
		return _cached_build_levels
	var ranking := _part_ranking()
	var levels: Array = [[]]   # stock is always a level
	var ballast := String(ranking.get("ballast", ""))
	if ballast != "":
		levels.append([ballast])
	for tier in ["modest", "best"]:
		var build: Array = []
		for slot in UpgradeLibrary.SLOTS:
			var picked := String((ranking.get(tier, {}) as Dictionary).get(slot, ""))
			if picked != "":
				build.append(picked)
		if not build.is_empty() and not levels.has(build):
			levels.append(build)
	_cached_build_levels = levels
	_cached_build_levels_key = key
	return levels


static var _cached_build_levels: Array = []
static var _cached_build_levels_key := ""


# What the cached build levels are only valid FOR: the upgrade catalogue they were derived
# from (a test seam can swap it wholesale) and the config fingerprint every rating is keyed
# under (a designer retuning the benchmark re-scores every part).
static func _build_levels_key() -> String:
	var ids := PackedStringArray()
	for item in UpgradeLibrary.all():
		ids.append(String(item.get("id", "")))
	return "|".join(ids) + "#" + CarPerformance.config_key()


# Per-slot part ranking: {"best": {slot: id}, "modest": {slot: id}, "ballast": id}.
#
# Each candidate is scored by the rating it gives CarPerformance's REFERENCE car when it is
# the only part fitted. "best" is the top scorer in the slot; "modest" is the lowest-scoring
# part that still IMPROVES on the bare reference, so a "lightly built" rival gets a real but
# small step up rather than a second copy of the fully-built car. A slot with one improving
# part reports the same id for both, and the duplicate level is dropped by _build_levels.
static func _part_ranking() -> Dictionary:
	var base := CarPerformance.rating(CarPerformance.REFERENCE_CAR)
	var best := {}
	var best_score := {}
	var modest := {}
	var modest_score := {}
	var ballast := ""
	var ballast_mass := 1.0
	for item in UpgradeLibrary.all():
		var slot := String(item.get("slot", ""))
		if slot == "" or slot == "nitrous" or bool(item.get("consumable", false)):
			continue
		var item_id := String(item["id"])
		var mass_mult := float((item.get("effect", {}) as Dictionary).get("mass_mult", 1.0))
		if mass_mult > 1.0:
			# Ballast: its own easy-end level, never part of a built one.
			if mass_mult > ballast_mass:
				ballast = item_id
				ballast_mass = mass_mult
			continue
		var score := CarPerformance.rating(CarPerformance.merged_meta(
			{"installed_upgrades": [item_id]}, CarPerformance.REFERENCE_CAR))
		if score <= base:
			# A part the rating cannot see (the sequential gearbox's shift time, the
			# drivetrain kit's flag) is left off every level. It would not move the rival's
			# time either — the same LapTimeModel drives both — so fitting it would only
			# dress a rival in hardware that does nothing.
			continue
		if score > int(best_score.get(slot, -1)):
			best_score[slot] = score
			best[slot] = item_id
		if score < int(modest_score.get(slot, 1 << 30)):
			modest_score[slot] = score
			modest[slot] = item_id
	return {"best": best, "modest": modest, "ballast": ballast}


# Every (car, engine, build level) combination a rally's restriction admits, each carrying
# the meta that build produces — the pool the opponent field draws its rivals from.
#
# Opponents get an engine swap (features/rally-roster.md) AND a build level (_build_levels).
# The swap alone turns a 10-car roster into 10 x EngineLibrary.ENGINES candidates, which is
# what stops a field of nine rivals being nine near-identical stock cars; the build levels
# multiply that again and, more importantly, extend the pool's rating range at BOTH ends —
# which is what gives adaptive difficulty something to aim at.
#
# The stored `meta` is CarPerformance.merged_meta, not effective_meta: a build level can
# fit tyres and a wing, and those reach the rating and the lap-time model only through the
# grip fields effective_meta deliberately withholds. For a stock (no-parts) combo the two
# are identical, so today's fields are unchanged.
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
			# The swap bias measures the ENGINE only — the pairing's stock-build p/w against
			# the car's own. Folding a build level's parts in here would make swap_weight
			# read a fully-built rival as a wild engine swap and all but exclude it, which
			# is precisely the top-end headroom the levels exist to add.
			var pw_swap := CarLibrary.power_to_weight_hp_tonne(UpgradeLibrary.effective_meta(
				{} if eid == stock else {"swapped_engine": eid}, entry))
			for level in _build_levels():
				var owned: Dictionary = {"installed_upgrades": level, "disabled_upgrades": []}
				if eid != stock:
					owned["swapped_engine"] = eid
				var pw_meta := UpgradeLibrary.effective_meta(owned, entry)
				# Eligibility is judged on the power-to-weight meta, as it always has been:
				# a rally's restriction is categorical, and no build level touches a
				# categorical field, so the grip fields would be noise here.
				if not is_eligible(rally, pw_meta):
					continue
				var meta := CarPerformance.merged_meta(owned, entry)
				pool.append({
					"car": entry,
					"engine_id": eid,
					"upgrades": level,
					"meta": meta,
					"pw_delta": absf(pw_swap - pw_stock),
					# What the rating-matched draw weighs the combo by
					# (_draw_distinct_combos / rating_match_weight).
					"rating": CarPerformance.rating(meta),
				})
	if not pool.is_empty():
		return pool
	for entry in CarLibrary.all():
		var stock_meta := UpgradeLibrary.effective_meta({}, entry)
		pool.append({
			"car": entry,
			"engine_id": String(entry.get("engine", "")),
			"upgrades": [],
			"meta": stock_meta,
			"pw_delta": 0.0,  # the stock combo IS the reference
			"rating": CarPerformance.rating(stock_meta),
		})
	return pool


# The residual pace scale: the part of a difficulty target the CARS could not express.
#
# The field is matched to `target_rating` by drawing better or worse machinery, which is
# the whole point of the design — a rival in a quicker car is legible, and its time stays a
# sane multiple of its OWN optimum so the windscreen ghost can still show it. But the
# roster is finite, and a categorical restriction can thin it hard (a country-locked rally
# may offer only a handful of cars at any rating). When the closest thing the pool can
# field is still short of the target, the SHORTFALL — never the whole offset — is taken up
# by scaling every rival's time.
#
# Rating is proportional to average speed (CarPerformance.rating), so the scale is just the
# ratio of what the pool can reach to what was asked for: a pool topping out at 90% of the
# target runs its rivals at 0.90x their times. 1.0 whenever the target sits inside the
# pool's range, which is the normal case — including a target of 0 (unmatched) and every
# target an unadapted, matched-to-the-player field asks for.
#
# Returns the multiplier only; the caller applies and clamps it (see GHOST_SOLVABLE_PACE).
static func _residual_pace_trim(pool: Array, target_rating: int) -> float:
	if target_rating <= 0 or pool.is_empty():
		return 1.0
	var lo := 1 << 30
	var hi := 0
	for combo in pool:
		var r := int(combo.get("rating", 0))
		lo = mini(lo, r)
		hi = maxi(hi, r)
	if hi <= 0:
		return 1.0
	if target_rating > hi:
		return float(hi) / float(target_rating)      # < 1: the pool is too slow, so drive it harder
	if target_rating < lo and lo > 0:
		return float(lo) / float(target_rating)      # > 1: the pool is too fast, so drive it slower
	return 1.0


# How much a combo is favoured in the draw, from how far its power-to-weight sits from
# the car's stock engine. Monotonically decreasing in `pw_delta`, always > 0 so no
# admitted combo is ever unreachable. Pure — see OPPONENT_SWAP_PW_SPREAD.
static func swap_weight(pw_delta: float) -> float:
	return exp(-absf(pw_delta) / maxf(OPPONENT_SWAP_PW_SPREAD, 0.001))


# How much a combo is favoured for being CLOSE TO THE PLAYER'S PACE, from the gap
# between its CarPerformance rating and the player's.
#
# This is what replaced the old power band. Rallies no longer gate on performance, so
# instead of the RALLY deciding how fast the field is, the PLAYER'S OWN CAR does —
# bring a quick car and you race quick cars. That is what keeps every stage a fight
# for P1 instead of a walkover once the player is well upgraded, and it is why
# upgrading is an intrinsic reward here rather than a route to easier wins.
#
# Same shape as swap_weight and for the same reason: a bias, never a filter, so a
# rally whose restriction admits only a handful of cars still fields a full grid.
static func rating_match_weight(rating_delta: float) -> float:
	var spread: float = maxf(Config.data.opponent_rating_match_spread, 0.001)
	return exp(-absf(rating_delta) / spread)


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
#
# `target_rating` (0 = unmatched) additionally biases the draw toward builds whose
# CarPerformance rating is near the player's, via rating_match_weight — see there for
# why the field is matched to the player at all. The two weights MULTIPLY: a rival is
# most likely to be both a plausible build for its car and a plausible match for the
# player's pace.
static func _draw_distinct_combos(rng: RandomNumberGenerator, pool: Array, count: int,
		target_rating := 0) -> Array:
	var out: Array = []
	if pool.is_empty():
		return out
	# Weighted sampling without replacement: pick by weight, remove, repeat. The pool is
	# at most cars x engines (~110), so the linear scan per pick is irrelevant.
	var remaining: Array = pool.duplicate()
	var weights: Array = []
	for combo in remaining:
		var w := swap_weight(float(combo.get("pw_delta", 0.0)))
		if target_rating > 0:
			w *= rating_match_weight(float(int(combo.get("rating", 0)) - target_rating))
		weights.append(w)
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
		# Present so a player row carries every identity key a rival row does; the player's
		# own fitted parts are not needed by any standings consumer.
		"upgrades": [],
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

# Count of rallies this profile has PODIUMED (top-3), the single progression metric
# (caps the car reward tier). NOT a count of rallies finished.
#
# THE GATE IS ON THE WRITE, NOT ON ANY ONE FIELD. `Save.record_podium_rally` has exactly one
# caller (`rally_session.gd`, inside `_award_podium_rewards`, which runs only
# `if podium_or_opening`), so a 5th-place finish writes NOTHING into the rally's record —
# which makes EVERY field of that record podium-gated: `completed`, `best_placed` and
# `best_combined_ms` alike. **There is no untainted sibling field to escape through.**
# Counting `best_placed > 0` instead of `completed` yields the same podium number under a
# more honest-sounding name, and that is the trap: it reads like "finished in any
# position" and is not.
#
# There is NO "finished in any position" counter anywhere in the save schema. A feature
# that needs one must ADD persistence for it (declared in `_default_profile()` so
# `_migrate`'s key backfill seeds existing saves) — not derive one from this record.
# Do not label UI off this as "rallies finished" or "rallies completed"; it means
# "podium finishes".
static func podium_count(profile: Dictionary) -> int:
	var rallies: Dictionary = profile.get(Save.KEY_RALLIES, {})
	var n := 0
	for rally_id in rallies:
		if rallies[rally_id].get("completed", false):
			n += 1
	return n


# DEPRECATED — use podium_count(). Counts PODIUM (top-3) finishes, not rallies finished.
static func completed_count(profile: Dictionary) -> int:
	return podium_count(profile)


# --- Star scoring ------------------------------------------------------------
# What a PLACEMENT is worth lives here; the running total does not. Stars are a persisted
# LEDGER on the profile now (Save.stars_earned / stars_spent — see todo/star-economy.md),
# because a derived total could not see Rally Challenge income and shrank whenever a rally
# was renamed or removed.
#
# Specials DO award stars, and no longer gate on them — the ladder counts completed ordinary
# rallies instead (see "Completion gating" below). Those two facts are linked: while specials
# were star-gated, paying them stars would have let a special bootstrap the next rung.

# How many places count as the podium. NOT a star count — the two were once the same number
# doing both jobs (a 1st -> 3, 2nd -> 2, 3rd -> 1 ramp made the podium size and the top rating
# necessarily equal). They are separate constants now, so widening the podium does not silently
# change what a win pays.
const PODIUM_PLACES := 3
## What winning outright (1st) pays — the top of the curve.
const STARS_FOR_WIN := 3
## What a podium finish pays, 2nd place down to PODIUM_PLACES.
const STARS_FOR_PODIUM := 2
## What merely FINISHING pays, anywhere off the podium.
const STARS_FOR_FINISH := 1
# The most a single rally can pay — i.e. the denominator the star rows draw against.
const MAX_STARS_PER_RALLY := STARS_FOR_WIN


# Stars a finishing position is worth: 1st -> STARS_FOR_WIN, the rest of the podium ->
# STARS_FOR_PODIUM, any other finish -> STARS_FOR_FINISH, and not finishing at all -> 0.
#
# THREE TIERS. Winning outright pays strictly more than scraping the podium — the win is the
# thing the player is chasing, and the rally's car/part prize alone did not make that legible
# in the currency itself. Below that, turning up and finishing always pays something, so a
# rally the player cannot podium is still worth driving.
#
# `placed <= 0` is "did not finish / never placed" and pays nothing — the one case that must
# stay at zero, since the opening rally can complete on a DNF (todo/opening-rally.md) and a
# ledger that paid for that would pay for quitting.
#
# THE one definition — Save.record_podium_rally's credit, the Rally Challenge award and the
# HQ's per-pin star row all go through it, so what a star is worth can never disagree
# between the surfaces that pay it and the ones that show it.
#
# NOTE stars are no longer summed from the roster: they are a PERSISTED LEDGER on the
# profile (`stars_earned` / `stars_spent`, see Save.stars_available and
# todo/star-economy.md). The old total_stars / max_total_stars are gone — a derived total
# could not see Rally Challenge income and shrank whenever a rally was renamed.
static func stars_for_placement(placed: int) -> int:
	if placed <= 0:
		return 0
	if placed == 1:
		return STARS_FOR_WIN
	return STARS_FOR_PODIUM if placed <= PODIUM_PLACES else STARS_FOR_FINISH


static func is_special(rally: Dictionary) -> bool:
	return bool(rally.get("special", false))


# --- Prizes: what a rally hands over ------------------------------------------
# A rally may award a CAR or a PART on top of its stars, and the map shows which by
# standing the prize itself on the pin (see features/map-exploration.md). This is what
# replaced buying cars with stars: the player can SEE what is out there and go and win it,
# instead of saving up for a random draw.
#
# The two halves are authored differently, on purpose:
#
#   * CAR — authored here as `prize_car`, a CarLibrary id. There is nowhere else for it to
#     live: a car does not know which event awards it.
#   * PART — NOT authored here. Derived from UpgradeLibrary's `unlocked_by_rally`, which
#     already names the rally that opens each part. Authoring it on both sides would be two
#     sources for one fact, and they would drift the first time a part was re-gated.
#
# Prize claiming is a PODIUM finish (top 3), the same `completed` bar that lights the map —
# so one good result advances exploration and hands over the reward together.


# The CarLibrary id this rally awards, or "" if it awards no car.
static func prize_car_id(rally: Dictionary) -> String:
	return String(rally.get("prize_car", ""))


# The UpgradeLibrary id this rally awards, or "" if it awards no part. Derived from the
# upgrade catalogue's own gate, never authored on the rally — see the note above.
static func prize_part_id(rally: Dictionary) -> String:
	return String(UpgradeLibrary.unlocked_by(String(rally.get("id", ""))).get("id", ""))


# --- Capability prizes -------------------------------------------------------
#
# A CAPABILITY is the third kind of thing a rally can award, alongside a car and a part: a garage
# MECHANIC rather than an object. Engine swapping is the only one today.
#
# It is gated differently on purpose — `ENGINE_SWAP_UNLOCK_RALLY` names the rally here, where parts
# are gated the other way round (UpgradeLibrary.unlocked_by_rally names the rally on the PART) —
# because a capability has no catalogue entry to hang the gate on. That asymmetry is deliberate and
# is NOT being collapsed; what it cost was a blind spot, because every "what does this rally award"
# query only ever asked about cars and parts. So a capability special looked prize-less to the map
# markers, the "prize rally" wording and the standing rule that a special must award SOMETHING.
# This is the one query that closes it.
#
# Returns a STABLE CAPABILITY ID, not an icon slot: the art mapping belongs to the view layer
# (OverworldMarker.capability_slot_of), and reaching UpgradeOptions from here would make this file
# and that one mutually dependent — the same cycle overworld_roads.gd documents avoiding with
# TerrainManager.
const CAPABILITY_ENGINE_SWAP := "engine_swap"


## The capability this rally awards, or "" for the overwhelming majority that award none.
static func prize_capability_id(rally: Dictionary) -> String:
	return CAPABILITY_ENGINE_SWAP if String(rally.get("id", "")) == ENGINE_SWAP_UNLOCK_RALLY else ""


# Does this rally hand over anything beyond stars? Drives the map marker choice (a car
# model / a part icon / a capability icon / a trophy / an ordinary flag) and the "prize rally"
# wording — and it is the predicate the shipped-roster contract test holds every `special: true`
# rally to, so a special can never again be a special by label alone.
static func has_prize(rally: Dictionary) -> bool:
	return prize_car_id(rally) != "" or prize_part_id(rally) != "" \
		or prize_capability_id(rally) != ""


# --- The opening rally -------------------------------------------------------

# The rally a player who picked `model_id` STARTS IN — the event that awards that model,
# which they are dropped into straight from the starter picker, before the map is ever
# shown (todo/opening-rally.md, features/map-exploration.md).
#
# Derived from `prize_car` rather than authored as a separate "opening" flag, because it
# is the same fact said once: the rally that advertises a car is that car's event, and for
# the player who already owns it the prize is dead — so it becomes their starting line
# instead. A second authored field could disagree with `prize_car`; this cannot.
#
# Returns "" when no rally awards the model — a roster where a starter has no event of its
# own. Callers fall back to the ordinary garage entry rather than treating it as an error,
# since it is a content gap, not a broken profile.
static func opening_rally_id_for(model_id: String) -> String:
	if model_id == "":
		return ""
	for rally in all():
		if prize_car_id(rally) == model_id:
			return String(rally.get("id", ""))
	return ""


# --- Map exploration: the reveal gate ----------------------------------------
# A rally opens because the player has DRIVEN THEIR WAY TO IT, not because a counter
# ticked over. See features/map-exploration.md.
#
# The map starts dark except for a circle around HQ; every rally the player completes
# lights a circle around its OWN map_pos; a rally is revealed when it falls inside any
# lit circle. So the player pushes the frontier outward from the middle and chooses
# which direction to go, rather than being handed the next wave.
#
# This replaced the old global wave counters — `reveal_after` on ordinary rallies and
# `requires_completions` on specials, both read through a `completions_required` shim.
# Those were a pure drip-feed: the rally you unlocked had no relationship to the rally
# you had just won, so a win in one corner opened a rally in another for no reason the
# player could see. The geometric rule makes the map itself the progression graph, and
# it is SELF-MAINTAINING — move a pin and its neighbourhood re-derives, where the old
# scheme needed every authored rung re-checked by hand.
#
# Pure function of (profile.rallies, RALLIES): no fog state is stored, so there is
# nothing to persist and nothing to migrate.

# Where HQ — the garage the player starts at — sits on the world map, normalised 0..1
# like a rally's map_pos. Near the CENTRE, so exploration runs outward toward all four
# corners rather than along a single axis. (This is the position the old present box
# used, for the same reason: the middle of the table reads as "here", not as content.)
const HQ_MAP_POS := Vector2(0.5, 0.5)

# The closest two pins may sit, in normalised map units. Two pins nearer than this are
# unpickable on the HQ map table, so this is a STRUCTURAL bound, not a tuning knob — it is
# the number test_rally_library.gd::test_map_pins_are_well_formed_and_never_stack enforces,
# and it lives here rather than in that test so authoring code and the guard cannot drift.
const MIN_PIN_SEPARATION := 0.03


# A LEGAL, CURRENTLY-FREE pin for a new rally in `region_id` — paste the result straight
# into a new RALLIES row's `map_pos`.
#
# WHY THIS IS A FUNCTION AND NOT A COMMENT. `map_pos` used to be the one field of the
# copy-pasteable rally template that could not be pasted: its rule was PROSE ("in your
# corner, >0.03 from every other pin, within map_reveal_radius of one") sitting next to a
# placeholder Vector2(0.5, 0.5) that is itself illegal — it is HQ. An author who pastes and
# nudges is doing 40-odd distance computations in their head, and the last one to try landed
# 0.021 from an existing pin and turned the pin-spacing guard red. A LIST of free
# coordinates would go stale the moment a pin moves; a function re-derives from whatever is
# authored right now, so it cannot.
#
# The result satisfies all three constraints at once:
#   * inside [0,1]^2 (with a margin, so it is not clipped at the map edge);
#   * more than `min_separation` from EVERY existing pin and from HQ_MAP_POS;
#   * within the anchor rally's own reveal radius, so the new rally is reachable by
#     exploring (test_every_shipped_rally_is_reachable_by_exploring_from_hq).
#
# The anchor is the first rally already authored in `region_id`, so the suggestion lands in
# THAT CORNER of the map — which is what keeps a rally's name, region and terrain agreeing
# with where its pin is (see the geography note above RALLIES). An unknown/empty region, or
# a brand-new region with no rally yet, anchors on HQ instead — the middle of the map — and
# the author should then move it into their corner and re-run this with a neighbouring
# rally's region, or simply re-check the result against `map_pos_is_free()`.
#
# Deterministic (a fixed spiral of candidates, no RNG): the same roster always yields the
# same suggestion. Returns Vector2(-1, -1) if the map is genuinely full at this separation,
# which is a real answer and not a legal pin, so callers must check.
static func suggest_map_pos(region_id := "", min_separation := MIN_PIN_SEPARATION) -> Vector2:
	var anchor := HQ_MAP_POS
	var reach := Config.data.map_reveal_radius if Config.data != null else 0.18
	for rally in all():
		if String(rally.get("region", "")) == region_id and region_id != "":
			anchor = map_pos_of(rally)
			reach = reveal_radius_of(rally)
			break
	var sep := maxf(min_separation, 0.0001)
	# Rings from just outside the separation bound out to just inside the reveal radius,
	# each rotated by the golden angle so candidates never line up into a grid.
	var r := sep * 1.25
	var ring := 0
	while r <= maxf(reach * 0.9, sep * 1.25):
		var base := float(ring) * 2.39996323  # golden angle, radians
		for i in 24:
			var a := base + TAU * float(i) / 24.0
			var cand := anchor + Vector2(cos(a), sin(a)) * r
			if map_pos_is_free(cand, min_separation):
				return Vector2(snappedf(cand.x, 0.001), snappedf(cand.y, 0.001))
		r += sep * 0.5
		ring += 1
	return Vector2(-1, -1)


# Whether `pos` is a legal pin RIGHT NOW: on the map (with a margin) and clear of every
# authored pin and of HQ by more than `min_separation`. The predicate form of the rule
# test_map_pins_are_well_formed_and_never_stack enforces, so an author (or a tool) can
# check a hand-picked coordinate without re-deriving the arithmetic.
static func map_pos_is_free(pos: Vector2, min_separation := MIN_PIN_SEPARATION) -> bool:
	var margin := maxf(min_separation, 0.0)
	if pos.x < margin or pos.x > 1.0 - margin or pos.y < margin or pos.y > 1.0 - margin:
		return false
	# A small cushion above the bound: the guard test asserts STRICTLY greater than
	# min_separation, so a suggestion sitting exactly on it would be red.
	var need := min_separation * 1.1
	if pos.distance_to(HQ_MAP_POS) <= need:
		return false
	for rally in all():
		if pos.distance_to(map_pos_of(rally)) <= need:
			return false
	return true

## Metres between the garage pad and the rally pad it stands beside, edge to edge. The two pads
## must not merge: OverworldPads flattens a circle per pin, and overlapping interiors are held at
## the AVERAGE of their two levels, so neither sits at its own — visible as a garage on a slope.
## Also keeps the garage clear of the zone's dwell circle so parking at one is never parking at
## both. Metres rather than map units because the pads are authored in metres.
const HQ_BESIDE_RALLY_GAP_M := 18.0


## WHERE THE GARAGE STANDS, for `profile`. Not a constant any more.
##
## The player's garage is planted beside the rally that gave them their FIRST CAR — the one their
## career started in. `HQ_MAP_POS` remains the answer before a starter is chosen (and the fallback
## whenever the starter cannot be resolved), so a fresh profile still finds a garage in the middle
## to pick a car at.
##
## WHY THIS IS PROFILE-DERIVED AND NOT LIVE. The position feeds the road network
## (`OverworldRoads` builds an `__hq__` node from it), the garage PAD, the reach set the precompute
## bakes, the default spawn and the garage building itself — and the first two are folded into the
## chunk cache's invalidation key. So it is resolved ONCE at hub build and is stable for that
## session: moving it mid-session would mean re-carving terrain under a driving car. In practice it
## changes exactly once, between the starter pick and the next hub visit, and the re-bake rides the
## loading screen the player is already watching on the way back from their opening rally.
##
## Offset DIRECTION is deterministic (toward the map centre, or +X for a rally already at it), so
## the same profile always rebuilds the same world — the cache key depends on it.
## `size_m` defaults to the LIVE overworld size rather than a literal, so every caller agrees on
## where the garage is without having to pass it — the offset is authored in metres and only
## becomes map units by dividing by the world's edge length.
static func hq_map_pos(profile: Dictionary, size_m: float = -1.0) -> Vector2:
	var world_m := size_m
	if world_m <= 0.0:
		world_m = Config.data.overworld_size_m if Config.data != null else 1000.0
	var starter := String(profile.get("starter_model_id", ""))
	if starter == "":
		return HQ_MAP_POS
	var opening_id := opening_rally_id_for(starter)
	if opening_id == "":
		return HQ_MAP_POS
	var rally := by_id(opening_id)
	if rally.is_empty():
		return HQ_MAP_POS
	var pin := map_pos_of(rally)
	# Edge-to-edge gap plus both radii, converted to map units by the live world size.
	var cfg: GameConfig = Config.data
	var gap_m: float = HQ_BESIDE_RALLY_GAP_M 		+ (cfg.overworld_pad_zone_radius_m if cfg != null else 12.0) 		+ (cfg.overworld_pad_garage_radius_m if cfg != null else 21.0)
	var step := gap_m / maxf(world_m, 1.0)
	var toward := HQ_MAP_POS - pin
	var dir := toward.normalized() if not toward.is_zero_approx() else Vector2.RIGHT
	# Clamped so a rally near an edge cannot push the garage off the map.
	return Vector2(clampf(pin.x + dir.x * step, 0.0, 1.0),
		clampf(pin.y + dir.y * step, 0.0, 1.0))


# How far a completed rally lights the map around itself, in normalised map units. A
# rally may author its own `reveal_radius` so a headline event opens a wider frontier
# than an ordinary one; absent (the usual case) it takes the GameConfig default, which
# is where the pacing is actually tuned.
static func reveal_radius_of(rally: Dictionary) -> float:
	var authored := float(rally.get("reveal_radius", 0.0))
	if authored > 0.0:
		return authored
	return Config.data.map_reveal_radius


# The lit sources on the map right now: HQ (always), plus every completed rally, as
# (centre, radius) pairs in normalised map space. The single derivation shared by the
# reveal predicate and by the HQ table's fog mask, so what the player can ENTER and what
# the player can SEE can never disagree.
static func lit_sources(profile: Dictionary) -> Array:
	# HQ LIGHTS A SMALL CIRCLE, and this used to say it lit nothing.
	#
	# It lit nothing because seeding the map with HQ's own circle opened the handful of pins
	# nearest the middle on a fresh profile for no reason the player had earned, and because the
	# player began INSIDE a rally, so the middle was ordinary fogged ground.
	#
	# The OVERWORLD changed the second premise: the player now stands at the garage and picks
	# their first car there, before any rally. With HQ unlit the fog veil darkens the screen and
	# the frontier push shoves the car while they are choosing. So `map_hq_reveal_radius` ships
	# small and non-zero — deliberately too small to touch any shipped pin, which is what keeps
	# the FIRST premise intact. `test_the_hq_circle_alone_reveals_no_rally` pins that against the
	# real roster: raise the radius past the nearest pin and it fails.
	#
	# The circle follows the GARAGE, which is no longer the map centre — it stands beside the
	# player's first-car rally (see `hq_map_pos`).
	var out: Array = []
	var hq_radius: float = Config.data.map_hq_reveal_radius
	if hq_radius > 0.0:
		out.append([hq_map_pos(profile), hq_radius])
	var rallies: Dictionary = profile.get(Save.KEY_RALLIES, {})
	# ONE pass over the roster. The opening rally is picked out HERE rather than through
	# opening_rally_id_for + by_id, which would each walk `all()` again — and this function
	# is called once per rally by the reveal predicate, so an extra scan is paid n times
	# over. Same rule, a third of the work.
	var starter := String(profile.get("starter_model_id", ""))
	for rally in all():
		var completed := bool(rallies.get(rally["id"], {}).get("completed", false))
		# The player's OPENING rally lights its corner from the very start, completed or
		# not (todo/opening-rally.md). It is where their career begins — they are dropped
		# into it before the map is ever shown — so it is lit for the same reason HQ used
		# to be: it is not somewhere to be reached, it is somewhere they already are.
		#
		# This is also the ANTI-STRANDING guard. The opening rally can sit well outside any
		# other circle, so a player who quits mid-run would otherwise come back to a map
		# with no way to reach the one rally the whole opening depends on — a dead end
		# created by pressing Quit. Lighting it here rather than special-casing
		# rally_revealed keeps fog, pin state and entry on the SAME derivation, which is
		# what stops what the player can SEE drifting from what they can ENTER.
		var is_opening := starter != "" and prize_car_id(rally) == starter
		if not completed and not is_opening:
			continue
		out.append([map_pos_of(rally), reveal_radius_of(rally)])
	# DEAD-END GUARD. Every source is a completed rally or the opening one, so a player who
	# HAS picked a starter but whose starter_model_id no rally awards would light NOTHING —
	# a permanently dark map with no way back, since the picker keys on `starter_picked` and
	# never re-runs. STARTER_MODEL_IDS and the `prize_car` set are two independent
	# authorings held in sync by convention alone, and a roster edit or a cloud profile from
	# another build is enough to break it.
	#
	# Gated on a starter being RECORDED, not merely on `out` being empty: a profile that has
	# not picked yet legitimately sees a dark map (it has not started, and the map is not
	# even reachable from there) — lighting the middle for it would put HQ's circle back by
	# the back door, which is the thing this whole change removed.
	if out.is_empty() and starter != "":
		out.append([hq_map_pos(profile), Config.data.map_reveal_radius])
	return out


# A rally's pin position, normalised 0..1. Centre-of-map is the fallback for a synthetic
# test rally that authors none — deliberately the same point as HQ, so such a rally reads
# as "always lit" rather than landing somewhere arbitrary and dark.
static func map_pos_of(rally: Dictionary) -> Vector2:
	return rally.get("map_pos", HQ_MAP_POS)


# Whether the special that gates `item_id`-style capabilities has been won. Used for the
# engine-swap CAPABILITY gate: tokens drop and bank from the start, but cannot be spent
# until this opens. See features/engine-swap.md.
# How far `rally` sits OUTSIDE the lit region, in normalised map units: 0.0 once it is
# revealed, otherwise the gap between its pin and the nearest lit circle's edge. This is
# the geometric replacement for "which rung is this special on" — with reveal driven by
# distance rather than by a counter, "how far is it from where I've got to" is the only
# meaningful ordering of what the player has not reached yet.
static func distance_beyond_frontier(rally: Dictionary, profile: Dictionary) -> float:
	var pos := map_pos_of(rally)
	var best := INF
	for src in lit_sources(profile):
		var centre: Vector2 = src[0]
		var radius: float = src[1]
		best = minf(best, pos.distance_to(centre) - radius)
	return maxf(best, 0.0)


# How many WAVES of exploration each rally sits behind THE STARTING LINE, ignoring car
# eligibility:
# repeatedly light everything currently reachable and complete it, counting rounds. Wave 1
# is what a fresh profile can enter; wave 2 is what those unlock, and so on. A rally no
# amount of exploring can reach is absent from the returned dict entirely.
#
# This is the roster's REACHABILITY ORDER, and it is what "opens before" means now — NOT
# euclidean distance from HQ. The two genuinely disagree: reveal spreads as a corridor
# along the chain of pins, so a rally that is nearer in a straight line can sit many waves
# further out because nothing lights the gap in between. Anything asserting authored order
# (which special is reached first, that a prerequisite precedes its dependent) must read
# this rather than a distance.
#
# Deliberately ignores cars: it answers "is the MAP connected and in what order", which is
# the authored-geometry question. Whether the player has something eligible to drive at
# each step is a separate, garage-dependent question.
# Seeded from the OPENING RALLIES — every starter's own event, all of them at once. HQ
# lights nothing (see lit_sources), so an unseeded walk would light nothing and report the
# whole roster as unreachable. Taking the union rather than one starter's opening keeps
# this the geometry-only question it claims to be: whichever car the player picks, their
# start is one of these, and asking about a single one would smuggle a garage-dependent
# assumption into an answer about the map. The per-starter walk that DOES account for cars
# is tools/sim_career.gd::solve_reachability.
static func reveal_depths() -> Dictionary:
	var out := {}
	var profile := {Save.KEY_RALLIES: {}}
	for rally in all():
		if prize_car_id(rally) != "" and CarLibrary.STARTER_MODEL_IDS.has(prize_car_id(rally)):
			profile[Save.KEY_RALLIES][String(rally["id"])] = {"completed": true}
			out[String(rally["id"])] = 1
	var wave := 1
	while true:
		var fresh: Array = []
		for rally in all():
			var rid := String(rally["id"])
			if out.has(rid):
				continue
			if rally_revealed(rally, profile):
				fresh.append(rid)
		if fresh.is_empty():
			return out
		wave += 1
		for rid in fresh:
			out[rid] = wave
			profile[Save.KEY_RALLIES][rid] = {"completed": true}
	return out


# The next SPECIAL the player is heading for: the unrevealed one closest to the frontier
# they have already lit ("" once every special is revealed). Roster order breaks a tie.
#
# The map table teases THIS special only, and is now the only surface that names it (the
# garage's carrot line, which quoted the same id, is gone — see
# features/map-exploration.md). It replaced next_locked_special_id,
# which picked the lowest authored rung of a ladder that no longer exists — nearest-to-
# reach is what "next" means once the player chooses their own direction.
static func nearest_locked_special_id(profile: Dictionary) -> String:
	var best := ""
	var best_gap := INF
	for rally in all():
		if not is_special(rally) or rally_revealed(rally, profile):
			continue
		var gap := distance_beyond_frontier(rally, profile)
		if best == "" or gap < best_gap:
			best = String(rally["id"])
			best_gap = gap
	return best


# Display name of the rally whose win unlocks engine swapping — what the locked swap row
# and the car-park confirm popup send the player after. A NAME, not a count: with reveal
# now geometric there is no counter to quote, and "go and win THIS event" is a destination
# the player can actually find on the map. Empty when the rally doesn't resolve (a
# synthetic test roster), so callers can fall back to a plain "not unlocked yet".
static func engine_swap_unlock_rally_name() -> String:
	return String(by_id(ENGINE_SWAP_UNLOCK_RALLY).get("name", ""))


static func engine_swaps_unlocked(profile: Dictionary) -> bool:
	# Careers that won the capability where it USED to live (The Foothills Trial) carry it
	# directly, written by the 5 -> 6 migration — checked first so a re-sited unlock is
	# never taken back. Empty for every career started after the move, exactly like
	# UpgradeLibrary.rally_gate_met's legacy part set.
	if bool(profile.get(Save.KEY_LEGACY_ENGINE_SWAP, false)):
		return true
	return bool((profile.get(Save.KEY_RALLIES, {}) as Dictionary)
		.get(ENGINE_SWAP_UNLOCK_RALLY, {}).get("completed", false))


# The special whose win unlocks engine swapping. Authored here rather than on the rally so
# the capability has one named owner (upgrades are gated the other way round, by
# UpgradeLibrary.unlocked_by_rally).
# Engine swapping is the FIRST thing the star ladder opens (the lowest rung), because it is
# the mechanic that makes the rest of the garage interesting — a player who has it early can
# experiment with every car they win, where a turbo is just a number going up. The part
# unlocks shifted one rung later to make room; the turbo -> supercharger dependency order is
# unchanged (see UpgradeLibrary's unlocked_by_rally fields).
const ENGINE_SWAP_UNLOCK_RALLY := "front_runners"


# Whether EVERY special on the roster is won — the win/credits beat, replacing the old
# the retired per-region gate. A roster with no specials reads as completed.
static func all_specials_completed(profile: Dictionary) -> bool:
	var rallies: Dictionary = profile.get(Save.KEY_RALLIES, {})
	for rally in all():
		if is_special(rally) and not bool(rallies.get(rally["id"], {}).get("completed", false)):
			return false
	return true


# Whether a rally's pin is REVEALED (enterable) yet: does its map_pos fall inside any lit
# circle — HQ's, or one lit by a rally the player has already completed. ONE rule for every
# rally on the roster, whatever it awards. The single reveal predicate shared by the map
# pins (hq.gd), the anti-soft-lock eligibility query, and the reward-draw walk. (Completion
# is a separate check the callers do — a revealed rally may still be incomplete or done.)
#
# Distances are compared SQUARED to keep this allocation- and sqrt-free: it is called once
# per rally per map refresh, and again per cell when the fog mask is rasterised.
static func rally_revealed(rally: Dictionary, profile: Dictionary) -> bool:
	return position_revealed(map_pos_of(rally), profile)


# Whether an arbitrary point on the map is lit. Factored out of rally_revealed so the fog
# mask shades the map with the EXACT predicate that gates entry, rather than a lookalike
# that could drift from it.
static func position_revealed(pos: Vector2, profile: Dictionary) -> bool:
	return position_lit_by(pos, lit_sources(profile))


# The containment test itself, against an ALREADY-BUILT source list. Split out so a caller
# asking about many points at once (reveal_link_pairs, one query per pin) pays for
# lit_sources ONCE instead of once per point, without hand-rolling a second copy of the rule
# that could drift from the one that gates entry.
static func position_lit_by(pos: Vector2, sources: Array) -> bool:
	for src in sources:
		var centre: Vector2 = src[0]
		var radius: float = src[1]
		if pos.distance_squared_to(centre) <= radius * radius:
			return true
	return false


# The map's REVEAL GRAPH, as unordered pairs of rally ids: the pairs sitting close enough
# that completing either would light the other. The HQ table draws one dotted line per pair
# (hq._build_reveal_links) — this is where the pairing itself is decided, alongside the
# reveal rule it is derived from.
#
# BOTH ends must already be revealed. An edge is a statement about ground the player has
# lit; drawn across the dark it hands them the shape of the whole roster before they have
# been anywhere, which is exactly what the fog exists to withhold — and 30-odd unreached
# pins webbed together turns the unexplored map into the busiest thing on the table. Kept to
# revealed pairs, the graph GROWS as the player explores: it draws the route they made.
#
# ONE entry per unordered pair, emitted when the link works in EITHER direction — reveal
# radius is per-rally, so A can reach B without B reaching A, and listing both directions
# would just double the geometry on every symmetric pair.
static func reveal_link_pairs(profile: Dictionary) -> Array:
	var rallies := all()
	var sources := lit_sources(profile)
	# Position and lit-ness are asked once per RALLY, not once per pair: the pair loop is
	# already O(n²) and lit_sources walks the whole roster to build its list, so asking
	# inside the inner loop would make a map refresh cubic in the roster size.
	var pins: Array[Vector2] = []
	var lit: Array[bool] = []
	for rally in rallies:
		var mp := map_pos_of(rally)
		pins.append(mp)
		lit.append(position_lit_by(mp, sources))
	var out: Array = []
	for a in rallies.size():
		if not lit[a]:
			continue
		for b in range(a + 1, rallies.size()):
			if not lit[b]:
				continue
			var reach := maxf(reveal_radius_of(rallies[a]), reveal_radius_of(rallies[b]))
			if pins[a].distance_squared_to(pins[b]) > reach * reach:
				continue
			out.append([String(rallies[a]["id"]), String(rallies[b]["id"])])
	return out


# Anti-soft-lock query for the reward system: the still-incomplete rallies a
# given car can currently enter (revealed — inside the lit region of the map — and
# eligible in-band).
#
# Entry is categorical now, so "can enter" is a plain eligibility check — there is no
# performance ceiling to duck under and no detune to consider.
static func incomplete_rallies_enterable_by(car_meta: Dictionary, profile: Dictionary) -> Array:
	var rallies: Dictionary = profile.get(Save.KEY_RALLIES, {})
	var out: Array = []
	for rally in all():
		if rallies.get(rally["id"], {}).get("completed", false):
			continue
		if not rally_revealed(rally, profile):
			continue
		if is_eligible(rally, car_meta):
			out.append(rally)
	return out

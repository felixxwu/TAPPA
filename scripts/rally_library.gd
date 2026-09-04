class_name RallyLibrary
extends RefCounted
# Docs: features/regions.md — update in the same change as this file.
# Tests: tests/headless/rally_fixtures.gd, tests/headless/test_menu_nav.gd, tests/headless/test_rally_library.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'RallyLibrary' tests/headless/` and read the assertions that pin what you are about to change (7 test files touch this script).
# The finite, curated list of rallies — authored CONTENT (like CarLibrary), not
# player state. A rally is a fixed set of 3 seeded TrackGenerator tracks plus a
# car restriction and a difficulty tier; player completion lives in the save
# profile (todo/save-persistence.md), keyed by the stable `id` here.
#
# This file is also the home of the pure functions the rest of the game needs:
#   * is_eligible(rally, car_meta)            — can this car enter?
#   * rally_revealed / lit_sources           — the map-exploration reveal gate
#   * incomplete_rallies_enterable_by(...)     — the anti-soft-lock query
#
# Determinism is the whole point: TrackGenerator.generate is deterministic for a
# given (seed, turn_count, width), so re-attempting a rally regenerates the SAME
# track. The rival field this file used to seed alongside it (generate_opponent_field
# and everything serving it) is deleted (todo/roguelike-pivot.md decision 5).

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
		# Used to award SNOW TIRES, back when parts existed (gated the usual way round by
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
		# Moved from (0.527, 0.476). That sat only ~24m from HQ_MAP_POS, and the garage
		# (RallyLibrary.hq_map_pos) stands offset from the player's OPENING rally pin by up
		# to ~52m (HQ_BESIDE_RALLY_GAP_M + both pad radii) toward the map centre — for the
		# MX-5/Focus starters the garage pad ended up overlapping this zone's pad (as close
		# as ~18m edge distance). Still deliberately inside BOTH the MX-5 (`shakedown`) and
		# Focus (`hm_timber_trophy`) opening rallies' reveal circles (map_reveal_radius,
		# ~104m) — see features/rally-roster.md's anti-soft-lock note — but far enough that
		# the garage pad clears it by 50m+ for either starter, and every other pin by 49m+.
		"map_pos": Vector2(0.656, 0.363),
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
	# THE DEMOTION (now): both parts MOVED AWAY in the (now-deleted) 4 -> 5 migration — Race
	# Tires gr_showdown -> sn_showdown, Sequential Gearbox hc_showdown -> sp_summit_trial, to
	# give the Alps corner something worth working toward. `Save.MOVED_PART_UNLOCKS`, which
	# recorded the move, is gone with the whole migration chain (todo/roguelike-pivot.md
	# decision 34); this note is what is left of the history. The `special: true` flags were
	# left behind, so for a
	# while the roster held two specials that awarded nothing at all — precisely what the rule at
	# the top of this note forbids. They pay stars like any other rally, so they are ordinary
	# rallies now: `special: false`, no trophy, no teaser, and no seat in the all-specials
	# endgame. Their `id` / `difficulty` / `restriction` / `events` are untouched — ids key saved
	# progress, and the other three are otherwise-ordinary authored fields.
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
		# Used to unlock the SUPERCHARGER, back when parts existed. Pinned on the arid
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


# stage_key (the global stage leaderboards' board key for one event) used to live
# here. Deleted along with the global stage leaderboards it served
# (todo/roguelike-pivot.md decision 30) — see cloud/leaderboard.gd / global_standings.gd.


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
	# and went with the car-performance rating rework, which matched a rival field to
	# the player's rating instead of blocking entry — and the rival field itself is now
	# deleted too (todo/roguelike-pivot.md decision 5), so a car's performance shapes
	# nothing here at all; there are no performance walls to upgrade into and detune
	# back out of. See docs/superpowers/specs/2026-08-15-car-performance-rating-design.md.
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


# --- Star scoring: DELETED (todo/roguelike-pivot.md decision 21) -------------
# PODIUM_PLACES, STARS_FOR_WIN / STARS_FOR_PODIUM / STARS_FOR_FINISH, MAX_STARS_PER_RALLY
# and stars_for_placement() are gone with the rest of the star ledger — see
# Save._default_profile()'s "Star ledger: DELETED" note. Nothing here replaces "how many
# places count as a podium" as a standalone concept; record_podium_rally's callers decide
# that for themselves (the old rally_session.gd gated on `top3 or opening_first`).


static func is_special(rally: Dictionary) -> bool:
	return bool(rally.get("special", false))


# --- Prizes: what a rally hands over ------------------------------------------
# PARTIALLY DELETED (todo/roguelike-pivot.md decision 28 / task "Prize rallies and the
# reward draw"): a rally used to award a CAR or a PART on top of its stars, and the map
# showed which by standing the prize itself on the pin. Car acquisition is a money shop
# now, not a rally-win draw, so `prize_part_id`, `prize_capability_id` and `has_prize` —
# and RewardSystem.draw_car, which drew from this — are gone, along with the `prize_car`
# field on every RALLIES entry.
#
# `prize_car_id` ITSELF SURVIVES, deliberately, as a narrower exception: with the field
# gone it now always returns "" (rally.get("prize_car", "") has nothing left to find), but
# deleting the function outright would require gutting `opening_rally_id_for` /
# `hq_map_pos` / `lit_sources` / `reveal_depths` below — the overworld map-reveal geometry,
# which is a SEPARATE, larger deletion ("The overworld map" in the pivot doc's What gets
# deleted, not this task's four items) and is currently config-gated off
# (`GameConfig.overworld_enabled == false`). Keeping the field's accessor as an always-""
# stub lets that whole subsystem degrade to its own already-coded empty-map fallback with
# no code changes here, rather than this task reaching into a wave it does not own. See
# this agent's report for the full reasoning.
static func prize_car_id(rally: Dictionary) -> String:
	return String(rally.get("prize_car", ""))


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


# MONEY SEAM (todo/roguelike-pivot.md decision 17: "engine swap is re-gated as a meta shop
# purchase" rather than retired). The MECHANISM is fully intact and untouched by the parts
# deletion — EngineSwap's maths, Save.swap_engines, car.gd's _apply_engine_swap and
# UpgradeLibrary.effective_meta's engine resolution all still work. What has to move is
# THIS GATE: it reads a rally-completion flag, and the rally that sets it
# (ENGINE_SWAP_UNLOCK_RALLY, below) is a career artefact — record_podium_rally now has no
# gameplay caller at all, so in practice this returns false for every profile and swapping
# is inert until the shop lands.
#
# WHEN THE META SHOP IS BUILT (stage 6): replace the body with a read of a purchased-unlock
# flag on the profile, exactly as the parts model's `UpgradeLibrary.drivetrain_swap_unlocked`
# would have been (that one is already deleted; its per-car counterpart survives as
# Save.drive_mode_available, which carries the matching seam note). Do NOT delete this
# function to "simplify" — a swap that is free from the first run is a decision the pivot
# explicitly did not take.
static func engine_swaps_unlocked(profile: Dictionary) -> bool:
	# The Save.KEY_LEGACY_ENGINE_SWAP fallback (careers that won the capability where it USED
	# to live, The Foothills Trial, carried directly by the 5 -> 6 migration) is deleted along
	# with the whole migration chain (todo/roguelike-pivot.md decision 34) — no migration is
	# written for the pivot, so a pre-pivot profile resets instead of carrying this flag
	# forward. See Save.SCHEMA_VERSION's own comment.
	return bool((profile.get(Save.KEY_RALLIES, {}) as Dictionary)
		.get(ENGINE_SWAP_UNLOCK_RALLY, {}).get("completed", false))


# The special whose win unlocks engine swapping. Authored here rather than on the rally so
# the capability has one named owner. It is what engine_swaps_unlocked above reads, and it
# goes when that gate becomes a purchase — see its MONEY SEAM comment. (The part unlocks
# that used to be gated the other way round, by UpgradeLibrary.unlocked_by_rally, are
# deleted with the parts model.)
const ENGINE_SWAP_UNLOCK_RALLY := "front_runners"


# Whether EVERY special on the roster is won — the win/credits beat, replacing the old
# the retired per-region gate. A roster with no specials reads as completed.
static func all_specials_completed(profile: Dictionary) -> bool:
	var rallies: Dictionary = profile.get(Save.KEY_RALLIES, {})
	for rally in all():
		if is_special(rally) and not bool(rallies.get(rally["id"], {}).get("completed", false)):
			return false
	return true


# Whether a rally has already been COMPLETED (a podium/top-3 finish — see the save-schema note
# above `podium_count()`, never "attempted in any position", which the schema does not track).
# The same inline `.get(KEY_RALLIES, {}).get(id, {}).get("completed", false)` every other reader
# of this field already does (podium_count, all_specials_completed, lit_sources, ...), factored
# out once so a caller outside this file — overworld_zone.gd's idle-tube dimming — has a named
# predicate to call instead of reaching into the profile dict itself.
static func rally_completed(rally: Dictionary, profile: Dictionary) -> bool:
	var rallies: Dictionary = profile.get(Save.KEY_RALLIES, {})
	return bool(rallies.get(String(rally.get("id", "")), {}).get("completed", false))


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

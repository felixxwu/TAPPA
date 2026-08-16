class_name WeatherLibrary
extends RefCounted
# The authored catalogue of WEATHER CONDITIONS — the single source of truth for what
# each condition IS, in the style of CarLibrary.CARS / RallyLibrary.RALLIES /
# RegionLibrary.REGIONS. Every consumer (tyre grip, the rival lap-time model, the
# world look, the particle field, the loading-screen tell, the opponent-cache
# fingerprint) reads THIS table; none of them may test `== WEATHER_x` any more.
#
# Before this table the system was shaped for two states and had grown to three, with
# a parallel `if weather == …` chain in five different files that all had to be kept
# in sync. Adding a condition now means adding ONE entry here (see "Adding a
# condition" below) — see features/weather.md.
#
# WHAT AN ENTRY HOLDS: the condition's SHAPE — which GameConfig fields it reads and
# which structural features it has. NOT the numbers. Per the project rule, every
# tunable value lives in config/game_config.tres; the table only names the fields.
#
# Entry keys (all optional except "id"; an omitted key means "this condition does not
# have that feature", which is exactly how DRY is expressed — an entry with nothing
# but an id):
#
#   "id"             String  — stable id, matches the authored event `weather` string
#                              and RallyLibrary.WEATHER_* / GameConfig.weather.
#   "grip_mult"      String  — GameConfig field holding the global tyre μ multiplier.
#                              "" / omitted => exactly 1.0 (see grip_mult()).
#   "particles"      String  — WeatherField particle kind ("rain" / "sand"). ""/omitted
#                              => NO particle field is constructed at all.
#   "particle_count" String  — GameConfig field for the quad count (with "particles").
#   "particle_speed" String  — GameConfig field for the particles' travel speed in
#                              m/s. Omitted => the particle KIND's own built-in speed
#                              (rain falls at its authored constant). Exists so no
#                              consumer reads a condition's config field directly.
#   "wind_dir"       String  — GameConfig field for the particle wind heading in
#                              degrees (0 = world +X, 90 = world +Z). Omitted => 0.
#   "look"           Dict    — environment override, mapping each LOOK_KEYS entry to
#                              the GameConfig field that supplies it. EMPTY/omitted =>
#                              the world look is not touched at all, which is what
#                              keeps a dry stage at exactly zero added per-frame cost.
#   "road_tint"      Dict    — {"amount": <GameConfig field>, "color": <GameConfig
#                              field>}. "amount" is the strength; "color" names the
#                              colour the road albedo is LERPED toward, and when it is
#                              OMITTED the albedo is simply MULTIPLIED by the amount
#                              (a plain darkening). Omitted entirely => the road albedo
#                              is left alone. A condition tinting toward a new colour
#                              (dust, snow) is therefore pure authoring: name a colour
#                              field, no world.gd change.
#   "wind"           Dict    — a LATERAL CROSSWIND force on the car body, mapping
#                              "strength"/"gust"/"dir_deg" to GameConfig fields (see
#                              WIND_KEYS). Omitted => no wind force at all. Read by
#                              the crosswind force in car.gd; folded into
#                              physics_fields() because it changes how the car drives.
#   "lightning"      Dict    — an occasional cosmetic flash, mapping "flash"/
#                              "duration"/"interval_min"/"interval_max" to GameConfig
#                              fields (see LIGHTNING_KEYS). Omitted => no flashes.
#                              Read by world.gd._start_lightning. Cosmetic, so it is
#                              NOT in physics_fields() and retuning it never forces a
#                              cache rebake.
#
# ADDING A CONDITION: add its GameConfig fields to game_config.gd + game_config.tres,
# add one entry here naming them, and author `"weather": "<id>"` on the events that
# should run it. No consumer changes. Adding a condition (or any structural edit here)
# re-keys the opponent cache automatically, as does retuning any value that can change
# a LAP TIME — see physics_fields() for the rule on which values those are, and why
# purely cosmetic ones deliberately do not force a rebake.

# The environment knobs a "look" block may supply, each mapped to a GameConfig field
# name. A look block authors ALL of these or none — world.gd._apply_weather_look
# reads them as a set. (Deliberately NOT a place for numbers; see the header.)
const LOOK_KEYS := [
	"background_color", "sky_color", "sun_energy_mult",
	"fog_density_mult", "fog_sky_affect",
]

# The id every unknown/absent condition resolves to. Load-bearing: by_id() returns
# this entry for a typo'd string, mirroring RallyLibrary.event_weather's tolerance.
const DEFAULT_ID := "dry"

const CONDITIONS: Array[Dictionary] = [
	# Dry is the ABSENCE of every feature: no grip multiplier (so grip_mult() is
	# exactly 1.0 and the μ multiply at each contact is unconditional), no look
	# override, no road tint, no particles, no loading tell. A dry stage therefore
	# constructs nothing and writes nothing — exactly zero added per-frame cost, which
	# is a hard requirement on the old phones this game targets. Keep it empty.
	{"id": "dry"},
	# Rain: flat grey overcast made entirely out of fog (no second sky), a darkened
	# wet road, falling drops, and a reduced μ that scales the rival field too.
	{
		"id": "rain",
		"grip_mult": "rain_grip_mult",
		"particles": "rain",
		"particle_count": "rain_particle_count",
		"look": {
			"background_color": "rain_background_color",
			"sky_color": "rain_sky_color",
			"sun_energy_mult": "rain_sun_energy_mult",
			"fog_density_mult": "rain_fog_density_mult",
			"fog_sky_affect": "rain_fog_sky_affect",
		},
		# No "color": the wet road is DARKENED (albedo × amount), not tinted.
		"road_tint": {"amount": "rain_road_darken"},
	},
	# Sandstorm: the same fog-only mechanism in dusty tan, dust blown along one fixed
	# world-space heading, and a road LERPED toward tan rather than darkened (dust
	# cakes on the surface rather than wetting it).
	{
		"id": "sandstorm",
		"grip_mult": "sand_grip_mult",
		"particles": "sand",
		"particle_count": "sand_particle_count",
		"wind_dir": "sand_wind_dir_deg",
		"particle_speed": "sand_wind_speed",
		"look": {
			"background_color": "sand_background_color",
			"sky_color": "sand_sky_color",
			"sun_energy_mult": "sand_sun_energy_mult",
			"fog_density_mult": "sand_fog_density_mult",
			"fog_sky_affect": "sand_fog_sky_affect",
		},
		# Dust CAKES on the surface, so the albedo is lerped toward a dust colour
		# rather than darkened — expressed by naming a colour field, not by a mode.
		"road_tint": {"amount": "sand_road_tint", "color": "sand_road_tint_color"},
	},
	# Fog: the cheapest condition in the table — no particles at all, no grip
	# multiplier, no road tint, just the environment knobs pushed hard. It attacks
	# VISIBILITY rather than μ, which makes it the one condition that is a genuine
	# DIFFICULTY lever rather than a variety one (the lap-time model has no eyes, so
	# rivals are unaffected) — deliberate, and authored on few events. See
	# features/weather.md → "Rival times".
	#
	# Note what is ABSENT and why: no "grip_mult" (μ is exactly 1.0, as dry — fog's
	# whole identity is that it is NOT a grip condition), no "particles" (an omitted
	# kind builds no field at all — this is the case the table was generalised for),
	# and no "road_tint" (a foggy road is dry, so it must not darken like rain's).
	{
		"id": "fog",
		"look": {
			"background_color": "mist_background_color",
			"sky_color": "mist_sky_color",
			"sun_energy_mult": "mist_sun_energy_mult",
			"fog_density_mult": "mist_fog_density_mult",
			"fog_sky_affect": "mist_fog_sky_affect",
		},
	},
	# Storm: rain's look and rain's particle KIND (so no new particle code), authored
	# heavier and wetter, plus two things rain does not have — a lateral crosswind
	# force on the car ("wind") and an occasional lightning flash ("lightning").
	# Both are new entry keys, each read by exactly one consumer; see the key docs
	# above the table.
	{
		"id": "storm",
		"grip_mult": "storm_grip_mult",
		"particles": "rain",
		"particle_count": "storm_particle_count",
		# The rain streaks blow along the SAME heading the wind pushes the car, so the
		# visual and the force read as one thing.
		"wind_dir": "storm_wind_dir_deg",
		"look": {
			"background_color": "storm_background_color",
			"sky_color": "storm_sky_color",
			"sun_energy_mult": "storm_sun_energy_mult",
			"fog_density_mult": "storm_fog_density_mult",
			"fog_sky_affect": "storm_fog_sky_affect",
		},
		"road_tint": {"amount": "storm_road_darken"},
		"wind": {
			"strength": "storm_wind_strength",
			"gust": "storm_wind_gust",
			"dir_deg": "storm_wind_dir_deg",
		},
		"lightning": {
			"flash": "storm_lightning_flash",
			"duration": "storm_lightning_duration_s",
			"interval_min": "storm_lightning_interval_min_s",
			"interval_max": "storm_lightning_interval_max_s",
		},
	},
	# Snowfall. Authored onto the alpine region's events (features/snow-region.md); the
	# same placement convention sandstorm follows for the desert.
	#
	# It deliberately authors NO grip_mult. The snow REGION already owns grip for every
	# stage in that corner, dry or not, so a weather multiplier here would be a second,
	# redundant lever over the same variable — and would make a snowfall stage
	# arbitrarily slipperier than a dry stage on the same frozen ground. Consequence,
	# and it is the correct one: snowfall names nothing in physics_fields, so it never
	# re-keys the opponent cache, because it changes no lap time.
	#
	# Like fog, this is a BRIGHT condition — a white-out, not a dusk. The common
	# mistake is authoring it dark.
	{
		"id": "snow",
		"particles": "snow",
		"particle_count": "snowfall_particle_count",
		"particle_speed": "snowfall_particle_speed",
		"wind_dir": "snowfall_wind_dir_deg",
		"look": {
			"background_color": "snowfall_background_color",
			"sky_color": "snowfall_sky_color",
			"sun_energy_mult": "snowfall_sun_energy_mult",
			"fog_density_mult": "snowfall_fog_density_mult",
			"fog_sky_affect": "snowfall_fog_sky_affect",
		},
		# Fresh snow SETTLES white on the road, so this lerps the albedo toward a colour
		# (sandstorm's caking mechanism) rather than darkening it the way rain does.
		"road_tint": {"amount": "snowfall_road_tint", "color": "snowfall_road_tint_color"},
	},
]

# Sub-keys of a "road_tint" block, in a stable order — both name GameConfig fields.
# "color" is OPTIONAL: without it the road albedo is multiplied by "amount" (darkened);
# with it the albedo is lerped toward that colour by "amount". This is what keeps the
# per-condition tan/darken special case OUT of world.gd.
const ROAD_TINT_KEYS := ["amount", "color"]

# Sub-keys of a "wind" block, in a stable order — the GameConfig fields the crosswind
# body force reads. Part of physics_fields() because wind CHANGES HOW THE CAR DRIVES,
# so retuning it must re-key the opponent cache like a grip change does.
const WIND_KEYS := ["strength", "gust", "dir_deg"]

# Sub-keys of a "lightning" block. Like the look/particle/road-tint keys it is
# cosmetic, so it is listed by config_fields() but NOT by physics_fields() — see the
# rule stated there.
const LIGHTNING_KEYS := ["flash", "duration", "interval_min", "interval_max"]

static var _seam := Registry.Seam.new(CONDITIONS)


static func all() -> Array[Dictionary]:
	return _seam.all()


static func override_for_test(conditions: Array[Dictionary]) -> void:
	_seam.override_for_test(conditions)


static func reset() -> void:
	_seam.reset()


# The entry for a condition id. An UNKNOWN id (a typo in an authored event, an older
# save, a condition removed from the table) resolves to the DRY entry rather than an
# empty dict, so every consumer can read it unguarded and a bad string degrades to a
# plain stage instead of crashing one.
static func by_id(id: String) -> Dictionary:
	var entry := Registry.by_id(all(), id)
	if entry.is_empty():
		entry = Registry.by_id(all(), DEFAULT_ID)
	return entry


# The global tyre μ multiplier for a condition, read out of `cfg`. Dry (and any
# unknown id, which resolves to dry) is EXACTLY 1.0 — a structural identity, not a
# tuning choice — which is what lets Drivetrain.surface_tire_params and
# LapTimeModel._surface_grip multiply unconditionally with no per-condition branch.
static func grip_mult(cfg: GameConfig, id: String) -> float:
	var field := String(by_id(id).get("grip_mult", ""))
	if field == "":
		return 1.0
	return float(cfg.get(field))


# Every GameConfig field name this entry references, in a stable order — the entry's
# full surface, used for validation and by tests. NOT what keys the opponent cache:
# see physics_fields() for that, and the rule it states.
static func config_fields(entry: Dictionary) -> Array:
	var out: Array = []
	for key in ["grip_mult", "particle_count", "wind_dir", "particle_speed"]:
		var field := String(entry.get(key, ""))
		if field != "":
			out.append(field)
	var look: Dictionary = entry.get("look", {})
	for key in LOOK_KEYS:
		if look.has(key):
			out.append(String(look[key]))
	var tint: Dictionary = entry.get("road_tint", {})
	for key in ROAD_TINT_KEYS:
		if tint.has(key):
			out.append(String(tint[key]))
	var wind: Dictionary = entry.get("wind", {})
	for key in WIND_KEYS:
		if wind.has(key):
			out.append(String(wind[key]))
	var lightning: Dictionary = entry.get("lightning", {})
	for key in LIGHTNING_KEYS:
		if lightning.has(key):
			out.append(String(lightning[key]))
	# De-duplicated: a field may legitimately be named twice by one entry (storm points
	# both its particle "wind_dir" and its force's "dir_deg" at one heading, so the
	# drops stream the way the car is pushed). Listing it once keeps this a clean set.
	var unique: Array = []
	for field in out:
		if not unique.has(field):
			unique.append(field)
	return unique


# The GameConfig fields of this entry that can change a LAP TIME, in a stable order:
# the grip multiplier and the wind block. THIS is what keys the opponent cache.
#
# THE RULE, stated once: a weather value belongs here if and only if it changes how
# fast the stage can be driven. Grip scales every rival's target time directly; wind
# is a real body force on the car. EVERYTHING ELSE IS LOOK — the particle count, every
# colour and fog value in the "look" block, the road tint, the lightning flash — and
# must stay out, because folding it in would mean a full multi-minute ./cache_all.sh
# rebake of all 86 rallies' rival fields every time someone nudges a colour.
#
# The safety net for the case this could get wrong (a NEW condition, or a new key on
# one, that does affect times) is fingerprint()'s `str(all())`: any edit to the table's
# STRUCTURE re-keys the cache regardless of what this function returns.
static func physics_fields(entry: Dictionary) -> Array:
	var out: Array = []
	var grip := String(entry.get("grip_mult", ""))
	if grip != "":
		out.append(grip)
	var wind: Dictionary = entry.get("wind", {})
	for key in WIND_KEYS:
		if wind.has(key):
			var field := String(wind[key])
			if not out.has(field):
				out.append(field)
	return out


# A hash of the WHOLE weather table plus every value it names that can change a lap
# time (physics_fields — see the rule there). Deliberately not a list of
# individual fields: adding a condition, adding a key to one, or retuning any
# time-affecting value it points at all change this string automatically, so a new
# condition can never silently change a stage's weather physics unnoticed. Costs one
# hash on a memoised path, not per rally.
static func fingerprint(cfg: GameConfig) -> String:
	var parts := PackedStringArray([str(all())])
	for entry in all():
		for field in physics_fields(entry):
			parts.append("%s=%s" % [field, cfg.get(field)])
	return "|".join(parts).sha256_text().substr(0, 16)

class_name WeatherLibrary
extends RefCounted
# The authored catalogue of WEATHER CONDITIONS — the single source of truth for what
# each condition IS, in the style of CarLibrary.CARS. Every consumer (tyre grip, the
# world look, the particle field, crosswind, headlights) reads THIS table; none of them
# may test `== WEATHER_x`.
#
# Before this table the system was shaped for two states and had grown to three, with
# a parallel `if weather == …` chain in five different files that all had to be kept
# in sync. Adding a condition now means adding ONE entry here (see "Adding a
# condition" below) — see features/weather.md.
#
# WHAT AN ENTRY HOLDS: the condition's SHAPE — which GameConfig fields it reads and
# which structural features it has. NOT the numbers. Per the project rule, every
# tunable value lives in scripts/game_config.gd; the table only names the fields.
#
# Entry keys (all optional except "id"; an omitted key means "this condition does not
# have that feature", which is exactly how DRY is expressed — an entry with nothing
# but an id):
#
#   "id"             String  — stable id: WeatherLibrary.WEATHER_* / GameConfig.weather
#                              and the ids in GameConfig.level_weather_pool.
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
#   "wind"           Dict    — a LATERAL CROSSWIND force on the car body, mapping
#                              "strength"/"gust"/"dir_deg" to GameConfig fields (see
#                              WIND_KEYS). Omitted => no wind force at all. Read by
#                              the crosswind force in car.gd.
#   "headlights"     String  — GameConfig field holding the STRENGTH (0..1) of the fake
#                              headlight cone this condition switches on. Omitted => the
#                              car's lights are off and every cone uniform is a
#                              bit-for-bit no-op. The cone's SHAPE (colour, range,
#                              angles, offset, pitch, separation) is shared and lives in
#                              the headlight_* config block, NOT here — only how hard it
#                              burns is per-condition, because the cone is ADDED to a
#                              light term whose brightness differs per condition. Read by
#                              HeadlightCone; cosmetic.
#   "foliage_wind"   String  — GameConfig field holding the tree-sway strength for
#                              this condition. Omitted => the shared base
#                              (foliage_wind_strength), which is deliberately the
#                              case for every condition but the stormy ones: wind
#                              reads the SAME everywhere except in a storm, where it
#                              authors higher. Read by WindSway; purely cosmetic.
#
# ADDING A CONDITION: add its GameConfig fields to game_config.gd, add one entry here
# naming them, its WETNESS row, and its id to GameConfig.level_weather_pool. No consumer
# changes.

# The environment knobs a "look" block may supply, each mapped to a GameConfig field
# name. A look block authors ALL of these or none — they
# are read as a set. (Deliberately NOT a place for numbers; see the header.)
const LOOK_KEYS := [
	"background_color", "sun_energy_mult",
	"fog_density_mult", "fog_sky_affect",
]

# The id every unknown/absent condition resolves to. Load-bearing: by_id() returns
# this entry for a typo'd string.
const DEFAULT_ID := "dry"

# Condition ids. For authoring and for setting GameConfig.weather, NOT for branching:
# do not write `weather == WEATHER_RAIN` to mean "wet" (storm is wetter) — ask is_wet(id),
# and put anything else per-condition as a KEY on the entry.
const WEATHER_DRY := "dry"
const WEATHER_RAIN := "rain"
const WEATHER_SANDSTORM := "sandstorm"
const WEATHER_FOG := "fog"
const WEATHER_STORM := "storm"
const WEATHER_SNOW := "snow"
const WEATHER_NIGHT := "night"

const CONDITIONS: Array[Dictionary] = [
	# Dry is the ABSENCE of every feature: no grip multiplier (so grip_mult() is
	# exactly 1.0 and the μ multiply at each contact is unconditional), no look
	# override, no particles. A dry stage therefore
	# constructs nothing and writes nothing — exactly zero added per-frame cost, which
	# is a hard requirement on the old phones this game targets. Keep it empty.
	{"id": "dry"},
	# Rain: flat grey overcast made entirely out of fog (no second sky), falling drops,
	# and a reduced μ.
	{
		"id": "rain",
		"grip_mult": "rain_grip_mult",
		"particles": "rain",
		"particle_count": "rain_particle_count",
		"look": {
			"background_color": "rain_background_color",
			"sun_energy_mult": "rain_sun_energy_mult",
			"fog_density_mult": "rain_fog_density_mult",
			"fog_sky_affect": "rain_fog_sky_affect",
		},
	},
	# Sandstorm: the same fog-only mechanism in dusty tan, dust blown along one fixed
	# world-space heading.
	{
		"id": "sandstorm",
		"grip_mult": "sand_grip_mult",
		"particles": "sand",
		"particle_count": "sand_particle_count",
		"wind_dir": "sand_wind_dir_deg",
		"particle_speed": "sand_wind_speed",
		"look": {
			"background_color": "sand_background_color",
			"sun_energy_mult": "sand_sun_energy_mult",
			"fog_density_mult": "sand_fog_density_mult",
			"fog_sky_affect": "sand_fog_sky_affect",
		},
		# Same reasoning as storm's — see the "foliage_wind" key doc above.
		"foliage_wind": "sand_foliage_wind_strength",
	},
	# Fog: the cheapest condition in the table — no particles, no grip multiplier, just
	# the environment knobs pushed hard. It attacks VISIBILITY rather than μ.
	{
		"id": "fog",
		"look": {
			"background_color": "mist_background_color",
			"sun_energy_mult": "mist_sun_energy_mult",
			"fog_density_mult": "mist_fog_density_mult",
			"fog_sky_affect": "mist_fog_sky_affect",
		},
	},
	# Storm: rain's look and rain's particle KIND (so no new particle code), authored
	# heavier and wetter, plus a lateral crosswind force on the car ("wind").
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
			"sun_energy_mult": "storm_sun_energy_mult",
			"fog_density_mult": "storm_fog_density_mult",
			"fog_sky_affect": "storm_fog_sky_affect",
		},
		"wind": {
			"strength": "storm_wind_strength",
			"gust": "storm_wind_gust",
			"dir_deg": "storm_wind_dir_deg",
		},
		# A storm is dark enough that the car's lights come on — the second condition to
		# author a cone, and the reason the cone's strength is a table key rather than a
		# night-only constant. It is authored WELL BELOW night's: the cone is ADDED to
		# the light term, and a storm's bake is a dimmed DAY rather than night's
		# near-black, so night's strength on top of it would blow the lit pool out to
		# white. Everything else about the cone (colour, range, angles, aim, separation)
		# is shared with night.
		"headlights": "storm_headlight_amount",
		# A stormy sky, not just a stormy road — trees rustle harder than the shared
		# base sway. See the "foliage_wind" key doc above and WindSway.
		"foliage_wind": "storm_foliage_wind_strength",
	},
	# Snowfall. LevelWeather shows it in place of rain over the level's snow biome
	# (features/snow-region.md).
	#
	# It deliberately authors NO grip_mult: LevelView.set_snow already sets grip from the
	# snow under the car, so a weather multiplier here would be a second lever over it.
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
			"sun_energy_mult": "snowfall_sun_energy_mult",
			"fog_density_mult": "snowfall_fog_density_mult",
			"fog_sky_affect": "snowfall_fog_sky_affect",
		},
	},
	# Night. PURELY A LOOK: the world
	# is darkened by a very low sun_energy_mult, which the terrain bakes into its vertex
	# colours, and a fake headlight cone re-lights a wedge in front of the player's car
	# additively in the shaders. Nothing here is physics.
	#
	# Note what is ABSENT, and that this is the point: no "grip_mult" (μ is exactly 1.0,
	# as dry — night is a visibility condition, not a grip one), no "wind", no
	# "particles" (no field is constructed at all).
	#
	# The cone's SHAPE fields (headlight_*) are deliberately NOT named here: they are
	# shared by every condition that switches the lights on and are driven per-frame as
	# shader globals, not read out of an entry like a look key. Its STRENGTH is the one
	# per-condition part, so that — and only that — is named by "headlights" below.
	# Night sits at the top of the range because it is the darkest condition in the
	# table; storm authors the same key far lower.
	#
	# Keep night_fog_density_mult LOW: fog is environment-side, so the cone cannot light
	# it, and thick haze at night reads as a flat grey sheet over a lit pool.
	{
		"id": "night",
		"look": {
			"background_color": "night_background_color",
			"sun_energy_mult": "night_sun_energy_mult",
			"fog_density_mult": "night_fog_density_mult",
			"fog_sky_affect": "night_fog_sky_affect",
		},
		"headlights": "night_headlight_amount",
		# Names a GameConfig field holding a sky path. OPTIONAL and unique to night so
		# far: no other condition changes the sky, because rain and dust are things
		# happening UNDER the region's sky while night replaces it outright. Applied
		# after the region look, so it overrides whatever the region chose.
		"sky_panorama": "night_sky_panorama",
	},
]

# WETNESS — the one classification of the table that is NOT a per-entry key, and the
# answer to "is there water on the road right now".
#
# WHY THIS EXISTS AT ALL. Three separate attempts in a row at a weather-conditioned rule
# (a wet tyre-grip axis, a wet spray effect, a wet handling tweak) were written as
# `weather == "rain"` and so were DEAD IN A STORM — which is the wettest condition in the
# table. There was nothing in the code that said which ids are wet, so every author had to
# rediscover it from the entry comments and every one of them got it wrong the same way.
# `is_wet()` below is that missing name. WRITE `WeatherLibrary.is_wet(id)`, NEVER
# `id == "rain"` — the same rule the rest of this file already states for `== WEATHER_x`.
#
# WHY A TABLE AND NOT A BOOLEAN CHAIN: `id == "rain" or id == "storm"` has to be REMEMBERED
# and extended by whoever adds the eighth condition. This dict cannot be forgotten, because
# it must name EVERY id in CONDITIONS — adding a condition without classifying it FAILS
# test_weather_library.gd::test_every_condition_is_classified_wet_or_dry. That test is the
# whole point of the dict being separate from the entries: an omitted entry KEY reads as
# "does not have that feature" (see the header), which would make an unclassified new
# condition silently dry.
#
# WET means LIQUID WATER ON THE ROAD SURFACE — the thing a wet-grip, spray or reflection
# rule actually keys off. It is NOT "has precipitation" and NOT "has a grip multiplier":
# snowfall lays a dry frozen layer (and deliberately authors no grip multiplier at all —
# see its entry), and a sandstorm carries a grip multiplier while being the driest
# condition in the table. Whether a given id is wet is a DESIGN call; only the requirement
# that every id is answered here is structural.
const WETNESS := {
	"dry": false,
	"rain": true,
	"storm": true,       # rain, harder — the id the `== "rain"` bug kept missing
	"sandstorm": false,  # dust, not water
	"fog": false,        # a visibility condition; the road under it is dry
	"snow": false,       # settled/falling snow is a frozen surface, not standing water
	"night": false,      # purely a look
}

# Whether `id` is a WET condition — water on the road. The ONLY sanctioned way to ask;
# see WETNESS above for why a literal comparison is a bug rather than a style choice.
#
# Unknown ids resolve through by_id()'s dry fallback exactly like every other query here,
# so a typo'd or removed condition is dry rather than a crash. A condition installed by
# override_for_test() that WETNESS does not name is likewise dry.
static func is_wet(id: String) -> bool:
	return bool(WETNESS.get(String(by_id(id).get("id", DEFAULT_ID)), false))


# Every wet condition id, in table order — for callers that need the SET rather than a
# per-id question (a doc line, a test subject list, an authoring tool). Derived from
# WETNESS so it can never drift from is_wet().
static func wet_ids() -> Array:
	var out: Array = []
	for entry in all():
		var id := String(entry.get("id", ""))
		if id != "" and is_wet(id):
			out.append(id)
	return out


# Sub-keys of a "wind" block, in a stable order — the GameConfig fields the crosswind
# body force reads.
const WIND_KEYS := ["strength", "gust", "dir_deg"]

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
# tuning choice — which is what lets Drivetrain.surface_tire_params
# multiply unconditionally with no per-condition branch.
static func grip_mult(cfg: GameConfig, id: String) -> float:
	var field := String(by_id(id).get("grip_mult", ""))
	if field == "":
		return 1.0
	return float(cfg.get(field))


# The headlight-cone STRENGTH for a condition, read out of `cfg` and clamped to 0..1.
# A condition that authors no "headlights" field returns EXACTLY 0.0 — the car's lights
# are off — which is what makes every cone uniform a bit-for-bit no-op in the shaders
# and lets HeadlightCone gate on this one number rather than on a weather id.
static func headlight_amount(cfg: GameConfig, id: String) -> float:
	if cfg == null:
		return 0.0
	var field := String(by_id(id).get("headlights", ""))
	if field == "":
		return 0.0
	return clampf(float(cfg.get(field)), 0.0, 1.0)


# Every GameConfig field name this entry references, in a stable order — the entry's
# full surface, used for validation and by tests.
static func config_fields(entry: Dictionary) -> Array:
	var out: Array = []
	for key in ["grip_mult", "particle_count", "wind_dir", "particle_speed", "headlights", "foliage_wind"]:
		var field := String(entry.get(key, ""))
		if field != "":
			out.append(field)
	var look: Dictionary = entry.get("look", {})
	for key in LOOK_KEYS:
		if look.has(key):
			out.append(String(look[key]))
	var wind: Dictionary = entry.get("wind", {})
	for key in WIND_KEYS:
		if wind.has(key):
			out.append(String(wind[key]))
	# De-duplicated: a field may legitimately be named twice by one entry (storm points
	# both its particle "wind_dir" and its force's "dir_deg" at one heading, so the
	# drops stream the way the car is pushed). Listing it once keeps this a clean set.
	var unique: Array = []
	for field in out:
		if not unique.has(field):
			unique.append(field)
	return unique

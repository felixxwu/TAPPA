class_name StageFields
extends RefCounted
# Docs: features/region-stage-library.md, features/weather.md — update in the same change as this file.
# Tests: tests/headless/test_stage_fields.gd — extend in the same change.
#
# Pure (Dictionary) -> value field readers for a STAGE/EVENT dict, plus the weather-id
# authoring constants. This is what survives `scripts/rally_library.gd` (deleted —
# todo/region-stage-slots-redesign.md Q6): the RALLIES roster, the eligibility
# predicates, the map/reveal geometry and the prize-lookup stubs are all gone with the
# rally wrapper they served. These seven getters have nothing to do with that wrapper —
# they are plain lookups-with-defaults over whatever stage dict a caller hands them
# (an authored RegionStageLibrary candidate, a ChallengeLibrary-rolled stage, or a
# Seed Lab preview dict) — so they get a getters-only home instead of dragging the
# 1,159-line RALLIES file along for seven functions.

const DEFAULT_WIDTH := 6.0

# Authored weather conditions (see WeatherLibrary for what each one DOES).
# THESE ARE FOR AUTHORING, NOT FOR BRANCHING. Do not write `weather == WEATHER_RAIN` to
# mean "wet" — WEATHER_STORM is wetter and that comparison silently skips it (it has been
# written wrong three times). Ask `WeatherLibrary.is_wet(id)` / `StageFields.event_is_wet(event)`
# instead; anything else per-condition belongs as a KEY on the WeatherLibrary entry.
const WEATHER_DRY := "dry"
const WEATHER_RAIN := "rain"
# Dust storm — authored only onto region == "greece" candidates.
const WEATHER_SANDSTORM := "sandstorm"
# Fog — a VISIBILITY condition, authored onto FEW candidates in the temperate regions.
const WEATHER_FOG := "fog"
# Storm — heavy rain plus a crosswind and lightning. Authored onto the coastal /
# exposed regions.
const WEATHER_STORM := "storm"
# Snowfall — authored onto region == "snow" candidates. Carries no grip multiplier of
# its own: the snow region already owns grip for its whole corner.
const WEATHER_SNOW := "snow"
# Night — a DARKENED stage lit by a fake headlight cone. Purely a look.
const WEATHER_NIGHT := "night"


# Width a stage runs at — its override, else the authored default.
static func event_width(event: Dictionary) -> float:
	return float(event.get("width", DEFAULT_WIDTH))


# How forested this stage is, in [0, 1]: the fraction of the area covered by trees.
# Trees only spawn where a 300 m-wavelength noise field exceeds (1 - forestiness), so
# higher = denser forest, 0 = bare, 1 = trees everywhere (the default for a stage that
# omits it). Bushes ignore this. See TreeScatter / features/trees.md.
static func event_forestiness(event: Dictionary) -> float:
	return clampf(float(event.get("forestiness", 1.0)), 0.0, 1.0)


# Fraction of this stage's track surfaced as tarmac, in [0, 1] (the rest gravel).
# The track switches surface exactly once along its length (TrackSurface); 0 = all
# gravel, 1 = all tarmac. The default (0) keeps a stage that omits it all gravel.
static func event_tarmac_fraction(event: Dictionary) -> float:
	return clampf(float(event.get("surface_mix", 0.0)), 0.0, 1.0)


# Bias toward straighter (easier) turns when generating this stage's track, in
# [0, 1]: 0 = no straightness bias (any sharpness equally welcome), 1 = strongly favour
# gentle corners and long straights. Fed to TrackGenerator.generate (it changes the
# track SHAPE, so the same value is used when deriving target times). Note that 0 is not
# "every corner equally likely" — TrackGenerator.CORNER_WEIGHTS keeps the sharpest
# authored shapes rarer than the rest on every track, whatever this value is.
static func event_straightness(event: Dictionary) -> float:
	return clampf(float(event.get("straightness", 0.0)), 0.0, 1.0)


# How cliffy this stage is, in [0, 1]: 0 = flat (no cliffs/drops), 1 = the tallest
# cliffs/deepest drops (cliff_max_height_m). Scales the global height ceiling
# (GameConfig.cliff_amount); the camber wavelength stays global. Default 0 keeps a
# stage that omits it flat. Cliffs don't change the centerline or the flat lengthwise
# road profile, so this does NOT feed opponent target-time derivation.
static func event_cliffiness(event: Dictionary) -> float:
	return clampf(float(event.get("cliffiness", 0.0)), 0.0, 1.0)


# The weather condition this stage runs in: WEATHER_DRY, WEATHER_RAIN, etc.
# Authored, never random, so a stage's condition is the same every attempt and its
# leaderboard compares like with like (see features/weather.md). An omitted key OR any
# unrecognised string (a typo) resolves to WEATHER_DRY, so the table stays tolerant
# rather than crashing a stage.
static func event_weather(event: Dictionary) -> String:
	# Resolved through the weather table rather than a chain of string tests, so a
	# condition added to WeatherLibrary is authorable immediately (by_id already
	# falls back to the dry entry for an unknown string). See features/weather.md.
	return String(WeatherLibrary.by_id(String(event.get("weather", WEATHER_DRY))).get("id", WEATHER_DRY))


# Whether this stage runs on a WET road. THE way to ask at the stage layer — a rule
# that should fire "when it's raining" almost always means "when the road is wet", and
# there is more than one wet condition (see WeatherLibrary.WETNESS).
#
# `event_weather(event) == WEATHER_RAIN` is the bug this replaces: it silently excludes
# WEATHER_STORM, which is WETTER than rain. If you are about to write `== WEATHER_RAIN`,
# you almost certainly want this instead.
static func event_is_wet(event: Dictionary) -> bool:
	return WeatherLibrary.is_wet(event_weather(event))

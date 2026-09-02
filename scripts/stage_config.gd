class_name StageConfig
extends RefCounted
# Docs: features/weather.md, features/track.md — update in the same change as this file.
# Tests: tests/headless/test_rally_session.gd, tests/headless/test_track_cache.gd, tests/headless/test_snow_region.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'StageConfig' tests/headless/` and read the assertions that pin what you are about to change.
# The CANONICAL writer that turns a stage/event dict into a GameConfig — i.e. the
# one place an authored (or rolled) stage's track parameters reach the config the
# world is generated from. Extracted from RallySession, which owned it only by
# accident of history: it is pure, scene-free and session-free, and every kind of
# run (career rally, Rally Challenge, benchmark, the offline track-cache tools)
# goes through it.
#
# Static-only, no autoload (same shape as RallyLibrary / ChallengeLibrary /
# DrivingContext) — so it can be reached by `class_name` from anywhere, including
# from `tools/` scripts run with `--script`, with no node in the tree.
#
# TWO ENTRY POINTS, and the difference matters:
#   * apply_event_config(cfg, event) writes onto the config you hand it (the LIVE
#     Config.data, in the run scene).
#   * canonical_event_config(event) returns a FRESH config for the event and
#     mutates nothing shared — the form every generation site that must agree on a
#     cache key uses (the lockfile generator, target-time derivation, previews).
#
# Do not add a third way to seat stage parameters. The reason this is one function
# is that Config.data is a persistent session working copy that is never reset
# between scenes, so any hand-written subset silently inherits whatever the last
# stage left in the fields it forgot.


# Write an event's track parameters into `cfg`. Pure (scene-free) so the fallback
# semantics can be tested directly.
#
# Fields an event may OMIT fall back to the AUTHORED baseline (the pristine cached
# .tres — Config.data is a duplicate of it), NOT the current cfg value. Config.data
# is a persistent session working copy that's never reset between events, so a
# cfg-value fallback would let one event's override leak into a later event that
# omits the key. `base` pins every omitted field to its global default.
#
# IDEMPOTENT by construction (it reloads `base` on every call), which is what lets
# DrivingContext.apply_stage_config call it at CONSUME time — world.gd._ready —
# rather than each scene producer having to remember to push it first.
static func apply_event_config(cfg: GameConfig, event: Dictionary) -> void:
	var base: GameConfig = load(Config.CONFIG_PATH)
	cfg.track_seed = int(event.get("seed", base.track_seed))
	cfg.track_turn_count = int(event.get("turn_count", base.track_turn_count))
	cfg.track_straightness = RallyLibrary.event_straightness(event)
	cfg.track_width = RallyLibrary.event_width(event)
	cfg.track_forestiness = RallyLibrary.event_forestiness(event)
	cfg.track_tarmac_fraction = RallyLibrary.event_tarmac_fraction(event)
	cfg.weather = RallyLibrary.event_weather(event)   # WEATHER_DRY / WEATHER_RAIN; see features/weather.md
	cfg.cliff_amount = RallyLibrary.event_cliffiness(event)   # [0,1], scales cliff_max_height_m
	cfg.water_enabled = bool(event.get("water_enabled", base.water_enabled))
	# event -> event's region (if the caller seated one, see RallySession.current_event() /
	# _generate_event_tracks) -> the authored baseline. See TrackGenParams.resolve_water_level.
	cfg.track_water_level_m = TrackGenParams.resolve_water_level(event, base.track_water_level_m)
	# Per-region HANDLING overrides (features/snow-region.md). The snow region drops
	# every surface's grip and adds deep snow at the roadside; every other region
	# authors neither, so these resolve to the authored baseline and a zero deep-snow
	# block — an exact no-op. Read off the event's own region, which the caller already
	# seated for resolve_water_level above, so no signature change was needed.
	#
	# Note the grip is seated onto the SAME live fields the lap-time model reads
	# (LapTimeModel._surface_grip), so the rival field scales with the player
	# automatically: snow is a variety lever, not a difficulty one. CarPerformance is
	# unaffected — it benchmarks at a frozen mu, so ratings cannot drift.
	var region_id := String(event.get("region", ""))
	var sgrip := RegionLibrary.surface_grip_of(base, region_id)
	cfg.grass_grip = float(sgrip.get("grass", base.grass_grip))
	cfg.gravel_grip = float(sgrip.get("gravel", base.gravel_grip))
	cfg.tarmac_grip = float(sgrip.get("tarmac", base.tarmac_grip))
	var deep_snow := RegionLibrary.deep_snow_of(base, region_id)
	cfg.deep_snow_drag = float(deep_snow.get("drag", 0.0))
	cfg.deep_snow_depth_m = float(deep_snow.get("depth", 0.0))
	# Frozen lakes: 0.0 means liquid, which is every region but the Alps, so the lake
	# stays the soft drag hazard it has always been unless a region says otherwise.
	cfg.frozen_water_grip = float(
		RegionLibrary.frozen_water_of(base, region_id).get("grip", 0.0))
	# Per-event terrain hill shape: any of the 3 Perlin layers' wavelength/amplitude
	# may be overridden; omitted ones use the authored global default (features/terrain.md).
	cfg.terrain_layer1_wavelength = float(event.get("terrain_layer1_wavelength", base.terrain_layer1_wavelength))
	cfg.terrain_layer1_amplitude = float(event.get("terrain_layer1_amplitude", base.terrain_layer1_amplitude))
	cfg.terrain_layer2_wavelength = float(event.get("terrain_layer2_wavelength", base.terrain_layer2_wavelength))
	cfg.terrain_layer2_amplitude = float(event.get("terrain_layer2_amplitude", base.terrain_layer2_amplitude))
	cfg.terrain_layer3_wavelength = float(event.get("terrain_layer3_wavelength", base.terrain_layer3_wavelength))
	cfg.terrain_layer3_amplitude = float(event.get("terrain_layer3_amplitude", base.terrain_layer3_amplitude))


# The canonical, event-resolved config for track generation: a fresh duplicate of
# the authored base with this event's overrides applied. Every generation site (the
# lockfile generator, target-time derivation, the run scene) must resolve params
# from THIS so their cache keys match. Standalone (no shared Config.data mutation).
#
# STATIC — it was an instance method only while it lived on the RallySession
# autoload, where a `func` was the ordinary way to be reachable as
# `RallySession.canonical_event_config(...)`. StageConfig is never instantiated,
# so there is nothing for an instance method to hang off; both entry points are
# statics and both stay unit-testable with no scene.
static func canonical_event_config(event: Dictionary) -> GameConfig:
	var cfg := (load(Config.CONFIG_PATH) as GameConfig).duplicate() as GameConfig
	apply_event_config(cfg, event)
	return cfg

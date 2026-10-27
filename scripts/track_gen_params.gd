class_name TrackGenParams
extends RefCounted
# Docs: features/lakes.md — update in the same change as this file.
# Tests: tests/headless/test_lake_field.gd, tests/headless/test_lakes_integration.gd — extend in the same change.
# The single shape contract for TrackGenerator.generate(). Holds EVERY determinant
# of the generated track shape — including water — so no shape can be produced
# without deciding a water level, and so the real run + target-time derivation +
# previews cannot drift (they all build params from the same factory). See
# docs/superpowers/specs/2026-07-13-roadside-lakes-design.md §3, §6.

const TerrainNoise = preload("res://scripts/terrain_noise.gd")

const NOMINAL_ORIGIN := Vector2.ZERO
const NOMINAL_HEADING := Vector2(0.0, -1.0)

# Dry-start search tuning (see recompute_origin).
const _DRY_SEARCH_RADIUS_M := 120.0   # how far out to look for a dry origin
const _DRY_SEARCH_STEP_M := 4.0       # ring spacing
const _START_PAD_M := 4.0             # radius of the start pad that must be dry

var seed: int = 1
var turn_count: int = 8
var width: float = 6.0
var clearance: float = 0.0
var reserve_behind: float = 0.0
var straightness: float = 0.0
var runoff_m: float = 0.0
var water_enabled: bool = false
var water_level: float = 0.0
var shore_clearance: float = 1.5
var origin: Vector2 = NOMINAL_ORIGIN
var heading: Vector2 = NOMINAL_HEADING
# The generation origin BEFORE any dry-start relocation. The run scene translates
# the car + start-anchored props by (origin - base_origin) so the spawn tracks the
# relocated start (see world.gd).
var base_origin: Vector2 = NOMINAL_ORIGIN
var water_sampler: Callable = Callable()


static func _base(cfg: GameConfig) -> TrackGenParams:
	var p := TrackGenParams.new()
	p.width = cfg.track_width
	p.clearance = cfg.track_clearance
	p.runoff_m = cfg.track_runoff_m
	p.shore_clearance = cfg.water_shore_clearance_m
	return p


# Build the pure headless sampler from the seed + config layers.
static func _sampler_for(seed_value: int, cfg: GameConfig) -> Callable:
	return TerrainNoise.make_sampler(seed_value, cfg.terrain_layers())


# Params for generation off cfg.track_* directly.
static func for_config(cfg: GameConfig) -> TrackGenParams:
	var p := _base(cfg)
	p.seed = cfg.track_seed
	p.turn_count = cfg.track_turn_count
	# width already seated from cfg.track_width by _base().
	p.straightness = cfg.track_straightness
	p.water_enabled = cfg.water_enabled
	p.water_level = cfg.track_water_level_m
	p.water_sampler = _sampler_for(p.seed, cfg)
	p.heading = NOMINAL_HEADING
	p.origin = NOMINAL_ORIGIN
	p.base_origin = p.origin
	p.recompute_origin()
	return p


# Positional convenience builder for tests/benchmarks that need a bare params
# object without a GameConfig (no cfg defaults, no dry-start relocation).
# Production code should use for_config instead.
static func of(start_pos: Vector2, start_heading: Vector2, seed_value: int,
		turns: int, track_width: float, clearance_m := 0.0, reserve := 0.0,
		straight := 0.0, runoff := 0.0) -> TrackGenParams:
	var p := TrackGenParams.new()
	p.origin = start_pos
	p.heading = start_heading
	p.seed = seed_value
	p.turn_count = turns
	p.width = track_width
	p.clearance = clearance_m
	p.reserve_behind = reserve
	p.straightness = straight
	p.runoff_m = runoff
	return p


# True if the start pad + the lead-in corridor at `o` sit above the waterline.
func _origin_dry(o: Vector2) -> bool:
	if not water_enabled or not water_sampler.is_valid():
		return true
	var ceiling := water_level + shore_clearance
	# Start pad: a ring of samples around o.
	for a in range(0, 360, 45):
		var pad := o + Vector2.RIGHT.rotated(deg_to_rad(a)) * _START_PAD_M
		if water_sampler.call(pad.x, pad.y) < ceiling:
			return false
	# Lead-in corridor behind o (reserve_behind), sampled along the heading.
	var steps := int(ceil(reserve_behind / _DRY_SEARCH_STEP_M))
	for s in steps + 1:
		var back := o - heading.normalized() * (float(s) * _DRY_SEARCH_STEP_M)
		if water_sampler.call(back.x, back.y) < ceiling:
			return false
	if water_sampler.call(o.x, o.y) < ceiling:
		return false
	return true


# Deterministic outward-spiral search for a dry origin; falls back to clamping the
# water level (then disabling water) if none is found in budget. Pure function of
# (seed, water_level, sampler) — same inputs -> same origin.
func recompute_origin() -> void:
	# Search relative to base_origin (the staged pre-relocation pose). Heading is
	# preserved — relocation is a pure translation, so the run scene can move the
	# car + props by (origin - base_origin) without re-orienting anything.
	origin = base_origin
	if not water_enabled or not water_sampler.is_valid():
		return
	if _origin_dry(origin):
		return
	var found := false
	var r := _DRY_SEARCH_STEP_M
	while r <= _DRY_SEARCH_RADIUS_M and not found:
		var ring := int(ceil(2.0 * PI * r / _DRY_SEARCH_STEP_M))
		for i in ring:
			var ang := (float(i) / float(ring)) * TAU
			var cand := base_origin + Vector2.RIGHT.rotated(ang) * r
			if _origin_dry(cand):
				origin = cand
				found = true
				break
		r += _DRY_SEARCH_STEP_M
	if found:
		return
	# Fallback: no dry origin within budget — clamp the water level below the
	# protected set (then disable water) so the start stays dry at base_origin.
	origin = base_origin
	var protected_min: float = water_sampler.call(base_origin.x, base_origin.y)
	var clamped: float = protected_min - shore_clearance
	if clamped <= water_level:
		water_level = clamped
	if not _origin_dry(base_origin):
		water_enabled = false



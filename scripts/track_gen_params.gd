class_name TrackGenParams
extends RefCounted
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


# Seat the pre-relocation origin/heading/reserve from cfg's start-line staging. A
# staged run generates from a point cfg.start_lead_in_ahead_m ahead of the nominal
# spawn and reserves the lead-in corridor behind it; free-roam is never staged.
# Identical logic in the run scene and target derivation keeps their shapes in sync.
static func _apply_staging(p: TrackGenParams, cfg: GameConfig, staged: bool) -> void:
	p.heading = NOMINAL_HEADING
	if staged:
		p.reserve_behind = cfg.start_lead_in_ahead_m + cfg.start_lead_in_behind_m
		p.origin = NOMINAL_ORIGIN + NOMINAL_HEADING * cfg.start_lead_in_ahead_m
	else:
		p.reserve_behind = 0.0
		p.origin = NOMINAL_ORIGIN
	p.base_origin = p.origin


# Build the pure headless sampler from the seed + config layers.
static func _sampler_for(seed_value: int, cfg: GameConfig) -> Callable:
	return TerrainNoise.make_sampler(seed_value, cfg.terrain_layers())


# Params for a rally event. Uses the RallyLibrary event_* helpers (clean constant
# defaults) so the shape — and thus opponent target times — matches what
# RallySession derives and what the run scene generates. An empty event {} falls
# back to cfg via those helpers' defaults; for free-roam use for_config instead.
static func for_event(event: Dictionary, cfg: GameConfig) -> TrackGenParams:
	var p := _base(cfg)
	p.seed = int(event.get("seed", cfg.track_seed))
	p.turn_count = int(event.get("turn_count", cfg.track_turn_count))
	p.width = RallyLibrary.event_width(event)
	p.straightness = RallyLibrary.event_straightness(event)
	p.water_enabled = bool(event.get("water_enabled", cfg.water_enabled))
	p.water_level = float(event.get("water_level", cfg.track_water_level_m))
	p.water_sampler = _sampler_for(p.seed, cfg)
	_apply_staging(p, cfg, cfg.start_line_enabled)
	p.recompute_origin()
	return p


# Params for free-roam / benchmark / editor generation (no rally event) — reads
# cfg.track_* directly, reproducing the pre-lakes cfg-driven behaviour.
static func for_config(cfg: GameConfig) -> TrackGenParams:
	var p := _base(cfg)
	p.seed = cfg.track_seed
	p.turn_count = cfg.track_turn_count
	# width already seated from cfg.track_width by _base().
	p.straightness = cfg.track_straightness
	p.water_enabled = cfg.water_enabled
	p.water_level = cfg.track_water_level_m
	p.water_sampler = _sampler_for(p.seed, cfg)
	_apply_staging(p, cfg, false)
	p.recompute_origin()
	return p


# Positional convenience builder for tests/benchmarks that need a bare params
# object without a GameConfig (no cfg defaults, no dry-start relocation).
# Production code should use for_event/for_config/for_trial instead.
static func of(start_pos: Vector2, start_heading: Vector2, seed_value: int,
		turn_count: int, width: float, clearance := 0.0, reserve := 0.0,
		straightness := 0.0, runoff := 0.0) -> TrackGenParams:
	var p := TrackGenParams.new()
	p.origin = start_pos
	p.heading = start_heading
	p.seed = seed_value
	p.turn_count = turn_count
	p.width = width
	p.clearance = clearance
	p.reserve_behind = reserve
	p.straightness = straightness
	p.runoff_m = runoff
	return p


static func for_trial(seed_value: int, water_level_m: float, turns: int,
		straight: float, cfg: GameConfig) -> TrackGenParams:
	var p := _base(cfg)
	p.seed = seed_value
	p.turn_count = turns
	p.straightness = straight
	p.water_enabled = true
	p.water_level = water_level_m
	p.water_sampler = _sampler_for(seed_value, cfg)
	p.recompute_origin()
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

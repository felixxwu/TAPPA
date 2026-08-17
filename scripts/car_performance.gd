extends RefCounted
class_name CarPerformance

# A car's performance RATING — one number saying how fast a given build is, the way
# Forza's PI does. Higher is faster.
#
# It is not a formula over stats: the car is simulated around a fixed benchmark track
# (BenchmarkTrack) with LapTimeModel, and the rating is derived from the TOTAL time.
# That means it automatically accounts for whatever the solver models, and it cannot
# drift out of agreement with a hand-written weighting.
#
# See docs/superpowers/specs/2026-08-15-car-performance-rating-design.md.
#
# WHAT IT MEASURES: power, mass, drag, tyre grip, downforce, drive mode, tyre WIDTH (via
# the load-sensitivity term, LapTimeModel._load_factor) and a car's GEARED TOP SPEED
# (LapTimeModel._geared_top_speed_sq — the ratios and final drive off its engine against
# its wheel radius).
# WHAT IT DOES NOT: braking (there is no per-car brake data in the game — see the
# spec's D7), the SHIFTS themselves (time lost per upshift, so a close-ratio box is not
# credited for it), the torque CURVE's shape (peak power is assumed available at every
# speed below the top-gear cap), turbo lag (a boosted engine is rated at full boost),
# suspension, weight distribution.
# The hairpin therefore measures low-speed cornering and corner exit, NOT braking.
# Do not describe it to the player as though it measures stopping power.

# Frozen benchmark conditions. Deliberately CONSTANTS rather than GameConfig lookups:
# LapTimeModel._surface_grip normally reads gravel_grip / tarmac_grip / the weather
# table, so an ordinary grip retune would silently re-score the whole roster. The
# rating must be a property of the CAR, so the conditions are nailed down here and
# passed via LapTimeModel's mu_override seam.
const BENCHMARK_SURFACE_GRIP := 1.0   # dry gravel reference; matches the shipped gravel_grip

# Scale constant for the displayed number. Pure presentation — it sets what range the
# roster lands in, not the ordering. Ratings are normalised against a reference car
# (see _reference_ms), so this is the reference car's own rating by construction.
const RATING_SCALE := 500.0

# Reference car defining the anchor of the scale. Fixing this is what stops a knob
# change from silently re-meaning every authored rating (e.g. Rally Challenge
# ceilings): when the track geometry moves, the reference moves with it, so a car
# that is "as fast as the reference" keeps rating RATING_SCALE.
#
# It is a SYNTHETIC spec, not a catalogue entry, precisely so that retuning or
# removing a shipped car cannot shift the scale under every other car.
const REFERENCE_CAR := {
	"mass": 1200.0,
	"peak_torque": 300.0,
	"redline": 7000.0,
	"tire_compound": 1.0,
	"drag": 0.05,
	"drive_mode": CarLibrary.RWD,
	"downforce_front": 0.0,
	"downforce_rear": 0.0,
}

# Memoised ratings. Keyed by the car inputs the solver reads PLUS a fingerprint of the
# config that shapes the track, because the geometry knobs live in GameConfig and a
# designer edit mid-session must not leave stale numbers on screen.
static var _cache: Dictionary = {}
static var _cached_track: Dictionary = {}
static var _cached_track_key := ""
static var _cached_reference_ms := 0


# The rating for a car meta. Pass a meta that already has upgrades folded in — see
# merged_meta() for why that needs BOTH of UpgradeLibrary's meta builders.
static func rating(meta: Dictionary) -> int:
	var ms := benchmark_ms(meta)
	if ms <= 0:
		return 0
	var ref := _reference_ms()
	if ref <= 0:
		return 0
	# Proportional to average SPEED, not to time. Raw time is inverted and compresses
	# badly at the fast end, where half a second between two quick cars means far more
	# than between two slow ones; the reciprocal spreads the roster evenly.
	return int(round(RATING_SCALE * float(ref) / float(ms)))


# Raw benchmark time in ms, for tooling and calibration.
static func benchmark_ms(meta: Dictionary) -> int:
	var key := _cache_key(meta)
	var hit: Variant = _cache.get(key)
	if hit != null:
		return int(hit)
	var ms := _simulate(meta)
	_cache[key] = ms
	return ms


# The meta CarPerformance should be given for an owned car.
#
# UpgradeLibrary keeps power and grip in two different metas: effective_meta mirrors
# only the EFFECTS entries flagged feeds_pw, and grip_meta carries tire_compound and
# downforce_*. That split existed because power-to-weight was the ELIGIBILITY currency
# and tyres were not allowed to move it. The rating has no such constraint — and a
# rating blind to aero and tyres would defeat the point of the benchmark's sweepers —
# so it must see both.
static func merged_meta(owned_car: Dictionary, base_meta: Dictionary) -> Dictionary:
	var out := UpgradeLibrary.effective_meta(owned_car, base_meta).duplicate()
	var grip := UpgradeLibrary.grip_meta(owned_car, base_meta)
	for k in ["tire_compound", "downforce_front", "downforce_rear"]:
		if grip.has(k):
			out[k] = grip[k]
	return out


# The GameConfig fingerprint every memoised rating is keyed under. Public so other caches
# built on the rating (CarStatBounds) can invalidate on exactly the same signal rather
# than inventing a second, drifting one.
static func config_key() -> String:
	return _config_key()


# Drop every memoised rating. Call when the catalogue or the config changes; the cache
# key already folds the config fingerprint, so this is belt-and-braces for seams that
# swap the catalogue wholesale (tests, CarFixtures).
static func reset() -> void:
	_cache.clear()
	_cached_track = {}
	_cached_track_key = ""
	_cached_reference_ms = 0


static func _simulate(meta: Dictionary) -> int:
	var mu := BENCHMARK_SURFACE_GRIP * float(meta.get("tire_compound", 1.0))
	return LapTimeModel.optimum_ms(_track(), meta, {}, 1.0, 1.0, mu)


static func _track() -> Dictionary:
	var key := _config_key()
	if _cached_track_key != key or _cached_track.is_empty():
		_cached_track = BenchmarkTrack.build()
		_cached_track_key = key
		_cached_reference_ms = 0   # geometry moved, so the anchor must be re-solved
	return _cached_track


static func _reference_ms() -> int:
	_track()   # ensures the anchor is invalidated with the geometry
	if _cached_reference_ms <= 0:
		_cached_reference_ms = _simulate(REFERENCE_CAR)
	return _cached_reference_ms


# Only the fields the benchmark actually reads. Anything else in a meta (names, model
# paths, ownership bookkeeping) would just fragment the cache.
static func _cache_key(meta: Dictionary) -> String:
	# The wheel widths are in the key because the model reads them: they set the contact
	# pressure the tire load-sensitivity term works off (LapTimeModel._load_factor), so two
	# otherwise identical metas on different rubber are genuinely different laps. Omitting
	# them would serve one car's time for the other.
	var cfg: GameConfig = Config.data
	return "%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%d|%.4f|%.4f|%.4f|%s|%s" % [
		float(meta.get("mass", 1200.0)),
		float(meta.get("peak_torque", 0.0)),
		float(meta.get("redline", 0.0)),
		float(meta.get("tire_compound", 1.0)),
		float(meta.get("drag", 0.0)),
		float(meta.get("downforce_front", 0.0)),
		float(meta.get("downforce_rear", 0.0)),
		int(meta.get("drive_mode", CarLibrary.RWD)),
		float(meta.get("wheel_width_front", cfg.wheel_width_front)),
		float(meta.get("wheel_width_rear", cfg.wheel_width_rear)),
		# The GEARED TOP SPEED inputs (LapTimeModel._geared_top_speed_sq): the wheel radius
		# off the car, and the engine id standing in for the ratios + final drive that hang
		# off it. The engine id matters on its own account here — two cars identical in every
		# other field but wearing different gearboxes now genuinely lap differently, and an
		# engine SWAP has to re-solve rather than serve the pre-swap time.
		float(meta.get("wheel_radius", 0.0)),
		String(meta.get("engine", "")),
		_config_key(),
	]


static func _config_key() -> String:
	var cfg: GameConfig = Config.data
	# The two tire load-sensitivity tunables are in here for the same reason the traction
	# factors are: the benchmark reads them (LapTimeModel._load_factor), so retuning either
	# has to invalidate every cached rating rather than leaving stale numbers on screen.
	return "%.2f|%.2f|%.2f|%d|%.3f|%.3f|%.3f|%.4f|%.1f" % [
		cfg.benchmark_straight_m, cfg.benchmark_hairpin_radius_m,
		cfg.benchmark_sweeper_radius_m, cfg.benchmark_sweeper_count,
		cfg.traction_factor_rwd, cfg.traction_factor_awd, cfg.traction_factor_fwd,
		cfg.tire_load_sensitivity, cfg.tire_ref_pressure,
	]

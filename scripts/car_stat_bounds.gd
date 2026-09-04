class_name CarStatBounds
extends RefCounted
# The min/max each comparable car stat can reach ACROSS THE WHOLE ROSTER, so a stat bar
# means something absolute: a full Speed bar is "as fast as anything in this game", not
# "as fast as this car gets". Without a shared scale every car's bars would look the
# same and the page would tell the player nothing about how their car compares.
#
# The scale runs across the roster AS THE CARS SHIP — worst stock car to best stock car —
# because the question a bar answers is "how does this car compare with the others", and
# cars are what the player chooses between.
#
# The alternative, stretching the top of the scale to the best car at its fully-upgraded
# ceiling, was tried and is worse: the shipped roster's ceiling is roughly 2.5x its best
# stock car, so every early-game car collapsed into a single lit block and the page could
# not tell a hot hatch from a kei van — losing all resolution exactly where most of the
# game is played. A heavily-upgraded car simply pegs its bar at full instead, which reads
# as "top-tier" and is true; losing resolution at the very top costs far less.
#
# HEADROOM (the ghost segment) is measured on this same scale, so it still shows an early
# car how much of the roster it can climb.
#
# CACHED, because the sweep walks every car through effective_meta. It is invalidated by
# CarLibrary.override_for_test / reset — a test that installs synthetic cars but keeps
# stale bounds would draw bars against a scale from a different game. It used to be
# invalidated by UpgradeLibrary's seam too, when the bounds depended on a second authored
# roster (the parts catalogue); that catalogue is deleted (todo/roguelike-pivot.md), so
# there is one roster and one invalidator.

# Grip is speed-dependent (downforce grows with v²), so its bounds are rated at the same
# reference speed the Grip readout quotes. Read from GameConfig.grip_reference_kmh — the
# single source both this sweep and any grip readout read — so the bounds can't be
# computed at one speed and displayed at another.

# How far below the worst car the scale's zero sits, as a fraction of the roster span.
# See _compute.
const FLOOR_PAD := 0.10

static var _cache: Dictionary = {}
# The GameConfig fingerprint the cached sweep was computed under. The RATING bound is a
# benchmark-lap solve whose track geometry and traction factors live in GameConfig, so a
# config edit mid-session must re-scale the bar — otherwise the rating cache correctly
# refreshes while the scale it is drawn against stays stale. Grip's reference speed is
# folded in for the same reason.
static var _cache_key := ""


# {"rating": [lo, hi], "pw": [lo, hi], "grip": [lo, hi], "mass": [lo, hi]} in each stat's
# own units. Empty ranges (a one-car roster where lo == hi) are widened by the reader, not
# here — see `fraction`.
static func all() -> Dictionary:
	var key := _config_key()
	if _cache.is_empty() or _cache_key != key:
		_cache = _compute()
		_cache_key = key
	return _cache


# Drop the cached sweep. Called by the catalogue seams; harmless to call spuriously.
static func invalidate() -> void:
	_cache = {}
	_cache_key = ""


# Where `value` sits in `key`'s roster range, as 0..1. A degenerate range (a single car,
# or a synthetic test roster where every car is identical) returns 1.0 rather than
# dividing by zero — with nothing to compare against, "this is the whole range" is the
# only honest answer.
static func fraction(key: String, value: float) -> float:
	var range_pair: Array = all().get(key, [])
	if range_pair.size() != 2:
		return 0.0
	var lo := float(range_pair[0])
	var hi := float(range_pair[1])
	if hi - lo <= 0.0001:
		return 1.0
	return clampf((value - lo) / (hi - lo), 0.0, 1.0)


static func _compute() -> Dictionary:
	var cfg: GameConfig = Config.data
	var out := {"rating": [INF, -INF], "pw": [INF, -INF], "grip": [INF, -INF],
		"mass": [INF, -INF]}
	for entry in CarLibrary.all():
		var stock := UpgradeLibrary.effective_meta({}, entry)
		# The rating needs the grip-side fields too, which effective_meta drops — see
		# CarPerformance.merged_meta. Each call is a benchmark-lap solve, but memoised per
		# car by CarPerformance, so the whole sweep is paid once per config fingerprint.
		_widen(out["rating"], CarPerformance.rating(CarPerformance.merged_meta({}, entry)))
		_widen(out["pw"], CarLibrary.power_to_weight_hp_tonne(stock))
		_widen(out["grip"], CarLibrary.max_lateral_g(stock, cfg, cfg.grip_reference_kmh))
		_widen(out["mass"], float(stock.get("mass", 0.0)))
	for key in out:
		if float((out[key] as Array)[0]) > float((out[key] as Array)[1]):
			out[key] = [0.0, 0.0]   # empty roster: a scale with no cars on it
			continue
		# Drop the FLOOR a little below the worst car so it still lights one block. A car
		# sitting on an entirely empty bar reads as broken rather than as slow, and the
		# slowest car in the game is still a car. The top is left exactly on the best car,
		# so a full bar keeps meaning "nothing ships faster than this".
		var lo := float((out[key] as Array)[0])
		var hi := float((out[key] as Array)[1])
		(out[key] as Array)[0] = lo - (hi - lo) * FLOOR_PAD
	return out


# What the cached sweep depends on beyond the catalogue: the rating's own config inputs
# (shared with CarPerformance so the scale and the figures can't diverge) plus the speed
# the grip bound is rated at.
static func _config_key() -> String:
	return "%s|%.2f" % [CarPerformance.config_key(), Config.data.grip_reference_kmh]


static func _widen(pair: Array, value: float) -> void:
	if not is_finite(value):
		return
	pair[0] = minf(float(pair[0]), value)
	pair[1] = maxf(float(pair[1]), value)

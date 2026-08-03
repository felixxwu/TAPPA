class_name Crosswind
extends RefCounted
# The storm CROSSWIND profile: a lateral body force that pushes the car off line and
# must be steered against. See features/car-physics.md → "Crosswind".
#
# DETERMINISM IS THE POINT OF THIS FILE. The gust profile is a PURE function of
# (distance along the stage, event seed) — never `randf()`, never the clock, never a
# frame counter, and no RandomNumberGenerator state carried between ticks. Two runs of
# the same stage therefore feel the identical force at the identical point on the road.
# That is load-bearing: every stage has a GLOBAL leaderboard keyed by
# RallyLibrary.stage_key (features/global-leaderboards.md), and a wind that differed
# between runs would silently stop the board comparing like with like. Seeding by
# DISTANCE rather than time also makes gusts learnable — the same gust waits in the
# same place every attempt — which is fairer play as well as fairer scoring.
#
# The whole module is static and side-effect free, so the guarantee is trivially
# testable (tests/headless/test_crosswind.gd) rather than merely asserted.
#
# WHICH stages get wind is not decided here: a condition opts in by carrying a "wind"
# block in its WeatherLibrary entry, naming the GameConfig fields that supply the
# numbers. No condition id is ever tested by name — a condition with no "wind" block
# (dry, rain, fog, …) resolves to an EMPTY dict and the caller then does nothing at
# all, which is how a non-storm stage costs exactly zero.

# Keys a "wind" block names, each mapping to a GameConfig field.
const STRENGTH_KEY := "strength"
const GUST_KEY := "gust"
const DIR_KEY := "dir_deg"

# How many octaves the gust profile layers. Structural (the SHAPE of the sum), not a
# tunable magnitude — the amplitudes and wavelengths halve per octave, and the sum is
# normalised, so the result always lands in [-1, 1] whatever this is set to.
const OCTAVES := 3


# The wind parameters for the CURRENT condition, or an EMPTY dictionary when the
# condition has no wind at all. Resolve this ONCE per stage (see car.gd
# `_resolve_wind`) — it allocates and does dictionary lookups, so it must never run
# per physics tick.
static func wind_params(cfg: GameConfig) -> Dictionary:
	var block: Dictionary = WeatherLibrary.by_id(cfg.weather).get("wind", {})
	if block.is_empty():
		return {}
	return {
		STRENGTH_KEY: _config_value(cfg, block, STRENGTH_KEY),
		GUST_KEY: _config_value(cfg, block, GUST_KEY),
		DIR_KEY: _config_value(cfg, block, DIR_KEY),
	}


static func _config_value(cfg: GameConfig, block: Dictionary, key: String) -> float:
	var field := String(block.get(key, ""))
	if field == "":
		return 0.0
	var value: Variant = cfg.get(field)
	return float(value) if value != null else 0.0


# The world-space wind force at a point on the stage. `dir_deg` is a WORLD heading
# (0 = +X, 90 = +Z, matching the particle-field wind convention in WeatherLibrary), so
# the force keeps a fixed world direction and does not rotate with the car — which is
# what makes it something to be steered against rather than a drag term.
#
# PURE and STATIC: same arguments in, same vector out, always.
static func force_at(distance_m: float, seed_value: int, strength: float,
		gust: float, dir_deg: float, wavelength_m := 400.0) -> Vector3:
	return direction(dir_deg) * magnitude_at(
		distance_m, seed_value, strength, gust, wavelength_m)


# Unit heading vector for a wind direction in degrees. Cache this per stage rather
# than recomputing the trig every tick.
static func direction(dir_deg: float) -> Vector3:
	var rad := deg_to_rad(dir_deg)
	return Vector3(cos(rad), 0.0, sin(rad))


# Signed force magnitude along `direction()`. `strength` is the steady component and
# `gust` the amplitude of a smooth, seeded profile in [-1, 1] layered over it — so
# with gust <= strength the wind never reverses, and above it, it does. Smooth
# (layered sines) rather than stepped, so a gust builds and eases instead of snapping.
static func magnitude_at(distance_m: float, seed_value: int, strength: float,
		gust: float, wavelength_m: float) -> float:
	if gust == 0.0:
		return strength
	var wl := wavelength_m if wavelength_m > 0.0 else 1.0
	var amp := 1.0
	var sum := 0.0
	var norm := 0.0
	for k in OCTAVES:
		sum += amp * sin(TAU * distance_m / wl + _phase(seed_value, k))
		norm += amp
		amp *= 0.5
		wl *= 0.5
	return strength + gust * (sum / norm)


# A stable phase offset per (seed, octave): an integer hash, not an RNG, so there is
# no stream state to get out of step and evaluation order can never matter.
static func _phase(seed_value: int, k: int) -> float:
	var h := (seed_value * 2654435761 + (k + 1) * 2246822519) & 0x7FFFFFFF
	h = ((h ^ (h >> 15)) * 668265263) & 0x7FFFFFFF
	h = (h ^ (h >> 13)) & 0x7FFFFFFF
	return float(h) / float(0x80000000) * TAU

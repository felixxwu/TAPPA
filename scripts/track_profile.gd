class_name TrackProfile
extends RefCounted
# Docs: features/track.md — update in the same change as this file.
# Tests: tests/headless/test_track_profile.gd, tests/headless/test_track_generator.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'TrackProfile' tests/headless/` and read the assertions that pin what you are about to change.
#
# The track's VERTICAL channel: a signed height offset (m) keyed on arc distance
# along the centerline, added on top of the terrain noise height when the road is
# baked. Today it carries exactly one feature — the JUMP crest.
#
# Pure static functions over arc distance, deliberately the same shape as
# TrackSurface.tarmac_weight(dist, ...): scene-free, allocation-light, unit-testable,
# and consumed by BOTH the look (terrain bake) and the feel (the car actually leaves
# the ground, because the collision heightmap derives from the same field).
#
# WHY A RAISED COSINE. The crest must join the surrounding terrain-following road at
# grade, or the bake puts a step in the road. y = h/2 * (1 + cos(2*PI*x/L)) over
# x in [-L/2, L/2] is zero in BOTH value and slope at each end, so the crest is
# self-contained inside its piece and no neighbouring corner is disturbed.
#
# WHY IT LAUNCHES THE CAR. A car leaves the ground when the road's downward curvature
# outruns gravity: v^2 * kappa > g. The apex curvature of the cosine above is
# kappa = (h/2) * (2*PI/L)^2 = 2*PI^2*h / L^2, so the launch threshold is
#
#     v_launch = sqrt(g/kappa) = (L/PI) * sqrt(g / (2h))
#
# — see launch_speed(). That single number is the design lever: it is what makes a
# jump one that FAST cars clear and slow ones merely get light over. Note L matters
# far more than h (it is squared, and on the numerator): a LONGER crest of the same
# height is a HARDER launch to trigger, not an easier one.

# The CornerLibrary corner that carries a crest. Kept here rather than in the
# generator so the vocabulary and the vertical channel name the shape once.
const CORNER_NAME := "Jump"

# Arc length (m) of the authored Jump corner's 2D curve — the piece the crest lives
# inside. MUST match the CornerLibrary "Jump" entry's straight-line length; the crest
# span is clamped to it so a mis-set config knob can never bleed the crest into the
# neighbouring pieces. test_track_profile pins the two together.
const PIECE_LENGTH_M := 60.0

const GRAVITY := 9.81


# Plan the crests for a generated track. One entry per Jump piece, centred on that
# piece's own 2D curve, as { "center_m", "height_m", "span_m" } in centerline arc
# distance. Mirrors Pacenotes.build / SignLayout.plan: the corner starts after the
# piece's connecting straight, and the arc offset comes from get_closest_offset.
#
# Pass the SAME centerline the terrain bake receives (world.gd bakes the runoff-
# extended curve). The runoff is appended past the finish, so offsets measured from
# the start are identical either way — but planning against the baked curve keeps
# that a fact rather than a coincidence.
static func plan(centerline: Curve2D, pieces: Array, height_m: float, span_m: float) -> Array:
	var out: Array = []
	if centerline == null or centerline.get_baked_length() <= 0.0:
		return out
	if height_m <= 0.0 or span_m <= 0.0:
		return out
	var span := minf(span_m, PIECE_LENGTH_M)
	for piece in pieces:
		if String(piece.get("corner", "")) != CORNER_NAME:
			continue
		var entry_pos: Vector2 = piece.get("entry_pos", Vector2.ZERO)
		var entry_heading: Vector2 = piece.get("entry_heading", Vector2(0.0, 1.0))
		var corner_entry := entry_pos + entry_heading.normalized() * float(piece.get("straight", 0.0))
		out.append({
			"center_m": centerline.get_closest_offset(corner_entry) + PIECE_LENGTH_M * 0.5,
			"height_m": height_m,
			"span_m": span,
		})
	return out


# Height offset (m) to ADD to the terrain noise height at arc distance `s`. Zero
# everywhere outside a crest, so an empty plan is a free no-op — which is the common
# case (most stages draw no jump at all) and why this is safe to call per road vertex.
static func offset_at(s: float, jumps: Array) -> float:
	var h := 0.0
	for j in jumps:
		var span := float(j.get("span_m", 0.0))
		if span <= 0.0:
			continue
		var dx: float = s - float(j.get("center_m", 0.0))
		if absf(dx) >= span * 0.5:
			continue
		h += float(j.get("height_m", 0.0)) * 0.5 * (1.0 + cos(TAU * dx / span))
	return h


# Speed (m/s) above which a car goes airborne over a crest of this height and span.
# Below it the car stays planted and merely gets light. See the header derivation.
# Returns INF for a degenerate crest (no height), which reads correctly as "never
# launches" at every call site.
static func launch_speed(height_m: float, span_m: float) -> float:
	if height_m <= 0.0 or span_m <= 0.0:
		return INF
	return (span_m / PI) * sqrt(GRAVITY / (2.0 * height_m))

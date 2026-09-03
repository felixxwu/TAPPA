extends RefCounted
class_name TrackFixtures

# Synthetic centerlines for tests that exercise LapTimeModel, so no test has to reach
# into a generated track or the authored catalogue. Promoted out of
# test_lap_time_model.gd for reuse across the track-generation test files — see
# features/testing.md. Every helper returns the {"centerline", "pieces"} dict shape the
# model consumes.


# A dead-straight track of `length` metres. Curve points are Vector2(world_x, world_z).
static func straight(length: float) -> Dictionary:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(0, -length))
	return {"centerline": c, "pieces": []}


# A circular arc approximated by densely sampled POINTS with no Bezier handles — all
# turning lives at the vertices. Cheap and adequate for "is a corner slower than a
# straight" style assertions.
static func arc(radius: float, sweep_rad: float, steps := 64) -> Dictionary:
	var c := Curve2D.new()
	for i in steps + 1:
		var a := sweep_rad * float(i) / float(steps)
		c.add_point(Vector2(radius * sin(a), -radius * (1.0 - cos(a))))
	return {"centerline": c, "pieces": []}


# A circular arc built the way track_generator builds real track: FEW points carrying
# real Bezier in/out handles, so the curve genuinely curves between its points.
#
# This is the only shape that can expose curvature loss when a curve is resampled into
# a handle-free polyline — `arc()` above is already handle-free at ~2 m spacing, so
# resampling it is near-lossless by construction and would let a broken resample pass.
# Handle length is the standard circular-arc approximation, (4/3)·tan(dθ/4)·r.
static func handled_arc(radius: float, sweep_rad: float, steps := 8) -> Dictionary:
	var c := Curve2D.new()
	var dtheta := sweep_rad / float(steps)
	var h := radius * (4.0 / 3.0) * tan(dtheta / 4.0)
	for i in steps + 1:
		var a := dtheta * float(i)
		var pos := Vector2(radius * sin(a), -radius * (1.0 - cos(a)))
		var tangent := Vector2(cos(a), -sin(a))
		c.add_point(pos, -tangent * h, tangent * h)
	return {"centerline": c, "pieces": []}


# A straight run into a sustained corner — a stage with both regimes, so a test can ask
# where a degraded driver actually loses the time.
static func straight_then_arc(straight_len: float, radius: float, sweep_rad: float) -> Dictionary:
	var c := Curve2D.new()
	c.add_point(Vector2(0, 0))
	c.add_point(Vector2(0, -straight_len))
	var steps := 48
	for i in range(1, steps + 1):
		var a := sweep_rad * float(i) / float(steps)
		c.add_point(Vector2(radius * sin(a), -straight_len - radius * (1.0 - cos(a))))
	return {"centerline": c, "pieces": []}


# Attach synthetic turn boundaries to a track dict. RallyLibrary.derive_turn_splits reads
# `pieces[i + 1].entry_pos` to find where each placed turn ends, so a track with no pieces
# yields no split boundaries at all — which silently makes any "the popup got its
# boundaries" assertion vacuous.
static func with_pieces(track: Dictionary, count := 4) -> Dictionary:
	var curve := track["centerline"] as Curve2D
	var length := curve.get_baked_length()
	var pieces: Array = []
	for i in count:
		var off := length * float(i) / float(count)
		pieces.append({"entry_pos": curve.sample_baked(off)})
	var out := track.duplicate()
	out["pieces"] = pieces
	return out

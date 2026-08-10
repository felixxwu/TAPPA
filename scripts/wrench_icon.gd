class_name WrenchIcon
extends RefCounted
# The drawn wrench that opens a stat row's own corner of the Advanced upgrades page.
#
# Drawn rather than typed for the same reason the price star is (see PolygonIcon): the UI
# font has no 🔧, and the web export has no system font to borrow one from, so a glyph
# would be a tofu box on mobile web. It also has to ride a Button's `icon`, and a Button
# lays out no children.
#
# An OPEN-ENDED SPANNER — a ROUND head with a jaw bitten out of it, on a shaft with a
# rounded tail, laid at a DIAGONAL. Three deliberate choices, all about the ~15px it is
# read at:
#   * round head, not square — the circular boss is what says "spanner" rather than
#     "letter T", and a curve survives the antialiasing at this size where a corner does
#     not;
#   * diagonal, not upright — an upright tool reads as a screwdriver or an exclamation
#     mark against a row of text, and the diagonal is the pose every tool icon in the
#     wild uses because it fills a square box with the longest possible silhouette;
#   * a spanner, not a gear — a gear reads as "settings", which is a different promise
#     from "change this part of the car".
#
# The outline is generated rather than authored point-by-point (see `_points`) so the
# proportions stay adjustable: hand-listed vertices would have to be re-derived by eye
# every time the head or the shaft changed.

# The house size, matching the 16px caps (UITheme.FONT_SIZE) it sits beside. The
# proportions below are tuned AT THIS SIZE — a thinner shaft or a longer one looks fine
# blown up and disappears into the antialiasing at 16px.
const HEIGHT := 16.0

# Proportions, in units of the head's radius. The silhouette is normalised to fit its own
# bounding box afterwards, so these are pure shape, not size.
const HEAD_RADIUS := 0.50
const JAW_HALF_WIDTH := 0.22    # half the opening across the jaw's mouth
const JAW_DEPTH := 0.10         # how far past the head's centre the jaw is bitten (y down)
const SHAFT_HALF_WIDTH := 0.20
const SHAFT_LENGTH := 1.12      # head centre to the tail's rounded tip
const TILT_DEGREES := -40.0     # laid diagonally, jaw pointing up and to the right
const ARC_STEPS := 28           # segments around the head; enough that 15px reads smooth
const TAIL_STEPS := 10


static func texture(height := HEIGHT, color := UITheme.INK) -> ImageTexture:
	return PolygonIcon.texture("wrench|%.2f" % height,
		_points(height * PolygonIcon.SUPERSAMPLES), color)


# The silhouette, as ONE closed polygon (PolygonIcon fills a single polygon, so the head
# and the shaft have to be traced as a single outline rather than unioned).
#
# Traced clockwise in screen space (y down), starting at the right-hand lip of the jaw:
# around the head to where the shaft meets it, out along the shaft's right side, round the
# tail, back up its left side, on around the head to the jaw's left lip, and finally across
# the jaw's mouth to close.
static func _points(size: float) -> PackedVector2Array:
	var r := HEAD_RADIUS
	# Where the jaw's faces and the shaft's sides meet the head's circle. Solving for the
	# circle's own y at those x keeps the straight edges flush with the curve instead of
	# leaving a step where they join.
	var jaw_y := -sqrt(maxf(r * r - JAW_HALF_WIDTH * JAW_HALF_WIDTH, 0.0))
	var shaft_y := sqrt(maxf(r * r - SHAFT_HALF_WIDTH * SHAFT_HALF_WIDTH, 0.0))
	var jaw_angle := atan2(jaw_y, JAW_HALF_WIDTH)          # right lip of the jaw
	var shaft_angle := atan2(shaft_y, SHAFT_HALF_WIDTH)    # right side of the shaft
	var pts: Array = []

	# Head: jaw's right lip round to the shaft's right side.
	_arc(pts, jaw_angle, shaft_angle, r)
	# Shaft's right side, down to the tail.
	pts.append(Vector2(SHAFT_HALF_WIDTH, SHAFT_LENGTH))
	# Rounded tail, right to left.
	for i in range(1, TAIL_STEPS):
		var a := lerpf(0.0, PI, float(i) / float(TAIL_STEPS))
		pts.append(Vector2(cos(a) * SHAFT_HALF_WIDTH,
			SHAFT_LENGTH + sin(a) * SHAFT_HALF_WIDTH))
	# Shaft's left side, back up to the head.
	pts.append(Vector2(-SHAFT_HALF_WIDTH, SHAFT_LENGTH))
	# Head: shaft's left side round to the jaw's left lip.
	_arc(pts, PI - shaft_angle, PI - jaw_angle, r)
	# The jaw itself — down one face, across the back of the mouth, and up the other.
	pts.append(Vector2(-JAW_HALF_WIDTH, JAW_DEPTH))
	pts.append(Vector2(JAW_HALF_WIDTH, JAW_DEPTH))

	return _fit(pts, size)


# Append the arc from `from` to `to` (radians, increasing = clockwise in screen space).
static func _arc(pts: Array, from: float, to: float, radius: float) -> void:
	var span := to - from
	var steps: int = maxi(2, roundi(ARC_STEPS * absf(span) / TAU))
	for i in steps + 1:
		var a := from + span * float(i) / float(steps)
		pts.append(Vector2(cos(a) * radius, sin(a) * radius))


# Tilt the silhouette, then scale it so its LONGEST axis is exactly `size`. Normalising
# after the rotation is what keeps the icon the same visual weight as the tilt is tuned —
# scaling first would leave the rotated shape overflowing its nominal box.
static func _fit(pts: Array, size: float) -> PackedVector2Array:
	var tilt := deg_to_rad(TILT_DEGREES)
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var turned: Array = []
	for p in pts:
		var q: Vector2 = (p as Vector2).rotated(tilt)
		turned.append(q)
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
		hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
	var extent := maxf(maxf(hi.x - lo.x, hi.y - lo.y), 0.0001)
	var out := PackedVector2Array()
	for q in turned:
		out.append((q as Vector2) * size / extent)
	return out

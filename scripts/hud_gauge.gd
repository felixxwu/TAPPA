class_name HudGauge
extends Control
# One in-run HUD gauge: a radial fill clipped to a SQUARE, with its icon in the middle
# (features/hud.md). Replaces the linear `ProgressBar` each of health / boost / NOS used
# to be — a dial is read at a glance from the corner of your eye in a way a bar of a
# given length is not, and the square keeps it in the house's orthogonal language instead
# of dropping a lone circle into a UI with no rounded corners anywhere else.
#
# It fills like a pie: the sweep starts at 12 o'clock and runs clockwise, but every point
# is projected onto the perimeter of a SQUARE, so the fill hugs the box and turns hard
# corners rather than describing a circle. The projection is exact, not sampled — between
# two corners the perimeter is a straight line, so one quad per corner-to-corner span
# reproduces the shape with no tessellation error at any size.
#
# It is a RING, not a solid pie, and that is load-bearing: on a solid pie the wedge sweeps
# UNDER the icon, so the icon sits on bright fill at one value and on empty track at the
# next and its contrast changes continuously while you drive. Putting the icon in the hole
# — over the gauge's own black plate — means it always reads the same. The hole is also
# the same negative-gap device the glyphs themselves use (gauge_icons.gd).
#
# The owner (hud.gd) sets `value` and `fill_color` and hides the node outright when the
# part isn't fitted. Both setters change-gate their own redraw, so assigning an unchanged
# value each frame costs nothing.

# Wall thickness as a fraction of the gauge's side: one 4-unit module on the icons' 24
# grid, so the ring stays in proportion with the glyph it frames at any size.
const RING_FRAC := GaugeIcons.MODULE / GaugeIcons.GRID
# Icon size as a fraction of the side. Sized to sit inside the hole with a clear margin
# rather than filling it, so the ring and the glyph don't optically merge.
const ICON_FRAC := 0.30
# The unfilled remainder, drawn at low alpha over the backing. An empty gauge still shows
# WHERE it is — otherwise a spent NOS tank and a car with no NOS fitted look identical.
const TRACK_ALPHA := 0.13
# Solid black plate behind the whole gauge, so the ring and the icon sit on a known
# ground instead of on the moving road. Without it the icon's contrast changes with
# whatever is driving past underneath, which is the same failure the ring was chosen to
# avoid in the first place. Pure black, per the design system's house rule for UI
# backgrounds (ui_theme.gd).
const BACKING := Color(0.0, 0.0, 0.0, 1.0)

# Sweep geometry. Clockwise from 12 o'clock; the corner angles are where the square's
# perimeter changes direction, and inserting them exactly is what keeps the fill sharp.
const _START := -PI * 0.5
const _CORNERS: Array[float] = [-PI * 0.25, PI * 0.25, PI * 0.75, PI * 1.25]

@export var icon: GaugeIcons.Kind = GaugeIcons.Kind.HEALTH:
	set(v):
		icon = v
		queue_redraw()

# Fill fraction, 0..1. Clamped on draw so a caller can't tear the polygon with a stray
# value; stored raw so round-tripping through the property is lossless.
var value := 0.0:
	set(v):
		if is_equal_approx(value, v):
			return
		value = v
		queue_redraw()

# The fill tint. Health grades this green→red with remaining HP and drops its ALPHA to
# pulse the low-HP warning; because the icon is drawn separately in ink, the pulse no
# longer drags the caption's colour with it the way `self_modulate` on the old bar did.
var fill_color := Color.WHITE:
	set(v):
		if fill_color == v:
			return
		fill_color = v
		queue_redraw()


func _init() -> void:
	# Purely a readout: never take focus or swallow a tap meant for the mobile controls.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


func _draw() -> void:
	var side := minf(size.x, size.y)
	if side <= 0.0:
		return
	var centre := size * 0.5
	var half := side * 0.5
	var inner := maxf(0.0, half - side * RING_FRAC)
	# Black plate first, covering the hole as well as the ring, so everything drawn after
	# it reads against the same ground whatever the car is driving over.
	draw_rect(Rect2(centre - Vector2(half, half), Vector2(side, side)), BACKING)
	var track := UITheme.INK
	track.a = TRACK_ALPHA
	_draw_ring(centre, half, inner, TAU, track)
	var frac := clampf(value, 0.0, 1.0)
	if frac > 0.0:
		_draw_ring(centre, half, inner, TAU * frac, fill_color)
	GaugeIcons.draw_into(self, icon, centre, side * ICON_FRAC, UITheme.INK)


# One square annulus sector, from 12 o'clock clockwise through `sweep` radians. Emitted
# as a quad per corner-to-corner span: both the outer and inner edges are straight over
# such a span (the squares are concentric and axis-aligned, so they share corner angles),
# which makes each quad convex — the only thing `draw_colored_polygon` renders correctly.
func _draw_ring(centre: Vector2, half: float, inner: float, sweep: float, color: Color) -> void:
	if sweep <= 0.0 or half <= 0.0:
		return
	var end := _START + sweep
	var angles: Array[float] = [_START]
	for corner in _CORNERS:
		if corner < end:
			angles.append(corner)
	angles.append(end)
	var quad := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	for i in range(angles.size() - 1):
		var a0 := angles[i]
		var a1 := angles[i + 1]
		if a1 - a0 <= 0.0001:
			continue
		quad[0] = _perimeter(centre, half, a0)
		quad[1] = _perimeter(centre, half, a1)
		quad[2] = _perimeter(centre, inner, a1)
		quad[3] = _perimeter(centre, inner, a0)
		draw_colored_polygon(quad, color)


# Where the ray at `angle` leaves a square of half-extent `half` centred on `centre`.
# Scaling the unit direction by half / max(|x|, |y|) lands exactly on the perimeter — the
# square analogue of multiplying by a radius.
static func _perimeter(centre: Vector2, half: float, angle: float) -> Vector2:
	var dir := Vector2(cos(angle), sin(angle))
	var reach := maxf(absf(dir.x), absf(dir.y))
	if reach <= 0.0:
		return centre
	return centre + dir * (half / reach)

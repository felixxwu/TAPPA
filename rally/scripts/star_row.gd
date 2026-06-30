class_name StarRow
extends Control
# A row of `total` five-pointed stars, the first `earned` filled gold (UITheme.GOLD)
# and the rest dim (UITheme.MUTED) — the design-system readout for a rally's medal
# tier. It replaces the old 3D sphere "stars" on the HQ map pins, and is drawn with
# polygons in `_draw` so it needs no font glyph (Syne Mono has no ★/☆, the reason the
# UI used spheres / ASCII before). Drop it in any Control layout, then call `setup`.

const POINTS := 5          # five-pointed star
const INNER_RATIO := 0.42  # inner vertex radius as a fraction of the outer radius

var earned := 0
var total := 3
var star_radius := 11.0    # outer radius of each star (px)
var gap := 7.0             # gap between stars (px)


# Set how many of how many stars are lit and size the control to fit the row.
func setup(p_earned: int, p_total: int) -> void:
	earned = p_earned
	total = p_total
	var gaps: int = maxi(0, total - 1)
	var w := total * star_radius * 2.0 + gaps * gap
	custom_minimum_size = Vector2(w, star_radius * 2.0)
	queue_redraw()


func _draw() -> void:
	var inner := star_radius * INNER_RATIO
	var cy := size.y * 0.5
	for i in total:
		var cx := star_radius + i * (star_radius * 2.0 + gap)
		var col: Color = UITheme.GOLD if i < earned else UITheme.MUTED
		draw_colored_polygon(_star_points(Vector2(cx, cy), star_radius, inner), col)


# The 10 alternating outer/inner vertices of a five-pointed star, starting at the
# top point (-90°) and winding clockwise.
func _star_points(c: Vector2, outer: float, inner: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in POINTS * 2:
		var r := outer if k % 2 == 0 else inner
		var ang := -PI / 2.0 + k * PI / float(POINTS)
		pts.append(c + Vector2(cos(ang), sin(ang)) * r)
	return pts

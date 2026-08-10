class_name StarRow
extends Control
# A row of `total` five-pointed stars, the first `earned` filled gold (UITheme.GOLD)
# and the rest dim (UITheme.MUTED), or `earned_color` / `unearned_color` when a caller on a
# non-black surface overrides them — the design-system readout for a rally's medal
# tier. It replaces the old 3D sphere "stars" on the HQ map pins, and is drawn with
# polygons in `_draw` so it needs no font glyph (Syne Mono has no ★/☆, the reason the
# UI used spheres / ASCII before). Drop it in any Control layout, then call `setup`.

const POINTS := 5          # five-pointed star
const INNER_RATIO := 0.42  # inner vertex radius as a fraction of the outer radius

# --- Inline star PRICES (a star inside a text run) ----------------------------
# `texture` rasterises the same star to an ImageTexture, for the places that need one
# WHERE A CHILD CONTROL CAN'T GO: a star price on a Button ("SMALL 2*"), which has to
# ride the button's own `icon` because a Button lays out no children. Those labels used
# to carry the ★ CHARACTER, which looked fine on desktop only because the OS handed
# Godot a system fallback font — the WEB export has no system fonts, so every price
# rendered as a tofu box on mobile web. Same `_star_points` geometry as `_draw`, so an
# icon star and a medal-row star can't drift apart.

# The house size for an inline price star: sized to sit with the 16px house caps
# (UITheme.FONT_SIZE). One constant so every price star in the game matches — the upgrade
# option rows, the Repair button, the upgrades menu's balance row.
const PRICE_RADIUS := 6.5
const TEXTURE_SS := 3      # supersamples per axis when rasterising, for antialiased edges

# Rasterised stars by "radius|colour". Cached because the callers rebuild their rows on
# every press, and the raster never changes for a given radius/colour.
static var _textures: Dictionary = {}

var earned := 0
var total := 3
var star_radius := 11.0    # outer radius of each star (px)
var gap := 7.0             # gap between stars (px)
# Palette overrides for a row sitting on a NON-BLACK surface. The defaults (GOLD / MUTED)
# assume the design system's black panel; on the white accent panel a special-event map pin
# wears, gold-on-white barely reads and MUTED's 55%-alpha olive washes out entirely — so that
# caller recolours the row instead. null = use the design-system default.
var earned_color: Variant = null
var unearned_color: Variant = null


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
		var col: Color
		if i < earned:
			col = earned_color if earned_color != null else UITheme.GOLD
		else:
			col = unearned_color if unearned_color != null else UITheme.MUTED
		draw_colored_polygon(_star_points(Vector2(cx, cy), star_radius, inner), col)


# The house inline price star: gold, at PRICE_RADIUS. Hand it to `Button.icon` with
# `icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT` and the star lands after the digits, where
# the ★ character used to be — and Button's own `icon_disabled_color` dims it along with the
# label when the option isn't affordable yet, so an unbuyable price greys as one piece.
static func price_icon() -> ImageTexture:
	return texture(PRICE_RADIUS, UITheme.GOLD)


# A single filled star of the given outer radius (px) in `color`, as a cached texture.
# Rasterised by supersampling the star polygon, so its edges are antialiased rather than
# the hard staircase a 13px-tall hard-edged polygon would give.
static func texture(radius: float, color: Color) -> ImageTexture:
	var key := "%.2f|%s" % [radius, color.to_html(true)]
	if _textures.has(key):
		return _textures[key]
	# Lay the star out in SUPERSAMPLED space around the origin, then measure its bounding
	# box: a five-pointed star is not symmetric about its centre (it spans 1.0 outer radius
	# up but only ~0.81 down), so centring the polygon in the pixel grid — rather than
	# centring the circle it was generated from — is what stops the icon sitting visibly
	# high against the text baseline beside it.
	var outer := radius * TEXTURE_SS
	var pts := _star_points(Vector2.ZERO, outer, outer * INNER_RATIO)
	var lo := pts[0]
	var hi := pts[0]
	for p in pts:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var w: int = maxi(1, ceili((hi.x - lo.x) / TEXTURE_SS))
	var h: int = maxi(1, ceili((hi.y - lo.y) / TEXTURE_SS))
	var origin := lo - (Vector2(w, h) * TEXTURE_SS - (hi - lo)) * 0.5
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var samples := float(TEXTURE_SS * TEXTURE_SS)
	for y in h:
		for x in w:
			var hits := 0
			for sy in TEXTURE_SS:
				for sx in TEXTURE_SS:
					var p := origin + Vector2(x * TEXTURE_SS + sx + 0.5, y * TEXTURE_SS + sy + 0.5)
					if Geometry2D.is_point_in_polygon(p, pts):
						hits += 1
			img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * hits / samples))
	var tex := ImageTexture.create_from_image(img)
	_textures[key] = tex
	return tex


# The 10 alternating outer/inner vertices of a five-pointed star, starting at the
# top point (-90°) and winding clockwise. Static so `texture` shares the exact geometry
# `_draw` uses.
static func _star_points(c: Vector2, outer: float, inner: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for k in POINTS * 2:
		var r := outer if k % 2 == 0 else inner
		var ang := -PI / 2.0 + k * PI / float(POINTS)
		pts.append(c + Vector2(cos(ang), sin(ang)) * r)
	return pts

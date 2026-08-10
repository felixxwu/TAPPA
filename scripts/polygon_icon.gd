class_name PolygonIcon
extends RefCounted
# Rasterise a flat polygon to a small ImageTexture, antialiased and cached.
#
# This exists because the UI font (Syne Mono) has no symbol glyphs, and the WEB export has
# no system fonts to fall back on — a ★ or a 🔧 in a label renders as a tofu box on mobile
# web even when it looks fine on desktop. Anywhere an icon has to ride a Button's own
# `icon` property (a Button lays out no children, so a drawn child Control is not an
# option), it has to be a texture, and drawing it ourselves is what keeps it a texture we
# can recolour and resize.
#
# Extracted from StarRow, which had the only copy; the wrench on the simple upgrades page
# needed the same rasteriser, and two hand-rolled supersamplers would drift.

const SUPERSAMPLES := 3   # samples per axis; enough to soften a ~16px silhouette

# Rasters by cache key. Cached because callers rebuild their rows on every press and the
# raster never changes for a given shape/size/colour.
static var _textures: Dictionary = {}


# `points` is the silhouette in arbitrary units; it is measured, centred and scaled so the
# result is exactly the polygon's own bounding box at `scale_px` units per unit. `key` must
# identify the SHAPE — callers append their own size/colour, which this adds for them.
#
# Centring on the polygon's measured bounds rather than on the coordinate origin is what
# stops an asymmetric shape (a five-pointed star spans 1.0 up but only ~0.81 down) sitting
# visibly high against the text beside it.
static func texture(key: String, points: PackedVector2Array, color: Color) -> ImageTexture:
	var full_key := "%s|%s" % [key, color.to_html(true)]
	if _textures.has(full_key):
		return _textures[full_key]
	var lo := points[0]
	var hi := points[0]
	for p in points:
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var w: int = maxi(1, ceili((hi.x - lo.x) / SUPERSAMPLES))
	var h: int = maxi(1, ceili((hi.y - lo.y) / SUPERSAMPLES))
	var origin := lo - (Vector2(w, h) * SUPERSAMPLES - (hi - lo)) * 0.5
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var samples := float(SUPERSAMPLES * SUPERSAMPLES)
	for y in h:
		for x in w:
			var hits := 0
			for sy in SUPERSAMPLES:
				for sx in SUPERSAMPLES:
					var p := origin + Vector2(
						x * SUPERSAMPLES + sx + 0.5, y * SUPERSAMPLES + sy + 0.5)
					if Geometry2D.is_point_in_polygon(p, points):
						hits += 1
			img.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * hits / samples))
	var tex := ImageTexture.create_from_image(img)
	_textures[full_key] = tex
	return tex

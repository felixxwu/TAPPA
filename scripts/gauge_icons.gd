class_name GaugeIcons
extends RefCounted
# Glyph geometry for the three in-run HUD gauges (features/hud.md): health, boost
# pressure and NOS. These replaced the `HEALTH` / `BOOST` / `NITROUS` text captions that
# used to sit inside the old linear bars — at a glance an icon reads faster than a word,
# and it survives being shrunk in a way 11px type does not.
#
# All three are authored on a 24-unit square with a 4-unit module: every edge lands on a
# multiple of MODULE, every negative gap is exactly one MODULE wide, corners are square
# (design-system house rule: no rounded corners), and each glyph is ONE flat fill with no
# outline. That shared construction is what makes them read as a set rather than three
# unrelated pictures — so if you add a fourth gauge, author it to the same grid.
#
# Consumers get triangles, not outlines. `draw_colored_polygon` only renders CONVEX
# polygons correctly, and two of these glyphs are concave (the cross, the bottle) while
# the third is a disc with a slot cut out of it. So each glyph is triangulated ONCE and
# cached in unit space, then scaled at draw time — see `draw_into`.

enum Kind { HEALTH, BOOST, NOS }

# The authoring grid. Geometry below is in these units; `draw_into` scales it.
const GRID := 24.0
const MODULE := 4.0

# Segment count for the boost dial's rim. 48 is smooth at every size the HUD uses and
# keeps the triangulated glyph small; the rim is the only curve in the whole set.
const _DISC_SEGMENTS := 48

# Triangulated glyphs in GRID space, keyed by Kind. Built on first use and shared by
# every gauge — the geometry is constant, so paying for it per-instance would be waste.
static var _cache: Dictionary = {}


# Triangle soup for `kind`, in GRID space: 3 vertices per triangle, so size() is a
# multiple of 3. Empty only if triangulation somehow fails, which callers must tolerate.
static func triangles(kind: Kind) -> PackedVector2Array:
	if _cache.has(kind):
		return _cache[kind]
	var tris := PackedVector2Array()
	for poly: PackedVector2Array in _outlines(kind):
		var idx := Geometry2D.triangulate_polygon(poly)
		# A failed triangulation returns empty rather than erroring; skipping the piece
		# loses that shape but must not take the whole HUD down mid-run.
		for i in idx:
			tris.push_back(poly[i])
	_cache[kind] = tris
	return tris


# Draw `kind` centred on `centre`, `px` wide and tall, in `color`. One draw call per
# triangle: the glyphs are a couple of dozen triangles each and gauge redraws are
# change-gated by the caller, so this is nowhere near hot.
static func draw_into(ci: CanvasItem, kind: Kind, centre: Vector2, px: float, color: Color) -> void:
	var tris := triangles(kind)
	if tris.is_empty() or px <= 0.0:
		return
	var scale := px / GRID
	var origin := centre - Vector2(px, px) * 0.5
	var tri := PackedVector2Array([Vector2.ZERO, Vector2.ZERO, Vector2.ZERO])
	for i in range(0, tris.size() - 2, 3):
		tri[0] = origin + tris[i] * scale
		tri[1] = origin + tris[i + 1] * scale
		tri[2] = origin + tris[i + 2] * scale
		ci.draw_colored_polygon(tri, color)


# The glyphs as closed outlines, already cut. Each entry is a separate filled piece.
static func _outlines(kind: Kind) -> Array:
	match kind:
		Kind.HEALTH:
			# A cross bleeding to all four edges: arms 2 modules thick on 2-module stubs.
			# Deliberately the only glyph with no interior gap — at the smallest HUD size
			# a solid cross is the shape most likely to survive.
			return [PackedVector2Array([
				Vector2(8, 0), Vector2(16, 0), Vector2(16, 8), Vector2(24, 8),
				Vector2(24, 16), Vector2(16, 16), Vector2(16, 24), Vector2(8, 24),
				Vector2(8, 16), Vector2(0, 16), Vector2(0, 8), Vector2(8, 8),
			])]
		Kind.NOS:
			# A pressure bottle: 1-module valve, 1-module shoulder chamfer, 3-module body.
			# Left as one unbroken silhouette — a label band across the body was the first
			# detail to muddy at gauge size, and the profile alone carries the read.
			return [PackedVector2Array([
				Vector2(10, 0), Vector2(14, 0), Vector2(14, 4), Vector2(16, 4),
				Vector2(18, 8), Vector2(18, 24), Vector2(6, 24), Vector2(6, 8),
				Vector2(8, 4), Vector2(10, 4),
			])]
		_:
			# Boost: a dial with the needle cut OUT as a 1-module slot swept to the upper
			# right, where a boost gauge sits under load. Round on purpose — every pressure
			# instrument in a car is — which also keeps it from colliding with the cross.
			return Geometry2D.clip_polygons(_disc(), _needle())


# The dial rim, as a closed polygon.
static func _disc() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var centre := Vector2(GRID, GRID) * 0.5
	for i in _DISC_SEGMENTS:
		var a := TAU * float(i) / float(_DISC_SEGMENTS)
		pts.push_back(centre + Vector2(cos(a), sin(a)) * (GRID * 0.5))
	return pts


# The needle slot: a MODULE-wide bar on the 45° axis, running from the hub out PAST the
# rim so the cut reaches all the way through and the needle reads as open to the edge.
static func _needle() -> PackedVector2Array:
	var centre := Vector2(GRID, GRID) * 0.5
	var axis := Vector2(1, -1).normalized()          # up and to the right
	var side := Vector2(axis.y, -axis.x) * (MODULE * 0.5)
	var tip := centre + axis * (GRID * 0.58)         # past the rim, so the slot breaks it
	return PackedVector2Array([centre - side, tip - side, tip + side, centre + side])

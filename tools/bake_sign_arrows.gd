extends SceneTree
# Bakes the roadside turn-arrow sign faces (todo/roadside-signs.md). Each face is a
# rally pacenote board: a bold arrow whose bend follows the REAL corner shape from
# CornerLibrary (so the arrow literally encodes the turn intensity), with the corner
# grade tucked INTO the bend's concave side rather than stacked below it. One texture
# per turn type per direction (left/right mirror). Renders Control/Node2D into a
# SubViewport and grabs the image. Writes PNGs to textures/signs/:
#
#   xvfb-run -a godot --path rally --rendering-driver opengl3 \
#       --script tools/bake_sign_arrows.gd
#
# After baking, run `godot --headless --path rally --import` so the new PNGs gain
# their .import files (SignField loads them via load()).
# Re-run whenever the board art changes. Pure tooling.


const OUT := "res://textures/signs"
const TEX := 256              # square face, matches the square sign panel
const FACE_INSET := 12.0      # ink border thickness around the light-brown board

# Palette — the shared desert-rally look (light-brown board, dark ink).
const BOARD := Color("d7bd93")
const INK := Color("23211f")

# Layout — the arrow fills the whole face and the grade nests in the bend.
const ARROW_MARGIN := 0.03    # face fraction kept clear around the arrow
const LABEL_H_FRAC := 0.62    # single-char grade font size, as a face fraction
const LABEL_H_FRAC_WIDE := 0.44   # ...for 2-char glyphs ("SQ")
const LABEL_INSET := 0.06     # face fraction the grade keeps clear of the border
const MEASURE_BOX := 128      # scratch box the grade is rendered into to measure it
const LABEL_CLEARANCE := 0.55     # ink kept off the glyph, in stroke widths
const LABEL_STEPS := 12       # placement search resolution per axis
const ARROW_SHRINK := [1.0, 0.92, 0.84, 0.76, 0.68, 0.6]  # tried in order
# Radius of the blob marking the note's entry, in stroke half-widths — it reads as
# "the corner starts here" and anchors the tail of the bend.
const TAIL_DOT := 1.45

# Turn types that get a board, with the grade shown inside the bend. The arrow
# shape is pulled from CornerLibrary by name, so the bend matches the real corner.
# Square / Hairpin have no 1-6 grade, so they carry a short glyph instead.
#
# Grades 5 and 6 are gentle: the ROADSIDE signs skip them (SignLayout.TURN_CORNERS
# is "4 or sharper"), but the in-run HUD pacenote strip (features/hud.md) calls
# EVERY corner, so their boards are baked here for the HUD to reuse.
const SIGNS: Array[Dictionary] = [
	{"corner": "1", "key": "arrow_1", "label": "1"},
	{"corner": "2", "key": "arrow_2", "label": "2"},
	{"corner": "3", "key": "arrow_3", "label": "3"},
	{"corner": "4", "key": "arrow_4", "label": "4"},
	{"corner": "5", "key": "arrow_5", "label": "5"},
	{"corner": "6", "key": "arrow_6", "label": "6"},
	{"corner": "Square", "key": "arrow_square", "label": "SQ"},
	{"corner": "Hairpin", "key": "arrow_uturn", "label": "U"},
]


var _glyph_cache: Dictionary = {}   # "<text>@<font_size>" -> measured ink Rect2


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var gallery: Array[Dictionary] = []  # {name, img} for the contact sheet
	for sign in SIGNS:
		var poly := _corner_polyline(String(sign["corner"]))
		for flip in [false, true]:
			var dir := "left" if flip else "right"
			var tex_name := "%s_%s" % [sign["key"], dir]
			var img := await _bake_face(poly, String(sign["label"]), flip)
			img.save_png("%s/%s.png" % [OUT, tex_name])
			print("SAVED %s/%s.png" % [OUT, tex_name])
			gallery.append({"name": tex_name, "img": img})
	await _bake_contact_sheet(gallery)
	print("SIGN ARROWS DONE")
	quit()


# The corner centerline as a meter-space polyline (entry at origin, heading +Y).
func _corner_polyline(corner: String) -> PackedVector2Array:
	for spec in CornerLibrary.CORNERS:
		if String(spec["name"]) == corner:
			return CornerLibrary.build_curve(spec).tessellate()
	return PackedVector2Array([Vector2.ZERO, Vector2(0, 10)])


# Render one board face to an Image: light-brown board + ink border, the arrow filling
# the face, the grade nested in the concave side of the bend.
func _bake_face(poly: PackedVector2Array, label: String, flip: bool) -> Image:
	var size := Vector2i(TEX, TEX)
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)

	var root := Control.new()
	root.size = size
	vp.add_child(root)

	# Ink border, then the board face inset within it.
	_rect(root, Vector2.ZERO, size, INK)
	var face_pos := Vector2(FACE_INSET, FACE_INSET)
	var face_size := Vector2(TEX - 2.0 * FACE_INSET, TEX - 2.0 * FACE_INSET)
	_rect(root, face_pos, face_size, BOARD)

	# The arrow gets the WHOLE face; the grade then slots into whatever gap the bend
	# leaves (see _solve_layout), so the two sit close instead of in stacked bands.
	var arrow_box := Rect2(face_pos + face_size * ARROW_MARGIN,
		face_size * (1.0 - 2.0 * ARROW_MARGIN))
	var h_frac := LABEL_H_FRAC_WIDE if label.length() > 1 else LABEL_H_FRAC
	var font_size := int(face_size.y * h_frac)
	var ink := await _measure_glyph(label, font_size)
	var layout := _solve_layout(poly, arrow_box, flip,
		Rect2(face_pos, face_size), ink.size)

	var arrow := _ArrowDraw.new()
	arrow.geom = layout["geom"]
	arrow.color = INK
	root.add_child(arrow)

	# `layout.label` is where the glyph's INK goes; back out the Label box that puts it
	# there (a centred Label draws its line box, which is taller and wider than the ink).
	var glyph: Rect2 = layout["label"]
	_label(root, glyph.position - ink.position, Vector2(MEASURE_BOX, MEASURE_BOX),
		label, font_size, INK)

	await process_frame
	await process_frame
	var img := vp.get_texture().get_image()
	vp.queue_free()
	return img


# Fit the arrow as large as possible while still leaving a clear slot for the grade,
# and pick where that slot goes. Returns {"geom": arrow geometry, "label": Rect2}.
#
# The grade wants the bottom corner on the INSIDE of the bend (a left-bending arrow
# leaves its bottom-left free), which is what makes the arrow read as curving AROUND
# the number. Tight shapes that fill that corner — the hairpin, whose ink wraps both
# sides — fall back to the nearest free slot (its belly), and only if no slot is free
# at all does the arrow shrink.
func _solve_layout(poly: PackedVector2Array, box: Rect2, flip: bool, face: Rect2,
		glyph: Vector2) -> Dictionary:
	# Preferred glyph position: bottom corner on the inside of the bend, inset from
	# the border by the same margin the arrow keeps.
	var inset := face.size * LABEL_INSET
	var lo := face.position + inset
	var hi := face.position + face.size - inset - glyph
	var want := Vector2(lo.x if flip else hi.x, hi.y)

	var geom := {}
	for mul in ARROW_SHRINK:
		geom = _arrow_geometry(poly, box, flip, mul)
		var pad: float = float(geom["width"]) * LABEL_CLEARANCE
		var best := Vector2.INF
		var best_cost := INF
		for iy in LABEL_STEPS + 1:
			for ix in LABEL_STEPS + 1:
				var at := Vector2(lerpf(lo.x, hi.x, ix / float(LABEL_STEPS)),
					lerpf(lo.y, hi.y, iy / float(LABEL_STEPS)))
				if _ink_hits(geom, Rect2(at, glyph).grow(pad)):
					continue
				# Distance to the wanted corner, biased so a lower slot wins ties.
				var d := at - want
				var cost := d.x * d.x + d.y * d.y * 1.4
				if cost < best_cost:
					best_cost = cost
					best = at
		if best != Vector2.INF:
			return {"geom": geom, "label": Rect2(best, glyph)}
	# Nothing fits even at the smallest arrow — park the grade at the wanted corner.
	return {"geom": geom, "label": Rect2(want, glyph)}


# The DRAWN extent of `label` at `font_size`, as a Rect2 relative to the Label's own
# top-left. Measured by rendering the text and scanning the pixels rather than derived
# from font metrics: a Label's line box carries ascent/descent padding well outside the
# digit's ink, so metric-based placement leaves the grade visibly off-centre in its
# slot (and can push it under the border). Cached — there are only a handful of glyphs.
func _measure_glyph(label: String, font_size: int) -> Rect2:
	var key := "%s@%d" % [label, font_size]
	if _glyph_cache.has(key):
		return _glyph_cache[key]
	var vp := SubViewport.new()
	vp.size = Vector2i(MEASURE_BOX, MEASURE_BOX)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	var root := Control.new()
	root.size = Vector2(MEASURE_BOX, MEASURE_BOX)
	vp.add_child(root)
	_label(root, Vector2.ZERO, root.size, label, font_size, Color.WHITE)
	await process_frame
	await process_frame
	var img := vp.get_texture().get_image()
	vp.queue_free()

	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.5:
				lo = lo.min(Vector2(x, y))
				hi = hi.max(Vector2(x + 1, y + 1))
	if lo.x > hi.x:  # nothing drawn (shouldn't happen) — fall back to the line box
		return Rect2(Vector2.ZERO, Vector2(font_size, font_size))
	var ink := Rect2(lo, hi - lo)
	_glyph_cache[key] = ink
	return ink


# Screen-space geometry for the arrow: the corner polyline fitted (and optionally
# mirrored) into `box` at `mul` of its full size, plus the arrowhead triangle.
# Returns {"stroke": PackedVector2Array, "width": float, "head": PackedVector2Array}.
func _arrow_geometry(points: PackedVector2Array, box: Rect2, flip: bool,
		mul: float) -> Dictionary:
	if points.size() < 2:
		return {"stroke": PackedVector2Array(), "width": 1.0, "head": PackedVector2Array()}
	# Fit the meter-space polyline uniformly (preserve angles, so the bend still
	# reads as the true turn intensity).
	var lo := points[0]
	var hi := points[0]
	for p in points:
		lo = lo.min(p)
		hi = hi.max(p)
	var content := hi - lo
	var content_c := (lo + hi) * 0.5

	var width := maxf(box.size.x, box.size.y) * 0.11 * mul
	var radius := width * 0.5
	# The arrowhead + round end caps overshoot the centerline, so scale the polyline
	# into the box MINUS a uniform margin that reserves room for them — then the whole
	# drawn shape (not just the centerline) fits. Kept just big enough to contain the
	# arrowhead's perpendicular spread (~1.1·width).
	var margin := width * 1.15
	var avail := box.size - Vector2(margin, margin) * 2.0
	var scale: float = minf(avail.x / maxf(content.x, 0.001),
		avail.y / maxf(content.y, 0.001)) * mul

	var screen: PackedVector2Array = []
	for p in points:
		var dx := (p.x - content_c.x) * scale
		var dy := (p.y - content_c.y) * scale
		if flip:
			dx = -dx
		# +Y up in meters -> -Y on screen, so entry sits low and exit points up.
		screen.append(Vector2(dx, -dy))

	# Arrowhead at the exit, aligned to the last segment.
	var tip := screen[screen.size() - 1]
	var dir := (tip - screen[screen.size() - 2]).normalized()
	var perp := Vector2(-dir.y, dir.x)
	var head := width * 1.9
	var apex := tip + dir * head * 0.5
	var base1 := tip - dir * head * 0.5 + perp * head * 0.6
	var base2 := tip - dir * head * 0.5 - perp * head * 0.6

	# Centre the FULL drawn ink (shaft stroke + arrowhead), not just the centerline —
	# otherwise the arrow leans toward its arrowhead side.
	var ink_lo := screen[0]
	var ink_hi := screen[0]
	for p in screen:
		ink_lo = ink_lo.min(p)
		ink_hi = ink_hi.max(p)
	for p in [apex, base1, base2]:
		ink_lo = ink_lo.min(p)
		ink_hi = ink_hi.max(p)
	ink_lo -= Vector2(radius, radius)
	ink_hi += Vector2(radius, radius)
	var shift := box.position + box.size * 0.5 - (ink_lo + ink_hi) * 0.5
	for i in screen.size():
		screen[i] += shift
	return {
		"stroke": screen,
		"width": width,
		"head": PackedVector2Array([apex + shift, base1 + shift, base2 + shift]),
	}


# True if any of the arrow's drawn ink lands inside `rect`. The shaft is tested as a
# run of discs walked along the polyline (the same round-jointed stroke that gets
# drawn), the head as a barycentric sampling of its triangle.
func _ink_hits(geom: Dictionary, rect: Rect2) -> bool:
	var stroke: PackedVector2Array = geom["stroke"]
	var radius: float = float(geom["width"]) * 0.5
	var tail_r := radius * TAIL_DOT
	for i in stroke.size():
		var r := tail_r if i == 0 else radius
		if _disc_hits(stroke[i], r, rect):
			return true
		if i == 0:
			continue
		# Walk the segment so a long chord between tessellation points can't slip
		# through the rect between two discs.
		var seg := stroke[i] - stroke[i - 1]
		var steps := int(seg.length() / maxf(radius, 0.001)) + 1
		for s in range(1, steps):
			if _disc_hits(stroke[i - 1] + seg * (s / float(steps)), radius, rect):
				return true
	var head: PackedVector2Array = geom["head"]
	if head.size() == 3:
		var n := 5
		for a in n + 1:
			for b in n + 1 - a:
				var wa := a / float(n)
				var wb := b / float(n)
				var p := head[0] * wa + head[1] * wb + head[2] * (1.0 - wa - wb)
				if rect.has_point(p):
					return true
	return false


func _disc_hits(centre: Vector2, radius: float, rect: Rect2) -> bool:
	var closest := centre.clamp(rect.position, rect.position + rect.size)
	return centre.distance_squared_to(closest) <= radius * radius


# A 4x4 contact sheet of every baked face, for previewing all turn types at once.
func _bake_contact_sheet(gallery: Array[Dictionary]) -> void:
	var cols := 4
	var rows := int(ceil(gallery.size() / float(cols)))
	var tile := 200
	var gap := 18
	var label_h := 30
	var cell_w := tile + gap
	var cell_h := tile + label_h + gap
	var size := Vector2i(cols * cell_w + gap, rows * cell_h + gap)

	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	var root := Control.new()
	root.size = size
	vp.add_child(root)
	_rect(root, Vector2.ZERO, size, Color("4a4641"))

	for i in gallery.size():
		var col := i % cols
		var row := i / cols
		var x := gap + col * cell_w
		var y := gap + row * cell_h
		# Caption above the tile so it never overlaps the grade printed on the face.
		_label(root, Vector2(x, y), Vector2(tile, label_h),
			String(gallery[i]["name"]), 16, BOARD)
		var tr := TextureRect.new()
		tr.texture = ImageTexture.create_from_image(gallery[i]["img"])
		# IGNORE_SIZE or the rect's minimum size is the 256px texture and the tiles
		# overflow their cells into the row below.
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.position = Vector2(x, y + label_h)
		tr.size = Vector2(tile, tile)
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		root.add_child(tr)

	await process_frame
	await process_frame
	var img := vp.get_texture().get_image()
	var sheet := ProjectSettings.globalize_path("res://../sign_arrows_contact.png")
	img.save_png(sheet)
	print("SAVED contact sheet -> %s" % sheet)
	vp.queue_free()


# ---- helpers -----------------------------
func _rect(parent: Control, pos: Vector2, size: Vector2, col: Color) -> ColorRect:
	var r := ColorRect.new()
	r.position = pos
	r.size = size
	r.color = col
	parent.add_child(r)
	return r


func _label(parent: Control, pos: Vector2, size: Vector2, text: String,
		font_size: int, col: Color) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = size
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)
	return l


# Draws the arrow geometry solved by _arrow_geometry: a thick, round-jointed stroke
# with a fat entry blob at the tail and the head triangle at the exit.
class _ArrowDraw extends Node2D:
	var geom: Dictionary = {}
	var color := Color.BLACK

	func _draw() -> void:
		var stroke: PackedVector2Array = geom.get("stroke", PackedVector2Array())
		if stroke.size() < 2:
			return
		var radius: float = float(geom["width"]) * 0.5
		for i in range(1, stroke.size()):
			draw_line(stroke[i - 1], stroke[i], color, float(geom["width"]))
		for p in stroke:
			draw_circle(p, radius, color)
		draw_circle(stroke[0], radius * TAIL_DOT, color)
		var head: PackedVector2Array = geom.get("head", PackedVector2Array())
		if head.size() == 3:
			draw_colored_polygon(head, color)

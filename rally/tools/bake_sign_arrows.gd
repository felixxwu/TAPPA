extends SceneTree
# Bakes the roadside turn-arrow sign faces (todo/roadside-signs.md). Each face is a
# rally pacenote board: a bold arrow whose bend follows the REAL corner shape from
# CornerLibrary (so the arrow literally encodes the turn intensity), with the corner
# grade below it. One texture per turn type per direction (left/right mirror).
# Renders Control/Node2D into a SubViewport and grabs the image, like
# bake_finish_banners.gd. Writes PNGs to textures/signs/:
#
#   xvfb-run -a godot --path rally --rendering-driver opengl3 \
#       --script tools/bake_sign_arrows.gd
#
# After baking, run `godot --headless --path rally --import` so the new PNGs gain
# their .import files (SignField loads them via load(), like the finish banners).
# Re-run whenever the board art changes. Pure tooling.

const CornerLibrary = preload("res://scripts/corner_library.gd")

const OUT := "res://textures/signs"
const TEX := 256              # square face, matches the square sign panel
const FACE_INSET := 12.0      # ink border thickness around the cream board

# Palette — shared with the finish banners (bake_finish_banners.gd) for one look.
const CREAM := Color("f3e9d2")
const INK := Color("23211f")
const ORANGE := Color("d84a26")

# Turn types that get a board (SignLayout.TURN_CORNERS), with the grade shown below
# the arrow. The arrow shape is pulled from CornerLibrary by name, so the bend
# matches the real corner. Gentle 5s/6s are unsigned (too straight to need a board);
# Square / Hairpin have no 1-6 grade, so they carry a short glyph instead.
const SIGNS: Array[Dictionary] = [
	{"corner": "1", "key": "arrow_1", "label": "1"},
	{"corner": "2", "key": "arrow_2", "label": "2"},
	{"corner": "3", "key": "arrow_3", "label": "3"},
	{"corner": "4", "key": "arrow_4", "label": "4"},
	{"corner": "Square", "key": "arrow_square", "label": "SQ"},
	{"corner": "Hairpin", "key": "arrow_uturn", "label": "U"},
]


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


# Render one board face to an Image: cream board + ink border, the arrow up top
# following the corner shape, the grade label below.
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

	# Ink border, then the cream board face inset within it.
	_rect(root, Vector2.ZERO, size, INK)
	var face_pos := Vector2(FACE_INSET, FACE_INSET)
	var face_size := Vector2(TEX - 2.0 * FACE_INSET, TEX - 2.0 * FACE_INSET)
	_rect(root, face_pos, face_size, CREAM)

	# Arrow occupies the top ~57% of the board; the grade sits below. Tight margins
	# so the arrow fills most of the board.
	var arrow_box := Rect2(face_pos + Vector2(face_size.x * 0.05, face_size.y * 0.04),
		Vector2(face_size.x * 0.90, face_size.y * 0.55))
	var arrow := _ArrowDraw.new()
	arrow.points = poly
	arrow.box = arrow_box
	arrow.flip = flip
	arrow.color = INK
	root.add_child(arrow)

	# An orange rule between the arrow and the grade.
	var rule_y := face_pos.y + face_size.y * 0.62
	_rect(root, Vector2(face_pos.x + face_size.x * 0.18, rule_y),
		Vector2(face_size.x * 0.64, 6.0), ORANGE)

	# Grade label in the lower band, kept clear of the bottom border: the band stops
	# short of the face edge and the font is small enough that its line height fits
	# inside the band (a centred glyph then never spills past the board).
	var label_pos := Vector2(face_pos.x, face_pos.y + face_size.y * 0.66)
	var label_size := Vector2(face_size.x, face_size.y * 0.28)
	var font_size := int(face_size.y * (0.18 if label.length() > 1 else 0.24))
	_label(root, label_pos, label_size, label, font_size, INK)

	await process_frame
	await process_frame
	var img := vp.get_texture().get_image()
	vp.queue_free()
	return img


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
			String(gallery[i]["name"]), 16, CREAM)
		var tr := TextureRect.new()
		tr.texture = ImageTexture.create_from_image(gallery[i]["img"])
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


# ---- helpers (mirror bake_finish_banners.gd) -----------------------------
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


# Draws a thick, round-jointed stroke along the corner polyline (fit + optionally
# mirrored into `box`, +Y up) and an arrowhead at the exit end.
class _ArrowDraw extends Node2D:
	var points: PackedVector2Array
	var box: Rect2
	var flip := false
	var color := Color.BLACK

	func _draw() -> void:
		if points.size() < 2:
			return
		# Fit the meter-space polyline uniformly (preserve angles, so the bend still
		# reads as the true turn intensity).
		var lo := points[0]
		var hi := points[0]
		for p in points:
			lo = lo.min(p)
			hi = hi.max(p)
		var content := hi - lo
		var content_c := (lo + hi) * 0.5

		var width := maxf(box.size.x, box.size.y) * 0.11
		var radius := width * 0.5
		# The arrowhead + round end caps overshoot the centerline, so scale the
		# polyline into the box MINUS a uniform margin that reserves room for them —
		# then the whole drawn shape (not just the centerline) fits. Kept just big
		# enough to contain the arrowhead's perpendicular spread (~1.1·width).
		var margin := width * 1.15
		var avail := box.size - Vector2(margin, margin) * 2.0
		var scale: float = minf(avail.x / maxf(content.x, 0.001),
			avail.y / maxf(content.y, 0.001))

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

		# Centre the FULL drawn ink (shaft stroke + arrowhead), not just the
		# centerline — otherwise the arrow leans toward its arrowhead side.
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
		apex += shift
		base1 += shift
		base2 += shift

		# Round-jointed stroke: a segment + a disc at each joint, then the head.
		for i in range(1, screen.size()):
			draw_line(screen[i - 1], screen[i], color, width)
		for p in screen:
			draw_circle(p, radius, color)
		draw_colored_polygon(PackedVector2Array([apex, base1, base2]), color)

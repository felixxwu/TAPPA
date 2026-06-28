extends SceneTree
# Bakes the finish-arch banner textures (the big "FINISH" beam strip and the
# stacked sponsor panels down each leg) by laying out Control nodes in a
# SubViewport and grabbing the rendered image. Writes PNGs to textures/finish/,
# which FinishArch loads at runtime (via Image.load, so no import step needed):
#
#   xvfb-run -a godot --path rally --rendering-driver opengl3 \
#       --script tools/bake_finish_banners.gd
#
# Re-run whenever the banner art changes. Pure tooling.

const OUT := "res://textures/finish"

# Palette — evokes the desert-rally look without copying any real logo.
const ORANGE := Color("d84a26")
const CREAM := Color("f3e9d2")
const WHITE := Color("f4f4f0")
const INK := Color("23211f")
const BLUE := Color("2f6db0")
const RED := Color("c8332c")
const GREEN := Color("2e9e54")
const SAND := Color("c9a86b")


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	await _bake("top", Vector2i(1280, 200), _build_top)
	await _bake("leg", Vector2i(256, 768), _build_leg)
	await _bake("back", Vector2i(1280, 200), _build_back)
	await _bake("top_start", Vector2i(1280, 200), _build_top_start)
	await _bake("back_start", Vector2i(1280, 200), _build_back_start)
	await _bake("leg_start", Vector2i(256, 768), _build_leg_start)
	print("BANNERS DONE")
	quit()


func _bake(tex_name: String, size: Vector2i, builder: Callable) -> void:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(vp)
	var root := Control.new()
	root.size = size
	vp.add_child(root)
	builder.call(root, size)
	await process_frame
	await process_frame
	var img := vp.get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT, tex_name])
	print("SAVED %s/%s.png %s" % [OUT, tex_name, size])
	vp.queue_free()


# ---- helpers -------------------------------------------------------------
func _rect(parent: Control, pos: Vector2, size: Vector2, col: Color) -> ColorRect:
	var r := ColorRect.new()
	r.position = pos
	r.size = size
	r.color = col
	parent.add_child(r)
	return r


func _label(parent: Control, pos: Vector2, size: Vector2, text: String,
		font_size: int, col: Color, bold := true) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = size
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	if bold:
		l.add_theme_constant_override("outline_size", 0)
	parent.add_child(l)
	return l


# A small framed sponsor card: white panel with a coloured header bar + label.
func _sponsor(parent: Control, pos: Vector2, size: Vector2, header: String,
		body: String, accent: Color) -> void:
	_rect(parent, pos, size, WHITE)
	var head_h := size.y * 0.42
	_rect(parent, pos, Vector2(size.x, head_h), accent)
	_label(parent, pos, Vector2(size.x, head_h), header, int(head_h * 0.5), WHITE)
	_label(parent, pos + Vector2(0, head_h), Vector2(size.x, size.y - head_h),
		body, int((size.y - head_h) * 0.4), INK)


# ---- TOP beam strip: wordmark on each side, sponsor cards through the middle ----
func _build_top(root: Control, size: Vector2i) -> void:
	_build_top_word(root, size, "FINISH")


# START variant of the top strip — same layout, START wordmarks.
func _build_top_start(root: Control, size: Vector2i) -> void:
	_build_top_word(root, size, "START")


func _build_top_word(root: Control, size: Vector2i, word: String) -> void:
	_rect(root, Vector2.ZERO, size, ORANGE)
	var w := float(size.x)
	var h := float(size.y)
	# Wordmark, far left and far right (cream on orange, like the photo).
	_label(root, Vector2(0.0, 0), Vector2(0.30 * w, h), word, int(h * 0.46), CREAM)
	_label(root, Vector2(0.70 * w, 0), Vector2(0.30 * w, h), word, int(h * 0.46), CREAM)
	# Centre band of sponsor cards.
	var cy := h * 0.16
	var ch := h * 0.68
	var cw := w * 0.14
	var gap := w * 0.015
	var x := w * 0.29
	_sponsor(root, Vector2(x, cy), Vector2(cw, ch), "RALLY", "RAID", BLUE)
	x += cw + gap
	_sponsor(root, Vector2(x, cy), Vector2(cw, ch), "STAGE", "FINAL", GREEN)
	x += cw + gap
	_sponsor(root, Vector2(x, cy), Vector2(cw, ch), "DESERT", "CUP", RED)


# ---- LEG: stacked sponsor panels + a footer. The finish legs say CONGRATS!, the
# start legs say GO! — otherwise identical. ----
func _build_leg(root: Control, size: Vector2i) -> void:
	_build_leg_footer(root, size, "CONGRATS!", ORANGE)


func _build_leg_start(root: Control, size: Vector2i) -> void:
	_build_leg_footer(root, size, "GO!", GREEN)


func _build_leg_footer(root: Control, size: Vector2i, footer: String, footer_col: Color) -> void:
	_rect(root, Vector2.ZERO, size, SAND.lightened(0.25))
	var w := float(size.x)
	var h := float(size.y)
	var pad := w * 0.08
	var pw := w - pad * 2.0
	var y := pad
	# A flag-ish emblem block up top.
	_rect(root, Vector2(pad, y), Vector2(pw, h * 0.13), GREEN)
	_label(root, Vector2(pad, y), Vector2(pw, h * 0.13), "2R", int(h * 0.08), WHITE)
	y += h * 0.13 + pad
	_sponsor(root, Vector2(pad, y), Vector2(pw, h * 0.16), "RALLY", "RAID", BLUE)
	y += h * 0.16 + pad
	_sponsor(root, Vector2(pad, y), Vector2(pw, h * 0.16), "STAGE", "12", ORANGE)
	y += h * 0.16 + pad
	_sponsor(root, Vector2(pad, y), Vector2(pw, h * 0.16), "TURBO", "OIL", RED)
	y += h * 0.16 + pad
	_rect(root, Vector2(pad, y), Vector2(pw, h * 0.1), footer_col)
	_label(root, Vector2(pad, y), Vector2(pw, h * 0.1), footer, int(h * 0.045), WHITE)


# ---- BACK of the top beam (down-track side): just the wordmark + emblem ----
func _build_back(root: Control, size: Vector2i) -> void:
	_build_back_word(root, size, "RALLY  RAID  CHAMPIONSHIP")


# START gate back face (faces down-track): a send-off message.
func _build_back_start(root: Control, size: Vector2i) -> void:
	_build_back_word(root, size, "GOOD  LUCK")


func _build_back_word(root: Control, size: Vector2i, text: String) -> void:
	_rect(root, Vector2.ZERO, size, ORANGE)
	var w := float(size.x)
	var h := float(size.y)
	_label(root, Vector2(0, 0), Vector2(w, h), text, int(h * 0.42), CREAM)

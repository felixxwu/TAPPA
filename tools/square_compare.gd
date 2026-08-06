extends Node2D
# Verification aid: draw the Square corner BEFORE and AFTER the handle-length change,
# overlaid at a readable scale, with the circular quarter-arc that shares its endpoints as
# a reference. The shared corner_catalog.tscn viewer auto-fits all nine shapes into one
# row, which makes a single corner far too small to judge — this is the zoomed view.
#
# Saves tools/corner_square_compare.png. Pure tooling; not shipped. Run windowed:
#
#   godot --path . --rendering-driver opengl3 res://tools/square_compare.tscn

const OUT_PATH := "res://tools/corner_square_compare.png"
# Layout is derived from the ACTUAL viewport each frame rather than hardcoded: the window
# size request and the project's viewport/stretch settings do not have to agree, and a
# hardcoded layout simply drew off the edge of the captured image.
const MARGIN_PX := 18.0
const LEGEND_PX := 84.0        # reserved band at the top for the text
const SPAN_M := Vector2(15.5, 19.0)   # corner extent to fit: endpoint plus the tallest handle
const BAKE_INTERVAL_M := 0.05
const PROBE_STEP_M := 0.5
const REFERENCE_MU := 1.1

const END := Vector2(14.6, 14.6)
# The three shapes: label, entry handle length, exit handle length, colour.
const SHAPES := [
	{"label": "BEFORE 13.95/13.30", "h1": 13.953, "h2": 13.302,
		"color": Color(1.0, 0.42, 0.42)},
	{"label": "AFTER 11.00/10.50", "h1": 11.0, "h2": 10.5,
		"color": Color(0.42, 1.0, 0.55)},
	{"label": "circular arc 8.06 (ref)", "h1": 8.06, "h2": 8.06,
		"color": Color(0.55, 0.6, 0.75)},
]


func _ready() -> void:
	if Platform.is_headless():
		for shape in SHAPES:
			var c := _curve(float(shape["h1"]), float(shape["h2"]))
			print("%-52s min_radius=%.2f m  v_cap=%.1f km/h" % [
				String(shape["label"]), _min_radius(c),
				sqrt(REFERENCE_MU * Platform.gravity() * _min_radius(c)) * 3.6])
		print("square-compare: headless — numbers only. Re-run windowed for the PNG.")
		get_tree().quit()
		return
	get_window().size = Vector2i(900, 640)
	for _i in 20:
		await get_tree().process_frame
	var err := get_viewport().get_texture().get_image().save_png(OUT_PATH)
	print("square-compare: saved %s err=%d" % [OUT_PATH, err])
	get_tree().quit()


# Entry at the origin heading +Y, exit at END heading +X — a right-hand ~90 degree turn,
# exactly how CornerLibrary authors it.
func _curve(h1: float, h2: float) -> Curve2D:
	var c := Curve2D.new()
	c.bake_interval = BAKE_INTERVAL_M
	c.add_point(Vector2.ZERO, Vector2.ZERO, Vector2(0.0, h1))
	c.add_point(END, Vector2(-h2, 0.0), Vector2.ZERO)
	return c


# Metres -> screen, fitted to the live viewport. Corner space is +Y "forward"; screen Y
# grows downward, so flip it.
func _scale_px() -> float:
	var size := get_viewport_rect().size
	var usable := Vector2(size.x - MARGIN_PX * 2.0, size.y - MARGIN_PX * 2.0 - LEGEND_PX)
	return minf(usable.x / SPAN_M.x, usable.y / SPAN_M.y)

func _origin_px() -> Vector2:
	var size := get_viewport_rect().size
	return Vector2(MARGIN_PX + 8.0, size.y - MARGIN_PX)

func _to_screen(p: Vector2) -> Vector2:
	var k := _scale_px()
	return _origin_px() + Vector2(p.x * k, -p.y * k)


func _min_radius(curve: Curve2D) -> float:
	var length := curve.get_baked_length()
	if length <= 0.0:
		return 0.0
	var best := 1.0e18
	var samples := int(length / PROBE_STEP_M)
	for i in range(1, samples):
		var back := curve.sample_baked(float(i - 1) * PROBE_STEP_M)
		var here := curve.sample_baked(float(i) * PROBE_STEP_M)
		var ahead := curve.sample_baked(minf(float(i + 1) * PROBE_STEP_M, length))
		var v1 := here - back
		var v2 := ahead - here
		if v1.length() < 0.0001 or v2.length() < 0.0001:
			continue
		var dtheta: float = absf(wrapf(v2.angle() - v1.angle(), -PI, PI))
		if dtheta < 0.00001:
			continue
		best = minf(best, PROBE_STEP_M / dtheta)
	return best


# The point along the curve where it is tightest — the one the lap-time model brakes for.
func _tightest_point(curve: Curve2D) -> Vector2:
	var length := curve.get_baked_length()
	var best := 1.0e18
	var at := 0.0
	var samples := int(length / PROBE_STEP_M)
	for i in range(1, samples):
		var back := curve.sample_baked(float(i - 1) * PROBE_STEP_M)
		var here := curve.sample_baked(float(i) * PROBE_STEP_M)
		var ahead := curve.sample_baked(minf(float(i + 1) * PROBE_STEP_M, length))
		var v1 := here - back
		var v2 := ahead - here
		if v1.length() < 0.0001 or v2.length() < 0.0001:
			continue
		var dtheta: float = absf(wrapf(v2.angle() - v1.angle(), -PI, PI))
		if dtheta < 0.00001:
			continue
		var r := PROBE_STEP_M / dtheta
		if r < best:
			best = r
			at = float(i) * PROBE_STEP_M
	return curve.sample_baked(at)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.06, 0.07, 0.1), true)

	# Entry / exit tangent guides, so "square" is visually meaningful.
	var guide := Color(0.25, 0.28, 0.35)
	draw_line(_to_screen(Vector2.ZERO), _to_screen(Vector2(0.0, 18.0)), guide, 1.0)
	draw_line(_to_screen(END), _to_screen(END + Vector2(6.0, 0.0)), guide, 1.0)

	var y := 20.0
	draw_string(font, Vector2(14, y), "CornerLibrary \"Square\" - 90 deg, same endpoints",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.9, 0.9, 0.95))
	y += 20.0

	for shape in SHAPES:
		var curve := _curve(float(shape["h1"]), float(shape["h2"]))
		var color: Color = shape["color"]
		var poly := curve.get_baked_points()
		for i in range(1, poly.size()):
			draw_line(_to_screen(poly[i - 1]), _to_screen(poly[i]), color, 3.0)
		# Handles.
		draw_line(_to_screen(Vector2.ZERO), _to_screen(Vector2(0.0, float(shape["h1"]))),
				color * Color(1, 1, 1, 0.45), 1.0)
		draw_line(_to_screen(END), _to_screen(END + Vector2(-float(shape["h2"]), 0.0)),
				color * Color(1, 1, 1, 0.45), 1.0)
		# Mark and annotate the tightest point.
		var r := _min_radius(curve)
		var tight := _tightest_point(curve)
		draw_circle(_to_screen(tight), 5.0, color)
		var v := sqrt(REFERENCE_MU * Platform.gravity() * r) * 3.6
		draw_string(font, Vector2(14, y),
				"%s  min r %.1f m -> %.0f km/h" % [String(shape["label"]), r, v],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color)
		y += 18.0

	draw_circle(_to_screen(Vector2.ZERO), 6.0, Color(0.49, 0.99, 0.0))
	draw_circle(_to_screen(END), 6.0, Color(0.95, 0.95, 0.95))
	draw_string(font, Vector2(14, y + 2.0),
			"dot = tightest point on each curve (what sets the braking)",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.65, 0.75))

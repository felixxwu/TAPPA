class_name CornerCatalog
extends Node2D
# Standalone debug viewer: draws every CornerLibrary turn type side by side so
# the bezier shapes can be eyeballed. Centerline + control-point markers +
# tangent handles + an entry dot + a name label per corner. Pure 2D, no game
# nodes. Run this scene directly (it is not the project's main scene).
#
# Corners are laid out in meter-space first, then the whole row is auto-fit to
# the current viewport so it never overflows regardless of the window/stretch
# settings inherited from project.godot.

const CornerLibrary = preload("res://scripts/corner_library.gd")

const GUTTER_M := 6.0          # meters of gap between corners
const MARGIN_PX := 48.0        # screen-space margin around the whole row
const LABEL_OFFSET_PX := 26.0  # label sits this far above a corner's top
const CENTERLINE_COLOR := Color(0.36, 0.55, 1.0)
const HANDLE_COLOR := Color(0.9, 0.45, 0.45)
const POINT_COLOR := Color(0.95, 0.95, 0.95)
const ENTRY_COLOR := Color(0.49, 0.99, 0.0)

# Each item: { "name", "curve", "poly" (meters), "x_off" (meters) }.
var _items: Array[Dictionary] = []
# Fit transform from meter-space to screen-space, computed in _fit_to_viewport.
var _scale := 1.0
var _bounds_min := Vector2.ZERO
var _bounds_max := Vector2.ZERO
# On-screen width of the laid-out row (read by tests / for framing).
var layout_width := 0.0


func _ready() -> void:
	_lay_out()
	_fit_to_viewport()
	_add_labels()
	queue_redraw()


# Place every corner left-to-right in meter-space, flush to a running cursor.
func _lay_out() -> void:
	var cursor := 0.0
	for spec in CornerLibrary.CORNERS:
		var curve := CornerLibrary.build_curve(spec)
		var poly := curve.tessellate()  # PackedVector2Array, meters
		var min_x := INF
		var max_x := -INF
		for p in poly:
			min_x = minf(min_x, p.x)
			max_x = maxf(max_x, p.x)
		_items.append({
			"name": spec["name"], "curve": curve, "poly": poly,
			"x_off": cursor - min_x,
		})
		cursor += (max_x - min_x) + GUTTER_M


# Measure the full laid-out row (curve + control handles) and pick a scale that
# fits it inside the viewport, leaving room for margins and the top labels.
func _fit_to_viewport() -> void:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for item in _items:
		var ox: float = item["x_off"]
		for p in item["poly"]:
			lo = lo.min(Vector2(p.x + ox, p.y))
			hi = hi.max(Vector2(p.x + ox, p.y))
		var curve: Curve2D = item["curve"]
		for i in range(curve.point_count):
			var pos := curve.get_point_position(i)
			for h in [pos, pos + curve.get_point_in(i), pos + curve.get_point_out(i)]:
				lo = lo.min(Vector2(h.x + ox, h.y))
				hi = hi.max(Vector2(h.x + ox, h.y))
	_bounds_min = lo
	_bounds_max = hi
	var content := hi - lo
	var vp := get_viewport_rect().size
	var avail := Vector2(
		maxf(vp.x - 2.0 * MARGIN_PX, 1.0),
		maxf(vp.y - 2.0 * MARGIN_PX - LABEL_OFFSET_PX, 1.0))
	_scale = minf(avail.x / maxf(content.x, 0.001), avail.y / maxf(content.y, 0.001))
	layout_width = content.x * _scale


# Meter-space point (x already includes the corner's x_off; +Y up) -> screen
# (+Y down), fit and offset by the margins.
func _to_screen(local: Vector2) -> Vector2:
	return Vector2(
		MARGIN_PX + (local.x - _bounds_min.x) * _scale,
		MARGIN_PX + LABEL_OFFSET_PX + (_bounds_max.y - local.y) * _scale)


func _add_labels() -> void:
	for item in _items:
		var ox: float = item["x_off"]
		var top_y := INF
		var left_x := INF
		for p in item["poly"]:
			var s := _to_screen(Vector2(p.x + ox, p.y))
			top_y = minf(top_y, s.y)
			left_x = minf(left_x, s.x)
		var label := Label.new()
		label.text = item["name"]
		label.position = Vector2(left_x, top_y - LABEL_OFFSET_PX)
		add_child(label)


func _draw() -> void:
	for item in _items:
		var ox: float = item["x_off"]
		var poly: PackedVector2Array = item["poly"]
		# Centerline.
		for i in range(1, poly.size()):
			draw_line(_to_screen(Vector2(poly[i - 1].x + ox, poly[i - 1].y)),
				_to_screen(Vector2(poly[i].x + ox, poly[i].y)), CENTERLINE_COLOR, 3.0)
		# Control points + tangent handles.
		var curve: Curve2D = item["curve"]
		for i in range(curve.point_count):
			var pos := curve.get_point_position(i)
			var screen_pos := _to_screen(Vector2(pos.x + ox, pos.y))
			var in_ctrl := curve.get_point_in(i)
			var out_ctrl := curve.get_point_out(i)
			if in_ctrl != Vector2.ZERO:
				var s := _to_screen(Vector2(pos.x + in_ctrl.x + ox, pos.y + in_ctrl.y))
				draw_line(screen_pos, s, HANDLE_COLOR, 1.0)
				draw_circle(s, 3.0, HANDLE_COLOR)
			if out_ctrl != Vector2.ZERO:
				var s := _to_screen(Vector2(pos.x + out_ctrl.x + ox, pos.y + out_ctrl.y))
				draw_line(screen_pos, s, HANDLE_COLOR, 1.0)
				draw_circle(s, 3.0, HANDLE_COLOR)
			draw_circle(screen_pos, 4.0, POINT_COLOR)
		# Entry marker (first point).
		var entry := curve.get_point_position(0)
		draw_circle(_to_screen(Vector2(entry.x + ox, entry.y)), 5.0, ENTRY_COLOR)

class_name LoadingScreen
extends CanvasLayer
# Full-screen "loading stage" overlay shown while world.gd builds the world.
#
# Godot's own boot bar only covers engine + .pck load + script compile. The
# world generation that runs in world.gd._ready() (track, terrain ring, tree
# and bush scatter) is heavy and synchronous, so without this the screen sits
# frozen with no feedback between the boot bar finishing and the first playable
# frame. world.gd shows this overlay first, then advances `set_step()` between
# generation stages (yielding a frame each time so the new label paints), and
# calls `finish()` when the world is ready.

# Drawn above the HUD (layer 2) and mobile controls (layer 3).
const _LAYER := 100

var _title: Label
var _step: Label
var _preview: _TrackPreview


func _init() -> void:
	layer = _LAYER

	var bg := ColorRect.new()
	bg.color = UITheme.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(box)

	_preview = _TrackPreview.new()
	box.add_child(_preview)

	_title = Label.new()
	_title.text = UITheme.caps("Loading stage…")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	box.add_child(_title)

	_step = Label.new()
	_step.text = ""
	_step.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_step.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	_step.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_step)


# Set the headline (defaults to "Loading stage…"; the HQ uses its own wording).
func set_title(text: String) -> void:
	if _title != null:
		_title.text = UITheme.caps(text)


# Update the current-stage line (e.g. "Building terrain…").
func set_step(text: String) -> void:
	if _step != null:
		_step.text = UITheme.caps(text)


# Update the live track drawing (the on_progress callback from TrackGenerator,
# and the one-shot finished-shape lock from world.gd). Points are in the
# generator's 2D world-XZ frame; fit_points handles the mapping.
func update_track_preview(points: PackedVector2Array) -> void:
	if _preview != null:
		_preview.set_points(points)


# Map world-XZ points into `rect` (inset by `pad` on all sides), preserving aspect
# ratio and centering. Pure — no node state. Returns empty for fewer than 2 points.
static func fit_points(points: PackedVector2Array, rect: Rect2, pad: float) -> PackedVector2Array:
	if points.size() < 2:
		return PackedVector2Array()
	var min_x := points[0].x; var max_x := points[0].x
	var min_y := points[0].y; var max_y := points[0].y
	for p in points:
		min_x = minf(min_x, p.x); max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y); max_y = maxf(max_y, p.y)
	var span_x := maxf(max_x - min_x, 1e-3)
	var span_y := maxf(max_y - min_y, 1e-3)
	var inner := Vector2(maxf(rect.size.x - 2.0 * pad, 1.0), maxf(rect.size.y - 2.0 * pad, 1.0))
	var fit := minf(inner.x / span_x, inner.y / span_y)
	# Centre the scaled drawing inside the inner box.
	var draw_size := Vector2(span_x * fit, span_y * fit)
	var origin := rect.position + Vector2(pad, pad) + (inner - draw_size) * 0.5
	var out := PackedVector2Array()
	for p in points:
		out.append(origin + Vector2((p.x - min_x) * fit, (p.y - min_y) * fit))
	return out


# Tear the overlay down once the world is ready.
func finish() -> void:
	queue_free()


# Simple line drawing of the track as it generates (and once finished, held).
class _TrackPreview extends Control:
	var _points := PackedVector2Array()

	func _init() -> void:
		custom_minimum_size = Vector2(0, 220)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_points(points: PackedVector2Array) -> void:
		_points = points
		queue_redraw()

	func _draw() -> void:
		var mapped := LoadingScreen.fit_points(_points, Rect2(Vector2.ZERO, size), 16.0)
		if mapped.size() < 2:
			return
		draw_polyline(mapped, UITheme.INK, 2.0, true)
		draw_circle(mapped[0], 4.0, UITheme.GREEN)

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
var _preview: TrackPreview


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

	_preview = TrackPreview.new()
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


# World-XZ bounding box of `points` (position = min corner, size = span).
# Returns an empty Rect2 for no points; callers guard on size for the < 2 case.
static func bounds_of(points: PackedVector2Array) -> Rect2:
	if points.is_empty():
		return Rect2()
	var min_x := points[0].x; var max_x := points[0].x
	var min_y := points[0].y; var max_y := points[0].y
	for p in points:
		min_x = minf(min_x, p.x); max_x = maxf(max_x, p.x)
		min_y = minf(min_y, p.y); max_y = maxf(max_y, p.y)
	return Rect2(Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


# World-XZ -> screen map that fits `bounds` into `rect` (inset by `pad` on all
# sides), preserving aspect ratio and centering. `screen = xform * world`. Pure.
static func fit_transform(bounds: Rect2, rect: Rect2, pad: float) -> Transform2D:
	var span_x := maxf(bounds.size.x, 1e-3)
	var span_y := maxf(bounds.size.y, 1e-3)
	var inner := Vector2(maxf(rect.size.x - 2.0 * pad, 1.0), maxf(rect.size.y - 2.0 * pad, 1.0))
	var fit := minf(inner.x / span_x, inner.y / span_y)
	var draw_size := Vector2(span_x * fit, span_y * fit)
	var origin := rect.position + Vector2(pad, pad) + (inner - draw_size) * 0.5
	# screen = origin + (world - bounds.position) * fit
	#        = (world * fit) + (origin - bounds.position * fit)
	return Transform2D(Vector2(fit, 0), Vector2(0, fit), origin - bounds.position * fit)


# Map world-XZ points into `rect` (inset by `pad`), preserving aspect ratio and
# centering. Returns empty for fewer than 2 points.
static func fit_points(points: PackedVector2Array, rect: Rect2, pad: float) -> PackedVector2Array:
	if points.size() < 2:
		return PackedVector2Array()
	var xf := fit_transform(bounds_of(points), rect, pad)
	var out := PackedVector2Array()
	for p in points:
		out.append(xf * p)
	return out


# The world-space edge length of one chunk square (TerrainManager.CHUNK_M),
# supplied once by world.gd so LoadingScreen stays decoupled from TerrainManager.
func set_chunk_size(world_m: float) -> void:
	if _preview != null:
		_preview.set_chunk_size(world_m)


# The growing list of loaded-chunk world-XZ min-corners, drawn as dark squares
# behind the track line during the "Precomputing chunks…" stage.
func update_loaded_chunks(corners: PackedVector2Array) -> void:
	if _preview != null:
		_preview.set_chunks(corners)


# Carve progress in [0, 1]: the fraction of the track line drawn WHITE (carved)
# from the start; the rest stays grey. 0 = all grey (during generation), 1 = all
# white (carving done). Driven by the bake walking the centerline.
func set_carve_progress(fraction: float) -> void:
	if _preview != null:
		_preview.set_carve_progress(fraction)


# The prefix of `mapped` (already screen-space) covering the first `progress`
# fraction of the polyline's length by point index, with an interpolated boundary
# point at the exact fractional split so the white/grey edge advances smoothly.
# Empty for progress <= 0 or < 2 points; the whole line for progress >= 1. Pure.
static func carve_prefix(mapped: PackedVector2Array, progress: float) -> PackedVector2Array:
	if mapped.size() < 2 or progress <= 0.0:
		return PackedVector2Array()
	if progress >= 1.0:
		return mapped
	var n := mapped.size()
	var split_f := progress * float(n - 1)
	var ki := int(floor(split_f))
	var frac := split_f - float(ki)
	var out := PackedVector2Array()
	for i in ki + 1:
		out.append(mapped[i])
	if frac > 0.0 and ki + 1 < n:
		out.append(mapped[ki].lerp(mapped[ki + 1], frac))
	return out


# Below-water cell centres (world XZ) + edge length, drawn behind the track line.
# Fed by world.gd during generation so the author watches the road route around
# the water live (features/lakes.md).
func update_water(cells: PackedVector2Array, cell_size: float) -> void:
	if _preview != null:
		_preview.set_water(cells, cell_size)


# Tear the overlay down once the world is ready.
func finish() -> void:
	queue_free()

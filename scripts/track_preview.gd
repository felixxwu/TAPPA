class_name TrackPreview
extends Control
# Shared 2D preview of a generated track: the centerline (grey → white as it
# carves), loaded terrain chunks (dark squares), and below-water cells (blue
# blocks behind the line). Used by the loading screen AND the dev seed-lab
# (settings_menu). All in the generator's 2D world-XZ frame; LoadingScreen's
# shared fit_transform maps everything into the panel. See features/lakes.md.

const PAD := 16.0

var _points := PackedVector2Array()          # track centerline, world XZ
# A NETWORK of disjoint polylines, world XZ — the overworld's road graph rather than one
# stage centreline. Kept separate from `_points` because that is drawn as a SINGLE
# draw_polyline: feeding 68 unconnected road edges through it would draw a spurious line
# from the end of each road to the start of the next, i.e. a scribble across the map.
var _polylines: Array[PackedVector2Array] = []
var _chunk_corners := PackedVector2Array()   # loaded-chunk min-corners, world XZ
var _chunk_size := 0.0                        # chunk edge length, world metres
var _carve_progress := 0.0                    # fraction of the line carved (white)
var _water_cells := PackedVector2Array()      # below-water cell CENTRES, world XZ
var _water_cell_size := 0.0                   # water cell edge length, world metres
var _frame := Rect2()                         # explicit fit region (world XZ); empty = derive from content


func _init() -> void:
	custom_minimum_size = Vector2(0, 220)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true  # squares beyond the track's frame clip at the edge


func set_points(points: PackedVector2Array) -> void:
	_points = points
	queue_redraw()


# A road NETWORK: one entry per road, each a world-XZ polyline. Used by the overworld's
# precompute screen, where the thing being built is a graph of roads between the rally pins
# rather than a single stage centreline. Every road draws at full brightness — there is no
# "carve progress" along a network, because the chunks (not the line) are what is progressing.
func set_polylines(lines: Array[PackedVector2Array]) -> void:
	_polylines = lines
	queue_redraw()


func set_carve_progress(fraction: float) -> void:
	_carve_progress = clampf(fraction, 0.0, 1.0)
	queue_redraw()


func set_chunk_size(world_m: float) -> void:
	_chunk_size = world_m
	queue_redraw()


func set_chunks(corners: PackedVector2Array) -> void:
	_chunk_corners = corners
	queue_redraw()


# Below-water cell centres (world XZ) + their edge length, drawn as blue blocks
# behind the road line. Doubles as the seed/water-level debug view. `frame` is the
# world-XZ region the water was sampled over; when given it also anchors the fit so
# the water fills the panel to its edges (matching the real game's full water plane),
# instead of the fit shrinking to the track and leaving dry letterbox bands.
func set_water(cells: PackedVector2Array, cell_size: float, frame := Rect2()) -> void:
	_water_cells = cells
	_water_cell_size = cell_size
	_frame = frame
	queue_redraw()


func water_cell_count() -> int:
	return _water_cells.size()


func _draw() -> void:
	# Solid black backdrop so the track/water read cleanly (used by the loading
	# screen — already black — and the dev seed lab).
	draw_rect(Rect2(Vector2.ZERO, size), Color.BLACK, true)
	# Fit to whatever content exists — water alone is enough to paint (it's known
	# up-front, before the track animates), so it shows first and the road draws over it.
	var content := _points.duplicate()
	# The network counts toward the fit too, or a road-only preview (the overworld, which has no
	# single centreline) would have nothing to fit to and draw nothing at all.
	for line in _polylines:
		for p in line:
			content.append(p)
	# The explicit water frame (if set) anchors the fit so water reaches the panel
	# edges; otherwise fall back to the water cells / track for the bounds.
	if _frame.size.x > 0.0 and _frame.size.y > 0.0:
		content.append(_frame.position)
		content.append(_frame.position + _frame.size)
	else:
		for c in _water_cells:
			content.append(c)
	if content.size() < 2:
		return
	# One transform from the combined bounds (track + water), shared by everything.
	var xf := LoadingScreen.fit_transform(
		LoadingScreen.bounds_of(content), Rect2(Vector2.ZERO, size), PAD)
	# Water blocks first (furthest back).
	if _water_cell_size > 0.0:
		var half := Vector2(_water_cell_size, _water_cell_size) * 0.5
		var water_col: Color = Config.data.water_color  # same source the stage renders from
		for c in _water_cells:
			var s0 := xf * (c - half)
			var s1 := xf * (c + half)
			draw_rect(Rect2(s0, s1 - s0), water_col, true)
	# Chunk squares next (behind the line), inset 1px for a subtle grid gap. Drawn as
	# near-transparent white so the water painted behind them still reads through.
	if _chunk_size > 0.0:
		var sz := Vector2(_chunk_size, _chunk_size)
		var chunk_col := Color(1.0, 1.0, 1.0, 0.05)
		for c in _chunk_corners:
			var s0 := xf * c
			var s1 := xf * (c + sz)
			draw_rect(Rect2(s0 + Vector2.ONE, (s1 - s0) - Vector2.ONE * 2.0),
				chunk_col, true)
	# The road NETWORK, each road its own polyline so unconnected roads stay unconnected.
	# Drawn under the stage centreline (which is empty whenever a network is in use).
	for line in _polylines:
		if line.size() < 2:
			continue
		var road := PackedVector2Array()
		for p in line:
			road.append(xf * p)
		draw_polyline(road, UITheme.INK, 2.0, true)
	# Track line: grey (uncarved) full length, then the carved prefix white on top.
	if _points.size() >= 2:
		var line := PackedVector2Array()
		for p in _points:
			line.append(xf * p)
		draw_polyline(line, UITheme.INK_DIM, 2.0, true)
		var carved := LoadingScreen.carve_prefix(line, _carve_progress)
		if carved.size() >= 2:
			draw_polyline(carved, UITheme.INK, 2.0, true)
		draw_circle(line[0], 4.0, UITheme.GREEN)

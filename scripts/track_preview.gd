class_name TrackPreview
extends Control
# Shared 2D preview of a generated track: the centerline (grey → white as it
# carves), loaded terrain chunks (dark squares), and below-water cells (blue
# blocks behind the line). Used by the loading screen AND the dev seed-lab
# (settings_menu). All in the generator's 2D world-XZ frame; LoadingScreen's
# shared fit_transform maps everything into the panel. See features/lakes.md.

const PAD := 16.0

var _points := PackedVector2Array()          # track centerline, world XZ
var _chunk_corners := PackedVector2Array()   # loaded-chunk min-corners, world XZ
var _chunk_size := 0.0                        # chunk edge length, world metres
var _carve_progress := 0.0                    # fraction of the line carved (white)
var _water_cells := PackedVector2Array()      # below-water cell CENTRES, world XZ
var _water_cell_size := 0.0                   # water cell edge length, world metres


func _init() -> void:
	custom_minimum_size = Vector2(0, 220)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true  # squares beyond the track's frame clip at the edge


func set_points(points: PackedVector2Array) -> void:
	_points = points
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
# behind the road line. Doubles as the seed/water-level debug view.
func set_water(cells: PackedVector2Array, cell_size: float) -> void:
	_water_cells = cells
	_water_cell_size = cell_size
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

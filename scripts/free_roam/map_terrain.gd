class_name MapTerrain
extends RefCounted
# Docs: features/minimap.md — update in the same change as this file.
# Tests: tests/headless/test_world_pages.gd — extend in the same change.
# The full map's top-down terrain picture, drawn the way tools/road_network_lab.html's 2D view
# draws it (drawTerrain): ring colours, hill shading from the slope, contour lines, higher ground
# lighter, lakes flat blue, the sea left out. Heights are slow to sample, so the picture is built
# from square tiles, a little per frame, and every tile is kept for the session: a tile's detail
# (metres per cell) is a power of two picked from the view's size, so moving or slightly growing
# the view reuses the tiles already drawn.

const TILE := 32  # cells per tile side

var _terrain: RoadTerrain
var _island_radius_m := 0.0
var _tiles := {}  # Vector3i(x, y, level) -> ImageTexture
var _wanted: Array[Vector3i] = []
var _last_level := 0
var _last_view := Rect2()
var _job_key := Vector3i.ZERO  # the tile being sampled
var _job_cell := -1  # its next cell to sample; -1 when no tile is under way
var _job_heights := PackedFloat32Array()
var _job_kind := PackedByteArray()
var _job_ring := PackedByteArray()


func _init(terrain: RoadTerrain, island_radius_m: float) -> void:
	_terrain = terrain
	_island_radius_m = island_radius_m


# Asks for the tiles covering `view`, at about `cells` cells across it.
func request(view: Rect2, cells: int) -> void:
	_wanted.clear()
	var level := ceili(log(maxf(view.size.x / cells, 1.0)) / log(2.0))
	var span := TILE * pow(2.0, level)
	for ty in range(floori(view.position.y / span), floori(view.end.y / span) + 1):
		for tx in range(floori(view.position.x / span), floori(view.end.x / span) + 1):
			var key := Vector3i(tx, ty, level)
			if not _tiles.has(key) and not (_job_cell >= 0 and key == _job_key) and _tile_on_island(key):
				_wanted.append(key)
	_last_level = level
	_last_view = view


func done() -> bool:
	return _wanted.is_empty() and _job_cell < 0


# Samples wanted tiles until `budget_usec` has passed (at least one cell), stopping mid-tile if it
# must: one whole tile takes far longer than a frame can spare. True once none are left.
func step(budget_usec: int) -> bool:
	var until := Time.get_ticks_usec() + budget_usec
	while not done():
		if _job_cell < 0:
			_start_tile(_wanted.pop_back())
		_sample_cell()
		if Time.get_ticks_usec() >= until:
			break
	return done()


# The tiles drawn so far over the last requested view, as [world rect, texture] pairs.
func drawn() -> Array:
	var out := []
	var span := TILE * pow(2.0, _last_level)
	for ty in range(floori(_last_view.position.y / span), floori(_last_view.end.y / span) + 1):
		for tx in range(floori(_last_view.position.x / span), floori(_last_view.end.x / span) + 1):
			var tex: Variant = _tiles.get(Vector3i(tx, ty, _last_level))
			if tex != null:
				out.append([Rect2(tx * span, ty * span, span, span), tex])
	return out


# A tile wholly out at sea (the coast never reaches the island radius) is left undrawn.
func _tile_on_island(key: Vector3i) -> bool:
	var span := TILE * pow(2.0, key.z)
	var nearest := Vector2(clampf(0.0, key.x * span, (key.x + 1) * span), clampf(0.0, key.y * span, (key.y + 1) * span))
	return nearest.length() < _island_radius_m


# A tile is sampled with a one-cell border (so slopes and contours match across tile edges).
func _start_tile(key: Vector3i) -> void:
	var n := TILE + 2
	_job_key = key
	_job_cell = 0
	_job_heights = PackedFloat32Array()
	_job_kind = PackedByteArray()
	_job_ring = PackedByteArray()
	_job_heights.resize(n * n)
	_job_kind.resize(n * n)
	_job_ring.resize(n * n)


func _sample_cell() -> void:
	var cell := pow(2.0, _job_key.z)
	var n := TILE + 2
	var i := _job_cell
	var x := _job_key.x * TILE * cell + (i % n - 0.5) * cell
	var y := _job_key.y * TILE * cell + (floori(i / float(n)) - 0.5) * cell
	if _terrain.on_land(x, y):
		_job_kind[i] = 2 if _terrain.is_lake(x, y) else 1
		_job_heights[i] = _terrain.height(x, y, PackedInt32Array(), false)
		_job_ring[i] = _terrain.ring_index(x, y)
	_job_cell += 1
	if _job_cell == n * n:
		var img := paint(_job_heights, _job_kind, _job_ring, n, n, cell).get_region(Rect2i(1, 1, TILE, TILE))
		_tiles[_job_key] = ImageTexture.create_from_image(img)
		_job_cell = -1


# The lab's colouring, given every cell's height, kind (0 sea, 1 land, 2 lake) and ring; `cell_m`
# is a cell's width in metres. Higher ground is lighter over the first map_lift_range_m above water.
static func paint(heights: PackedFloat32Array, kind: PackedByteArray, ring: PackedByteArray, cols: int, rows: int, cell_m: float) -> Image:
	var cfg := Config.data
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	var h_at := func(c: int, r: int) -> float: return heights[clampi(r, 0, rows - 1) * cols + clampi(c, 0, cols - 1)]
	var palette: PackedColorArray = cfg.map_ring_colors
	var water: float = cfg.free_roam.water_level_m
	for r in rows:
		for c in cols:
			var i := r * cols + c
			if kind[i] == 0:
				img.set_pixel(c, r, Color.TRANSPARENT)
				continue
			if kind[i] == 2:
				img.set_pixel(c, r, cfg.map_lake_color)
				continue
			var slope: float = ((h_at.call(c + 1, r) - h_at.call(c - 1, r)) + (h_at.call(c, r + 1) - h_at.call(c, r - 1))) / (2.0 * cell_m)
			var shade := clampf(0.85 - slope * 1.2, 0.35, 1.3)
			var band := floori(heights[i] / cfg.map_contour_m)
			if band != floori(h_at.call(c + 1, r) / cfg.map_contour_m) or band != floori(h_at.call(c, r + 1) / cfg.map_contour_m):
				shade *= 0.7
			var lift := clampf((heights[i] - water) / cfg.map_lift_range_m, 0.0, 1.0) * 60.0 / 255.0
			var base := palette[ring[i] % palette.size()]
			img.set_pixel(c, r, Color(base.r * shade + lift, base.g * shade + lift, base.b * shade + lift))
	return img

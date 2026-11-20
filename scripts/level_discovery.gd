class_name LevelDiscovery
extends RefCounted
# Docs: features/level-editor.md ("Map discovery") — update in the same change as this file.
# Tests: tests/headless/test_level_discovery.gd — extend in the same change.
# Which parts of a level the player has driven near: a coarse byte grid over the level's square, 0 hidden,
# 255 shown, with a soft edge. LevelMap stamps the car's position into it while driving and draws
# everything outside it under fog; it is saved per level file (LevelView.save_pose).

var size_m := 0.0     # the level's side, centred on the origin
var cell_m := 10.0    # one grid cell's side
var cells := 0        # grid cells per side
var grid := PackedByteArray()
var changed := false  # set by a stamp that showed something new; whoever saves clears it
var _rgba := PackedByteArray()  # the fog image's pixels once fog_image has built them, kept in step by stamp


func _init(level_size_m: float = 600.0, cell: float = 10.0) -> void:
	size_m = level_size_m
	cell_m = maxf(cell, 1.0)
	cells = maxi(ceili(size_m / cell_m), 1)
	grid.resize(cells * cells)


# Shows everything within `radius_m` of the world spot (x, z), fading out over the last `feather_m`; true if anything new showed.
func stamp(p: Vector2, radius_m: float, feather_m: float) -> bool:
	var any := false
	var half := size_m / 2.0
	var cx := (p.x + half) / cell_m
	var cz := (p.y + half) / cell_m
	var r := radius_m / cell_m
	var f := maxf(feather_m / cell_m, 0.001)
	var x0 := maxi(floori(cx - r), 0)
	var x1 := mini(ceili(cx + r), cells - 1)
	var z0 := maxi(floori(cz - r), 0)
	var z1 := mini(ceili(cz + r), cells - 1)
	for z in range(z0, z1 + 1):
		var dz := z + 0.5 - cz
		var row := z * cells
		for x in range(x0, x1 + 1):
			var d := sqrt((x + 0.5 - cx) ** 2 + dz * dz)
			if d >= r:
				continue
			var v := int(clampf((r - d) / f, 0.0, 1.0) * 255.0)
			if v > grid[row + x]:
				grid[row + x] = v
				any = true
				if not _rgba.is_empty():
					_rgba[(row + x) * 4 + 3] = 255 - v
	changed = changed or any
	return any


# How shown the world spot (x, z) is, 0 to 1 (the cell it falls in; outside the square is hidden).
func shown(p: Vector2) -> float:
	var half := size_m / 2.0
	var x := floori((p.x + half) / cell_m)
	var z := floori((p.y + half) / cell_m)
	if x < 0 or z < 0 or x >= cells or z >= cells:
		return 0.0
	return grid[z * cells + x] / 255.0


# The fog over the map: one pixel per cell, row 0 at the north (-z) edge like the map image, opaque where hidden.
# The pixels are built once (a loop over every cell) and then only patched by stamp, so reopening the map is cheap.
func fog_image(color: Color) -> Image:
	if _rgba.is_empty():
		_rgba.resize(grid.size() * 4)
		var r := color.r8
		var g := color.g8
		var b := color.b8
		for i in grid.size():
			_rgba[i * 4] = r
			_rgba[i * 4 + 1] = g
			_rgba[i * 4 + 2] = b
			_rgba[i * 4 + 3] = 255 - grid[i]
	return Image.create_from_data(cells, cells, false, Image.FORMAT_RGBA8, _rgba)


# The saved form: which level, the grid's cell size, and the grid deflated and base64'd (mostly zeros, so small).
func to_save(level: String) -> Dictionary:
	return {"level": level, "size": size_m, "cell": cell_m, "grid": Marshalls.raw_to_base64(grid.compress(FileAccess.COMPRESSION_DEFLATE))}


# Restores a `to_save` dictionary into this grid; anything saved for another level, size or cell size is ignored (returns false).
func load_save(saved: Variant, level: String) -> bool:
	if not saved is Dictionary or saved.get("level") != level \
			or not is_equal_approx(float(saved.get("size", -1.0)), size_m) or not is_equal_approx(float(saved.get("cell", -1.0)), cell_m):
		return false
	var raw := Marshalls.base64_to_raw(String(saved.get("grid", "")))
	if raw.is_empty():
		return false
	var g := raw.decompress(grid.size(), FileAccess.COMPRESSION_DEFLATE)
	if g.size() != grid.size():
		return false
	grid = g
	_rgba = PackedByteArray()
	return true

class_name LevelSpectators
extends Node3D
# Docs: features/spectators.md — update in the same change as this file.
# Tests: tests/headless/test_level_spectators.gd — extend in the same change.
# The level view's spectator groups from the save's `spectators` ({x, z, r, n}): each is a live SpectatorGroup that exists only while the car is near.

const CHECK_S := 0.5
const PLACE_TRIES := 30

var car: Node3D
var groups: Array = []
var _view: Node
var _bake: LevelBake
var _buildings: LevelBuildings
var _live := {}
var _since := 0.0


func setup(list: Array, view: Node, bake: LevelBake, buildings: LevelBuildings) -> void:
	groups = list
	_view = view
	_bake = bake
	_buildings = buildings


func _process(dt: float) -> void:
	_since += dt
	if car == null or _since < CHECK_S:
		return
	_since = 0.0
	refresh(Vector2(car.global_position.x, car.global_position.z))


# Spawns the groups the car has come near and frees the ones it has left.
func refresh(car_xz: Vector2) -> void:
	var cfg: GameConfig = Config.data
	for i in groups.size():
		var g: Dictionary = groups[i]
		var d := car_xz.distance_to(Vector2(g.x, g.z))
		var alive := _live.has(i) and is_instance_valid(_live[i])
		if wants_alive(alive, d, cfg.level_spectator_spawn_m, cfg.level_spectator_despawn_m) == alive:
			continue
		if alive:
			_live[i].queue_free()
			_live.erase(i)
		else:
			var group := _spawn(i, g)
			if group != null:
				_live[i] = group


func live_count() -> int:
	var c := 0
	for i in _live:
		if is_instance_valid(_live[i]):
			c += 1
	return c


func _spawn(i: int, g: Dictionary) -> SpectatorGroup:
	var cfg: GameConfig = Config.data
	if not cfg.spectators_enabled:
		return null
	var p := cfg.spectator_params()
	var centre := Vector2(g.x, g.z)
	var r := float(g.r)
	var reach: float = r + p["road_probe_m"] + 2.0
	var road := road_cells_near(centre, reach, _bake.surface_at)
	var obstacles := tree_points_near(_bake, centre, reach + p["tree_avoid_m"])
	if _buildings != null:
		for q in _buildings.footprint_points:
			if q.distance_to(centre) <= reach + p["tree_avoid_m"]:
				obstacles.append(q)
	var grid := SpectatorScatter.build_point_grid(obstacles, p["tree_cell_m"])
	var seed_value := int(ScatterMath.hash01(i, 0, 0, 71) * 1_000_000.0)
	var members := place(centre, r, int(g.n), cfg.spectator_separation_m, road, grid, p["tree_cell_m"], p["tree_avoid_m"], seed_value)
	if members.is_empty():
		return null
	var meshes := Crowd.level_meshes()
	p["homes"] = edge_homes(members, road, cfg.level_spectator_edge_gap_m, cfg.spectator_separation_m * 1.5)
	p["road_probe_m"] = cfg.level_spectator_road_probe_m
	p["w_anchor"] = cfg.level_spectator_walk_mps
	p["seed"] = seed_value
	p["ragdoll_pool_size"] = 0
	p["face_car"] = true
	p["meshes"] = meshes
	p["models"] = assign_models(members.size(), meshes.size(), seed_value)
	var group := SpectatorGroup.new()
	group.name = "Spectators%d" % i
	add_child(group)
	group.setup(members, car, _view, road, grid, p)
	return group


# Whether a group should exist: it appears inside `spawn_m` and stays until the car is past `despawn_m`.
static func wants_alive(alive: bool, dist: float, spawn_m: float, despawn_m: float) -> bool:
	return dist <= (despawn_m if alive else spawn_m)


# Up to `count` seeded standing spots inside the disc, off the road, clear of obstacles and at least `separation` apart.
static func place(centre: Vector2, radius: float, count: int, separation: float, road_cells: Dictionary,
		obstacle_grid: Dictionary, cell: float, avoid: float, seed_value: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for _k in count * PLACE_TRIES:
		if out.size() >= count:
			break
		var p := centre + Vector2.from_angle(rng.randf() * TAU) * radius * sqrt(rng.randf())
		if ScatterMath.on_road(p, road_cells) or SpatialGrid.near_point(p, obstacle_grid, cell, avoid):
			continue
		var clear := true
		for q in out:
			if q.distance_squared_to(p) < separation * separation:
				clear = false
				break
		if clear:
			out.append(p)
	return out


# Where each member should stand: just off the road's edge when there is room, else where it is.
# Nearest-road members claim the verge first; later ones step back towards their own spot until clear of earlier homes.
static func edge_homes(members: PackedVector2Array, road_cells: Dictionary, gap: float, spacing: float) -> PackedVector2Array:
	var homes := members.duplicate()
	var edge := PackedVector2Array()
	for c: Vector2i in road_cells:
		for o in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if not road_cells.has(c + o):
				edge.append((Vector2(c) + Vector2(0.5, 0.5)) * ScatterMath.CELL_M)
				break
	if edge.is_empty():
		return homes
	var near := PackedVector2Array()
	var near_d := PackedFloat32Array()
	var order: Array[int] = []
	for i in members.size():
		var best := edge[0]
		for q in edge:
			if q.distance_squared_to(members[i]) < best.distance_squared_to(members[i]):
				best = q
		near.append(best)
		near_d.append(best.distance_to(members[i]))
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return near_d[a] < near_d[b])
	var taken := PackedVector2Array()
	for i in order:
		var orig := members[i]
		var reach := ScatterMath.CELL_M * 0.5 + gap
		var dir := (orig - near[i]).normalized()
		var target := near[i] + dir * reach
		var pick := orig
		if near_d[i] > reach:
			var back := orig - target
			var steps := int(back.length() / spacing)
			for k in steps + 1:
				var p := target + back.normalized() * k * spacing
				if k == steps and k * spacing >= back.length():
					break
				if ScatterMath.on_road(p, road_cells):
					continue
				var free := true
				for t in taken:
					if t.distance_to(p) < spacing:
						free = false
						break
				if free:
					pick = p
					break
		homes[i] = pick
		taken.append(pick)
	return homes


# A model index for each member, seeded so a respawned group looks the same.
static func assign_models(n: int, models: int, seed_value: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(n)
	if models <= 1:
		return out
	for i in n:
		out[i] = int(ScatterMath.hash01(i, 0, seed_value, 73) * models) % models
	return out


# Road cells (ScatterMath's raster) in the box round `centre`, where `surface` ((x, z) -> Vector2 whose x is the road weight) says road.
static func road_cells_near(centre: Vector2, reach: float, surface: Callable) -> Dictionary:
	var cells := {}
	var step := ScatterMath.CELL_M
	var lo := ScatterMath.cell_of(centre - Vector2(reach, reach))
	var hi := ScatterMath.cell_of(centre + Vector2(reach, reach))
	for cx in range(lo.x, hi.x + 1):
		for cz in range(lo.y, hi.y + 1):
			if (surface.call((cx + 0.5) * step, (cz + 0.5) * step) as Vector2).x > 0.5:
				cells[Vector2i(cx, cz)] = true
	return cells


# Baked tree positions within `reach` of `centre`.
static func tree_points_near(bake: LevelBake, centre: Vector2, reach: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	if bake.tree_tile_n <= 0:
		return out
	var a := bake.tree_tile_of(centre.x - reach, centre.y - reach)
	var b := bake.tree_tile_of(centre.x + reach, centre.y + reach)
	var n := bake.tree_tile_n
	for tz in range(floori(float(a) / n), floori(float(b) / n) + 1):
		for tx in range(a % n, b % n + 1):
			var t := tz * n + tx
			for k in range(bake.tree_tile_first[t], bake.tree_tile_first[t + 1]):
				var at := Vector2(bake.tree_xf[k * 12 + 3], bake.tree_xf[k * 12 + 11])
				if at.distance_to(centre) <= reach:
					out.append(at)
	return out

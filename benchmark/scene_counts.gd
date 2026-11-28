class_name SceneCounts
extends Node
# Scene counts golden: lists every tree, bush, building, fence, log pile and spectator near a few pinned road spots
# once streaming has finished and before anything moves, so a port or refactor can be checked to put the same world
# in the same places. NOT part of the test suite. Run on demand (features/benchmark.md):
#
#   godot --headless --fixed-fps 60 res://benchmark/scene_counts.tscn -- [--golden] [--seed=90210] [--out=<file>] [--check[=<golden>]] [--bless]

const SPOTS := [0.1, 0.35, 0.6, 0.85]  # fractions along the road samples, as tools/level_draw_calls.gd picks them
const RADIUS_M := 100.0  # inside the ground cover's reach, so every bush in range has been built
const TOLERANCE_M := 0.01
const DEFAULT_OUT := "user://scene_counts.jsonl"
const GOLDEN_PATH := "res://goldens/scene_counts.jsonl.gz"  # written only by ./bless.sh scene_counts (--bless)
const FIXTURE_PROFILE_PATH := "user://scene_counts_profile.json"  # never written: save_disabled is on


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var out_path := DEFAULT_OUT
	var check_path := ""
	var bless := false
	var rng_seed := Benchmark.RNG_SEED
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out_path = arg.get_slice("=", 1)
		elif arg == "--check":
			check_path = GOLDEN_PATH
		elif arg.begins_with("--check="):
			check_path = arg.get_slice("=", 1)
		elif arg == "--bless":
			bless = true
		elif arg.begins_with("--seed="):
			rng_seed = int(arg.get_slice("=", 1))
	Save.profile_path = FIXTURE_PROFILE_PATH
	Save.profile = Save._default_profile()
	Save.save_disabled = true
	Benchmark.active = true
	Benchmark.golden = true
	Config.data.threaded_chunk_build = false
	Config.data.threaded_tree_build = false
	RngStreams.reseed(rng_seed)
	var world := (load(Scenes.WORLD) as PackedScene).instantiate()
	add_child(world)
	var level := world.get_node("Level") as LevelView
	await level.loaded
	get_tree().paused = true  # crowds must not steer, nor the car settle, while the spots are listed
	var car := world.get_node("Car") as VehicleBody3D
	level._streamer.focus = car  # a profile with no car parks the focus at the start shop instead
	level._streamer.brush = car
	var bake: LevelBake = level._bake
	var lines := PackedStringArray([JSON.stringify({"format": "scene_counts/1", "level_path": Config.data.level_path,
		"seed": rng_seed, "godot_version": Engine.get_version_info().string, "platform": OS.get_name(),
		"radius_m": RADIUS_M, "spots": SPOTS}, "", true, true)])
	for f: float in SPOTS:
		var i := clampi(int(f * bake.sx.size()), 0, bake.sx.size() - 2)
		var p := Vector2(bake.sx[i], bake.sz[i])
		var ahead := Vector3(bake.sx[i + 1] - p.x, 0.0, bake.sz[i + 1] - p.y)
		car.reset_to(level.road_pose(p, ahead.normalized()))
		await level._streamer.prefill_async()
		level._trees.settle()
		level._spectators.refresh(Vector2(1e9, 1e9))  # drop the crowds placed while loading, which may have walked
		level._spectators.refresh(p)
		lines.append(JSON.stringify({"spot": f, "x": p.x, "z": p.y, "items": collect(level, p)}, "", true, true))
	var text := "\n".join(lines) + "\n"
	if not _write(out_path, text) or (bless and not _write(GOLDEN_PATH, text)):
		get_tree().quit(1)
		return
	get_tree().quit(0 if check_path == "" or _check(lines, check_path) else 1)


# Every scene item within RADIUS_M of `at`, as [type, x, y, z]. Flat items (buildings, crowds, bushes) have y = 0.
static func collect(level: LevelView, at: Vector2) -> Array:
	var out := []
	var bake: LevelBake = level._bake
	for id in bake.tree_count():
		var x := bake.tree_xf[id * 12 + 3]
		var z := bake.tree_xf[id * 12 + 11]
		if not level._trees.is_fallen(id) and at.distance_to(Vector2(x, z)) <= RADIUS_M:
			out.append(["tree:" + bake.tree_kinds[bake.tree_kind[id]], x, bake.tree_xf[id * 12 + 7], z])
	for b: Dictionary in level._buildings.boxes:
		_add_flat(out, "building", b.centre, at)
	for body: StaticBody3D in (level.get_node("Fences") as LevelFences).bodies:
		for cs in body.get_children():
			_add(out, "fence", (cs as Node3D).global_position, at)
	for n in level.get_children():
		if n.name.begins_with("LogPile"):
			_add(out, "log_pile", (n as Node3D).global_position, at)
	for g in level._spectators._live.values():
		if not is_instance_valid(g) or g.is_queued_for_deletion():
			continue
		for k in g._pos.size():
			_add_flat(out, "spectator", g._pos[k], at)
			_add_flat(out, "spectator_home", g._home[k], at)
	for field in level._streamer.cover.find_children("BushInteraction", "", true, false):
		if field is BushField and not field.get_parent().is_queued_for_deletion():
			for q: Vector2 in field._points:
				_add_flat(out, "bush", q, at)
	return out


static func _add(out: Array, type: String, p: Vector3, at: Vector2) -> void:
	if at.distance_to(Vector2(p.x, p.z)) <= RADIUS_M:
		out.append([type, p.x, p.y, p.z])


static func _add_flat(out: Array, type: String, p: Vector2, at: Vector2) -> void:
	_add(out, type, Vector3(p.x, 0.0, p.y), at)


## Pairs each item of `a` with an unused item of `b` of the same type within `tol` metres, nearest first, and returns
## what found no partner: {"only_a": [...], "only_b": [...]}. Positions aren't rounded, since two values either side
## of a rounding boundary would never match however close they are.
static func match_items(a: Array, b: Array, tol: float = TOLERANCE_M) -> Dictionary:
	var grid := {}
	for j in b.size():
		var key := _cell(b[j], tol)
		if not grid.has(key):
			grid[key] = []
		grid[key].append(j)
	var used := {}
	var only_a := []
	for item: Array in a:
		var c := _cell(item, tol)
		var best := -1
		var best_d := INF
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					for j: int in grid.get(c + Vector3i(dx, dy, dz), []):
						var d := _pos(item).distance_to(_pos(b[j]))
						if not used.has(j) and b[j][0] == item[0] and d <= tol and d < best_d:
							best = j
							best_d = d
		if best < 0:
			only_a.append(item)
		else:
			used[best] = true
	var only_b := []
	for j in b.size():
		if not used.has(j):
			only_b.append(b[j])
	return {"only_a": only_a, "only_b": only_b}


static func _pos(item: Array) -> Vector3:
	return Vector3(item[1], item[2], item[3])


static func _cell(item: Array, tol: float) -> Vector3i:
	return Vector3i((_pos(item) / tol).floor())


# Writes `text` to `path`, gzipped when the path ends in .gz.
func _write(path: String, text: String) -> bool:
	if path.begins_with("res://"):
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("scene counts: can't write %s" % path)
		return false
	var bytes := text.to_utf8_buffer()
	file.store_buffer(bytes.compress(FileAccess.COMPRESSION_GZIP) if path.ends_with(".gz") else bytes)
	file.close()
	print("scene counts: wrote %s" % path)
	return true


static func _read(path: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(path)
	return (bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP) if path.ends_with(".gz") else bytes).get_string_from_utf8()


# Matches this run's spots against a golden file's, printing every unmatched item; true when all match.
func _check(lines: PackedStringArray, golden_path: String) -> bool:
	var golden := _read(golden_path).strip_edges().split("\n")
	if golden.size() != lines.size():
		push_error("scene counts: %s has %d spots, this run %d" % [golden_path, golden.size() - 1, lines.size() - 1])
		return false
	var ok := true
	for i in range(1, lines.size()):
		var want: Dictionary = JSON.parse_string(golden[i])
		var got: Dictionary = JSON.parse_string(lines[i])
		var diff := match_items(want["items"], got["items"])
		for item in diff.only_a:
			print("scene counts: spot %s: golden only: %s" % [got["spot"], item])
		for item in diff.only_b:
			print("scene counts: spot %s: this run only: %s" % [got["spot"], item])
		ok = ok and diff.only_a.is_empty() and diff.only_b.is_empty()
	print("scene counts: %s %s" % ["matches" if ok else "differs from", golden_path])
	return ok

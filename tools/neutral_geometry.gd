class_name NeutralGeometry
# Docs: features/level-streamer.md — update in the same change as this file.
# Writes the level geometry the game builds at run time along the Hafren replay path (ground meshes, cover tiles, tuft meshes)
# into one neutral file, level_geometry.tapn, so the Godot-free viewer draws exactly what the game draws there.
# Run through tools/neutral_export.tscn -- --geometry=<dir>; it boots the world, so callers must await it.

const FILE := "level_geometry.tapn"
const SAMPLE_M := 50.0
const Replay := preload("res://benchmark/level_replay.gd")
const ARRAY_NAMES := {Mesh.ARRAY_VERTEX: "vertex", Mesh.ARRAY_NORMAL: "normal", Mesh.ARRAY_TANGENT: "tangent",
	Mesh.ARRAY_COLOR: "color", Mesh.ARRAY_TEX_UV: "uv", Mesh.ARRAY_TEX_UV2: "uv2", Mesh.ARRAY_INDEX: "index"}


static func export(dir: String) -> PackedStringArray:
	var ticks: PackedFloat32Array = FileAccess.open(Replay.DEFAULT_PATH, FileAccess.READ).get_var()["ticks"]
	var chunks := {}  # "level,x,z" -> [level, coord, n, mask, arrays]; a rebuilt chunk keeps its last arrays
	var cover := {}  # "x,z,key,far" -> [tile, key, far, buffer]
	var tufts := {}  # "key,far" -> [key, far, mesh]
	LevelStreamer.on_chunk_built = func(level: int, coord: Vector2i, n: int, mask: int, arrays: Array) -> void:
		chunks["%d,%d,%d" % [level, coord.x, coord.y]] = [level, coord, n, mask, arrays]
	GroundCover.on_layer_built = func(t: Vector2i, key: String, far: bool, buf: PackedFloat32Array, mesh: ArrayMesh) -> void:
		cover["%d,%d,%s,%s" % [t.x, t.y, key, far]] = [t, key, far, buf]
		tufts["%s,%s" % [key, far]] = [key, far, mesh]
	# The replay's fresh profile and main-thread streaming, so every machine builds the same chunks.
	var was_golden: bool = Benchmark.golden
	Benchmark.golden = true
	Save.profile_path = Replay.FIXTURE_PROFILE_PATH
	Save.profile = Save._default_profile()
	Save.save_disabled = true
	var tree := Engine.get_main_loop() as SceneTree
	var world: Node = (load(Scenes.WORLD) as PackedScene).instantiate()
	tree.root.add_child.call_deferred(world)
	await tree.process_frame
	var view := world.get_node("Level") as LevelView
	await view.loaded
	var streamer := view._streamer
	var marker := Node3D.new()
	world.add_child(marker)
	streamer.focus = marker
	var last := Vector3.INF
	for i in floori(ticks.size() / float(Replay.STRIDE)):
		var o := i * Replay.STRIDE + 9
		var p := Vector3(ticks[o], ticks[o + 1], ticks[o + 2])
		if last != Vector3.INF and p.distance_to(last) < SAMPLE_M:
			continue
		last = p
		marker.global_position = p
		await streamer.prefill_async()  # one synchronous pass in a golden run: ground, then cover
	LevelStreamer.on_chunk_built = Callable()
	GroundCover.on_layer_built = Callable()
	world.free()
	Benchmark.golden = was_golden
	return _write(dir.path_join(FILE), chunks, cover, tufts)


static func _write(path: String, chunks: Dictionary, cover: Dictionary, tufts: Dictionary) -> PackedStringArray:
	var header := {"kind": "level_geometry", "sample_m": SAMPLE_M, "chunks": [], "cover": [], "tuft_meshes": []}
	var raw := []  # [[name, bytes], ...]
	var indices := {}
	var keys := chunks.keys()
	keys.sort()
	for i in keys.size():
		var c: Array = chunks[keys[i]]
		var arrays: Array = c[4]
		header["chunks"].append({"level": c[0], "coord": [c[1].x, c[1].y], "n": c[2], "mask": c[3]})
		for a: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2]:
			raw.append(["chunk.%d.%s" % [i, ARRAY_NAMES[a]], arrays[a].to_byte_array()])
		indices[c[2]] = arrays[Mesh.ARRAY_INDEX]
	var sizes := indices.keys()
	sizes.sort()
	for n: int in sizes:
		raw.append(["indices.%d" % n, (indices[n] as PackedInt32Array).to_byte_array()])
	keys = cover.keys()
	keys.sort()
	for i in keys.size():
		var c: Array = cover[keys[i]]
		header["cover"].append({"tile": [c[0].x, c[0].y], "layer": c[1], "far": c[2], "count": int((c[3] as PackedFloat32Array).size() / 12.0)})
		raw.append(["cover.%d" % i, (c[3] as PackedFloat32Array).to_byte_array()])
	keys = tufts.keys()
	keys.sort()
	for i in keys.size():
		var t: Array = tufts[keys[i]]
		var mesh: ArrayMesh = t[2]
		var names := []
		if mesh.get_surface_count() > 0:  # a recipe with no geometry builds a mesh with no surface
			var arrays := mesh.surface_get_arrays(0)
			for a: int in ARRAY_NAMES:
				if arrays[a] != null:
					names.append(ARRAY_NAMES[a])
					raw.append(["tuft.%d.%s" % [i, ARRAY_NAMES[a]], arrays[a].to_byte_array()])
		header["tuft_meshes"].append({"layer": t[0], "far": t[1], "arrays": names})
	var sections := []
	var lines := PackedStringArray()
	for s: Array in raw:
		sections.append([s[0], NeutralFile.zip(s[1])])
		lines.append(NeutralFile.line(FILE, s[0], s[1]))
	var err := NeutralFile.write(path, header, sections)
	if err != OK:
		printerr("neutral_geometry: couldn't write %s (%s)" % [path, error_string(err)])
		return PackedStringArray()
	print("neutral_geometry: wrote %s, %d chunks, %d cover layers, %d tuft meshes, %.1f MB" % [path, chunks.size(),
		cover.size(), tufts.size(), FileAccess.get_file_as_bytes(path).size() / 1048576.0])
	lines.sort()
	return lines

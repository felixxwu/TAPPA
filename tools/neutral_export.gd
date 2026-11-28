extends Node
# Writes the neutral (Godot-free) files and appends Godot's side of the parity manifest that the Rust reader's output is diffed against.
# Run: godot --headless --path . res://tools/neutral_export.tscn -- --bake=res://tools/levels/x.json | --assets=<dir> | --geometry=<dir> | --camera=<dir>
# --bake writes <save>.bake.bin beside the save; every mode merges its lines into <dir>/godot.manifest (--out=<dir> for --bake, default build/neutral).


func _ready() -> void:
	var out_dir := "res://build/neutral"
	var jobs := []
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() < 2:
			continue
		if kv[0] == "--out":
			out_dir = kv[1]
		else:
			jobs.append(kv)
	var code := 0
	for kv: PackedStringArray in jobs:
		var lines := PackedStringArray()
		var dir := _abs(out_dir)
		match kv[0]:
			"--bake": lines = _bake(kv[1])
			"--assets":
				dir = _abs(kv[1])
				lines = await _call_optional("res://tools/neutral_assets.gd", "export_all", dir)
			"--geometry":
				dir = _abs(kv[1])
				lines = await _call_optional("res://tools/neutral_geometry.gd", "export", dir)
			"--camera":
				dir = _abs(kv[1])
				lines = await _call_optional("res://tools/neutral_camera.gd", "export", dir)
			_:
				printerr("neutral_export: unknown option %s" % kv[0])
				code = 1
				continue
		if lines.is_empty() and kv[0] in ["--bake", "--camera"]:
			code = 1
			continue
		_merge_manifest(dir, lines)
	get_tree().quit(code)


func _bake(save: String) -> PackedStringArray:
	var b := LevelBake.load_fresh(save)
	if b == null:
		printerr("neutral_export: %s is missing or stale; rebake it first" % LevelBake.bake_path(save))
		return PackedStringArray()
	if b.is_incomplete():
		printerr("neutral_export: %s has no visibility; finish it with tools/bake_level.sh" % LevelBake.bake_path(save))
		return PackedStringArray()
	var output := []
	var key_js := ProjectSettings.globalize_path("res://tools/neutral_key.js")
	if OS.execute("node", [key_js, ProjectSettings.globalize_path(save)], output) != 0 or output.is_empty():
		printerr("neutral_export: node tools/neutral_key.js failed: %s" % "".join(output))
		return PackedStringArray()
	var path := LevelBake.neutral_path(save)
	var err := b.save_neutral(path, String(output[0]).strip_edges())
	if err != OK:
		printerr("neutral_export: couldn't write %s (%s)" % [path, error_string(err)])
		return PackedStringArray()
	print("neutral_export: wrote %s" % path)
	var lines := b.manifest(path.get_file())
	lines.append_array(_level_lines(save))
	return lines


# The save's embedded images and tree rows, and the buildings sidecar, decoded the way the game decodes them.
func _level_lines(save: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(save))
	if d is Dictionary:
		var json_file := save.get_file()
		var level := LevelData.unpack(d)
		# per tree six f64: x, z, rot, sx, sy, and its species' index in the save's `kinds`
		var kinds: Array = d.get("kinds", [])
		var trees := PackedFloat64Array()
		for t: Dictionary in level.get("trees", []):
			trees.append_array([t["x"], t["z"], t["rot"], t["sx"], t["sy"], kinds.find(t["kind"])])
		out.append(NeutralFile.line(json_file, "json.trees", trees.to_byte_array()))
		var hm: Variant = level.get("heightmap", PackedFloat32Array())
		out.append(NeutralFile.line(json_file, "json.height", PackedFloat32Array(hm).to_byte_array()))
		out.append(NeutralFile.line(json_file, "json.cover", GroundCover.decode_cover(d)))
	var bin := save.get_basename() + ".buildings.bin"
	if FileAccess.file_exists(bin):
		var floats := PackedFloat32Array()
		for b: Dictionary in LevelBuildings.parse_bin(FileAccess.get_file_as_bytes(bin)):
			for k in ["p", "n", "uv", "c"]:
				floats.append_array(b[k])
		out.append(NeutralFile.line(bin.get_file(), "buildings.floats", floats.to_byte_array()))
	return out


# The asset and geometry exporters land separately; until their script exists the mode adds nothing.
func _call_optional(script_path: String, method: String, dir: String) -> PackedStringArray:
	if not ResourceLoader.exists(script_path):
		print("neutral_export: %s not there yet, skipping" % script_path)
		return PackedStringArray()
	DirAccess.make_dir_recursive_absolute(dir)
	var got: Variant = await load(script_path).call(method, dir)
	return PackedStringArray(got) if got is Array or got is PackedStringArray else PackedStringArray()


# Replaces any earlier line for the same file and field, so a mode can be rerun, and keeps the whole file sorted.
func _merge_manifest(dir: String, lines: PackedStringArray) -> void:
	if lines.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("godot.manifest")
	var by_key := {}
	if FileAccess.file_exists(path):
		for l in FileAccess.get_file_as_string(path).split("\n", false):
			by_key[l.get_slice("\t", 0) + "\t" + l.get_slice("\t", 1)] = l
	for l in lines:
		by_key[l.get_slice("\t", 0) + "\t" + l.get_slice("\t", 1)] = l
	var all := PackedStringArray(by_key.values())
	all.sort()
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("\n".join(all) + "\n")
	f.close()


# A relative dir is taken from the project root, so `--assets=build/neutral` means the repo's build/neutral.
func _abs(dir: String) -> String:
	if dir.is_absolute_path():
		return ProjectSettings.globalize_path(dir)
	return ProjectSettings.globalize_path("res://" + dir)

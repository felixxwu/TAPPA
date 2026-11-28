extends GutTest
# Guards determinism: game code draws only from RngStreams, never Godot's global RNG or an unseeded
# generator, so a replay with the same --seed repeats exactly. See features/determinism.md.

const SCRIPTS_DIR := "res://scripts"
const EXEMPT := "rng_streams.gd"


func _scripts(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd") and f != EXEMPT:
			out.append(dir_path.path_join(f))
	for sub in d.get_directories():
		_scripts(dir_path.path_join(sub), out)


func test_no_script_uses_the_global_or_an_unseeded_rng() -> void:
	var global_call := RegEx.create_from_string(
		"(?<![\\w.])(randf|randi|randf_range|randi_range|randfn|randomize|seed)\\s*\\(")
	var collection := RegEx.create_from_string("\\.(shuffle|pick_random)\\(")
	var new_rng := RegEx.create_from_string("var\\s+(\\w+)\\s*:?=\\s*RandomNumberGenerator\\.new\\(\\)")
	var paths: Array[String] = []
	_scripts(SCRIPTS_DIR, paths)
	assert_gt(paths.size(), 100, "scripts/ must be readable")
	var bad: Array[String] = []
	for path in paths:
		var text := FileAccess.get_file_as_string(path)
		var n := 0
		for line in text.split("\n"):
			n += 1
			if line.strip_edges().begins_with("#"):
				continue
			if global_call.search(line) or collection.search(line):
				bad.append("%s:%d %s" % [path, n, line.strip_edges()])
		for m in new_rng.search_all(text):
			var v := m.get_string(1)
			if not (text.contains("%s.seed =" % v) or text.contains("%s.state =" % v)):
				bad.append("%s: %s is never seeded" % [path, v])
	assert_eq(bad, [] as Array[String], "use RngStreams.make / shared instead:\n" + "\n".join(bad))

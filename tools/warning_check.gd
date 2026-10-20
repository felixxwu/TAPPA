extends Node
# Dev tool: compile every script in the project (with the autoloads present) and print every
# GDScript WARNING the compiler raises. The test runner treats a warning as an error the first time
# a test happens to load that script, so a warning in a rarely loaded file (one only the stage scene
# uses, say) fails whichever unrelated test compiles it first. This lists them all up front.
#   godot --headless -d --path . res://tools/warning_check.tscn [-- --all]
# (-d is required: without the debug flag the compiler raises no warnings at all.)

class Catcher:
	extends Logger
	var found: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, _backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_WARNING and file.ends_with(".gd"):
			found.append("%s:%d  %s  %s" % [file, line, code, rationale])


func _ready() -> void:
	var catcher := Catcher.new()
	OS.add_logger(catcher)
	var count := 0
	for dir in ["res://scripts", "res://tests/headless", "res://tools"]:
		for path in _files_under(dir):
			count += 1
			ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE)
	OS.remove_logger(catcher)
	var unique := {}
	for w in catcher.found:
		unique[w] = true
	# Game scripts are what a test loads mid-run, so only their warnings fail a test; the tests'
	# and tools' own warnings are listed with --all.
	var game := 0
	var all := "--all" in OS.get_cmdline_user_args()
	for w: String in unique:
		var is_game := w.begins_with("res://scripts/")
		game += int(is_game)
		if is_game or all:
			print("WARNING: ", w)
	print("warning check: %d scripts, %d warnings in game scripts (%d in tests/tools; --all lists them)"
		% [count, game, unique.size() - game])
	get_tree().quit(1 if game > 0 else 0)


func _files_under(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		out.append_array(_files_under(dir.path_join(sub)))
	return out

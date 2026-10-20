extends Node
# Dev tool: load every script in the project (with the autoloads present, unlike `--check-only`)
# and report the ones that fail to compile. Exits 1 on any failure.
#   godot --headless --path . res://tools/compile_check.tscn
# Written for the free-roam demolition (todo/2026-10-19-free-roam-pivot.md stage 8), where
# deleting a system must not leave a dangling reference that only a rarely-loaded script hits.

func _ready() -> void:
	var failed: Array[String] = []
	var count := 0
	for dir in ["res://scripts", "res://tests/headless", "res://tools"]:
		for path in _scripts_under(dir):
			count += 1
			var s := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) as Script
			if s == null or not s.can_instantiate() and not _is_static_only(s):
				failed.append(path)
	var scenes := 0
	for path in _files_under("res://", ".tscn"):
		if path.begins_with("res://addons") or path == "res://tools/compile_check.tscn":
			continue
		scenes += 1
		if ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REUSE) == null:
			failed.append(path)
	for f in failed:
		print("COMPILE FAIL: ", f)
	print("compile check: %d scripts, %d scenes, %d failed" % [count, scenes, failed.size()])
	get_tree().quit(1 if not failed.is_empty() else 0)


func _is_static_only(s: Script) -> bool:
	# An abstract or RefCounted-only helper may not instantiate here but still compiled.
	return s.has_source_code() and s.get_instance_base_type() != StringName()


func _scripts_under(dir: String) -> PackedStringArray:
	return _files_under(dir, ".gd")


func _files_under(dir: String, ext: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		if f.ends_with(ext):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		if not sub.begins_with("."):
			out.append_array(_files_under(dir.path_join(sub), ext))
	return out

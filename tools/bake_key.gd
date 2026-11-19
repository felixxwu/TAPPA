extends Node
# Prints a save's bake key and whether its .bake.res is usable, so the publish and fetch scripts never re-implement LevelBake's key.
# Run: godot --headless --path . res://tools/bake_key.tscn -- res://tools/levels/x.json   ->  "bake_key: <key> <ok|missing|stale|incomplete>"


func _ready() -> void:
	var save := ""
	for a in OS.get_cmdline_user_args():
		save = a
	var key := LevelBake.key_of(save)
	var status := "missing"
	if FileAccess.file_exists(LevelBake.bake_path(save)):
		var b := load(LevelBake.bake_path(save)) as LevelBake
		status = "stale" if b == null or b.source_key != key else ("incomplete" if b.is_incomplete() else "ok")
	print("bake_key: %s %s" % [key.replace("/", "-"), status])
	get_tree().quit()

extends GutTest
# Every export preset must ship the files the game reads at runtime outside the resource system.
# The level view reads its save (GameConfig.dev_level_path) with FileAccess, so a preset whose
# exclude filter swallows it (Android's old `tools/*`) boots to a loading screen that never ends.

const PRESETS := "res://export_presets.cfg"


func _filters(value: String) -> PackedStringArray:
	var out := PackedStringArray()
	for f in value.split(",", false):
		out.append(f.strip_edges())
	return out


func _matches(path: String, filters: PackedStringArray) -> bool:
	for f in filters:
		if path.matchn(f) or path.get_file().matchn(f):
			return true
	return false


func test_every_preset_ships_the_level_save() -> void:
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(PRESETS), OK, "export_presets.cfg loads")
	var level := String(Config.data.dev_level_path).trim_prefix("res://")
	var checked := 0
	for section in cfg.get_sections():
		if section.ends_with(".options") or not section.begins_with("preset."):
			continue
		var name := String(cfg.get_value(section, "name", section))
		var include := _filters(String(cfg.get_value(section, "include_filter", "")))
		var exclude := _filters(String(cfg.get_value(section, "exclude_filter", "")))
		assert_true(_matches(level, include), "%s includes %s" % [name, level])
		assert_false(_matches(level, exclude), "%s doesn't exclude %s" % [name, level])
		checked += 1
	assert_gt(checked, 0, "found export presets")

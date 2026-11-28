extends GutTest
# Every export preset must ship the files the game reads at runtime outside the resource system.
# The level view reads its save (GameConfig.level_path) with FileAccess, so a preset whose
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
	var level := String(Config.data.level_path).trim_prefix("res://")
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


func _ios_options() -> Dictionary:
	var cfg := ConfigFile.new()
	cfg.load(PRESETS)
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options") \
				and cfg.get_value(section, "platform", "") == "iOS":
			var out := {}
			for key in cfg.get_section_keys(section + ".options"):
				out[key] = cfg.get_value(section + ".options", key)
			return out
	return {}


func test_ios_preset_ships_to_the_app_store() -> void:
	var o := _ios_options()
	assert_false(o.is_empty(), "there is an iOS preset")
	assert_eq(int(o.get("application/export_method_release", -1)), 0, "release builds are App Store builds")
	assert_ne(String(o.get("application/bundle_identifier", "")), "", "the iOS preset has a bundle ID")


func test_ios_privacy_manifest_declares_cloud_save_data() -> void:
	# App Store review compares the privacy manifest with what the app sends: cloud save
	# sends an email address and an account ID, used only to make the save work.
	const APP_FUNCTIONALITY := 2
	var o := _ios_options()
	assert_false(bool(o.get("privacy/tracking_enabled", true)), "the app does no tracking")
	for kind in ["email_address", "user_id"]:
		var base := "privacy/collected_data/%s/" % kind
		assert_true(bool(o.get(base + "collected", false)), "%s is declared as collected" % kind)
		assert_false(bool(o.get(base + "used_for_tracking", true)), "%s is not used for tracking" % kind)
		assert_true(int(o.get(base + "collection_purposes", 0)) & APP_FUNCTIONALITY != 0,
			"%s is collected for app functionality" % kind)

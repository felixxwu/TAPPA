extends GutTest
# Fixture saves (tests/fixtures/saves/) loaded by Save, written back, and compared as parsed values,
# so a field the loader or writer drops or reshapes fails here. Fixture numbers are opaque data, not tuning.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_save_round_trip.json"
const FIXTURES := "res://tests/fixtures/saves/"

var _save: Node


func before_each() -> void:
	CarFixtures.install()  # the fixture cars use the synthetic roster, so _sanitise keeps them
	_save = SaveTestHelpers.redirect(TEST_PATH)


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	CarFixtures.restore()


# Numbers become floats (JSON has one number type) and `updated_utc` goes, since save() restamps it.
static func normalise(v: Variant) -> Variant:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_ARRAY:
			var items := []
			for item in v:
				items.append(normalise(item))
			return items
		TYPE_DICTIONARY:
			var out := {}
			for k in v:
				if k != "updated_utc":
					out[k] = normalise(v[k])
			return out
	return v


# The path of the first difference between two normalised values, or "" when equal.
static func first_difference(a: Variant, b: Variant, path := "") -> String:
	if typeof(a) != typeof(b):
		return path + " (type)"
	if a is Dictionary:
		for k in (a as Dictionary).keys() + (b as Dictionary).keys():
			if not a.has(k) or not b.has(k):
				return "%s.%s (missing)" % [path, k]
			var d := first_difference(a[k], b[k], "%s.%s" % [path, k])
			if d != "":
				return d
		return ""
	if a is Array:
		if a.size() != b.size():
			return path + " (size)"
		for i in a.size():
			var d := first_difference(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	return "" if a == b else "%s (%s != %s)" % [path, a, b]


func _read_json(path: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	assert_true(parsed is Dictionary, "%s parses as a JSON object" % path)
	return parsed if parsed is Dictionary else {}


# Load a fixture through Save, write it straight back, and return [expected, written].
# Expected is the fixture with any key it leaves out backfilled from the default profile.
func _round_trip(fixture: String) -> Array:
	var source := _read_json(FIXTURES + fixture)
	var f := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	f.store_string(FileAccess.get_file_as_string(FIXTURES + fixture))  # the fixture's own text, so `1e-7` and `3.0` reach the parser as written
	f.close()
	_save.load_or_new()
	_save.save_now()
	var expected: Dictionary = _save._default_profile().merged(source, true)
	return [normalise(expected), normalise(_read_json(TEST_PATH))]


func test_each_fixture_round_trips() -> void:
	for fixture in ["full.json", "minimal.json", "odd_numbers.json"]:
		var r := _round_trip(fixture)
		assert_eq(first_difference(r[0], r[1]), "", "%s survives load and save unchanged" % fixture)


func test_full_fixture_has_every_default_profile_key() -> void:
	var full := _read_json(FIXTURES + "full.json")
	for key in _save._default_profile():
		assert_true(full.has(key), "full.json carries the profile key '%s'" % key)


func test_full_fixture_has_every_setting_the_game_writes() -> void:
	var settings: Dictionary = _read_json(FIXTURES + "full.json").get("settings", {})
	var written := _written_setting_keys()
	assert_gt(written.size(), 0, "the scan found the game's set_setting calls")
	for key in written:
		assert_true(settings.has(key), "full.json's settings carry '%s' (written by %s)" % [key, written[key]])


func test_fixture_cars_come_from_the_synthetic_roster() -> void:
	var ids := CarFixtures.cars().map(func(c: Dictionary) -> String: return c["id"])
	for fixture in ["full.json", "odd_numbers.json"]:
		for car: Dictionary in _read_json(FIXTURES + fixture).get("cars", []):
			assert_has(ids, car["model_id"], "%s uses fixture cars, never the shipped catalogue" % fixture)


func test_normalise_ignores_number_type_and_the_save_stamp() -> void:
	var a: Variant = normalise({"n": 3, "list": [1, {"x": 2}], "updated_utc": "then"})
	var b: Variant = normalise({"n": 3.0, "list": [1.0, {"x": 2.0}], "updated_utc": "now"})
	assert_eq(first_difference(a, b), "")
	assert_eq(first_difference(a, normalise({"n": 3.0, "list": [1.0, {}]})), ".list[1].x (missing)")


# Every settings key some script writes: `set_setting(KEY, …)` where KEY is a string literal,
# a const in the same file, or `ClassName.CONST`. Maps key -> the file that writes it.
func _written_setting_keys() -> Dictionary:
	var sources := {}
	var classes := {}
	var class_re := RegEx.create_from_string("(?m)^class_name\\s+(\\w+)")
	for path in _gd_files("res://scripts"):
		var text := FileAccess.get_file_as_string(path)
		sources[path] = text
		var m := class_re.search(text)
		if m != null:
			classes[m.get_string(1)] = path
	var call_re := RegEx.create_from_string("(?<!func )set_setting\\(\\s*(\"[^\"]*\"|[A-Za-z_][\\w.]*)")
	var keys := {}
	for path: String in sources:
		for m in call_re.search_all(sources[path]):
			var arg := m.get_string(1)
			var key := arg.trim_prefix("\"").trim_suffix("\"") if arg.begins_with("\"") else ""
			if key == "":
				var parts := arg.split(".")
				var owner_path: String = path if parts.size() == 1 else classes.get(parts[0], "")
				key = _const_string(sources.get(owner_path, ""), parts[-1])
			assert_ne(key, "", "%s: can't resolve the settings key '%s' (extend this scan)" % [path, arg])
			if key != "":
				keys[key] = path
	return keys


func _const_string(text: String, name: String) -> String:
	var m := RegEx.create_from_string("const\\s+%s\\s*(?::=|:\\s*String\\s*=)\\s*\"([^\"]*)\"" % name).search(text)
	return m.get_string(1) if m != null else ""


func _gd_files(dir: String) -> Array[String]:
	var out: Array[String] = []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_gd_files(dir.path_join(d)))
	return out

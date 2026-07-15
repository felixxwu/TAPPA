extends GutTest

# UpgradesMenu is the reusable per-car upgrades UI shared by the HQ lift and the
# car-park detune popup. These tests use synthetic owned-car dicts (no catalogue
# dependency) and check the component's LOGIC/behaviour, not any tuned value.

const UpgradesMenuScript = preload("res://scripts/upgrades_menu.gd")

func _first_part_id() -> String:
	# Any non-consumable, non-drivetrain catalogue part — the test needs a real slot
	# option to toggle, but does not depend on which one (catalogue-agnostic).
	for def in UpgradeLibrary.all():
		if bool(def.get("consumable", false)):
			continue
		if String(def.get("slot", "")) == "drivetrain":
			continue
		return String(def.get("id", ""))
	return ""

func _menu(owned: Dictionary, on_change := Callable(), on_swap := Callable()) -> Control:
	var m = UpgradesMenuScript.new()
	add_child_autofree(m)
	m.setup(owned, on_change, on_swap)
	return m

func test_setup_renders_against_the_given_owned_car() -> void:
	var owned := {"instance_id": 42, "model_id": "synthetic", "installed_upgrades": [], "upgrades": {}, "tuning": {}}
	var m = _menu(owned)
	assert_eq(int(m._owned.get("instance_id", -1)), 42, "renders against the passed owned car, not a global")
	assert_gt(m.get_child_count(), 0, "builds rows")

func test_stats_line_present_and_recomputes_on_rebuild() -> void:
	var owned := {"instance_id": 7, "model_id": "synthetic", "installed_upgrades": [], "upgrades": {}, "tuning": {}}
	var m = _menu(owned)
	assert_not_null(m._stats_label, "has a stats label")
	# Rebuild with a fitted part; the label recomputes (contains the p/w + G markers).
	owned["installed_upgrades"] = [_first_part_id()]
	m.rebuild()
	# The house theme uppercases displayed text, so match case-insensitively.
	assert_string_contains(m._stats_label.text.to_lower(), "hp/tonne")
	assert_string_contains(m._stats_label.text.to_lower(), "g")

func test_swap_row_only_when_on_swap_valid() -> void:
	var owned := {"instance_id": 8, "model_id": "synthetic", "installed_upgrades": [], "upgrades": {}, "tuning": {}}
	var without = _menu(owned)
	assert_false(_has_swap_button(without), "no swap row when on_swap is invalid (popup)")
	var with_swap = _menu(owned, Callable(), func(): pass)
	assert_true(_has_swap_button(with_swap), "swap row present when on_swap is valid (lift)")

func _has_swap_button(m: Control) -> bool:
	for node in m.find_children("*", "Button", true, false):
		if String((node as Button).text).to_lower().begins_with("swap engine"):
			return true
	return false

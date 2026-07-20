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


# pw_limit advisory — uses the CarFixtures synthetic roster so the assertions never
# pin a real catalogue car's stats, only the logic (over/under a given limit).

func before_each() -> void:
	CarFixtures.install()

func after_each() -> void:
	CarFixtures.restore()

func _owned_fixture_car() -> Dictionary:
	return {
		"instance_id": 99, "model_id": "fx_light_rwd",
		"installed_upgrades": [], "upgrades": {}, "tuning": {},
	}

func _menu_with_limit(owned: Dictionary, pw_limit: float) -> Control:
	var m = UpgradesMenuScript.new()
	add_child_autofree(m)
	m.setup(owned, Callable(), Callable(), pw_limit)
	return m

func test_no_limit_by_default_not_over() -> void:
	var m = _menu_with_limit(_owned_fixture_car(), -1.0)
	assert_false(m.over_pw_limit(), "no limit => never over")

func test_limit_below_ratio_flags_over() -> void:
	# A limit of 1 hp/tonne is below any real car's ratio, so it must read as over.
	var m = _menu_with_limit(_owned_fixture_car(), 1.0)
	assert_true(m.over_pw_limit(), "ratio above the limit reads as over")
	assert_false(m.can_close(), "cannot close while over the limit")

func test_limit_above_ratio_not_over() -> void:
	# A limit of 100000 hp/tonne is above any real car's ratio, so it's within.
	var m = _menu_with_limit(_owned_fixture_car(), 100000.0)
	assert_false(m.over_pw_limit(), "ratio below the limit reads as within")
	assert_true(m.can_close(), "can close when within the limit")


# The gated close button (bind_close_button): over a set limit it goes red and refuses
# to close; within the limit (or no limit) it closes via the host callback.

func test_close_button_blocks_and_reddens_over_the_limit() -> void:
	var m = _menu_with_limit(_owned_fixture_car(), 1.0)  # 1 hp/tonne → always over
	var closed := [0]
	var btn := Button.new()
	btn.text = "Back"
	add_child_autofree(btn)
	m.bind_close_button(btn, func(): closed[0] += 1)
	assert_ne(btn.modulate, Color(1, 1, 1, 1), "over-limit button is painted (red), not neutral")
	m.request_close()
	assert_eq(closed[0], 0, "closing is blocked while over the limit")

func test_close_button_allows_close_within_the_limit() -> void:
	var m = _menu_with_limit(_owned_fixture_car(), 100000.0)  # generous → within
	var closed := [0]
	var btn := Button.new()
	btn.text = "Back"
	add_child_autofree(btn)
	m.bind_close_button(btn, func(): closed[0] += 1)
	assert_eq(btn.modulate, Color(1, 1, 1, 1), "within-limit button is not reddened")
	m.request_close()
	assert_eq(closed[0], 1, "closing works when within the limit")

func test_close_button_closes_freely_with_no_limit() -> void:
	var m = _menu(_owned_fixture_car())  # no pw_limit
	var closed := [0]
	var btn := Button.new()
	btn.text = "Back"
	add_child_autofree(btn)
	m.bind_close_button(btn, func(): closed[0] += 1)
	m.request_close()
	assert_eq(closed[0], 1, "no limit → always closes")
	assert_eq(btn.text, "Back", "no limit → keeps the plain Back label")


# Engine detune moved here from the tuning panel — it's a p/w knob, so the upgrades
# menu owns its slider. (fixture roster is installed by before_each above.)

func test_has_an_engine_detune_slider() -> void:
	var m = _menu(_owned_fixture_car())
	assert_not_null(m._detune_slider, "the upgrades menu hosts the detune slider")

func test_detune_slider_is_full_range() -> void:
	# Eligibility is enforced at Start, not by capping the slider, so detune always spans
	# the full 0-100% range — with or without a rally pw_limit passed.
	assert_eq(_menu(_owned_fixture_car())._detune_slider.max_value, 100.0, "reaches 100% (no limit)")
	assert_eq(_menu_with_limit(_owned_fixture_car(), 160.0)._detune_slider.max_value, 100.0,
		"still reaches 100% when a pw_limit is shown")

func test_editing_detune_writes_fraction_and_fires_callback() -> void:
	var owned := _owned_fixture_car()
	var fired := [0]
	var m = _menu(owned, func(): fired[0] += 1)
	m._detune_slider.value = 50.0   # emits value_changed → 0.5 fraction
	assert_almost_eq(float(owned["tuning"]["engine_detune"]), 0.5, 0.001, "50% slider stores 0.5")
	assert_gt(fired[0], 0, "on_change fired")

func test_detune_label_shows_pw_but_not_the_cap() -> void:
	# The detune label carries the live p/w readout; the max-p/w cap moved to the close
	# button, so the label never mentions the limit even when one is set.
	var with_limit = _menu_with_limit(_owned_fixture_car(), 160.0)
	assert_string_contains(with_limit._detune_value.text.to_lower(), "hp/tonne")
	assert_false(with_limit._detune_value.text.to_lower().contains("max"),
		"the cap is on the button now, not the detune label")


# The weight slot: a p/w lever with free ballast + an earned lightweight, each labelled
# by a rounded kg delta. Tests exercise the LOGIC (free/earned gating, label format),
# never the authored multipliers or a specific part id.

func test_weight_delta_label_is_signed_and_rounded_to_100() -> void:
	var m = _menu(_owned_fixture_car())
	# (mult-1)*base, rounded to the nearest 100, signed with a "kg" suffix.
	assert_eq(m._weight_delta_label(1.5, 1000.0), "+500kg", "adds mass, +signed, exact 100")
	assert_eq(m._weight_delta_label(0.8, 1000.0), "-200kg", "removes mass, -signed")
	assert_eq(m._weight_delta_label(1.5, 1030.0), "+500kg", "515 rounds to the nearest 100")
	assert_eq(m._weight_delta_label(1.0, 1000.0), "+0kg", "no change reads +0kg")

func test_weight_slot_ballast_is_free_lightweight_is_gated() -> void:
	# On a car that owns no weight parts, every FREE weight option is selectable and every
	# non-free (earned) one is greyed — iterating the slot's parts as opaque contract.
	var owned := _owned_fixture_car()  # installed_upgrades == []
	var m = _menu(owned)
	var found_free := false
	var found_gated := false
	for node in m.find_children("*", "Button", true, false):
		var b := node as Button
		if not b.has_meta("upgrade_focus_key"):
			continue
		var key := String(b.get_meta("upgrade_focus_key"))
		if not key.begins_with("opt:weight:"):
			continue
		var pid := key.trim_prefix("opt:weight:")
		if pid == "none":
			assert_false(b.disabled, "Stock is always available")
			continue
		if UpgradeLibrary.is_free(pid):
			found_free = true
			assert_false(b.disabled, "free ballast is selectable without being installed")
		else:
			found_gated = true
			assert_true(b.disabled, "an earned weight option is greyed until installed")
	assert_true(found_free, "the weight slot exposes at least one free ballast option")
	assert_true(found_gated, "the weight slot exposes at least one earn-gated option")

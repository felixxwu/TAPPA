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

# Mark the engine-swap capability's gating special won / not won for the duration of a test.
# The row is gated on it, so a test that wants the row has to open the gate first.
func _set_engine_swaps_unlocked(unlocked: bool) -> void:
	var rallies: Dictionary = Save.profile.get("rallies", {})
	if unlocked:
		rallies[RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY] = {"completed": true, "best_placed": 1}
	else:
		rallies.erase(RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY)
	Save.profile["rallies"] = rallies


func test_swap_row_only_when_on_swap_valid() -> void:
	var owned := {"instance_id": 8, "model_id": "synthetic", "installed_upgrades": [], "upgrades": {}, "tuning": {}}
	_set_engine_swaps_unlocked(true)
	var without = _menu(owned)
	assert_false(_has_swap_button(without), "no swap row when on_swap is invalid (popup)")
	var with_swap = _menu(owned, Callable(), func(): pass)
	assert_true(_has_swap_button(with_swap), "swap row present when on_swap is valid (lift)")
	_set_engine_swaps_unlocked(false)


func test_swap_row_is_absent_entirely_while_the_capability_is_locked() -> void:
	# Not a disabled row: absent. A permanently-dead row just invites "when do I get this?",
	# which is the same reason star-locked part options are hidden rather than greyed.
	var owned := {"instance_id": 9, "model_id": "synthetic", "installed_upgrades": [], "upgrades": {}, "tuning": {}}
	_set_engine_swaps_unlocked(false)
	var locked = _menu(owned, Callable(), func(): pass)
	assert_false(_has_swap_button(locked), "no swap row at all while swapping is star-locked")
	_set_engine_swaps_unlocked(true)
	var unlocked = _menu(owned, Callable(), func(): pass)
	assert_true(_has_swap_button(unlocked), "winning the gating special brings the row in")
	_set_engine_swaps_unlocked(false)


# The label text of every slot row the menu built, so a test can assert a row is ABSENT
# (label and all) rather than merely disabled.
func _row_labels(m: Control) -> Array:
	var out: Array = []
	for row in m.get_children():
		for child in row.get_children():
			if child is Label:
				out.append(String(child.text))
			elif child is Container:
				for inner in child.get_children():
					if inner is Label:
						out.append(String(inner.text))
	return out


func test_a_slot_whose_every_option_is_star_locked_gets_no_row_at_all() -> void:
	# "Not even the label": with every real option in a slot still behind a star gate, the row
	# would be a bare label plus an unusable Stock button — exactly the dead end that hiding
	# locked options exists to remove. Derived from the catalogue: find a slot whose parts are
	# ALL gated, rather than pinning "drivetrain".
	assert_gt(UpgradeLibrary.all().size(), 0, "UpgradeLibrary.all() is non-empty (else this test asserts nothing)")
	var by_slot := {}
	for def in UpgradeLibrary.all():
		var slot := String(def.get("slot", ""))
		if slot == "" or bool(def.get("consumable", false)) or UpgradeLibrary.is_hidden_slot(slot):
			continue
		if not by_slot.has(slot):
			by_slot[slot] = []
		by_slot[slot].append(String(def.get("id", "")))
	var fully_gated := ""
	for slot in by_slot:
		var all_gated := true
		for pid in by_slot[slot]:
			if UpgradeLibrary.unlocked_by_rally(pid) == "":
				all_gated = false
				break
		if all_gated:
			fully_gated = String(slot)
			break
	if fully_gated == "":
		pass_test("no slot is entirely star-gated in this catalogue; nothing to assert")
		return
	var owned := {"instance_id": 11, "model_id": "synthetic", "installed_upgrades": [],
		"upgrades": {}, "tuning": {}}
	var m = _menu(owned)
	for text in _row_labels(m):
		assert_false(text.to_lower().begins_with(fully_gated.to_lower()),
			"a fully star-locked slot contributes no row label (%s)" % fully_gated)


func test_a_star_locked_option_is_absent_from_its_slot_row() -> void:
	# The slot still has an ungated option, so the ROW appears — but the locked option must
	# not, not even greyed.
	var gated := ""
	var ungated_sibling := ""
	for def in UpgradeLibrary.all():
		var pid := String(def.get("id", ""))
		var slot := String(def.get("slot", ""))
		if slot == "" or bool(def.get("consumable", false)) or UpgradeLibrary.is_hidden_slot(slot):
			continue
		if UpgradeLibrary.unlocked_by_rally(pid) == "":
			continue
		for other in UpgradeLibrary.all():
			if String(other.get("slot", "")) == slot \
					and UpgradeLibrary.unlocked_by_rally(String(other.get("id", ""))) == "" \
					and not bool(other.get("consumable", false)):
				gated = pid
				ungated_sibling = String(other.get("id", ""))
				break
		if gated != "":
			break
	if gated == "":
		pass_test("no star-gated part shares a slot with an ungated one; nothing to assert")
		return
	var owned := {"instance_id": 12, "model_id": "synthetic", "installed_upgrades": [],
		"upgrades": {}, "tuning": {}}
	var m = _menu(owned)
	var visible: Array = m._slot_parts(UpgradeLibrary.slot_of(gated), [])["parts"]
	var ids: Array = []
	for def in visible:
		ids.append(String(def.get("id", "")))
	assert_does_not_have(ids, gated, "a star-locked option is not offered at all")
	assert_has(ids, ungated_sibling, "its ungated slot-mate still is")


func test_a_fitted_part_stays_visible_even_if_its_gate_is_shut() -> void:
	# The gate governs EARNING a part, never keeping one — a car must never display less than
	# it is actually running.
	var gated := ""
	for def in UpgradeLibrary.all():
		var pid := String(def.get("id", ""))
		if UpgradeLibrary.unlocked_by_rally(pid) != "" and not UpgradeLibrary.is_hidden_slot(
				String(def.get("slot", ""))):
			gated = pid
			break
	if gated == "":
		pass_test("no star-gated part authored; nothing to assert")
		return
	var owned := {"instance_id": 13, "model_id": "synthetic", "installed_upgrades": [gated],
		"upgrades": {}, "tuning": {}}
	var m = _menu(owned)
	var ids: Array = []
	for def in m._slot_parts(UpgradeLibrary.slot_of(gated), [gated])["parts"]:
		ids.append(String(def.get("id", "")))
	assert_has(ids, gated, "an already-fitted part is shown despite its gate being shut")

func _has_swap_button(m: Control) -> bool:
	for node in m.find_children("*", "Button", true, false):
		if String((node as Button).text).to_lower().begins_with("swap engine"):
			return true
	return false


# pw_limit advisory — uses the CarFixtures synthetic roster so the assertions never
# pin a real catalogue car's stats, only the logic (over/under a given limit).

func before_each() -> void:
	CarFixtures.install()
	UpgradeFixtures.install()

func after_each() -> void:
	UpgradeFixtures.restore()
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

# A challenge-locked car is NOT special-cased here: UpgradesMenu is per-car and knows
# nothing about sessions. The ceiling is enforced by the pw_limit-bound close button,
# exactly like a career rally's pw_max — never by freezing the slider (a hard
# editable=false lock here was a real past bug). Same behaviour, locked or not.
func test_detune_slider_and_pw_gate_behave_identically_when_challenge_locked() -> void:
	var prior: Variant = Save.profile.get("challenge_run", {})
	for locked in [false, true]:
		var owned := _owned_fixture_car()
		owned["tuning"] = {"engine_detune": 1.0}
		var iid := int(owned["instance_id"])
		Save.profile["challenge_run"] = {"car_instance_id": iid} if locked else {}
		assert_eq(Save.is_challenge_locked(iid), locked, "setup: the lock state is what we asked for")
		# A ceiling at HALF this car's full-power ratio — derived from the same helper
		# under test, so no tuned value is pinned.
		var limit := _full_power_pw(owned) * 0.5
		var m = _menu_with_limit(owned, limit)
		var label := "locked" if locked else "unlocked"
		assert_true(m._detune_slider.editable, "%s: the detune slider stays editable" % label)
		assert_true(m.over_pw_limit(), "%s: full power reads as over a half-ratio ceiling" % label)
		assert_false(m.can_close(), "%s: cannot proceed while over the ceiling" % label)
		m._detune_slider.value = 25.0  # a quarter power — comfortably under half
		assert_false(m.over_pw_limit(), "%s: detuning under the ceiling clears the over-limit flag" % label)
		assert_true(m.can_close(), "%s: proceeding is allowed once under the ceiling" % label)
	Save.profile["challenge_run"] = prior

func _full_power_pw(owned: Dictionary) -> float:
	var full := owned.duplicate(true)
	full["tuning"] = {"engine_detune": 1.0}
	var entry := CarLibrary.by_id(String(full.get("model_id", "")))
	return CarLibrary.power_to_weight_hp_tonne(UpgradeLibrary.effective_meta(full, entry))

func test_detune_label_shows_pw_but_not_the_cap() -> void:
	# The detune label carries the live p/w readout; the max-p/w cap moved to the close
	# button, so the label never mentions the limit even when one is set.
	var with_limit = _menu_with_limit(_owned_fixture_car(), 160.0)
	assert_string_contains(with_limit._detune_value.text.to_upper(), "HP/T")
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


# --- Row layout ---------------------------------------------------------------

# The turbo slot carries the most options of any slot (Stock + every induction part), and
# they share ONE HFlowContainer with the slot label — a flow container, so anything that
# does not fit WRAPS onto a second line and the row grows a ragged extra line under it.
#
# Measured, not eyeballed: HFlowContainer reports its own line count, so this asserts the
# thing the player actually sees rather than a proxy for it. It is the option LABELS that
# decide the answer ("Supercharger" wrapped on its own; "Super" does not), so this is what
# stops a future rename quietly pushing the row onto two lines again.
func test_the_turbo_row_fits_on_one_line_with_every_option_shown() -> void:
	var slot := "turbo"
	var owned := {"instance_id": 77, "model_id": "synthetic", "upgrades": {}, "tuning": {}}
	# Every turbo part FITTED, which is the widest the row can ever be: a fitted part shows
	# its bare label, and each un-fitted one would otherwise be hidden or priced.
	var installed: Array = []
	for def in UpgradeLibrary.all():
		if String(def.get("slot", "")) == slot and not bool(def.get("consumable", false)):
			installed.append(String(def.get("id", "")))
	assert_gt(installed.size(), 1, "setup: the turbo slot has several options")
	owned["installed_upgrades"] = installed
	owned["disabled_upgrades"] = []

	var m = _menu(owned)
	# Give the menu a realistic width and let it lay out — a zero-width container would
	# report a wrap for every row and prove nothing.
	m.custom_minimum_size = Vector2(560, 0)
	m.size = Vector2(560, 400)
	await get_tree().process_frame
	await get_tree().process_frame

	var flow := _slot_flow(m, slot)
	assert_not_null(flow, "the turbo slot has a flow row")
	assert_eq(flow.get_line_count(), 1,
		"the turbo row's options all fit on one line")

	# PROVE THE MEASUREMENT IS LIVE. A line count that always read 1 — because the row was
	# never laid out, or was given unbounded width — would make the assertion above pass
	# whatever the labels said. Squeezing the menu must produce a wrap.
	m.custom_minimum_size = Vector2(120, 0)
	m.size = Vector2(120, 400)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_gt(flow.get_line_count(), 1,
		"a too-narrow menu DOES wrap the row — so the one-line result above was measured")


# The HFlowContainer holding `slot`'s label + option buttons, found by its label text so
# the test does not depend on child ordering.
func _slot_flow(m: Control, slot: String) -> HFlowContainer:
	for node in m.find_children("*", "HFlowContainer", true, false):
		for child in (node as HFlowContainer).get_children():
			if child is Label and String((child as Label).text).to_lower() == slot:
				return node
	return null

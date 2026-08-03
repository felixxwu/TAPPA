extends GutTest
# UpgradeReveal: the shared slot-spin reward card (features/menus.md). Normal
# parts land on an Upgrades/Next action row (granted fitted-disabled, no Apply/Keep
# — the player enables them later, either right now via Upgrades or later in the
# garage). There is no Apply/Keep choice any more — it existed only for a won repair
# kit, and repair kits are gone. Headless -> the slot resolves
# instantly, so the action row is reachable at once. A Skip button
# fast-forwards a real (non-headless) spin straight to the actual won item; tests
# force a real spin by flipping `_headless` post-construction.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const UpgradeFixtures = preload("res://tests/headless/upgrade_fixtures.gd")

var _save: Node

func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	UpgradeFixtures.install()
	_save = get_node("/root/Save")
	_save.profile_path = "user://test_upgrade_reveal_profile.json"
	_save.save_disabled = false
	_save.load_or_new()

func after_each() -> void:
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	UpgradeFixtures.restore()
	CarFixtures.restore()
	if RallySession.is_active():
		RallySession.abandon()
	if ChallengeSession.is_active():
		ChallengeSession.abandon()
	Save.profile["challenge_run"] = {}
	RallySession.auto_load_scenes = true
	RallyLibrary.reset()

func _make() -> UpgradeReveal:
	var w := UpgradeReveal.new()
	add_child_autofree(w)
	return w

func test_slottable_part_reveal_offers_upgrades_and_next() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "fx_aero", false)  # reward loop fitted it disabled
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal("fx_aero", id)
	await get_tree().process_frame
	assert_true(w._action_box.visible, "a normal part is one 'Next' step, no Apply/Keep choice")
	assert_true(_save.get_car(id)["installed_upgrades"].has("fx_aero"), "the part stays fitted")
	assert_false(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_aero"),
		"the part stays disabled — enabled via Next-into-garage or the Upgrades button now")
	assert_true(w._action_box.visible, "the Upgrades/Next row is shown once the reveal lands")
	assert_true(w._upgrades_button.visible, "an Upgrades button is offered")
	assert_true(w._next_button.visible, "a Next button is offered")
	assert_false(done[0], "finished does not fire until Next/Upgrades-done is pressed")
	w._next_button.pressed.emit()
	assert_true(done[0], "Next continues the flow exactly like the old immediate finish")

func test_a_won_consumable_lands_in_inventory_and_offers_next() -> void:
	# Every consumable now takes the same plain path — no branch offers to spend one
	# on the driven car, because the repair kit that used to do that is gone. A DAMAGED
	# car is used deliberately: that is exactly the state that used to divert here.
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.apply_damage(id, 200.0)
	assert_lt(float(_save.get_car(id)["hp"]), float(CarLibrary.by_id("fx_awd").get("max_hp", 0.0)),
		"precondition: the driven car is damaged")
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, id)
	await get_tree().process_frame
	assert_true(w._action_box.visible, "the Upgrades/Next row is shown, with no choice to make")
	assert_false(done[0], "finished does not fire until Next is pressed")
	w._next_button.pressed.emit()
	assert_true(done[0], "Next continues the flow")

func test_skip_button_hidden_when_spin_resolves_instantly() -> void:
	# Headless (the default in tests) resolves the spin synchronously, so there's
	# nothing to fast-forward — the Skip button must stay hidden.
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "fx_aero", false)
	var w := _make()
	w.reveal("fx_aero", id)
	await get_tree().process_frame
	assert_false(w._skip_button.visible, "no running spin to skip once it's already landed")

func test_skip_fast_forwards_a_running_spin_to_the_actual_won_item() -> void:
	# Force a REAL animated spin (as in normal, non-headless play) by flipping the
	# instance flag after construction, then press Skip immediately — it must land on
	# the actual won part without waiting out podium_slot_spin_time.
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "fx_aero", false)
	var w := _make()
	w._headless = false
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal("fx_aero", id)
	assert_true(w._skip_button.visible, "Skip appears while a real spin is animating")
	assert_false(done[0], "the reveal has not landed yet")
	w._skip_button.pressed.emit()
	assert_false(w._skip_button.visible, "Skip hides once the spin has landed")
	assert_true(w._reveal_done, "skipping counts as the spin having landed")
	assert_eq(w._slot_label.text, UITheme.caps(String(UpgradeLibrary.by_id("fx_aero").get("name", "fx_aero"))),
		"skipping lands on the actual won item, not a random reel stop")
	assert_true(w._action_box.visible, "the normal landing steps still run (Upgrades/Next shown) after a skip")
	assert_false(done[0], "finished waits for Next/Upgrades-done even after a skip")
	w._next_button.pressed.emit()
	assert_true(done[0], "Next finishes the flow after a skip")

func test_drivetrain_kit_installs_enabled_without_choice() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "fx_drivetrain", false)
	var w := _make()
	w.reveal("fx_drivetrain", id)
	await get_tree().process_frame
	assert_true(w._action_box.visible, "the drivetrain kit goes straight to the action row")
	assert_true(UpgradeLibrary.is_enabled(_save.get_car(id), "fx_drivetrain"),
		"the drivetrain kit installs enabled")


# --- Upgrades button: opens the real UpgradesMenu, reusing the same rally p/w-limit
# warning the pre-stage start line / HQ garage popup use. -----------------------------

func test_upgrades_button_opens_the_real_upgrades_menu_component() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "fx_aero", false)
	var w := _make()
	w.reveal("fx_aero", id)
	await get_tree().process_frame
	assert_true(w._action_box.visible, "precondition: the action row is showing")
	w._upgrades_button.pressed.emit()
	assert_not_null(w._upgrades_menu, "pressing Upgrades builds the menu component")
	assert_true(w._upgrades_menu is UpgradesMenu,
		"it's the real UpgradesMenu component, not a stub reimplementation")
	assert_true(w._upgrades_overlay.visible, "the upgrades overlay is shown")
	assert_eq(int(w._upgrades_menu._owned.get("instance_id", -1)), id,
		"the menu is fed the driven car")

func test_upgrades_menu_surfaces_the_same_rally_over_limit_warning_as_pre_stage() -> void:
	# A synthetic rally with a p/w ceiling far below any fixture car's ratio — mirrors
	# test_upgrades_menu.gd's "1 hp/tonne is below any real car's ratio" pattern, so
	# this never depends on a specific catalogue rally/car, only the logic.
	var tiny_limit_rally: Dictionary = {
		"id": "fx_tiny_limit_reveal", "name": "Fixture Tiny Limit", "region": "home",
		"difficulty": 1, "special": false, "restriction": {"pw_max": 1.0}, "events": [],
	}
	RallyLibrary.override_for_test([tiny_limit_rally])
	RallySession.auto_load_scenes = false
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	RallySession.start_rally(tiny_limit_rally, _save.get_car(id), true)
	_save.install_upgrade(id, "fx_aero", false)
	var w := _make()
	w.reveal("fx_aero", id)
	await get_tree().process_frame
	w._upgrades_button.pressed.emit()
	assert_true(w._upgrades_menu.over_pw_limit(),
		"the driven car's build reads as over the active rally's p/w ceiling")
	assert_false(w._upgrades_menu.can_close(),
		"the menu blocks closing over the limit — same gate as the pre-stage popup")
	assert_true(String(w._upgrades_back.text).begins_with("Over limit"),
		"the Done button reddens/reprompts exactly like UpgradesMenu.bind_close_button does pre-stage")
	w._upgrades_back.pressed.emit()
	assert_true(w._upgrades_overlay.visible,
		"pressing Done while over the limit does not close the overlay")

func test_finishing_the_upgrades_menu_continues_the_flow_like_next() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_save.install_upgrade(id, "fx_aero", false)
	var w := _make()
	var done := [false]
	w.finished.connect(func() -> void: done[0] = true, CONNECT_ONE_SHOT)
	w.reveal("fx_aero", id)
	await get_tree().process_frame
	w._upgrades_button.pressed.emit()
	assert_true(w._upgrades_overlay.visible, "precondition: the overlay is open")
	assert_false(done[0], "finished has not fired yet — the player is inside Upgrades")
	w._upgrades_back.pressed.emit()  # no rally limit set → Done closes freely
	assert_false(w._upgrades_overlay.visible, "Done closes the overlay")
	assert_true(done[0], "finishing Upgrades continues the flow exactly like Next")


# --- Challenge run: the ceiling applies ----------------------------------------------
#
# The reveal's Upgrades overlay used to read RallySession.rally_id()'s restriction
# directly, which resolves to "no limit" mid-challenge (rally_id() is "") — so a
# challenge car had NO p/w gate here at all. It now goes through DrivingContext.

func _start_challenge_on(id: int) -> void:
	ChallengeSession.auto_load_scenes = false
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _save.get_car(id),
		int(Time.get_unix_time_from_system())), "setup: the challenge run starts")

func test_upgrades_overlay_gets_the_challenges_ceiling_not_no_limit() -> void:
	var car: Dictionary = _save.grant_car("fx_awd")
	var id := int(car["instance_id"])
	_start_challenge_on(id)
	assert_false(RallySession.is_active(), "setup: no rally is running alongside the challenge")
	_save.install_upgrade(id, "fx_aero", false)
	var w := _make()
	w.reveal("fx_aero", id)
	await get_tree().process_frame
	w._upgrades_button.pressed.emit()
	# Derived from the same accessor the code uses — the authored ceiling BAND is
	# tunable, so nothing pins a number; what matters is that a real cap arrived.
	assert_ne(w._upgrades_menu._pw_limit, DrivingContext.NO_LIMIT,
		"a challenge run's mid-run Upgrades overlay carries a real p/w ceiling")
	assert_eq(w._upgrades_menu._pw_limit, ChallengeLibrary.ceiling_for(ChallengeSession.period_key()),
		"and it's the period's own rolled ceiling")

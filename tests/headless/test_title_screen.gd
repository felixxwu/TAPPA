extends GutTest
# The title screen (features/world-session.md → "Title screen"): Continue / New World / Settings,
# the starter-car choice, and keyboard/gamepad navigation.

const TEST_PATH := "user://test_title_profile.json"

var _save: Node
var _title: TitleScreen
var _entered := [0]


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.profile = _save._default_profile()
	CarFixtures.install()
	_entered[0] = 0


func after_each() -> void:
	if is_instance_valid(_title):
		_title.free()
	CarFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _open() -> TitleScreen:
	_title = TitleScreen.new()
	_title.enter_world = func() -> void: _entered[0] += 1
	add_child(_title)
	await get_tree().process_frame
	await get_tree().process_frame
	return _title


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


func test_continue_is_only_offered_with_a_world() -> void:
	var t := await _open()
	assert_eq(CardUI.index_of(t.cards(), "Continue"), -1)
	t.free()
	WorldSession.new_world(3, String(CarLibrary.all()[0]["id"]))
	t = await _open()
	assert_eq(CardUI.index_of(t.cards(), "Continue"), 0, "Continue leads the list")
	assert_true(CardUI.pick(t.cards(), "Continue"))
	assert_eq(_entered[0], 1, "Continue drives into the world")


func test_the_starter_choice_is_the_cheapest_few_cars() -> void:
	var by_cost: Array = CarLibrary.all().duplicate()
	by_cost.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("cost", 0)) < int(b.get("cost", 0)))
	var choices := TitleScreen.starter_choices()
	assert_eq(choices.size(), mini(TitleScreen.STARTER_COUNT, by_cost.size()))
	for i in choices.size():
		assert_eq(int(CarLibrary.by_id(choices[i]).get("cost", 0)), int(by_cost[i].get("cost", 0)))


func test_new_world_picks_a_starter_and_drives_in() -> void:
	var t := await _open()
	assert_true(CardUI.pick(t.cards(), "New world"))
	await get_tree().process_frame
	assert_eq(t.view, TitleScreen.View.STARTER)
	assert_eq(t.cards().card_count(), TitleScreen.starter_choices().size(), "a card per starter car")
	var choice := TitleScreen.starter_choices()[1]
	t.cards().select(1, false)
	t.cards()._confirm_selected()
	t.cards().skip_confirm_flash()
	assert_true(WorldSession.has_world())
	assert_eq(String(WorldSession.active_car()["model_id"]), choice)
	assert_eq(_entered[0], 1)


func test_new_world_over_an_existing_world_asks_first() -> void:
	WorldSession.new_world(3, String(CarLibrary.all()[0]["id"]))
	var t := await _open()
	assert_true(CardUI.pick(t.cards(), "New world"))
	assert_not_null(ConfirmPopup.any_open(get_tree()), "a confirm guards the old world")
	assert_eq(t.view, TitleScreen.View.MAIN)
	ConfirmPopup.any_open(get_tree()).queue_free()
	await get_tree().process_frame


func test_the_title_screen_is_keyboard_and_gamepad_navigable() -> void:
	WorldSession.new_world(3, String(CarLibrary.all()[0]["id"]))
	var t := await _open()
	var vp := t.get_viewport()
	var cards := t.cards()
	assert_eq(vp.gui_get_focus_owner(), cards, "the card list has the cursor")
	assert_eq(cards.selected_index(), 0, "on Continue")
	var nav := MenuNav.of(t._page)
	nav._unhandled_input(_press("menu_right"))
	assert_eq(cards.selected_index(), 1, "right moves to New world")
	nav._unhandled_input(_press("menu_right"))
	assert_eq(cards.selected_index(), 2, "and on to Settings")
	cards._confirm_selected()
	cards.skip_confirm_flash()
	await get_tree().process_frame
	assert_eq(t.view, TitleScreen.View.SETTINGS)
	await get_tree().process_frame
	t._settings_back()
	await get_tree().process_frame
	assert_eq(t.view, TitleScreen.View.MAIN, "back from Settings returns to the title")
	t._show(TitleScreen.View.STARTER)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(vp.gui_get_focus_owner(), t.cards())
	MenuNav.of(t._page)._unhandled_input(_press("ui_cancel"))
	await get_tree().process_frame
	assert_eq(t.view, TitleScreen.View.MAIN, "back from the starter choice returns to the title")


func test_the_update_prompt_records_its_dismissal() -> void:
	var t := await _open()
	t.show_update_prompt(100, 120)
	var popup := ConfirmPopup.any_open(get_tree())
	assert_not_null(popup, "the prompt appears over the title")
	popup._actions[0]["callback"].call()  # Not now
	assert_eq(int(_save.get_setting(UpdateCheck.DISMISSED_SETTING, 0)), 120)
	popup.queue_free()
	await get_tree().process_frame


func test_the_build_version_label_is_never_in_the_nav_order() -> void:
	var t := await _open()
	var label := t._page.get_node_or_null("VersionLabel")
	if label == null:
		pass_test("an unstamped build shows no version label")
		return
	assert_eq((label as Control).focus_mode, Control.FOCUS_NONE)

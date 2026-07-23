extends GutTest
# Keyboard / gamepad menu navigation (features/menus.md → "Menu navigation"). Flat
# menus drive a cursor with Godot's native focus (focus_mode = FOCUS_ALL + the
# engine's ui_up/ui_down/ui_accept), so the theme's focus stylebox paints the cursor
# and arrow keys / D-pad / left-stick all work for free; the diegetic HQ stations keep
# their spatial menu_* handlers (covered in test_menu_flow.gd). This file checks the
# shared pieces: the input actions exist, and the shared SettingsMenu focuses its rows
# and steps back a level at a time.

const TEST_PATH := "user://test_menu_nav_profile.json"

var _save: Node


func before_each() -> void:
	_save = get_node("/root/Save")
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	RallyFixtures.install()


func after_each() -> void:
	RallyFixtures.restore()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# The six directional menu actions are all mapped (up/down were added for the HQ
# hub + map-table cursors alongside the pre-existing left/right/select/back).
func test_menu_input_actions_exist() -> void:
	for action in ["menu_up", "menu_down", "menu_left", "menu_right", "menu_select", "menu_back"]:
		assert_true(InputMap.has_action(action), "the %s action is mapped" % action)


# WASD is bound on the directional menu actions — this is what lets the MenuNav
# framework fill the gap in Godot's native ui_* defaults (which bind arrows + D-pad
# + stick but NOT WASD). Guards the framework contract against a silent regression.
func test_wasd_is_bound_on_menu_directions() -> void:
	var wants := {"menu_up": KEY_W, "menu_down": KEY_S, "menu_left": KEY_A, "menu_right": KEY_D}
	for action in wants:
		var found := false
		for e in InputMap.action_get_events(action):
			if e is InputEventKey and (e as InputEventKey).physical_keycode == wants[action]:
				found = true
		assert_true(found, "%s is bound to its WASD key" % action)


# Build a throwaway flat menu (a column of buttons) so we can exercise the framework
# directly without standing up a whole game scene.
func _make_flat_menu(count: int) -> Control:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	for i in count:
		var b := Button.new()
		b.text = "OPT %d" % i
		b.focus_mode = Control.FOCUS_NONE  # framework should flip these to FOCUS_ALL
		b.custom_minimum_size = Vector2(120, 30)
		root.add_child(b)
	return root


func _press(action: String) -> InputEventAction:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	return e


# attach() makes every button focusable and lands the cursor on the first one.
func test_attach_makes_buttons_focusable_and_grabs_first() -> void:
	var menu := _make_flat_menu(3)
	add_child_autofree(menu)
	MenuNav.attach(menu)
	await get_tree().process_frame  # deferred focus grab
	for b in menu.get_children():
		if b is Button:
			assert_eq((b as Button).focus_mode, Control.FOCUS_ALL, "button made focusable")
	assert_eq(menu.get_viewport().gui_get_focus_owner(), menu.get_child(0),
		"the first button is focused on open")


# A widget can opt out of the framework's focus wiring with the menu_nav_skip meta
# (used by the diegetic HQ station buttons that keep FOCUS_NONE).
# A ScrollContainer inside a MenuNav menu is switched to follow_focus, so directional
# nav onto a scrolled-out row auto-scrolls it into view (general list-nav fix).
func test_attach_enables_scroll_follow_focus() -> void:
	var menu := Control.new()
	var scroll := ScrollContainer.new()
	menu.add_child(scroll)
	var list := VBoxContainer.new()
	scroll.add_child(list)
	for i in 3:
		list.add_child(Button.new())
	add_child_autofree(menu)
	assert_false(scroll.follow_focus, "follow_focus off before attach")
	MenuNav.attach(menu)
	await get_tree().process_frame
	assert_true(scroll.follow_focus, "attach turns follow_focus on")


func test_menu_nav_skip_meta_is_left_focus_none() -> void:
	var menu := _make_flat_menu(2)
	(menu.get_child(1) as Button).set_meta("menu_nav_skip", true)
	add_child_autofree(menu)
	MenuNav.attach(menu)
	await get_tree().process_frame
	assert_eq((menu.get_child(1) as Button).focus_mode, Control.FOCUS_NONE,
		"a menu_nav_skip widget is left un-focusable")


# WASD (menu_down) moves the focus cursor to the next widget — the gap the framework
# fills over Godot's native ui_* (which don't bind WASD).
func test_wasd_moves_focus() -> void:
	var menu := _make_flat_menu(3)
	add_child_autofree(menu)
	var nav := MenuNav.attach(menu)
	await get_tree().process_frame  # grab first + lay out so neighbours resolve
	assert_eq(menu.get_viewport().gui_get_focus_owner(), menu.get_child(0), "start on first")
	nav._unhandled_input(_press("menu_down"))
	assert_eq(menu.get_viewport().gui_get_focus_owner(), menu.get_child(1),
		"menu_down (W/S family) moves the cursor down one")


# on_back fires for BOTH ui_cancel (Esc / gamepad B) and menu_back — the uneven
# back-routing the framework unifies.
func test_on_back_fires_for_ui_cancel_and_menu_back() -> void:
	var menu := _make_flat_menu(2)
	add_child_autofree(menu)
	var hits := [0]
	var nav := MenuNav.attach(menu, {on_back = func() -> void: hits[0] += 1})
	await get_tree().process_frame
	nav._unhandled_input(_press("ui_cancel"))
	nav._unhandled_input(_press("menu_back"))
	assert_eq(hits[0], 2, "on_back fired for both ui_cancel and menu_back")


# The framework goes inert while its menu is hidden, so a hidden overlay can't eat
# input meant for whatever is actually on screen.
func test_hidden_menu_does_not_consume_back() -> void:
	var menu := _make_flat_menu(2)
	add_child_autofree(menu)
	var hits := [0]
	var nav := MenuNav.attach(menu, {on_back = func() -> void: hits[0] += 1})
	await get_tree().process_frame
	menu.visible = false
	nav._unhandled_input(_press("menu_back"))
	assert_eq(hits[0], 0, "a hidden menu ignores back")


# The shared SettingsMenu rows are focusable, drilling into a category lands the
# cursor on that page's first row, and go_back() steps sub-page → list → (false).
func test_settings_menu_is_keyboard_navigable() -> void:
	var sm := SettingsMenu.new()
	add_child_autofree(sm)
	await get_tree().process_frame  # _ready builds the pages + shows the list

	assert_eq(sm.camera_rows[0]["button"].focus_mode, Control.FOCUS_ALL,
		"settings rows are focusable for keyboard/gamepad")

	# Drilling into a category focuses that page's first row (deferred grab).
	sm.show_camera()
	await get_tree().process_frame
	assert_eq(sm.get_viewport().gui_get_focus_owner(), sm.camera_rows[0]["button"],
		"opening the Camera page focuses its first row")

	# Back steps out one level: sub-page → list (consumed), then list → not consumed
	# (so the host closes Settings / runs its own bottom action).
	assert_true(sm.go_back(), "go_back from a sub-page is consumed")
	assert_true(sm.at_root(), "go_back returns to the category list")
	assert_false(sm.go_back(), "go_back at the root is left to the host")


# The Audio page carries a focusable music-volume slider that reflects the saved
# setting, so it is reachable and adjustable by keyboard/gamepad (not just mouse).
func test_audio_page_slider_is_focusable_and_reflects_saved_volume() -> void:
	var prev_disabled: bool = Save.save_disabled
	Save.save_disabled = true
	Save.set_setting(MusicDirector.SETTING_KEY, 0.5)

	var sm := SettingsMenu.new()
	add_child_autofree(sm)
	await get_tree().process_frame  # _ready builds the pages

	sm.show_audio()
	await get_tree().process_frame  # deferred focus grab settles

	assert_not_null(sm.music_slider, "audio page has a music slider")
	assert_eq(sm.music_slider.focus_mode, Control.FOCUS_ALL,
		"the slider is keyboard/gamepad focusable")
	assert_almost_eq(sm.music_slider.value, 0.5, 0.0001,
		"the slider reflects the saved volume")
	assert_eq(sm.get_viewport().gui_get_focus_owner(), sm.music_slider,
		"opening the Audio page focuses the slider")

	Save.save_disabled = prev_disabled


# The standings interstitial shows the event-only leaderboard first (for events
# after the first), its button is keyboard/gamepad-focusable, and pressing it
# switches to the combined-standings page (mid-rally). See features/menus.md.
func test_standings_event_page_then_combined_is_navigable() -> void:
	RallySession.auto_load_scenes = false
	var owned: Dictionary = _save.grant_car("mx5")
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	RallySession._opponent_field = [
		{"name": "Quick", "car_name": "Porsche 911", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
	]
	RallySession.report_event_result(50000)   # event 0 -> standings (first event: combined only)
	RallySession.continue_to_next_event()      # -> event 1
	RallySession.report_event_result(50000)   # event 1 -> standings (event-only first)

	var s := preload("res://standings.tscn").instantiate()
	add_child_autofree(s)
	await get_tree().process_frame

	assert_true(s.showing_event_page(), "a later event opens on the event-only page")
	assert_false(s.is_final_event(), "the 2nd of 3 events is not the final event")
	assert_eq(s._action_button.focus_mode, Control.FOCUS_ALL, "the page button is focusable")
	assert_eq(s.get_viewport().gui_get_focus_owner(), s._action_button, "the button is focused on entry")

	# Pressing the event-page button switches to the combined page (no scene change,
	# since this is a mid-rally event).
	s._action_button.pressed.emit()
	await get_tree().process_frame
	assert_false(s.showing_event_page(), "the button advances to the combined page")
	assert_eq(s.get_viewport().gui_get_focus_owner(), s._action_button, "focus re-grabs on the combined page")

	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true


# --- ButtonCursor (scripts/button_cursor.gd) ---------------------------------
# The manual left/right cursor the diegetic HQ stations (garage action row, tuning
# hub) use in place of native focus. hq.gd owns the index; the cursor owns the shared
# wrap / repaint / fire behaviour. These check that behaviour directly.

# wrapped() steps the index and wraps at both ends of the row.
func test_button_cursor_wraps_at_both_ends() -> void:
	var cursor := ButtonCursor.new()
	var buttons: Array = []
	for i in 4:
		buttons.append(Button.new())
	cursor.setup(buttons, [func() -> void: pass, func() -> void: pass,
		func() -> void: pass, func() -> void: pass])
	assert_eq(cursor.wrapped(2, 1), 3, "step forward advances one")
	assert_eq(cursor.wrapped(3, 1), 0, "stepping past the end wraps to the first")
	assert_eq(cursor.wrapped(0, -1), 3, "stepping back from the first wraps to the last")
	for b in buttons:
		b.free()


# An empty cursor never crashes: wrapped() returns the index unchanged and refresh() is
# a no-op (so hq can paint before the row is built).
func test_button_cursor_empty_is_safe() -> void:
	var cursor := ButtonCursor.new()
	assert_eq(cursor.wrapped(0, 1), 0, "wrapped() on an empty row returns the index")
	cursor.refresh(0)  # must not error
	cursor.activate(0)  # out of range -> no-op, must not error
	pass_test("empty ButtonCursor tolerates wrap/refresh/activate")


# activate(index) fires the action wired to that index; an out-of-range index no-ops.
func test_button_cursor_activate_fires_the_indexed_action() -> void:
	var cursor := ButtonCursor.new()
	var fired := [-1]
	var a := Button.new()
	var b := Button.new()
	cursor.setup([a, b], [
		func() -> void: fired[0] = 0,
		func() -> void: fired[0] = 1,
	])
	cursor.activate(1)
	assert_eq(fired[0], 1, "activate(1) fires the second action")
	cursor.activate(0)
	assert_eq(fired[0], 0, "activate(0) fires the first action")
	fired[0] = -1
	cursor.activate(5)  # out of range
	assert_eq(fired[0], -1, "an out-of-range activate fires nothing")
	a.free()
	b.free()


# refresh(index) paints exactly the button at `index` as focused and clears the rest —
# the manual equivalent of a native focus ring (UITheme.mark_focused).
func test_button_cursor_refresh_paints_only_the_focused_button() -> void:
	var cursor := ButtonCursor.new()
	var a := Button.new()
	var b := Button.new()
	var c := Button.new()
	add_child_autofree(a)
	add_child_autofree(b)
	add_child_autofree(c)
	cursor.setup([a, b, c], [func() -> void: pass, func() -> void: pass, func() -> void: pass])
	cursor.refresh(1)
	# mark_focused overrides the "normal" stylebox + font colour on the focused button
	# only; the others carry no such override.
	assert_false(a.has_theme_stylebox_override("normal"), "unfocused button has no cursor box")
	assert_true(b.has_theme_stylebox_override("normal"), "the focused button is painted")
	assert_false(c.has_theme_stylebox_override("normal"), "the other unfocused button is clear")
	# Moving the cursor clears the old highlight.
	cursor.refresh(0)
	assert_true(a.has_theme_stylebox_override("normal"), "the new index is painted")
	assert_false(b.has_theme_stylebox_override("normal"), "the old highlight is cleared")


# wrapped() skips DISABLED buttons in the travel direction (a disabled item is not a valid
# cursor stop, same as native focus) — so a disabled Change Car is stepped over.
func test_button_cursor_wrapped_skips_disabled() -> void:
	var cursor := ButtonCursor.new()
	var buttons: Array = []
	for i in 4:
		buttons.append(Button.new())
	buttons[1].disabled = true  # e.g. Change Car with only one owned car
	cursor.setup(buttons, [func() -> void: pass, func() -> void: pass,
		func() -> void: pass, func() -> void: pass])
	assert_eq(cursor.wrapped(0, 1), 2, "forward from 0 skips the disabled 1 to land on 2")
	assert_eq(cursor.wrapped(2, -1), 0, "backward from 2 skips the disabled 1 to land on 0")
	for b in buttons:
		b.free()


# settled(index) re-seats the cursor off a button that just became disabled, onto the next
# enabled one; activate() no-ops on a disabled index.
func test_button_cursor_settled_and_disabled_activate() -> void:
	var cursor := ButtonCursor.new()
	var fired := [-1]
	var buttons: Array = []
	for i in 3:
		buttons.append(Button.new())
	buttons[1].disabled = true
	cursor.setup(buttons, [
		func() -> void: fired[0] = 0,
		func() -> void: fired[0] = 1,
		func() -> void: fired[0] = 2,
	])
	assert_eq(cursor.settled(1), 2, "settled() nudges off the disabled index to the next enabled")
	assert_eq(cursor.settled(0), 0, "settled() leaves an already-enabled index alone")
	cursor.activate(1)  # disabled -> no-op
	assert_eq(fired[0], -1, "activate on a disabled index fires nothing")
	for b in buttons:
		b.free()

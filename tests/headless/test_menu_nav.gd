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
	CarFixtures.install()


func after_each() -> void:
	# Modals are tree-wide and exclusive, so one left standing would silence the next
	# test's menu (that is the whole point of input_blocked). Clear any before moving on.
	for n in get_tree().get_nodes_in_group(ConfirmPopup.MODAL_GROUP):
		if is_instance_valid(n) and not (n as Node).is_queued_for_deletion():
			(n as Node).queue_free()
	CarFixtures.restore()
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


# Native focus activation and back both run through Godot's ui_accept / ui_cancel
# (a focused BaseButton fires on ui_accept; MenuNav + hosts route back through
# ui_cancel). Those actions ship with keyboard defaults but NO joypad binding, so a
# controller can move the cursor (ui_up/down carry the D-pad + stick) yet not select
# or go back until we add the gamepad face buttons. Guard that both carry a joypad
# button so the whole game stays gamepad-navigable — the exact index is a platform
# convention, not asserted here.
func test_accept_and_cancel_have_a_gamepad_button() -> void:
	for action in ["ui_accept", "ui_cancel"]:
		var found := false
		for e in InputMap.action_get_events(action):
			if e is InputEventJoypadButton:
				found = true
		assert_true(found, "%s has a gamepad button so controllers can drive menus" % action)


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


# --- MenuNav.input_blocked ----------------------------------------------------
# One shared predicate for "should this node ignore menu input right now?", folding
# together the two reasons a host goes deaf: the player is typing, and a modal owns
# the screen. Every host asking the same question is the point — hq.gd asked a
# hand-rolled version that knew about its own overlays but not about ConfirmPopup, so
# station rows kept firing behind an open popup.

func _open_modal(host: Node) -> ConfirmPopup:
	return ConfirmPopup.open(host, "T", "B", [{"label": "OK", "callback": Callable()}])


func test_input_blocked_is_false_with_nothing_in_the_way() -> void:
	var page := _make_flat_menu(2)
	add_child_autofree(page)
	assert_null(ConfirmPopup.any_open(get_tree()), "setup: no modal on screen")
	assert_false(MenuNav.input_blocked(page),
		"an ordinary page is not blocked when nothing is up and nobody is typing")


func test_input_blocked_is_true_for_a_page_behind_a_modal() -> void:
	var page := _make_flat_menu(2)
	add_child_autofree(page)
	var popup := _open_modal(page)
	assert_not_null(popup, "setup: the modal opened")
	assert_true(MenuNav.input_blocked(page),
		"a page behind an open modal ignores menu input")


func test_input_blocked_is_false_inside_the_open_modal() -> void:
	# THE CARVE-OUT. The modal builds a MenuNav of its own on its centring container;
	# if the modal blocked its own subtree the popup would stop answering Back and the
	# player would be trapped in it.
	var host := Control.new()
	add_child_autofree(host)
	var popup := _open_modal(host)
	var inner := popup.find_children("*", "Button", true, false)[0] as Button
	assert_false(MenuNav.input_blocked(inner),
		"a widget inside the open modal keeps its input")
	assert_false(MenuNav.input_blocked(popup),
		"and so does the modal itself")


func test_a_screen_claimer_blocks_everyone_but_its_own_subtree() -> void:
	# A full-screen overlay that is NOT a ConfirmPopup still owns the screen — the car
	# park's Change-Upgrades page, which can't join MODAL_GROUP because it HOSTS confirms
	# (its Auto-Upgrade row opens one) and would refuse its own children. It claims via
	# SCREEN_CLAIMER_GROUP instead. This matters for the pointer as much as for nav:
	# WorldPanel._input asks input_blocked before projecting clicks into its 3D panel, so an
	# unclaimed overlay is one the world underneath goes on eating clicks for.
	var page := _make_flat_menu(2)
	add_child_autofree(page)
	var claimer := Control.new()
	var inner := Button.new()
	claimer.add_child(inner)
	add_child_autofree(claimer)
	claimer.add_to_group(MenuNav.SCREEN_CLAIMER_GROUP)
	assert_true(MenuNav.input_blocked(page), "a page behind the claimed screen goes deaf")
	assert_false(MenuNav.input_blocked(inner), "the claimer's own widgets keep their input")
	assert_false(MenuNav.input_blocked(claimer), "and so does the claimer itself")


func test_a_hidden_screen_claimer_releases_its_claim() -> void:
	# Hosts keep these pages alive and toggle `visible` (hq_carpark.gd
	# _close_upgrades_popup), so the claim has to follow visibility — otherwise closing the
	# page leaves the whole screen permanently deaf.
	var page := _make_flat_menu(2)
	add_child_autofree(page)
	var claimer := Control.new()
	add_child_autofree(claimer)
	claimer.add_to_group(MenuNav.SCREEN_CLAIMER_GROUP)
	assert_true(MenuNav.input_blocked(page), "setup: the claim is live while shown")
	claimer.visible = false
	assert_false(MenuNav.input_blocked(page), "hiding the claimer releases the screen")


func test_a_confirm_over_a_screen_claimer_keeps_its_own_input() -> void:
	# The whole reason for the separate group: a claimer HOSTS confirms. The confirm must
	# open (not be refused) and its buttons must not be blocked by the page underneath.
	var claimer := Control.new()
	add_child_autofree(claimer)
	claimer.add_to_group(MenuNav.SCREEN_CLAIMER_GROUP)
	var popup := _open_modal(claimer)
	assert_not_null(popup, "a confirm still opens over a screen claimer")
	if popup == null:
		return
	var btn := popup.find_children("*", "Button", true, false)[0] as Button
	assert_false(MenuNav.input_blocked(btn), "the confirm's own buttons keep their input")


func test_input_blocked_follows_text_editing() -> void:
	var line := LineEdit.new()
	add_child_autofree(line)
	var page := _make_flat_menu(2)
	add_child_autofree(page)
	assert_false(MenuNav.input_blocked(page), "not blocked while nothing is focused")
	line.grab_focus()
	await get_tree().process_frame
	assert_true(MenuNav.is_text_editing(), "setup: the field has the cursor")
	assert_true(MenuNav.input_blocked(page), "blocked while the player is typing")
	line.release_focus()
	await get_tree().process_frame
	assert_false(MenuNav.input_blocked(page), "and released again once typing stops")


func test_a_page_does_not_move_or_act_while_a_modal_is_up() -> void:
	var menu := _make_flat_menu(3)
	add_child_autofree(menu)
	var hits := [0]
	var nav := MenuNav.attach(menu, {on_back = func() -> void: hits[0] += 1})
	await get_tree().process_frame
	var first := menu.get_child(0)
	assert_eq(menu.get_viewport().gui_get_focus_owner(), first, "setup: cursor seated")

	var popup := _open_modal(menu)
	assert_not_null(popup, "setup: a modal is on screen")
	nav._unhandled_input(_press("menu_down"))
	nav._unhandled_input(_press("menu_back"))
	assert_eq(menu.get_viewport().gui_get_focus_owner(), first,
		"the page's cursor does not move behind the modal")
	assert_eq(hits[0], 0, "and its Back does not fire either")


func test_the_modals_own_nav_still_answers_back() -> void:
	# The other half of the carve-out, end to end: the popup's own MenuNav is NOT
	# blocked by the popup, so Back still dismisses it.
	var host := Control.new()
	add_child_autofree(host)
	var flag := [0]
	var popup := ConfirmPopup.open(host, "T", "B",
		[{"label": "OK", "callback": func() -> void: flag[0] += 1}])
	await get_tree().process_frame
	var nav := _nav_of(popup.get_child(1))
	assert_not_null(nav, "setup: the popup is MenuNav-wired")
	nav._unhandled_input(_press("menu_back"))
	assert_eq(flag[0], 1, "Back inside the modal still fires its action")


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


# The Audio page carries focusable master + music volume sliders that reflect the
# saved settings, so they are reachable and adjustable by keyboard/gamepad (not
# just mouse), and the cursor seats on the first of them when the page opens.
func test_audio_page_slider_is_focusable_and_reflects_saved_volume() -> void:
	var prev_disabled: bool = Save.save_disabled
	Save.save_disabled = true
	Save.set_setting(MusicDirector.SETTING_KEY, 0.5)
	Save.set_setting(MusicDirector.MASTER_SETTING_KEY, 0.75)

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
	assert_not_null(sm.master_slider, "audio page has a master slider")
	assert_eq(sm.master_slider.focus_mode, Control.FOCUS_ALL,
		"the master slider is keyboard/gamepad focusable")
	assert_almost_eq(sm.master_slider.value, 0.75, 0.0001,
		"the master slider reflects the saved master volume")
	assert_eq(sm.get_viewport().gui_get_focus_owner(), sm.master_slider,
		"opening the Audio page focuses the first slider")

	Save.save_disabled = prev_disabled


# The standings interstitial stacks BOTH leaderboards (this stage's result and the
# overall standings) on one page, and its single Continue button is keyboard /
# gamepad focusable and focused on entry. See features/menus.md.
func test_standings_shows_both_leaderboards_and_is_navigable() -> void:
	RallySession.auto_load_scenes = false
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
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

	var headings: Array[String] = []
	for l in s.find_children("*", "Label", true, false):
		headings.append(String(l.text))
	var joined := "\n".join(headings)
	assert_true(joined.contains(UITheme.caps("STAGE 2 RESULT")),
		"this stage's own result is on the page")
	assert_true(joined.contains(UITheme.caps(Standings.overall_heading(2))),
		"the overall standings are on the SAME page, naming both stages so far")
	assert_false(s.is_final_event(), "the 2nd of 3 events is not the final event")
	assert_eq(s._action_button.focus_mode, Control.FOCUS_ALL, "the page button is focusable")
	assert_eq(s.get_viewport().gui_get_focus_owner(), s._action_button, "the button is focused on entry")

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
# cursor stop, same as native focus) — so a disabled action button is stepped over.
func test_button_cursor_wrapped_skips_disabled() -> void:
	var cursor := ButtonCursor.new()
	var buttons: Array = []
	for i in 4:
		buttons.append(Button.new())
	buttons[1].disabled = true  # e.g. a hub action that's unavailable in the current state
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


# --- GlobalStandings (page 2 of the interstitial) ----------------------------
# The global stage leaderboard is a menu like any other, so it carries the whole
# keyboard + gamepad contract: a seated cursor, WASD/arrow/D-pad movement between
# its buttons, and a Back that both the pointer and Esc / gamepad B can reach.
# See features/menus.md → "Menu navigation".

# A stand-in for Cloud.leaderboard.submit_and_fetch: no network, no catalogue, no
# tunables — just the result shape the page reads.
func _fake_board(rank: int = 0, total: int = 12, top_n: int = 3,
		signed_in: bool = false) -> Callable:
	return func(_key: String, _ms: int, _identity: Dictionary) -> Dictionary:
		var rows: Array = []
		for i in top_n:
			rows.append({"placed": i + 1, "name": "RIVAL%d" % i, "car_name": "TEST CAR",
				"combined_ms": 50000 + i * 100, "dnf": false, "is_player": false})
		var mine: Dictionary = {}
		if rank >= 1:
			mine = {"placed": rank, "name": "TESTER", "car_name": "TEST CAR",
				"combined_ms": 60000, "dnf": false, "is_player": true}
		return {"ok": true, "error": "", "rows": rows, "total": total,
			"signed_in": signed_in, "player_rank": rank, "player_row": mine,
			"posted": rank >= 1}


func _global_page(fetch: Callable, opts: Dictionary = {}) -> GlobalStandings:
	var page := GlobalStandings.new()
	page.fetcher = fetch
	var base := {"stage_key": "test__0__abc__e1", "stage_number": 2, "time_ms": 60000,
		"car_name": "TEST CAR", "car_id": "test_car"}
	base.merge(opts, true)
	page.configure(base)
	page.custom_minimum_size = Vector2(640, 480)
	add_child_autofree(page)
	return page


func _nav_of(root: Node) -> MenuNav:
	# Thin wrapper on the framework's own accessor — kept so existing call sites read
	# unchanged. New code should call MenuNav.of(root) directly.
	return MenuNav.of(root as Control)


# With nothing standing between the player and a posted time, the cursor seats on
# Continue so the rally can be advanced with no pointer.
func test_global_standings_seats_the_cursor_on_continue() -> void:
	_save.profile["username"] = "TESTER"
	var page := _global_page(_fake_board(4, 12, 3, true))
	await get_tree().process_frame
	await get_tree().process_frame  # deferred focus grab settles
	assert_null(page._action_button, "a signed-in, named player has no prompt to answer")
	assert_eq(page._continue_button.focus_mode, Control.FOCUS_ALL,
		"the page's Continue is keyboard / gamepad focusable")
	assert_eq(page.get_viewport().gui_get_focus_owner(), page._continue_button,
		"Continue is focused on entry")


# When there IS a prompt, the cursor seats on THAT instead: a player who never
# answers it never posts a time, silently, so it must be the default action for a
# keyboard and a gamepad rather than something to spot and aim at.
func test_global_standings_seats_the_cursor_on_the_prompt_when_there_is_one() -> void:
	_save.profile["username"] = ""
	var page := _global_page(_fake_board(0, 12, 3, true))
	await get_tree().process_frame
	await get_tree().process_frame
	assert_not_null(page._action_button, "a signed-in player with no name is prompted")
	assert_eq(page.get_viewport().gui_get_focus_owner(), page._action_button,
		"and the cursor starts on the prompt, not on Continue")


# Every button on the page is focusable and WASD walks between them — the page is
# not pointer-only.
func test_global_standings_wasd_moves_between_its_buttons() -> void:
	var page := _global_page(_fake_board())
	await get_tree().process_frame
	await get_tree().process_frame
	var buttons := page.find_children("*", "Button", true, false)
	assert_gt(buttons.size(), 1, "the page carries Back alongside Continue")
	for b in buttons:
		assert_eq((b as Button).focus_mode, Control.FOCUS_ALL,
			"%s is keyboard / gamepad focusable" % (b as Button).text)
	var nav := _nav_of(page)
	assert_not_null(nav, "the page is wired to the MenuNav framework")
	nav._unhandled_input(_press("menu_left"))
	assert_ne(page.get_viewport().gui_get_focus_owner(), null,
		"a directional press keeps a live cursor on the page")


# Back (Esc / gamepad B) leaves the page, and so does its on-screen button.
func test_global_standings_back_fires_for_keyboard_and_gamepad() -> void:
	var page := _global_page(_fake_board())
	await get_tree().process_frame
	var hits := [0]
	page.back_pressed.connect(func() -> void: hits[0] += 1)
	var nav := _nav_of(page)
	nav._unhandled_input(_press("ui_cancel"))
	nav._unhandled_input(_press("menu_back"))
	assert_eq(hits[0], 2, "Back fires for both Esc and the gamepad B button")


# With no page 1 behind it (the reward path tore it down), Back is neither drawn
# nor reachable — a Back that lands on a dead end is worse than no Back.
func test_global_standings_without_a_page_one_has_no_back() -> void:
	var page := _global_page(_fake_board(), {"show_back": false})
	await get_tree().process_frame
	var hits := [0]
	page.back_pressed.connect(func() -> void: hits[0] += 1)
	_nav_of(page)._unhandled_input(_press("menu_back"))
	assert_eq(hits[0], 0, "back is swallowed when there is nowhere to go back to")
	for b in page.find_children("*", "Button", true, false):
		assert_false(String((b as Button).text).to_upper().contains("BACK"),
			"no Back button is drawn either")


# Back returns to page 1, restores its cursor, and — crucially — the parent's nav
# does NOT also consume that same press (only one nav is live at a time, because
# showing page 2 hides page 1's root).
func test_global_standings_back_restores_page_one_focus() -> void:
	RallySession.auto_load_scenes = false
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	RallySession._opponent_field = [
		{"name": "Quick", "car_name": "Rival Car", "event_times_ms": [40000, 40000, 40000],
			"dnf": false, "combined_ms": 120000},
	]
	RallySession.report_event_result(50000)

	var s := preload("res://standings.tscn").instantiate()
	add_child_autofree(s)
	await get_tree().process_frame
	var page_one_button: Button = s._action_button

	s._advance()  # the sole exit: first call shows page 2
	await get_tree().process_frame
	assert_not_null(s._global_page, "the first exit shows the global page")
	assert_false(s._root_box.visible,
		"page 1's root VBox is hidden, so its MenuNav goes inert with it")
	# The parent's MenuNav hangs off the VBox that page 2 hides, so it reports
	# itself off-screen and swallows nothing — only page 2's nav is live.
	var parent_nav := _nav_of(s._root_box)
	assert_not_null(parent_nav, "page 1's nav lives on the VBox that page 2 hides")
	assert_false(parent_nav._menu_visible(),
		"the parent nav does not consume input while page 2 is up")

	s._global_page._on_back()
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(s._root_box.visible, "Back re-shows page 1")
	assert_eq(s.get_viewport().gui_get_focus_owner(), page_one_button,
		"and re-seats the cursor on page 1's Continue")

	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true


# --- UsernamePopup -----------------------------------------------------------
# A new modal, so it carries the whole contract: a seated cursor, an explicitly
# wired up/down column (a LineEdit swallows left/right for the caret), and a Back
# that both Esc and gamepad B reach. It must not ship pointer-only.

func test_username_popup_is_keyboard_and_gamepad_navigable() -> void:
	var host := Control.new()
	add_child_autofree(host)
	var popup := UsernamePopup.open(host)
	await get_tree().process_frame  # deferred focus grab settles

	assert_eq(popup._field.line.focus_mode, Control.FOCUS_ALL, "the field is focusable")
	assert_eq(host.get_viewport().gui_get_focus_owner(), popup._field.line,
		"the cursor starts in the field, so typing works with no pointer")
	var buttons := popup.find_children("*", "Button", true, false)
	assert_eq(buttons.size(), 2, "Save and Cancel")
	for b in buttons:
		assert_true((b as Button).is_visible_in_tree(),
			"%s is on screen" % (b as Button).text)
		assert_eq((b as Button).focus_mode, Control.FOCUS_ALL,
			"%s is keyboard / gamepad focusable" % (b as Button).text)
	# TextField.wire_column chains the field to Save explicitly, because the
	# automatic neighbour search can't be trusted once a LineEdit is in the column.
	# Found by LABEL, not by index: the row is ordered Cancel-then-Save now (leaving is
	# leftmost — features/menus.md → "Button order"), and down out of the field must
	# still reach the PRIMARY action rather than whatever happens to sit first.
	var save_btn: Button = null
	for b in buttons:
		if String((b as Button).text).to_upper() == "SAVE":
			save_btn = b
	assert_not_null(save_btn, "the popup offers a Save button")
	assert_eq(popup._field.line.focus_neighbor_bottom, save_btn.get_path(),
		"down out of the field lands on Save, not on Cancel")


# Back closes the popup having written nothing — it is deliberately dismissable
# (the leaderboard page's prompt and the Account row are the two ways back).
func test_username_popup_back_cancels_without_writing() -> void:
	Save.profile["username"] = ""
	var host := Control.new()
	add_child_autofree(host)
	var popup := UsernamePopup.open(host)
	await get_tree().process_frame
	var results: Array = []
	popup.finished.connect(func(name: String) -> void: results.append(name))

	# The nav is attached to the popup's centring container, not the CanvasLayer.
	var center := popup.get_child(1) as CenterContainer
	var nav := _nav_of(center)
	assert_not_null(nav, "the popup is wired to the MenuNav framework")
	# Release the field first: while typing, Back means "stop typing"
	# (MenuNav.is_text_editing), which is the behaviour a half-entered name wants.
	popup._field.line.release_focus()
	nav._unhandled_input(_press("menu_back"))
	assert_eq(results, [""], "gamepad B cancels, reporting no name")
	assert_eq(UsernamePopup.current(), "", "and writes nothing")


# --- MenuNav `remember` --------------------------------------------------------
# The framework can return the cursor to whichever row the player last had selected
# instead of always re-opening on `first`. It lives here, once, rather than in each
# menu: hand-rolled per-widget focus_entered tracking in a menu script is the thing
# this replaces. Behaviour only — nothing here pins which menus opt in.

# Builds a two-row menu attached to MenuNav, returns [root, row_a, row_b].
func _remember_menu(remember: bool) -> Array:
	var root := Control.new()
	add_child_autofree(root)
	var a := Button.new()
	a.text = "A"
	root.add_child(a)
	var b := Button.new()
	b.text = "B"
	root.add_child(b)
	MenuNav.attach(root, {first = a, remember = remember})
	await get_tree().process_frame
	return [root, a, b]


# Off by default: a menu that says nothing keeps re-opening on its `first` row, so
# switching the framework on cannot change any existing menu's behaviour.
func test_remember_is_off_by_default() -> void:
	var parts: Array = await _remember_menu(false)
	var root: Control = parts[0]
	var a: Button = parts[1]
	var b: Button = parts[2]
	b.grab_focus()
	root.visible = false
	root.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(root.get_viewport().gui_get_focus_owner(), a,
		"without remember, re-showing the menu returns to first")


# The whole feature: select a row, close, reopen, and the cursor is back on it.
func test_remember_returns_to_the_row_that_was_selected() -> void:
	var parts: Array = await _remember_menu(true)
	var root: Control = parts[0]
	var b: Button = parts[2]
	b.grab_focus()
	root.visible = false
	root.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(root.get_viewport().gui_get_focus_owner(), b,
		"reopening the menu returns the cursor to the remembered row")


# First open has nothing to remember, so it still lands on `first`.
func test_remember_falls_back_to_first_before_anything_is_selected() -> void:
	var parts: Array = await _remember_menu(true)
	var a: Button = parts[1]
	assert_eq(a.get_viewport().gui_get_focus_owner(), a,
		"the first open lands on first, with nothing remembered yet")


# A remembered row that is hidden (it lives on a sub-panel the host is not showing —
# the pause menu's Settings page is the real case) must not be restored: the cursor
# would land somewhere invisible. Falls back to `first`.
func test_remember_skips_a_row_that_is_no_longer_on_screen() -> void:
	var root := Control.new()
	add_child_autofree(root)
	var a := Button.new()
	root.add_child(a)
	var sub := Control.new()
	root.add_child(sub)
	var hidden_row := Button.new()
	sub.add_child(hidden_row)
	MenuNav.attach(root, {first = a, remember = true})
	await get_tree().process_frame

	hidden_row.grab_focus()
	sub.visible = false
	root.visible = false
	root.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(root.get_viewport().gui_get_focus_owner(), a,
		"a remembered row on a hidden sub-panel falls back to first")


# Focus landing outside the menu (another overlay, a modal) must not be recorded as
# this menu's row — otherwise reopening would try to restore a foreign control.
func test_remember_ignores_focus_outside_the_menu() -> void:
	var parts: Array = await _remember_menu(true)
	var root: Control = parts[0]
	var a: Button = parts[1]
	var b: Button = parts[2]
	b.grab_focus()
	var outsider := Button.new()
	add_child_autofree(outsider)
	outsider.grab_focus()
	await get_tree().process_frame

	root.visible = false
	root.visible = true
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(root.get_viewport().gui_get_focus_owner(), b,
		"focus outside the menu is ignored; the menu's own last row is restored")
	assert_ne(root.get_viewport().gui_get_focus_owner(), a,
		"and it is not reset to first just because focus left the menu")


# --- One owner for opening focus (ratchet) -------------------------------------
# A menu that attaches MenuNav must not ALSO grab focus itself in open(): showing the
# root fires visibility_changed, which the framework already answers, so a host grab
# silently wins the same deferred flush and any change made through MenuNav looks
# like it did nothing. pause_menu.gd did this, and it masked a real bug for rounds
# (its _show_settings(false) grabbed the Settings row even when opening fresh).
#
# Derives its subject list from the filesystem, so a menu written tomorrow is covered
# without touching this test. The allowlist is EMPTY and must only ever shrink — if a
# menu genuinely needs its own grab, fix the menu, don't add it here.
const FOCUS_OWNER_EXEMPT: Array[String] = []


func _gd_scripts_under(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_gd_scripts_under(full, out)
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()


func test_a_menunav_menu_does_not_also_grab_focus_in_open() -> void:
	var scripts: Array = []
	_gd_scripts_under("res://scripts", scripts)
	assert_gt(scripts.size(), 0, "found scripts to scan")
	var offenders: Array[String] = []
	for path in scripts:
		var text := FileAccess.get_file_as_string(path)
		if text == "" or not text.contains("MenuNav.attach"):
			continue
		var in_open := false
		for line in text.split("\n"):
			if line.begins_with("func "):
				in_open = line.begins_with("func open(")
				continue
			if in_open and line.contains("UITheme.focus_grab"):
				offenders.append("%s (%s)" % [path, line.strip_edges()])
				break
	for path in FOCUS_OWNER_EXEMPT:
		assert_true(offenders.has(path),
			"%s is on FOCUS_OWNER_EXEMPT but no longer offends — remove it from the list" % path)
		offenders.erase(path)
	assert_eq(offenders, ([] as Array[String]),
		"a menu using MenuNav must let the framework own opening focus — delete the "
		+ "UITheme.focus_grab from open() and pass what you want through "
		+ "MenuNav.attach(root, {first = ..., remember = ...}); see features/menus.md "
		+ "-> \"Menu navigation\" -> \"One owner for opening focus\"")

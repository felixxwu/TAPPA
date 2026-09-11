extends GutTest
# The flat shell (scripts/hub_shell.gd) — the game's main scene and the only way into a
# run, replacing the deleted diegetic 3D hub.
#
# Three things are pinned here and nothing else:
#   1. NAVIGATION. CLAUDE.md requires every menu in the game to be keyboard + gamepad
#      navigable, and says a new menu ships with a nav test in the same piece of work.
#      That is the rule this file exists for.
#   2. The SCREEN GRAPH — which page leads where, and what each one does with the run
#      state. Deliberately NOT the page's looks, wording or button order: stage 3's shell
#      is explicitly a placeholder that stages 4-8 rewrite, and a test that pinned its
#      layout would break on every one of those stages while proving nothing.
#   3. The INTERACTIVE LOAD contract (features/card-carousel.md's warming section): the
#      hub's loading screen stays up until every car preview is cached.

var _save: Node
var _shell: HubShell


func before_each() -> void:
	CarFixtures.install()
	_save = Save
	_save.profile = _save._default_profile()
	_shell = HubShell.new()
	add_child_autofree(_shell)


func after_each() -> void:
	FreePlay.clear()
	if RunSession.is_active():
		RunSession.pause_run()
	_save.clear_run()
	RunSession.clear_last_result()
	CarFixtures.restore()


func _page() -> MenuPage:
	return _shell._page


# Every focusable Button on the live page, in tree order.
func _buttons() -> Array:
	var out: Array = []
	for node in _page().find_children("*", "Button", true, false):
		if (node as Button).focus_mode != Control.FOCUS_NONE:
			out.append(node)
	return out


# MAIN/REGION/CAR/SHOP/SKILLS present their rows as one CardCarousel (features/
# card-carousel.md) rather than a Button per row now — CHALLENGE/STATS/SETTINGS
# still don't. Null when the current page has no carousel.
func _carousel() -> CardCarousel:
	var found := _page().find_children("*", "CardCarousel", true, false)
	return (found[0] as CardCarousel) if not found.is_empty() else null


func _card_text(c: CardCarousel, i: int) -> String:
	var t := ""
	for child in c._cards[i].info.get_children():
		if child is Label:
			t += String((child as Label).text) + " "
	return t.to_upper()


# Uppercased text of every Label AND Button under the page — what's SHOWN, focusable
# or not (a locked/disabled row is still shown, just not confirmable — see
# _confirmable_texts).
func _all_texts() -> String:
	var texts: Array[String] = []
	for label in _page().find_children("*", "Label", true, false):
		texts.append(String((label as Label).text).to_upper())
	for b in _page().find_children("*", "Button", true, false):
		texts.append(String((b as Button).text).to_upper())
	return " | ".join(texts)


# Uppercased text of every row the keyboard/gamepad cursor can actually confirm right
# now: enabled Buttons, plus non-disabled carousel cards (a disabled card is shown but
# CardCarousel.confirmed never fires for it — see card_carousel.gd _confirm_selected).
func _confirmable_texts() -> String:
	var texts: Array[String] = []
	for b in _buttons():
		texts.append(String((b as Button).text).to_upper())
	var c := _carousel()
	if c != null:
		for i in c.card_count():
			if not c._cards[i].disabled:
				texts.append(_card_text(c, i))
	return " | ".join(texts)


func _press(text: String) -> bool:
	for b in _buttons():
		if String((b as Button).text).to_upper().contains(text.to_upper()):
			(b as Button).pressed.emit()
			return true
	var c := _carousel()
	if c != null:
		for i in c.card_count():
			if not c._cards[i].disabled and _card_text(c, i).contains(text.to_upper()):
				c.confirmed.emit(i)
				return true
	return false


# --- Touch simulation ----------------------------------------------------------
#
# `_press`/`c.confirmed.emit(i)` above exercise the SCREEN GRAPH but not the actual touch
# code path a phone player drives it with — these instead dispatch real
# InputEventScreenTouch/Drag through CardCarousel's own entry points
# (_on_card_gui_input / _gui_input / _input), the same ones card_carousel.gd's own drag/tap
# regression tests use, so a real touch-handling bug (see test_touch_navigation_below)
# shows up here rather than only in a unit test of the carousel in isolation.

# A real single-finger TAP (press then release at the same point, no movement) on
# whichever card is CURRENTLY CENTRED — CardCarousel treats a tap on the centred card as a
# CONFIRM (card_carousel.gd _tap_card), same as a player tapping the highlighted item.
func _touch_tap_selected_card(carousel: CardCarousel) -> void:
	var index := carousel.selected_index()
	var pos := Vector2(carousel.get_card(index).root.size.x * 0.5, 10.0)
	var press := InputEventScreenTouch.new()
	press.pressed = true
	press.position = pos
	carousel._on_card_gui_input(press, index)
	var release := InputEventScreenTouch.new()
	release.pressed = false
	release.position = pos
	carousel._on_card_gui_input(release, index)
	# A real confirm now plays a flash before `confirmed` fires (card_carousel.gd
	# _confirm_selected) — this helper is testing the MENU WALK the tap leads to, not the
	# flash itself (that's card_carousel.gd's own confirm-flash tests), so skip straight to
	# the end of it.
	carousel.skip_confirm_flash()


# A real drag gesture starting on the carousel's own BACKGROUND (not any specific card —
# see card_carousel.gd's "_drag_active must arm from the background too" fix) that moves
# far enough to cross the snap threshold, then releases. `steps` cards' worth of
# horizontal travel, negative to drag toward higher indices.
func _touch_swipe(carousel: CardCarousel, steps: float) -> void:
	var start := carousel.size * 0.5
	var press := InputEventScreenTouch.new()
	press.pressed = true
	press.position = start
	carousel._gui_input(press)

	var unit: float = Config.data.card_carousel_card_width + Config.data.card_carousel_gap
	var drag_pos := start + Vector2(unit * steps, 0.0)
	var drag := InputEventScreenDrag.new()
	drag.position = drag_pos
	carousel._gui_input(drag)

	var release := InputEventScreenTouch.new()
	release.pressed = false
	release.position = drag_pos
	carousel._input(release)


# Regression coverage for the touch bugs found and fixed on this carousel (jump-on-touch
# coordinate mismatch, background drags doing nothing, a card's own confirm never firing)
# — exercised here as an end-to-end MENU WALK rather than isolated CardCarousel unit
# tests, so a wiring mistake in HOW HubShell hooks up `confirmed`/`selection_changed`
# would show up too, not just a bug in the carousel itself.
func test_touch_navigation_walks_main_to_region_to_car_and_back() -> void:
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	var main_carousel := _carousel()
	assert_not_null(main_carousel)
	assert_eq(_card_text(main_carousel, main_carousel.selected_index()), "NEW RUN ",
		"setup: a fresh profile's first MAIN card is New Run")
	_touch_tap_selected_card(main_carousel)
	await get_tree().process_frame
	assert_eq(_shell._view, HubShell.View.REGION,
		"a touch tap on MAIN's centred card must enter region select")

	var region_carousel := _carousel()
	assert_not_null(region_carousel)
	_touch_tap_selected_card(region_carousel)
	await get_tree().process_frame
	assert_eq(_shell._view, HubShell.View.CAR,
		"a touch tap on the first (always-unlocked) region must enter car select")

	var car_carousel := _carousel()
	assert_not_null(car_carousel)
	if car_carousel.card_count() > 1:
		var before := car_carousel.selected_index()
		_touch_swipe(car_carousel, -1.0)
		await get_tree().process_frame
		assert_ne(car_carousel.selected_index(), before,
			"a touch swipe on the CAR page must move the selection")

	assert_true(_press("Back"), "setup: the CAR page offers a Back action")
	await get_tree().process_frame
	assert_eq(_shell._view, HubShell.View.REGION, "back from CAR must return to region select")


func _popup_button(popup: ConfirmPopup, label: String) -> Button:
	for node in popup.find_children("*", "Button", true, false):
		if String((node as Button).text).to_lower() == label.to_lower():
			return node
	return null


# --- Update check placement (re-homed from the deleted diegetic hub) -------------

# Under headless UpdateCheck.applicable() is false BY DESIGN (no stamped build number),
# so the boot-time check must be a silent no-op here — no popup, no request. This pins
# the gate: a future edit that fires the prompt in the editor/test runner fails loudly.
func test_the_boot_time_update_check_is_a_silent_no_op_under_headless() -> void:
	_shell._check_for_update()
	await get_tree().process_frame
	assert_null(ConfirmPopup.any_open(get_tree()),
		"headless/editor builds raise no update prompt")


# The prompt itself, driven through the split-out _show_update_prompt so the platform
# gate does not have to be fought. Both buttons record the dismissal (the player has
# now SEEN this build), and the store button's callback shells out — not pressed here.
func test_the_update_prompt_records_its_dismissal_when_answered() -> void:
	_shell._show_update_prompt(61, 74)
	var popup := ConfirmPopup.any_open(get_tree()) as ConfirmPopup
	assert_not_null(popup, "the prompt is up over the hub")
	assert_not_null(_popup_button(popup, "Not now"),
		"leaving is the left/Back action (Esc / gamepad-B routes to it)")
	assert_not_null(_popup_button(popup, UpdateCheck.store_label()),
		"and the store action is the focused one (default index 1)")
	assert_eq(int(_save.get_setting(UpdateCheck.DISMISSED_SETTING, 0)), 0,
		"setup: nothing recorded yet — an unshown prompt must not count as dismissed")
	var not_now := _popup_button(popup, "Not now")
	assert_not_null(not_now, "the dismissing action exists")
	not_now.pressed.emit()
	await get_tree().process_frame
	assert_eq(int(_save.get_setting(UpdateCheck.DISMISSED_SETTING, 0)), 74,
		"answering records the build the player was told about")
	assert_false(is_instance_valid(popup), "and the prompt dismisses")


# --- Free play (the session-less sandbox) ---------------------------------------

# The whole three-page flow in one test: MAIN's card enters it, EVERY catalogue car is
# offered (owned or not), every region (locked or not), boosts toggle in any
# combination, and Start writes the FreePlay plan the world consumes. Pressing by
# card text keeps this on the SCREEN GRAPH, not the layout.
func test_freeplay_flow_picks_car_region_and_boosts_into_a_plan() -> void:
	_shell._show(HubShell.View.MAIN)
	var unowned := ""
	for spec in CarLibrary.all():
		var mid := String(spec.get("id", ""))
		if not mid.is_empty() and not _save.owns_model(mid):
			unowned = String(spec.get("name", mid))
			break
	assert_ne(unowned, "", "setup: the fixture roster has an unowned car to lend")
	var first_region: Dictionary = RegionLibrary.ordered()[0]
	var region_name := String(first_region.get("name", ""))

	assert_true(_press("Free play"), "MAIN offers the free play card")
	assert_eq(_shell._view, HubShell.View.FREEPLAY_CAR)
	assert_true(_all_texts().contains(unowned.to_upper()),
		"an unowned car is offered — free play lends it")

	assert_true(_press(unowned), "picking the car advances to the region page")
	assert_eq(_shell._view, HubShell.View.FREEPLAY_REGION)

	assert_true(_press(region_name), "picking a region advances to the upgrade page")
	assert_eq(_shell._view, HubShell.View.FREEPLAY_SETUP)

	var boost_label := BoostLibrary.label_for(String(BoostLibrary.CATALOGUE.keys()[0]))
	assert_false(_all_texts().contains("SELECTED"),
		"setup: nothing is selected yet")
	assert_true(_press(boost_label), "toggling the boost selects it")
	assert_true(_all_texts().contains("SELECTED"),
		"the page rebuilds with the selection legible")

	assert_true(_press("Start free play"), "Start launches the sandbox drive")
	assert_true(FreePlay.has_plan(), "the plan is written for the world to consume")
	assert_true(FreePlay.boost_effects().size() >= 1,
		"the toggled boost rides the plan's effects list")
	assert_false(FreePlay.event().is_empty(),
		"the plan carries a real TrackGenParams-shaped stage from the region pool")


func test_backing_out_of_free_play_leaves_no_plan_behind() -> void:
	_shell._show(HubShell.View.MAIN)
	assert_true(_press("Free play"))
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN, "back from the car page returns to MAIN")
	assert_false(FreePlay.has_plan(), "no half-picked plan survives backing out")


# --- Navigation (the CLAUDE.md contract) --------------------------------------

# The rule, on every page the shell can show: a menu reachable only by pointer is not
# shippable. Walks the graph rather than testing one page, because the shell rebuilds its
# page on every transition and a nav wiring that is only correct on the first build is the
# failure this guards.
func test_every_page_is_keyboard_navigable() -> void:
	for view in [HubShell.View.TITLE, HubShell.View.MAIN, HubShell.View.REGION,
			HubShell.View.CAR, HubShell.View.SUMMARY, HubShell.View.SHOP,
			HubShell.View.SKILLS, HubShell.View.STATS, HubShell.View.CHALLENGE,
			HubShell.View.SETTINGS, HubShell.View.FREEPLAY_CAR,
			HubShell.View.FREEPLAY_REGION, HubShell.View.FREEPLAY_SETUP]:
		_shell._show(view)
		await get_tree().process_frame
		assert_not_null(MenuNav.of(_page()),
			"view %d has a MenuNav attached" % view)
		# A carousel counts as ONE focusable unit (it owns its own left/right — see
		# menu_nav.gd menu_nav_handles_side), same as the Button rows the other pages
		# still use.
		var focusable_count := _buttons().size()
		if _carousel() != null:
			focusable_count += 1
		assert_gt(focusable_count, 0,
			"view %d offers at least one focusable control" % view)


# The carousel pages want the live 3D menu showcase (todo/menu-background-showcase.md)
# visible through the gaps between cards, so their MenuPage body box must be fully
# transparent — opaque would paint the showcase over with solid black everywhere except
# the cards themselves (which carry their own opaque stylebox regardless — card_carousel.gd).
# Every OTHER page keeps the normal opaque box (menu_page.gd rule 1: a page reads as a
# panel resting over the world, not a wall of pure black either way, but a carousel page
# specifically must let the world show in its own empty space, not just around its edges).
func test_carousel_pages_have_a_transparent_body_and_others_stay_opaque() -> void:
	for view in [HubShell.View.TITLE, HubShell.View.MAIN, HubShell.View.REGION,
			HubShell.View.CAR, HubShell.View.SHOP, HubShell.View.SKILLS,
			HubShell.View.FREEPLAY_CAR, HubShell.View.FREEPLAY_REGION,
			HubShell.View.FREEPLAY_SETUP]:
		_shell._show(view)
		await get_tree().process_frame
		var box := (_page().panel().get_theme_stylebox("panel") as UIHardShadowBox).inner as StyleBoxFlat
		assert_almost_eq(box.bg_color.a, 0.0, 0.01, "view %d's body must be transparent" % view)

	for view in [HubShell.View.STATS, HubShell.View.CHALLENGE,
			HubShell.View.SETTINGS]:
		_shell._show(view)
		await get_tree().process_frame
		var box := (_page().panel().get_theme_stylebox("panel") as UIHardShadowBox).inner as StyleBoxFlat
		assert_almost_eq(box.bg_color.a, 1.0, 0.01, "view %d's body must stay opaque" % view)


# The corner build-version label (features/update-check.md, hub_shell.gd
# `_build_version_label`). The test runner's project.godot ships the unstamped
# "0.0-dev" — the same value the editor sees — so under a normal test run the
# label must not appear at all rather than render "0.0-dev" or an empty box.
func test_main_page_hides_the_version_label_when_the_build_is_unstamped() -> void:
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	assert_eq(UpdateCheck.current_build(), -1,
		"precondition: the test runner's version is unstamped")
	for label in _page().find_children("*", "Label", true, false):
		assert_ne((label as Label).text, "0.0-DEV",
			"an unstamped build must not render its raw version string")


# Overrides application/config/version to a stamped value for the duration of the
# test to exercise the "build IS stamped" branch without depending on the runner's
# own (unstamped) version.
func test_main_page_shows_a_stamped_version_as_passive_non_nav_chrome() -> void:
	var prev: String = ProjectSettings.get_setting("application/config/version", "")
	ProjectSettings.set_setting("application/config/version", "0.61 (b154d5c)")
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	var found: Array = []
	for label in _page().find_children("*", "Label", true, false):
		if (label as Label).text == "0.61 (B154D5C)":
			found.append(label)
	ProjectSettings.set_setting("application/config/version", prev)
	assert_eq(found.size(), 1, "a stamped version renders exactly one corner label")
	if found.size() == 1:
		var l := found[0] as Label
		assert_eq(l.focus_mode, Control.FOCUS_NONE,
			"the version label must never be focusable")
		assert_false(_buttons().has(l),
			"the version label must not be counted among the page's focusable controls")


func test_back_walks_the_page_stack_and_stops_at_the_root() -> void:
	_shell._show(HubShell.View.CAR)
	_shell._back()
	assert_eq(_shell._view, HubShell.View.REGION, "car backs out to region select")
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN, "region backs out to the main page")
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN,
		"and the root absorbs Back rather than dropping the player somewhere they never went")


func test_the_main_page_reaches_settings() -> void:
	_shell._show(HubShell.View.MAIN)
	assert_true(_press("Settings"), "the main page offers a Settings row")
	assert_eq(_shell._view, HubShell.View.SETTINGS, "pressing it opens the settings page")


# Regression: SettingsMenu was originally mounted inside a SECOND TouchScrollContainer,
# nested inside MenuPage.body()'s OWN scroll. A ScrollContainer deliberately reports a
# near-zero minimum size (menu_page.gd::_sync_body_height's own comment), so the outer
# page measured that near-zero inner scroll as "the content" and collapsed its body to an
# almost-empty box — every SettingsMenu row was still IN THE TREE (so test_settings_page_
# hosts_the_shared_settings_menu above kept passing) but rendered with no visible height.
# This asserts the actual measured height, not just node presence, so a reintroduced nested
# scroll fails loudly instead of silently shipping an empty-looking page again.
func test_settings_page_is_not_collapsed_by_a_nested_scroll_container() -> void:
	_shell._show(HubShell.View.SETTINGS)
	await get_tree().process_frame
	await get_tree().process_frame
	var measured_height: float = _page()._scroll.custom_minimum_size.y
	assert_gt(measured_height, 200.0,
		"the settings page's measured body height (%.1f) is near-zero — SettingsMenu is probably wrapped in a second scroll container that is defeating MenuPage's own height sync" % measured_height)


func test_settings_page_hosts_the_shared_settings_menu() -> void:
	_shell._show(HubShell.View.SETTINGS)
	await get_tree().process_frame
	var found := _page().find_children("*", "SettingsMenu", true, false)
	assert_eq(found.size(), 1, "the settings page mounts exactly one SettingsMenu")


func test_settings_backs_out_to_the_main_page() -> void:
	_shell._show(HubShell.View.SETTINGS)
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN,
		"settings backs out to the main page once its own category list has nothing left to back out of")


func test_settings_gives_its_own_sub_pages_first_refusal_backing_out() -> void:
	_shell._show(HubShell.View.SETTINGS)
	await get_tree().process_frame
	_shell._settings_menu.show_audio()
	_shell._back()
	assert_eq(_shell._view, HubShell.View.SETTINGS,
		"backing out of a settings sub-page returns to the settings category list, not the main page")
	assert_true(_shell._settings_menu.at_root(), "the settings menu itself is back on its category list")
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN,
		"a second back, now at the settings root, leaves the settings page entirely")


func test_shop_backs_out_to_the_main_page() -> void:
	_shell._show(HubShell.View.SHOP)
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN, "the shop backs out to the main page")


# One page at a time. The shell frees the old page's CanvasLayer on every transition; a
# leaked one keeps claiming input and swallows the new page's navigation.
func test_showing_a_page_frees_the_previous_one() -> void:
	_shell._show(HubShell.View.REGION)
	var first := _page()
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_false(is_instance_valid(first) and first.is_inside_tree(),
		"the previous page is gone, not parked under the tree still claiming input")


# --- The screen graph ---------------------------------------------------------

func test_the_shell_opens_on_the_title_page_with_no_result_parked() -> void:
	assert_eq(_shell._view, HubShell.View.TITLE,
		"a fresh boot lands on the title splash")


func test_starting_from_the_title_page_reaches_the_main_page() -> void:
	assert_true(_press("Start"), "the title page offers a way in")
	assert_eq(_shell._view, HubShell.View.MAIN,
		"Start moves from the title splash into the main page")


# The run's outcome has to survive the scene change back here, or the player is dropped at
# a title screen with no idea whether they cleared the region.
func test_a_finished_run_opens_the_summary_instead_of_the_main_page() -> void:
	RunSession._last_result = {"completed": false, "stages_completed": 3,
		"stage_count": 8, "money_earned": 400, "stage_times_ms": [1000, 2000, 3000]}
	var shell := HubShell.new()
	add_child_autofree(shell)
	await get_tree().process_frame
	assert_eq(shell._view, HubShell.View.SUMMARY,
		"the summary is shown for a run that just ended")


# The summary is one-shot: _ready() shows it whenever a result is parked, so a summary
# that did not clear the result would trap the player on it forever.
func test_continuing_from_the_summary_clears_the_result() -> void:
	RunSession._last_result = {"completed": true, "stages_completed": 8,
		"stage_count": 8, "money_earned": 900, "stage_times_ms": []}
	_shell._show(HubShell.View.SUMMARY)
	assert_true(_press("Continue"), "setup: the summary offers a way out")
	assert_true(RunSession.last_result().is_empty(),
		"the result is cleared, so returning to the hub does not re-open the summary")
	assert_eq(_shell._view, HubShell.View.MAIN, "and the player lands back on the main page")


# A run's end is the biggest moment in the loop, and used to read identically to a stat
# sheet either way. The summary now fires a ConfirmPopup announcement distinguishing the
# two outcomes before the plain stats underneath.
func test_clearing_the_region_announces_a_distinct_outcome() -> void:
	RunSession._last_result = {"completed": true, "stages_completed": 8,
		"stage_count": 8, "money_earned": 900, "stage_times_ms": []}
	_shell._show(HubShell.View.SUMMARY)
	var popup := ConfirmPopup.any_open(get_tree())
	assert_not_null(popup, "clearing the region announces its outcome")
	assert_eq(String(popup.get_meta("modal_title", "")), "REGION CLEARED!")


func test_missing_the_clock_announces_a_distinct_outcome() -> void:
	RunSession._last_result = {"completed": false, "failed": true, "stages_completed": 3,
		"stage_count": 8, "money_earned": 400, "stage_times_ms": [1000, 2000, 3000]}
	_shell._show(HubShell.View.SUMMARY)
	var popup := ConfirmPopup.any_open(get_tree())
	assert_not_null(popup, "a run stopped by the clock announces its outcome")
	assert_eq(String(popup.get_meta("modal_title", "")), "RUN OVER")


# --- Decision 48: the paused-run confirm --------------------------------------

# The shell owes the other half of decision 48. Discarding a paused run BURNS its attempt,
# so starting a new run over the top of one must ask first — the rule is defensible, but
# discovering it after the fact is not.
func test_starting_a_run_over_a_paused_one_asks_first() -> void:
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	assert_true(RunSession.start_region("home", car), "setup: a run is going")
	RunSession.pause_run()

	_shell._pending_region = "home"
	_shell._start_run(car)
	await get_tree().process_frame

	assert_not_null(ConfirmPopup.any_open(get_tree()),
		"a confirm is raised rather than silently throwing the paused run away")
	# Leave nothing parked for the next test.
	var modal := ConfirmPopup.any_open(get_tree())
	if modal != null:
		(modal as ConfirmPopup).trigger_back()
		await get_tree().process_frame


func test_starting_a_run_with_nothing_paused_does_not_ask() -> void:
	var car: Dictionary = _save.grant_car(String(CarFixtures.cars()[0]["id"]))
	_shell._pending_region = "home"
	_shell._start_run(car)
	await get_tree().process_frame
	assert_null(ConfirmPopup.any_open(get_tree()),
		"nothing to lose, so nothing to confirm")
	assert_true(RunSession.is_active(), "and the run starts")


# --- Linear region unlock (stage 4) -------------------------------------------

# A locked region is on the page, named (its card says just "Locked" + the pay rate —
# NOT the gate it hides behind), but is not focusable, so the keyboard cannot land on a
# card it can never press. Asserts the RULE against a
# synthetic order rather than the shipped table: which region is second is authored data a
# designer may reorder freely.
func test_a_locked_region_is_shown_but_not_focusable() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_first", "order": 0, "name": "First"},
		{"id": "fx_second", "order": 1, "name": "Second"},
	] as Array[Dictionary])
	_shell._show(HubShell.View.REGION)
	await get_tree().process_frame

	# UITheme.enforce uppercases label/button text, so compare case-insensitively
	# rather than pinning the presentation.
	var joined := _all_texts()
	assert_true(joined.contains("SECOND"), "the locked region is still listed")
	assert_true(joined.contains("FIRST"), "and the gate region is listed alongside it")

	assert_false(_confirmable_texts().contains("LOCKED"),
		"a locked card is not confirmable — the keyboard cannot land on it")
	RegionLibrary.reset()


func test_clearing_a_region_unlocks_the_next() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_first", "order": 0, "name": "First"},
		{"id": "fx_second", "order": 1, "name": "Second"},
	] as Array[Dictionary])
	assert_false(RegionLibrary.is_unlocked("fx_second", _save.profile),
		"setup: the second region starts locked")
	assert_true(RegionLibrary.is_unlocked("fx_first", _save.profile),
		"the first region is always open — a new profile must be able to start somewhere")

	_save.profile[_save.KEY_REGIONS_CLEARED] = ["fx_first"]
	assert_true(RegionLibrary.is_unlocked("fx_second", _save.profile),
		"clearing the first opens the second")
	RegionLibrary.reset()


# The ledger is what unlock reads, so only a run that cleared EVERY stage may write it.
func test_only_a_completed_run_records_the_region_as_cleared() -> void:
	var mode := RegionRunMode.for_region("home")
	mode.record_outcome({"completed": false, "stages_completed": 5}, 0)
	assert_false((_save.profile[_save.KEY_REGIONS_CLEARED] as Array).has("home"),
		"a run stopped by the clock has not cleared the region, however far it got")

	mode.record_outcome({"completed": true}, 0)
	assert_true((_save.profile[_save.KEY_REGIONS_CLEARED] as Array).has("home"),
		"clearing every stage records it")

	mode.record_outcome({"completed": true}, 0)
	assert_eq((_save.profile[_save.KEY_REGIONS_CLEARED] as Array).count("home"), 1,
		"a region stays replayable, so a second clear must not duplicate the entry")


# The invariant RegionLibrary's own header states: array position carries no meaning, so
# progression must read the authored `order` field. Reversing the table must not re-rank
# the game.
func test_progression_reads_the_authored_order_not_array_position() -> void:
	RegionLibrary.override_for_test([
		{"id": "fx_late", "order": 1, "name": "Late"},
		{"id": "fx_early", "order": 0, "name": "Early"},
	] as Array[Dictionary])
	assert_eq(RegionLibrary.order_of("fx_early"), 0,
		"the first region is the one authored order 0, not the one listed first")
	assert_true(RegionLibrary.is_unlocked("fx_early", _save.profile))
	assert_false(RegionLibrary.is_unlocked("fx_late", _save.profile))
	assert_eq(String(RegionLibrary.ordered()[0].get("id", "")), "fx_early",
		"ordered() sorts by the field, not by table position")
	assert_eq(RegionRunMode.for_region("fx_late").region_index(), 1,
		"and the run's difficulty/payout rank comes from the same field")
	RegionLibrary.reset()


# --- The meta shop (stage 6) ---------------------------------------------------

# The shop is a permanent money sink and money only comes from running stages, which needs
# a car — so spending there before owning one can leave a player unable to afford any car
# at all. The MAIN page's Shop row is disabled until the profile owns a car.
func test_the_shop_is_not_confirmable_while_the_profile_owns_no_car() -> void:
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	assert_true(_all_texts().contains("SHOP"),
		"the shop row is still SHOWN with no car, so the player can see why it is gated")
	assert_false(_confirmable_texts().contains("SHOP"),
		"with no car owned, the shop row is not confirmable")


func test_owning_a_car_re_enables_the_shop() -> void:
	_save.grant_car(String((CarLibrary.all()[0] as Dictionary).get("id", "")))
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	assert_true(_confirmable_texts().contains("SHOP"),
		"once a car is owned the shop row is confirmable again")


# Decision 28: the CAR page is no longer a dead end for a car-less profile — a fresh
# profile is seeded with money (GameConfig.run_starting_money) and the page lists
# unowned cars with a Buy action.
# "Show stats" is a PAGE ACTION (features/card-carousel.md / hub_shell.gd's own header
# on _action("Show stats", ...)) rather than a per-card icon, precisely so it stays
# reachable on keyboard/gamepad without a pointer — CLAUDE.md's menu-navigation rule.
func test_car_page_offers_a_focusable_show_stats_action() -> void:
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	var found := false
	for b in _buttons():
		if String((b as Button).text).to_upper().contains("SHOW STATS"):
			found = true
	assert_true(found, "the CAR page exposes Show stats as a focusable Button")


func test_show_stats_opens_a_spec_sheet_modal_over_the_highlighted_card() -> void:
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	assert_true(_press("Show stats"), "setup: the action is reachable via the screen graph")
	await get_tree().process_frame
	# The modal is its own MenuPage.open_modal layer under the shell, not nested inside
	# _page() — see menu_page.gd's header on why it needs its own CanvasLayer.
	var grid := _shell.find_children("*", "GridContainer", true, false)
	assert_false(grid.is_empty(), "the spec sheet's 2-column grid is mounted over the car page")
	var back_buttons: Array = []
	for b in _shell.find_children("*", "Button", true, false):
		if String((b as Button).text).to_upper().contains("BACK"):
			back_buttons.append(b)
	assert_false(back_buttons.is_empty(), "the modal offers its own Back action back to the card")
	(back_buttons[0] as Button).pressed.emit()


func test_a_car_less_profile_can_buy_from_the_car_page() -> void:
	assert_true((_save.profile.get(_save.KEY_CARS, []) as Array).is_empty(),
		"setup: nothing owned yet")
	assert_gt(_save.money(), 0, "setup: decision 28 seeds a starting purse")
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	assert_true(_all_texts().contains("BUY"), "the car page offers a Buy action, not a dead end")


# A live CarCardPreview is a real SubViewport + a full car.tscn instantiation — three
# designs were tried before this one (every car up front; a window rebuilt per move; a
# single reused instance) and each traded one problem for another — see
# features/card-carousel.md → "A small pool of live previews..." for the history. The
# shape that holds: every card the carousel can ACTUALLY show at once
# (CardCarousel.visible_card_count(), centred on the selection) gets its own live preview,
# and a card that stays in the window across a selection move keeps its SAME preview node
# untouched rather than being rebuilt.
func test_car_page_shows_a_live_preview_on_every_visible_card() -> void:
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	var carousel := _carousel()
	assert_not_null(carousel)
	assert_gte(carousel.card_count(), 4,
		"setup: CarFixtures ships at least four unowned cars to buy")

	# Force a KNOWN, non-trivial visible window (3 cards) regardless of the real viewport.
	var unit: float = Config.data.card_carousel_card_width + Config.data.card_carousel_gap
	carousel.fit_to_available_width(unit * 3.0)
	carousel.select(1, false)
	await get_tree().process_frame
	assert_eq(carousel.visible_card_count(), 3, "setup: window forced to 3 cards")

	var live_nodes := func() -> Dictionary:
		var found := {}
		for i in carousel.card_count():
			var card := carousel.get_card(i)
			if card.visual.get_child_count() > 0 and card.visual.get_child(0) is CarCardPreview:
				found[i] = card.visual.get_child(0)
		return found

	var before: Dictionary = live_nodes.call()
	assert_eq(before.keys(), [0, 1, 2],
		"every card in the (selection-centred) visible window must have a live preview")

	carousel.select(2, false)
	await get_tree().process_frame

	var after: Dictionary = live_nodes.call()
	assert_eq(after.keys(), [1, 2, 3], "the live window must follow the selection")
	assert_eq(after[1], before[1], "a card that stayed in the window keeps its SAME preview node")
	assert_eq(after[2], before[2], "same for the other card that stayed in the window")


# Regression: the pool-by-screen-slot design (a prior fix) reassigned instances to
# whichever card entered the window, re-spawning the CarProp inside even for a car the
# player had already scrolled past moments earlier — reported as considerable lag every
# time the selection moved. A car's preview must be CACHED by car ref and simply
# reparented back when that car re-enters view, not rebuilt.
func test_a_previously_seen_car_reuses_its_cached_preview_without_respawning() -> void:
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	var carousel := _carousel()
	assert_not_null(carousel)
	assert_gte(carousel.card_count(), 4,
		"setup: CarFixtures ships at least four unowned cars to buy")

	var unit: float = Config.data.card_carousel_card_width + Config.data.card_carousel_gap
	carousel.fit_to_available_width(unit * 3.0)
	carousel.select(1, false)
	await get_tree().process_frame

	var card0 := carousel.get_card(0)
	var is_live := func() -> bool:
		return card0.visual.get_child_count() > 0 and card0.visual.get_child(0) is CarCardPreview
	assert_true(is_live.call(), "setup: card 0 starts inside the visible window")
	var original_preview: CarCardPreview = card0.visual.get_child(0)

	carousel.select(2, false)  # window becomes [1, 2, 3] — card 0 scrolls out of view
	await get_tree().process_frame
	assert_false(is_live.call(), "setup: card 0 lost its live preview once it left the window")

	carousel.select(0, false)  # window includes 0 again
	await get_tree().process_frame
	assert_true(is_live.call(), "card 0 must show a live preview again once it re-enters the window")
	assert_eq(card0.visual.get_child(0), original_preview,
		"a car seen earlier this visit must reuse its CACHED preview, not spawn a new one")


# Free play's car page must show the same live CarCardPreview 3D viewports as the main
# CAR page, not the flat "car" icon it used before — the two pages share the same
# car_refs -> _sync_car_previews wiring.
func test_freeplay_car_page_shows_a_live_preview_on_the_selected_card() -> void:
	_shell._show(HubShell.View.FREEPLAY_CAR)
	await get_tree().process_frame
	var carousel := _carousel()
	assert_not_null(carousel)
	assert_gt(carousel.card_count(), 0, "setup: the catalogue has at least one car")

	var card := carousel.get_card(carousel.selected_index())
	assert_true(card.visual.get_child_count() > 0 and card.visual.get_child(0) is CarCardPreview,
		"the selected free-play car card must show a live CarCardPreview")


func test_buying_a_car_from_the_shop_moves_it_into_the_owned_list() -> void:
	var cheapest := ""
	var cheapest_cost := -1
	for spec in CarLibrary.all():
		var cost := int(spec.get("cost", 0))
		if cheapest_cost < 0 or cost < cheapest_cost:
			cheapest = String(spec.get("id", ""))
			cheapest_cost = cost
	_save.profile[_save.KEY_MONEY] = cheapest_cost
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	assert_true(_press("Buy"), "setup: a buy row is on the page")
	assert_true(_save.owns_model(cheapest), "the cheapest car is now owned")


# An unaffordable row is disabled AND carries menu_nav_skip — the same rule the REGION
# page's locked rows follow (see test_a_locked_region_is_shown_but_not_focusable).
func test_an_unaffordable_car_row_is_shown_but_not_focusable() -> void:
	_save.profile[_save.KEY_MONEY] = 0
	_shell._show(HubShell.View.CAR)
	await get_tree().process_frame
	assert_false(_confirmable_texts().contains("BUY"),
		"with no money, no Buy card is confirmable")


# Every id the SHOP/SKILLS carousels key an icon by must have a real icons/cards/<id>.svg
# — a new catalogue entry without its icon would silently fall back to the generic
# sparkle in _card_icon, which is fine for a test fixture's fx_* id but a shipped
# wording-quality bug this catches at the table level.
func test_every_catalogued_boost_and_skill_has_a_card_icon() -> void:
	for id in BoostLibrary.CATALOGUE.keys():
		assert_true(ResourceLoader.exists("res://icons/cards/%s.svg" % id),
			"boost '%s' has no icon in icons/cards/" % id)
	for skill in SkillLibrary.all():
		var id := String((skill as Dictionary).get("id", ""))
		if id.is_empty():
			continue
		assert_true(ResourceLoader.exists("res://icons/cards/%s.svg" % id),
			"skill '%s' has no icon in icons/cards/" % id)


func test_shop_lists_every_leveled_boost_in_one_carousel() -> void:
	_shell._show(HubShell.View.SHOP)
	await get_tree().process_frame
	assert_not_null(_carousel(), "the shop presents its wares as a carousel")
	for id in BoostLibrary.CATALOGUE:
		assert_true(_all_texts().contains(BoostLibrary.label_for(String(id)).to_upper()),
			"boost %s is on the shop page itself" % id)
	# The Engine Swap is NOT here any more: it is a genuine, deterministic mid-run engine
	# swap now (RunSession._pool_engine_swap_ids), not a leveled BoostLibrary entry with a
	# shop price — see features/engine-swap.md.


# Level display is 1-based even though Save.boost_level storage is 0-based: an
# un-upgraded boost (stored level 0) must read "Lv 1", never "Lv 0" — and the total rung
# count / "rolls X to Y" ladder range must not appear at all now that the card only shows
# the current level, current increase and upgrade price.
func test_shop_card_shows_a_one_based_level_for_an_unupgraded_boost() -> void:
	var id: String = BoostLibrary.CATALOGUE.keys()[0]
	assert_eq(_save.boost_level(id), 0, "setup: never purchased")
	_shell._show(HubShell.View.SHOP)
	await get_tree().process_frame
	var c := _carousel()
	assert_not_null(c, "the shop presents its wares as a carousel")
	var text := _card_text(c, 0)
	assert_true(text.contains("LV 1"), "a never-upgraded boost displays as level 1, not 0")
	assert_false(text.contains("/"), "the total rung count is no longer shown on the card")
	assert_false(text.contains("ROLLS"), "the old 'rolls X to Y' ladder-range wording is gone")


# Buying a level bumps the displayed level by one too, tracking storage exactly.
func test_shop_card_level_display_tracks_a_purchased_level() -> void:
	var id: String = BoostLibrary.CATALOGUE.keys()[0]
	_save.profile[_save.KEY_MONEY] = _save.boost_level_price(id)
	_shell._show(HubShell.View.SHOP)
	await get_tree().process_frame
	assert_true(_press(BoostLibrary.label_for(id)), "setup: buy one level")
	assert_eq(_save.boost_level(id), 1, "setup: stored level is now 1")
	_shell._show(HubShell.View.SHOP)
	await get_tree().process_frame
	var c := _carousel()
	assert_true(_card_text(c, 0).contains("LV 2"),
		"a boost stored at level 1 displays as level 2 (stored + 1)")


func test_buying_a_boost_level_raises_it_and_spends_money() -> void:
	var id: String = BoostLibrary.CATALOGUE.keys()[0]
	_save.profile[_save.KEY_MONEY] = _save.boost_level_price(id)
	assert_eq(_save.boost_level(id), 0, "setup: level 0")
	_shell._show(HubShell.View.SHOP)
	await get_tree().process_frame
	assert_true(_press(BoostLibrary.label_for(id)), "setup: the boost's card is on the page")
	assert_eq(_save.boost_level(id), 1, "the level went up by one")
	assert_eq(_save.money(), 0, "and the price was spent")


# --- Skills + lifetime stats (stage 7) -------------------------------------------
# Synthetic skills throughout (SkillLibrary.override_for_test), never the shipped
# SKILLS table — per CLAUDE.md, a skill's price/threshold/existence is authored data
# and must not be pinned by a test.

const FX_SKILLS: Array[Dictionary] = [
	{
		"id": "fx_locked", "label": "Fixture Locked Skill", "price": 100,
		"unlock": {"stat": "fx_stat", "threshold": 999},
	},
	{
		"id": "fx_buyable", "label": "Fixture Buyable Skill", "price": 50,
		"unlock": {"stat": "fx_stat", "threshold": 0},
	},
]


func test_skills_page_shows_a_locked_skill_but_not_focusable() -> void:
	SkillLibrary.override_for_test(FX_SKILLS)
	_shell._show(HubShell.View.SKILLS)
	await get_tree().process_frame
	assert_true(_all_texts().contains("FIXTURE LOCKED SKILL"), "the locked skill is still shown")
	assert_false(_confirmable_texts().contains("FIXTURE LOCKED SKILL"),
		"but it is not confirmable — its threshold has not been crossed")
	SkillLibrary.reset()


func test_buying_an_unlocked_skill_from_the_page_moves_it_to_owned() -> void:
	SkillLibrary.override_for_test(FX_SKILLS)
	_save.profile[_save.KEY_MONEY] = 50
	_shell._show(HubShell.View.SKILLS)
	await get_tree().process_frame
	assert_true(_press("Fixture Buyable Skill"), "setup: a buy card is on the page")
	assert_true(_save.owns_skill("fx_buyable"), "the skill is now owned")
	SkillLibrary.reset()


func test_equipping_an_owned_skill_from_the_page_marks_it_equipped() -> void:
	SkillLibrary.override_for_test(FX_SKILLS)
	_save.profile[_save.KEY_MONEY] = 50
	_save.buy_skill("fx_buyable")
	_shell._show(HubShell.View.SKILLS)
	await get_tree().process_frame
	assert_true(_press("Equip"), "setup: an equip row is on the page")
	assert_true(_save.skill_equipped("fx_buyable"))
	SkillLibrary.reset()


func test_stats_page_lists_every_lifetime_stat_and_still_backs_out() -> void:
	_save.profile[_save.KEY_LIFETIME] = {}
	_shell._show(HubShell.View.STATS)
	await get_tree().process_frame
	var texts: Array[String] = []
	# Walk the whole subtree, not just direct children: MenuPage nests its body inside a
	# scroll container. And compare UPPERCASED — UITheme.enforce uppercases every label, so
	# a case-sensitive match tests the theme's casing rather than the page's content.
	for label in _page().find_children("*", "Label", true, false):
		texts.append(String((label as Label).text).to_upper())
	var joined := " | ".join(texts)
	for id in LifetimeStats.IDS:
		assert_true(joined.contains(LifetimeStats.label_for(String(id)).to_upper()),
			"the stats page shows a row for '%s'" % id)
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN, "stats backs out to the main page")


# --- The challenge entry point (stage 9, decision 15) ---------------------------------
#
# The MINIMUM that makes the retained challenge mode reachable. These pin the SCREEN GRAPH
# and the eligibility gate, not the wording or the period rules (ChallengeLibrary's own
# tests own those).

func test_the_main_page_reaches_the_challenge() -> void:
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	assert_true(_press("Rally challenge"), "the main page offers the challenge")
	assert_eq(_shell._view, HubShell.View.CHALLENGE)


func test_the_challenge_page_backs_out_to_main() -> void:
	_shell._show(HubShell.View.CHALLENGE)
	await get_tree().process_frame
	_shell._back()
	assert_eq(_shell._view, HubShell.View.MAIN)


# Picking a period hands off to the SHARED car page — and the car page must then back out
# to the challenge, not to region select, or the player is dropped into a flow they never
# opened.
func test_picking_a_period_opens_the_car_page_and_backs_out_to_the_challenge() -> void:
	_shell._show(HubShell.View.CHALLENGE)
	await get_tree().process_frame
	assert_true(_press("Daily"), "a live period is offered")
	assert_eq(_shell._view, HubShell.View.CAR)
	await get_tree().process_frame
	_shell._back()
	assert_eq(_shell._view, HubShell.View.CHALLENGE)


# Region select CLEARS the pending challenge, so a player who backs out of a challenge and
# starts a region run does not silently start a challenge instead.
func test_opening_region_select_clears_a_pending_challenge() -> void:
	_shell._show(HubShell.View.CHALLENGE)
	await get_tree().process_frame
	assert_true(_press("Daily"))
	assert_ne(_shell._pending_challenge, "", "setup: a challenge is pending")
	_shell._show(HubShell.View.REGION)
	await get_tree().process_frame
	assert_eq(_shell._pending_challenge, "", "region select drops the challenge intent")


# --- Drivetrain conversions: MOVED to the between-stage pick -----------------------
#
# Decision 52 (a per-car purchase sold from the SHOP page, DRIVETRAIN / DRIVETRAIN_CAR) is
# superseded: a conversion is now a run-scoped mid-run upgrade picked between stages
# (RunSession.choose_drivetrain, RunPickPanel), so the SHOP no longer hosts it — see
# tests/headless/test_run_pick_panel.gd and test_run_session.gd for the coverage that
# replaces this block.


# --- Interactive load: cars warm behind the loading screen ------------------------
#
# features/card-carousel.md's warming section: on an interactive load, _ready() holds a
# LoadingScreen over the pages until CarPreviewCache has EVERY car cached, so the CAR
# page opens on pure cache hits instead of paying CarProp.spawn's synchronous cost the
# first time each car scrolls in (the original first-visit lag). Headless runs keep the
# fire-and-forget trickle, so this test flips _warm_behind_loading_screen BEFORE the
# shell enters the tree to exercise the interactive path deterministically.
func test_interactive_load_holds_a_loading_screen_until_every_car_is_cached() -> void:
	var shell := HubShell.new()
	shell._warm_behind_loading_screen = true
	add_child_autofree(shell)

	# The overlay is up from the moment _ready starts warming (it is added before the
	# awaited warm_all, in the same call).
	assert_false(shell.find_children("*", "LoadingScreen", true, false).is_empty(),
		"a loading screen must cover the pages while warming runs")

	# An awaited warm_all joins whatever pass the shells started and returns only when
	# the whole cache is built — one extra frame lets the overlay's finish() queue_free
	# land before the tree is searched again.
	await CarPreviewCache.warm_all()
	await get_tree().process_frame

	assert_true(shell.find_children("*", "LoadingScreen", true, false).is_empty(),
		"the loading screen must be gone once every car is cached")
	for index in CarLibrary.all().size():
		assert_true(CarPreviewCache._cache.has(CarPreviewCache.key_for(index)),
			"catalogue car %d must be cached by the time the loading screen lifts" % index)

	# The warmed previews live under the CarPreviewCache AUTOLOAD (its graveyard), not
	# under this test's tree, so add_child_autofree never reaches them — free and erase
	# them the way test_car_preview_cache.gd's after_each does, or GUT's orphan monitor
	# flags them at run end. Fetched untyped first: a stale entry must not crash the
	# typed assignment below it guards.
	for key in CarPreviewCache._cache.keys():
		var cached = CarPreviewCache._cache[key]
		if cached != null and is_instance_valid(cached):
			if (cached as Node).get_parent() != null:
				(cached as Node).get_parent().remove_child(cached as Node)
			(cached as CarCardPreview).free()
		CarPreviewCache._cache.erase(key)


# --- The Resume card and the boot-time cloud pull ------------------------------
#
# The paused run lives in the profile, and the profile can be REPLACED under a live
# MAIN page: a signed-in player's cloud copy is downloaded asynchronously just after
# boot (Cloud._kick_off_initial_pull -> CloudSync.apply_remote -> profile_replaced),
# which is after HubShell._ready has already built MAIN and decided whether to offer
# "Resume run". The bug this pins: on first load the front door showed no Resume card
# for a run that WAS resumable, and only grew one once the player navigated away and
# came back.

# A minimal region-run record — the shape RunSession._persist writes, with only the
# keys resumable_run() reads. Synthetic on purpose (CLAUDE.md: no catalogue lookups).
func _paused_region_run() -> Dictionary:
	return {"mode": "region", "region_id": "anywhere", "run_seed": 7, "stage_count": 8,
		"car_instance_id": 0, "stage_index": 2, "stage_times_ms": [1000, 1000],
		"dnf": false, "money_earned": 0}


func test_main_offers_resume_for_a_stored_run() -> void:
	_save.profile[Save.KEY_RUN] = _paused_region_run()
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	assert_string_contains(_confirmable_texts(), "RESUME",
		"MAIN must offer the paused run when the profile holds a resumable one")


func test_profile_replaced_by_the_cloud_pull_rebuilds_main() -> void:
	_shell._show(HubShell.View.MAIN)
	await get_tree().process_frame
	assert_false(_confirmable_texts().contains("RESUME"),
		"setup: a fresh profile has no run to resume")

	# What the boot pull does: swap the profile, then say so.
	_save.profile[Save.KEY_RUN] = _paused_region_run()
	Cloud.profile_replaced.emit()
	await get_tree().process_frame

	assert_eq(_shell._view, HubShell.View.MAIN, "the shell stays on MAIN")
	assert_string_contains(_confirmable_texts(), "RESUME",
		"a run that arrived with the cloud pull must show as resumable without leaving MAIN")


func test_profile_replaced_does_not_yank_the_player_off_another_page() -> void:
	_shell._show(HubShell.View.SETTINGS)
	await get_tree().process_frame
	_save.profile[Save.KEY_RUN] = _paused_region_run()
	Cloud.profile_replaced.emit()
	await get_tree().process_frame
	assert_eq(_shell._view, HubShell.View.SETTINGS,
		"a mid-interaction page is left alone; only MAIN rebuilds itself")

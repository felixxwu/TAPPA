extends GutTest
# The SIMPLE upgrades page (UpgradesSimple) — the page every host mounts now, with today's
# page kept verbatim behind its Advanced button. See todo/simplified-upgrade-menu.md §3.
#
# What is worth testing here is the SHELL: that it honours the same host interface
# UpgradesMenu does, that Advanced round-trips, that the p/w gate can't be escaped through
# it, and that it is navigable without a pointer. The solver behind Auto-Upgrade is
# covered in test_auto_build.gd and the two-press rule in test_upgrades_menu.gd.


func before_each() -> void:
	CarFixtures.install()
	UpgradeFixtures.install()


func after_each() -> void:
	UpgradeFixtures.restore()
	CarFixtures.restore()


func _owned() -> Dictionary:
	return {"instance_id": -1, "model_id": "fx_light_rwd", "hp": 100.0,
		"installed_upgrades": [], "disabled_upgrades": [], "tuning": {}}


func _page(pw_limit := UpgradesSimple.NO_LIMIT) -> UpgradesSimple:
	var p := UpgradesSimple.new()
	add_child_autofree(p)
	p.setup(_owned(), Callable(), Callable(), pw_limit)
	return p


func test_it_builds_a_stat_block_and_an_advanced_button() -> void:
	var p := _page()
	assert_gt(p._simple_box.get_child_count(), 1, "the simple page has rows")
	assert_not_null(p._advanced_button, "and a way through to Advanced")
	assert_false(p._advanced_box.visible, "which starts closed")


func test_the_stat_block_is_drawn_as_bars() -> void:
	# The stats are bars scaled against the whole roster (CarStatBounds), not bare numbers:
	# a countable bar is what lets a player compare this car with every other one.
	var p := _page()
	var bars := 0
	for c in p._simple_box.get_children():
		if c is StatBar:
			bars += 1
	assert_gt(bars, 1, "the summary draws several stat bars")


func test_stability_is_a_bar_as_well_as_a_word() -> void:
	# Stability is an INDEX, not a measurement, so what is testable is the rule it encodes:
	# an all-wheel-drive car with balanced weight forgives more than a rear-heavy RWD one,
	# and the score always lands inside the unit range so the bar can draw it.
	var p := _page()
	var forgiving := p._stability_index({"drive_mode": CarLibrary.AWD, "weight_front": 0.5})
	var twitchy := p._stability_index({"drive_mode": CarLibrary.RWD, "weight_front": 0.2})
	assert_gt(forgiving, twitchy, "balanced AWD scores above rear-heavy RWD")
	for score in [forgiving, twitchy, p._stability_index({})]:
		assert_between(score, 0.0, 1.0, "the index stays inside the unit range")


func test_advanced_round_trips_back_to_simple() -> void:
	var p := _page()
	p._show_advanced()
	assert_true(p._advanced_box.visible, "Advanced opens")
	assert_false(p._simple_box.visible, "and takes over the page")
	p._show_simple()
	assert_true(p._simple_box.visible, "Back returns to the summary")
	assert_false(p._advanced_box.visible, "and closes Advanced")


func test_the_pw_gate_cannot_be_escaped_through_the_simple_page() -> void:
	# A limit of 1 hp/t is under any real car, so the page must refuse to close — otherwise
	# Simple would be a way to walk out of the start line still over the cap.
	var p := _page(1.0)
	assert_true(p.over_pw_limit(), "the page knows it is over the limit")
	assert_false(p.can_close(), "and refuses to close")
	var free_page := _page(100000.0)
	assert_true(free_page.can_close(), "a legal build closes freely")


func test_no_limit_never_blocks_closing() -> void:
	var p := _page()
	assert_false(p.over_pw_limit(), "no limit means never over")
	assert_true(p.can_close(), "so closing is always allowed")


func test_it_is_navigable_without_a_pointer() -> void:
	# CLAUDE.md: every menu answers to keyboard AND gamepad. A page whose controls are
	# FOCUS_NONE is reachable by tap only.
	var p := _page()
	assert_not_null(p.first_control(), "there is somewhere for the cursor to land")
	assert_eq(p._advanced_button.focus_mode, Control.FOCUS_ALL,
		"the Advanced button is focusable")
	var found_nav := false
	for c in p._simple_box.get_children():
		if c is MenuNav:
			found_nav = true
	assert_true(found_nav, "the summary is wired to the nav framework")


func test_the_close_button_binding_is_shared_with_advanced() -> void:
	var p := _page(1.0)
	var button := Button.new()
	add_child_autofree(button)
	p.bind_close_button(button, Callable())
	assert_false(p.can_close(), "still gated while over the limit")
	assert_eq(button.text, p._advanced._close_button.text,
		"both pages paint the one close button")


func test_the_bars_actually_get_width_when_laid_out() -> void:
	# The bug this guards: the page is hosted in a shrink-wrapping panel, so a bar built
	# from zero-minimum blocks laid out to nothing and the stat block rendered as plain
	# text rows. Assert on the POST-LAYOUT size, not just the minimum, since that is what
	# the player sees.
	var host := PanelContainer.new()
	host.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child_autofree(host)
	var page := UpgradesSimple.new()
	host.add_child(page)
	page.setup(_owned(), Callable(), Callable())
	await get_tree().process_frame
	await get_tree().process_frame
	var bar: StatBar = null
	for c in page._simple_box.get_children():
		if c is StatBar:
			bar = c
			break
	assert_not_null(bar, "the summary has a stat bar")
	var blocks := 0
	for child in bar.get_children():
		if not (child is HBoxContainer):
			continue
		for block in child.get_children():
			if block is ColorRect and (block as ColorRect).size.x > 0.0:
				blocks += 1
	assert_eq(blocks, StatBar.SEGMENTS, "every block is laid out with real width")


func test_auto_upgrade_only_appears_under_a_rally_target() -> void:
	# The HQ lift mounts this page with no ceiling and must show no Auto row: with no event
	# in mind there is nothing for Auto to aim at. The hosts that DO pass one (start line,
	# over-power prompt, reward reveal) get it.
	# A REAL saved car, since Auto plans against the save rather than the passed dict.
	var earned: int = int(Save.profile.get("stars_earned", 0))
	Save.profile["stars_earned"] = 100
	var car: Dictionary = Save.grant_car("fx_light_rwd")
	assert_null(_auto_row(_page_for(car, UpgradesSimple.NO_LIMIT)),
		"no target, no Auto-Upgrade row")
	assert_not_null(_auto_row(_page_for(car, 100000.0)),
		"a hosted p/w ceiling brings it in")
	Save.profile["stars_earned"] = earned


func _page_for(owned: Dictionary, pw_limit: float) -> UpgradesSimple:
	var p := UpgradesSimple.new()
	add_child_autofree(p)
	p.setup(owned, Callable(), Callable(), pw_limit)
	return p


func _auto_row(page: UpgradesSimple) -> AutoUpgradeRow:
	for c in page._simple_box.get_children():
		if c is AutoUpgradeRow:
			return c
	return null


func test_the_close_button_is_repainted_after_a_rebuild() -> void:
	# Regression: committing an Auto-Upgrade rebuilds the page, which replaces the Advanced
	# instance the close button was bound to. An unbound page paints nothing, so the stale
	# "over limit" warning stayed on screen next to a now-legal figure and Start stayed
	# refused. Every rebuild must re-bind.
	var p := _page(1.0)   # a 1 hp/t cap: no car is legal
	var button := Button.new()
	add_child_autofree(button)
	p.bind_close_button(button, Callable())
	var warned := String(button.text)
	assert_true(p.over_pw_limit(), "the car starts over the cap")
	# The build changing under the page is what a committed plan does; re-render and the
	# gate must catch up rather than keep the old warning.
	p._pw_limit = 100000.0
	p.rebuild()
	assert_not_null(p.advanced()._close_button,
		"the rebuilt Advanced page is bound to the host's close button")
	assert_true(p.can_close(), "a legal build may close")
	assert_ne(String(button.text), warned, "and the stale over-limit warning is gone")


# --- Per-category wrenches ----------------------------------------------------

func _bars(page: UpgradesSimple) -> Array:
	var out: Array = []
	for c in page._simple_box.get_children():
		if c is StatBar:
			out.append(c)
	return out


func _wrench_of(bar: StatBar) -> Button:
	for c in bar.get_children():
		if c is Button:
			return c
	return null


func test_every_category_row_carries_a_wrench() -> void:
	var p := _page()
	var seen := 0
	for bar in _bars(p):
		if _wrench_of(bar) != null:
			seen += 1
	assert_eq(seen, UpgradesSimple.CATEGORIES.size(),
		"one wrench per category, and none on the rows with no upgrades behind them")


func test_a_wrench_opens_advanced_filtered_to_its_own_slots() -> void:
	var p := _page()
	for category in UpgradesSimple.CATEGORIES:
		p._show_advanced(category)
		assert_true(p._advanced_box.visible, "%s's wrench opens Advanced" % category)
		assert_true(p.advanced().is_filtered(), "%s opens a filtered page" % category)
		var want: Array = (UpgradesSimple.CATEGORIES[category] as Dictionary)["slots"]
		assert_eq(p.advanced()._filter_slots, want,
			"%s shows exactly its own slots" % category)
		p._show_simple()


func test_the_advanced_button_still_opens_everything() -> void:
	var p := _page()
	p._show_advanced()
	assert_false(p.advanced().is_filtered(), "Advanced with no category is the whole page")


func test_the_categories_partition_the_slots() -> void:
	# Every real slot belongs to exactly one category, so "where do I change this?" has one
	# answer — and a slot added to the catalogue later can't silently become unreachable
	# from the simple page.
	var claimed := {}
	for category in UpgradesSimple.CATEGORIES:
		for slot in (UpgradesSimple.CATEGORIES[category] as Dictionary)["slots"]:
			assert_false(claimed.has(slot), "%s is claimed by only one category" % slot)
			claimed[slot] = true
	for slot in UpgradeLibrary.SLOTS:
		if UpgradeLibrary.is_hidden_slot(slot):
			continue
		assert_true(claimed.has(slot), "%s is reachable from some category" % slot)


func test_the_wrenches_are_keyboard_navigable() -> void:
	# CLAUDE.md: no menu is pointer-only. The wrenches sit at the right edge while
	# Auto-Upgrade and Advanced span the width, so up/down is wired explicitly rather than
	# left to the geometric neighbour search.
	var p := _page()
	var column: Array = []
	for bar in _bars(p):
		var w := _wrench_of(bar)
		if w != null:
			column.append(w)
	assert_gt(column.size(), 1, "there are several wrenches to move between")
	for w in column:
		assert_eq((w as Button).focus_mode, Control.FOCUS_ALL, "each wrench takes focus")
	for i in range(column.size() - 1):
		var below: Control = (column[i] as Control).get_node(
			(column[i] as Control).focus_neighbor_bottom)
		assert_eq(below, column[i + 1], "down moves to the next row's wrench")
		var above: Control = (column[i + 1] as Control).get_node(
			(column[i + 1] as Control).focus_neighbor_top)
		assert_eq(above, column[i], "and up comes back")
	# The chain must not dead-end at the last bar: Advanced sits below it.
	var last: Control = column[column.size() - 1]
	assert_ne(last.get_node(last.focus_neighbor_bottom), last,
		"the last wrench leads on to the buttons below")


func test_a_category_with_nothing_in_it_gets_no_wrench() -> void:
	# A category is empty while every part in it is still undiscovered — the drivetrain row
	# shows nothing until the swap kit is won. A wrench opening a blank page is worse than
	# no wrench: it is the "when do I get this?" prompt the rest of the menu hides locked
	# options to avoid.
	#
	# The stock fixture roster has an UNGATED drivetrain kit (so that category is legitimately
	# non-empty there); this installs a roster where it is gated behind an unwon rally.
	var gated: Array[Dictionary] = []
	for item in UpgradeFixtures.upgrades():
		if String(item.get("slot", "")) == "drivetrain":
			item["unlocked_by_rally"] = "a_rally_nobody_has_won"
		gated.append(item)
	UpgradeLibrary.override_for_test(gated)

	var p := _page()
	assert_false(p.advanced().has_rows_for(["drivetrain"], false, false),
		"an undiscovered swap kit leaves the drivetrain category empty")
	assert_null(_wrench_of(_bar_named(p, "Stability")), "so Stability shows no wrench")
	# ... and the categories that DO have parts keep theirs, so this isn't just "no
	# wrenches anywhere".
	assert_not_null(_wrench_of(_bar_named(p, "Speed")), "Speed still has one")


func _bar_named(page: UpgradesSimple, name: String) -> StatBar:
	for bar in _bars(page):
		var label := (bar as StatBar).get_child(0) as Label
		if label != null and label.text.to_upper().begins_with(name.to_upper()):
			return bar
	return null


func test_every_row_is_the_same_height() -> void:
	# A wrenched row is as tall as a menu button; a wrenchless one would otherwise be as
	# tall as its text, leaving the bars unevenly spaced for no visible reason.
	var host := PanelContainer.new()
	add_child_autofree(host)
	var page := UpgradesSimple.new()
	host.add_child(page)
	page.setup(_owned(), Callable(), Callable())
	await get_tree().process_frame
	await get_tree().process_frame
	var heights := {}
	for bar in _bars(page):
		heights[roundi((bar as StatBar).size.y)] = true
	assert_eq(heights.size(), 1, "every stat row lays out to the same height")


func test_rows_without_a_wrench_keep_the_figures_aligned() -> void:
	# Condition never has a wrench. Its value column must still line up with the rows that
	# do — a ragged column of numbers reads as a bug.
	var p := _page()
	for bar in _bars(p):
		var last: Control = bar.get_child(bar.get_child_count() - 1)
		assert_almost_eq(last.custom_minimum_size.x, StatBar.WRENCH_MIN_W, 0.01,
			"every row ends with a wrench-width column, button or not")


func test_editing_on_the_advanced_page_does_not_yank_focus() -> void:
	# Regression: the host re-attached MenuNav to Advanced after every edit to keep its back
	# route alive, and MenuNav.attach defers a focus GRAB — so left/right on the engine
	# detune slider adjusted the value and then threw the cursor to the top of the page.
	# The back route is owned by the page itself now (UpgradesMenu.set_back_action), so an
	# edit re-attaches nothing.
	var p := _page()
	p._show_advanced()
	await get_tree().process_frame
	var slider: HSlider = p.advanced()._detune_slider
	assert_not_null(slider, "the advanced page has its detune slider")
	slider.grab_focus()
	await get_tree().process_frame
	p._on_advanced_change()   # what an edit notifies
	await get_tree().process_frame
	await get_tree().process_frame
	assert_eq(get_viewport().gui_get_focus_owner(), slider,
		"the cursor stays on the slider being dragged")

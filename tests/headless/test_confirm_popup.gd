# tests/headless/test_confirm_popup.gd
extends GutTest

var _host: Node

func before_each() -> void:
	_host = Node.new()
	add_child_autofree(_host)

func _actions_with_flag(flag: Array) -> Array:
	# flag is a shared 1-element array the callback writes into, so the test can
	# observe which callback fired.
	return [
		{"label": "Yes", "callback": func() -> void: flag[0] = "yes"},
		{"label": "No", "callback": func() -> void: flag[0] = "no"},
	]

func test_open_builds_one_button_per_action() -> void:
	var popup := ConfirmPopup.open(_host, "T", "B", _actions_with_flag([""]))
	var buttons := popup.find_children("*", "Button", true, false)
	assert_eq(buttons.size(), 2, "one button per action")

func test_pressing_action_fires_its_callback_and_dismisses() -> void:
	var flag := [""]
	var popup := ConfirmPopup.open(_host, "T", "B", _actions_with_flag(flag))
	var buttons := popup.find_children("*", "Button", true, false)
	(buttons[0] as Button).pressed.emit()
	assert_eq(flag[0], "yes", "action 0 callback fired")
	await get_tree().process_frame
	assert_false(is_instance_valid(popup), "popup dismissed after press")

func test_disabled_action_button_is_disabled() -> void:
	var actions := [
		{"label": "Go", "callback": Callable(), "disabled": true},
		{"label": "Cancel", "callback": Callable()},
	]
	var popup := ConfirmPopup.open(_host, "T", "B", actions)
	var buttons := popup.find_children("*", "Button", true, false)
	assert_true((buttons[0] as Button).disabled, "disabled flag honoured")

# CHANGED DELIBERATELY: back used to default to the LAST action, which was right only
# while the dismiss button sat on the right. The house order now puts exit/cancel LEFT
# and the proceeding action RIGHT (features/menus.md "Button order"), so the default had
# to move with it — leaving it on the last action would route Esc / gamepad-B to the
# CONFIRMING button, i.e. Escape would abandon a rally or overwrite a career.
func test_back_index_defaults_to_the_first_action() -> void:
	var flag := [""]
	var popup := ConfirmPopup.open(_host, "T", "B", _actions_with_flag(flag))
	popup.trigger_back()
	assert_eq(flag[0], "yes", "Back fires the FIRST (leftmost = cancel) action by default")


# A single-action popup is unaffected by that change — first and last are one button.
func test_back_on_a_single_action_popup_fires_that_action() -> void:
	var flag := [""]
	var popup := ConfirmPopup.open(_host, "T", "B",
		[{"label": "OK", "callback": func() -> void: flag[0] = "ok"}])
	popup.trigger_back()
	assert_eq(flag[0], "ok", "the only action is both the default and the back action")

# --- One modal at a time ------------------------------------------------------
# Every modal in the game is a ConfirmPopup or a UsernamePopup, both on layer 101,
# so two on screen at once is always a bug: the top one hides the other and
# dismissing it "does nothing" except reveal a twin with the focus cursor reset.
# That shipped once, from two subscribers to one broadcast each checking its own
# private latch. The rule now lives in ConfirmPopup.MODAL_GROUP.
# See todo/challenge-career-reuse-drift.md item 10.

func test_a_popup_joins_the_modal_group_and_is_reported_tree_wide() -> void:
	assert_null(ConfirmPopup.any_open(get_tree()), "setup: nothing on screen")
	var popup := ConfirmPopup.open(_host, "T", "B", _actions_with_flag([""]))
	assert_eq(ConfirmPopup.any_open(get_tree()), popup,
		"the live popup is the tree-wide answer to 'is a modal up?'")

func test_a_second_popup_is_refused_rather_than_stacked() -> void:
	var first := ConfirmPopup.open(_host, "First", "B", _actions_with_flag([""]))
	assert_not_null(first, "setup: the first one opens")

	assert_null(ConfirmPopup.open(_host, "Second", "B", _actions_with_flag([""])),
		"a second modal is refused, not stacked")
	assert_eq(ConfirmPopup.any_open(get_tree()), first,
		"and the one already on screen is untouched")

func test_a_different_host_cannot_stack_a_second_popup() -> void:
	# The shape of the original bug: two DIFFERENT nodes reacting to one broadcast.
	# A per-host latch cannot see across hosts; the group can.
	var other := Node.new()
	add_child_autofree(other)
	assert_not_null(ConfirmPopup.open(_host, "First", "B", _actions_with_flag([""])))
	assert_null(ConfirmPopup.open(other, "Second", "B", _actions_with_flag([""])),
		"exclusivity is tree-wide, not per-host")

func test_a_popup_being_freed_does_not_block_the_next_one() -> void:
	# A dismissed popup stays in its groups until the end of the frame, so a host
	# re-checking from its own `finished` handler must not be told a modal is still
	# up by the very popup that just closed.
	var first := ConfirmPopup.open(_host, "First", "B", _actions_with_flag([""]))
	first.queue_free()
	assert_null(ConfirmPopup.any_open(get_tree()),
		"a popup queued for deletion no longer counts as on screen")
	assert_not_null(ConfirmPopup.open(_host, "Second", "B", _actions_with_flag([""])),
		"so the replacement opens in the same frame")

func test_allow_stack_lets_a_failure_notice_through() -> void:
	# The one deliberate exception: a "couldn't sync" notice dropped silently is how
	# a failed resolution becomes invisible.
	assert_not_null(ConfirmPopup.open(_host, "First", "B", _actions_with_flag([""])))
	assert_not_null(
		ConfirmPopup.open(_host, "Failure", "B", [{"label": "OK"}], 0, 0, true),
		"allow_stack opts out of the exclusivity rule")

func test_the_username_popup_shares_the_same_exclusivity() -> void:
	# It is the same layer-101 furniture, so it has to mean the same thing to the
	# group or the two kinds of modal stack over each other.
	assert_not_null(ConfirmPopup.open(_host, "First", "B", _actions_with_flag([""])))
	assert_null(UsernamePopup.open(_host),
		"a name prompt cannot open over a confirm popup")

func test_a_confirm_popup_cannot_open_over_a_username_popup() -> void:
	assert_not_null(UsernamePopup.open(_host), "setup: the name prompt opens")
	assert_null(ConfirmPopup.open(_host, "Second", "B", _actions_with_flag([""])),
		"and the exclusivity holds in the other direction too")

# --- open_committing: reserve the screen, THEN commit -------------------------
# The bug: an irreversible save transaction ran BEFORE a presentation that can be
# refused, so the transaction landed and its one and only reveal was dropped (two
# mystery boxes opened, one reveal seen). open_committing acquires the modal slot
# first, so "committed but unreportable" cannot happen.

func test_open_committing_runs_the_mutation_and_shows_its_body() -> void:
	var ran := [0]
	var popup: ConfirmPopup = await ConfirmPopup.open_committing(_host, "T", "...",
		[{"label": "OK", "callback": Callable()}],
		func(_p: ConfirmPopup) -> String:
			ran[0] += 1
			return "the reward")
	assert_not_null(popup, "with the slot free, the popup opens")
	assert_eq(ran[0], 1, "and the mutation ran exactly once")
	assert_eq(popup._body_label.text, "the reward",
		"the body the commit produced replaced the placeholder")


func test_open_committing_does_not_run_the_mutation_when_a_modal_is_up() -> void:
	assert_not_null(ConfirmPopup.open(_host, "First", "B", _actions_with_flag([""])),
		"setup: something else owns the screen")
	var ran := [0]
	var popup: ConfirmPopup = await ConfirmPopup.open_committing(_host, "T", "...",
		[{"label": "OK", "callback": Callable()}],
		func(_p: ConfirmPopup) -> String:
			ran[0] += 1
			return "spent")
	assert_null(popup, "refused, like any other second modal")
	assert_eq(ran[0], 0,
		"and CRUCIALLY the irreversible mutation never ran — nothing was spent")


func test_open_committing_awaits_a_coroutine_commit() -> void:
	# world.gd's challenge reward must await its grant, so the commit contract has to
	# accept a coroutine, not just a plain function.
	var ran := [0]
	var tree := get_tree()
	var popup: ConfirmPopup = await ConfirmPopup.open_committing(_host, "T", "...",
		[{"label": "OK", "callback": Callable()}],
		func(_p: ConfirmPopup) -> String:
			await tree.process_frame
			ran[0] += 1
			return "granted")
	assert_eq(ran[0], 1, "the coroutine commit completed before the call returned")
	assert_eq(popup._body_label.text, "granted", "and its body landed on the popup")


func test_open_committing_lets_the_commit_fill_the_body_itself() -> void:
	# A commit with nothing to return can still report, by writing to the popup it was
	# handed — the same reason the body is deferred rather than a return value.
	var popup: ConfirmPopup = await ConfirmPopup.open_committing(_host, "T", "placeholder",
		[{"label": "OK", "callback": Callable()}],
		func(p: ConfirmPopup) -> void:
			p.set_body("written by the commit"))
	assert_eq(popup._body_label.text, "written by the commit",
		"set_body fills the placeholder in")


func test_open_committing_returns_an_ordinary_popup() -> void:
	var flag := [""]
	var popup: ConfirmPopup = await ConfirmPopup.open_committing(_host, "T", "...",
		_actions_with_flag(flag), func(_p: ConfirmPopup) -> String: return "body")
	assert_eq(ConfirmPopup.any_open(get_tree()), popup, "it holds the modal slot")
	var buttons := popup.find_children("*", "Button", true, false)
	assert_eq(buttons.size(), 2, "one button per action, as usual")
	popup.trigger_back()
	assert_eq(flag[0], "yes", "Back routes to the first (leftmost) action, as usual")
	await get_tree().process_frame
	assert_false(is_instance_valid(popup), "and it dismisses itself")


# --- Long body: scroll, don't push the buttons off screen ---------------------
# A ConfirmPopup has no touch dismissal other than its own buttons (trigger_back
# is reachable only from ui_cancel/menu_back — Escape or gamepad B, see
# project.godot) and its dim backdrop swallows taps, so a long caller-supplied
# body (server error text, a computed multi-line reward) must never be able to
# push the buttons past reach.

func test_a_very_long_body_still_leaves_every_button_present_and_focusable() -> void:
	var long_body := "line of text that should wrap and repeat many times over. ".repeat(60)
	var popup := ConfirmPopup.open(_host, "T", long_body, _actions_with_flag([""]))
	var buttons := popup.find_children("*", "Button", true, false)
	assert_eq(buttons.size(), 2, "both action buttons still exist")
	for b in buttons:
		assert_true((b as Button).focus_mode == Control.FOCUS_ALL,
			"and each stays focusable — never removed to make room")

func test_a_very_long_body_panel_does_not_exceed_the_viewport() -> void:
	var long_body := "line of text that should wrap and repeat many times over. ".repeat(60)
	var popup := ConfirmPopup.open(_host, "T", long_body, _actions_with_flag([""]))
	var panel := popup.find_children("*", "PanelContainer", true, false)[0] as PanelContainer
	var viewport_h: float = popup.get_viewport().get_visible_rect().size.y
	assert_true(panel.get_combined_minimum_size().y <= viewport_h,
		"a very long body must never grow the panel taller than the screen")

func test_a_short_body_popup_is_not_made_needlessly_tall() -> void:
	var popup := ConfirmPopup.open(_host, "T", "Short.", _actions_with_flag([""]))
	var panel := popup.find_children("*", "PanelContainer", true, false)[0] as PanelContainer
	var viewport_h: float = popup.get_viewport().get_visible_rect().size.y
	assert_true(panel.get_combined_minimum_size().y < viewport_h,
		"a short body should hug its content, nowhere near the full viewport height")

func test_username_popup_panel_does_not_exceed_the_viewport() -> void:
	# Same shape as ConfirmPopup, fixed for consistency even though its body is
	# an authored (not caller-supplied) string.
	var popup := UsernamePopup.open(_host)
	var panel := popup.find_children("*", "PanelContainer", true, false)[0] as PanelContainer
	var viewport_h: float = popup.get_viewport().get_visible_rect().size.y
	assert_true(panel.get_combined_minimum_size().y <= viewport_h,
		"the username popup panel must also never exceed the screen")

# REGRESSION. The scroll around the body was sized from
# `Font.get_multiline_string_size`, which knows nothing about the Label's
# `line_spacing` theme constant — so an N-line body got a viewport (N-1) x spacing
# too short and the last line(s) hid behind a scrollbar, on a FULLSCREEN popup with
# room to spare. These popups must always show all of their text.
#
# Asserts the relationship, not pixels: the scroll's viewport is at least as tall as
# the content inside it, i.e. there is nothing left to scroll to.
func _assert_body_fully_visible(label: Label, note: String) -> void:
	var scroll := label.get_parent() as ScrollContainer
	assert_not_null(scroll, "setup: the body sits in a scroll container")
	var bar := scroll.get_v_scroll_bar()
	assert_true(bar.page + 1.0 >= bar.max_value,
		"%s: the whole body fits without scrolling (content %.1f, viewport %.1f)"
			% [note, bar.max_value, bar.page])
	assert_true(scroll.size.y + 1.0 >= label.size.y,
		"%s: the scroll is at least as tall as its body label (%.1f vs %.1f)"
			% [note, scroll.size.y, label.size.y])

func test_a_multi_line_body_is_shown_in_full_without_scrolling() -> void:
	var body := "You are about to abandon this rally and return to the HQ. " \
		+ "Your progress in this run, including any stage times you have already " \
		+ "set, will be lost and cannot be recovered later on."
	var popup := ConfirmPopup.open(_host, "Quit to HQ?", body, _actions_with_flag([""]))
	await get_tree().process_frame
	await get_tree().process_frame
	assert_gt(popup._body_label.get_line_count(), 1, "setup: this body really does wrap")
	_assert_body_fully_visible(popup._body_label, "multi-line body")

func test_replacing_the_body_regrows_the_scroll_to_fit_it() -> void:
	# open_committing fills in a placeholder AFTER the popup is on screen, so the
	# fit must follow the new text rather than staying sized to the placeholder.
	var popup := ConfirmPopup.open(_host, "T", "Working...", _actions_with_flag([""]))
	await get_tree().process_frame
	popup.set_body("The mystery box paid out a brand new turbocharger for your car, "
		+ "plus a healthy pile of cash to spend on the next one you fancy.")
	await get_tree().process_frame
	await get_tree().process_frame
	assert_gt(popup._body_label.get_line_count(), 1, "setup: the replacement body wraps")
	_assert_body_fully_visible(popup._body_label, "replaced body")

func test_the_username_popup_body_is_shown_in_full_too() -> void:
	var popup := UsernamePopup.open(_host)
	await get_tree().process_frame
	await get_tree().process_frame
	var label := popup.find_children("*", "Label", true, false)[1] as Label
	_assert_body_fully_visible(label, "username popup body")

func test_a_pathologically_long_body_stays_scrollable_rather_than_clipped() -> void:
	# The cap is a fallback, not the normal case: a body too tall for the screen
	# must remain reachable by scrolling, and must not push the panel off screen.
	var long_body := "line of text that should wrap and repeat many times over. ".repeat(60)
	var popup := ConfirmPopup.open(_host, "T", long_body, _actions_with_flag([""]))
	await get_tree().process_frame
	await get_tree().process_frame
	var label: Label = popup._body_label
	var scroll := label.get_parent() as ScrollContainer
	var bar := scroll.get_v_scroll_bar()
	assert_gt(bar.max_value, bar.page, "an over-tall body keeps a real scroll range")
	var panel := popup.find_children("*", "PanelContainer", true, false)[0] as PanelContainer
	assert_true(panel.get_combined_minimum_size().y
		<= popup.get_viewport().get_visible_rect().size.y,
		"and the panel still fits on screen")

func test_an_unparented_host_cannot_raise_a_modal() -> void:
	# Exclusivity is answered from the scene tree, so a host outside it has no tree
	# to ask — raise nothing rather than a popup nobody can see or dismiss.
	var orphan := Node.new()
	assert_null(ConfirmPopup.open(orphan, "T", "B", _actions_with_flag([""])))
	assert_null(UsernamePopup.open(orphan))
	orphan.free()


# REGRESSION. The body Label lives in a TouchScrollContainer so a long body can't push
# the buttons off screen. But an autowrapped Label's MINIMUM width is a single character,
# and a ScrollContainer hands its child that minimum rather than stretching it — so the
# body collapsed to one column and wrapped after every letter ("A" / "B" / "A" …) with a
# scrollbar beside it. Reported from the phone on the "Quit to HQ?" confirm.
#
# Asserts the relationship, not a pixel width: a wrapped body must produce far fewer
# lines than it has characters. One-character-per-line makes lines ≈ characters.
func test_the_body_wraps_at_the_panel_width_not_one_character_per_line() -> void:
	var body := "Abandon this rally and return to HQ? Your progress in this run is lost."
	var popup := ConfirmPopup.open(self, "Quit to HQ?", body,
		[{"label": "Quit", "callback": Callable()}, {"label": "Cancel", "callback": Callable()}], 0)
	assert_not_null(popup, "setup: the popup opened")
	await get_tree().process_frame
	await get_tree().process_frame

	var label: Label = popup._body_label
	assert_not_null(label, "the popup keeps a handle on its body label")
	assert_lt(label.get_line_count(), int(body.length() / 4.0),
		"the body wraps at the panel width, not one character per line (got %d lines for %d chars)"
			% [label.get_line_count(), body.length()])
	assert_gt(label.size.x, 100.0,
		"and the label is actually given a sane width to wrap within (got %.1f)" % label.size.x)
	popup.trigger_back()
	await get_tree().process_frame

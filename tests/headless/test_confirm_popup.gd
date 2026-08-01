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

func test_back_index_defaults_to_last_action() -> void:
	var flag := [""]
	var popup := ConfirmPopup.open(_host, "T", "B", _actions_with_flag(flag))
	popup.trigger_back()
	assert_eq(flag[0], "no", "Back fires the last action by default")

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

func test_an_unparented_host_cannot_raise_a_modal() -> void:
	# Exclusivity is answered from the scene tree, so a host outside it has no tree
	# to ask — raise nothing rather than a popup nobody can see or dismiss.
	var orphan := Node.new()
	assert_null(ConfirmPopup.open(orphan, "T", "B", _actions_with_flag([""])))
	assert_null(UsernamePopup.open(orphan))
	orphan.free()

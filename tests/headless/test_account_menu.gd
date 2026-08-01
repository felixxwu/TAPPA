extends GutTest
# AccountMenu structure (see features/cloud-save.md › "UI").
#
# These are deliberately dumb "is the control actually on screen" checks rather
# than assertions about wording or layout. They exist because the first version
# of the sign-in forms BUILT their buttons and never parented them: every form
# shipped with no Create account / Sign in / Back button, reachable only by
# pressing Enter. Every widget the player must be able to press needs a test
# that it is in the tree, because "it was constructed" is not the same thing.

var _menu: AccountMenu
var _saved_uid := ""
var _saved_refresh := ""
var _saved_email := ""


func before_each() -> void:
	# Present as signed OUT regardless of the machine's real state. The Cloud
	# autoload restores a live session from user://auth.json at boot, so on a
	# developer machine that has actually signed in, the page would render its
	# signed-in variant and these assertions would flip.
	#
	# The in-memory fields are blanked directly rather than calling sign_out(),
	# which DELETES the credential file — a test must not log the developer out
	# of their own game.
	_saved_uid = Cloud.auth.uid
	_saved_refresh = Cloud.auth.refresh_token
	_saved_email = Cloud.auth.email
	Cloud.auth.uid = ""
	Cloud.auth.refresh_token = ""
	Cloud.auth.email = ""

	_menu = AccountMenu.new()
	add_child_autofree(_menu)


func after_each() -> void:
	Cloud.auth.uid = _saved_uid
	Cloud.auth.refresh_token = _saved_refresh
	Cloud.auth.email = _saved_email
	var focused := get_tree().root.get_viewport().gui_get_focus_owner()
	if focused != null:
		focused.release_focus()


# Every Button anywhere under the menu, by its (uppercased by UITheme) label.
func _button_labels() -> Array:
	var labels: Array = []
	for node in _menu.find_children("*", "Button", true, false):
		labels.append((node as Button).text)
	return labels


func _has_button_containing(fragment: String) -> bool:
	for label in _button_labels():
		if String(label).contains(fragment.to_upper()):
			return true
	return false


func test_signed_out_offers_a_way_in() -> void:
	assert_true(_has_button_containing("sign in with email"),
		"signed-out account page must offer email sign-in")
	assert_true(_has_button_containing("create an account"))


func test_the_register_form_has_a_submit_button() -> void:
	# The exact regression: the form rendered with fields but nothing to press.
	_menu._show(AccountMenu.View.REGISTER)
	assert_true(_has_button_containing("create account"),
		"the register form must have a button that submits it")
	assert_true(_has_button_containing("back"), "and a way back out")


func test_the_sign_in_form_has_its_buttons() -> void:
	_menu._show(AccountMenu.View.SIGN_IN)
	assert_true(_has_button_containing("sign in"))
	assert_true(_has_button_containing("forgot password"))
	assert_true(_has_button_containing("back"))


func test_the_reset_form_has_its_buttons() -> void:
	_menu._show(AccountMenu.View.RESET)
	assert_true(_has_button_containing("send reset email"))
	assert_true(_has_button_containing("back"))


func test_the_register_form_has_three_fields() -> void:
	_menu._show(AccountMenu.View.REGISTER)
	assert_eq(_menu.find_children("*", "LineEdit", true, false).size(), 3,
		"email, password and confirm password")


func test_every_form_control_is_focusable() -> void:
	# A control the cursor cannot reach is as good as absent on a gamepad.
	_menu._show(AccountMenu.View.REGISTER)
	for node in _menu.find_children("*", "Button", true, false):
		assert_ne((node as Button).focus_mode, Control.FOCUS_NONE,
			"button '%s' must be reachable by keyboard/gamepad" % (node as Button).text)
	for node in _menu.find_children("*", "LineEdit", true, false):
		assert_ne((node as LineEdit).focus_mode, Control.FOCUS_NONE,
			"text fields must be reachable by keyboard/gamepad")


func test_back_returns_to_the_main_view() -> void:
	_menu._show(AccountMenu.View.REGISTER)
	assert_false(_menu.at_root())
	assert_true(_menu.go_back(), "a form consumes Back")
	assert_true(_menu.at_root())
	assert_false(_menu.go_back(), "at the top level Back belongs to the host")


# --- The busy state (scripts/cloud/cloud_busy.gd) ------------------------------
# This page used to own a private copy of "a cloud call is in flight". It now uses
# the shared one, in its ambient shape. Assert the RELATIONSHIP and the controls,
# never the copy — the wording is content.

func test_a_cloud_call_in_flight_shows_the_shared_busy_state() -> void:
	assert_false(CloudBusy.showing(_menu), "nothing in flight on a freshly built page")
	assert_true(_menu._begin("Signing in…"), "a first request is accepted")
	assert_true(CloudBusy.showing(_menu), "and it shows the shared busy state")
	_menu._finish({"ok": true, "error": ""})
	assert_false(CloudBusy.showing(_menu), "which is gone once the call lands")


func test_a_second_request_cannot_start_while_one_is_in_flight() -> void:
	assert_true(_menu._begin("Signing in…"))
	assert_false(_menu._begin("Signing in again…"),
		"a double-tap must not fire two sign-ins")
	_menu._finish({"ok": true, "error": ""})
	assert_true(_menu._begin("Signing in…"), "and the page is usable again after")
	_menu._finish({"ok": true, "error": ""})


func test_the_busy_state_survives_the_rebuild_a_cloud_event_triggers() -> void:
	# Cloud.state_changed fires during a sign-in and rebuilds this page wholesale.
	# The busy line belongs to the call, not to the page.
	_menu._begin("Signing in…")
	_menu.rebuild()
	assert_true(CloudBusy.showing(_menu), "the rebuild must not take the busy line away")
	_menu._finish({"ok": true, "error": ""})


func test_a_failed_cloud_call_tells_the_player_why() -> void:
	_menu._begin("Signing in…")
	_menu._finish({"ok": false, "error": "that password is wrong"})
	assert_string_contains(_menu._message, "that password is wrong",
		"the server's own words reach the player")
	assert_eq(_menu._message_role, "red", "and read as a failure")

	# A failure with nothing to say still says something — one answer, from
	# CloudBusy, not a per-page invention.
	_menu._begin("Signing in…")
	_menu._finish({"ok": false, "error": ""})
	assert_eq(_menu._message, CloudBusy.GENERIC_FAILURE)

	_menu._begin("Signing in…")
	_menu._finish({"ok": true, "error": ""})
	assert_eq(_menu._message, "", "and a call that worked leaves no error behind")


# --- Signed-in main view (row-budget compaction) -------------------------------
# scripts/account_menu.gd's ROW BUDGET comment above _build_main: this page is
# hosted in a CENTRED VBox that also carries the host's Back button below it
# (hq.gd._open_account_overlay), so anything that overflows the screen pushes
# Back off the bottom where it cannot be pressed. These tests assert the
# behaviour that compaction must preserve, not the wording it landed on.

func _sign_in_fake() -> void:
	Cloud.auth.uid = "test_uid"
	Cloud.auth.refresh_token = "test_refresh"
	Cloud.auth.email = "player@example.com"
	_menu._show(AccountMenu.View.MAIN)  # rebuild against the now-signed-in Cloud


func test_signed_in_main_view_offers_every_action() -> void:
	_sign_in_fake()
	assert_true(_has_button_containing("leaderboard name"),
		"a way to change the leaderboard name must survive the compaction")
	assert_true(_has_button_containing("sync now"))
	assert_true(_has_button_containing("sign out"))


func test_leaderboard_name_rides_on_the_button_not_a_separate_label() -> void:
	# The compaction: the old layout had a Label row saying "Online leaderboard
	# name: X" ABOVE a button that changed it. The value now lives on the
	# button's own text, so no label row is needed to see it.
	var saved_name := String(Save.profile.get("username", ""))
	Save.profile["username"] = "kangaroo"
	_sign_in_fake()
	assert_true(_has_button_containing("kangaroo"),
		"the current leaderboard name must be reachable from a button, without a"
		+ " label row above it")
	Save.profile["username"] = saved_name


func test_signed_in_main_view_row_count_is_bounded() -> void:
	# Regression guard, not a pin on the exact count: the whole point of this
	# compaction was fitting above a Back button that lives OUTSIDE this menu
	# (hq.gd._open_account_overlay) on small screens. A generous but finite bound
	# stops the page quietly creeping back up to where Back is unreachable again.
	_sign_in_fake()
	var row_count := _menu.get_child_count()
	assert_lt(row_count, 8,
		"signed-in main view grew past its row budget (%d rows) — Back must stay"
		% row_count + " on screen below this page on a small screen")


func test_every_button_in_the_signed_in_view_is_focusable() -> void:
	_sign_in_fake()
	for node in _menu.find_children("*", "Button", true, false):
		assert_ne((node as Button).focus_mode, Control.FOCUS_NONE,
			"button '%s' must be reachable by keyboard/gamepad" % (node as Button).text)


func test_controls_come_back_after_a_cloud_call() -> void:
	# The busy state disables the page's buttons, so it must hand them back —
	# a menu left inert is unreachable by keyboard and gamepad alike.
	_menu._begin("Signing in…")
	for node in _menu.find_children("*", "Button", true, false):
		assert_true((node as Button).disabled, "buttons go inert while a call is in flight")
	_menu._finish({"ok": true, "error": ""})
	var buttons := _menu.find_children("*", "Button", true, false)
	assert_gt(buttons.size(), 0, "the page still has its controls")
	for node in buttons:
		assert_false((node as Button).disabled, "and they are live again afterwards")
		assert_ne((node as Button).focus_mode, Control.FOCUS_NONE,
			"and still reachable by keyboard/gamepad")

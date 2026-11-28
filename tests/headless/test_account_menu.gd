extends GutTest
# AccountMenu structure (see features/cloud-save.md › "UI").
#
# Deliberately dumb "is the control actually on screen" checks rather than
# assertions about wording or layout: a button that was built but never parented
# once shipped, and "it was constructed" is not the same as "it can be pressed".

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
	Cloud.auth.pending_email = ""
	Cloud.link_code = ""
	Cloud.deletion_needs_link = false
	Cloud._deleting_uid = ""
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


func test_back_is_held_only_while_a_call_is_in_flight() -> void:
	assert_false(_menu.go_back(), "an idle page leaves Back to the host")
	assert_true(_menu._begin("Signing in…"))
	assert_true(_menu.go_back(), "Back stays on the page until the call lands")
	_menu._finish({"ok": false, "error": ""})
	assert_false(_menu.go_back())


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
	_menu._finish({"ok": false, "error": "that link has expired"})
	assert_string_contains(_menu._message, "that link has expired",
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
# (a host that pins Back below the widget), so anything that overflows the screen pushes
# Back off the bottom where it cannot be pressed. These tests assert the
# behaviour that compaction must preserve, not the wording it landed on.

func _sign_in_fake() -> void:
	Cloud.auth.uid = "test_uid"
	Cloud.auth.refresh_token = "test_refresh"
	Cloud.auth.email = "player@example.com"
	_menu.rebuild()  # against the now-signed-in Cloud


func test_signed_in_main_view_offers_every_action() -> void:
	_sign_in_fake()
	assert_true(_has_button_containing("sync now"))
	assert_true(_has_button_containing("sign out"))
	assert_true(_has_button_containing("delete account"))


# --- Email link sign-in and account deletion ----------------------------------

func _fields() -> Array:
	return _menu.find_children("*", "TextField", true, false)


func _assert_reachable(controls: Array) -> void:
	for node in controls:
		for focusable in [node] + (node as Node).find_children("*", "Control", true, false):
			if focusable is LineEdit or focusable is Button:
				assert_ne((focusable as Control).focus_mode, Control.FOCUS_NONE,
					"%s must be reachable by keyboard/gamepad" % focusable)


func test_signed_out_page_offers_an_email_field_and_a_send_button() -> void:
	assert_gt(_fields().size(), 0, "somewhere to type the address")
	assert_true(_has_button_containing("sign-in link"))
	_assert_reachable(_fields())
	_assert_reachable(_menu.find_children("*", "Button", true, false))


func test_the_address_sent_to_is_filled_in_again() -> void:
	Cloud.auth.pending_email = "player@example.com"
	_menu.rebuild()
	assert_eq((_fields()[0] as TextField).text(), "player@example.com")


func test_a_code_from_the_page_url_waits_on_the_page_with_a_sign_in_button() -> void:
	Cloud.link_code = "the-code"
	_menu.rebuild()
	assert_eq(_fields().size(), 2, "address and code")
	assert_eq((_fields()[1] as TextField).text(), "the-code")
	assert_true(_has_button_containing("sign in"))


func test_typed_text_survives_a_rebuild() -> void:
	(_fields()[0] as TextField).set_text("typed@example.com")
	_menu.rebuild()
	assert_eq((_fields()[0] as TextField).text(), "typed@example.com")


func test_waiting_for_a_deletion_link_shows_a_code_form_and_back_cancels_it() -> void:
	_sign_in_fake()
	Cloud._deleting_uid = "test_uid"
	Cloud.deletion_needs_link = true
	_menu.rebuild()
	assert_eq(_fields().size(), 1, "somewhere to paste the code")
	assert_true(_has_button_containing("delete account"))
	assert_true(_has_button_containing("cancel"))
	_assert_reachable(_fields())
	_assert_reachable(_menu.find_children("*", "Button", true, false))
	assert_true(_menu.go_back(), "Back cancels the deletion rather than leaving the page")
	assert_false(Cloud.deletion_needs_link)
	assert_false(Cloud.is_deleting_account())
	assert_true(Cloud.sync.enabled, "and the career syncs again")


func test_signed_in_main_view_row_count_is_bounded() -> void:
	# Regression guard, not a pin on the exact count: the whole point of this
	# compaction was fitting above a Back button that lives OUTSIDE this menu
	# (a host that pins Back below the widget) on small screens. A generous but finite bound
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
	_sign_in_fake()
	_menu._begin("Syncing…")
	for node in _menu.find_children("*", "Button", true, false):
		assert_true((node as Button).disabled, "buttons go inert while a call is in flight")
	_menu._finish({"ok": true, "error": ""})
	var buttons := _menu.find_children("*", "Button", true, false)
	assert_gt(buttons.size(), 0, "the page still has its controls")
	for node in buttons:
		assert_false((node as Button).disabled, "and they are live again afterwards")
		assert_ne((node as Button).focus_mode, Control.FOCUS_NONE,
			"and still reachable by keyboard/gamepad")

class_name AccountMenu
extends VBoxContainer
# The optional-account UI: sign in, see sync status, resolve a conflict, sign out.
#
# ONE builder, TWO hosts — the same arrangement SettingsMenu already uses. It is
# added as a page inside Settings, and again as a standalone overlay reachable
# from the title screen (a player who wants to restore their career on a new
# device should not have to dig through Settings to find that out).
#
# Rebuilt wholesale on every state change rather than poking individual widgets:
# the page is small, it is never on screen during gameplay, and a full rebuild
# cannot leave a stale label behind.

signal page_changed(is_root: bool)

enum View { MAIN, SIGN_IN, REGISTER, RESET }

var _view: int = View.MAIN
var _busy := false
# The live shared busy state while a cloud call is in flight, else null.
# See scripts/cloud/cloud_busy.gd and _begin/_finish below.
var _busy_state: CloudBusy = null
var _message := ""
var _message_role := "dim"

var _email_field: TextField
var _password_field: TextField
var _confirm_field: TextField
# NO modal latches here. "Is a prompt already up?" is asked of the scene tree via
# ConfirmPopup.MODAL_GROUP — this page can be instantiated three times over, so a
# per-instance bool was never able to answer it.


func _ready() -> void:
	# GAP_TIGHT, not GAP: this page stacks more rows than any other menu and shares its
	# host with a Back button that must stay on screen (see _build_main's row budget).
	add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	Cloud.state_changed.connect(_on_cloud_state_changed)
	Cloud.conflict_detected.connect(_on_conflict_detected)
	Cloud.auth_lost.connect(_on_auth_lost)
	rebuild()


# --- Host-facing API ----------------------------------------------------------

# True while the top-level account view is showing (vs a form). Mirrors
# SettingsMenu.at_root() so the two hosts can treat both the same way.
func at_root() -> bool:
	return _view == View.MAIN


# Step back one level. Returns true when it consumed the press.
func go_back() -> bool:
	if _busy:
		return true  # a request is in flight; swallow rather than half-leave
	if at_root():
		return false
	_show(View.MAIN)
	return true


func focus_first() -> void:
	# Only when actually on screen. This page is built once at boot and parked
	# inside the Settings overlay, which the HQ hides via its CanvasLayer — and
	# a hidden CanvasLayer does not make is_visible_in_tree() false, so without
	# this guard a rebuild here yanks focus off whatever the player is looking
	# at (it stole the HQ title screen's cursor).
	if not MenuNav.is_on_screen(self):
		return
	UITheme.focus_grab(UITheme.first_focusable(self))


# --- Building -----------------------------------------------------------------

func rebuild() -> void:
	for child in get_children():
		# The in-flight cloud busy line survives a rebuild. It belongs to the call,
		# not to the page, and every state change during a sign-in triggers one of
		# these — freeing it here would take the "Signing in…" line away mid-request.
		# See scripts/cloud/cloud_busy.gd.
		if child.is_in_group(CloudBusy.GROUP):
			continue
		remove_child(child)
		child.queue_free()
	_email_field = null
	_password_field = null
	_confirm_field = null

	match _view:
		View.SIGN_IN:
			_build_email_form("Sign in", _on_sign_in_pressed)
		View.REGISTER:
			_build_email_form("Create account", _on_register_pressed, true)
		View.RESET:
			_build_reset_form()
		_:
			_build_main()

	if _message != "":
		add_child(UITheme.label(_message, _message_role))

	# Keep the preserved busy line at the bottom, where the message it stands in
	# for would have been.
	for child in get_children():
		if child.is_in_group(CloudBusy.GROUP):
			move_child(child, get_child_count() - 1)

	UITheme.enforce(self)
	# Only claim the cursor when this page is genuinely on screen. rebuild() runs
	# on every Cloud state change — including at boot, while parked inside the
	# hidden Settings overlay — and a focus grab from here lands on whatever the
	# player is actually looking at.
	var on_screen := MenuNav.is_on_screen(self)
	MenuNav.attach(self, {"grab": on_screen})
	if on_screen:
		focus_first.call_deferred()
	page_changed.emit(at_root())

	# A conflict raised while this page was closed still needs answering; show it
	# on OPEN — but only when this page is genuinely on screen. The modal is a
	# layer-101 CanvasLayer that seizes focus, so raising it from a page parked
	# inside a hidden overlay would throw a dialog over the title screen (or, in
	# a test run, over whatever the test was driving).
	if at_root() and MenuNav.is_on_screen(self) \
			and Cloud.sync != null and Cloud.sync.blocked_by_conflict:
		_prompt_conflict.call_deferred(Cloud.sync.conflict_summary())


# ROW BUDGET. This page is hosted in a CENTRED VBox that also carries the host's Back
# button below it (a host that pins Back below the widget), so anything that overflows the screen
# pushes Back off the bottom where it cannot be pressed. Every row here has to earn its
# place: prefer merging a value onto the control that changes it, or onto a related
# row, over adding a line of its own.
func _build_main() -> void:
	add_child(_heading("Account"))

	if not Cloud.is_signed_in():
		add_child(_sub("Sign in to back your career up and continue it on another device. "
			+ "This is optional — your progress is always saved on this device."))
		if FirebaseConfig.google_configured():
			add_child(_action("Sign in with Google", _on_google_pressed))
		add_child(_action("Sign in with email", func() -> void: _show(View.SIGN_IN)))
		add_child(_action("Create an account", func() -> void: _show(View.REGISTER)))
		return

	add_child(_sub("Signed in as %s" % Cloud.account_label()))
	# Sync status and last-sync time share ONE row. They are two halves of the same
	# answer ("is my career backed up, and as of when"), and this page has to fit on a
	# phone with the host's Back button still on screen below it — see the row budget
	# note above _build_main.
	var status := Cloud.status_message()
	var synced_at := ""
	if Cloud.sync != null and Cloud.sync.last_sync_utc != "":
		synced_at = "%s UTC" % Cloud.sync.last_sync_utc
	if status != "" and synced_at != "":
		add_child(UITheme.label("%s · %s" % [status, synced_at], _status_role()))
	elif status != "":
		add_child(UITheme.label(status, _status_role()))
	elif synced_at != "":
		add_child(_sub("Last synced %s" % synced_at))

	if Cloud.sync != null and Cloud.sync.blocked_by_conflict:
		add_child(_action("Resolve sync conflict",
			func() -> void: _prompt_conflict(Cloud.sync.conflict_summary())))

	# The leaderboard display name. Only shown signed in, because it is only ever
	# used on a posted time and only a signed-in player can post one. Captured on
	# first post (the global standings page); this is the edit-it-afterwards path.
	#
	# The value rides ON the button rather than sitting in a label above it. The pair
	# was two full rows saying the same word twice ("Online leaderboard name: Felix" /
	# "Change online leaderboard name"), which is the single biggest thing that pushed
	# Back off a small screen.
	var username := UsernamePopup.current()
	# Parenthesised deliberately: `%` binds tighter than the conditional, so the
	# unbracketed form means what it says here — but it reads as though the ternary
	# picks the format string, which is a trap for the next person to touch it.
	var name_button := _action(
		("Leaderboard name: %s" % username) if username != "" else "Set a leaderboard name",
		_on_username_pressed)
	name_button.tooltip_text = "Change the name shown on the online leaderboards"
	add_child(name_button)

	add_child(_action("Sync now", _on_sync_now_pressed))
	add_child(_action("Sign out", _on_sign_out_pressed))


func _build_email_form(action_label: String, on_submit: Callable, confirm := false) -> void:
	add_child(_heading(action_label))
	_email_field = TextField.new("Email", "you@example.com")
	_password_field = TextField.new("Password", "at least 6 characters", true)
	add_child(_email_field)
	add_child(_password_field)
	var column: Array = [_email_field, _password_field]
	if confirm:
		_confirm_field = TextField.new("Confirm password", "", true)
		add_child(_confirm_field)
		column.append(_confirm_field)

	# NOTE the add_child on every row: _action() only BUILDS a button, it does not
	# parent it. Forgetting that here once shipped a form with no buttons at all.
	var submit := _action(action_label, on_submit)
	add_child(submit)
	column.append(submit)
	if _view == View.SIGN_IN:
		var forgot := _action("Forgot password?", func() -> void: _show(View.RESET))
		add_child(forgot)
		column.append(forgot)
	var back := _action("< Back", func() -> void: _show(View.MAIN))
	add_child(back)
	column.append(back)

	# Enter in any field submits the form — the ordinary expectation, and the only
	# way to submit at all on a phone where the on-screen keyboard covers the button.
	_email_field.submitted.connect(on_submit)
	_password_field.submitted.connect(on_submit)
	if _confirm_field != null:
		_confirm_field.submitted.connect(on_submit)

	TextField.wire_column(column)


func _build_reset_form() -> void:
	add_child(_heading("Reset password"))
	add_child(_sub("We'll email you a link to set a new password."))
	_email_field = TextField.new("Email", "you@example.com")
	add_child(_email_field)
	var send := _action("Send reset email", _on_reset_pressed)
	add_child(send)
	var back := _action("< Back", func() -> void: _show(View.SIGN_IN))
	add_child(back)
	_email_field.submitted.connect(_on_reset_pressed)
	TextField.wire_column([_email_field, send, back])


# --- Actions ------------------------------------------------------------------
# Each handler follows the same shape: _begin() puts the page in its busy state
# (or refuses, if something is already in flight), then the operation runs, then
# _finish() repaints with whatever it reported.
#
# Deliberately NOT wrapped in a generic `await operation.call()` helper: some of
# these operations are coroutines (anything that touches the network) and some
# are purely local, and awaiting a non-coroutine is both a warning and a lie
# about what the code does. Spelling each one out keeps that honest.

func _on_google_pressed() -> void:
	# Platform-specific wording: on a phone the game is backgrounded while the
	# browser has focus, and the player must come back for the sign-in to
	# complete. See GoogleSignIn.waiting_message.
	if not _begin(GoogleSignIn.waiting_message()):
		return
	# Google is the path with no form of its own, so it is the one most easily
	# left out of the post-sign-in hook. It goes through the same call as the rest.
	if _finish(await Cloud.sign_in_google()):
		_maybe_prompt_username()


func _on_sign_in_pressed() -> void:
	var address := _email_field.text()
	var password := _password_field.line.text
	if not _begin("Signing in…"):
		return
	if _finish(await Cloud.sign_in_email(address, password)):
		_show(View.MAIN)
		_maybe_prompt_username()


func _on_register_pressed() -> void:
	if not _passwords_match():
		return
	var address := _email_field.text()
	var password := _password_field.line.text
	if not _begin("Creating your account…"):
		return
	if _finish(await Cloud.register_email(address, password)):
		_show(View.MAIN)
		_maybe_prompt_username()


func _on_reset_pressed() -> void:
	var address := _email_field.text()
	if not _begin("Sending…"):
		return
	if _finish(await Cloud.send_password_reset(address)):
		_set_message("Check your inbox for the reset link.", "green")
		rebuild()


func _on_sync_now_pressed() -> void:
	if not _begin("Syncing…"):
		return
	_finish(await Cloud.sync_now())


# --- Leaderboard name ---------------------------------------------------------

# Ask for a leaderboard name the moment an account exists without one.
#
# WHY HERE, and not on the leaderboard page. A signed-in player with a blank
# username posts NOTHING, silently — the cloud layer degrades a blank name to a
# read-only fetch. Leaving that to a button on the post-stage page meant relying
# on the player noticing and pressing it, on a screen they want to leave. Just
# after a successful sign-in is the one moment they are already setting their
# account up, and it happens once instead of after every stage.
#
# The global standings page KEEPS its own prompt as the fallback: players who
# signed in before this existed have a blank username and no sign-in event coming.
#
# Called from all three sign-in paths (email, register, Google) rather than from
# `_finish`, which is also the exit for Sync now / password reset / conflict
# resolution — none of which should raise a name prompt.
func _maybe_prompt_username() -> void:
	if UsernamePopup.current() != "":
		return
	# Same guard the conflict modal uses: the popup is a layer-101 CanvasLayer that
	# seizes focus, so it must never be raised from a page parked inside a hidden
	# overlay. is_on_screen, NOT is_visible_in_tree — the latter ignores a hidden
	# CanvasLayer ancestor.
	if not MenuNav.is_on_screen(self):
		return
	# Unconditional: UsernamePopup.open refuses tree-wide if any modal is up (it
	# shares ConfirmPopup.MODAL_GROUP), so there is nothing left for a per-instance
	# latch to add — and this page can exist three times over, so it never could.
	var popup := UsernamePopup.open(self)
	if popup != null:
		popup.finished.connect(func(_name: String) -> void: rebuild())


func _on_username_pressed() -> void:
	# Nothing to await and nothing to fail: the name lives in the profile and rides
	# the ordinary cloud sync, so there is no busy state and no error path here.
	var popup := UsernamePopup.open(self)
	if popup != null:
		popup.finished.connect(func(_name: String) -> void: rebuild())


func _on_sign_out_pressed() -> void:
	# No confirm: nothing is destroyed. The local career is untouched and the
	# cloud copy stays reachable by signing back in.
	Cloud.sign_out()
	_set_message("Signed out. Your progress on this device is unchanged.", "dim")
	_show(View.MAIN)


# --- Conflict -----------------------------------------------------------------

func _on_conflict_detected(summary: Dictionary) -> void:
	# is_on_screen, NOT is_visible_in_tree: the latter ignores a hidden
	# CanvasLayer ancestor, so a closed Settings page would still pop the modal.
	# When it is not on screen the conflict is not lost — rebuild() re-raises it
	# the next time the page is actually opened.
	if MenuNav.is_on_screen(self):
		_prompt_conflict(summary)


# Delegates to the SHARED prompt (scripts/cloud/conflict_prompt.gd) rather than
# building its own. This page is no longer the only place a conflict can be raised —
# hq.gd listens too, and the boot-time starter-pick gate raises it blockingly — so the
# copy, the three choices and the resolution calls must come from one place. The
# `summary` argument is kept for the existing call sites; ConflictPrompt re-reads the
# live summary itself.
#
# NO PRIVATE "already open" LATCH. This page can exist up to three times over (the
# Settings host, the HQ title overlay and the standings page each build one), so a
# per-instance bool could never answer "is a prompt up?" — ConfirmPopup.MODAL_GROUP
# answers it for the tree, and open() refuses rather than stacking.
func _prompt_conflict(_summary: Dictionary) -> void:
	if not ConflictPrompt.is_blocked():
		return
	ConflictPrompt.open(self, rebuild)


# NOTE: the three resolution handlers that used to live here are gone. They are the
# shared prompt's business now (scripts/cloud/conflict_prompt.gd) — keeping a private
# copy is what let this page's behaviour drift from every other host's.


func _on_auth_lost(reason: String) -> void:
	_set_message(reason, "red")
	rebuild()


func _on_cloud_state_changed() -> void:
	# Only repaint the summary view; a rebuild mid-form would destroy the
	# half-typed fields the player is looking at.
	if at_root() and not _busy:
		rebuild()


# --- Helpers ------------------------------------------------------------------

# Put the page into its busy state. Returns false when a request is already in
# flight, so a double-tap cannot fire two sign-ins.
#
# The busy line itself is the SHARED one (scripts/cloud/cloud_busy.gd), in its
# AMBIENT shape: this page is already on screen, its buttons go disabled while
# _busy, and a full-screen cover over a form the player is looking at would be
# worse than the line. What used to be private here is now the same mechanism
# every other cloud call site uses.
func _begin(busy_text: String) -> bool:
	if _busy:
		return false
	_busy = true
	_set_message("", "dim")
	_busy_state = CloudBusy.ambient(self, busy_text, self)
	rebuild()
	return true


# Leave the busy state and repaint with the result. Returns whether it succeeded,
# so callers can branch on it inline.
#
# NOT a coroutine, deliberately: every caller reads it as `if _finish(await ...)`,
# and the ambient state has no minimum-duration floor to hold (that is a cover's
# problem — see CloudBusy.MIN_COVER_VISIBLE_SEC), so end() returns without
# suspending here and there is nothing to await.
func _finish(result: Dictionary) -> bool:
	_busy = false
	if _busy_state != null:
		_busy_state.end()
		_busy_state = null
	var ok := bool(result.get("ok", false))
	# CloudBusy.failure_text is the ONE answer to "what does the player see when a
	# cloud call fails" — this page renders it in its own red row rather than
	# stacking a modal, but the words come from the same place as everywhere else.
	_set_message(CloudBusy.failure_text(result), "dim" if ok else "red")
	rebuild()
	return ok


func _passwords_match() -> bool:
	if _confirm_field == null:
		return true
	if _password_field.line.text == _confirm_field.line.text:
		return true
	_set_message("Those passwords don't match.", "red")
	rebuild()
	return false


func _show(view: int) -> void:
	_view = view
	_message = ""
	rebuild()


func _set_message(text: String, role: String) -> void:
	_message = text
	_message_role = role


func _status_role() -> String:
	if Cloud.sync == null:
		return "dim"
	match Cloud.sync.status:
		CloudSync.Status.SYNCED:
			return "green"
		CloudSync.Status.ERROR, CloudSync.Status.CONFLICT:
			return "red"
		_:
			return "dim"


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.px(20))
	return l


func _sub(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.px(14))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


# Built on the shared UITheme.row_button factory, with this page's one real
# extra behaviour layered on top: a button goes disabled while a cloud call is
# in flight, so a double-tap during sign-in/sync can't fire the request twice.
# Focusability comes from TextField.wire_column / MenuNav.attach, which promote
# anything they are handed.
func _action(text: String, on_press: Callable) -> Button:
	var b := UITheme.row_button(text, on_press)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = _busy
	return b

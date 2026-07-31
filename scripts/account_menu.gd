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
var _message := ""
var _message_role := "dim"

var _email_field: TextField
var _password_field: TextField
var _confirm_field: TextField
var _conflict_open := false


func _ready() -> void:
	add_theme_constant_override("separation", UITheme.GAP)
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

	UITheme.enforce(self)
	MenuNav.attach(self)
	focus_first.call_deferred()
	page_changed.emit(at_root())

	# A conflict raised while this page was closed still needs answering; show it
	# on OPEN — but only when this page is genuinely on screen. The modal is a
	# layer-101 CanvasLayer that seizes focus, so raising it from a page parked
	# inside a hidden overlay would throw a dialog over the title screen (or, in
	# a test run, over whatever the test was driving).
	if at_root() and MenuNav.is_on_screen(self) \
			and Cloud.sync != null and Cloud.sync.blocked_by_conflict and not _conflict_open:
		_prompt_conflict.call_deferred(Cloud.sync.conflict_summary())


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
	var status := Cloud.status_message()
	if status != "":
		add_child(UITheme.label(status, _status_role()))
	if Cloud.sync != null and Cloud.sync.last_sync_utc != "":
		add_child(_sub("Last synced %s UTC" % Cloud.sync.last_sync_utc))

	if Cloud.sync != null and Cloud.sync.blocked_by_conflict:
		add_child(_action("Resolve sync conflict",
			func() -> void: _prompt_conflict(Cloud.sync.conflict_summary())))

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
	if not _begin("Opening Google sign-in…"):
		return
	_finish(await Cloud.sign_in_google())


func _on_sign_in_pressed() -> void:
	var address := _email_field.text()
	var password := _password_field.line.text
	if not _begin("Signing in…"):
		return
	if _finish(await Cloud.sign_in_email(address, password)):
		_show(View.MAIN)


func _on_register_pressed() -> void:
	if not _passwords_match():
		return
	var address := _email_field.text()
	var password := _password_field.line.text
	if not _begin("Creating your account…"):
		return
	if _finish(await Cloud.register_email(address, password)):
		_show(View.MAIN)


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


func _prompt_conflict(summary: Dictionary) -> void:
	if _conflict_open or summary.is_empty():
		return
	_conflict_open = true
	var body := "This device: %s\nCloud (from %s): %s\n\nWhich one should be kept?" % [
		summary.get("local", ""), summary.get("cloud_device", "another device"),
		summary.get("cloud", ""),
	]
	var popup := ConfirmPopup.open(self, "Your progress differs", body, [
		{"label": "Keep this device", "callback": _resolve_keep_local},
		{"label": "Use cloud", "callback": _resolve_use_cloud},
		{"label": "Decide later", "callback": _resolve_later},
	], 0, 2)
	popup.finished.connect(func() -> void: _conflict_open = false)


func _resolve_keep_local() -> void:
	if not _begin("Uploading this device's progress…"):
		return
	_finish(await Cloud.resolve_keep_local())


func _resolve_use_cloud() -> void:
	# Local-only: parse, migrate, write. No await, because there is nothing to
	# wait for — the document was already downloaded when the conflict was raised.
	if not _begin("Applying cloud progress…"):
		return
	_finish(Cloud.resolve_use_cloud())


func _resolve_later() -> void:
	Cloud.resolve_later()
	rebuild()


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
func _begin(busy_text: String) -> bool:
	if _busy:
		return false
	_busy = true
	_set_message(busy_text, "dim")
	rebuild()
	return true


# Leave the busy state and repaint with the result. Returns whether it succeeded,
# so callers can branch on it inline.
func _finish(result: Dictionary) -> bool:
	_busy = false
	var ok := bool(result.get("ok", false))
	_set_message("" if ok else String(result.get("error", "Something went wrong.")),
		"dim" if ok else "red")
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
	l.add_theme_font_size_override("font_size", 20)
	return l


func _sub(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 14)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _action(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 40)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.disabled = _busy
	if on_press.is_valid():
		b.pressed.connect(on_press)
	return b

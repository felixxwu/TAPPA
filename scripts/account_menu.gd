class_name AccountMenu
extends VBoxContainer
# The optional-account UI: sign in, see sync status, resolve a conflict, sign out.
#
# A page inside Settings.
#
# Rebuilt wholesale on every state change rather than poking individual widgets:
# the page is small, it is never on screen during gameplay, and a full rebuild
# cannot leave a stale label behind.

var _busy := false
# The live shared busy state while a cloud call is in flight, else null.
# See scripts/cloud/cloud_busy.gd and _begin/_finish below.
var _busy_state: CloudBusy = null
var _message := ""
var _message_role := "dim"
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

# Returns true when it consumed the press: a request in flight holds the page.
func go_back() -> bool:
	return _busy


func focus_first() -> void:
	# Only when actually on screen: a hidden CanvasLayer does not make
	# is_visible_in_tree() false, so a rebuild here could yank focus off whatever
	# the player is looking at.
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

	# A conflict raised while this page was closed still needs answering; show it
	# on OPEN — but only when this page is genuinely on screen. The modal is a
	# layer-101 CanvasLayer that seizes focus, so raising it from a page parked
	# inside a hidden overlay would throw a dialog over the game (or, in
	# a test run, over whatever the test was driving).
	if MenuNav.is_on_screen(self) \
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

	add_child(_action("Sync now", _on_sync_now_pressed))
	add_child(_action("Sign out", _on_sign_out_pressed))


# --- Actions ------------------------------------------------------------------
# Each handler follows the same shape: _begin() puts the page in its busy state
# (or refuses, if something is already in flight), then the operation runs, then
# _finish() repaints with whatever it reported.
#
# Deliberately NOT wrapped in a generic `await operation.call()` helper: some of
# these operations are coroutines (anything that touches the network) and some
# are purely local, and awaiting a non-coroutine is both a warning and a lie
# about what the code does. Spelling each one out keeps that honest.

func _on_sync_now_pressed() -> void:
	if not _begin("Syncing…"):
		return
	_finish(await Cloud.sync_now())


func _on_sign_out_pressed() -> void:
	# No confirm: nothing is destroyed. The local career is untouched and the
	# cloud copy stays reachable by signing back in.
	Cloud.sign_out()
	_set_message("Signed out. Your progress on this device is unchanged.", "dim")
	rebuild()


# --- Conflict -----------------------------------------------------------------

func _on_conflict_detected(summary: Dictionary) -> void:
	# is_on_screen, NOT is_visible_in_tree: the latter ignores a hidden
	# CanvasLayer ancestor, so a closed Settings page would still pop the modal.
	# When it is not on screen the conflict is not lost — rebuild() re-raises it
	# the next time the page is actually opened.
	if MenuNav.is_on_screen(self):
		_prompt_conflict(summary)


# Delegates to the SHARED prompt (scripts/cloud/conflict_prompt.gd): the level raises the
# same prompt for a conflict found while this page is closed, so the copy, the choices and
# the resolution calls come from one place. ConfirmPopup.MODAL_GROUP, not a private latch,
# keeps two hosts from stacking it.
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
	if not _busy:
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
	l.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	return l


func _sub(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
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

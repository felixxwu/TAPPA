extends Node
# Docs: features/cloud-save.md — update in the same change as this file.
# Autoload "Cloud": the facade the rest of the game talks to for optional cloud
# save. Wires the four units in scripts/cloud/ together and owns their lifetime.
#
# DEPENDENCY DIRECTION. Cloud depends on Save; Save must never depend on Cloud.
# Save emits `profile_changed` and Cloud subscribes — so the save layer keeps
# working identically (and keeps its tests passing) whether or not this autoload
# is present. Everything here is inert until the player chooses to sign in.

signal state_changed()
signal conflict_detected(summary: Dictionary)
# The local profile was replaced by a downloaded one — live UI must rebuild.
signal profile_replaced()
signal signed_in(uid: String)
signal signed_out()
signal auth_lost(reason: String)

var rest: Node = null
var auth: AuthService = null
var sync: CloudSync = null
# A sign-in code that arrived without a stored address (link opened on another device); the
# Account page asks for the address and finishes with it.
var link_code := ""
# The account being deleted, while a deletion is under way; sync stays off throughout.
var _deleting_uid := ""
var _document_deleted := false
# The deletion is waiting for the player to paste the code from a fresh sign-in link.
var deletion_needs_link := false


func _ready() -> void:
	rest = RestClient.new()
	rest.name = "RestClient"
	add_child(rest)

	auth = AuthService.new()
	auth.rest = rest
	auth.signed_in.connect(_on_signed_in)
	auth.signed_out.connect(_on_signed_out)
	auth.auth_lost.connect(func(reason: String) -> void: auth_lost.emit(reason))

	sync = CloudSync.new()
	sync.name = "CloudSync"
	sync.rest = rest
	sync.auth = auth
	sync.state_changed.connect(func() -> void: state_changed.emit())
	sync.conflict_detected.connect(func(summary: Dictionary) -> void: conflict_detected.emit(summary))
	sync.profile_replaced.connect(func() -> void: profile_replaced.emit())
	add_child(sync)

	# Local saves drive cloud pushes. Debounced inside CloudSync, so connecting
	# to every save is cheap.
	if Save.has_signal("profile_changed"):
		Save.profile_changed.connect(_on_profile_changed)
	# The one flush entry point Save already uses for tab-close / app-pause also
	# flushes the cloud, so no new lifecycle plumbing is needed on any platform.
	if Save.has_signal("flushed"):
		Save.flushed.connect(_on_flushed)

	# HEADLESS (the test runner) stays signed out and never touches the network.
	#
	# Without this, a test run on a machine whose developer happens to be signed
	# in restores that real session, pulls, finds the throwaway test profile
	# disagrees with the live cloud document, and raises a conflict modal over
	# whatever the test was driving — which is exactly what happened: an
	# unrelated HQ navigation test started failing because a "Keep this device /
	# Use cloud" dialog stole its focus. Test outcomes must not depend on who is
	# logged in, and a headless run has no player to sync for.
	if Platform.is_headless():
		return

	# Restore a previous session WITHOUT blocking startup on the network: restore()
	# only reads the local credential file; the token refresh and the first pull
	# happen lazily just after boot, and failing either leaves the player in their
	# local career rather than stuck on a spinner.
	var code := _take_code_from_page_url()
	if auth.restore() and code == "":
		_kick_off_initial_pull.call_deferred()
	if code != "":
		_finish_link_from_page.call_deferred(code)


func is_signed_in() -> bool:
	return auth != null and auth.is_signed_in()


func account_label() -> String:
	if not is_signed_in():
		return "Not signed in"
	return auth.email


func status_message() -> String:
	if not is_signed_in():
		return ""
	return sync.status_message


func sign_out() -> void:
	# The local profile is deliberately LEFT ALONE: the player keeps playing the
	# career they were just playing. Wiping it here would turn "sign out" into
	# "delete my game", which is not what the words say.
	auth.sign_out()


func send_sign_in_link(address: String) -> Dictionary:
	return await auth.send_sign_in_link(address)


# Finish an email-link sign-in. `address` falls back to the one stored when the link was sent.
func sign_in_with_link(code: String, address := "") -> Dictionary:
	var before := auth.uid
	var result := await auth.sign_in_with_link(code, address)
	if result.ok:
		link_code = ""
		if before != "" and auth.uid != before:
			sync.reset_for_account()  # a link for another account replaced the session
	return await _after_sign_in(result)


# Account deletion, steps 1-2 of the order in features/cloud-save.md. Either finishes the
# deletion or sends a fresh link and leaves deletion_needs_link set for confirm_account_deletion.
func start_account_deletion() -> Dictionary:
	if not is_signed_in():
		return {"ok": false, "error": "Not signed in."}
	_deleting_uid = auth.uid
	await sync.stop()
	if auth.signed_in_recently():
		return await _finish_account_deletion()
	var sent := await auth.send_sign_in_link(auth.email, true)
	if not sent.ok:
		cancel_account_deletion()
		return sent
	deletion_needs_link = true
	state_changed.emit()
	return {"ok": true, "error": "", "needs_link": true}


func confirm_account_deletion(code: String) -> Dictionary:
	if _deleting_uid == "":
		return {"ok": false, "error": "No account deletion in progress."}
	var result := await auth.sign_in_with_link(code, auth.email)
	if not result.ok:
		return result
	if auth.uid != _deleting_uid:
		_document_deleted = false
		cancel_account_deletion()
		sync.reset_for_account()
		return {"ok": false, "error": "That code is for a different account. Nothing was deleted."}
	return await _finish_account_deletion()


func cancel_account_deletion() -> void:
	_deleting_uid = ""
	deletion_needs_link = false
	# Once the document is gone, syncing again would write it straight back.
	if not _document_deleted:
		sync.enabled = true
	state_changed.emit()


func is_deleting_account() -> bool:
	return _deleting_uid != ""


# Player-initiated "Sync now".
func sync_now() -> Dictionary:
	if not is_signed_in():
		return {"ok": false, "error": "Not signed in."}
	return await sync.pull()


# DEV "wipe all progress": publish the wiped profile so the cloud copy is cleared
# too. Without this the next pull restores everything the player just deleted —
# see CloudSync.push_wipe. A no-op when signed out: the cloud copy is left alone, and
# signing back in asks which to keep.
func publish_local_wipe() -> Dictionary:
	if not is_signed_in():
		return {"ok": true, "error": ""}
	return await sync.push_wipe()


func resolve_keep_local() -> Dictionary:
	return await sync.resolve_keep_local()


func resolve_use_cloud() -> Dictionary:
	# Not awaited: applying a downloaded profile is a local operation (parse,
	# migrate, write), so unlike resolve_keep_local it never touches the network.
	return sync.resolve_use_cloud()


func resolve_later() -> void:
	sync.resolve_later()


# --- Internals ---------------------------------------------------------------

func _after_sign_in(result: Dictionary) -> Dictionary:
	if not result.ok:
		return result
	# A freshly signed-in device almost always has local progress AND may have a
	# cloud document; pull() is what decides between them (or asks).
	await sync.pull()
	return {"ok": true, "error": ""}


# Steps 3-5: the document, then the account, then the stored credential.
func _finish_account_deletion() -> Dictionary:
	deletion_needs_link = false
	var doc := await sync.delete_document()
	if not doc.ok:
		cancel_account_deletion()
		return doc
	_document_deleted = true
	# ponytail: sync stays off only for this session; a restart before the retry succeeds re-uploads the career.
	var gone := await auth.delete_account()
	if not gone.ok:
		return gone
	_deleting_uid = ""
	auth.sign_out()
	return {"ok": true, "error": ""}


# Web only: the sign-in link lands on the game page with ?oobCode=. Read it, then strip it from
# the address bar so a reload doesn't retry a code that is already spent.
func _take_code_from_page_url() -> String:
	if not Platform.is_web():
		return ""
	var search := String(JavaScriptBridge.eval("window.location.search", true))
	if not search.contains("oobCode="):
		return ""
	JavaScriptBridge.eval("""(function () {
		var u = new URL(window.location.href);
		['oobCode', 'mode', 'apiKey', 'lang', 'continueUrl', 'tenantId'].forEach(function (k) {
			u.searchParams.delete(k);
		});
		window.history.replaceState(null, '', u.toString());
	})();""", true)
	return AuthService.code_from(search)


func _finish_link_from_page(code: String) -> void:
	if auth.pending_email == "":
		link_code = code
		state_changed.emit()
		return
	await sign_in_with_link(code)


func _kick_off_initial_pull() -> void:
	await sync.pull()


func _on_signed_in(uid: String) -> void:
	signed_in.emit(uid)
	state_changed.emit()


func _on_profile_changed() -> void:
	if sync != null:
		sync.request_push()


func _on_signed_out() -> void:
	_deleting_uid = ""
	_document_deleted = false
	deletion_needs_link = false
	sync.reset_for_account()
	signed_out.emit()
	state_changed.emit()


func _on_flushed() -> void:
	if sync != null:
		sync.flush()


# Pull again when the app comes back to the foreground: the player may have been
# on another device in the meantime. Web and desktop don't get this signal; there the
# read before each upload (CloudSync._upload_pending) catches a newer cloud save.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED and is_signed_in():
		_kick_off_initial_pull.call_deferred()

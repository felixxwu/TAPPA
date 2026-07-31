extends Node
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
var google: GoogleSignIn = null


func _ready() -> void:
	rest = RestClient.new()
	rest.name = "RestClient"
	add_child(rest)

	auth = AuthService.new()
	auth.rest = rest
	auth.signed_in.connect(_on_signed_in)
	auth.signed_out.connect(func() -> void: signed_out.emit(); state_changed.emit())
	auth.auth_lost.connect(func(reason: String) -> void: auth_lost.emit(reason))

	sync = CloudSync.new()
	sync.name = "CloudSync"
	sync.rest = rest
	sync.auth = auth
	sync.state_changed.connect(func() -> void: state_changed.emit())
	sync.conflict_detected.connect(func(summary: Dictionary) -> void: conflict_detected.emit(summary))
	sync.profile_replaced.connect(func() -> void: profile_replaced.emit())
	add_child(sync)

	google = GoogleSignIn.new()
	google.name = "GoogleSignIn"
	google.rest = rest
	add_child(google)

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
	if auth.restore():
		_kick_off_initial_pull.call_deferred()


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


# --- Sign-in entry points ----------------------------------------------------
# Each returns {ok, error} and, on success, immediately reconciles with the
# cloud so the player sees their other device's progress right away.

func sign_in_email(address: String, password: String) -> Dictionary:
	return await _after_sign_in(await auth.sign_in_email(address, password))


func register_email(address: String, password: String) -> Dictionary:
	return await _after_sign_in(await auth.register_email(address, password))


func sign_in_google() -> Dictionary:
	var token := await google.sign_in()
	if not token.ok:
		return {"ok": false, "error": token.error}
	return await _after_sign_in(await auth.sign_in_with_google(token.id_token))


func send_password_reset(address: String) -> Dictionary:
	return await auth.send_password_reset(address)


func sign_out() -> void:
	# The local profile is deliberately LEFT ALONE: the player keeps playing the
	# career they were just playing. Wiping it here would turn "sign out" into
	# "delete my game", which is not what the words say.
	auth.sign_out()


# Player-initiated "Sync now".
func sync_now() -> Dictionary:
	if not is_signed_in():
		return {"ok": false, "error": "Not signed in."}
	return await sync.pull()


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


func _kick_off_initial_pull() -> void:
	await sync.pull()


func _on_signed_in(uid: String) -> void:
	signed_in.emit(uid)
	state_changed.emit()


func _on_profile_changed() -> void:
	if sync != null:
		sync.request_push()


func _on_flushed() -> void:
	if sync != null:
		sync.flush()


# Pull again when the app comes back to the foreground: the player may have been
# on another device in the meantime. The web build gets the same signal through
# Save's existing visibilitychange listener (see _ready).
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED and is_signed_in():
		_kick_off_initial_pull.call_deferred()

extends Node
# Docs: features/cloud-save.md — update in the same change as this file.
# Tests: tests/headless/test_cloud_boot_gate.gd — extend in the same change.
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
# The boot-time pull has finished — succeeded, failed, or been given up on.
# Emitted exactly once per pending pull, so a caller can wait for the player's
# real career to land before offering them a decision that assumes it has not.
signal initial_sync_settled()

# How long anything is allowed to wait on the boot pull. Deliberately shorter
# than RestClient.TIMEOUT_SEC: this budget is "how long a player will stare at a
# spinner", not "how long a request may take". Exceeding it does not cancel the
# pull — it just stops waiting for it.
const INITIAL_SYNC_WAIT_SEC := 8.0

var rest: Node = null
var auth: AuthService = null
var sync: CloudSync = null
var google: GoogleSignIn = null
# Global per-stage boards. Entirely passive — it makes no request until the UI
# asks, so a player who never finishes a stage never touches it.
var leaderboard: Leaderboard = null
# The Rally Challenge world board (challenge_runs/{period_key}/entries). Same
# passive posture as leaderboard above.
var challenge_leaderboard: ChallengeLeaderboard = null

# True from boot until the FIRST automatic pull settles. Only ever set when a
# stored credential was found, so a player who has never signed in — or who
# signed out — sees this false for the whole session and is never made to wait
# for anything. See await_initial_sync.
var initial_pull_pending := false


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

	leaderboard = Leaderboard.new()
	leaderboard.name = "Leaderboard"
	leaderboard.rest = rest
	leaderboard.auth = auth
	add_child(leaderboard)

	challenge_leaderboard = ChallengeLeaderboard.new()
	challenge_leaderboard.name = "ChallengeLeaderboard"
	challenge_leaderboard.rest = rest
	challenge_leaderboard.auth = auth
	add_child(challenge_leaderboard)

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
		# Set BEFORE the deferred call, not inside it: HQ can reach its first
		# frame between here and the pull actually starting, and a gate that is
		# not armed yet is no gate at all.
		initial_pull_pending = true
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
	# Nothing is coming any more, so nobody should still be waiting for it.
	_settle_initial_sync()


# Wait for the boot-time pull to settle, so a caller can avoid acting on a
# profile that is about to be replaced. Returns true if it settled, false if the
# wait ran out.
#
# THIS ALWAYS RETURNS. Signing in is never required and every failure degrades to
# "you keep playing locally", so this must not be able to strand anyone:
#   * no stored credential (never signed in, or signed out) -> returns instantly;
#   * pull finished already -> returns instantly;
#   * offline / 5xx / hung socket -> the pull's own failure path settles it, and
#     `timeout_sec` is a hard backstop underneath that.
# The pull is NOT cancelled on timeout — it lands whenever it lands, and
# profile_replaced still fires. This only bounds the waiting.
func await_initial_sync(timeout_sec := INITIAL_SYNC_WAIT_SEC) -> bool:
	if not initial_pull_pending:
		return true
	var tree := get_tree()
	if tree == null:
		return false
	# POLL THE FLAG, do not close over a local. A `var settled := false` mutated
	# by a signal-connected lambda cannot work: GDScript lambdas capture outer
	# locals BY VALUE, so the callback would flip its own private copy and this
	# loop would only ever exit on the deadline — every signed-in player sitting
	# through the full timeout after a pull that finished in 200 ms. The flag
	# `_settle_initial_sync` clears is the shared state; read that directly and
	# there is no closure to get wrong.
	var deadline := Time.get_ticks_msec() + int(maxf(timeout_sec, 0.0) * 1000.0)
	while initial_pull_pending and Time.get_ticks_msec() < deadline:
		await tree.process_frame
	return not initial_pull_pending


# Player-initiated "Sync now".
func sync_now() -> Dictionary:
	if not is_signed_in():
		return {"ok": false, "error": "Not signed in."}
	return await sync.pull()


# DEV "wipe all progress": publish the wiped profile so the cloud copy is cleared
# too. Without this the next pull restores everything the player just deleted —
# see CloudSync.push_wipe. A no-op when signed out, where there is no cloud copy
# to clear and the local wipe is already the whole story.
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


func _kick_off_initial_pull() -> void:
	await sync.pull()
	_settle_initial_sync()


# Release anyone waiting on the boot pull. Idempotent, because the resumed-from-
# background path reuses _kick_off_initial_pull and must not re-arm the gate.
func _settle_initial_sync() -> void:
	if not initial_pull_pending:
		return
	initial_pull_pending = false
	initial_sync_settled.emit()


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

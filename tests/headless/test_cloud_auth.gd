extends GutTest
# AuthService — the Firebase Authentication state machine (see
# features/cloud-save.md). Everything here runs against FakeRestClient, so these
# are assertions about OUR logic (what we send, what we store, how we classify a
# failure), never about Google's servers.

const TEST_AUTH_PATH := "user://test_cloud_auth.json"

var _auth: AuthService
var _rest: FakeRestClient


func before_each() -> void:
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)
	_auth = AuthService.new()
	_auth.rest = _rest
	_auth.auth_path = TEST_AUTH_PATH
	_remove_auth_file()


func after_each() -> void:
	_remove_auth_file()


func _remove_auth_file() -> void:
	for suffix in ["", ".tmp"]:
		if FileAccess.file_exists(TEST_AUTH_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_AUTH_PATH + suffix))


func _session(local_id := "uid123", mail := "player@example.com") -> Dictionary:
	return {
		"localId": local_id, "idToken": "id-token", "refreshToken": "refresh-token",
		"email": mail, "expiresIn": "3600",
	}


# Every sign-in goes through _identity_call, so that is what these drive.
func _sign_in() -> Dictionary:
	return await _auth._identity_call("signInWithEmailLink", {"returnSecureToken": true})


# --- Sign-in --------------------------------------------------------------------

func test_a_sign_in_stores_the_session() -> void:
	_rest.queue_ok(_session())
	var result: Dictionary = await _sign_in()
	assert_true(result.ok, "a 200 with a session should sign the player in")
	assert_eq(_auth.uid, "uid123")
	assert_eq(_auth.email, "player@example.com")
	assert_eq(_auth.refresh_token, "refresh-token")
	assert_true(_auth.is_signed_in())


# --- Error mapping ------------------------------------------------------------

func test_a_known_error_code_becomes_a_player_facing_message() -> void:
	_rest.queue_error(400, "USER_DISABLED")
	var result: Dictionary = await _sign_in()
	assert_false(result.ok)
	assert_ne(String(result.error), "")
	assert_false(String(result.error).contains("USER_DISABLED"),
		"a mapped code should not leak the raw string at the player")


func test_an_unknown_error_code_still_yields_a_message_and_keeps_the_code() -> void:
	# The point of this one: an unmapped failure must stay diagnosable from a
	# screenshot rather than collapsing into a generic "error".
	_rest.queue_error(400, "SOME_FUTURE_FIREBASE_CODE")
	var result: Dictionary = await _sign_in()
	assert_false(result.ok)
	assert_string_contains(String(result.error), "SOME_FUTURE_FIREBASE_CODE")


func test_a_code_with_trailing_detail_still_maps() -> void:
	# Firebase suffixes some codes ("TOO_MANY_ATTEMPTS_TRY_LATER : Access ...").
	_rest.queue_error(400, "TOO_MANY_ATTEMPTS_TRY_LATER : Access to this account has been disabled")
	var result: Dictionary = await _sign_in()
	assert_false(String(result.error).contains("TOO_MANY_ATTEMPTS_TRY_LATER"),
		"the detail must not stop the code mapping")


func test_a_network_failure_is_reported_as_a_network_failure() -> void:
	_rest.queue_offline()
	var result: Dictionary = await _sign_in()
	assert_false(result.ok)
	assert_true(result.get("network", false),
		"callers branch on this to retry instead of signing the player out")


# --- Token lifecycle ----------------------------------------------------------

func test_a_valid_token_is_not_refreshed() -> void:
	_rest.queue_ok(_session())
	await _sign_in()
	var before: int = _rest.requests.size()
	var result: Dictionary = await _auth.ensure_fresh_token()
	assert_true(result.ok)
	assert_eq(_rest.requests.size(), before, "a token far from expiry needs no round trip")


func test_an_expiring_token_is_refreshed() -> void:
	_rest.queue_ok(_session())
	await _sign_in()
	_auth.expires_at = Time.get_unix_time_from_system() + 1.0  # inside the margin
	_rest.queue_ok({"id_token": "fresh", "refresh_token": "r2", "user_id": "uid123",
		"expires_in": "3600"})
	var result: Dictionary = await _auth.ensure_fresh_token()
	assert_true(result.ok)
	assert_eq(_auth.id_token, "fresh")
	assert_eq(_auth.refresh_token, "r2")


func test_a_network_failure_during_refresh_does_not_sign_out() -> void:
	# Being offline must never cost the player their account — this is the whole
	# reason refresh distinguishes transport failures from rejections.
	_rest.queue_ok(_session())
	await _sign_in()
	_auth.expires_at = 0.0
	_rest.queue_offline()
	var result: Dictionary = await _auth.ensure_fresh_token()
	assert_false(result.ok)
	assert_true(_auth.is_signed_in(), "still signed in after a failed refresh attempt")


func test_a_rejected_refresh_signs_out_and_reports_it() -> void:
	_rest.queue_ok(_session())
	await _sign_in()
	_auth.expires_at = 0.0
	watch_signals(_auth)
	_rest.queue_error(400, "TOKEN_EXPIRED")
	var result: Dictionary = await _auth.ensure_fresh_token()
	assert_false(result.ok)
	assert_false(_auth.is_signed_in(), "a dead refresh token cannot be revived")
	assert_signal_emitted(_auth, "auth_lost")


func test_a_server_outage_during_refresh_does_not_sign_out() -> void:
	_rest.queue_ok(_session())
	await _sign_in()
	for status in [429, 503]:
		_auth.expires_at = 0.0
		_rest.queue_error(status)
		var result: Dictionary = await _auth.ensure_fresh_token()
		assert_false(result.ok)
		assert_true(_auth.is_signed_in(), "a %d is the server's trouble, not a dead token" % status)


# --- Credential persistence ---------------------------------------------------

func test_the_session_survives_a_restart() -> void:
	_rest.queue_ok(_session())
	await _sign_in()

	var restored := AuthService.new()
	restored.rest = _rest
	restored.auth_path = TEST_AUTH_PATH
	assert_true(restored.restore(), "a stored refresh token should restore the session")
	assert_eq(restored.uid, "uid123")
	assert_eq(restored.email, "player@example.com")
	assert_eq(restored.id_token, "",
		"the short-lived token is never persisted — it is refreshed on first use")


func test_signing_out_clears_the_stored_credential() -> void:
	_rest.queue_ok(_session())
	await _sign_in()
	_auth.sign_out()
	assert_false(_auth.is_signed_in())
	var restored := AuthService.new()
	restored.rest = _rest
	restored.auth_path = TEST_AUTH_PATH
	assert_false(restored.restore(), "a signed-out device must not restore the session")


func test_credentials_are_not_stored_in_the_uploaded_profile() -> void:
	# The one mistake in this design that would be a security incident: profile
	# ["settings"] is inside the blob uploaded to Firestore, so a token parked
	# there would be published to the database.
	_rest.queue_ok(_session())
	await _sign_in()
	var blob := JSON.stringify(Save.profile)
	assert_false(blob.contains("refresh-token"),
		"the refresh token must live in auth.json, never in the synced profile")


# --- RestClient pause immunity ------------------------------------------------

# A cloud call started while the tree is PAUSED must still complete. HTTPRequest
# drives its transfer from an internal process callback, so a pausable RestClient
# silently stalls mid-request and the awaiting caller hangs forever — which is how
# "Wipe all progress" from the pause menu (the Overworld HQ, or a mid-rally pause)
# left CloudBusy's full-screen cover up for good. Asserted via can_process(), the
# engine's own answer to "would this node tick right now".
func test_rest_client_keeps_running_while_the_tree_is_paused() -> void:
	var rest := RestClient.new()
	add_child_autofree(rest)
	await get_tree().process_frame  # let _ready build the HTTPRequest child
	var was_paused := get_tree().paused
	get_tree().paused = true
	var http := rest.get_child(0) as HTTPRequest
	var rest_ticks := rest.can_process()
	var http_ticks := http != null and http.can_process()
	get_tree().paused = was_paused
	assert_true(rest_ticks, "RestClient must keep processing while the tree is paused")
	assert_true(http_ticks, "its HTTPRequest must keep processing while the tree is paused")

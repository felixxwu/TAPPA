extends GutTest
# Account deletion through the Cloud facade (features/cloud-save.md › "Deleting the account"):
# the five steps in order, and that nothing can write the cloud document back while they run.
# A private Cloud instance over FakeRestClient, so the live autoload and the network stay out of it.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_account_deletion_profile.json"
const AUTH_PATH := "user://test_account_deletion_auth.json"

var _save: Node
var _rest: FakeRestClient
var _cloud: Node


func before_each() -> void:
	CarFixtures.install()
	_save = SaveTestHelpers.redirect(TEST_PATH)
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)
	_cloud = load("res://scripts/cloud/cloud_manager.gd").new()
	add_child_autofree(_cloud)
	_cloud.auth.rest = _rest
	_cloud.auth.auth_path = AUTH_PATH
	_cloud.sync.rest = _rest
	var auth: AuthService = _cloud.auth
	auth.uid = "uid123"
	auth.email = "player@example.com"
	auth.refresh_token = "refresh"
	auth.id_token = "id"
	auth.expires_at = Time.get_unix_time_from_system() + 3600.0
	_save.profile["cloud_uid"] = "uid123"


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	CarFixtures.restore()
	for suffix in ["", ".tmp"]:
		if FileAccess.file_exists(AUTH_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(AUTH_PATH + suffix))


func _calls() -> Array:
	var out: Array = []
	for r in _rest.requests:
		var url := String(r.url)
		if int(r.method) == HTTPClient.METHOD_PATCH:
			out.append("write_doc")
		elif int(r.method) == HTTPClient.METHOD_DELETE:
			out.append("delete_doc")
		elif int(r.method) == HTTPClient.METHOD_GET:
			out.append("read_doc")
		else:
			out.append(url.get_slice("accounts:", 1).get_slice("?", 0))
	return out


func test_a_recent_sign_in_deletes_the_document_then_the_account_then_the_credential() -> void:
	_cloud.auth.signed_in_at = Time.get_unix_time_from_system()
	_cloud.auth._write_credentials()
	var result: Dictionary = await _cloud.start_account_deletion()
	assert_true(result.ok)
	assert_eq(_calls(), ["delete_doc", "delete"])
	assert_false(_cloud.is_signed_in(), "the session is gone")
	assert_false(FileAccess.file_exists(AUTH_PATH), "and so is auth.json")


func test_an_old_sign_in_is_confirmed_by_a_fresh_link_before_anything_is_deleted() -> void:
	var result: Dictionary = await _cloud.start_account_deletion()
	assert_true(result.ok)
	assert_true(result.get("needs_link", false))
	assert_true(_cloud.deletion_needs_link)
	assert_eq(_calls(), ["sendOobCode"], "nothing is deleted before the player signs in again")
	assert_eq(_rest.last_body().get("email"), "player@example.com")
	assert_eq(_rest.last_body().get("continueUrl"), FirebaseConfig.sign_in_continue_url(true),
		"the code must come back to this game to be pasted, on every platform")

	_rest.queue_ok({"localId": "uid123", "idToken": "id2", "refreshToken": "r2",
		"email": "player@example.com", "expiresIn": "3600"})
	result = await _cloud.confirm_account_deletion("the-code")
	assert_true(result.ok)
	assert_eq(_calls(), ["sendOobCode", "signInWithEmailLink", "delete_doc", "delete"],
		"signing in again during the deletion reads and writes nothing")
	assert_false(_cloud.is_signed_in())


func test_sync_cannot_recreate_the_document_mid_delete() -> void:
	await _cloud.start_account_deletion()
	_save.save()  # a profile change, as driving would make
	_cloud.sync.request_push()
	_cloud.sync.flush()
	await _cloud._kick_off_initial_pull()
	assert_eq(_calls(), ["sendOobCode"], "sync stays off while the deletion waits")

	_rest.queue_ok({"localId": "uid123", "idToken": "id2", "refreshToken": "r2",
		"email": "player@example.com", "expiresIn": "3600"})
	await _cloud.confirm_account_deletion("the-code")
	assert_false(_calls().has("write_doc"))


func test_a_sync_under_way_finishes_without_writing_before_the_document_is_deleted() -> void:
	_cloud.auth.signed_in_at = Time.get_unix_time_from_system()
	_rest.queue_error(404)
	_save.save()
	_cloud.sync.request_push()
	_cloud.sync.flush()
	await _cloud.start_account_deletion()
	assert_eq(_calls(), ["read_doc", "delete_doc", "delete"])


func test_a_failed_document_delete_turns_sync_back_on() -> void:
	_cloud.auth.signed_in_at = Time.get_unix_time_from_system()
	_rest.queue_error(403)
	var result: Dictionary = await _cloud.start_account_deletion()
	assert_false(result.ok)
	assert_true(_cloud.is_signed_in(), "nothing was deleted")
	assert_true(_cloud.sync.enabled, "so the career keeps syncing")


func test_a_failed_account_delete_keeps_sync_off() -> void:
	_cloud.auth.signed_in_at = Time.get_unix_time_from_system()
	_rest.queue_ok({}).queue_error(400, "CREDENTIAL_TOO_OLD_LOGIN_AGAIN")
	var result: Dictionary = await _cloud.start_account_deletion()
	assert_false(result.ok)
	assert_false(_cloud.sync.enabled, "the document is gone, so a push would bring it back")
	_cloud.cancel_account_deletion()
	assert_false(_cloud.sync.enabled, "even once the player gives up")


func test_a_code_for_another_account_deletes_nothing() -> void:
	await _cloud.start_account_deletion()
	_rest.queue_ok({"localId": "someone_else", "idToken": "id2", "refreshToken": "r2",
		"email": "other@example.com", "expiresIn": "3600"})
	var result: Dictionary = await _cloud.confirm_account_deletion("the-code")
	assert_false(result.ok)
	assert_false(_calls().has("delete_doc"))
	assert_false(_calls().has("delete"))
	assert_false(_cloud.is_deleting_account())


func test_cancelling_before_the_link_is_used_turns_sync_back_on() -> void:
	await _cloud.start_account_deletion()
	_cloud.cancel_account_deletion()
	assert_false(_cloud.deletion_needs_link)
	assert_true(_cloud.sync.enabled)

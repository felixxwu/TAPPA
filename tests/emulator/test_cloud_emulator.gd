extends GutTest
# Sign-in, sync and account deletion against the Firebase Auth and Firestore emulators: the real
# REST API and the real firestore.rules, where tests/headless/ only has FakeRestClient.
# Run with `firebase emulators:exec --only auth,firestore "./run_tests.sh --emulator"`.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_cloud_emulator_profile.json"
const AUTH_PATH := "user://test_cloud_emulator_auth.json"
const OTHER_AUTH_PATH := "user://test_cloud_emulator_other_auth.json"

var _save: Node
var _cloud: Node
var _rest: RestClient


func should_skip_script():
	if OS.get_environment(FirebaseConfig.AUTH_EMULATOR_ENV) == "" \
			or OS.get_environment(FirebaseConfig.FIRESTORE_EMULATOR_ENV) == "":
		return "No Firebase emulators: run under `firebase emulators:exec` (features/testing.md)"
	return false


func before_each() -> void:
	CarFixtures.install()
	_save = SaveTestHelpers.redirect(TEST_PATH)
	_cloud = load("res://scripts/cloud/cloud_manager.gd").new()
	add_child_autofree(_cloud)
	_cloud.auth.auth_path = AUTH_PATH
	_rest = _cloud.rest
	await _rest.request_json(HTTPClient.METHOD_DELETE,
		_emulator(FirebaseConfig.AUTH_EMULATOR_ENV, "accounts"), PackedStringArray())
	await _rest.request_json(HTTPClient.METHOD_DELETE,
		_emulator(FirebaseConfig.FIRESTORE_EMULATOR_ENV, "databases/(default)/documents"),
		PackedStringArray())


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	CarFixtures.restore()
	for path in [AUTH_PATH, OTHER_AUTH_PATH]:
		for suffix in ["", ".tmp"]:
			if FileAccess.file_exists(path + suffix):
				DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))


func _emulator(env: String, path: String) -> String:
	return "http://%s/emulator/v1/projects/%s/%s" % [
		OS.get_environment(env), FirebaseConfig.PROJECT_ID, path]


# The Auth emulator sends no mail; it lists every link it would have sent.
func _latest_code(address: String) -> String:
	var response: Dictionary = await _rest.request_json(HTTPClient.METHOD_GET,
		_emulator(FirebaseConfig.AUTH_EMULATOR_ENV, "oobCodes"), PackedStringArray())
	var code := ""
	for entry in response.json.get("oobCodes", []):
		if entry.get("email") == address and entry.get("requestType") == "EMAIL_SIGNIN":
			code = String(entry.oobCode)
	return code


func _sign_in(auth: AuthService, address: String) -> Dictionary:
	var sent: Dictionary = await auth.send_sign_in_link(address)
	if not sent.ok:
		return sent
	return await auth.sign_in_with_link(await _latest_code(address))


func _sign_in_cloud(address: String) -> Dictionary:
	var sent: Dictionary = await _cloud.send_sign_in_link(address)
	if not sent.ok:
		return sent
	return await _cloud.sign_in_with_link(await _latest_code(address))


# "Bearer owner" is the Firestore emulator's admin token: it skips the rules.
func _admin_read(uid: String) -> Dictionary:
	return await _rest.request_json(HTTPClient.METHOD_GET, FirebaseConfig.user_doc(uid),
		RestClient.json_headers("owner"))


func _write_as(token: String, uid: String, revision: int) -> Dictionary:
	var doc := CloudSync.to_document(JSON.stringify(Save.profile), Save.SCHEMA_VERSION, revision,
		Time.get_datetime_string_from_system(true), "android")
	return await _rest.request_json(HTTPClient.METHOD_PATCH,
		FirebaseConfig.user_doc(uid) + FirestoreCodec.update_mask(CloudSync.DOC_FIELDS),
		RestClient.json_headers(token), JSON.stringify(doc))


func test_an_emailed_code_signs_in_and_uploads_the_career() -> void:
	var result := await _sign_in_cloud("player@example.com")
	assert_true(result.ok, String(result.error))
	assert_true(_cloud.is_signed_in())
	assert_eq(_cloud.auth.email, "player@example.com")
	var doc: Dictionary = await _admin_read(_cloud.auth.uid)
	assert_eq(int(doc.status), 200, "the first pull found no cloud save and pushed one")
	assert_eq(CloudSync.from_document(doc.json).get("revision"), 1)


func test_a_spent_code_is_refused() -> void:
	await _cloud.send_sign_in_link("player@example.com")
	var code := await _latest_code("player@example.com")
	assert_true((await _cloud.auth.sign_in_with_link(code)).ok)
	var again: Dictionary = await _cloud.auth.sign_in_with_link(code, "player@example.com")
	assert_false(again.ok)


func test_sync_pushes_local_changes_and_takes_a_newer_cloud_save() -> void:
	assert_true((await _sign_in_cloud("player@example.com")).ok)
	_save.save()
	_cloud.auth.expires_at = 0.0  # the next call refreshes through the real token endpoint
	var pulled: Dictionary = await _cloud.sync_now()
	assert_eq(pulled.get("state"), "pushed", String(pulled.get("error")))
	var doc: Dictionary = await _admin_read(_cloud.auth.uid)
	assert_eq(CloudSync.from_document(doc.json).get("revision"), 2)

	var written: Dictionary = await _write_as(_cloud.auth.id_token, _cloud.auth.uid, 5)
	assert_true(written.ok, "another device on the same account moves the cloud on")
	pulled = await _cloud.sync_now()
	assert_eq(pulled.get("state"), "applied")
	assert_eq(int(Save.profile.get("cloud_revision")), 5)


func test_the_rules_keep_each_player_to_their_own_document() -> void:
	var other := AuthService.new()
	other.rest = _rest
	other.auth_path = OTHER_AUTH_PATH
	assert_true((await _sign_in(other, "other@example.com")).ok)
	assert_true((await _write_as(other.id_token, other.uid, 1)).ok)
	assert_true((await _sign_in_cloud("player@example.com")).ok)
	var token: String = _cloud.auth.id_token

	var read: Dictionary = await _rest.request_json(HTTPClient.METHOD_GET,
		FirebaseConfig.user_doc(other.uid), RestClient.json_headers(token))
	assert_eq(int(read.status), 403, "reading someone else's save")
	assert_eq(int((await _write_as(token, other.uid, 9)).status), 403, "overwriting it")
	var deleted: Dictionary = await _rest.request_json(HTTPClient.METHOD_DELETE,
		FirebaseConfig.user_doc(other.uid), RestClient.json_headers(token))
	assert_eq(int(deleted.status), 403, "deleting it")
	var anonymous: Dictionary = await _rest.request_json(HTTPClient.METHOD_GET,
		FirebaseConfig.user_doc(other.uid), RestClient.json_headers())
	assert_eq(int(anonymous.status), 403, "reading it signed out")
	var doc: Dictionary = await _admin_read(other.uid)
	assert_eq(CloudSync.from_document(doc.json).get("revision"), 1, "and it is untouched")


func _assert_account_gone(uid: String, old_token: String) -> void:
	assert_false(_cloud.is_signed_in())
	assert_eq(int((await _admin_read(uid)).status), 404, "the cloud save is gone")
	var lookup: Dictionary = await _rest.request_json(HTTPClient.METHOD_POST,
		FirebaseConfig.identity("lookup"), RestClient.json_headers(),
		JSON.stringify({"idToken": old_token}))
	assert_false(lookup.ok, "and so is the account")


func test_deleting_after_a_recent_sign_in_removes_the_save_and_the_account() -> void:
	assert_true((await _sign_in_cloud("player@example.com")).ok)
	var uid: String = _cloud.auth.uid
	var token: String = _cloud.auth.id_token
	var result: Dictionary = await _cloud.start_account_deletion()
	assert_true(result.ok, String(result.error))
	assert_false(result.get("needs_link", false))
	await _assert_account_gone(uid, token)


func test_deleting_after_an_old_sign_in_waits_for_a_fresh_code() -> void:
	assert_true((await _sign_in_cloud("player@example.com")).ok)
	var uid: String = _cloud.auth.uid
	var token: String = _cloud.auth.id_token
	_cloud.auth.signed_in_at = 0.0
	var started: Dictionary = await _cloud.start_account_deletion()
	assert_true(started.get("needs_link", false), String(started.error))
	assert_eq(int((await _admin_read(uid)).status), 200, "nothing is deleted before the code")

	var result: Dictionary = await _cloud.confirm_account_deletion(
		await _latest_code("player@example.com"))
	assert_true(result.ok, String(result.error))
	await _assert_account_gone(uid, token)

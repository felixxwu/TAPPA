extends GutTest
# CloudSync — Firestore document encoding and the local-vs-cloud reconciliation
# rules (see features/cloud-save.md › "Conflict model"). Runs against
# FakeRestClient and a throwaway profile, so nothing here touches the network or
# the player's real save.
#
# The conflict matrix is the part worth being strict about: every row of it is a
# decision about whose progress survives.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_cloud_sync_profile.json"

var _save: Node
var _rest: FakeRestClient
var _auth: AuthService
var _sync: CloudSync


func before_each() -> void:
	CarFixtures.install()
	_save = SaveTestHelpers.redirect(TEST_PATH)
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)

	_auth = AuthService.new()
	_auth.rest = _rest
	_auth.auth_path = "user://test_cloud_sync_auth.json"
	# Seat a live session directly: obtaining one is AuthService's job and is
	# covered in test_cloud_auth.
	_auth.uid = "uid123"
	_auth.refresh_token = "refresh"
	_auth.id_token = "id"
	_auth.expires_at = Time.get_unix_time_from_system() + 3600.0

	_sync = CloudSync.new()
	_sync.rest = _rest
	_sync.auth = _auth
	add_child_autofree(_sync)

	# Default posture: this device is already paired with the signed-in account,
	# so a stored cloud_revision means what it says. The account-switching tests
	# below override cloud_uid to exercise the other case.
	_save.profile["cloud_uid"] = _auth.uid


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	CarFixtures.restore()
	for suffix in ["", ".tmp"]:
		var path: String = "user://test_cloud_sync_auth.json" + suffix
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# Build a Firestore document response for a remote profile.
func _remote_doc(revision: int, profile: Dictionary, schema := -1) -> Dictionary:
	var version := schema if schema >= 0 else Save.SCHEMA_VERSION
	return CloudSync.to_document(JSON.stringify(profile), version, revision,
		"2026-07-30T10:00:00", "android")


func _remote_profile(cars: int = 1) -> Dictionary:
	var p: Dictionary = _save._default_profile()
	p["starter_picked"] = true
	p["cars"] = []
	for i in cars:
		# Synthetic fixture cars, never real catalogue entries: this test is about
		# sync, and the shipped roster must stay free to change without breaking it.
		p["cars"].append({"instance_id": i + 1, "model_id": "fx_light_rwd", "hp": 100,
			"installed_upgrades": [], "disabled_upgrades": [], "tuning": {}})
	return p


# --- Document encoding --------------------------------------------------------

func test_document_round_trips() -> void:
	var doc := CloudSync.to_document("{\"a\":1}", 2, 7, "2026-07-30T10:00:00", "web")
	var back := CloudSync.from_document(doc)
	assert_eq(back["profile"], "{\"a\":1}")
	assert_eq(back["schema_version"], 2)
	assert_eq(back["revision"], 7)
	assert_eq(back["device"], "web")


func test_integers_survive_firestore_string_encoding() -> void:
	# Firestore encodes integerValue as a JSON STRING; decoding it as a number
	# would silently yield 0 and make every revision comparison wrong.
	var doc := CloudSync.to_document("{}", 2, 41, "", "web")
	assert_eq(String(doc["fields"]["revision"]["integerValue"]), "41",
		"revision must be sent as a string, as the Firestore REST API requires")
	assert_eq(CloudSync.from_document(doc)["revision"], 41)


func test_a_document_without_a_profile_field_is_unreadable() -> void:
	assert_true(CloudSync.from_document({"fields": {"revision": {"integerValue": "3"}}}).is_empty())
	assert_true(CloudSync.from_document({}).is_empty())
	assert_true(CloudSync.from_document("nonsense").is_empty())


func test_profile_description_counts_cars_and_completed_rallies() -> void:
	var described := CloudSync.describe_profile({
		"cars": [{}, {}, {}],
		"rallies": {"a": {"completed": true}, "b": {"completed": false}, "c": {"completed": true}},
	})
	assert_string_contains(described, "3 cars")
	assert_string_contains(described, "2 rallies")


# --- The conflict matrix ------------------------------------------------------

func test_no_cloud_document_uploads_the_local_profile() -> void:
	_rest.queue_error(404)
	_rest.queue_ok({})
	var result: Dictionary = await _sync.pull()
	assert_eq(result.state, "no_cloud")
	assert_eq(int(_save.profile["cloud_revision"]), 1, "the first push claims revision 1")
	assert_false(_save.has_unsynced())


func test_matching_revisions_with_a_clean_profile_do_nothing() -> void:
	_save.profile["cloud_revision"] = 4
	_save.mark_synced()
	_rest.queue_ok(_remote_doc(4, _remote_profile()))
	var result: Dictionary = await _sync.pull()
	assert_eq(result.state, "up_to_date")
	assert_eq(_rest.requests.size(), 1, "nothing to send")


func test_local_changes_at_the_agreed_revision_are_pushed() -> void:
	_save.profile["cloud_revision"] = 4
	_save.mark_synced()
	_save.save()  # local progress
	assert_true(_save.has_unsynced())
	_rest.queue_ok(_remote_doc(4, _remote_profile()))
	_rest.queue_ok({})
	var result: Dictionary = await _sync.pull()
	assert_eq(result.state, "pushed")
	assert_eq(int(_save.profile["cloud_revision"]), 5)
	assert_false(_save.has_unsynced())


func test_a_newer_cloud_over_a_clean_profile_is_downloaded() -> void:
	_save.profile["cloud_revision"] = 1
	_save.profile["starter_model_id"] = "local_only"
	_save.mark_synced()
	var remote := _remote_profile()
	remote["starter_model_id"] = "from_cloud"
	_rest.queue_ok(_remote_doc(9, remote))
	var result: Dictionary = await _sync.pull()
	assert_eq(result.state, "applied")
	assert_eq(_save.profile["starter_model_id"], "from_cloud")
	assert_eq(int(_save.profile["cloud_revision"]), 9)


func test_both_sides_moving_on_raises_a_conflict_instead_of_guessing() -> void:
	_save.profile["cloud_revision"] = 1
	_save.profile["starter_model_id"] = "local_only"
	_save.save()  # local moved on too
	watch_signals(_sync)
	_rest.queue_ok(_remote_doc(9, _remote_profile()))
	var result: Dictionary = await _sync.pull()
	assert_eq(result.state, "conflict")
	assert_signal_emitted(_sync, "conflict_detected")
	assert_true(_sync.blocked_by_conflict)
	assert_eq(_save.profile["starter_model_id"], "local_only",
		"an unresolved conflict must not touch the local profile")


func test_a_conflict_blocks_further_pushes_until_it_is_resolved() -> void:
	_save.profile["cloud_revision"] = 1
	_save.save()
	_rest.queue_ok(_remote_doc(9, _remote_profile()))
	await _sync.pull()
	var before: int = _rest.requests.size()
	_sync.pending = true
	var pushed: Dictionary = await _sync.push()
	assert_false(pushed.ok)
	assert_eq(_rest.requests.size(), before, "nothing may be uploaded while a conflict stands")


func test_a_newer_schema_is_refused_rather_than_downgraded() -> void:
	# An older build must never write over a save it cannot even read.
	_save.profile["cloud_revision"] = 1
	_rest.queue_ok(_remote_doc(9, _remote_profile(), Save.SCHEMA_VERSION + 1))
	var result: Dictionary = await _sync.pull()
	assert_eq(result.state, "newer_schema")
	assert_eq(_rest.requests.size(), 1, "refusing means not pushing either")


func test_an_unreadable_cloud_blob_is_not_overwritten() -> void:
	_save.profile["cloud_revision"] = 1
	var doc := CloudSync.to_document("{not json", Save.SCHEMA_VERSION, 9, "", "web")
	_rest.queue_ok(doc)
	var result: Dictionary = await _sync.pull()
	assert_false(result.ok)
	assert_eq(_rest.requests.size(), 1, "a corrupt remote copy is reported, never replaced")


# --- Resolution ---------------------------------------------------------------

func test_keep_local_uploads_above_the_remote_revision() -> void:
	_save.profile["cloud_revision"] = 1
	_save.profile["starter_model_id"] = "local_only"
	_save.save()
	_rest.queue_ok(_remote_doc(9, _remote_profile()))
	await _sync.pull()
	_rest.queue_ok({})
	var result: Dictionary = await _sync.resolve_keep_local()
	assert_true(result.ok)
	assert_eq(int(_save.profile["cloud_revision"]), 10,
		"pushing above the remote revision is what makes the other device see us as ahead")
	assert_eq(_save.profile["starter_model_id"], "local_only")
	assert_false(_sync.blocked_by_conflict)


func test_use_cloud_replaces_the_profile_and_backs_up_what_it_replaced() -> void:
	_save.profile["cloud_revision"] = 1
	_save.profile["starter_model_id"] = "local_only"
	_save.save()
	var remote := _remote_profile()
	remote["starter_model_id"] = "from_cloud"
	_rest.queue_ok(_remote_doc(9, remote))
	await _sync.pull()
	var result: Dictionary = await _sync.resolve_use_cloud()
	assert_true(result.ok)
	assert_eq(_save.profile["starter_model_id"], "from_cloud")
	assert_true(FileAccess.file_exists(TEST_PATH + ".conflict.bak"),
		"a mis-tapped 'use cloud' must be recoverable")
	assert_false(_sync.blocked_by_conflict)


func test_decide_later_keeps_sync_paused_and_picks_neither_side() -> void:
	_save.profile["cloud_revision"] = 1
	_save.profile["starter_model_id"] = "local_only"
	_save.save()
	_rest.queue_ok(_remote_doc(9, _remote_profile()))
	await _sync.pull()
	_sync.resolve_later()
	assert_true(_sync.blocked_by_conflict)
	assert_eq(_save.profile["starter_model_id"], "local_only")


func test_the_conflict_summary_describes_both_sides() -> void:
	_save.profile["cloud_revision"] = 1
	_save.save()
	_rest.queue_ok(_remote_doc(9, _remote_profile(2)))
	await _sync.pull()
	var summary := _sync.conflict_summary()
	assert_string_contains(String(summary["cloud_device"]), "android")
	assert_false(String(summary["local"]).is_empty())
	assert_false(String(summary["cloud"]).is_empty())


# --- Failure handling ---------------------------------------------------------

func test_a_failed_push_leaves_the_local_profile_alone_and_stays_pending() -> void:
	_save.profile["starter_model_id"] = "local_only"
	_save.save()
	_sync.pending = true
	_rest.queue_offline()
	var result: Dictionary = await _sync.push()
	assert_false(result.ok)
	assert_true(_sync.pending, "the change is still owed to the cloud")
	assert_true(_save.has_unsynced())
	assert_eq(int(_save.profile["cloud_revision"]), 0,
		"a revision is only claimed after the server accepts it")
	assert_eq(_save.profile["starter_model_id"], "local_only")


func test_a_permission_failure_names_the_rules() -> void:
	# 403 is a developer mistake, not a player one — the message should say so.
	_sync.pending = true
	_rest.queue_error(403)
	var result: Dictionary = await _sync.push()
	assert_false(result.ok)
	assert_string_contains(String(result.error).to_lower(), "rules")


func test_a_server_error_is_treated_as_offline_and_retried() -> void:
	_sync.pending = true
	_rest.queue_error(503)
	var result: Dictionary = await _sync.push()
	assert_eq(result.state, "offline")
	assert_eq(_sync.status, CloudSync.Status.OFFLINE)


func test_backoff_grows_between_attempts() -> void:
	_sync.pending = true
	_rest.queue_offline()
	await _sync.push()
	var first: float = _sync._backoff
	_rest.queue_offline()
	await _sync.push()
	assert_gt(_sync._backoff, first, "repeated failures must back off, not hammer the server")
	assert_lte(_sync._backoff, CloudSync.BACKOFF_MAX_SEC, "backoff is capped")


func test_nothing_syncs_while_signed_out() -> void:
	_auth.refresh_token = ""
	_sync.request_push()
	assert_false(_sync.pending, "a signed-out player has nothing to push")
	var result: Dictionary = await _sync.pull()
	assert_false(result.ok)
	assert_eq(_rest.requests.size(), 0)


# --- The uploaded payload -----------------------------------------------------

func test_the_upload_targets_the_users_document_with_an_update_mask() -> void:
	_sync.pending = true
	_rest.queue_ok({})
	await _sync.push()
	var url := String(_rest.last()["url"])
	assert_string_contains(url, "/documents/users/uid123")
	assert_string_contains(url, "updateMask.fieldPaths=profile",
		"without an explicit mask a PATCH replaces the whole document")


func test_the_uploaded_blob_is_not_marked_unsynced() -> void:
	# Otherwise the device that downloads it immediately believes it has work to
	# push, and bounces a pointless revision back.
	_save.save()
	_sync.pending = true
	_rest.queue_ok({})
	await _sync.push()
	var sent := _rest.last_body()
	var blob: String = sent["fields"]["profile"]["stringValue"]
	var json := JSON.new()
	json.parse(blob)
	assert_false(bool((json.data as Dictionary).get("unsynced", true)))


# --- Account switching --------------------------------------------------------
# A revision number is only meaningful against ONE account's document. Signing
# out of A and into B must not compare B's document against A's counter — doing
# so reads as "we are ahead" and overwrites B's career with A's.

func test_switching_account_does_not_push_over_the_new_accounts_save() -> void:
	# Local profile belongs to account A, well ahead of B's document.
	_save.profile["cloud_uid"] = "uid_account_a"
	_save.profile["cloud_revision"] = 7
	_save.profile["starter_model_id"] = "account_a_career"
	_save.mark_synced()

	var remote := _remote_profile()
	remote["starter_model_id"] = "account_b_career"
	_rest.queue_ok(_remote_doc(3, remote))
	var result: Dictionary = await _sync.pull()

	assert_eq(result.state, "applied",
		"a different account's document is authoritative, not stale-looking")
	assert_eq(_save.profile["starter_model_id"], "account_b_career")
	assert_eq(_rest.requests.size(), 1, "nothing may be pushed over account B")


func test_switching_account_with_unsynced_work_asks_instead_of_choosing() -> void:
	_save.profile["cloud_uid"] = "uid_account_a"
	_save.profile["cloud_revision"] = 7
	_save.save()  # unsynced work belonging to account A

	_rest.queue_ok(_remote_doc(3, _remote_profile()))
	var result: Dictionary = await _sync.pull()
	assert_eq(result.state, "conflict",
		"unsynced work from the previous account must not be silently discarded")


func test_a_push_records_which_account_it_synced_with() -> void:
	_sync.pending = true
	_rest.queue_ok({})
	await _sync.push()
	assert_eq(_save.profile["cloud_uid"], "uid123",
		"without this the next account switch has nothing to compare against")


func test_adopting_a_remote_profile_records_the_account() -> void:
	_save.profile["cloud_revision"] = 1
	_save.mark_synced()
	_rest.queue_ok(_remote_doc(5, _remote_profile()))
	await _sync.pull()
	assert_eq(_save.profile["cloud_uid"], "uid123")


# --- Device-local settings ----------------------------------------------------

func test_settings_are_not_uploaded() -> void:
	# They describe the hardware in the player's hands (touch scheme, frame cap,
	# key bindings), not their career.
	_save.set_setting("mobile_control_scheme", 2)
	_sync.pending = true
	_rest.queue_ok({})
	await _sync.push()
	var blob: String = _rest.last_body()["fields"]["profile"]["stringValue"]
	var json := JSON.new()
	json.parse(blob)
	assert_false((json.data as Dictionary).has("settings"),
		"device settings must not be published to the cloud")


func test_downloading_a_profile_keeps_this_devices_settings() -> void:
	_save.set_setting("mobile_control_scheme", 2)
	_save.profile["cloud_revision"] = 1
	_save.mark_synced()
	var remote := _remote_profile()
	remote["settings"] = {"mobile_control_scheme": 99}
	_rest.queue_ok(_remote_doc(9, remote))
	await _sync.pull()
	assert_eq(_save.get_setting("mobile_control_scheme", -1), 2,
		"another device's control scheme must not override this one's")


func test_downloading_a_career_announces_that_the_profile_was_replaced() -> void:
	# Live UI (the HQ car park) is showing the OLD career until it hears this, so
	# a player who signs in sees their cars restored on disk but an empty lot.
	_save.profile["cloud_revision"] = 1
	_save.mark_synced()
	watch_signals(_sync)
	_rest.queue_ok(_remote_doc(9, _remote_profile(2)))
	await _sync.pull()
	assert_signal_emitted(_sync, "profile_replaced")


func test_an_ordinary_push_does_not_announce_a_replacement() -> void:
	# Nothing changed locally, so nothing needs rebuilding.
	watch_signals(_sync)
	_sync.pending = true
	_rest.queue_ok({})
	await _sync.push()
	assert_signal_not_emitted(_sync, "profile_replaced")

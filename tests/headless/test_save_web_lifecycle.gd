extends GutTest
# The web lifecycle flush path on the Save autoload (see
# features/save-persistence.md › "Web build"). On the HTML5 export the browser
# never sends NOTIFICATION_WM_CLOSE_REQUEST, so the web build reaches the flush
# through JS visibilitychange / pagehide listeners instead. We cannot fire a
# browser event headlessly, so these tests assert the seam either side of it:
# the shared flush entry point behaves exactly like the desktop close
# notification, and installing the listeners is a safe no-op off web.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_web_lifecycle_profile.json"

var _save: Node


func before_each() -> void:
	_save = SaveTestHelpers.redirect(TEST_PATH)


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)


func test_flush_and_sync_writes_immediately() -> void:
	# The entry point the web listeners call must hit disk without waiting for the
	# debounce — that's the whole point of it existing.
	_save.profile["starter_model_id"] = "web_flush_probe"
	_save.save()  # debounced: nothing on disk yet
	assert_false(FileAccess.file_exists(TEST_PATH), "debounced save should not have written yet")
	_save.flush_and_sync()
	assert_true(FileAccess.file_exists(TEST_PATH), "flush_and_sync should write immediately")
	_save.load_or_new()
	assert_eq(_save.profile.get("starter_model_id", ""), "web_flush_probe",
		"the flushed profile should round-trip from disk")


func test_close_notification_reaches_the_same_flush() -> void:
	# The desktop close path and the web path share one entry point, so whatever
	# the browser listeners trigger is exactly what a desktop close does.
	_save.profile["starter_model_id"] = "close_probe"
	_save.save()
	_save.notification(NOTIFICATION_WM_CLOSE_REQUEST)
	assert_true(FileAccess.file_exists(TEST_PATH), "close notification should flush to disk")
	_save.load_or_new()
	assert_eq(_save.profile.get("starter_model_id", ""), "close_probe")


func test_flush_respects_disabled_storage() -> void:
	# A degraded environment (blocked IndexedDB / read-only fs) must stay
	# in-memory-only — the lifecycle flush must not resurrect writing.
	_save.save_disabled = true
	_save.flush_and_sync()
	assert_false(FileAccess.file_exists(TEST_PATH), "no write while storage is disabled")


func test_install_web_lifecycle_is_inert_off_web() -> void:
	# Called unconditionally from _ready; off the web build it must report "not
	# installed" and touch nothing (headless has no JavaScriptBridge).
	assert_false(Platform.is_web(), "sanity: the test runner is not the web export")
	assert_false(_save.install_web_lifecycle(), "no listeners off web")
	_save.request_web_sync()  # must not error off web
	pass_test("request_web_sync is a no-op off web")

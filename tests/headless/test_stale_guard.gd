extends GutTest
# Logic tests for StaleGuard (scripts/stale_guard.gd), the shared generation-
# token helper for "is this async result still wanted?". Pure logic — no scene
# instantiation needed.


func test_captured_token_is_current_until_bump() -> void:
	var guard := StaleGuard.new()
	var t: int = guard.token()
	assert_true(guard.is_current(t))


func test_bump_invalidates_previously_captured_token() -> void:
	var guard := StaleGuard.new()
	var t: int = guard.token()
	guard.bump()
	assert_false(guard.is_current(t))


func test_token_captured_after_bump_is_current() -> void:
	var guard := StaleGuard.new()
	guard.bump()
	var t: int = guard.token()
	assert_true(guard.is_current(t))


func test_multiple_bumps_still_invalidate_old_token() -> void:
	var guard := StaleGuard.new()
	var t: int = guard.token()
	guard.bump()
	guard.bump()
	guard.bump()
	assert_false(guard.is_current(t))


func test_independent_guards_do_not_interfere() -> void:
	var guard_a := StaleGuard.new()
	var guard_b := StaleGuard.new()
	var token_a: int = guard_a.token()
	var token_b: int = guard_b.token()
	guard_a.bump()
	assert_false(guard_a.is_current(token_a))
	assert_true(guard_b.is_current(token_b))


func test_token_survives_a_process_frame_await_when_not_bumped() -> void:
	var guard := StaleGuard.new()
	var t: int = guard.token()
	await get_tree().process_frame
	assert_true(guard.is_current(t))


func test_bump_during_an_await_invalidates_the_in_flight_token() -> void:
	var guard := StaleGuard.new()
	var t: int = guard.token()
	guard.bump()  # simulates a rebuild that happens while other code awaits
	await get_tree().process_frame
	assert_false(guard.is_current(t))

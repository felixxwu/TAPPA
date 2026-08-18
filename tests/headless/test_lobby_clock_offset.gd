extends GutTest
# The lobby's clock-offset correction.
#
# Every round boundary and every timestamp in the lobby is only as good as the
# device's clock. A phone 20 s fast races a DIFFERENT round than everyone else while
# believing it shares theirs — the single largest failure mode in the design, and one
# that produces no error, just a player alone in a lobby that looks broken.
#
# The fix is to trust the server's Date header over the local clock. These tests pin
# the plumbing that makes that possible.

var _rest: FakeRestClient


func before_each() -> void:
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)


func test_a_response_surfaces_the_server_date() -> void:
	_rest.queue_ok({}, 200, 1_700_000_000_000)
	var res: Dictionary = await _rest.request_json(HTTPClient.METHOD_GET, "http://x", PackedStringArray())
	assert_eq(int(res.get("date_ms", 0)), 1_700_000_000_000,
		"the server's Date reaches the caller")


func test_a_response_without_a_date_reports_zero_not_a_bogus_epoch() -> void:
	_rest.queue_ok({})
	var res: Dictionary = await _rest.request_json(HTTPClient.METHOD_GET, "http://x", PackedStringArray())
	assert_eq(int(res.get("date_ms", 0)), 0,
		"a missing Date is reported as absent, never as 1970")


func test_the_offset_is_the_difference_between_server_and_local() -> void:
	# A device 20 s BEHIND the server must add 20 s to its own clock.
	assert_eq(RoundClock.offset_from(1_700_000_020_000, 1_700_000_000_000), 20_000,
		"a slow local clock yields a positive offset")
	assert_eq(RoundClock.offset_from(1_700_000_000_000, 1_700_000_020_000), -20_000,
		"a fast local clock yields a negative offset")


func test_an_absent_server_date_leaves_the_offset_alone() -> void:
	assert_eq(RoundClock.offset_from(0, 1_700_000_000_000), 0,
		"no server time means no correction — never a 55-year offset")


func test_the_corrected_clock_can_move_a_client_into_the_right_round() -> void:
	# The failure this whole mechanism exists to prevent, end to end.
	var span_ms: int = RoundClock.ROUND_SECONDS * 1000
	var true_now_ms: int = (RoundClock.LOBBY_EPOCH * 1000) + span_ms + 1000
	var skewed_local_ms: int = true_now_ms - span_ms  # 3 minutes slow
	var offset: int = RoundClock.offset_from(true_now_ms, skewed_local_ms)
	assert_eq(RoundClock.round_index((skewed_local_ms + offset) / 1000),
		RoundClock.round_index(true_now_ms / 1000),
		"the correction puts a skewed client in the same round as everyone else")

extends GutTest
# LobbyBoard — the lobby's one Firestore collection.
#
# Runs entirely against FakeRestClient: no network, no Firestore, no real account.
# What is worth being strict about is (a) the encoding traps that silently produce
# zeroes, (b) that a signed-out player degrades to READ-ONLY rather than erroring,
# since spectating without an account is a supported state, and (c) that the query
# descends — ascending would return the SLOWEST racers, so the leader (the one racer
# the mode renders) would be missing from a busy lobby entirely.

const ROUND := "mp:12345"

var _rest: FakeRestClient
var _auth: AuthService
var _board: LobbyBoard


func before_each() -> void:
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)

	_auth = AuthService.new()
	_auth.rest = _rest
	_auth.uid = "uid123"
	_auth.refresh_token = "refresh"
	_auth.id_token = "id"
	_auth.expires_at = Time.get_unix_time_from_system() + 3600.0

	_board = LobbyBoard.new()
	_board.rest = _rest
	_board.auth = _auth
	add_child_autofree(_board)


func _sample(progress_m := 100, speed_mms := 20000,
		state := LobbyStandings.STATE_RACING, finish_ms := 0) -> Dictionary:
	return {"progress_m": progress_m, "speed_mms": speed_mms,
		"state": state, "finish_ms": finish_ms, "at_ms": 1_700_000_000_000}


func _identity() -> Dictionary:
	return {"name": "Racer", "car_id": "synthetic"}


# --- posting ------------------------------------------------------------------

func test_a_post_writes_to_this_rounds_own_path() -> void:
	_rest.queue_ok({})
	await _board.post(ROUND, _sample(), _identity())
	var url: String = String((_rest.requests[0] as Dictionary)["url"])
	assert_string_contains(url, "lobby_rounds", "writes into the lobby collection")
	assert_string_contains(url, "racers/uid123", "writes the player's OWN document")


func test_a_post_carries_an_update_mask() -> void:
	# A Firestore PATCH without an updateMask is a full REPLACE. Without this the
	# write still succeeds, so nothing fails loudly — it just quietly clobbers.
	_rest.queue_ok({})
	await _board.post(ROUND, _sample(), _identity())
	assert_string_contains(String((_rest.requests[0] as Dictionary)["url"]),
		"updateMask", "the PATCH names the fields it is writing")


func test_the_posted_numbers_survive_encoding() -> void:
	# The encoding trap: a wrongly-typed field arrives as a silent zero, which reads
	# as "parked on the start line" rather than as an error.
	_rest.queue_ok({})
	await _board.post(ROUND, _sample(4321, 19000), _identity())
	var body: String = String((_rest.requests[0] as Dictionary)["body"])
	assert_string_contains(body, "4321", "the distance reaches the wire")
	assert_string_contains(body, "19000", "the speed reaches the wire")


func test_a_negative_speed_is_clamped_rather_than_rejected() -> void:
	# A car reversing after a crash has negative track speed. Unclamped, the rules
	# reject the write and that racer FREEZES on every other screen, with no
	# diagnosable cause.
	_rest.queue_ok({})
	var res: Dictionary = await _board.post(ROUND, _sample(100, -5000), _identity())
	assert_eq(res["state"], LobbyBoard.POST_OK, "a reversing car still posts")
	assert_false(String((_rest.requests[0] as Dictionary)["body"]).contains("-5000"),
		"the negative speed never reaches the wire")


func test_a_signed_out_player_does_not_attempt_a_write() -> void:
	# Spectating without an account is supported. It must cost zero requests, not a
	# failed one.
	_auth.uid = ""
	_auth.id_token = ""
	var res: Dictionary = await _board.post(ROUND, _sample(), _identity())
	assert_eq(res["state"], LobbyBoard.POST_SIGNED_OUT, "reports why it did not post")
	assert_eq(_rest.requests.size(), 0, "and sends nothing")


func test_a_rejected_write_is_reported_not_swallowed() -> void:
	_rest.queue_error(403)
	var res: Dictionary = await _board.post(ROUND, _sample(), _identity())
	assert_false(res["ok"], "a rejected write is not a success")
	assert_ne(res["state"], LobbyBoard.POST_OK, "and says so")


# --- reading ------------------------------------------------------------------

func test_the_field_query_descends() -> void:
	# Ascending would return the SLOWEST racers. On a busy lobby the leader — the one
	# racer this mode actually renders — would never appear at all.
	_rest.queue_ok({})
	await _board.fetch(ROUND)
	assert_string_contains(String((_rest.requests[0] as Dictionary)["body"]),
		"DESCENDING", "the field is queried leader-first")


func test_a_read_needs_no_account() -> void:
	_auth.uid = ""
	_auth.id_token = ""
	# runQuery answers with an ARRAY; an empty lobby is an empty array, not {}.
	_rest.queue_ok([])
	var res: Dictionary = await _board.fetch(ROUND)
	assert_true(res["ok"], "a signed-out player can still watch the lobby")
	assert_eq(res["rows"].size(), 0, "an empty lobby reads as an empty field")
	var headers: PackedStringArray = (_rest.requests[0] as Dictionary)["headers"]
	for h: String in headers:
		assert_false(h.to_lower().begins_with("authorization"),
			"a signed-out read sends no Authorization header")


func test_rows_decode_with_their_uid_and_numbers() -> void:
	_rest.queue_ok([{"document": {
		"name": "projects/p/databases/(default)/documents/lobby_rounds/mp:1/racers/other",
		"fields": {
			"name": {"stringValue": "Rival"},
			"car_id": {"stringValue": "synthetic"},
			"progress_m": {"integerValue": "2500"},
			"speed_mms": {"integerValue": "18000"},
			"at_ms": {"integerValue": "1700000000000"},
			"state": {"stringValue": "racing"},
			"finish_ms": {"integerValue": "0"},
		}}}])
	var res: Dictionary = await _board.fetch(ROUND)
	assert_eq(res["rows"].size(), 1, "the row decodes")
	var row: Dictionary = res["rows"][0]
	assert_eq(String(row["uid"]), "other", "the uid comes off the document path")
	assert_eq(int(row["progress_m"]), 2500, "the distance decodes as a number, not a zero")
	assert_eq(int(row["at_ms"]), 1700000000000,
		"a millisecond timestamp survives — it exceeds 32 bits, so a narrow decode truncates it")


func test_a_failed_read_degrades_rather_than_erroring() -> void:
	# A lobby read must never cost someone their race.
	_rest.queue_error(500)
	var res: Dictionary = await _board.fetch(ROUND)
	assert_false(res["ok"], "the failure is reported")
	assert_eq(res["rows"].size(), 0, "and yields an empty field, not a crash")


# --- the shared round-state document --------------------------------------------

func test_reading_state_decodes_the_round() -> void:
	_rest.queue_ok({"fields": {
		"round_index": {"integerValue": "4200"},
		"started_at_ms": {"integerValue": "1700000000000"},
	}})
	var res: Dictionary = await _board.read_state()
	assert_true(res["ok"], "the state doc reads")
	assert_eq(int(res["round_index"]), 4200, "the round index decodes")
	assert_eq(int(res["started_at_ms"]), 1700000000000,
		"the start stamp survives 64-bit decoding")


func test_a_missing_state_doc_is_reported_as_absent_not_an_error() -> void:
	# The very first player the lobby has ever seen hits this path; it must read as
	# "bootstrap me", not as a failure.
	_rest.queue_error(404)
	var res: Dictionary = await _board.read_state()
	assert_false(res["ok"], "no document is not a successful read")
	assert_true(bool(res["absent"]), "but it is recognisably ABSENT, not broken")


func test_a_state_read_needs_no_account() -> void:
	_auth.uid = ""
	_auth.id_token = ""
	_rest.queue_ok({"fields": {
		"round_index": {"integerValue": "7"},
		"started_at_ms": {"integerValue": "1700000000000"},
	}})
	var res: Dictionary = await _board.read_state()
	assert_true(res["ok"], "a signed-out player can still learn the current round")


func test_advancing_writes_the_new_round() -> void:
	_rest.queue_ok({})
	var res: Dictionary = await _board.advance_state(4201, 1_700_000_180_000)
	assert_true(res["ok"], "the advance posts")
	var body: String = String((_rest.requests[0] as Dictionary)["body"])
	assert_string_contains(body, "4201", "the new round index reaches the wire")


func test_a_signed_out_player_cannot_advance() -> void:
	# Writes need auth. A lobby of signed-out spectators sits on a finished round —
	# an accepted consequence of having no anonymous accounts, documented in the
	# feature doc rather than papered over here.
	_auth.uid = ""
	_auth.id_token = ""
	var res: Dictionary = await _board.advance_state(4201, 1_700_000_180_000)
	assert_false(res["ok"], "no write without an account")
	assert_eq(_rest.requests.size(), 0, "and no request is even attempted")


func test_a_lost_advance_race_is_reported_calmly() -> void:
	# Two clients advancing the same round both write the same index; the rules
	# reject the second. That is the SYSTEM WORKING — the loser adopts the winner's
	# value on its next read, so the result must be distinguishable from a network
	# failure and must not be retried blindly.
	_rest.queue_error(403)
	var res: Dictionary = await _board.advance_state(4201, 1_700_000_180_000)
	assert_false(res["ok"], "the lost race is not a success")
	assert_eq(String(res["state"]), LobbyBoard.POST_REJECTED,
		"rejected, distinctly from a network failure")

extends GutTest
# Leaderboard — the global per-stage boards (see the design spec, §4).
#
# Runs entirely against FakeRestClient: no network, no Firestore, no real
# account. What is worth being strict about here is (a) the encoding traps that
# silently produce zeroes, (b) the submit-if-faster decision, since a wrong
# answer either loses a personal best or spams writes, and (c) that EVERY
# failure class degrades to "unavailable" rather than anything the player can
# notice — a leaderboard read must never cost someone their rally.

const STAGE := "front_runners__2__a3f19c__e1"

var _rest: FakeRestClient
var _auth: AuthService
var _board: Leaderboard


func before_each() -> void:
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)

	_auth = AuthService.new()
	_auth.rest = _rest
	# Seat a live session directly: obtaining one is AuthService's job.
	_auth.uid = "uid123"
	_auth.refresh_token = "refresh"
	_auth.id_token = "id"
	_auth.expires_at = Time.get_unix_time_from_system() + 3600.0

	_board = Leaderboard.new()
	_board.rest = _rest
	_board.auth = _auth
	add_child_autofree(_board)


func _sign_out() -> void:
	_auth.uid = ""
	_auth.refresh_token = ""
	_auth.id_token = ""


# --- Response builders --------------------------------------------------------

func _doc(uid: String, display_name: String, time_ms: int) -> Dictionary:
	var doc := FirestoreCodec.document({
		"name": display_name,
		"car_name": "V12 MIOT ROADSTER",
		"car_id": "miot_roadster",
		"time_ms": time_ms,
		"updated_utc": "2026-07-31T10:00:00",
	})
	doc["name"] = "projects/p/databases/(default)/documents/stage_times/%s/times/%s" % [STAGE, uid]
	return doc


func _query_result(docs: Array) -> Array:
	var out: Array = []
	for doc in docs:
		out.append({"document": doc})
	return out


func _count_result(n: int) -> Array:
	return [{"result": {"aggregateFields": {"count": {"integerValue": str(n)}}}}]


# Queue the four calls a successful fetch() makes, in order.
func _queue_fetch(top: Array, own: Variant, faster: int, total: int) -> void:
	_rest.queue_ok(_query_result(top))
	if own == null:
		_rest.queue_error(404)
	else:
		_rest.queue_ok(own)
	if own != null:
		_rest.queue_ok(_count_result(faster))
	_rest.queue_ok(_count_result(total))


func _patch_requests() -> Array:
	var out: Array = []
	for request in _rest.requests:
		if int(request.get("method", 0)) == HTTPClient.METHOD_PATCH:
			out.append(request)
	return out


# --- Encoding -----------------------------------------------------------------

func test_integer_values_round_trip_as_strings() -> void:
	# Firestore carries integers as JSON STRINGS so 64-bit values survive. A
	# number here would decode as 0 and silently rank everyone at the top.
	var doc := FirestoreCodec.document({"time_ms": 58120, "name": "KANGAROO"})
	var fields: Dictionary = doc["fields"]
	assert_eq(typeof(fields["time_ms"]["integerValue"]), TYPE_STRING,
		"integerValue must be encoded as a string")
	assert_eq(FirestoreCodec.int_field(fields, "time_ms"), 58120)
	assert_eq(FirestoreCodec.string_field(fields, "name"), "KANGAROO")


func test_missing_and_malformed_fields_decode_to_empty() -> void:
	assert_eq(FirestoreCodec.int_field({}, "time_ms"), 0)
	assert_eq(FirestoreCodec.string_field({"name": "raw"}, "name"), "")
	assert_true(FirestoreCodec.fields_of("nonsense").is_empty())


func test_update_mask_lists_every_field() -> void:
	var mask := FirestoreCodec.update_mask(["a", "b"])
	assert_eq(mask, "?updateMask.fieldPaths=a&updateMask.fieldPaths=b")


# --- Submit -------------------------------------------------------------------

func test_faster_time_is_written_with_an_update_mask() -> void:
	_rest.queue_ok(_doc("uid123", "KANGAROO", 60000))  # own entry, slower
	_rest.queue_ok(_doc("uid123", "KANGAROO", 58120))  # the PATCH response
	_queue_fetch([_doc("uid123", "KANGAROO", 58120)], _doc("uid123", "KANGAROO", 58120), 0, 1)

	var result: Dictionary = await _board.submit_and_fetch(
		STAGE, 58120, {"name": "KANGAROO", "car_name": "MX-5", "car_id": "mx5"})

	assert_true(result.ok, "a successful round trip is available")
	assert_true(result.posted, "beating your own time posts it")

	var writes := _patch_requests()
	assert_eq(writes.size(), 1, "exactly one write")
	var url := String(writes[0]["url"])
	# Without an explicit updateMask, Firestore treats a PATCH as a FULL replace.
	for field in ["name", "car_name", "car_id", "time_ms", "updated_utc"]:
		assert_string_contains(url, "updateMask.fieldPaths=" + field)

	var body := JSON.parse_string(String(writes[0]["body"])) as Dictionary
	assert_eq(body["fields"]["time_ms"]["integerValue"], "58120")


func test_slower_time_produces_no_write() -> void:
	_rest.queue_ok(_doc("uid123", "KANGAROO", 50000))  # own entry, already faster
	_queue_fetch([_doc("uid123", "KANGAROO", 50000)], _doc("uid123", "KANGAROO", 50000), 0, 1)

	var result: Dictionary = await _board.submit_and_fetch(
		STAGE, 58120, {"name": "KANGAROO", "car_name": "MX-5", "car_id": "mx5"})

	assert_true(result.ok)
	assert_false(result.posted, "a slower run must not overwrite a personal best")
	assert_eq(_patch_requests().size(), 0, "no PATCH at all")


func test_first_time_on_a_board_is_written() -> void:
	_rest.queue_error(404)  # no own entry yet
	_rest.queue_ok({})      # the PATCH response
	_queue_fetch([_doc("uid123", "KANGAROO", 58120)], _doc("uid123", "KANGAROO", 58120), 0, 1)

	var result: Dictionary = await _board.submit_and_fetch(
		STAGE, 58120, {"name": "KANGAROO", "car_name": "MX-5", "car_id": "mx5"})

	assert_true(result.posted, "a 404 means 'never posted here', not a failure")


func test_write_403_keeps_the_board_but_is_reported() -> void:
	# A 403 is either the improvement-only backstop racing another device, or the
	# rules genuinely refusing this uid (in practice: firestore.rules never
	# deployed). Indistinguishable from the response, so the board must stay
	# available AND the refusal must be visible — silently calling it "benign" is
	# what made a never-deployed rules file look like a successful post.
	_rest.queue_error(404)
	_rest.queue_error(403)
	_queue_fetch([_doc("other", "MILKFLOAT", 55000)], _doc("uid123", "KANGAROO", 58120), 1, 2)

	var result: Dictionary = await _board.submit_and_fetch(
		STAGE, 58120, {"name": "KANGAROO", "car_name": "MX-5", "car_id": "mx5"})

	assert_true(result.ok, "a refused write must never cost the player their rally")
	assert_false(result.posted, "nothing was written")
	assert_eq(String(result.post_state), Leaderboard.POST_DENIED)
	assert_ne(String(result.post_error), "", "a denial is never silent")
	assert_string_contains(String(result.post_error), "firestore.rules")


func test_write_401_is_also_reported_as_denied() -> void:
	_rest.queue_error(404)
	_rest.queue_error(401)
	_queue_fetch([], null, 0, 0)

	var result: Dictionary = await _board.submit_and_fetch(
		STAGE, 58120, {"name": "KANGAROO", "car_name": "MX-5", "car_id": "mx5"})

	assert_true(result.ok)
	assert_eq(String(result.post_state), Leaderboard.POST_DENIED)


# Every reason a finished stage can produce no document must be tellable apart
# from the result alone — that is the whole point of post_state.
func test_no_stage_key_is_its_own_post_state() -> void:
	var result: Dictionary = await _board.submit_and_fetch("", 58120, {"name": "K"})
	assert_eq(String(result.post_state), Leaderboard.POST_NO_KEY)
	assert_eq(_rest.requests.size(), 0)


func test_signed_out_submit_reports_signed_out() -> void:
	_sign_out()
	_rest.queue_ok(_query_result([]))
	_rest.queue_ok(_count_result(0))
	var result: Dictionary = await _board.submit_and_fetch(STAGE, 58120, {"name": "K"})
	assert_eq(String(result.post_state), Leaderboard.POST_SIGNED_OUT)
	assert_eq(_patch_requests().size(), 0)


func test_blank_username_reports_no_username() -> void:
	_queue_fetch([], null, 0, 0)
	var result: Dictionary = await _board.submit_and_fetch(STAGE, 58120, {"name": ""})
	assert_eq(String(result.post_state), Leaderboard.POST_NO_USERNAME)
	assert_eq(_patch_requests().size(), 0)


func test_a_dnf_reports_no_time() -> void:
	# A DNF reaches us as a non-positive time: there is nothing to rank, and the
	# rules would reject time_ms <= 0 anyway.
	_queue_fetch([], null, 0, 0)
	var result: Dictionary = await _board.submit_and_fetch(STAGE, -1, {"name": "K"})
	assert_eq(String(result.post_state), Leaderboard.POST_NO_TIME)
	assert_eq(_patch_requests().size(), 0)


func test_not_faster_reports_not_faster() -> void:
	_rest.queue_ok(_doc("uid123", "K", 50000))
	_queue_fetch([], _doc("uid123", "K", 50000), 0, 1)
	var result: Dictionary = await _board.submit_and_fetch(STAGE, 58120, {"name": "K"})
	assert_eq(String(result.post_state), Leaderboard.POST_NOT_FASTER)


func test_a_transport_failure_on_the_write_reports_failed() -> void:
	_rest.queue_error(404)   # no own entry
	_rest.queue_offline()    # the PATCH never lands
	var result: Dictionary = await _board.submit_and_fetch(STAGE, 58120, {"name": "K"})
	assert_false(result.ok)
	assert_eq(String(result.post_state), Leaderboard.POST_FAILED)


func test_no_username_reads_without_writing() -> void:
	_queue_fetch([_doc("other", "MILKFLOAT", 55000)], null, 0, 7)

	var result: Dictionary = await _board.submit_and_fetch(
		STAGE, 58120, {"name": "", "car_name": "MX-5", "car_id": "mx5"})

	assert_true(result.ok)
	assert_eq(_patch_requests().size(), 0, "no name means nothing to post under")
	assert_eq(result.total, 7, "the total is shown even with no entry of your own")


# --- Fetch --------------------------------------------------------------------

func test_rank_is_the_faster_count_plus_one() -> void:
	_queue_fetch([_doc("a", "KANGAROO", 50000)], _doc("uid123", "YOU", 72800), 46, 312)

	var result: Dictionary = await _board.fetch(STAGE)

	assert_true(result.ok)
	assert_eq(result.player_rank, 47, "46 players are faster, so you are 47th")
	assert_eq(result.total, 312)
	assert_eq(int(result.player_row["placed"]), 47)
	assert_true(bool(result.player_row["is_player"]))


func test_rows_are_placed_in_query_order() -> void:
	_queue_fetch([_doc("a", "A", 50000), _doc("b", "B", 51000)], null, 0, 2)

	var result: Dictionary = await _board.fetch(STAGE)

	assert_eq(result.rows.size(), 2)
	assert_eq(int(result.rows[0]["placed"]), 1)
	assert_eq(int(result.rows[1]["placed"]), 2)
	# Mapped into the shape UITheme.standings_row reads.
	assert_eq(int(result.rows[0]["combined_ms"]), 50000)
	assert_eq(String(result.rows[0]["name"]), "A")
	assert_eq(String(result.rows[0]["uid"]), "a", "uid comes from the document path")


func test_empty_board_is_not_a_failure() -> void:
	# runQuery answers an empty collection with one element carrying only a
	# readTime and no document.
	_rest.queue_ok([{"readTime": "2026-07-31T10:00:00Z"}])
	_rest.queue_error(404)
	_rest.queue_ok(_count_result(0))

	var result: Dictionary = await _board.fetch(STAGE)

	assert_true(result.ok)
	assert_eq(result.rows.size(), 0)
	assert_eq(result.total, 0)


func test_signed_out_fetch_sends_no_authorization_header() -> void:
	_sign_out()
	_rest.queue_ok(_query_result([_doc("a", "A", 50000)]))
	_rest.queue_ok(_count_result(4))

	var result: Dictionary = await _board.fetch(STAGE)

	assert_true(result.ok)
	assert_false(result.signed_in)
	assert_eq(result.player_rank, 0, "there is no 'you' to rank")
	assert_eq(_rest.requests.size(), 2, "no own-entry read and no rank count")
	for request in _rest.requests:
		for header in request["headers"] as PackedStringArray:
			assert_false(String(header).begins_with("Authorization"),
				"a signed-out read must carry no credential at all")


# --- Degradation ---------------------------------------------------------------

func test_every_failure_class_lands_in_unavailable() -> void:
	for failure in ["offline", "500", "429", "unparseable"]:
		_rest.requests.clear()
		_rest.queued.clear()
		match failure:
			"offline": _rest.queue_offline()
			"500": _rest.queue_error(500)
			"429": _rest.queue_error(429)
			"unparseable": _rest.queue_ok({"not": "an array"})

		var result: Dictionary = await _board.fetch(STAGE)

		assert_false(result.ok, "%s must read as unavailable" % failure)
		assert_eq(result.rows.size(), 0)
		assert_eq(result.total, 0)


func test_a_missing_stage_key_is_unavailable_and_silent() -> void:
	var result: Dictionary = await _board.fetch("")
	assert_false(result.ok)
	assert_eq(_rest.requests.size(), 0, "no request is made without a key")


# --- Display assembly ----------------------------------------------------------
# Deliberately NOT Standings.visible_rows: that needs the complete ranked field
# to find the player inside it, which a top-N-plus-aggregate fetch never has.

func _row(placed: int) -> Dictionary:
	return {"placed": placed, "name": "N", "car_name": "C", "combined_ms": 1000 * placed}


func test_gap_marker_appears_only_below_the_podium() -> void:
	var top: Array = []
	for i in Leaderboard.PODIUM_ROWS:
		top.append(_row(i + 1))

	var far := Leaderboard.display_rows(top, _row(47))
	assert_eq(far.size(), top.size() + 2)
	assert_true(bool(far[top.size()].get("gap", false)), "a distant rank gets a gap")
	assert_eq(int(far[far.size() - 1]["placed"]), 47)

	# Immediately below the podium: adjacent, so a gap marker would be a lie.
	var adjacent := Leaderboard.display_rows(top, _row(Leaderboard.PODIUM_ROWS + 1))
	assert_eq(adjacent.size(), top.size() + 1)
	for row in adjacent:
		assert_false(bool((row as Dictionary).get("gap", false)))


func test_a_player_on_the_podium_is_not_listed_twice() -> void:
	var top: Array = [_row(1), _row(2), _row(3)]
	assert_eq(Leaderboard.display_rows(top, _row(2)).size(), 3)


func test_no_player_row_leaves_the_list_alone() -> void:
	var top: Array = [_row(1)]
	assert_eq(Leaderboard.display_rows(top, {}).size(), 1)

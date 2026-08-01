extends GutTest
# ChallengeLeaderboard — the Daily/Weekly/Monthly Rally Challenge's world board
# (scripts/cloud/challenge_leaderboard.gd, spec §5). Same FakeRestClient/
# AuthService seam as test_cloud_leaderboard.gd (Leaderboard's own test file),
# adapted to the challenge_runs/{period_key}/entries/{uid} write-once-per-
# checkpoint contract firestore.rules enforces server-side: this file exercises
# the CLIENT's own pre-check of those same transitions (isValidCreate /
# isStageAdvance / isDnfFlip / maxStage), since the actual rules can't run here.

const PERIOD_KEY := "weekly:2026-W31:e1"

var _rest: FakeRestClient
var _auth: AuthService
var _board: ChallengeLeaderboard


func before_each() -> void:
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)

	_auth = AuthService.new()
	_auth.rest = _rest
	_auth.uid = "uid123"
	_auth.refresh_token = "refresh"
	_auth.id_token = "id"
	_auth.expires_at = Time.get_unix_time_from_system() + 3600.0

	_board = ChallengeLeaderboard.new()
	_board.rest = _rest
	_board.auth = _auth
	add_child_autofree(_board)


func _sign_out() -> void:
	_auth.uid = ""
	_auth.refresh_token = ""
	_auth.id_token = ""


# --- Response builders (challenge_runs/entries shape: stages_completed, dnf,
# cum_ms_N) ---------------------------------------------------------------------

func _doc(uid: String, display_name: String, stages_completed: int, dnf: bool, cum_ms: Dictionary) -> Dictionary:
	var values := {
		"name": display_name, "car_name": "V12 MIOT ROADSTER", "car_id": "miot_roadster",
		"stages_completed": stages_completed, "dnf": dnf,
	}
	for k in cum_ms:
		values["cum_ms_%d" % int(k)] = int(cum_ms[k])
	var doc := FirestoreCodec.document(values)
	doc["name"] = "projects/p/databases/(default)/documents/challenge_runs/%s/entries/%s" % [
		PERIOD_KEY, uid]
	return doc


func _query_result(docs: Array) -> Array:
	var out: Array = []
	for doc in docs:
		out.append({"document": doc})
	return out


func _count_result(n: int) -> Array:
	return [{"result": {"aggregateFields": {"count": {"integerValue": str(n)}}}}]


# The four sequential calls fetch_standings_at makes when the player has an
# entry: top query, own-entry read, faster-count, total-count, reached-count.
func _queue_fetch_standings(top: Array, own: Variant, faster: int, total: int, reached: int) -> void:
	_rest.queue_ok(_query_result(top))
	if own == null:
		_rest.queue_error(404)
	else:
		_rest.queue_ok(own)
	if own != null:
		_rest.queue_ok(_count_result(faster))
	_rest.queue_ok(_count_result(total))
	_rest.queue_ok(_count_result(reached))


func _patch_requests() -> Array:
	var out: Array = []
	for request in _rest.requests:
		if int(request.get("method", 0)) == HTTPClient.METHOD_PATCH:
			out.append(request)
	return out


func _identity() -> Dictionary:
	return {"name": "KANGAROO", "car_name": "MX-5", "car_id": "mx5"}


# --- post_checkpoint: k == 1 (create) -------------------------------------------

func test_post_checkpoint_at_k1_creates_a_new_document_when_none_exists() -> void:
	_rest.queue_error(404)  # own entry: none yet
	_rest.queue_ok({})      # the write

	var result: Dictionary = await _board.post_checkpoint(PERIOD_KEY, 1, 50000, _identity())

	assert_true(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_POSTED)
	assert_eq(_patch_requests().size(), 1)
	var body := JSON.parse_string(String(_patch_requests()[0]["body"])) as Dictionary
	assert_eq(body["fields"]["stages_completed"]["integerValue"], "1")
	assert_eq(body["fields"]["cum_ms_1"]["integerValue"], "50000")


func test_post_checkpoint_at_k1_when_own_entry_already_exists_reports_already_posted() -> void:
	_rest.queue_ok(_doc("uid123", "KANGAROO", 1, false, {1: 40000}))

	var result: Dictionary = await _board.post_checkpoint(PERIOD_KEY, 1, 50000, _identity())

	assert_false(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_ALREADY_POSTED)
	assert_eq(_patch_requests().size(), 0, "an existing k==1 entry is never overwritten")


# --- post_checkpoint: k > 1 (advance / out-of-order / dnf) ---------------------

func test_post_checkpoint_advances_when_the_prior_checkpoint_landed() -> void:
	_rest.queue_ok(_doc("uid123", "KANGAROO", 1, false, {1: 40000}))
	_rest.queue_ok({})  # the write

	var result: Dictionary = await _board.post_checkpoint(PERIOD_KEY, 2, 90000, _identity())

	assert_true(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_POSTED)
	var body := JSON.parse_string(String(_patch_requests()[0]["body"])) as Dictionary
	assert_eq(body["fields"]["stages_completed"]["integerValue"], "2")
	assert_eq(body["fields"]["cum_ms_2"]["integerValue"], "90000")


func test_post_checkpoint_out_of_order_when_the_prior_checkpoint_never_landed() -> void:
	# stored doc is stuck at stages_completed=1; posting k=3 skips k=2 entirely.
	_rest.queue_ok(_doc("uid123", "KANGAROO", 1, false, {1: 40000}))

	var result: Dictionary = await _board.post_checkpoint(PERIOD_KEY, 3, 130000, _identity())

	assert_false(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_OUT_OF_ORDER)
	assert_eq(_patch_requests().size(), 0, "an out-of-order checkpoint writes nothing")


func test_post_checkpoint_when_no_document_exists_at_all_is_out_of_order() -> void:
	# k>1 with nothing stored at all (e.g. the create silently failed earlier).
	_rest.queue_error(404)

	var result: Dictionary = await _board.post_checkpoint(PERIOD_KEY, 2, 90000, _identity())

	assert_false(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_OUT_OF_ORDER)
	assert_eq(_patch_requests().size(), 0)


func test_post_checkpoint_refuses_to_advance_a_dnfd_run() -> void:
	_rest.queue_ok(_doc("uid123", "KANGAROO", 1, true, {1: 40000}))

	var result: Dictionary = await _board.post_checkpoint(PERIOD_KEY, 2, 90000, _identity())

	assert_false(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_ALREADY_POSTED,
		"a dnf'd run is over — no further stage advance")
	assert_eq(_patch_requests().size(), 0)


# --- post_dnf --------------------------------------------------------------

func test_post_dnf_on_a_nonexistent_document_is_a_silent_no_op() -> void:
	_rest.queue_error(404)  # own entry: none yet — a DNF before any checkpoint

	var result: Dictionary = await _board.post_dnf(PERIOD_KEY)

	assert_true(result.ok, "a no-op is not an error")
	assert_eq(String(result.state), ChallengeLeaderboard.POST_ALREADY_POSTED)
	assert_eq(_patch_requests().size(), 0, "nothing to flip means nothing is written")


func test_post_dnf_on_an_existing_non_dnf_document_flips_it() -> void:
	_rest.queue_ok(_doc("uid123", "KANGAROO", 1, false, {1: 40000}))
	_rest.queue_ok({})  # the PATCH

	var result: Dictionary = await _board.post_dnf(PERIOD_KEY)

	assert_true(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_POSTED)
	assert_eq(_patch_requests().size(), 1)
	var body := JSON.parse_string(String(_patch_requests()[0]["body"])) as Dictionary
	assert_eq(bool(body["fields"]["dnf"]["booleanValue"]), true)
	assert_string_contains(String(_patch_requests()[0]["url"]), "updateMask.fieldPaths=dnf")


func test_post_dnf_on_an_already_dnfd_document_is_a_no_op() -> void:
	_rest.queue_ok(_doc("uid123", "KANGAROO", 1, true, {1: 40000}))

	var result: Dictionary = await _board.post_dnf(PERIOD_KEY)

	assert_true(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_ALREADY_POSTED)
	assert_eq(_patch_requests().size(), 0)


func test_post_dnf_signed_out_reports_signed_out_without_a_network_call() -> void:
	_sign_out()
	var result: Dictionary = await _board.post_dnf(PERIOD_KEY)
	assert_false(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_SIGNED_OUT)
	assert_eq(_rest.requests.size(), 0)


# --- post_checkpoint: signed out ------------------------------------------------

func test_post_checkpoint_signed_out_reports_signed_out_without_a_network_call() -> void:
	_sign_out()
	var result: Dictionary = await _board.post_checkpoint(PERIOD_KEY, 1, 50000, _identity())
	assert_false(result.ok)
	assert_eq(String(result.state), ChallengeLeaderboard.POST_SIGNED_OUT)
	assert_eq(_rest.requests.size(), 0)


# --- fetch_standings_at -----------------------------------------------------

func test_fetch_standings_at_assembles_totals_and_rank() -> void:
	_queue_fetch_standings(
		[_doc("a", "A", 2, false, {2: 50000})],
		_doc("uid123", "YOU", 2, false, {2: 90000}), 6, 10, 8)

	var result: Dictionary = await _board.fetch_standings_at(PERIOD_KEY, 2)

	assert_true(result.ok)
	assert_eq(int(result.total_entries), 10)
	assert_eq(int(result.player_rank), 7, "6 faster entries -> rank 7")
	assert_eq(int(result.not_yet_complete), 2, "10 total - 8 reached stage 2")
	assert_eq(result.rows.size(), 1)
	assert_eq(int(result.rows[0]["placed"]), 1)


func test_fetch_standings_at_with_no_own_entry_reports_rank_zero() -> void:
	_rest.queue_ok(_query_result([_doc("a", "A", 1, false, {1: 50000})]))
	_rest.queue_error(404)  # no own entry at this checkpoint
	_rest.queue_ok(_count_result(5))   # total
	_rest.queue_ok(_count_result(3))   # reached

	var result: Dictionary = await _board.fetch_standings_at(PERIOD_KEY, 1)

	assert_true(result.ok)
	assert_eq(int(result.player_rank), 0, "no entry at this checkpoint -> unranked")
	assert_eq(int(result.total_entries), 5)
	assert_eq(int(result.not_yet_complete), 2)


func test_fetch_standings_at_every_failure_class_lands_in_unavailable() -> void:
	for failure in ["offline", "500", "unparseable"]:
		_rest.requests.clear()
		_rest.queued.clear()
		match failure:
			"offline": _rest.queue_offline()
			"500": _rest.queue_error(500)
			"unparseable": _rest.queue_ok({"not": "an array"})

		var result: Dictionary = await _board.fetch_standings_at(PERIOD_KEY, 1)

		assert_false(result.ok, "%s must read as unavailable" % failure)
		assert_eq(result.rows.size(), 0)
		assert_eq(int(result.total_entries), 0)


# --- fetch_final_rank --------------------------------------------------------

func test_fetch_final_rank_wraps_standings_at_the_final_stage() -> void:
	_queue_fetch_standings(
		[_doc("a", "A", 4, false, {4: 100000})],
		_doc("uid123", "YOU", 4, false, {4: 150000}), 2, 5, 5)

	var result: Dictionary = await _board.fetch_final_rank(PERIOD_KEY, 4)

	assert_true(result.ok)
	assert_eq(int(result.rank), 3)
	assert_eq(int(result.total_entries), 5)


func test_fetch_final_rank_is_not_ok_without_a_player_rank() -> void:
	_rest.queue_ok(_query_result([_doc("a", "A", 4, false, {4: 100000})]))
	_rest.queue_error(404)  # never posted the final checkpoint
	_rest.queue_ok(_count_result(5))
	_rest.queue_ok(_count_result(3))

	var result: Dictionary = await _board.fetch_final_rank(PERIOD_KEY, 4)

	assert_false(result.ok, "no rank at the final checkpoint means no completion reward eligibility")


# --- FirestoreCodec.bool round-trip (no dedicated codec test file exists yet) --

func test_firestore_codec_bool_round_trips() -> void:
	var doc := FirestoreCodec.document({"dnf": true, "completed": false})
	var fields: Dictionary = doc["fields"]
	assert_eq(typeof(fields["dnf"]["booleanValue"]), TYPE_BOOL)
	assert_true(FirestoreCodec.bool_field(fields, "dnf"))
	assert_false(FirestoreCodec.bool_field(fields, "completed"))
	assert_false(FirestoreCodec.bool_field({}, "missing"), "a missing field decodes false, not an error")


# --- fetch_cutoff: the time currently on the top-50% cut line ------------------

# The gate is judged once the player is IN the field, so the denominator to predict
# against is the current entry count PLUS the player (unless they already posted).
# Beating the current rank-r time is what puts you AT rank r, so the time to beat is
# the entry at ceil(field / 2), read at that offset - 1.
#
# Queue order: total count, own-entry read (404 = not entered yet), then the one-row
# cut-line query.
func _queue_cutoff(total: int, entered: bool, rows: Array) -> void:
	_rest.queue_ok(_count_result(total))
	if entered:
		_rest.queue_ok(_doc("uid123", "YOU", 1, false, {1: 999999}))
	else:
		_rest.queue_error(404)
	_rest.queue_ok(_query_result(rows))


func _cut_offset() -> int:
	return int(_rest.last_body()["structuredQuery"].get("offset", 0))


# ONE rival: beating their time makes you P1 of 2, and the top 50% of 2 is rank 1 —
# so the time to beat is that single existing time.
func test_fetch_cutoff_with_one_rival_targets_that_rivals_time() -> void:
	_queue_cutoff(1, false, [_doc("a", "A", 4, false, {4: 412340})])

	var result: Dictionary = await _board.fetch_cutoff(PERIOD_KEY, 4)

	assert_true(result.ok)
	assert_true(result.exists, "one rival IS a cut line — this is not an empty board")
	assert_eq(int(result.cutoff_ms), 412340)
	assert_eq(_cut_offset(), 0, "P1 holds the line in a field of two")


# TWO rivals: you would be P2 of 3, and the top 50% of 3 is rank 2 — so the line is
# held by the current P2, not P1.
func test_fetch_cutoff_with_two_rivals_targets_the_current_second_place() -> void:
	_queue_cutoff(2, false, [_doc("b", "B", 4, false, {4: 500000})])

	var result: Dictionary = await _board.fetch_cutoff(PERIOD_KEY, 4)

	assert_true(result.ok)
	assert_eq(_cut_offset(), 1, "P2 holds the line in a field of three")


# THREE rivals: field of 4, top 50% is rank 2 — still the current P2.
func test_fetch_cutoff_with_three_rivals_still_targets_second_place() -> void:
	_queue_cutoff(3, false, [_doc("b", "B", 4, false, {4: 500000})])

	await _board.fetch_cutoff(PERIOD_KEY, 4)

	assert_eq(_cut_offset(), 1, "P2 holds the line in a field of four")


# Already posted this period: the player is ALREADY counted, so the field must not be
# inflated by one on top of them.
func test_fetch_cutoff_does_not_double_count_a_player_already_on_the_board() -> void:
	_queue_cutoff(3, true, [_doc("b", "B", 4, false, {4: 500000})])

	await _board.fetch_cutoff(PERIOD_KEY, 4)

	assert_eq(_cut_offset(), 1, "a field of three, already including you -> P2 holds the line")


func test_fetch_cutoff_orders_by_the_final_checkpoint() -> void:
	_queue_cutoff(1, false, [_doc("a", "A", 4, false, {4: 412340})])

	await _board.fetch_cutoff(PERIOD_KEY, 4)

	var query: Dictionary = _rest.last_body()["structuredQuery"]
	assert_eq(int(query.get("limit", 0)), 1, "asks for just the one row on the line")
	var order: Array = query["orderBy"]
	assert_eq(String(order[0]["field"]["fieldPath"]), "cum_ms_4",
		"ordered by the FINAL checkpoint, which is what the gate ranks on")


# Fewer FINISHERS than the cut rank: the denominator counts everyone who ever posted,
# so the query comes back empty. A real answer — nobody is on the line yet, so any
# finish currently makes the cut — not a failure.
func test_fetch_cutoff_reports_no_line_when_too_few_have_finished() -> void:
	_queue_cutoff(9, false, [])

	var result: Dictionary = await _board.fetch_cutoff(PERIOD_KEY, 4)

	assert_true(result.ok, "an empty line is an answer, not an error")
	assert_false(result.exists)
	assert_eq(int(result.total_entries), 9)


func test_fetch_cutoff_reports_no_line_for_an_empty_board() -> void:
	_queue_cutoff(0, false, [])

	var result: Dictionary = await _board.fetch_cutoff(PERIOD_KEY, 4)

	assert_true(result.ok)
	assert_false(result.exists, "nobody has posted, so there is nothing to beat")


# Same posture as the rest of this class: an unreachable board collapses to
# {"ok": false} — never an error, never a retry. Nothing gates on this value.
func test_fetch_cutoff_collapses_a_failure_instead_of_raising() -> void:
	_rest.queue_error(500)

	var result: Dictionary = await _board.fetch_cutoff(PERIOD_KEY, 4)

	assert_false(result.ok)


func test_fetch_cutoff_refuses_a_nonsense_period_without_calling_out() -> void:
	assert_false(bool((await _board.fetch_cutoff("", 4)).get("ok", false)))
	assert_false(bool((await _board.fetch_cutoff(PERIOD_KEY, 0)).get("ok", false)))
	assert_eq(_rest.requests.size(), 0, "neither one touches the network")

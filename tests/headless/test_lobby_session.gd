extends GutTest
# LobbySession — the autoload that ticks the lobby.
#
# The logic it orchestrates is tested in test_round_clock / test_lobby_standings /
# test_lobby_board. What is left to pin HERE is the wiring nobody else covers: the
# join table (racing immediately is the default — a joiner is never parked staring
# at an empty track), the shared-document round identity with RoundClock as
# bootstrap and fallback, the early advance when everyone has finished, and the
# degradation paths (signed-out, offline) that must never eject a player.

const LobbySessionScript = preload("res://scripts/multiplayer/lobby_session.gd")

var _rest: FakeRestClient
var _auth: AuthService
var _session


func before_each() -> void:
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)

	_auth = AuthService.new()
	_auth.rest = _rest
	_auth.uid = "uid123"
	_auth.id_token = "id"
	_auth.refresh_token = "refresh"
	_auth.expires_at = Time.get_unix_time_from_system() + 3600.0

	_session = LobbySessionScript.new()
	_session.rest = _rest
	_session.auth = _auth
	add_child_autofree(_session)


func after_each() -> void:
	_session.leave()


func _queue_state(round_index: int, started_at_ms: int) -> void:
	_rest.queue_ok({"fields": {
		"round_index": {"integerValue": str(round_index)},
		"started_at_ms": {"integerValue": str(started_at_ms)},
	}})


func _finished_row(uid: String, finish_ms: int) -> Dictionary:
	return {"uid": uid, "name": uid, "car_id": "synthetic", "progress_m": 5000,
		"speed_mms": 0, "at_ms": _session.now_ms(),
		"state": LobbyStandings.STATE_FINISHED, "finish_ms": finish_ms}


func test_it_starts_idle_and_inactive() -> void:
	assert_eq(_session.state(), LobbySessionScript.STATE_IDLE, "nothing runs until entered")
	assert_false(_session.is_active(), "an unentered lobby is not an active session")


func test_entering_a_live_round_races_immediately() -> void:
	# The default is to JOIN, not to wait: a lobby round awards nothing, so
	# start-line fairness is not worth parking the second player who arrives twenty
	# seconds after the first.
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	assert_eq(_session.state(), LobbySessionScript.STATE_RACING,
		"a joiner races now rather than waiting out someone else's round")
	assert_eq(_session.round_index(), 500, "and adopts the shared document's round")
	assert_false(_session.joined_late(), "five seconds in is not a late join")
	assert_eq(_rest.requests.size(), 1, "joining a live round costs one read, no write")


func test_entering_a_dead_lobby_advances_to_a_fresh_round() -> void:
	# Nobody has played for hours: the stored round is long over. The first player
	# in advances the document and races a fresh round immediately — the cold-start
	# case this whole document exists for.
	_queue_state(5, _session.now_ms() - 3_600_000)
	_rest.queue_ok({})  # the advance PATCH
	await _session.enter()
	assert_eq(_session.state(), LobbySessionScript.STATE_RACING, "no waiting in a dead lobby")
	assert_true(_session.round_index() > 5, "the dead round was left behind")
	assert_eq(_rest.requests.size(), 2, "one read, one advance write")


func test_the_very_first_player_bootstraps_the_document() -> void:
	_rest.queue_error(404)  # no state doc has ever existed
	_rest.queue_ok({})  # the creating PATCH
	await _session.enter()
	assert_eq(_session.state(), LobbySessionScript.STATE_RACING,
		"the lobby's first-ever player races immediately")
	assert_eq(_session.round_index(),
		RoundClock.round_index(int(_session.now_ms() / 1000)),
		"the bootstrap round comes from the wall clock")


func test_a_failed_state_read_falls_back_to_the_clock() -> void:
	# The player must always be able to drive SOMETHING: a broken read degrades to
	# the derived round rather than an error screen, and writes nothing.
	_rest.queue_error(500)
	await _session.enter()
	assert_eq(_session.state(), LobbySessionScript.STATE_RACING, "still racing")
	assert_eq(_session.round_index(),
		RoundClock.round_index(int(_session.now_ms() / 1000)),
		"on the clock-derived round")
	assert_eq(_rest.requests.size(), 1, "and no write was attempted against a broken read")


func test_a_late_joiner_is_marked_but_never_refused() -> void:
	var deep_in: int = _session.now_ms() - int(LobbySessionScript.MAX_ROUND_MS * 0.9)
	_queue_state(600, deep_in)
	await _session.enter()
	assert_eq(_session.state(), LobbySessionScript.STATE_RACING, "still joins")
	assert_true(_session.joined_late(), "but the standings can flag the entry as late")


func test_spectating_is_a_choice_not_a_sentence() -> void:
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter(true)
	assert_eq(_session.state(), LobbySessionScript.STATE_SPECTATING,
		"opting to watch is honoured")
	assert_true(_session.is_active(), "and still counts as being in the lobby")
	assert_false(_session.can_post(), "a spectator posts nothing")


func test_the_corrected_clock_is_the_only_clock() -> void:
	# Every boundary and timestamp must go through this, or a skewed device silently
	# races a different round than everyone else.
	_session.set_clock_offset_ms(60_000)
	var corrected: int = _session.now_ms()
	var raw: int = int(Time.get_unix_time_from_system() * 1000.0)
	assert_almost_eq(float(corrected - raw), 60_000.0, 2000.0,
		"now_ms() carries the offset, it does not read the system clock raw")


func test_a_round_cannot_outlive_its_ceiling() -> void:
	# The LOCAL failsafe: even offline or signed out, a client cycles rounds rather
	# than wedging forever on one — that is what unwedges a lobby whose last racer
	# quit without posting.
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	watch_signals(_session)
	_session.set_clock_offset_ms(LobbySessionScript.MAX_ROUND_MS + 60_000)
	_session.poll_round()
	assert_true(_session.round_index() > 500, "the ceiling forced the round over")
	assert_signal_emitted(_session, "round_changed", "and said so")
	assert_eq(_session.state(), LobbySessionScript.STATE_RACING,
		"rolling over starts the player racing fresh")


func test_everyone_finished_ends_the_round_early() -> void:
	# The whole point of the shared document: the round ends when the racing is
	# done, not when the wall clock says so.
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	watch_signals(_session)
	_rest.queue_ok({})  # the advance PATCH
	await _session.check_round_over([
		_finished_row("a", 90_000), _finished_row("b", 95_000),
	])
	assert_true(_session.round_index() > 500, "all finishers ended the round")
	assert_signal_emitted(_session, "round_changed", "and announced it")


func test_a_lost_advance_race_adopts_the_winners_round() -> void:
	# Two clients see "everyone finished" together; one wins the write. The loser
	# must land on the SAME round as the winner, not retry or sulk.
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	_rest.queue_error(403)  # the rules rejected our advance: someone beat us to it
	_queue_state(501, _session.now_ms())  # the winner's round, on re-read
	await _session.check_round_over([_finished_row("a", 90_000)])
	assert_eq(_session.round_index(), 501, "the loser adopts the winner's round")


func test_a_round_with_racers_still_out_does_not_end_early() -> void:
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	var still_racing: Dictionary = {"uid": "c", "name": "c", "car_id": "synthetic",
		"progress_m": 900, "speed_mms": 20000, "at_ms": _session.now_ms(),
		"state": LobbyStandings.STATE_RACING, "finish_ms": 0}
	await _session.check_round_over([_finished_row("a", 90_000), still_racing])
	assert_eq(_session.round_index(), 500, "one racer on track holds the round open")


func test_a_signed_out_player_may_race_but_not_post() -> void:
	_auth.uid = ""
	_auth.id_token = ""
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	assert_true(_session.is_active(), "playing without an account is supported")
	assert_eq(_session.state(), LobbySessionScript.STATE_RACING, "they drive like anyone")
	assert_false(_session.can_post(), "but they do not appear to anyone")


func test_losing_the_network_does_not_eject_a_racer() -> void:
	# A blip mid-round must not throw someone out of a race they are winning.
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	_session.note_read_failed()
	assert_eq(_session.state(), LobbySessionScript.STATE_OFFLINE, "the state reflects reality")
	_session.note_read_succeeded()
	assert_eq(_session.state(), LobbySessionScript.STATE_RACING,
		"and it returns to racing when the network does")


func test_leaving_returns_to_idle() -> void:
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	_session.leave()
	assert_eq(_session.state(), LobbySessionScript.STATE_IDLE, "leaving stops everything")
	assert_false(_session.is_active(), "and the lobby is no longer active")


# --- the synchronised start -------------------------------------------------------

func test_a_fresh_claim_is_held_until_the_shared_release() -> void:
	# The join window: whoever starts a round is held at the line so players who
	# arrive within it start TOGETHER, on one shared clock.
	_queue_state(5, _session.now_ms() - 3_600_000)  # dead lobby
	_rest.queue_ok({})  # the advance
	await _session.enter()
	if Config.data.lobby_start_hold_seconds <= 0.0:
		pass_test("hold disabled in config; nothing to hold")
		return
	assert_true(_session.held(), "a freshly claimed round is inside the join window")
	assert_false(_session.joined_late(), "and its claimant is on time by definition")
	# Jump the corrected clock past the release instant: the hold ends by clock, not
	# by any message — that is what keeps every client's release simultaneous.
	_session.set_clock_offset_ms(_session.release_at_ms() - _session.now_ms() + 1_000)
	assert_false(_session.held(), "past the shared instant the round is released")


func test_a_joiner_inside_the_hold_window_is_not_late() -> void:
	_queue_state(500, _session.now_ms())  # a round claimed this instant
	await _session.enter()
	assert_false(_session.joined_late(),
		"entering during the join window is on time — the window existing is its point")


func test_a_spectator_is_not_held_they_are_spectating() -> void:
	# held() speaks only for a racer at the line; a spectator's hold is their state.
	_queue_state(500, _session.now_ms())
	await _session.enter(true)
	assert_false(_session.held(), "spectating is its own condition, not a held race")


func test_an_early_end_schedules_the_next_start_in_the_future() -> void:
	# started_at_ms in the shared document IS the agreed start instant, so the
	# post-stage countdown on every client counts to the same moment off one write.
	_queue_state(500, _session.now_ms() - 5_000)
	await _session.enter()
	_rest.queue_ok({})  # the advance PATCH
	await _session.check_round_over([_finished_row("a", 90_000)])
	assert_true(_session.release_at_ms() > _session.now_ms(),
		"the next round starts in the FUTURE — an intermission, not an instant cut")
	assert_true(_session.held(), "and every client is held until that shared instant")

extends GutTest
# LobbyStandings (scripts/multiplayer/lobby_standings.gd): the pure maths that turns
# a handful of 3-second-old progress samples into a live-looking field.
#
# Every sample here is SYNTHETIC — hand-built dicts with only the fields the code
# reads. Nothing touches Firestore, a catalogue entry, or a real track.
#
# Two classes of bug are what this file exists to catch, because both would ship
# looking plausible:
#   1. A unit slip in the metres -> milliseconds gap (a 1000x error still looks
#      almost right on a slow car).
#   2. A sort that cannot order finishers, because extrapolation clamps them all to
#      the same distance at the finish line.

const ORIGIN := 0.0
const FINISH := 5000.0


func _sample(uid: String, progress_m: int, speed_mms: int, at_ms: int,
		state: String = LobbyStandings.STATE_RACING, finish_ms: int = 0) -> Dictionary:
	return {"uid": uid, "name": uid, "car_id": "synthetic",
		"progress_m": progress_m, "speed_mms": speed_mms, "at_ms": at_ms,
		"state": state, "finish_ms": finish_ms}


# --- extrapolation ------------------------------------------------------------

func test_a_stale_sample_is_carried_forward_by_its_speed() -> void:
	# 20 m/s for 3 s = 60 m past the posted 100 m.
	var s: Dictionary = _sample("a", 100, 20000, 1_000_000)
	var est: float = LobbyStandings.extrapolate(s, 1_003_000, ORIGIN, FINISH)
	assert_almost_eq(est, 160.0, 0.5, "3 s at 20 m/s carries the sample 60 m forward")


func test_a_fresher_sample_of_the_same_racer_extrapolates_further() -> void:
	# The property that must hold for ANY speed: time moves you forward.
	var s: Dictionary = _sample("a", 100, 20000, 1_000_000)
	var early: float = LobbyStandings.extrapolate(s, 1_001_000, ORIGIN, FINISH)
	var late: float = LobbyStandings.extrapolate(s, 1_002_000, ORIGIN, FINISH)
	assert_true(late > early, "a later instant extrapolates further along the track")


func test_extrapolation_does_not_truncate_slow_movement_to_zero() -> void:
	# The integer trap: mm/s * ms is a big number that MUST NOT be integer-divided
	# early. At 1 m/s over 3 s the racer moves 3 m, not 0.
	var s: Dictionary = _sample("a", 100, 1000, 1_000_000)
	var est: float = LobbyStandings.extrapolate(s, 1_003_000, ORIGIN, FINISH)
	assert_almost_eq(est, 103.0, 0.1, "slow movement survives as fractional metres")


func test_extrapolation_clamps_at_the_finish_line() -> void:
	var s: Dictionary = _sample("a", 4990, 40000, 1_000_000)
	var est: float = LobbyStandings.extrapolate(s, 1_010_000, ORIGIN, FINISH)
	assert_eq(est, FINISH, "a racer cannot be extrapolated past the finish")


func test_extrapolation_clamps_at_the_origin() -> void:
	var s: Dictionary = _sample("a", 0, 0, 1_000_000)
	var est: float = LobbyStandings.extrapolate(s, 900_000, ORIGIN, FINISH)
	assert_eq(est, ORIGIN, "a clock-skewed past timestamp cannot push a racer backwards")


# --- the gap conversion -------------------------------------------------------

func test_gap_converts_metres_and_mm_per_second_to_milliseconds() -> void:
	# 100 m at 20 m/s (20000 mm/s) is 5 s = 5000 ms. This exact assertion is what
	# catches a 1000x factor slip, which would otherwise look plausible on screen.
	assert_eq(LobbyStandings.gap_ms(100.0, 20000), 5000,
		"100 m at 20 m/s is 5000 ms")


func test_gap_scales_linearly_with_distance() -> void:
	var near: int = LobbyStandings.gap_ms(50.0, 20000)
	var far: int = LobbyStandings.gap_ms(150.0, 20000)
	assert_true(far > near, "more ground to make up is a bigger gap")


func test_gap_is_never_negative() -> void:
	# show_position() documents gap_ms as always >= 0; its meaning is carried by the
	# `leading` flag, not by a sign.
	assert_true(LobbyStandings.gap_ms(-40.0, 20000) >= 0,
		"a negative distance still yields a non-negative gap")


func test_gap_survives_a_stationary_racer() -> void:
	# Division by zero is the COMMON case here, not an edge case: every racer is
	# stationary on the start line and after every crash.
	var g: int = LobbyStandings.gap_ms(100.0, 0)
	assert_true(g >= 0, "a stopped racer yields a usable gap, not a crash or a NAN")


# --- ranking ------------------------------------------------------------------

func test_the_further_racer_leads() -> void:
	var ranked: Array = LobbyStandings.rank([
		_sample("behind", 100, 20000, 1_000_000),
		_sample("ahead", 400, 20000, 1_000_000),
	], 1_000_000, ORIGIN, FINISH)
	assert_eq(ranked[0]["uid"], "ahead", "more distance covered is a better place")


func test_a_finisher_outranks_everyone_still_racing() -> void:
	var ranked: Array = LobbyStandings.rank([
		_sample("racing", 4999, 40000, 1_000_000),
		_sample("done", 5000, 0, 1_000_000, LobbyStandings.STATE_FINISHED, 120_000),
	], 1_000_000, ORIGIN, FINISH)
	assert_eq(ranked[0]["uid"], "done",
		"crossing the line beats being one metre short of it")


func test_two_finishers_order_by_their_finishing_time() -> void:
	# The reason distance alone cannot be the sort key: extrapolation clamps every
	# finisher to exactly FINISH, so they all tie and the standings freeze wrong in
	# the last 30 seconds of a round — precisely when anyone is looking at them.
	var ranked: Array = LobbyStandings.rank([
		_sample("slow", 5000, 0, 1_000_000, LobbyStandings.STATE_FINISHED, 150_000),
		_sample("fast", 5000, 0, 1_000_000, LobbyStandings.STATE_FINISHED, 120_000),
	], 1_000_000, ORIGIN, FINISH)
	assert_eq(ranked[0]["uid"], "fast", "the quicker finishing time wins")


func test_a_dnf_sorts_last_even_when_far_along() -> void:
	var ranked: Array = LobbyStandings.rank([
		_sample("wrecked", 4900, 0, 1_000_000, LobbyStandings.STATE_DNF),
		_sample("crawling", 50, 1000, 1_000_000),
	], 1_000_000, ORIGIN, FINISH)
	assert_eq(ranked[1]["uid"], "wrecked", "a DNF is classified behind anyone still running")


func test_a_stale_sample_still_sorts_correctly_against_a_fresh_one() -> void:
	# The whole point of extrapolation: a racer whose update is 3 s old is not
	# actually behind a slower racer who posted a moment ago.
	var ranked: Array = LobbyStandings.rank([
		_sample("fresh_slow", 200, 5000, 1_003_000),
		_sample("stale_fast", 150, 40000, 1_000_000),
	], 1_003_000, ORIGIN, FINISH)
	assert_eq(ranked[0]["uid"], "stale_fast",
		"the fast racer's stale sample extrapolates past the slow racer's fresh one")


func test_place_of_is_one_based_and_counts_the_player() -> void:
	var ranked: Array = LobbyStandings.rank([
		_sample("first", 400, 20000, 1_000_000),
		_sample("me", 200, 20000, 1_000_000),
	], 1_000_000, ORIGIN, FINISH)
	assert_eq(LobbyStandings.place_of(ranked, "first"), 1, "the leader is P1, not P0")
	assert_eq(LobbyStandings.place_of(ranked, "me"), 2, "second place is P2")


func test_place_of_reports_absence_rather_than_guessing() -> void:
	var ranked: Array = LobbyStandings.rank([
		_sample("someone", 400, 20000, 1_000_000),
	], 1_000_000, ORIGIN, FINISH)
	assert_eq(LobbyStandings.place_of(ranked, "nobody"), 0,
		"a uid not in the field has no place — 0, never 1")


func test_an_empty_field_ranks_without_crashing() -> void:
	assert_eq(LobbyStandings.rank([], 1_000_000, ORIGIN, FINISH).size(), 0,
		"an empty lobby is a legal state, not an error")


# --- liveness and the all-finished check ---------------------------------------

func test_a_recently_posting_racer_is_live() -> void:
	var live: Array = LobbyStandings.live_racers([
		_sample("here", 100, 20000, 1_000_000),
	], 1_003_000, 15_000)
	assert_eq(live.size(), 1, "a racer 3 s stale is still live")


func test_a_long_silent_racer_is_abandoned() -> void:
	# Without an abandonment rule, one stale document keeps a lobby looking
	# occupied forever — and "everyone finished" can never come true.
	var live: Array = LobbyStandings.live_racers([
		_sample("gone", 100, 20000, 1_000_000),
	], 1_020_000, 15_000)
	assert_eq(live.size(), 0, "a racer silent past the threshold no longer counts")


func test_a_finished_racer_stays_live_despite_silence() -> void:
	# A finisher has nothing left to post. Their silence is completion, not
	# abandonment — dropping them would erase the round's results one by one.
	var live: Array = LobbyStandings.live_racers([
		_sample("done", 5000, 0, 1_000_000, LobbyStandings.STATE_FINISHED, 90_000),
	], 1_060_000, 15_000)
	assert_eq(live.size(), 1, "a finisher is live however long ago they crossed")


func test_all_finished_needs_at_least_one_finisher() -> void:
	# An empty field must NOT read as "everyone finished" — that would advance an
	# empty lobby round after round for no one.
	assert_false(LobbyStandings.all_finished([]),
		"an empty field is not a completed race")


func test_all_finished_is_false_while_anyone_races() -> void:
	var field: Array = [
		_sample("done", 5000, 0, 1_000_000, LobbyStandings.STATE_FINISHED, 90_000),
		_sample("racing", 2000, 20000, 1_000_000),
	]
	assert_false(LobbyStandings.all_finished(field),
		"one racer still out on track holds the round open")


func test_all_finished_counts_a_dnf_as_settled() -> void:
	# A DNF'd racer's round is over; holding the round open for them would wedge it.
	var field: Array = [
		_sample("done", 5000, 0, 1_000_000, LobbyStandings.STATE_FINISHED, 90_000),
		_sample("out", 1000, 0, 1_000_000, LobbyStandings.STATE_DNF),
	]
	assert_true(LobbyStandings.all_finished(field),
		"finished plus DNF is a settled round")

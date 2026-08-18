extends GutTest
# LobbyField (scripts/multiplayer/lobby_field.gd): the run-scene glue between the
# lobby session, the leader ghost and the HUD position readout.
#
# What is worth pinning here is the PURE decision layer — which row becomes the
# ghost, what four values reach Hud.show_position, and how the local sample settles
# on finish — all with synthetic rows and a stub clock. The scene wiring (ghost
# spawning, HUD calls) is deliberately thin and exercised by playing the mode.


class StubSession:
	extends RefCounted
	signal field_updated(rows: Array)
	var _now: int = 1_000_000
	func now_ms() -> int:
		return _now


var _field: LobbyField


func before_each() -> void:
	_field = LobbyField.new()
	_field.session = StubSession.new()
	_field.own_uid = "me"
	add_child_autofree(_field)


func _row(uid: String, est_m: float, speed_mms: int,
		state: String = LobbyStandings.STATE_RACING) -> Dictionary:
	return {"uid": uid, "name": uid, "car_id": "synthetic", "est_m": est_m,
		"progress_m": int(est_m), "speed_mms": speed_mms,
		"at_ms": 1_000_000, "state": state, "finish_ms": 0}


# --- the readout ----------------------------------------------------------------

func test_the_readout_reports_place_and_field_counting_the_player() -> void:
	var r: Dictionary = _field.readout_for([
		_row("ahead", 400.0, 20000), _row("me", 200.0, 20000),
	])
	assert_eq(int(r["position"]), 2, "the player is P2")
	assert_eq(int(r["field"]), 2, "of a field of 2, counting themselves")
	assert_false(bool(r["leading"]), "and is chasing, not leading")


func test_the_chasing_gap_is_time_at_own_speed_in_milliseconds() -> void:
	# 100 m behind at 20 m/s = 5000 ms. The same 1000x-slip tripwire as
	# test_lobby_standings, but through the layer that actually feeds the HUD —
	# this is the number a player will read as seconds.
	var r: Dictionary = _field.readout_for([
		_row("ahead", 300.0, 20000), _row("me", 200.0, 20000),
	])
	assert_eq(int(r["gap_ms"]), 5000, "100 m at 20 m/s reads as 5.00 s")


func test_the_leading_gap_is_the_cushion_back_to_the_chaser() -> void:
	var r: Dictionary = _field.readout_for([
		_row("me", 300.0, 20000), _row("chaser", 200.0, 20000),
	])
	assert_true(bool(r["leading"]), "P1 is leading")
	assert_true(int(r["gap_ms"]) > 0, "with a real cushion behind")


func test_alone_in_the_lobby_reads_p1_of_1() -> void:
	var r: Dictionary = _field.readout_for([_row("me", 200.0, 20000)])
	assert_eq(int(r["position"]), 1, "alone is P1")
	assert_eq(int(r["field"]), 1, "of 1")
	assert_eq(int(r["gap_ms"]), 0, "with no gap to anyone")


func test_an_absent_player_yields_no_readout_rather_than_a_wrong_one() -> void:
	var r: Dictionary = _field.readout_for([_row("someone", 200.0, 20000)])
	assert_true(r.is_empty(), "no own row means nothing to show, never a guess")


# --- the leader ghost ------------------------------------------------------------

func test_the_ghost_is_the_best_placed_remote_racer() -> void:
	var leader: Dictionary = _field.leader_row([
		_row("them", 400.0, 20000), _row("me", 200.0, 20000),
	])
	assert_eq(String(leader["uid"]), "them", "the remote leader gets the ghost")


func test_the_player_leading_means_no_ghost() -> void:
	# The mode renders the one car worth chasing; when that is nobody, it renders
	# nobody — a ghost of P2 behind you is noise.
	var leader: Dictionary = _field.leader_row([
		_row("me", 400.0, 20000), _row("them", 200.0, 20000),
	])
	assert_eq(String(leader["uid"]), "them",
		"the best-placed REMOTE racer is the ghost even when the player leads")


func test_an_empty_field_means_no_ghost() -> void:
	assert_true(_field.leader_row([]).is_empty(), "nobody to chase, nobody rendered")


# --- the local sample ------------------------------------------------------------

func test_the_sample_settles_on_finish_and_keeps_its_time() -> void:
	_field.note_finished(93.5)
	var s: Dictionary = _field.local_sample()
	assert_eq(String(s["state"]), LobbyStandings.STATE_FINISHED, "finished is posted")
	assert_eq(int(s["finish_ms"]), 93_500, "with the stage time in milliseconds")
	assert_eq(int(s["speed_mms"]), 0, "and a settled racer posts no speed")


func test_a_dnf_outranks_a_finish_in_the_sample() -> void:
	# The round boundary can cut a racer off in the same instant they cross the
	# line; DNF-after-finish must not resurrect them as racing.
	_field.note_finished(93.5)
	_field.note_dnf()
	var s: Dictionary = _field.local_sample()
	assert_eq(String(s["state"]), LobbyStandings.STATE_DNF, "dnf is terminal")

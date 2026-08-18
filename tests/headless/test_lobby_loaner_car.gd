extends GutTest
# The lobby's loaner car.
#
# A lobby round hands everyone the same car regardless of what they own, and touches
# NOTHING in the save profile. These tests pin the two halves of that: the car is
# resolvable to a real catalogue index, and a lobby round counts as an active session
# so it is not silently mistaken for free roam.
#
# enter() reads the shared round document, so the AUTOLOAD's board is pointed at a
# FakeRestClient for the duration — these tests must never touch the network.

var _rest: FakeRestClient
var _saved_board


func before_each() -> void:
	_rest = FakeRestClient.new()
	add_child_autofree(_rest)
	var fake_auth := AuthService.new()
	fake_auth.rest = _rest
	var fake_board := LobbyBoard.new()
	fake_board.rest = _rest
	fake_board.auth = fake_auth
	add_child_autofree(fake_board)
	_saved_board = LobbySession.board
	LobbySession.board = fake_board


func after_each() -> void:
	LobbySession.leave()
	LobbySession.board = _saved_board


func _enter_live_round() -> void:
	_rest.queue_ok({"fields": {
		"round_index": {"integerValue": "500"},
		"started_at_ms": {"integerValue": str(LobbySession.now_ms() - 5_000)},
	}})
	await LobbySession.enter()


func test_the_rounds_car_resolves_to_a_catalogue_index() -> void:
	# world.gd fields it via CarLibrary.index_of(...); a -1 would silently fall back
	# to the default car, so every player would drive the same starter and believe it
	# was the round's pick.
	for i: int in range(40):
		var id: String = LobbyRound.car_id_for(RoundClock.round_key(i))
		assert_true(CarLibrary.index_of(id) >= 0,
			"round %d's car '%s' resolves to a real catalogue index" % [i, id])


func test_a_lobby_round_counts_as_an_active_session() -> void:
	# Without this, everything gated on session_active() treats a lobby round as free
	# roam — including the stage config that seats the round's own track.
	assert_false(DrivingContext.session_active(), "nothing is active to begin with")
	await _enter_live_round()
	assert_true(DrivingContext.session_active(),
		"a lobby round is a real run, not free roam")


func test_a_lobby_round_fields_no_owned_instance() -> void:
	# The loaner is a bare catalogue model: no owned instance, so nothing can be
	# repaired, refitted, or written back to the profile.
	await _enter_live_round()
	assert_eq(DrivingContext.active_car_instance_id(), -1,
		"there is no owned instance behind a loaner")
	assert_true(DrivingContext.driven_car().is_empty(),
		"driven_car() reports 'nothing fielded', its documented empty return")

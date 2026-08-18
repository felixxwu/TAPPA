extends GutTest
# LobbyRound (scripts/multiplayer/lobby_round.gd): turning a round key into the
# content every client must independently agree on — the stage and the loaner car.
#
# The contract under test is DETERMINISM and WELL-FORMEDNESS, never the rolled
# values. Which car round 12 picks and how twisty its stage is are outputs of a
# tunable roll; asserting them would pin a moving number. What must hold for any
# roll is that two clients computing it get the same answer, and that the answer is
# usable by the code downstream.


func test_the_same_key_yields_an_identical_stage() -> void:
	# The no-server premise, at the content level: two CLIENTS, not two calls.
	var a: Dictionary = LobbyRound.stage_for("mp:900")
	var b: Dictionary = LobbyRound.stage_for("mp:900")
	assert_eq(a, b, "two clients rolling the same key get byte-identical stages")


func test_different_keys_yield_different_stages() -> void:
	assert_ne(LobbyRound.stage_for("mp:1"), LobbyRound.stage_for("mp:2"),
		"consecutive rounds are not the same track")


func test_the_stage_carries_the_fields_the_generator_reads() -> void:
	# Whatever the roll produces, the dict has to be usable by
	# RallySession.apply_event_config / TrackGenParams.for_event downstream.
	var stage: Dictionary = LobbyRound.stage_for("mp:55")
	for key: String in ["seed", "turn_count", "straightness"]:
		assert_true(stage.has(key), "the stage dict carries '%s'" % key)


func test_the_stage_is_generatable_not_degenerate() -> void:
	# Sanity guards only: these rule out a broken roll (a zero-turn track, a
	# negative seed), not a particular chosen value.
	for i: int in range(30):
		var stage: Dictionary = LobbyRound.stage_for(RoundClock.round_key(i))
		assert_true(int(stage["turn_count"]) > 0, "round %d has turns" % i)
		assert_true(int(stage["seed"]) >= 0, "round %d has a usable seed" % i)


func test_the_same_key_yields_the_same_car() -> void:
	assert_eq(LobbyRound.car_id_for("mp:77"), LobbyRound.car_id_for("mp:77"),
		"the loaner car is a pure function of the key")


func test_the_car_is_always_a_real_catalogue_entry() -> void:
	# Iterating the table as opaque input — this asserts the CONTRACT (a drawn car
	# is a real car) without depending on any one entry existing.
	var ids: Array = []
	for car: Dictionary in CarLibrary.all():
		ids.append(car["id"])
	for i: int in range(60):
		var picked: String = LobbyRound.car_id_for(RoundClock.round_key(i))
		assert_true(ids.has(picked),
			"round %d picked '%s', which is in the catalogue" % [i, picked])


func test_the_car_pick_survives_a_reordered_catalogue() -> void:
	# The pick sorts ids before indexing, so it depends on the SET of cars, not on
	# the authored array order — reordering CARS must not silently change rounds.
	var forward: Array[Dictionary] = CarLibrary.all().duplicate()
	var picked_before: String = LobbyRound.car_id_for("mp:31")
	var reversed_cars: Array[Dictionary] = []
	for i: int in range(forward.size() - 1, -1, -1):
		reversed_cars.append(forward[i])
	CarLibrary.override_for_test(reversed_cars)
	var picked_after: String = LobbyRound.car_id_for("mp:31")
	CarLibrary.reset()
	assert_eq(picked_before, picked_after,
		"reordering the authored table does not change which car a round picks")

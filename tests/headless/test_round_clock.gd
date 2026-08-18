extends GutTest
# RoundClock (scripts/multiplayer/round_clock.gd): the wall clock IS the lobby's
# coordinator — there is no server, so two clients agree on which round is running
# only because they compute it from the same pure function of unix time.
#
# Every test injects its own unix time. Nothing here reads the real clock, and
# nothing asserts the ROUND_SECONDS value itself (a designer may retune it) — only
# that the derivation holds for whatever it is set to.


func test_the_epoch_instant_is_round_zero() -> void:
	assert_eq(RoundClock.round_index(RoundClock.LOBBY_EPOCH), 0,
		"the epoch is the origin of the round numbering")


func test_a_round_lasts_exactly_round_seconds() -> void:
	var t: int = RoundClock.LOBBY_EPOCH
	var span: int = RoundClock.ROUND_SECONDS
	assert_eq(RoundClock.round_index(t + span - 1), 0,
		"one second before the boundary is still the same round")
	assert_eq(RoundClock.round_index(t + span), 1,
		"the boundary instant belongs to the NEXT round")


func test_time_before_the_epoch_does_not_wrap_to_a_huge_round() -> void:
	# Integer division truncates toward zero in GDScript, so a naive
	# (t - EPOCH) / SPAN gives 0 for the whole span BEFORE the epoch too —
	# two different instants collapsing onto one round key.
	assert_eq(RoundClock.round_index(RoundClock.LOBBY_EPOCH - 1), -1,
		"pre-epoch time floors to a negative round, never back onto round 0")


func test_bounds_are_the_half_open_interval_of_their_round() -> void:
	var b: Dictionary = RoundClock.bounds(7)
	assert_eq(RoundClock.round_index(b["starts_at"]), 7,
		"a round contains its own start instant")
	assert_eq(RoundClock.round_index(b["ends_at"]), 8,
		"a round's end instant is already the next round — the interval is half-open")
	assert_eq(b["ends_at"] - b["starts_at"], RoundClock.ROUND_SECONDS,
		"the interval is exactly one round long")


func test_round_keys_are_distinct_per_round() -> void:
	assert_ne(RoundClock.round_key(4), RoundClock.round_key(5),
		"two rounds must not share a database path")


func test_the_same_key_always_yields_the_same_seed() -> void:
	# This is the whole no-server premise: two CLIENTS running this independently
	# must land on the same number, so it must be a pure function of the key.
	var a: int = RoundClock.seed_for("mp:12345")
	var b: int = RoundClock.seed_for("mp:12345")
	assert_eq(a, b, "the seed is a pure function of the key")


func test_different_keys_yield_different_seeds() -> void:
	assert_ne(RoundClock.seed_for("mp:1"), RoundClock.seed_for("mp:2"),
		"consecutive rounds must not generate the same content")


func test_the_seed_is_non_negative() -> void:
	# It feeds RandomNumberGenerator.seed and is used in modulo arithmetic for the
	# car pick; a negative would make the car index negative too.
	for i: int in range(50):
		assert_true(RoundClock.seed_for(RoundClock.round_key(i)) >= 0,
			"seed for round %d is non-negative" % i)

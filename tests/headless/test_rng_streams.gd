extends GutTest
# RngStreams: named, seeded random streams, so a replay with the same seed draws the same numbers.

var _saved_seed := 0


func before_all() -> void:
	_saved_seed = RngStreams.game_seed


func after_all() -> void:
	RngStreams.reseed(_saved_seed)


func _draws(rng: RandomNumberGenerator) -> Array:
	return [rng.randi(), rng.randi(), rng.randf()]


func test_same_seed_name_and_id_draw_the_same() -> void:
	RngStreams.reseed(42)
	assert_eq(_draws(RngStreams.make("x", 3)), _draws(RngStreams.make("x", 3)))


func test_a_different_name_id_or_seed_draws_differently() -> void:
	RngStreams.reseed(42)
	var base := _draws(RngStreams.make("x", 3))
	assert_ne(_draws(RngStreams.make("y", 3)), base, "name changes the stream")
	assert_ne(_draws(RngStreams.make("x", 4)), base, "id changes the stream")
	RngStreams.reseed(43)
	assert_ne(_draws(RngStreams.make("x", 3)), base, "seed changes the stream")


func test_reseed_restarts_shared_streams() -> void:
	RngStreams.reseed(7)
	var first := _draws(RngStreams.shared("s"))
	assert_same(RngStreams.shared("s"), RngStreams.shared("s"), "shared caches one stream per name")
	RngStreams.reseed(7)
	assert_eq(_draws(RngStreams.shared("s")), first)


func test_live_states_lists_living_streams_by_key() -> void:
	RngStreams.reseed(1)
	var a := RngStreams.make("live")
	var b := RngStreams.make("live")
	a.randi()
	var states := RngStreams.live_states()
	assert_eq(states.get("live/0#1"), a.state)
	assert_eq(states.get("live/0#2"), b.state)
	a = null
	assert_false(RngStreams.live_states().has("live/0#1"), "a freed stream drops out")


func test_fnv1a32_matches_the_reference_vectors() -> void:
	assert_eq(RngStreams.fnv1a32(""), 0x811C9DC5)
	assert_eq(RngStreams.fnv1a32("a"), 0xE40C292C)
	assert_eq(RngStreams.fnv1a32("foobar"), 0xBF9CF968)

class_name LobbyRound
# Docs: features/multiplayer-lobby.md
# Tests: tests/headless/test_lobby_round.gd
#
# A round key becomes the content every client must independently agree on: the
# stage to drive and the car to drive it in. Pure statics, no I/O — two clients
# call this with the same key and get the same answer, which is the entire reason
# the lobby needs no server.
#
# Structure copied from ChallengeLibrary.stages_for: one RNG seeded once, then
# rolled forward field by field, so the whole dict is a function of the seed.

# Roll ranges. Tunables — retune freely; no test pins them.
const TURN_COUNT_RANGE := [18, 28]
const STRAIGHTNESS_RANGE := [0.25, 0.65]
const FORESTINESS_RANGE := [0.1, 0.7]
const CLIFFINESS_RANGE := [0.0, 0.5]


# The stage every client drives this round. Shaped for RallySession.apply_event_config.
static func stage_for(round_key: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = RoundClock.seed_for(round_key)
	# Order matters: each draw advances the stream, so reordering these lines
	# changes every round's content. Append new fields at the END.
	var turn_count: int = rng.randi_range(TURN_COUNT_RANGE[0], TURN_COUNT_RANGE[1])
	var straightness: float = rng.randf_range(STRAIGHTNESS_RANGE[0], STRAIGHTNESS_RANGE[1])
	var forestiness: float = rng.randf_range(FORESTINESS_RANGE[0], FORESTINESS_RANGE[1])
	var cliffiness: float = rng.randf_range(CLIFFINESS_RANGE[0], CLIFFINESS_RANGE[1])
	return {
		"seed": RoundClock.seed_for(round_key),
		"turn_count": turn_count,
		"straightness": straightness,
		"forestiness": forestiness,
		"cliffiness": cliffiness,
	}


# The loaner car every client drives this round.
#
# Sorted before indexing on purpose: CarLibrary.CARS is an authored array whose ORDER
# is not a contract, so indexing it directly would silently change every round's car
# the first time someone reordered the table. Sorting makes the pick depend only on
# the SET of cars — the weakest dependency available. It still shifts when a car is
# added or removed, which is acceptable because rounds are ephemeral.
static func car_id_for(round_key: String) -> String:
	var ids: Array = []
	for car: Dictionary in CarLibrary.all():
		ids.append(String(car["id"]))
	if ids.is_empty():
		return ""
	ids.sort()
	return String(ids[RoundClock.seed_for(round_key) % ids.size()])

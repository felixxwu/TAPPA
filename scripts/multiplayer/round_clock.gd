class_name RoundClock
# Docs: features/multiplayer-lobby.md
# Tests: tests/headless/test_round_clock.gd, tests/headless/test_lobby_clock_offset.gd
#
# The lobby has no server and no host, so the WALL CLOCK is the coordinator: every
# value two clients must agree on is derived here, as a pure function of unix time.
# Same instant in, same round out, on every device.
#
# This mirrors ChallengeLibrary (scripts/challenge_library.gd), which already solves
# the identical problem for the Daily/Weekly/Monthly challenge — same sha256-prefix
# seed derivation, same "no round trip" guarantee. See features/multiplayer-lobby.md.

# How long one round lasts. A tunable: short enough that a joiner's spectate wait is
# tolerable, long enough that a stage is finishable. Not a value any test may pin.
const ROUND_SECONDS := 180

# The origin of the round numbering (unix seconds). PERMANENT once shipped: changing
# it renumbers every client's rounds mid-flight, so clients on different builds would
# silently race different tracks while believing they shared one.
# 2026-01-01T00:00:00Z.
const LOBBY_EPOCH := 1767225600


# Which round is running at `unix_time`. Negative before the epoch.
static func round_index(unix_time: int) -> int:
	return _floor_div(unix_time - LOBBY_EPOCH, ROUND_SECONDS)


# The database path segment and seed source for a round. Distinct per round.
static func round_key(index: int) -> String:
	return "mp:%d" % index


# The half-open interval [starts_at, ends_at) that `index` occupies.
static func bounds(index: int) -> Dictionary:
	var starts: int = LOBBY_EPOCH + index * ROUND_SECONDS
	return {"starts_at": starts, "ends_at": starts + ROUND_SECONDS}


# The content seed for a round. Non-negative, and a pure function of the key — which
# is what lets two clients generate an identical stage without talking to each other.
static func seed_for(round_key_str: String) -> int:
	return round_key_str.sha256_text().substr(0, 8).hex_to_int()


# GDScript's `/` truncates toward zero, so -1 / 180 is 0 rather than -1. That would
# fold the whole span before the epoch onto round 0 — two different instants sharing
# one round key. Floor instead.
static func _floor_div(numerator: int, denominator: int) -> int:
	var q: int = numerator / denominator
	if numerator % denominator != 0 and (numerator < 0) != (denominator < 0):
		q -= 1
	return q


# How much to ADD to the local clock to land on the server's, in milliseconds.
#
# `server_ms` of 0 means the response carried no Date, so there is nothing to learn
# and the offset stays 0 — correcting against a missing header would fling the client
# back to 1970.
static func offset_from(server_ms: int, local_ms: int) -> int:
	if server_ms <= 0:
		return 0
	return server_ms - local_ms

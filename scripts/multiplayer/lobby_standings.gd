class_name LobbyStandings
# Docs: features/multiplayer-lobby.md
# Tests: tests/headless/test_lobby_standings.gd
#
# Turns a handful of up-to-3-second-old progress samples into a live-looking field.
# Pure statics over plain dicts: no nodes, no Firestore, no Config.
#
# UNITS, because two of them are traps:
#   progress_m  metres          speed_mms  millimetres/second
#   at_ms       unix ms         finish_ms  elapsed ms
# Metres / (mm/s) yields KILOseconds, so metres -> milliseconds is
# `* 1_000_000 / speed_mms`, NOT the intuitive `* 1000`. A 1000x slip here still
# looks almost right on a slow car, which is exactly why it would ship.

const STATE_RACING := "racing"
const STATE_FINISHED := "finished"
const STATE_DNF := "dnf"

# The ceiling for an unknowable gap (a stopped racer). An hour: large enough to read
# as "no meaningful gap", small enough not to overflow anything formatting it.
const MAX_GAP_MS := 3_600_000

# Ordering classes. Lower sorts first.
const _CLASS_FINISHED := 0
const _CLASS_RACING := 1
const _CLASS_DNF := 2


# Where a racer is NOW, given a sample taken up to a few seconds ago.
#
# Carrying speed in the sample is what makes a 3-second cadence look live: without
# it a client would have to differentiate two consecutive samples, leaving it a full
# interval behind and blind to a racer's first update.
static func extrapolate(sample: Dictionary, now_ms: int, origin_m: float,
		finish_m: float) -> float:
	var posted: float = float(sample.get("progress_m", 0))
	var speed: float = float(sample.get("speed_mms", 0))
	var elapsed: float = float(now_ms - int(sample.get("at_ms", now_ms)))
	# float throughout: mm/s * ms / 1e6 integer-divides to ZERO for anything under
	# ~1 m of travel, which would freeze slow and stationary racers on the spot.
	var travelled: float = speed * elapsed / 1_000_000.0
	return clampf(posted + travelled, origin_m, finish_m)


# How long `distance_m` of track takes at `speed_mms`, in MILLISECONDS.
#
# Always non-negative: Hud.show_position documents gap_ms as >= 0 and carries the
# direction in its `leading` flag rather than in a sign.
#
# A zero speed is the COMMON case, not an edge case — every racer is stationary on
# the start line and after every crash — so it returns the cap rather than dividing.
static func gap_ms(distance_m: float, speed_mms: int) -> int:
	var d: float = absf(distance_m)
	if speed_mms <= 0:
		return MAX_GAP_MS
	return mini(int(d * 1_000_000.0 / float(speed_mms)), MAX_GAP_MS)


# The field, best-first, each row gaining an "est_m" key.
#
# The sort key is COMPOSITE and must stay that way: extrapolation clamps at the
# finish, so every finisher ties on distance and cannot be ordered against another
# finisher by distance alone.
static func rank(samples: Array, now_ms: int, origin_m: float,
		finish_m: float) -> Array:
	var rows: Array = []
	for s: Dictionary in samples:
		var row: Dictionary = s.duplicate(true)
		row["est_m"] = extrapolate(s, now_ms, origin_m, finish_m)
		rows.append(row)
	rows.sort_custom(_before)
	return rows


static func _before(a: Dictionary, b: Dictionary) -> bool:
	var ca: int = _class_of(a)
	var cb: int = _class_of(b)
	if ca != cb:
		return ca < cb
	if ca == _CLASS_FINISHED:
		return int(a.get("finish_ms", 0)) < int(b.get("finish_ms", 0))
	return float(a.get("est_m", 0.0)) > float(b.get("est_m", 0.0))


static func _class_of(row: Dictionary) -> int:
	match String(row.get("state", STATE_RACING)):
		STATE_FINISHED:
			return _CLASS_FINISHED
		STATE_DNF:
			return _CLASS_DNF
		_:
			return _CLASS_RACING


# 1-based place of `uid` in a ranked field; 0 when absent.
static func place_of(ranked: Array, uid: String) -> int:
	for i: int in range(ranked.size()):
		if String((ranked[i] as Dictionary).get("uid", "")) == uid:
			return i + 1
	return 0


# The rows that still count as "someone is in this round".
#
# A racer whose last sample is older than `stale_ms` has quit, crashed the app, or
# lost their network — treat them as gone. Without this rule one stale document
# keeps a lobby looking occupied forever, and "everyone finished" can never come
# true. A FINISHER is exempt: they have nothing left to post, so their silence is
# completion, not abandonment — dropping them would erase the round's results one
# by one as they aged out.
static func live_racers(rows: Array, now_ms: int, stale_ms: int) -> Array:
	var live: Array = []
	for r: Dictionary in rows:
		var settled: bool = String(r.get("state", STATE_RACING)) != STATE_RACING
		if settled or now_ms - int(r.get("at_ms", 0)) <= stale_ms:
			live.append(r)
	return live


# True when the round has nothing left to wait for: at least one racer, and every
# one of them settled (finished or DNF — a DNF'd racer's round is over, and holding
# the round open for them would wedge it).
#
# An empty field is deliberately NOT "all finished": that would advance an empty
# lobby round after round for no one. Callers pass the LIVE field from
# live_racers(), so an abandoned mid-race quitter cannot hold the round open either.
static func all_finished(live: Array) -> bool:
	if live.is_empty():
		return false
	for r: Dictionary in live:
		if String(r.get("state", STATE_RACING)) == STATE_RACING:
			return false
	return true

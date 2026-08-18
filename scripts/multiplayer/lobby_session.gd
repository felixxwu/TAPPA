extends Node
# Docs: features/multiplayer-lobby.md
# Tests: tests/headless/test_lobby_session.gd
#
# Autoload "LobbySession" — the node that ticks the round-based multiplayer lobby:
# one timer, one state machine, one corrected clock. All the logic it orchestrates
# lives in RoundClock / LobbyStandings / LobbyBoard — this is wiring, deliberately
# kept thin so the interesting parts stay synchronously testable without a node.
#
# THE CLOCK RULE: nothing in the lobby reads Time.get_unix_time_from_system()
# directly. Everything goes through now_ms(), which carries the server offset. A
# device with a skewed clock would otherwise race a different round than everyone
# else and never find out why.
#
# ROUND IDENTITY comes from the shared lobby_state/current document, so a round can
# end EARLY when everyone finishes and a dead lobby restarts the moment someone
# walks in. RoundClock is the bootstrap (no document yet) and the fallback (read
# failed / signed out): a player must always be able to drive SOMETHING. The
# advance write-race is settled by the security rules (strictly increasing index);
# losing it just means adopting the winner's round on the next read.

signal round_changed(index: int)
signal field_updated(rows: Array)

const STATE_IDLE := "idle"
const STATE_SPECTATING := "spectating"
const STATE_RACING := "racing"
const STATE_OFFLINE := "offline"

# How often to poll the board. A tunable, not a contract any test may pin.
const TICK_SECONDS := 3.0

# A round may never outlive this, however it goes — the failsafe that unwedges a
# lobby whose last racer quit without posting. The wall-clock round length is the
# natural ceiling now that rounds can end early.
const MAX_ROUND_MS := RoundClock.ROUND_SECONDS * 1000

# A RACING row silent longer than this is an abandoned racer (see
# LobbyStandings.live_racers). Tunable.
const STALE_MS := 15_000

# Past this fraction of the round, a joiner is marked late — purely informational,
# so the standings can flag a provisional entrant; it never blocks the join.
const LATE_JOIN_FRACTION := 0.25

# Injected so a test can substitute fakes; falls back to the Cloud autoload in
# _ready() only when left null, so a bare LobbySession.new() with rest/auth already
# supplied never touches Cloud.
var rest
var auth
var board

# () -> Dictionary {progress_m, speed_mms, state, finish_ms}: the live sample to
# post, supplied by the run scene's LobbyField once a stage is actually being
# driven. Invalid = nothing to post yet (HQ, loading) — the tick just reads.
var sample_source := Callable()
# () -> Dictionary {name, car_id}: who to post as. Kept injectable for tests.
var identity_source := Callable()
# () -> Dictionary {origin_m, finish_m}: the live track extents, supplied by the
# run scene. Invalid = the Phase A placeholder span.
var span_source := Callable()

var _round_index: int = 0
var _round_started_at_ms: int = 0
var _joined_late: bool = false
var _state: String = STATE_IDLE
var _state_before_offline: String = STATE_IDLE
var _clock_offset_ms: int = 0
var _field: Array = []
var _timer: Timer


func _ready() -> void:
	if rest == null:
		rest = Cloud.rest
	if auth == null:
		auth = Cloud.auth
	if board == null:
		board = LobbyBoard.new()
		board.rest = rest
		board.auth = auth
		add_child(board)

	_timer = Timer.new()
	_timer.wait_time = TICK_SECONDS
	_timer.timeout.connect(_on_tick)
	add_child(_timer)


func state() -> String:
	return _state


# Spectating counts as active: the player is present in the lobby even though they
# have no car in the round yet.
func is_active() -> bool:
	return _state != STATE_IDLE


func round_index() -> int:
	return _round_index


func round_key() -> String:
	return RoundClock.round_key(_round_index)


# Racing immediately is the DEFAULT; spectating is a choice (`spectate = true`).
# A lobby round awards nothing, so strict start-line fairness is not load-bearing —
# and the first player into a dead lobby, or the second player twenty seconds
# behind the first, must not be parked staring at an empty track. The join table:
#
#   no state doc yet          -> bootstrap it from the clock, race now
#   round older than ceiling  -> advance to a fresh round, race now
#   round live                -> join it now (marked late past LATE_JOIN_FRACTION)
#   state read failed         -> fall back to the clock, race now, post nothing new
func enter(spectate := false) -> void:
	_field = []
	_joined_late = false
	var res: Dictionary = await board.read_state()
	var clock_idx: int = RoundClock.round_index(int(now_ms() / 1000))
	if res["ok"]:
		var age: int = now_ms() - int(res["started_at_ms"])
		if age > MAX_ROUND_MS:
			await _claim_round(maxi(int(res["round_index"]) + 1, clock_idx))
		else:
			_round_index = int(res["round_index"])
			_round_started_at_ms = int(res["started_at_ms"])
			_joined_late = age > int(MAX_ROUND_MS * LATE_JOIN_FRACTION)
	elif res["absent"]:
		# The lobby's very first player ever. Their advance CREATES the document.
		await _claim_round(clock_idx)
	else:
		# The read failed. RoundClock keeps the player driving rather than staring
		# at an error — they just won't advance the shared round until it recovers.
		_round_index = clock_idx
		_round_started_at_ms = now_ms()
	_state = STATE_SPECTATING if spectate else STATE_RACING
	_state_before_offline = _state
	if _timer != null:
		_timer.start()


# Purely informational: the standings can flag a late entrant as provisional so
# their placing is explainable, but a late join is never refused.
func joined_late() -> bool:
	return _joined_late


# Claim `idx` as the current round in the shared document. Losing the write race is
# NORMAL (two clients advancing the same round both try the same index; the rules
# reject the second): the loser adopts whatever the winner wrote instead of retrying.
# A signed-out player skips the write and just runs the round locally.
func _claim_round(idx: int) -> void:
	_round_index = idx
	_round_started_at_ms = now_ms()
	if auth == null or not auth.is_signed_in():
		return
	var res: Dictionary = await board.advance_state(idx, _round_started_at_ms)
	if not res["ok"] and String(res["state"]) == LobbyBoard.POST_REJECTED:
		var st: Dictionary = await board.read_state()
		if st["ok"]:
			_round_index = maxi(int(st["round_index"]), _round_index)
			_round_started_at_ms = int(st["started_at_ms"])


func leave() -> void:
	_state = STATE_IDLE
	_field = []
	if _timer != null:
		_timer.stop()


# The ONLY clock the lobby reads. Everything else — round boundaries, gap math,
# extrapolation — derives from this, never from the raw system clock.
func now_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0) + _clock_offset_ms


func set_clock_offset_ms(offset_ms: int) -> void:
	_clock_offset_ms = offset_ms


# now_ms() already includes the current offset, so what a fresh response reports is
# RESIDUAL drift since the last correction — accumulating it converges on the
# server's clock over successive polls. Assigning instead of adding would throw away
# the correction already in effect and oscillate around the true offset rather than
# settling on it.
func _learn_clock(response: Dictionary) -> void:
	var offset: int = RoundClock.offset_from(int(response.get("date_ms", 0)), now_ms())
	if offset != 0:
		_clock_offset_ms += offset


# The LOCAL failsafe: whatever the shared document says (or fails to say), a round
# may never outlive its ceiling on this client. This is what keeps an offline or
# signed-out player cycling through rounds instead of wedging on a finished one.
# Split out from the tick so a test can drive it by moving the clock rather than
# waiting three real minutes.
func poll_round() -> void:
	if _state == STATE_IDLE:
		return
	if now_ms() - _round_started_at_ms <= MAX_ROUND_MS:
		return
	_adopt_round(maxi(_round_index + 1, RoundClock.round_index(int(now_ms() / 1000))),
		now_ms())


# The round ends EARLY when every live racer has settled. Whoever observes it first
# advances the shared document; everyone else loses the write race and adopts the
# winner's round on the read below. A signed-out player cannot write, so they only
# adopt — a lobby of signed-out spectators sits on a finished round until the
# poll_round() ceiling fires, an accepted cost of having no anonymous auth.
func check_round_over(rows: Array) -> void:
	var live: Array = LobbyStandings.live_racers(rows, now_ms(), STALE_MS)
	if not LobbyStandings.all_finished(live):
		return
	var next: int = maxi(_round_index + 1, RoundClock.round_index(int(now_ms() / 1000)))
	if auth != null and auth.is_signed_in():
		var res: Dictionary = await board.advance_state(next, now_ms())
		if res["ok"]:
			_adopt_round(next, now_ms())
			return
	var st: Dictionary = await board.read_state()
	if st["ok"] and int(st["round_index"]) > _round_index:
		_adopt_round(int(st["round_index"]), int(st["started_at_ms"]))


func _adopt_round(idx: int, started_at_ms: int) -> void:
	_round_index = idx
	_round_started_at_ms = started_at_ms
	_field = []
	_joined_late = false
	# A spectator's wait is over and a racer starts fresh — both land in RACING.
	if _state != STATE_IDLE and _state != STATE_OFFLINE:
		_state = STATE_RACING
	_state_before_offline = STATE_RACING
	round_changed.emit(_round_index)


# Offline is NOT an exit — a network blip mid-round must not throw someone out of a
# race they are winning. IDLE/OFFLINE already reflect "not racing" so there is
# nothing to remember or downgrade.
func note_read_failed() -> void:
	if _state == STATE_IDLE or _state == STATE_OFFLINE:
		return
	_state_before_offline = _state
	_state = STATE_OFFLINE


func note_read_succeeded() -> void:
	if _state == STATE_OFFLINE:
		_state = _state_before_offline


# Signed-out is a FLAG, not a state — such a player traverses the same states
# (idle/spectating/racing) with posting disabled; modelling it as its own state
# would duplicate every transition above for no behavioural gain.
func can_post() -> bool:
	return auth != null and auth.is_signed_in() and _state == STATE_RACING


func field() -> Array:
	return _field


func _on_tick() -> void:
	poll_round()
	if _state == STATE_IDLE:
		return
	# Post BEFORE reading, so the read that follows can include our own fresh row —
	# one write and one read per tick, exactly the budget the design promises.
	if can_post() and sample_source.is_valid() and identity_source.is_valid():
		var posted: Dictionary = await board.post(round_key(),
			sample_source.call(), identity_source.call())
		if not posted["ok"] and String(posted["state"]) == LobbyBoard.POST_NETWORK:
			note_read_failed()
	var res: Dictionary = await board.fetch(round_key())
	_learn_clock(res)
	if not res["ok"]:
		note_read_failed()
		return
	note_read_succeeded()
	_field = LobbyStandings.rank(res["rows"], now_ms(), _origin_m(), _finish_m())
	field_updated.emit(_field)
	await check_round_over(res["rows"])


# The live track extents when a run scene has supplied them (LobbyField wires
# span_source from TrackProgress), else the Phase A placeholder span — ranking
# still works during loading, it just cannot clamp at a real finish line.
func _origin_m() -> float:
	if span_source.is_valid():
		return float((span_source.call() as Dictionary).get("origin_m", 0.0))
	return 0.0


func _finish_m() -> float:
	if span_source.is_valid():
		return float((span_source.call() as Dictionary).get("finish_m", 100000.0))
	return 100000.0

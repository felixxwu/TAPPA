class_name LobbyField
extends Node
# Docs: features/multiplayer-lobby.md
# Tests: tests/headless/test_lobby_field.gd
#
# The run-scene half of the multiplayer lobby: everything that needs a real track
# under it. world.gd builds one per lobby run and hands it the live pieces; this
# node then (a) supplies LobbySession's sample/identity/span callables, (b) renders
# the round LEADER as a GhostCar posed from their extrapolated offset, and (c)
# drives the HUD's position readout off the ranked field.
#
# ONE OWNER PER MODE: the lobby never calls StageManager.setup_splits() /
# setup_live_standings(), so the career driver's _update_live_standings() no-ops
# and these two HUD labels have exactly one writer here. See features/hud.md.

# A ghost for a leader this far behind or ahead of nothing isn't worth spawning;
# also the leader row must not be the local player. Tunable.
const MIN_LEADER_LEAD_M := 1.0

var session = null            # the LobbySession autoload (injectable for tests)
var progress: TrackProgress = null
var terrain: Node = null
var hud = null                # scripts/hud.gd instance (untyped: it has no class_name)
var car = null                # the player's car, for the live sample
var ghost_car_scene: PackedScene = null
var event: Dictionary = {}    # the round's stage dict, for GhostCar cosmetics
# Set by world.gd for a SPECTATOR only: the CameraManager to point at the leader
# ghost once one exists. A racer keeps their own chase camera untouched.
var spectate_camera = null

var own_uid: String = ""
var _wired := false           # setup() ran; _exit_tree only severs what it wired
var _finished := false
var _finish_ms := 0
var _dnf := false
var _ghost: GhostCar = null
var _leader_row: Dictionary = {}


func setup(p_session, p_progress: TrackProgress, p_terrain: Node, p_hud, p_car,
		p_ghost_scene: PackedScene, p_event: Dictionary) -> void:
	session = p_session
	progress = p_progress
	terrain = p_terrain
	hud = p_hud
	car = p_car
	ghost_car_scene = p_ghost_scene
	event = p_event
	own_uid = String(Cloud.auth.uid) if Cloud.auth != null else ""
	session.sample_source = local_sample
	session.identity_source = _identity
	session.span_source = _span
	_wired = true
	if not session.field_updated.is_connected(_on_field_updated):
		session.field_updated.connect(_on_field_updated)


# The callables handed to the autoload MUST be severed when this scene dies, or the
# next tick calls into freed objects. exit_tree covers every teardown path (round
# rollover reload, leaving the mode, quitting to HQ) without each needing to remember.
func _exit_tree() -> void:
	if session == null or not _wired:
		return
	session.sample_source = Callable()
	session.identity_source = Callable()
	session.span_source = Callable()
	if session.field_updated.is_connected(_on_field_updated):
		session.field_updated.disconnect(_on_field_updated)


# --- what we tell the lobby ------------------------------------------------------

# The live sample LobbySession posts every tick. Progress and speed come straight
# off the track/car; state flips once and stays (a finisher keeps posting the same
# settled row so late joiners still see them — see the feature doc).
func local_sample() -> Dictionary:
	var state := LobbyStandings.STATE_RACING
	if _dnf:
		state = LobbyStandings.STATE_DNF
	elif _finished:
		state = LobbyStandings.STATE_FINISHED
	var speed_mms := 0
	if car != null and not _finished and not _dnf:
		speed_mms = int(car.linear_velocity.length() * 1000.0)
	var offset := 0.0
	if progress != null:
		offset = progress.progress_offset() - progress.origin_offset()
	return {
		"progress_m": maxi(0, int(offset)),
		"speed_mms": maxi(0, speed_mms),
		"state": state,
		"finish_ms": _finish_ms,
		"at_ms": session.now_ms() if session != null else 0,
	}


func _identity() -> Dictionary:
	return {"name": UsernamePopup.current(),
		"car_id": LobbyRound.car_id_for(session.round_key())}


func _span() -> Dictionary:
	if progress == null:
		return {"origin_m": 0.0, "finish_m": 100000.0}
	# Samples are posted relative to the origin (progress_m 0 = the start line), so
	# the ranking span is relative too.
	return {"origin_m": 0.0,
		"finish_m": progress.finish_offset() - progress.origin_offset()}


# Wired by world.gd to StageManager.stage_completed. finish_ms is THIS client's
# stage-elapsed time; a late joiner's is shorter than a from-the-gun racer's, which
# is why joined_late() exists as a marker rather than pretending otherwise.
func note_finished(elapsed_seconds: float) -> void:
	_finished = true
	_finish_ms = maxi(1, int(elapsed_seconds * 1000.0))


func note_dnf() -> void:
	_dnf = true


# --- what the lobby tells us ------------------------------------------------------

func _on_field_updated(rows: Array) -> void:
	var merged: Array = merged_field(rows)
	_update_readout(merged)
	_update_ghost(merged)


# The fetched field with the LOCAL player's row replaced by the live local sample.
# The database copy of our own row is up to a tick stale; showing the player a
# place computed from their own stale position makes the readout lag every
# overtake they can see happening in front of them.
func merged_field(rows: Array) -> Array:
	var sample: Dictionary = local_sample()
	sample["uid"] = own_uid
	sample["name"] = UsernamePopup.current()
	sample["car_id"] = String(event.get("car_id", ""))
	var merged: Array = []
	for r: Dictionary in rows:
		if own_uid != "" and String(r.get("uid", "")) == own_uid:
			continue
		merged.append(r)
	merged.append(sample)
	return LobbyStandings.rank(merged, session.now_ms(), _span()["origin_m"],
		_span()["finish_m"])


# The four ints/bools Hud.show_position wants, from a ranked merged field. Pure so
# the test can pin the gap conversion without a scene.
func readout_for(ranked: Array) -> Dictionary:
	var place: int = LobbyStandings.place_of(ranked, own_uid)
	if place <= 0:
		return {}
	var mine: Dictionary = ranked[place - 1]
	var gap := 0
	var leading := place == 1
	if leading and ranked.size() > 1:
		var chaser: Dictionary = ranked[1]
		gap = LobbyStandings.gap_ms(
			float(mine.get("est_m", 0.0)) - float(chaser.get("est_m", 0.0)),
			int(chaser.get("speed_mms", 0)))
	elif not leading:
		var ahead: Dictionary = ranked[place - 2]
		gap = LobbyStandings.gap_ms(
			float(ahead.get("est_m", 0.0)) - float(mine.get("est_m", 0.0)),
			maxi(int(mine.get("speed_mms", 0)), 1))
	return {"position": place, "field": ranked.size(), "gap_ms": gap,
		"leading": leading}


func _update_readout(ranked: Array) -> void:
	if hud == null:
		return
	var r: Dictionary = readout_for(ranked)
	if r.is_empty():
		return
	hud.show_position(int(r["position"]), int(r["field"]), int(r["gap_ms"]),
		bool(r["leading"]))


# --- the leader ghost ---------------------------------------------------------------

# The best-placed row that is not the local player. {} when the player leads or is
# alone — the mode renders exactly one remote car, the one worth chasing.
func leader_row(ranked: Array) -> Dictionary:
	for r: Dictionary in ranked:
		if own_uid == "" or String(r.get("uid", "")) != own_uid:
			return r
	return {}


func _update_ghost(ranked: Array) -> void:
	_leader_row = leader_row(ranked)
	if _leader_row.is_empty():
		if _ghost != null:
			_ghost.stop()
			_ghost.visible = false
		return
	if _ghost == null and progress != null and ghost_car_scene != null:
		_ghost = GhostCar.new()
		add_child(_ghost)
		# Null pace: the lobby ghost is posed from the network offset, not a solved
		# pace profile — the seam pose_at_offset/offset_source exists for exactly this.
		_ghost.setup(null, progress, terrain, _leader_row, ghost_car_scene, event)
		_ghost.offset_source = _leader_offset
		_ghost.start()
		# A spectator has no drive of their own to watch: chase the leader instead.
		# retarget() is the existing car-swap hook, reused unchanged.
		if spectate_camera != null and spectate_camera.has_method("retarget"):
			spectate_camera.retarget(_ghost)
	if _ghost != null:
		_ghost.visible = true


# What GhostCar's external drive mode polls each frame: the leader's extrapolated
# offset (absolute, origin-based — samples are start-line-relative) and speed.
func _leader_offset() -> Dictionary:
	if _leader_row.is_empty() or progress == null or session == null:
		return {"offset_m": 0.0, "speed_mps": 0.0}
	var rel: float = LobbyStandings.extrapolate(_leader_row, session.now_ms(),
		0.0, progress.finish_offset() - progress.origin_offset())
	return {"offset_m": progress.origin_offset() + rel,
		"speed_mps": float(_leader_row.get("speed_mms", 0)) / 1000.0}

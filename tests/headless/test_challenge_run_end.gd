extends GutTest
# The END of a Rally Challenge run: world.gd._on_challenge_run_finished, which is
# the challenge's counterpart to RallySession._resolve_results (spec §6).
#
#   clean finish -> ChallengeSession.try_grant_completion_reward (placement-gated)
#   DNF          -> Cloud.challenge_leaderboard.post_dnf (best-effort, not awaited)
#
# Both used to be dead code with no callers anywhere. The seam is the same one
# test_challenge_leaderboard.gd uses — a real ChallengeLeaderboard driven by a
# FakeRestClient — swapped onto the Cloud autoload for the duration of the test,
# so "did the run's end reach the board at all" is assertable without a network.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_challenge_run_end_profile.json"

var _scene: Node3D
var _save: Node
var _rest: FakeRestClient
var _auth: AuthService
var _board: ChallengeLeaderboard
var _real_board: ChallengeLeaderboard
var _scenes: Array[String] = []


func before_all() -> void:
	# One cheap world (1-turn track, no foliage) reused by every test here — we only
	# need the World root to call the run-end handler on.
	SceneHelpers.minimal_world()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)


func after_all() -> void:
	_scene.free()
	Config.reset()


func before_each() -> void:
	CarFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	ChallengeSession.auto_load_scenes = false
	if ChallengeSession.is_active():
		ChallengeSession.abandon()

	_rest = FakeRestClient.new()
	add_child_autofree(_rest)
	_auth = AuthService.new()
	_auth.rest = _rest
	_auth.uid = "uid123"
	_auth.refresh_token = "refresh"
	_auth.id_token = "id"
	_auth.expires_at = Time.get_unix_time_from_system() + 3600.0
	_board = ChallengeLeaderboard.new()
	_board.rest = _rest
	_board.auth = _auth
	add_child_autofree(_board)
	_real_board = Cloud.challenge_leaderboard
	Cloud.challenge_leaderboard = _board

	# Capture the hand-off instead of really changing scene (the GUT runner scene
	# would be replaced).
	_scenes = []
	_scene.scene_change_hook = func(path: String) -> void: _scenes.append(path)


func after_each() -> void:
	_scene.scene_change_hook = Callable()
	Cloud.challenge_leaderboard = _real_board
	if ChallengeSession.is_active():
		ChallengeSession.abandon()
	ChallengeSession.auto_load_scenes = true
	Save.profile["challenge_run"] = {}
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	CarFixtures.restore()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _start_run(kind_str: String) -> Dictionary:
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	assert_true(ChallengeSession.start(kind_str, car, int(Time.get_unix_time_from_system())),
		"the fixture run starts")
	return car


func _urls() -> String:
	var out := ""
	for r in _rest.requests:
		out += String(r.get("url", "")) + "\n"
	return out


# --- Firestore response builders for a qualifying completion-reward fetch,
# mirroring test_challenge_leaderboard.gd's _doc/_query_result/_count_result
# (fetch_final_rank wraps fetch_standings_at, which issues exactly these five
# calls when the player has posted an entry: top query, own-entry read,
# faster-count, total-count, reached-count). -----------------------------------

func _doc(uid: String, stages_completed: int, cum_ms: int) -> Dictionary:
	var values := {
		"name": "YOU", "car_name": "CAR", "car_id": "fx_light_rwd",
		"stages_completed": stages_completed, "dnf": false,
		"cum_ms_%d" % stages_completed: cum_ms,
	}
	var doc := FirestoreCodec.document(values)
	doc["name"] = "projects/p/databases/(default)/documents/challenge_runs/x/entries/%s" % uid
	return doc


func _count_result(n: int) -> Array:
	return [{"result": {"aggregateFields": {"count": {"integerValue": str(n)}}}}]


# Queue the sequence of responses that makes a lone finisher rank #1 of 1 —
# comfortably inside the top-50% placement gate (spec §6) regardless of how the
# reward table itself is tuned, since only "did a reward get granted" and "was
# it revealed" are asserted, never a specific reward.
func _queue_qualifying_rank(stage_count: int) -> void:
	_rest.queue_ok([])  # top query: nobody else has posted
	_rest.queue_ok(_doc("uid123", stage_count, 50000))  # own entry
	_rest.queue_ok(_count_result(0))   # faster
	_rest.queue_ok(_count_result(1))   # total
	_rest.queue_ok(_count_result(1))   # reached


# --- Clean finish: the completion reward is actually attempted -------------------

func test_a_clean_finish_resolves_the_completion_reward_before_handing_off() -> void:
	_start_run(ChallengeLibrary.DAILY)
	var result := {
		"completed": true, "dnf": false, "kind": ChallengeLibrary.DAILY,
		"period_key": ChallengeSession.period_key(),
		"car_instance_id": ChallengeSession.car_instance_id(),
	}
	await _scene._on_challenge_run_finished(result)

	# try_grant_completion_reward is placement-gated on the LIVE board, so the proof
	# it ran is that the run's end consulted the board at all — the call that used to
	# never happen. What it then grants depends on the (tunable) reward table and the
	# fetched field, so nothing about the grant itself is asserted here.
	assert_true(_urls().contains("runQuery"),
		"a clean finish queries the challenge board for the player's placement")
	# Scenes.hub_path() rather than the literal: which scene is the hub is a flag now
	# (GameConfig.overworld_enabled), and what this test cares about is that the run hands off to
	# THE HUB, whichever that is. Asserting the literal broke the moment the flag was flipped.
	assert_eq(_scenes, [Scenes.hub_path()], "and then hands off to the hub")


func test_a_headless_clean_finish_grants_the_reward_with_no_popup_attempted() -> void:
	# Headless play (server exports, and the test runner itself) must never try to
	# put a ConfirmPopup on screen, but the grant is unconditional and must still
	# land — a headless finish is not a lesser finish. _scene._headless mirrors
	# real play here (Platform.is_headless() is true under the test runner).
	assert_true(_scene._headless, "setup: this scene sees a headless runtime, same as real headless play")
	var car := _start_run(ChallengeLibrary.DAILY)
	var stage_count: int = int(ChallengeLibrary.STAGE_COUNTS[ChallengeLibrary.DAILY])
	_queue_qualifying_rank(stage_count)

	await _scene._on_challenge_run_finished({
		"completed": true, "dnf": false, "kind": ChallengeLibrary.DAILY,
		"period_key": ChallengeSession.period_key(),
		"car_instance_id": int(car["instance_id"]),
	})

	assert_null(ConfirmPopup.any_open(get_tree()), "headless never opens a popup")
	# Stars, not boxes: the challenge completion payout replaced the mystery-box grant.
	assert_gt(_save.stars_available(), 0,
		"the placement-gated reward was still granted with nothing on screen to show it")
	assert_eq(_scenes, [Scenes.hub_path()], "and the hand-off to HQ still happens")


# --- The reward reveal must never be silently dropped ---------------------------
#
# try_grant_completion_reward is a ONE-SHOT, non-retryable call: by the time
# run_finished fires, ChallengeSession._finish_locally has already recorded this
# period's outcome and cleared challenge_run, so the period is terminal (see
# ChallengeSession.start/resume, which both refuse once period_outcome is set) and
# there is no "reward pending reveal" state to come back to. Gating the grant
# itself on modal availability (the open_committing shape) would therefore not
# defer the grant on refusal, it would silently keep a reward the player can never
# be told about — worse than the original bug, which never lost the reward, only
# its reveal. So world.gd grants unconditionally and instead GUARANTEES the reveal
# via ConfirmPopup's allow_stack escape hatch. This proves that guarantee: with
# another modal already occupying the one modal slot, the reward card still opens
# (stacked on top) rather than being refused.
func test_the_completion_reward_reveal_stacks_over_an_existing_modal_instead_of_being_dropped() -> void:
	_scene._headless = false
	var car := _start_run(ChallengeLibrary.DAILY)
	var stage_count: int = int(ChallengeLibrary.STAGE_COUNTS[ChallengeLibrary.DAILY])
	_queue_qualifying_rank(stage_count)

	var earlier := ConfirmPopup.open(_scene, "Already on screen", "some other modal",
		[{"label": "OK"}])
	assert_not_null(earlier, "setup: a modal is on screen before the reward fires")

	# Not awaited: _on_challenge_run_finished suspends on popup.finished, so it must
	# be driven from outside like the DNF tests above.
	_scene._on_challenge_run_finished({
		"completed": true, "dnf": false, "kind": ChallengeLibrary.DAILY,
		"period_key": ChallengeSession.period_key(),
		"car_instance_id": int(car["instance_id"]),
	})
	for i in 10:
		await get_tree().process_frame

	var open_modals := get_tree().get_nodes_in_group(ConfirmPopup.MODAL_GROUP)
	assert_eq(open_modals.size(), 2,
		"the reward card opened ON TOP of the pre-existing modal rather than being refused")
	assert_eq(_scenes, [], "the run hasn't handed off to HQ yet — still waiting on the reward card")

	# Dismiss both so the coroutine can finish and hand off.
	for m in open_modals.duplicate():
		if is_instance_valid(m):
			(m as ConfirmPopup).trigger_back()
	for i in 10:
		await get_tree().process_frame

	assert_null(ConfirmPopup.any_open(get_tree()), "both modals are gone")
	assert_eq(_scenes, [Scenes.hub_path()], "and the run now hands off to HQ")


func test_a_clean_finish_still_reaches_hq_when_the_board_is_unavailable() -> void:
	_start_run(ChallengeLibrary.DAILY)
	_rest.queue_error(500)
	_rest.queue_error(500)
	await _scene._on_challenge_run_finished({
		"completed": true, "dnf": false, "kind": ChallengeLibrary.DAILY,
		"period_key": ChallengeSession.period_key(),
		"car_instance_id": ChallengeSession.car_instance_id(),
	})
	assert_eq(_scenes, [Scenes.hub_path()],
		"a failed placement fetch never strands the player in the run scene")


# --- DNF: the board's dnf field is flipped ---------------------------------------

func test_a_dnf_posts_the_board_flip_without_delaying_the_hand_off() -> void:
	_start_run(ChallengeLibrary.WEEKLY)
	var period := ChallengeSession.period_key()
	ChallengeSession.abandon()

	_scene._on_challenge_run_finished({
		"completed": false, "dnf": true, "kind": ChallengeLibrary.WEEKLY,
		"period_key": period,
	})
	# NOT awaited by the handler: the scene hand-off must already have happened by
	# the time control returns, with the post still in flight.
	assert_eq(_scenes, [Scenes.hub_path()], "the DNF returns to HQ immediately")

	# ...and the post resolves in the background against the autoload board.
	for i in 6:
		await get_tree().process_frame
	assert_true(_urls().contains(period.uri_encode()) or _urls().contains(period),
		"post_dnf reached the board for this period key")


func test_a_dnf_is_harmless_with_no_cloud_board_wired_up() -> void:
	Cloud.challenge_leaderboard = null
	_scene._on_challenge_run_finished({"completed": false, "dnf": true, "kind": "weekly"})
	assert_eq(_scenes, [Scenes.hub_path()], "still returns to HQ with no board available")

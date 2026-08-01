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
	assert_eq(_scenes, ["res://hq.tscn"], "and then hands off to HQ")


func test_a_clean_finish_still_reaches_hq_when_the_board_is_unavailable() -> void:
	_start_run(ChallengeLibrary.DAILY)
	_rest.queue_error(500)
	_rest.queue_error(500)
	await _scene._on_challenge_run_finished({
		"completed": true, "dnf": false, "kind": ChallengeLibrary.DAILY,
		"period_key": ChallengeSession.period_key(),
		"car_instance_id": ChallengeSession.car_instance_id(),
	})
	assert_eq(_scenes, ["res://hq.tscn"],
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
	assert_eq(_scenes, ["res://hq.tscn"], "the DNF returns to HQ immediately")

	# ...and the post resolves in the background against the autoload board.
	for i in 6:
		await get_tree().process_frame
	assert_true(_urls().contains(period.uri_encode()) or _urls().contains(period),
		"post_dnf reached the board for this period key")


func test_a_dnf_is_harmless_with_no_cloud_board_wired_up() -> void:
	Cloud.challenge_leaderboard = null
	_scene._on_challenge_run_finished({"completed": false, "dnf": true, "kind": "weekly"})
	assert_eq(_scenes, ["res://hq.tscn"], "still returns to HQ with no board available")

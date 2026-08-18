extends GutTest
# world.gd's rival-ghost wiring, end to end (features/rival-ghost.md).
#
# This file exists because every runtime bug this feature shipped lived HERE, in the
# GO-path plumbing, not in the pieces: a wrong-arity callback that only fired once the
# countdown hit zero, a solve scheduled before the timing origin was anchored, a facing
# error. test_ghost_car.gd covers GhostCar's geometry and test_rival_pace.gd covers the
# solve, but nothing exercised world.gd calling them in order — so nothing could catch a
# defect in the order.
#
# It drives the two phases directly (_setup_stage_splits, then _solve_rival_pace) against
# a real booted world with a real car and a synthetic opponent field, which is exactly the
# sequence StageManager.stage_started triggers in play.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const TEST_SAVE := "user://test_ghost_wiring_save.json"

var _world: Node
var _save


# The world is built ONCE. Instantiating main.tscn per test cost ~4 s each (28 s for this
# file) — the exact trap features/testing.md flags. Nothing here mutates the world
# irreversibly: the ghost node is _replace_named_child'd on every phase-1 call, so re-running
# both phases against one world is the same code path a second event takes.
func before_all() -> void:
	SceneHelpers.minimal_world()
	# MUST be off before ANY start_rally below. RallySession.start_rally -> _enter_event
	# ends in `if auto_load_scenes: get_tree().change_scene_to_file("res://main.tscn")`,
	# and the default is TRUE — so leaving it alone here does not just "not load a scene
	# for this test", it swaps the RUNNER's scene for a full main.tscn that is never freed
	# and stays parked under /root, in the shared World3D, for the whole rest of the run.
	# That is an order-dependent poisoning of every later 3D file: its terrain/car
	# colliders sit in the same physics space, so a settling car lands on them
	# (test_live_refit_suspension) and a camera pick ray hits them first
	# (test_menu_flow's HQ car-park tap) — green in --fast, red in a full run.
	RallySession.auto_load_scenes = false
	CarFixtures.install()
	RallyFixtures.install()
	_save = SaveTestHelpers.redirect(TEST_SAVE)
	_world = load("res://main.tscn").instantiate()
	add_child(_world)


func after_all() -> void:
	if _world != null:
		remove_child(_world)
		_world.free()
		_world = null
	# This file starts real rallies and never finishes them; leaving one active would
	# make every later file's Save/HQ state read as "mid-rally".
	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true
	SaveTestHelpers.cleanup(TEST_SAVE)
	RallyFixtures.restore()
	CarFixtures.restore()
	Config.reset()


func before_each() -> void:
	# Per-test state only: the config knobs these tests flip, and a clean pace/ghost so one
	# test cannot see the previous one's solve.
	Config.data.rival_ghost_enabled = true
	_world._rival_pace = null
	_world._p1_snapshot = {}
	_world._split_boundaries = []


# A rally in progress with a known P1: two classified rivals, the faster one is P1.
func _start_session_with_field(p1_ms: int, p2_ms: int) -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	RallySession._opponent_field = [
		{"name": "Quick", "car_id": "fx_light_rwd", "engine_id": "", "car_name": "Quick Car",
			"event_times_ms": [p1_ms, p1_ms, p1_ms], "dnf": false, "combined_ms": p1_ms * 3,
			"wreck_event": -1, "wreck_progress": 0.0, "wreck_side": 1},
		{"name": "Slow", "car_id": "fx_rwd_coupe", "engine_id": "", "car_name": "Slow Car",
			"event_times_ms": [p2_ms, p2_ms, p2_ms], "dnf": false, "combined_ms": p2_ms * 3,
			"wreck_event": -1, "wreck_progress": 0.0, "wreck_side": -1},
	]


# The track dict world.gd would have generated. A real centerline, so the pace solve and
# the turn-boundary conversion both have something honest to work on.
func _track() -> Dictionary:
	# with_pieces because derive_turn_splits reads turn boundaries out of `pieces`; without
	# them phase 1 captures nothing and the split assertions below would be vacuous.
	return TrackFixtures.with_pieces(TrackFixtures.straight_then_arc(300.0, 60.0, PI), 4)


# Phase 1 then phase 2, the same order stage_started drives them in.
func _run_both_phases(track: Dictionary) -> void:
	_world._setup_stage_splits(track, true, Config.data)
	_world._solve_rival_pace()


func test_the_ghost_is_built_and_solved_for_the_leader() -> void:
	# The whole chain: snapshot P1 -> build the node -> solve at GO -> hand over the pace.
	var p1 := 90000
	_start_session_with_field(p1, 120000)
	_run_both_phases(_track())

	assert_not_null(_world._rival_pace, "a pace object exists after GO")
	assert_false(_world._rival_pace.is_degenerate(), "and it is usable")
	assert_almost_eq(_world._rival_pace.total_ms(), p1, 2,
			"solved to P1's own event time, which is what the standings will report")
	assert_not_null(_world._ghost, "the ghost node was built")
	assert_not_null(_world._ghost.pace, "and was handed the pace at GO, not before")

func test_the_ghost_drives_the_leaders_car_not_the_runner_ups() -> void:
	# The fidelity requirement, through the real wiring rather than a unit seam.
	_start_session_with_field(90000, 120000)
	_run_both_phases(_track())
	assert_eq(String(_world._p1_snapshot.get("car_id", "")), "fx_light_rwd",
			"the snapshot is the fastest classified rival's row")
	# CarProp.spawn's engine_id branch also needs `index`; without it every ghost is
	# silently catalogue car 0 regardless of who P1 is. car.gd has no model-id getter, so
	# assert via mass, which apply_car copies off the catalogue entry — and which differs
	# between P1's car and the runner-up's.
	var p1_meta := CarLibrary.by_id("fx_light_rwd")
	var other_meta := CarLibrary.by_id("fx_rwd_coupe")
	assert_ne(float(p1_meta["mass"]), float(other_meta["mass"]),
			"the two fixture cars differ in mass, so this assertion can discriminate")
	if _world._ghost != null and _world._ghost.car != null:
		assert_almost_eq(float(_world._ghost.car.mass), float(p1_meta["mass"]), 1.0,
				"the spawned ghost wears P1's car, not catalogue car 0")

func test_a_wrecked_leader_is_skipped_for_the_next_fastest() -> void:
	# -1 marks a DNF/wreck for that event. The ghost must never be a rival whose car is
	# simultaneously staged as a roadside wreck.
	_start_session_with_field(90000, 120000)
	RallySession._opponent_field[0]["event_times_ms"] = [-1, -1, -1]
	_run_both_phases(_track())
	assert_eq(int(_world._p1_snapshot.get("time_ms", -1)), 120000,
			"ghosts the next fastest classified rival")

func test_no_classified_rival_means_no_ghost_and_no_error() -> void:
	_start_session_with_field(90000, 120000)
	for opp in RallySession._opponent_field:
		opp["event_times_ms"] = [-1, -1, -1]
	_run_both_phases(_track())
	assert_null(_world._rival_pace, "no pace when nobody has a time")
	assert_true(_world._p1_snapshot.is_empty(), "and no snapshot")

func test_the_split_popup_is_wired_from_the_same_pace() -> void:
	# One pace model for the HUD delta and the ghost, so they cannot disagree.
	_start_session_with_field(90000, 120000)
	_run_both_phases(_track())
	assert_gt(_world._split_boundaries.size(), 0,
			"turn boundaries were captured in phase 1")
	assert_not_null(_world._rival_pace, "and the popup's times come from the pace object")

func test_the_pace_is_built_even_with_the_ghost_visual_disabled() -> void:
	# The popup runs on every session run, so the shared pace must NOT be gated on the
	# ghost's display flag — otherwise turning the ghost off silently kills the delta popup.
	Config.data.rival_ghost_enabled = false
	_start_session_with_field(90000, 120000)
	_run_both_phases(_track())
	assert_not_null(_world._rival_pace, "pace still solved with the ghost switched off")
	assert_null(_world._ghost, "but no ghost node was built")

func test_posing_through_the_real_wiring_does_not_error() -> void:
	# The countdown-hits-zero crash class: this drives the ghost the way _process does,
	# against the world's real TrackProgress and terrain, which is where the wrong-arity
	# wheel-settle callback blew up.
	_start_session_with_field(90000, 120000)
	_run_both_phases(_track())
	if _world._ghost == null or _world._ghost.car == null:
		pass_test("no ghost car built in this configuration")
		return
	for i in 10:
		_world._ghost.pose_at(float(i) * 3.0, 0.016)
	assert_true(is_finite(_world._ghost.car.global_position.y),
			"the ghost holds a finite pose across the run")

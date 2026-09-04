extends GutTest
# The ROGUELIKE REGION RUN — `RunSession` driven through `RegionRunMode`
# (scripts/run_session.gd + scripts/region_run_mode.gd, todo/roguelike-pivot.md
# stage 3). Driven directly against a throwaway Save profile, mirroring
# test_challenge_session.gd — no scene loads, no real driving.
#
# What this file pins is the LOGIC, never the tuning. `target_pace`, the money base,
# the growth exponent and the region scale are all `GameConfig` values a designer
# retunes in the inspector, so every assertion below is a RELATIONSHIP or a
# derivation that survives any reasonable setting of them. The stages come from a
# synthetic rally catalogue, so no authored rally or region is depended on either.

const TEST_PATH := "user://test_region_run_profile.json"
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

const REGION := "fx_run_region"
const RUN_SEED := 20260904

var _save: Node


func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	RallyLibrary.override_for_test(_rallies())
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	RunSession.auto_load_scenes = false
	_leave_run()


func after_each() -> void:
	_leave_run()
	RunSession.auto_load_scenes = true
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	RallyLibrary.reset()
	CarFixtures.restore()
	Config.reset()


func _leave_run() -> void:
	RunSession.pause_run()
	if _save != null:
		_save.profile[Save.KEY_RUN] = {}


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _grant(model := "fx_light_rwd") -> Dictionary:
	return _save.grant_car(model)


# Enough synthetic events to fill an 8-stage run with no repeats.
func _rallies() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in 4:
		var events: Array = []
		for j in 3:
			events.append({
				"seed": 5000 + i * 10 + j, "turn_count": 8, "forestiness": 0.4,
				"surface_mix": 0.5, "straightness": 0.6, "cliffiness": 0.3,
				"water_level": -50.0, "terrain_layer1_amplitude": 12.0,
			})
		out.append({
			"id": "fx_run_%d" % i, "name": "Fixture Run %d" % i, "region": REGION,
			"difficulty": 1 + i, "special": false, "restriction": {},
			"map_pos": Vector2(0.5, 0.5), "events": events,
		})
	return out


# A synthetic track for the target-time solve. A real generated result is not needed
# — LapTimeModel reads the centerline and nothing else off the dict.
func _track() -> Dictionary:
	return TrackFixtures.straight_then_arc(300.0, 45.0, PI)


# Start a region run and seat the first stage's target from `_track()`.
func _start(seed_value := RUN_SEED) -> Dictionary:
	var car := _grant()
	assert_true(RunSession.start_region(REGION, car, seed_value), "setup: the run starts")
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())
	return car


# Drive the current stage in `elapsed_ms` and, if the run continues, boot the next.
func _drive(elapsed_ms: int) -> void:
	RunSession.report_event_result(elapsed_ms)
	if RunSession.is_active():
		RunSession.continue_to_next_stage()
		@warning_ignore("return_value_discarded")
		RunSession.set_stage_track(_track())


# --- Starting and persisting ---------------------------------------------------

func test_a_region_run_starts_at_stage_zero_and_persists_immediately() -> void:
	var car := _start()
	assert_true(RunSession.is_active())
	assert_eq(RunSession.mode_id(), RunMode.REGION)
	assert_eq(RunSession.region_id(), REGION)
	assert_eq(RunSession.events_completed(), 0)
	assert_eq(RunSession.stage_count(), RegionRunMode.STAGE_COUNT)

	var run: Dictionary = _save.profile[Save.KEY_RUN]
	assert_false(run.is_empty(), "the run is persisted right away, so a quit still resumes")
	assert_eq(String(run["mode"]), RunMode.REGION)
	assert_eq(String(run["region_id"]), REGION)
	assert_eq(int(run["car_instance_id"]), int(car["instance_id"]))
	assert_eq(int(run["stage_index"]), 0)


func test_the_run_locks_its_car_through_the_shared_car_lock_predicate() -> void:
	var car := _start()
	assert_true(_save.is_challenge_locked(int(car["instance_id"])),
		"the car lock covers a region run, not just a challenge")
	assert_true(DrivingContext.is_car_locked(int(car["instance_id"])),
		"…and the UI-facing question agrees with it")


func test_a_paused_region_run_resumes_with_the_identical_stage_list() -> void:
	_start()
	var before := RunSession.current_stage_params().duplicate(true)
	RunSession.pause_run()
	assert_false(RunSession.is_active(), "setup: paused")

	assert_true(RunSession.resume(int(Time.get_unix_time_from_system())),
		"a stored region run always resumes — only a challenge can go stale")
	assert_eq(RunSession.current_stage_params(), before,
		"the persisted run seed re-derives the very same stage")


# --- One run slot (decision 27) -------------------------------------------------

func test_starting_a_region_run_discards_a_paused_challenge_run() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(RunSession.start(ChallengeLibrary.DAILY, _grant(), t), "setup: a challenge run")
	RunSession.pause_run()
	assert_false((_save.profile[Save.KEY_RUN] as Dictionary).is_empty(),
		"setup: the paused challenge run is stored")

	assert_true(RunSession.start_region(REGION, _grant(), RUN_SEED))
	var run: Dictionary = _save.profile[Save.KEY_RUN]
	assert_eq(String(run["mode"]), RunMode.REGION,
		"the one run slot now holds the region run — the paused challenge is gone")
	assert_false(run.has("period_key"),
		"and none of the challenge run's own fields survive in it")


func test_starting_a_challenge_run_discards_a_paused_region_run() -> void:
	_start()
	RunSession.pause_run()
	assert_true(RunSession.start(ChallengeLibrary.DAILY, _grant(),
		int(Time.get_unix_time_from_system())))
	var run: Dictionary = _save.profile[Save.KEY_RUN]
	assert_eq(String(run["mode"]), RunMode.CHALLENGE, "the slot holds the challenge now")
	assert_false(run.has("region_id"), "and the region run is gone from it")


# --- The fixed timer (decisions 11 and 22) --------------------------------------

func test_the_target_is_the_reference_cars_optimum_scaled_by_the_pace() -> void:
	# THE point of decision 11: the clock is solved against CarPerformance.REFERENCE_CAR,
	# so it is a property of the STAGE — identical for every player and every car — and
	# buying a faster car makes the clock easier instead of raising the bar to match.
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	var track := _track()
	var event: Dictionary = mode.stages()[0]
	var optimum := LapTimeModel.optimum_ms(track, CarPerformance.REFERENCE_CAR, event)
	assert_gt(optimum, 0, "setup: the fixture track solves to a real time")
	assert_eq(mode.stage_target_ms(0, track),
		int(round(float(optimum) * mode.target_pace(0))),
		"target = reference-car optimum x target_pace, and nothing else")


func test_the_clock_never_loosens_later_in_a_run() -> void:
	# Relationship only — the step is a tunable, and 0 (a flat run) is a legal setting.
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	var previous := mode.target_pace(0)
	for i in range(1, RegionRunMode.STAGE_COUNT):
		var pace := mode.target_pace(i)
		assert_true(pace <= previous, "stage %d's pace is no looser than stage %d's" % [i, i - 1])
		previous = pace


func test_the_pace_never_demands_a_time_under_the_optimum() -> void:
	# A pace below 1.0 asks for a time the point-mass solve itself could not set. The
	# floor exists so no combination of stage and region steps can get there.
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	for i in range(0, RegionRunMode.STAGE_COUNT):
		assert_gt(mode.target_pace(i), 0.0, "the pace stays positive at stage %d" % i)
	assert_true(mode.target_pace(RegionRunMode.STAGE_COUNT * 10) >= Config.data.run_target_pace_min,
		"the floor holds however far the ramp is pushed")


func test_a_track_that_did_not_solve_yields_no_target_rather_than_an_unwinnable_one() -> void:
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	assert_eq(mode.stage_target_ms(0, {}), 0, "no track, no clock")
	assert_false(mode.stage_failed(0, 999_999_999, 0),
		"and a run with no clock can never be failed by one")


# --- The one fail state (decision 4) --------------------------------------------

func test_missing_the_target_ends_the_run_on_the_spot() -> void:
	_start()
	var target := RunSession.stage_target_ms()
	assert_gt(target, 0, "setup: the stage has a clock")
	assert_true(RunSession.stage_count() > 2, "setup: this is NOT the last stage")

	RunSession.report_event_result(target + 1)
	assert_false(RunSession.is_active(), "the run is over the moment the target is missed")
	assert_true(RunSession.failed(), "…and it is recorded as a failure, not a completion")
	assert_false(bool(RunSession.last_result()["completed"]))
	assert_true((_save.profile[Save.KEY_RUN] as Dictionary).is_empty(),
		"the run slot is cleared — a failed run is not resumable")


func test_beating_the_target_carries_the_run_into_the_next_stage() -> void:
	_start()
	var target := RunSession.stage_target_ms()
	_drive(target - 1)
	assert_true(RunSession.is_active(), "the run continues")
	assert_false(RunSession.failed())
	assert_eq(RunSession.events_completed(), 1, "…on the next stage")


func test_a_full_run_completes_after_its_last_stage() -> void:
	_start()
	for _i in RegionRunMode.STAGE_COUNT:
		_drive(maxi(1, RunSession.stage_target_ms() - 1))
	assert_false(RunSession.is_active(), "the run ends after the final stage")
	assert_false(RunSession.failed(), "…as a completion, not a failure")
	var result := RunSession.last_result()
	assert_true(bool(result["completed"]))
	assert_eq(int(result["stages_completed"]), RegionRunMode.STAGE_COUNT)
	assert_eq((result["stage_times_ms"] as Array).size(), RegionRunMode.STAGE_COUNT,
		"every stage banked a time")


func test_a_challenge_stage_has_no_clock_and_can_never_be_failed() -> void:
	# Decision 15 keeps the challenge, and it is scored by cumulative time on a cloud
	# board — a slow stage costs placing, never the run.
	var t := int(Time.get_unix_time_from_system())
	assert_true(RunSession.start(ChallengeLibrary.WEEKLY, _grant(), t), "setup")
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())
	assert_eq(RunSession.stage_target_ms(), 0, "a challenge stage carries no target")
	RunSession.report_event_result(999_999_999)
	assert_true(RunSession.is_active(), "an absurdly slow challenge stage does not end the run")
	assert_false(RunSession.failed())


# --- Money (decisions 14, 21, 31, 36) -------------------------------------------

func test_money_banks_at_stage_clear_not_at_run_end() -> void:
	_start()
	assert_eq(_save.money(), 0, "setup: a fresh profile is broke")
	_drive(maxi(1, RunSession.stage_target_ms() - 1))
	assert_true(RunSession.is_active(), "setup: the run is still going")
	assert_gt(_save.money(), 0, "the cleared stage paid out immediately")


func test_a_failed_run_keeps_every_penny_it_earned() -> void:
	# Soft permadeath destroys the RUN — stage progress, boosts, damage — and never
	# the wallet (decision 14).
	_start()
	_drive(maxi(1, RunSession.stage_target_ms() - 1))
	var banked: int = _save.money()
	assert_gt(banked, 0, "setup: stage 1 paid")

	RunSession.report_event_result(RunSession.stage_target_ms() + 1)
	assert_false(RunSession.is_active(), "setup: the run died on stage 2")
	assert_eq(_save.money(), banked, "the failed stage takes nothing back")


func test_the_stage_that_misses_the_target_pays_nothing() -> void:
	_start()
	RunSession.report_event_result(RunSession.stage_target_ms() + 1)
	assert_eq(_save.money(), 0, "a stage that was not CLEARED is not a stage clear")


func test_a_faster_clear_is_never_worth_less_than_a_slower_one() -> void:
	# The fast-completion bonus is proportional to the time saved. Relationship only:
	# a zero bonus (the designer switching it off) leaves these equal, not inverted.
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	var target := 100_000
	var quick := mode.stage_money(0, 50_000, target)
	var late := mode.stage_money(0, target - 1, target)
	assert_true(quick >= late, "saving more time pays at least as well")


func test_the_run_reports_what_it_banked() -> void:
	_start()
	_drive(maxi(1, RunSession.stage_target_ms() - 1))
	assert_eq(RunSession.money_earned(), _save.money(),
		"the run's own tally agrees with what reached the profile")

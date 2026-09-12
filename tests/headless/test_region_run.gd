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
	RegionStageLibrary.override_for_test(_regions())
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	# A known baseline for the money tests below: decision 28 seeds a fresh profile from
	# GameConfig.run_starting_money rather than 0, so "starts broke" is set explicitly here
	# instead of assumed from a fresh profile's default.
	_save.profile[Save.KEY_MONEY] = 0
	RunSession.auto_load_scenes = false
	_leave_run()


func after_each() -> void:
	_leave_run()
	RunSession.auto_load_scenes = true
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	RegionStageLibrary.reset()
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


# Push a car's HP well below run_boost_healthy_threshold, HOWEVER that tunable is
# set — half of it, never a hardcoded HP number — so a test can rely on the pending
# pick offering repair (the non-reward branch) regardless of where a designer tunes
# the threshold.
func _damage_below_threshold(car: Dictionary) -> void:
	var iid := int(car["instance_id"])
	var hp: float = float(_save.get_car(iid)["hp"])
	_save.apply_damage(iid, hp * (1.0 - Config.data.run_boost_healthy_threshold * 0.5))


# A synthetic region shaped like the real RegionStageLibrary: 8 slots x 3 candidates,
# enough to fill an 8-stage run with no repeats.
func _regions() -> Dictionary:
	var slots: Array = []
	for slot_index in 8:
		var candidates: Array = []
		for c in 3:
			candidates.append({
				"seed": 5000 + slot_index * 10 + c, "turn_count": 8, "forestiness": 0.4,
				"surface_mix": 0.5, "straightness": 0.6, "cliffiness": 0.3,
				"water_level": -50.0, "terrain_layer1_amplitude": 12.0,
			})
		slots.append(candidates)
	return {REGION: slots}


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
#
# A region run's non-final, non-missed clear now offers a between-stage PICK instead
# of repairing automatically (stage 5) — continue_to_next_stage() refuses to advance
# while one is outstanding. Every test using this helper just wants the run to keep
# moving, so it resolves the pick with the repair (an arbitrary, consistent choice;
# tests that care about the CHOICE itself drive report_event_result/choose_* directly
# instead of going through this helper).
func _drive(elapsed_ms: int) -> void:
	RunSession.report_event_result(elapsed_ms)
	if RunSession.pick_awaiting():
		# Repair may not be on offer (the undamaged-arrival reward pick, Task 2) — fall
		# back to taking the first boost so the run keeps moving either way. This
		# helper only cares about advancing, never about which pick mechanic resolved.
		if RunSession.offer_repair():
			RunSession.choose_repair()
		else:
			var pick: Array = RunSession.pending_pick()
			RunSession.choose_boost(String((pick[0] as Dictionary).get("id", "")))
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


# --- The rival ghost's pace-scaled profile (features/rival-ghost.md) ------------

func test_stage_target_profile_last_sample_matches_stage_target_ms() -> void:
	# stage_target_ms and stage_target_profile each round once at their own single
	# scalar (see region_run_mode.gd's comment on why they don't chain), so this is a
	# within-a-millisecond agreement check rather than an exact one: the rival ghost's
	# pace line and the fixed clock it's shown visualising can never drift apart by
	# more than a rounding step.
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	var track := _track()
	var profile := mode.stage_target_profile(0, track)
	var t: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	assert_false(t.is_empty(), "setup: the fixture track solves to a real profile")
	assert_almost_eq(int(round(float(t[t.size() - 1]) * 1000.0)), mode.stage_target_ms(0, track), 1,
		"the profile's last (pace-scaled) sample IS the ms target, within a rounding step")


func test_stage_target_profile_scales_every_sample_by_the_same_pace() -> void:
	# Not just the total: RegionRunMode's whole point is that a rival driving this
	# profile can be POSED along the track mid-stage, so every intermediate sample —
	# not only the last one — must carry the same pace multiplier as the total.
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	var track := _track()
	var event: Dictionary = mode.stages()[0]
	var raw := LapTimeModel.optimum_profile(track, CarPerformance.REFERENCE_CAR, event)
	var raw_t: PackedFloat32Array = raw.get("t", PackedFloat32Array())
	var profile := mode.stage_target_profile(0, track)
	var scaled_t: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	assert_eq(scaled_t.size(), raw_t.size(), "setup: same sample count as the raw solve")
	var pace := mode.target_pace(0)
	for i in raw_t.size():
		assert_almost_eq(float(scaled_t[i]), float(raw_t[i]) * pace, 0.01,
			"sample %d scaled by the same target_pace() the total uses" % i)


func test_stage_target_profile_empty_for_a_degenerate_track() -> void:
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	assert_eq(mode.stage_target_profile(0, {}), {}, "no track, no profile — matches stage_target_ms")


func test_run_session_seats_the_profile_alongside_the_target() -> void:
	_start()
	var profile := RunSession.stage_target_profile()
	var t: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	assert_false(t.is_empty(), "set_stage_track seats a real profile for a solvable track")
	assert_almost_eq(int(round(float(t[t.size() - 1]) * 1000.0)), RunSession.stage_target_ms(), 1,
		"RunSession's seated profile agrees with its own seated ms target, within a rounding step")


func test_challenge_run_mode_has_no_target_profile() -> void:
	# ChallengeRunMode never overrides stage_target_profile (only RegionRunMode does),
	# so it falls through to RunMode's base {} — matching its stage_target_ms's own 0,
	# i.e. a challenge run has no rival to visualise, on top of having no clock.
	var mode := ChallengeRunMode.for_kind(ChallengeLibrary.DAILY, 1_700_000_000)
	assert_not_null(mode, "setup: a daily challenge mode builds")
	assert_eq(mode.stage_target_profile(0, _track()), {},
		"a challenge run has no target clock, so no rival profile either")


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
	assert_eq(_save.money(), 0, "setup: zeroed in before_each")
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


# --- Coins (decisions 13, 35, 36, 50) --------------------------------------------

func test_coins_collected_never_pay_less_than_none() -> void:
	# Relationship only (CLAUDE.md) — GameConfig.coin_money is a tunable a designer
	# could zero out, which would make more coins pay the SAME, never less.
	var mode := RegionRunMode.new(REGION, RUN_SEED)
	var target := 100_000
	var none := mode.stage_money(0, 50_000, target, 0)
	var some := mode.stage_money(0, 50_000, target, 3)
	assert_true(some >= none, "collecting coins never pays worse than collecting none")


func test_coin_money_banks_with_the_stage_that_cleared_it() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1), 0.0, 2)
	if RunSession.pick_awaiting():
		RunSession.choose_repair()
	assert_gt(_save.money(), 0, "a cleared stage with coins pays out, coins included")


func test_a_missed_stages_coins_pay_no_money() -> void:
	# Decision 36 — the coin GAMBLE (leaving the line, decision 35) is lost along
	# with everything else on a missed stage; only a CLEARED stage's coins bank.
	_start()
	RunSession.report_event_result(RunSession.stage_target_ms() + 1, 0.0, 5)
	assert_eq(_save.money(), 0, "no money banks for a stage that missed its target")


func test_a_missed_stages_coins_still_count_toward_the_lifetime_ledger() -> void:
	# The lifetime stat is a driving-skill record (a real detour was taken), separate
	# from the money it would have paid — mirrors DAMAGE_TAKEN, written unconditionally.
	_start()
	var before: int = _save.lifetime_stat(LifetimeStats.COINS_COLLECTED)
	RunSession.report_event_result(RunSession.stage_target_ms() + 1, 0.0, 5)
	assert_eq(_save.lifetime_stat(LifetimeStats.COINS_COLLECTED), before + 5,
		"coins picked up before a missed target still count as collected")


func test_zero_coins_collected_never_regresses_the_lifetime_ledger() -> void:
	_start()
	var before: int = _save.lifetime_stat(LifetimeStats.COINS_COLLECTED)
	_drive(maxi(1, RunSession.stage_target_ms() - 1))
	assert_eq(_save.lifetime_stat(LifetimeStats.COINS_COLLECTED), before,
		"report_event_result's default coins_collected (0) writes nothing")


# --- Distance driven (stage 9) --------------------------------------------------
#
# world.gd snapshots TrackProgress.progress_offset() at the finish crossing and passes it
# here. Counted on EVERY stage, missed ones included — the metres were driven either way,
# exactly like DAMAGE_TAKEN and COINS_COLLECTED.

func test_distance_driven_is_added_to_the_lifetime_ledger() -> void:
	_start()
	var before: int = _save.lifetime_stat(LifetimeStats.DISTANCE_DRIVEN_M)
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1), 0.0, 0, 1234.6)
	assert_eq(_save.lifetime_stat(LifetimeStats.DISTANCE_DRIVEN_M), before + 1235,
		"metres are rounded to the nearest whole point, like every other int ledger")


func test_a_missed_stages_distance_still_counts() -> void:
	_start()
	var before: int = _save.lifetime_stat(LifetimeStats.DISTANCE_DRIVEN_M)
	RunSession.report_event_result(RunSession.stage_target_ms() + 1, 0.0, 0, 900.0)
	assert_eq(_save.lifetime_stat(LifetimeStats.DISTANCE_DRIVEN_M), before + 900,
		"a stage that missed its target was still driven")


func test_no_distance_reported_never_regresses_the_ledger() -> void:
	_start()
	var before: int = _save.lifetime_stat(LifetimeStats.DISTANCE_DRIVEN_M)
	_drive(maxi(1, RunSession.stage_target_ms() - 1))
	assert_eq(_save.lifetime_stat(LifetimeStats.DISTANCE_DRIVEN_M), before,
		"the default distance_m (0.0) writes nothing")


# --- The between-stage pick: repair competes with a boost (stage 5) --------------

func test_clearing_a_non_final_stage_offers_a_pick_instead_of_auto_repairing() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	assert_true(RunSession.is_active(), "setup: the run continues")
	assert_true(RunSession.pick_awaiting(), "a cleared non-final stage offers a pick")
	assert_false(RunSession.pending_pick().is_empty(), "…of at least one boost")
	assert_true(RunSession.take_pending_repair().is_empty(),
		"repair is no longer applied automatically — it's one of the offered picks")


func test_continue_to_next_stage_refuses_while_a_pick_is_awaiting() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	assert_true(RunSession.pick_awaiting(), "setup: a pick is outstanding")
	var stage_before := RunSession.events_completed()

	RunSession.continue_to_next_stage()

	assert_eq(RunSession.events_completed(), stage_before,
		"the run does not advance until the pick is resolved")
	assert_true(RunSession.is_active(), "…and stays active, not stuck or ended")


func test_choosing_repair_fully_repairs_the_car() -> void:
	var car := _start()
	_damage_below_threshold(car)  # below the healthy-arrival threshold: repair is on offer
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	assert_true(RunSession.offer_repair(), "setup: repair is offered on a damaged car")

	RunSession.choose_repair()

	assert_false(RunSession.pick_awaiting(), "the pick is resolved")
	assert_true(RunSession.pending_pick().is_empty())
	var repair := RunSession.take_pending_repair()
	assert_false(repair.is_empty(), "choosing repair leaves a pending repair summary")
	assert_almost_eq(float(repair["hp_after"]), float(repair["max_hp"]), 0.01,
		"choosing repair (over an upgrade) fully restores HP, not a partial patch-up")
	var iid := int(car["instance_id"])
	for v in _save.get_car(iid)["wheel_toe"]:
		assert_almost_eq(float(v), 0.0, 0.001, "every wheel is fully straightened")
	RunSession.continue_to_next_stage()
	assert_eq(RunSession.events_completed(), 1, "and the run now advances")


func test_choosing_a_boost_records_it_on_the_run_and_takes_no_repair() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var offered: Array = RunSession.pending_pick()
	var id := String((offered[0] as Dictionary)["id"])

	RunSession.choose_boost(id)

	assert_false(RunSession.pick_awaiting())
	assert_true(RunSession.take_pending_repair().is_empty(),
		"taking a boost costs the repair, not the other way round")
	var picked_ids: Array = []
	for b in RunSession.boosts():
		picked_ids.append(String((b as Dictionary)["id"]))
	assert_true(picked_ids.has(id), "the chosen boost is recorded on the run")


# A non-stacking pick ("gearbox" — an absolute shift time, a dead repeat) drops out of
# the NEXT pool once taken; a stacking pick ("grip" — a multiplier that compounds)
# stays offered, since a second one genuinely does more.
func test_a_non_stacking_boost_is_not_offered_again_after_being_picked() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	RunSession.choose_boost("gearbox")
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))

	var ids: Array = []
	for entry in RunSession.pending_pick():
		ids.append(String((entry as Dictionary).get("id", "")))
	assert_false(ids.has("gearbox"), "a repeat of a non-stacking boost is a dead roll, so it's excluded")


func test_a_stacking_boost_is_still_offered_after_being_picked() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	RunSession.choose_boost("grip")
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))

	var ids: Array = []
	for entry in RunSession.pending_pick():
		ids.append(String((entry as Dictionary).get("id", "")))
	assert_true(ids.has("grip"), "a stacking boost genuinely does more the second time, so it stays offered")


func test_a_boost_pick_never_reaches_the_persisted_car() -> void:
	var car := _start()
	var iid := int(car["instance_id"])
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var offered: Array = RunSession.pending_pick()

	RunSession.choose_boost(String((offered[0] as Dictionary)["id"]))

	assert_false(_save.get_car(iid).has("boosts"),
		"a run's boosts are RUN state, never written to Save's persisted car")


func test_a_resumed_run_re_offers_the_identical_pick() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var before: Array = RunSession.pending_pick()

	RunSession.pause_run()
	assert_true(RunSession.resume(int(Time.get_unix_time_from_system())))

	assert_true(RunSession.pick_awaiting(), "the pick survives a pause/resume")
	assert_eq(RunSession.pending_pick(), before,
		"a resumed run offers the identical choice it offered before")


func test_boosts_do_not_survive_a_completed_run() -> void:
	_start()
	for _i in RegionRunMode.STAGE_COUNT:
		RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
		if RunSession.pick_awaiting():
			var offered: Array = RunSession.pending_pick()
			RunSession.choose_boost(String((offered[0] as Dictionary)["id"]))
		if RunSession.is_active():
			RunSession.continue_to_next_stage()
			@warning_ignore("return_value_discarded")
			RunSession.set_stage_track(_track())
	assert_false(RunSession.is_active(), "setup: the run completed")
	assert_true(bool(RunSession.last_result()["completed"]))
	assert_true(RunSession.boosts().is_empty(),
		"every picked boost is wiped the moment the run ends, even a win")


func test_boosts_do_not_survive_a_failed_run() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var offered: Array = RunSession.pending_pick()
	RunSession.choose_boost(String((offered[0] as Dictionary)["id"]))
	assert_false(RunSession.boosts().is_empty(), "setup: a boost was picked")
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.report_event_result(RunSession.stage_target_ms() + 1)  # miss the target

	assert_false(RunSession.is_active(), "setup: the run failed")
	assert_true(RunSession.boosts().is_empty(),
		"a failed run wipes its boosts too — soft permadeath, not just the loss")


func test_a_fresh_run_starts_with_no_boosts_from_a_previous_one() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var offered: Array = RunSession.pending_pick()
	RunSession.choose_boost(String((offered[0] as Dictionary)["id"]))
	assert_false(RunSession.boosts().is_empty(), "setup: a boost was picked")
	# The pick has to be RESOLVED AND ADVANCED before the next stage can be reported:
	# continue_to_next_stage() refuses while a pick is awaiting, and the next stage needs
	# its own track before it has a target to miss. Reporting straight through leaves the
	# session mid-stage, and the run never actually ends.
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.report_event_result(RunSession.stage_target_ms() + 1)  # fail the run
	assert_false(RunSession.is_active(), "setup: the run failed")

	_start()

	assert_true(RunSession.boosts().is_empty(), "a new run never inherits the last one's boosts")


# --- The between-stage pick: a drivetrain conversion, superseding decision 52 ----------
#
# Decision 52 sold a drivetrain conversion as a permanent per-car purchase. That is
# superseded: a conversion is now offered in the SAME between-stage pick as repair and the
# drawn boosts — run-scoped, free, and gone when the run ends, exactly like a boost.

func test_a_pending_pick_offers_every_non_current_drivetrain_layout() -> void:
	var car := _start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	assert_true(RunSession.pick_awaiting(), "setup: a pick is outstanding")
	var stock := UpgradeLibrary.stock_drive_mode(_save.get_car(int(car["instance_id"])))
	var choices: Array = RunSession.drivetrain_choices()
	assert_false(choices.has(stock), "the car's own current layout is not offered")
	assert_eq(choices.size(), Drivetrain.DriveMode.values().size() - 1,
		"every OTHER layout is offered")


func test_an_available_awd_conversion_competes_in_the_same_pool_as_boosts() -> void:
	# fx_light_rwd (the default _grant() fixture) is not AWD, so an AWD conversion is
	# available — RunSession folds it into the SAME pool as the boost catalogue
	# (RunSession._pool_drivetrain_ids, region_run_mode.gd boost_pool_ids) rather than
	# appending it on top of a draw: the pool is now the WHOLE catalogue plus whatever
	# extras are available (todo/mid-run-upgrade-menu.md), so its size is exactly the
	# catalogue's own size plus one AWD entry — never a random subset.
	var car := _start()  # a fresh car is at full health -> the undamaged-arrival reward pick
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var stock := UpgradeLibrary.stock_drive_mode(_save.get_car(int(car["instance_id"])))
	assert_ne(stock, Drivetrain.DriveMode.AWD, "setup: AWD conversion is available")
	var pending_pick_now: Array = RunSession.pending_pick()
	var extras := RunSession._pool_engine_swap_ids().size()
	assert_eq(pending_pick_now.size(), BoostLibrary.CATALOGUE.size() + 1 + extras,
		"the whole catalogue plus the one AWD conversion (plus any engine swap available)")
	var drivetrain_seen := 0
	for entry in pending_pick_now:
		var id := String((entry as Dictionary).get("id", ""))
		if id.begins_with("drivetrain:"):
			drivetrain_seen += 1
			assert_eq(int((entry as Dictionary)["drivetrain_mode"]), Drivetrain.DriveMode.AWD,
				"the only drivetrain conversion ever offered in the pool is AWD")
	assert_eq(drivetrain_seen, 1, "the AWD conversion appears exactly once")


func test_choosing_a_drivetrain_conversion_resolves_the_pick_and_takes_no_repair() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var choices: Array = RunSession.drivetrain_choices()
	var mode := int(choices[0])

	RunSession.choose_drivetrain(mode)

	assert_false(RunSession.pick_awaiting(), "the pick is resolved")
	assert_true(RunSession.take_pending_repair().is_empty(),
		"taking a conversion costs the repair, not the other way round")
	assert_eq(RunSession.drivetrain_override(), mode, "the chosen layout is recorded on the run")


func test_a_drivetrain_conversion_never_reaches_the_persisted_car() -> void:
	var car := _start()
	var iid := int(car["instance_id"])
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var mode := int(RunSession.drivetrain_choices()[0])

	RunSession.choose_drivetrain(mode)

	assert_false(_save.get_car(iid).has("drivetrain_override"),
		"a run's conversion is RUN state, never written to Save's persisted car")


func test_a_later_conversion_replaces_the_earlier_one_rather_than_stacking() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var first := int(RunSession.drivetrain_choices()[0])
	RunSession.choose_drivetrain(first)
	assert_eq(RunSession.drivetrain_override(), first, "setup: the first pick is recorded")
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var second := int(RunSession.drivetrain_choices()[0])
	RunSession.choose_drivetrain(second)

	assert_eq(RunSession.drivetrain_override(), second,
		"the run only ever runs ONE layout at a time — the latest pick wins")


func test_drivetrain_conversion_does_not_survive_a_completed_or_failed_run() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	RunSession.choose_drivetrain(int(RunSession.drivetrain_choices()[0]))
	assert_ne(RunSession.drivetrain_override(), -1, "setup: a conversion was picked")
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.report_event_result(RunSession.stage_target_ms() + 1)  # fail the run

	assert_false(RunSession.is_active(), "setup: the run failed")
	assert_eq(RunSession.drivetrain_override(), -1,
		"a failed run wipes its conversion too — soft permadeath, not just the loss")


func test_a_resumed_run_keeps_its_picked_drivetrain_conversion() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var mode := int(RunSession.drivetrain_choices()[0])
	RunSession.choose_drivetrain(mode)
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.pause_run()
	assert_true(RunSession.resume(int(Time.get_unix_time_from_system())))

	assert_eq(RunSession.drivetrain_override(), mode,
		"the picked layout survives a pause/resume, same as boosts")


# --- The between-stage pick: an engine swap -------------------------------------------
#
# Mirrors the drivetrain-conversion section above: a genuine EngineLibrary swap offered
# in the SAME between-stage pick pool, deterministic (the next most powerful engine
# relative to the car's current one), run-scoped, and gone when the run ends.
# CarFixtures installs exactly two engines (fx_i4, fx_v8), with fx_v8 strictly more
# powerful — the default _grant() car (fx_light_rwd) runs fx_i4, so a swap to fx_v8 is
# always available and always the offered id.

func test_the_pool_offers_the_next_most_powerful_engine() -> void:
	_start()
	var ids := RunSession._pool_engine_swap_ids()
	assert_eq(ids.size(), 1, "a strictly more powerful engine exists")
	var offered_id := String(ids[0]).substr("engine_swap:".length())
	var offered := EngineLibrary.by_id(offered_id)
	var current := EngineLibrary.by_id("fx_i4")
	var offered_power := CarLibrary.peak_power_kw(
		{"peak_torque": offered["peak_torque"], "redline": offered["redline_rpm"]})
	var current_power := CarLibrary.peak_power_kw(
		{"peak_torque": current["peak_torque"], "redline": current["redline_rpm"]})
	assert_gt(offered_power, current_power, "the offered engine is strictly more powerful")
	# No catalogue engine sits strictly between the two — the smallest strictly-greater one.
	for eng in EngineLibrary.all():
		var power := CarLibrary.peak_power_kw(
			{"peak_torque": eng["peak_torque"], "redline": eng["redline_rpm"]})
		if power > current_power:
			assert_gte(power, offered_power, "%s is not a smaller strictly-greater engine" % eng["id"])


func test_the_pool_is_empty_once_the_car_already_runs_the_most_powerful_engine() -> void:
	_start()
	var ids := RunSession._pool_engine_swap_ids()
	var offered_id := String(ids[0]).substr("engine_swap:".length())
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	RunSession.choose_engine_swap(offered_id)

	assert_true(RunSession._pool_engine_swap_ids().is_empty(),
		"already running the most powerful catalogue engine -> no swap left to offer")


func test_an_available_engine_swap_competes_in_the_same_pool_as_boosts() -> void:
	var car := _start()  # a fresh car is at full health -> the undamaged-arrival reward pick
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var pending_pick_now: Array = RunSession.pending_pick()
	var extra_drivetrain := RunSession._pool_drivetrain_ids().size()
	assert_eq(pending_pick_now.size(), BoostLibrary.CATALOGUE.size() + 1 + extra_drivetrain,
		"the whole catalogue plus the one engine swap (plus AWD, also available on this car)")
	for entry in pending_pick_now:
		var id := String((entry as Dictionary).get("id", ""))
		if id.begins_with("engine_swap:"):
			assert_eq(id, "engine_swap:fx_v8", "the only engine swap ever offered is the next rung up")
			assert_gt(float((entry as Dictionary).get("hp_delta", 0.0)), 0.0,
				"a swap is only ever offered as a power gain")


func test_choosing_an_engine_swap_resolves_the_pick_and_takes_no_repair() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var offered_id := String(String(RunSession._pool_engine_swap_ids()[0]).substr("engine_swap:".length()))

	RunSession.choose_engine_swap(offered_id)

	assert_false(RunSession.pick_awaiting(), "the pick is resolved")
	assert_true(RunSession.take_pending_repair().is_empty(),
		"taking a swap costs the repair, not the other way round")
	assert_eq(RunSession.engine_swap_id(), offered_id, "the chosen engine is recorded on the run")


func test_an_engine_swap_never_reaches_the_persisted_car() -> void:
	var car := _start()
	var iid := int(car["instance_id"])
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var offered_id := String(String(RunSession._pool_engine_swap_ids()[0]).substr("engine_swap:".length()))

	RunSession.choose_engine_swap(offered_id)

	assert_false(_save.get_car(iid).has("swapped_engine"),
		"a run's swap is RUN state, never written to Save's persisted car")


func test_a_later_engine_swap_replaces_the_earlier_one_rather_than_stacking() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var first := String(String(RunSession._pool_engine_swap_ids()[0]).substr("engine_swap:".length()))
	RunSession.choose_engine_swap(first)
	assert_eq(RunSession.engine_swap_id(), first, "setup: the first pick is recorded")
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	# The pool is now empty (the car already runs the most powerful engine), so a second
	# pick offers no swap option to choose — assert the run keeps exactly one engine
	# recorded rather than stacking, via a direct call mirroring choose_drivetrain's own
	# "the run only ever runs ONE X at a time" test.
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	RunSession.choose_engine_swap(first)  # a stale re-pick of the same id still no-ops cleanly

	assert_eq(RunSession.engine_swap_id(), first,
		"the run only ever runs ONE engine at a time")


func test_engine_swap_does_not_survive_a_completed_or_failed_run() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var offered_id := String(String(RunSession._pool_engine_swap_ids()[0]).substr("engine_swap:".length()))
	RunSession.choose_engine_swap(offered_id)
	assert_ne(RunSession.engine_swap_id(), "", "setup: a swap was picked")
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.report_event_result(RunSession.stage_target_ms() + 1)  # fail the run

	assert_false(RunSession.is_active(), "setup: the run failed")
	assert_eq(RunSession.engine_swap_id(), "",
		"a failed run wipes its swap too — soft permadeath, not just the loss")


func test_a_resumed_run_keeps_its_picked_engine_swap() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	var offered_id := String(String(RunSession._pool_engine_swap_ids()[0]).substr("engine_swap:".length()))
	RunSession.choose_engine_swap(offered_id)
	RunSession.continue_to_next_stage()
	@warning_ignore("return_value_discarded")
	RunSession.set_stage_track(_track())

	RunSession.pause_run()
	assert_true(RunSession.resume(int(Time.get_unix_time_from_system())))

	assert_eq(RunSession.engine_swap_id(), offered_id,
		"the picked engine survives a pause/resume, same as boosts")


# A mid-tier engine that's only a small hp gain over fx_i4 (< MIN_SWAP_HP_GAIN) must be
# skipped over in favour of fx_v8 — a swap that's barely an upgrade isn't worth offering.
func test_the_pool_skips_an_engine_swap_under_the_minimum_hp_gain() -> void:
	var engines := CarFixtures.engines()
	engines.append({
		"id": "fx_i4_plus", "name": "Fixture i4+", "layout": "i4", "displacement_l": 2.1, "mass": 120.0,
		"redline_rpm": 7000.0, "peak_torque": 230.0, "peak_torque_rpm": 4500.0, "engine_inertia": 0.15,
		"low_octave_mix": 0.0, "volume_db": -5.0, "noise_db": -54.0, "soft_clip_post_gain": 0.07,
		"gear_ratios": [3.5, 2.0, 1.4, 1.0, 0.8], "final_drive": 4.0, "shift_time": 0.30,
	})
	EngineLibrary.override_for_test(engines)

	var current := EngineLibrary.by_id("fx_i4")
	var mid := EngineLibrary.by_id("fx_i4_plus")
	var current_hp := CarLibrary.horsepower(
		{"peak_torque": current["peak_torque"], "redline": current["redline_rpm"]})
	var mid_hp := CarLibrary.horsepower(
		{"peak_torque": mid["peak_torque"], "redline": mid["redline_rpm"]})
	assert_lt(mid_hp - current_hp, RunSession.MIN_SWAP_HP_GAIN,
		"setup: fx_i4_plus is a real but too-small gain over fx_i4")

	_start()
	var ids := RunSession._pool_engine_swap_ids()
	assert_eq(ids.size(), 1, "exactly one swap offered")
	assert_eq(String(ids[0]), "engine_swap:fx_v8",
		"the too-small fx_i4_plus rung is skipped in favour of the next one that clears the bar")


# --- Task 1: a new run always starts the car at 100% health ---------------------

func test_beginning_a_run_restores_a_damaged_car_to_full_health() -> void:
	var car := _grant()
	var iid := int(car["instance_id"])
	var max_hp := float(_save.get_car(iid)["hp"])
	_save.apply_damage(iid, max_hp * 0.5)
	assert_lt(float(_save.get_car(iid)["hp"]), max_hp, "setup: the car carries damage in")

	assert_true(RunSession.start_region(REGION, _save.get_car(iid), RUN_SEED))

	assert_almost_eq(float(_save.get_car(iid)["hp"]), max_hp, 0.001,
		"a new run always starts the car at 100% health")


func test_beginning_a_run_on_an_already_full_car_changes_nothing() -> void:
	var car := _grant()
	var iid := int(car["instance_id"])
	var max_hp := float(_save.get_car(iid)["hp"])

	assert_true(RunSession.start_region(REGION, car, RUN_SEED))

	assert_almost_eq(float(_save.get_car(iid)["hp"]), max_hp, 0.001)


# --- Task 2: an undamaged car earns the whole catalogue with no repair row --------
#
# Redesigned per todo/mid-run-upgrade-menu.md: the pool is now always the WHOLE
# catalogue regardless of health (there is no "+1" any more since there's no draw to
# size) — the reward is entirely that the repair option disappears, so every roll lands
# on a real upgrade instead of the usual repair-or-upgrade choice.

func test_a_damaged_car_offers_the_full_pool_and_repair() -> void:
	var car := _start()
	_damage_below_threshold(car)

	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))

	assert_true(RunSession.pick_awaiting())
	assert_true(RunSession.offer_repair(), "below the threshold, repair is still offered")
	assert_eq(RunSession.pending_pick().size(),
		BoostLibrary.CATALOGUE.size() + RunSession._pool_drivetrain_ids().size()
			+ RunSession._pool_engine_swap_ids().size(),
		"the pool is the whole catalogue plus whatever extras are available")


func test_a_healthy_car_offers_the_full_pool_and_no_repair() -> void:
	_start()  # a freshly granted car begin()s at full health (Task 1)

	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))

	assert_true(RunSession.pick_awaiting())
	assert_false(RunSession.offer_repair(),
		"at or above the threshold, the reward pick offers no repair row")
	assert_eq(RunSession.pending_pick().size(),
		BoostLibrary.CATALOGUE.size() + RunSession._pool_drivetrain_ids().size()
			+ RunSession._pool_engine_swap_ids().size(),
		"the pool is the same whole catalogue as the damaged case — the reward is 'no repair', not a bigger pool")


func test_choose_repair_refuses_on_a_pick_that_does_not_offer_repair() -> void:
	_start()  # full health -> the reward pick, no repair on offer
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	assert_false(RunSession.offer_repair(), "setup: repair is not on offer")

	RunSession.choose_repair()

	assert_true(RunSession.pick_awaiting(),
		"choose_repair() refuses rather than silently repairing when it isn't offered")
	assert_true(RunSession.take_pending_repair().is_empty(),
		"…and nothing was applied")


func test_the_pending_pick_never_exceeds_the_catalogue_plus_available_extras() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	assert_true(RunSession.pending_pick().size() <= BoostLibrary.CATALOGUE.size() + 2,
		"the pool never exceeds the catalogue plus (at most) one AWD entry and one engine swap")


# Every id in the pool resolves to a real catalogue boost or a real drivetrain/engine-swap
# pseudo-entry — nothing in the pool names something BoostLibrary.resolve_id can't handle.
func test_every_pending_pick_entry_is_a_real_pool_member() -> void:
	_start()
	RunSession.report_event_result(maxi(1, RunSession.stage_target_ms() - 1))
	for entry in RunSession.pending_pick():
		var id := String((entry as Dictionary).get("id", ""))
		var known := BoostLibrary.CATALOGUE.has(id) \
			or id.begins_with("drivetrain:") or id.begins_with("engine_swap:")
		assert_true(known, "pool entry '%s' is a real catalogue id or pseudo-id" % id)

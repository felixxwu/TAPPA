extends GutTest
# ChallengeSession: the Daily/Weekly/Monthly Rally Challenge orchestrator
# (scripts/challenge_session.gd, spec §3-4-6). Driven directly against a
# throwaway Save profile, mirroring test_rally_session.gd's pattern — no scene
# loads, no real driving.

const TEST_PATH := "user://test_challenge_session_profile.json"
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

var _save: Node


func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	ChallengeSession.auto_load_scenes = false
	_leave_run()


func after_each() -> void:
	_leave_run()
	ChallengeSession.auto_load_scenes = true
	# The free-roam handoff lives on the RallySession autoload, so a test that sets
	# it must not leak it into the next one.
	RallySession.clear_free_roam_handoff()
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()


# Leave any live run WITHOUT ending it (pause_run is the non-terminal path — only a
# wreck DNFs a challenge, item 12), then drop the persisted run so a paused run never
# leaks into the next test.
func _leave_run() -> void:
	ChallengeSession.pause_run()
	if _save != null:
		_save.profile["challenge_run"] = {}


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


func _grant(model := "fx_light_rwd") -> Dictionary:
	return _save.grant_car(model)


# Highest member of the (tunable) ceiling band — used only to place a fixture
# car definitively ABOVE any possible roll, never to assert on the band's
# contents itself.
var CEILING_BAND_MAX: float = ChallengeLibrary.CEILING_BAND_HP_TONNE.max()


# Invert CarLibrary.power_to_weight_hp_tonne's own formula: given the target
# hp/tonne figure a fixture car should read as, solve for the peak_torque that
# produces it at `mass`/`redline` (both fixed and arbitrary) — so the fixture
# exercises the SAME derivation the code under test uses, without pinning any
# authored stat.
func _torque_for_target_hp_tonne(target_hp_tonne: float, mass: float, redline: float) -> float:
	var power_kw := target_hp_tonne / CarLibrary.KW_KG_TO_HP_TONNE * mass
	return power_kw / (redline * (TAU / 60.0) / 1000.0 * CarLibrary.TORQUE_POWER_FALLOFF)


# --- start() ------------------------------------------------------------------

func test_start_fails_when_already_active() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, car, t))
	assert_false(ChallengeSession.start(ChallengeLibrary.DAILY, car, t),
		"a second start is refused while a run is active")


func test_start_succeeds_and_persists_immediately_at_stage_zero() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	assert_true(ChallengeSession.start(ChallengeLibrary.WEEKLY, car, t))
	assert_true(ChallengeSession.is_active())
	assert_eq(ChallengeSession.events_completed(), 0)

	var run: Dictionary = _save.profile["challenge_run"]
	assert_false(run.is_empty(), "the run is persisted to the profile right away")
	assert_eq(int(run["stage_index"]), 0)
	assert_eq(int(run["car_instance_id"]), int(car["instance_id"]))
	assert_eq(String(run["kind"]), ChallengeLibrary.WEEKLY)


# --- resumable_run / has_stale_run ---------------------------------------------

func test_resumable_run_reads_stale_period_as_not_resumable() -> void:
	var t := int(Time.get_unix_time_from_system())
	var profile := {
		"challenge_run": {
			"period_key": "daily:2000-01-01:e%d" % ChallengeLibrary.CHALLENGE_EPOCH,
			"kind": ChallengeLibrary.DAILY, "car_instance_id": 1,
			"stage_index": 0, "stage_times_ms": [], "dnf": false,
		}
	}
	assert_true(ChallengeSession.resumable_run(profile, t).is_empty(),
		"a run whose period has rolled over is not resumable")
	assert_true(ChallengeSession.has_stale_run(profile, t),
		"and is flagged as stale")


func test_resumable_run_reads_current_period_as_resumable() -> void:
	var t := int(Time.get_unix_time_from_system())
	var period := ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)
	var profile := {
		"challenge_run": {
			"period_key": String(period["key"]), "kind": ChallengeLibrary.DAILY,
			"car_instance_id": 1, "stage_index": 0, "stage_times_ms": [], "dnf": false,
		}
	}
	# A later moment still INSIDE the same period stays resumable. Derived from the
	# period's own bounds, never `t + <fixed offset>`: within an hour of the daily
	# rollover a fixed offset lands in the NEXT period, where the run is correctly
	# non-resumable, and the test flaked for that window of every day.
	var later: int = int(period["starts_at"]) + maxi(
		1, (int(period["ends_at"]) - int(period["starts_at"])) / 2)
	assert_gt(later, int(period["starts_at"]) - 1, "setup: the probe is inside the period")
	assert_lt(later, int(period["ends_at"]), "setup: …and before it rolls over")
	assert_false(ChallengeSession.resumable_run(profile, later).is_empty(),
		"a run whose period key still matches is resumable")
	assert_false(ChallengeSession.has_stale_run(profile, later))


func test_has_stale_run_is_false_with_no_run_at_all() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_false(ChallengeSession.has_stale_run({}, t))
	assert_false(ChallengeSession.has_stale_run({"challenge_run": {}}, t))


func test_resume_fails_after_the_run_ended() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(ChallengeLibrary.DAILY, car, t)
	ChallengeSession.report_wreck()  # the ONE terminal path — nothing left to resume
	assert_false(ChallengeSession.resume(t), "an ended run leaves nothing stored to resume")


# Test D (todo/challenge-career-reuse-drift.md): the test that USED to carry the
# "resume restores an active session" name only proved resume FAILS after the run
# ended. This is the missing half — a run left mid-way comes back on the stage
# it was left on, with its banked times, and can be driven on.
func test_resume_restores_the_stage_and_banked_times_of_a_stored_run() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(_longest_kind(), car, t)
	assert_gt(ChallengeSession.stage_count(), 1, "setup: a multi-stage kind")
	ChallengeSession.report_event_result(51_000)
	ChallengeSession.continue_to_next_stage()
	var banked := ChallengeSession.stage_times_ms()
	var stored: Dictionary = (_save.profile["challenge_run"] as Dictionary).duplicate(true)
	assert_eq(int(stored["stage_index"]), 1, "setup: the run persisted one stage in")

	# Simulate quitting to the desktop and relaunching: the autoload comes back
	# inert and the ONLY thing that survives is what was written to the profile.
	ChallengeSession.pause_run()
	_save.profile["challenge_run"] = stored
	assert_false(ChallengeSession.is_active(), "setup: nothing in memory to fall back on")

	assert_true(ChallengeSession.resume(t), "a stored run in the current period resumes")
	assert_true(ChallengeSession.is_active())
	assert_eq(ChallengeSession.events_completed(), 1,
		"it comes back ON the stage the run was left on, not at stage 0")
	assert_eq(ChallengeSession.stage_times_ms(), banked, "with the banked times intact")
	assert_eq(ChallengeSession.cumulative_ms(), 51_000)
	assert_eq(ChallengeSession.car_instance_id(), int(car["instance_id"]),
		"still locked to the car the run was started on")
	assert_eq(ChallengeSession.period_key(), String(stored["period_key"]))
	assert_false(ChallengeSession.current_stage_params().is_empty(),
		"and the stage it landed on has a track to generate")

	# A resumed run is DRIVEABLE, not just readable — the stage gate opened too.
	ChallengeSession.report_event_result(52_000)
	assert_eq(ChallengeSession.events_completed(), 2, "the resumed run advances")


# Item 9: a challenge fields its own car and authors no region, so it supersedes a
# pending free-roam pick exactly as RallySession.start_rally does. Left set, a
# free-roam drive quit at the pause menu dressed the next challenge stage in that
# drive's random region look.
func test_starting_a_challenge_clears_a_pending_free_roam_pick() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RallySession.free_roam_instance_id = 4242
	RallySession.free_roam_model_id = "fx_light_rwd"
	RallySession.free_roam_region_id = "some_other_region"

	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, car, t))

	assert_eq(RallySession.free_roam_instance_id, -1)
	assert_eq(RallySession.free_roam_model_id, "")
	assert_eq(RallySession.free_roam_region_id, "",
		"the region is cleared too — it is what leaked into the stage's look")


func test_resuming_a_challenge_clears_a_pending_free_roam_pick() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(_longest_kind(), car, t)
	var stored: Dictionary = (_save.profile["challenge_run"] as Dictionary).duplicate(true)
	ChallengeSession.pause_run()
	_save.profile["challenge_run"] = stored

	RallySession.free_roam_instance_id = 4242
	RallySession.free_roam_model_id = "fx_light_rwd"
	RallySession.free_roam_region_id = "some_other_region"

	assert_true(ChallengeSession.resume(t))

	assert_eq(RallySession.free_roam_instance_id, -1)
	assert_eq(RallySession.free_roam_model_id, "")
	assert_eq(RallySession.free_roam_region_id, "")


# --- eligible_cars --------------------------------------------------------------

func test_eligible_cars_includes_at_or_under_and_detune_reachable_over_ceiling() -> void:
	var t := int(Time.get_unix_time_from_system())
	var period := ChallengeLibrary.current_period(ChallengeLibrary.WEEKLY, t)
	var ceiling: float = ChallengeLibrary.ceiling_for(String(period["key"]))

	# Build a synthetic profile with two cars whose effective p/w straddle the
	# ceiling: one clearly under, one clearly over. Rather than pin a max_hp
	# number (power_to_weight_hp_tonne is actually derived from peak_torque +
	# redline via the engine, not a max_hp field — see CarLibrary.peak_power_kw),
	# invert CarLibrary's own formula to author a peak_torque that lands each
	# fixture's hp/tonne definitively on one side of whatever ceiling rolled.
	var mass := 1000.0
	var redline := 6000.0
	var band_max: float = CEILING_BAND_MAX
	var target_under: float = maxf(1.0, ceiling - 10.0)
	var target_over: float = band_max + 100.0

	var entry_under := {
		"id": "fx_under", "mass": mass, "engine": "fx_i4",
		"peak_torque": _torque_for_target_hp_tonne(target_under, mass, redline), "redline": redline,
	}
	var entry_over := {
		"id": "fx_over", "mass": mass, "engine": "fx_i4",
		"peak_torque": _torque_for_target_hp_tonne(target_over, mass, redline), "redline": redline,
	}
	var roster: Array[Dictionary] = CarFixtures.cars()
	roster.append(entry_under)
	roster.append(entry_over)
	CarLibrary.override_for_test(roster)

	var profile := {
		"cars": [
			{"instance_id": 1, "model_id": "fx_under", "installed_upgrades": [], "detune": 0.0},
			{"instance_id": 2, "model_id": "fx_over", "installed_upgrades": [], "detune": 0.0},
		]
	}
	var eligible := ChallengeSession.eligible_cars(ChallengeLibrary.WEEKLY, profile, t)

	var ids: Array = []
	for car in eligible:
		ids.append(int(car["instance_id"]))
	assert_true(ids.has(1), "a car at/under the ceiling is eligible")
	# Consistent with career-mode rally entry (hq_carpark.gd._qualifying_detune_for):
	# a car over the ceiling STOCK still counts as eligible if detuning down
	# would fit it under — no forced auto-detune, but it isn't excluded just
	# because its slider currently sits above what's needed.
	assert_true(ids.has(2), "a car over the ceiling but reachable via detune is still eligible")
	var entry_meta := CarLibrary.by_id("fx_over")
	var frac := ChallengeSession.qualifying_detune_for(
		{"restriction": {"pw_max": ceiling}}, profile["cars"][1], entry_meta)
	assert_gt(frac, 0.0, "a real detune fraction exists for the over-ceiling car")
	assert_lt(frac, 1.0, "and it is genuinely a reduction, not a no-op")


func test_eligible_cars_ignores_cars_missing_from_the_catalogue() -> void:
	var t := int(Time.get_unix_time_from_system())
	var profile := {"cars": [{"instance_id": 1, "model_id": "no_such_model"}]}
	var eligible := ChallengeSession.eligible_cars(ChallengeLibrary.DAILY, profile, t)
	assert_true(eligible.is_empty())


# --- report_event_result --------------------------------------------------------

func test_report_event_result_appends_to_stage_times() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(ChallengeLibrary.WEEKLY, car, t)  # stage_count 4
	ChallengeSession.report_event_result(50000)
	assert_eq(ChallengeSession.stage_times_ms(), [50000])
	assert_eq(ChallengeSession.events_completed(), 1)
	assert_eq(ChallengeSession.cumulative_ms(), 50000)


func test_non_final_stage_grants_a_per_stage_reward_and_a_field_repair() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	var driven_id := int(car["instance_id"])
	ChallengeSession.start(ChallengeLibrary.WEEKLY, car, t)  # stage_count 4

	var upgrades_before: int = (_save.get_car(driven_id)["installed_upgrades"] as Array).size()
	var items_before := 0
	for item_id in _save.profile["inventory"]:
		items_before += int(_save.profile["inventory"][item_id])

	ChallengeSession.report_event_result(50000, 100.0)  # non-final: stage 1 of 4

	assert_true(ChallengeSession.is_active(), "the run continues past a non-final stage")
	var upgrades_after: int = (_save.get_car(driven_id)["installed_upgrades"] as Array).size()
	var items_after := 0
	for item_id in _save.profile["inventory"]:
		items_after += int(_save.profile["inventory"][item_id])
	assert_true(upgrades_after > upgrades_before or items_after > items_before,
		"a non-final stage grants a reward: installed on the car or added to inventory")

	var repair := ChallengeSession.take_pending_repair()
	assert_false(repair.is_empty(), "a non-final stage leaves a pending field repair")
	assert_true(ChallengeSession.take_pending_repair().is_empty(),
		"the pending repair is consumed once (one-shot)")


func test_final_stage_ends_the_run_and_clears_the_persisted_profile() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(ChallengeLibrary.DAILY, car, t)  # stage_count 1

	var finished: Array = []
	ChallengeSession.run_finished.connect(
		func(result: Dictionary) -> void: finished.append(result), CONNECT_ONE_SHOT)

	ChallengeSession.report_event_result(40000)  # the only stage -> final

	assert_false(ChallengeSession.is_active(), "the final stage ends the run")
	assert_eq(finished.size(), 1, "run_finished emitted exactly once")
	assert_true(bool(finished[0]["completed"]))
	assert_false(bool(finished[0]["dnf"]))
	assert_true(_save.profile["challenge_run"].is_empty(),
		"the persisted challenge_run clears once the run is over")
	assert_true(ChallengeSession.take_pending_repair().is_empty(),
		"the final stage leaves no pending repair (no next stage to cushion for)")


# Drive every stage but the last, so the NEXT report_event_result is the final
# one. On a DAILY (one stage) this is a no-op and the very first stage is already
# the final stage — which is exactly the case items 2 and 5 have to survive.
func _run_up_to_the_final_stage() -> void:
	while ChallengeSession.events_completed() < ChallengeSession.stage_count() - 1:
		ChallengeSession.report_event_result(50_000)
		ChallengeSession.continue_to_next_stage()


# --- Item 2: the FINAL stage's interstitial belongs to the CHALLENGE ------------

# THE regression test for "a Daily's time never reaches Firestore". The final
# stage used to call _finish_locally() (clearing _active) and only THEN emit
# standings_ready, so the interstitial — and every session read it makes — fell
# through to the idle career session. A Daily has exactly one stage, so its only
# stage is also its final stage: the challenge branch was never taken, the board
# opts described the career `stage_times` board with a blank stage_key, and
# ChallengeLeaderboard.post_checkpoint (reachable ONLY from the is_challenge
# branch) was never called on any run.
#
# Deliberately run against a DAILY — a multi-stage kind would mask this, because
# its earlier stages post correctly.
func test_the_final_stages_interstitial_resolves_against_the_challenge_not_the_career() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, car, t))
	_run_up_to_the_final_stage()

	var seen: Dictionary = {}
	var order: Array = []
	ChallengeSession.standings_ready.connect(func(_idx: int) -> void:
		order.append("standings_ready")
		seen["active"] = ChallengeSession.is_active()
		seen["done"] = ChallengeSession.events_completed()
		seen["total"] = ChallengeSession.stage_count()
		seen["opts"] = GlobalStandings.for_current_stage(), CONNECT_ONE_SHOT)
	ChallengeSession.run_finished.connect(func(_r: Dictionary) -> void:
		order.append("run_finished"), CONNECT_ONE_SHOT)

	ChallengeSession.report_event_result(45_000)

	assert_eq(order, ["standings_ready", "run_finished"],
		"the interstitial is announced BEFORE the run tears itself down, not after")
	assert_eq(int(seen["done"]), int(seen["total"]),
		"setup: the interstitial under test is the FINAL stage's")
	assert_true(bool(seen["active"]),
		"the challenge is still the active session while its interstitial is built")

	var opts: Dictionary = seen["opts"]
	assert_true(bool(opts["is_challenge"]),
		"the final stage's board opts route to the CHALLENGE board — this is the call " \
		+ "that reaches ChallengeLeaderboard.post_checkpoint at all")
	assert_false(opts.has("stage_key"),
		"and NOT to the career stage_times board (whose opts carry a stage_key)")
	assert_ne(String(opts["period_key"]), "", "carrying a real period key, not a blank one")
	assert_eq(String(opts["period_key"]), ChallengeSession.period_key(),
		"the period key is this run's own")
	assert_eq(int(opts["time_ms"]), ChallengeSession.cumulative_ms(),
		"and the posted time is the run's cumulative time")


# Page 2 of the interstitial is reached AFTER the player presses Continue, by
# which time the run has ended for real. standings.gd latches the session at
# construction and passes it in, so the board the final checkpoint posts to does
# not change under the player mid-screen.
func test_the_latched_mode_still_resolves_the_challenge_board_after_the_run_ended() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, car, t))
	var period_key := ChallengeSession.period_key()
	_run_up_to_the_final_stage()
	ChallengeSession.report_event_result(45_000)
	assert_false(ChallengeSession.is_active(), "setup: the run has ended")

	var latched := GlobalStandings.for_current_stage(true)
	assert_true(bool(latched["is_challenge"]),
		"a latched interstitial still resolves the challenge board once _active is false")
	assert_eq(String(latched["period_key"]), period_key)
	assert_eq(int(latched["time_ms"]), ChallengeSession.cumulative_ms())

	# Without the latch this is what the page would have got instead.
	var unlatched := GlobalStandings.for_current_stage()
	assert_false(bool(unlatched["is_challenge"]),
		"setup: re-asking is_active() here IS the bug — it lands on the career board")


# --- Item 5: the final stage repairs, like a career rally's last event ----------

# RallySession._resolve_results applies the partial field repair after the FINAL
# event so its damage isn't left standing; the challenge's final branch used to be
# a literal `pass`. Both now go through the one shared writer
# (RallySession.apply_field_repair_to), which is what this asserts — an AGREEMENT
# between the two paths, so no repair fraction is pinned.
func test_the_final_stage_repairs_the_cars_damage_the_same_way_career_does() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	var driven_id := int(car["instance_id"])
	# A second, identical car that never enters the challenge: the career-side
	# control the challenge's result is compared against.
	var control_id := int(_grant()["instance_id"])
	var max_hp := float(_save.get_car(driven_id)["hp"])

	ChallengeSession.start(ChallengeLibrary.DAILY, car, t)
	_run_up_to_the_final_stage()
	var hp_before_final := float(_save.get_car(driven_id)["hp"])
	var hp_lost := hp_before_final * 0.25
	var damaged := hp_before_final - hp_lost

	ChallengeSession.report_event_result(45_000, hp_lost)  # the FINAL stage

	var hp_after := float(_save.get_car(driven_id)["hp"])
	assert_gt(hp_after, damaged,
		"the final stage's damage is patched up, not left standing until the next event")
	assert_true(hp_after <= max_hp, "and never beyond the car's own maximum")

	# The career path's final-event repair, applied to the control car from the
	# same damaged HP. Same shared writer, same config fractions -> same result.
	var control: Dictionary = _save.get_car(control_id)
	control["hp"] = damaged
	@warning_ignore("return_value_discarded")
	RallySession.apply_field_repair_to(control_id)
	assert_almost_eq(hp_after, float(_save.get_car(control_id)["hp"]), 0.001,
		"a challenge's final repair is exactly the repair a career rally's final event applies")

	assert_true(ChallengeSession.take_pending_repair().is_empty(),
		"applied SILENTLY — the run-end flow is left no repair popup to show")


# --- continue_to_next_stage: the whole multi-stage run ------------------------

# The challenge kind with the most stages, resolved from the table rather than
# named — these tests need "a multi-stage run", not a particular authored count.
func _longest_kind() -> String:
	var best := ""
	var most := -1
	for kind_str in ChallengeLibrary.STAGE_COUNTS:
		if int(ChallengeLibrary.STAGE_COUNTS[kind_str]) > most:
			most = int(ChallengeLibrary.STAGE_COUNTS[kind_str])
			best = String(kind_str)
	return best



# THE regression test for "a Weekly/Monthly challenge can't get past stage 1":
# standings.gd's Continue had no ChallengeSession counterpart to
# RallySession.continue_to_next_event(), so the interstitial's only exit was a
# no-op. Drives a multi-stage run end to end through the same two calls the
# interstitial makes — report_event_result then continue_to_next_stage — and
# asserts it actually reaches the finish.
func test_a_multi_stage_run_advances_through_every_stage_to_the_finish() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	# Whichever kind currently has the MOST stages — the point is "more than one",
	# not any particular authored count.
	ChallengeSession.start(_longest_kind(), car, t)
	var total := ChallengeSession.stage_count()
	assert_true(total > 1, "the longest kind is multi-stage (else this proves nothing)")

	var finished: Array = []
	ChallengeSession.run_finished.connect(
		func(result: Dictionary) -> void: finished.append(result), CONNECT_ONE_SHOT)
	var entered: Array = []
	ChallengeSession.stage_started.connect(func(idx: int) -> void: entered.append(idx))

	for i in total:
		assert_eq(ChallengeSession.events_completed(), i,
			"stage %d is the one about to run" % (i + 1))
		assert_false(ChallengeSession.current_stage_params().is_empty(),
			"stage %d has a track to generate" % (i + 1))
		ChallengeSession.report_event_result(50000 + i * 1000)
		ChallengeSession.continue_to_next_stage()  # the interstitial's Continue

	assert_eq(ChallengeSession.events_completed(), total, "every stage was driven")
	assert_false(ChallengeSession.is_active(), "the run finished rather than stalling")
	assert_eq(finished.size(), 1, "run_finished fired exactly once, at the end")
	assert_eq(ChallengeSession.stage_times_ms().size(), total, "every stage banked a time")
	# One re-entry per NON-final stage; the final stage ends the run instead, so its
	# continue is a no-op rather than a fifth scene load.
	assert_eq(entered.size(), total - 1, "the run re-entered driving once per remaining stage")


func test_continue_to_next_stage_is_a_no_op_once_the_run_is_over() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(ChallengeLibrary.DAILY, car, t)
	var entered: Array = []
	ChallengeSession.stage_started.connect(func(idx: int) -> void: entered.append(idx))
	while ChallengeSession.is_active():
		ChallengeSession.report_event_result(40000)
		ChallengeSession.continue_to_next_stage()
	var re_entries := entered.size()
	ChallengeSession.continue_to_next_stage()  # must not error or re-enter driving
	assert_eq(entered.size(), re_entries,
		"a finished run never re-enters the driving scene")


# --- Local standings (a field of one) -----------------------------------------

func test_stage_standings_are_the_players_own_row_alone() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(_longest_kind(), car, t)
	assert_eq(ChallengeSession.current_event_standings(), [],
		"no stage standings before any stage completes")

	ChallengeSession.report_event_result(50000)
	var stage_rows := ChallengeSession.current_event_standings()
	assert_eq(stage_rows.size(), 1, "a challenge has no rival field, so one row")
	assert_true(bool(stage_rows[0]["is_player"]), "and that row is the player's")
	assert_eq(int(stage_rows[0]["combined_ms"]), 50000, "carrying that stage's time")

	ChallengeSession.continue_to_next_stage()
	ChallengeSession.report_event_result(40000)
	var overall := ChallengeSession.current_standings()
	assert_eq(overall.size(), 1)
	assert_eq(int(overall[0]["combined_ms"]), 90000, "the overall row sums the stages")


# --- report_wreck -------------------------------------------------

func test_report_wreck_ends_the_run_as_dnf_and_keeps_times_already_appended() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(ChallengeLibrary.WEEKLY, car, t)  # stage_count 4
	ChallengeSession.report_event_result(50000)  # stage 1 of 4, non-final
	# Back out on a live stage before crashing. report_wreck now carries
	# RallySession's Phase.RUNNING gate (item 8), so a wreck is only honoured while
	# a stage is actually being driven — not while the interstitial is up.
	ChallengeSession.continue_to_next_stage()

	var finished: Array = []
	ChallengeSession.run_finished.connect(
		func(result: Dictionary) -> void: finished.append(result), CONNECT_ONE_SHOT)

	ChallengeSession.report_wreck()

	assert_true(ChallengeSession.dnf())
	assert_false(ChallengeSession.is_active())
	assert_eq(finished.size(), 1)
	assert_true(bool(finished[0]["dnf"]))
	assert_false(bool(finished[0]["completed"]))
	assert_eq(finished[0]["stage_times_ms"], [50000],
		"the stage time already banked before the wreck stands")


# Item 8: RallySession.report_wreck early-outs unless _phase == RUNNING; the
# challenge equivalent guarded only _active. The standings interstitial keeps the
# run world and $Car alive with begin_replay running, so a `wrecked` emission in
# that window would have DNF'd a stage the player had already finished.
func test_a_wreck_reported_during_the_standings_window_is_ignored() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(_longest_kind(), car, t)
	assert_gt(ChallengeSession.stage_count(), 1, "setup: a multi-stage kind")

	ChallengeSession.report_event_result(50_000)  # stage over; the interstitial is up
	ChallengeSession.report_wreck()               # the replaying car "crashes"

	assert_false(ChallengeSession.dnf(),
		"a wreck from the replay window does not DNF a stage that already finished")
	assert_true(ChallengeSession.is_active(), "and the run carries on to the next stage")

	# Back on a live stage, a wreck means what it always meant.
	ChallengeSession.continue_to_next_stage()
	ChallengeSession.report_wreck()
	assert_true(ChallengeSession.dnf(), "a wreck while actually driving still ends the run")
	assert_false(ChallengeSession.is_active())


# The same gate on the result path: a second result for a stage already reported
# (the interstitial is up; nothing is being driven) must not bank a phantom time.
func test_a_second_result_for_the_same_stage_is_ignored() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(_longest_kind(), car, t)
	ChallengeSession.report_event_result(50_000)
	var banked := ChallengeSession.stage_times_ms()
	var done := ChallengeSession.events_completed()

	ChallengeSession.report_event_result(1_000)

	assert_eq(ChallengeSession.stage_times_ms(), banked, "no phantom time is banked")
	assert_eq(ChallengeSession.events_completed(), done, "and the run does not skip a stage")


# --- pause_run: leaving the run is NOT a DNF (item 12) ------------------------
#
# The rule, from the user: ONLY a wreck DNFs a challenge. Everything else that
# leaves the run — the pause menu's "Quit to HQ", starting a dev benchmark —
# pauses it. Leaving used to route to _end_as_dnf, which records a terminal
# per-period outcome, so stepping out to the garage permanently burned the period.
func test_pause_run_leaves_the_run_resumable_with_no_outcome_recorded() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(_longest_kind(), car, t)
	assert_gt(ChallengeSession.stage_count(), 1, "setup: a multi-stage kind")
	ChallengeSession.report_event_result(50_000)
	ChallengeSession.continue_to_next_stage()
	var banked := ChallengeSession.stage_times_ms()

	var finished: Array = []
	ChallengeSession.run_finished.connect(
		func(result: Dictionary) -> void: finished.append(result), CONNECT_ONE_SHOT)

	ChallengeSession.pause_run()

	assert_false(ChallengeSession.is_active(), "the run stops being the active session")
	assert_false(ChallengeSession.dnf(), "but it is NOT a DNF")
	assert_eq(finished.size(), 0, "and the run has not finished — no run_finished")
	assert_true(ChallengeSession.period_outcome(_save.profile,
		String(ChallengeLibrary.current_period(_longest_kind(), t)["key"])).is_empty(),
		"no terminal outcome is recorded, so the period is not spent")

	var run := ChallengeSession.resumable_run(_save.profile, t)
	assert_false(run.is_empty(), "the stored run survives and is still resumable")
	assert_eq(int(run["stage_index"]), 1, "left on the stage it was paused on")
	assert_eq(run["stage_times_ms"], banked, "with its banked stage times intact")
	assert_eq(int(run["car_instance_id"]), int(car["instance_id"]))

	assert_true(ChallengeSession.resume(t), "and resume picks it straight back up")
	assert_eq(ChallengeSession.events_completed(), 1,
		"landing on the stage the run was paused on")
	assert_eq(ChallengeSession.stage_times_ms(), banked)


# The other half of the split: the terminal path is untouched.
func test_a_wreck_is_still_terminal_after_the_pause_split() -> void:
	var t := int(Time.get_unix_time_from_system())
	ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t)

	var finished: Array = []
	ChallengeSession.run_finished.connect(
		func(result: Dictionary) -> void: finished.append(result), CONNECT_ONE_SHOT)

	ChallengeSession.report_wreck()

	assert_true(ChallengeSession.dnf())
	assert_false(ChallengeSession.is_active())
	assert_eq(finished.size(), 1, "a wreck ends the run")
	assert_true(bool(finished[0]["dnf"]))
	assert_true(ChallengeSession.resumable_run(_save.profile, t).is_empty(),
		"a wrecked run is not left resumable")
	assert_false(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t),
		"and the period is spent — no retry")


func test_pause_run_is_a_no_op_when_not_active() -> void:
	assert_false(ChallengeSession.is_active())
	ChallengeSession.pause_run()  # must not error
	assert_false(ChallengeSession.is_active())


# Starting a dev benchmark clears whatever session is live so world.gd doesn't boot
# the benchmark down the challenge path. That must PAUSE the run, not spend the
# player's one attempt at the period. Benchmark.start() itself is not callable from a
# test (it ends in change_scene_to_file, which would replace the GUT runner scene), so
# this asserts the property its call site depends on: leaving a run active-less costs
# nothing, on any number of repeats.
func test_leaving_and_re_entering_a_run_repeatedly_never_spends_the_period() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	ChallengeSession.start(ChallengeLibrary.DAILY, car, t)
	for _i in 3:
		ChallengeSession.pause_run()
		assert_false(ChallengeSession.is_active())
		assert_true(ChallengeSession.resume(t), "each pause is followed by a clean resume")
	assert_true(ChallengeSession.period_outcome(_save.profile,
		String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"])).is_empty(),
		"no outcome recorded — the period survives leaving the run")
	assert_false(ChallengeSession.dnf())


# --- try_grant_completion_reward: DNF short-circuit (local-only) ---------------

func test_try_grant_completion_reward_returns_empty_on_dnf_without_touching_cloud() -> void:
	# Deliberately no Cloud/Cloud.challenge_leaderboard setup here: the
	# completed:false branch must return before ever reading Cloud, so this
	# call succeeding with no Cloud wired up IS the assertion.
	var result: Dictionary = await ChallengeSession.try_grant_completion_reward(
		{"completed": false, "kind": ChallengeLibrary.DAILY, "period_key": "x"})
	assert_true(result.is_empty(), "a DNF result grants nothing and touches no cloud state")


# --- DrivingContext.apply_stage_config: the stage's rolled params reach the run --

# Regression: a challenge stage used to reach the driving scene WITHOUT its rolled
# parameters ever being written into the config. TrackGenParams.for_event reads only
# seed/turn_count/width/straightness/water_* out of the stage dict — terrain relief,
# forestiness, cliffiness and surface mix reach generation ONLY via cfg, and the lake
# that is actually rendered and collided against is built from cfg.track_water_level_m
# (world.gd._build_lakes), not from params.water_level. Skipping the apply left the
# road routed against the default relief while dodging a waterline the renderer never
# used, and at high relief the generator failed to route at all.
#
# Asserts the cfg AGREES WITH THE STAGE, never that either holds a particular value —
# every one of these is a rolled/tunable number.
func test_apply_stage_config_writes_the_stages_rolled_params_into_the_config() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t))
	var stage := ChallengeSession.current_stage_params()
	assert_false(stage.is_empty(), "setup: an active run exposes its current stage")

	var cfg: GameConfig = (load(Config.CONFIG_PATH) as GameConfig).duplicate()
	DrivingContext.apply_stage_config(cfg)

	assert_eq(cfg.track_seed, int(stage["seed"]), "the stage's seed reaches the config")
	assert_eq(cfg.track_turn_count, int(stage["turn_count"]), "the stage's turn count reaches the config")
	# The rendered/collided waterline and the relief the road is routed against —
	# the two that produced the road-into-the-lake bug when they were dropped.
	assert_almost_eq(cfg.track_water_level_m, float(stage["water_level"]), 0.001,
		"the RENDERED water level matches the level the road was generated against")
	assert_almost_eq(cfg.terrain_layer1_amplitude, float(stage["terrain_layer1_amplitude"]), 0.001,
		"the terrain relief the road is routed against is the stage's, not the default")
	assert_almost_eq(cfg.track_forestiness, float(stage["forestiness"]), 0.001,
		"the stage's forestiness reaches the config")
	assert_almost_eq(cfg.cliff_amount, float(stage["cliffiness"]), 0.001,
		"the stage's cliffiness reaches the config")


# The params must resolve afresh on every stage entry, not just the first — stage
# 2+ enters via continue_to_next_stage, a different code path to the HQ hand-off,
# and each stage rolls its own water level and relief. Both entries now converge on
# the SAME consume-time resolve world.gd._ready performs, which is what this drives.
func test_entering_the_next_stage_resolves_that_stages_config() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(ChallengeSession.start(ChallengeLibrary.MONTHLY, _grant(), t))
	assert_gt(ChallengeSession.stage_count(), 1, "setup: a multi-stage kind")

	ChallengeSession.report_event_result(60_000, 0.0)
	assert_eq(ChallengeSession.events_completed(), 1, "setup: advanced onto stage 2")
	var stage_two := ChallengeSession.current_stage_params()

	Config.data.track_seed = -1  # a value no roll can produce, so the write is observable
	ChallengeSession.continue_to_next_stage()
	# What world.gd._ready does on boot, and the only place the config is seated.
	DrivingContext.apply_stage_config(Config.data)
	assert_eq(Config.data.track_seed, int(stage_two["seed"]),
		"entering stage 2 seats that stage's own params into the live config")
	assert_almost_eq(Config.data.track_water_level_m, float(stage_two["water_level"]), 0.001,
		"stage 2's own water level is applied, not stage 1's")


# Test A (todo/challenge-career-reuse-drift.md): the config a challenge stage runs
# against must be FIELD-FOR-FIELD what the career path would build for the same
# event dict. Closes the CLASS the water bug belonged to rather than the fields it
# happened to hit — a per-event field added later is covered automatically, and no
# value is pinned (the two derivations are compared to each other).
func test_a_stages_resolved_config_equals_the_canonical_event_config() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t))
	var stage := ChallengeSession.current_stage_params()
	assert_false(stage.is_empty(), "setup: an active run exposes its current stage")

	var cfg: GameConfig = (load(Config.CONFIG_PATH) as GameConfig).duplicate()
	DrivingContext.apply_stage_config(cfg)
	var canonical := RallySession.canonical_event_config(stage)

	var compared := 0
	for prop in cfg.get_property_list():
		if int(prop.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var field: String = prop["name"]
		compared += 1
		assert_eq(cfg.get(field), canonical.get(field),
			"%s: the stage's live config must equal the canonical event config" % field)
	assert_gt(compared, 0, "setup: the GameConfig exposes script variables to diff")


# --- DrivingContext.session_active ---------------------------------------------

# The F-to-finish dev cheat (world.gd._unhandled_input) used to gate on
# RallySession.is_active() alone, which left it silently dead during a challenge —
# the mode whose multi-stage flow is slowest to exercise by hand. It now asks
# DrivingContext.session_active(), so a challenge run must answer true.
func test_session_active_is_true_during_a_challenge_run() -> void:
	assert_false(DrivingContext.session_active(),
		"setup: nothing is being driven before a run starts")
	var t := int(Time.get_unix_time_from_system())
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t))
	assert_true(DrivingContext.session_active(),
		"a challenge run counts as an active driving session, same as a career rally")
	ChallengeSession.pause_run()
	assert_false(DrivingContext.session_active(),
		"and it stops counting once the run ends")


# --- One attempt per period ------------------------------------------------------

# A finished run is TERMINAL for its period. _finish_locally/_end_as_dnf clear
# challenge_run, so without a separate outcome record the entry screen would read
# "Not started" again and the player could re-run the period and post a second time.
func test_a_completed_period_cannot_be_started_again() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t))
	while ChallengeSession.is_active():
		ChallengeSession.report_event_result(60_000, 0.0)
	assert_false(ChallengeSession.is_active(), "setup: the run played through to the end")

	assert_true(ChallengeSession.is_period_finished(ChallengeLibrary.DAILY, _save.profile, t),
		"the finished period is recorded as spent")
	var outcome := ChallengeSession.period_outcome(_save.profile,
		String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"]))
	assert_false(bool(outcome.get("dnf", true)), "it is recorded as a completion, not a DNF")
	assert_false(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t),
		"starting the same period again is refused")


# A wreck is equally terminal — the design is explicitly no-retry.
func test_a_dnfd_period_cannot_be_retried() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t))
	ChallengeSession.report_wreck()
	assert_false(ChallengeSession.is_active(), "setup: the wreck ended the run")

	var outcome := ChallengeSession.period_outcome(_save.profile,
		String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"]))
	assert_true(bool(outcome.get("dnf", false)), "the period is recorded as a DNF")
	assert_false(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t),
		"a DNF'd period is not retryable")


# A DIFFERENT kind's period is untouched by another kind's outcome — they are
# independent runs, and only one can be active at a time.
func test_finishing_one_kind_leaves_the_others_startable() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t))
	while ChallengeSession.is_active():
		ChallengeSession.report_event_result(60_000, 0.0)
	assert_false(ChallengeSession.is_period_finished(ChallengeLibrary.WEEKLY, _save.profile, t),
		"the weekly period is untouched by the daily's outcome")
	assert_true(ChallengeSession.start(ChallengeLibrary.WEEKLY, _grant(), t),
		"another kind can still be started")


# The outcome map must not grow one entry per day forever — only live periods survive
# a write. Uses a synthetic dead key rather than time travel.
func test_recording_an_outcome_prunes_periods_that_have_rolled_over() -> void:
	var t := int(Time.get_unix_time_from_system())
	_save.profile["challenge_results"] = {
		"daily:1999-01-01:e1": {"kind": ChallengeLibrary.DAILY, "dnf": false, "cumulative_ms": 1},
	}
	assert_true(ChallengeSession.start(ChallengeLibrary.DAILY, _grant(), t))
	ChallengeSession.report_wreck()

	var results: Dictionary = _save.profile["challenge_results"]
	assert_false(results.has("daily:1999-01-01:e1"),
		"a period that has long since rolled over is dropped")
	assert_true(results.has(String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"])),
		"the period just played is kept")

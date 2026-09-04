extends GutTest
# The CHALLENGE half of the run spine: `RunSession` (scripts/run_session.gd) driven
# through `ChallengeRunMode` (scripts/challenge_run_mode.gd), spec §3-4-6. Driven
# directly against a throwaway Save profile — no scene loads, no real driving.
#
# The session is shared with the roguelike region run now, so the SHARED machinery
# (the one run slot, the stage cursor, the fail rule, money) is covered by
# tests/headless/test_region_run.gd; what stays here is everything that is
# challenge-specific — periods, staleness, eligibility, one attempt per period.
# The file keeps its name so the challenge's coverage stays findable by it.

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
	RunSession.auto_load_scenes = false
	_leave_run()


func after_each() -> void:
	_leave_run()
	RunSession.auto_load_scenes = true
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()


# Leave any live run WITHOUT ending it (pause_run is the non-terminal path — only a
# wreck DNFs a challenge, item 12), then drop the persisted run so a paused run never
# leaks into the next test.
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


# The extremes of the (tunable) rating ceiling band — used ONLY to sanity-check that a
# fixture car sits definitively on one side of whatever the period happens to roll,
# never to assert on the band's contents itself.
var CEILING_BAND_MAX: float = ChallengeLibrary.CEILING_BAND_RATING.max()
var CEILING_BAND_MIN: float = ChallengeLibrary.CEILING_BAND_RATING.min()


# A synthetic catalogue entry whose CarPerformance rating is far below anything the band
# can roll: heavy, weak and draggy. Nothing is pinned — the tests below assert the
# resulting RATING against the band, so a retune of either surfaces as a fixture-sanity
# failure rather than a silently vacuous test.
func _slow_entry(id: String) -> Dictionary:
	return {"id": id, "mass": 3000.0, "engine": "fx_i4", "redline": 4000.0,
		"peak_torque": 60.0, "drive_mode": CarLibrary.FWD, "tire_compound": 0.6}


# The mirror image: light and very powerful, so its rating clears the whole band.
func _fast_entry(id: String) -> Dictionary:
	return {"id": id, "mass": 500.0, "engine": "fx_v8", "redline": 9000.0,
		"peak_torque": 1200.0, "drive_mode": CarLibrary.AWD, "tire_compound": 1.4}


# The rating the challenge path judges an owned car by (the same merged meta
# ChallengeRunMode.classify_car uses, so the fixture can never drift from it).
func _rating_of(owned: Dictionary, entry: Dictionary) -> int:
	return CarPerformance.rating(CarPerformance.merged_meta(owned, entry))


# --- start() ------------------------------------------------------------------

func test_start_fails_when_already_active() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	assert_true(RunSession.start(ChallengeLibrary.DAILY, car, t))
	assert_false(RunSession.start(ChallengeLibrary.DAILY, car, t),
		"a second start is refused while a run is active")


func test_start_succeeds_and_persists_immediately_at_stage_zero() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	assert_true(RunSession.start(ChallengeLibrary.WEEKLY, car, t))
	assert_true(RunSession.is_active())
	assert_eq(RunSession.events_completed(), 0)

	var run: Dictionary = _save.profile[Save.KEY_RUN]
	assert_false(run.is_empty(), "the run is persisted to the profile right away")
	assert_eq(int(run["stage_index"]), 0)
	assert_eq(int(run["car_instance_id"]), int(car["instance_id"]))
	assert_eq(String(run["kind"]), ChallengeLibrary.WEEKLY)


# --- resumable_run / has_stale_run ---------------------------------------------

func test_resumable_run_reads_stale_period_as_not_resumable() -> void:
	var t := int(Time.get_unix_time_from_system())
	var profile := {
		Save.KEY_RUN: {
			"period_key": "daily:2000-01-01:e%d" % ChallengeLibrary.CHALLENGE_EPOCH,
			"kind": ChallengeLibrary.DAILY, "car_instance_id": 1,
			"stage_index": 0, "stage_times_ms": [], "dnf": false,
		}
	}
	assert_true(RunSession.resumable_run(profile, t).is_empty(),
		"a run whose period has rolled over is not resumable")
	assert_true(RunSession.has_stale_run(profile, t),
		"and is flagged as stale")


func test_resumable_run_reads_current_period_as_resumable() -> void:
	var t := int(Time.get_unix_time_from_system())
	var period := ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)
	var profile := {
		Save.KEY_RUN: {
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
	assert_false(RunSession.resumable_run(profile, later).is_empty(),
		"a run whose period key still matches is resumable")
	assert_false(RunSession.has_stale_run(profile, later))


func test_has_stale_run_is_false_with_no_run_at_all() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_false(RunSession.has_stale_run({}, t))
	assert_false(RunSession.has_stale_run({Save.KEY_RUN: {}}, t))


func test_resume_fails_after_the_run_ended() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(ChallengeLibrary.DAILY, car, t)
	while RunSession.is_active():  # play it out — completion is the only terminal path
		RunSession.report_event_result(60_000, 0.0)
	assert_false(RunSession.resume(t), "an ended run leaves nothing stored to resume")


# Test D (todo/challenge-career-reuse-drift.md): the test that USED to carry the
# "resume restores an active session" name only proved resume FAILS after the run
# ended. This is the missing half — a run left mid-way comes back on the stage
# it was left on, with its banked times, and can be driven on.
func test_resume_restores_the_stage_and_banked_times_of_a_stored_run() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(_longest_kind(), car, t)
	assert_gt(RunSession.stage_count(), 1, "setup: a multi-stage kind")
	RunSession.report_event_result(51_000)
	RunSession.continue_to_next_stage()
	var banked := RunSession.stage_times_ms()
	var stored: Dictionary = (_save.profile[Save.KEY_RUN] as Dictionary).duplicate(true)
	assert_eq(int(stored["stage_index"]), 1, "setup: the run persisted one stage in")

	# Simulate quitting to the desktop and relaunching: the autoload comes back
	# inert and the ONLY thing that survives is what was written to the profile.
	RunSession.pause_run()
	_save.profile[Save.KEY_RUN] = stored
	assert_false(RunSession.is_active(), "setup: nothing in memory to fall back on")

	assert_true(RunSession.resume(t), "a stored run in the current period resumes")
	assert_true(RunSession.is_active())
	assert_eq(RunSession.events_completed(), 1,
		"it comes back ON the stage the run was left on, not at stage 0")
	assert_eq(RunSession.stage_times_ms(), banked, "with the banked times intact")
	assert_eq(RunSession.cumulative_ms(), 51_000)
	assert_eq(RunSession.car_instance_id(), int(car["instance_id"]),
		"still locked to the car the run was started on")
	assert_eq(RunSession.period_key(), String(stored["period_key"]))
	assert_false(RunSession.current_stage_params().is_empty(),
		"and the stage it landed on has a track to generate")

	# A resumed run is DRIVEABLE, not just readable — the stage gate opened too.
	RunSession.report_event_result(52_000)
	assert_eq(RunSession.events_completed(), 2, "the resumed run advances")


# NOTE: two tests lived here — "starting a challenge clears a pending free-roam pick"
# and its resume twin (drift spec item 9). Both are DELETED, not weakened: they drove
# RallySession.free_roam_* , and free roam is removed outright by decision 25. The bug
# they guarded (a quit free-roam drive dressing the next challenge stage in that drive's
# random region look) cannot occur once nothing can author a pending free-roam pick.


# --- Discarding burns the attempt (decision 48) --------------------------------

# Decision 27 gives the profile ONE run slot, so starting a region run discards a paused
# challenge. That used to write no outcome, which handed the player a free retry: quit a
# daily, start anything else, and the daily was startable again from stage 1. The attempt
# is burned instead. Asserts the RULE, not any stored field's spelling.
func test_discarding_a_paused_run_burns_the_attempt() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	assert_true(RunSession.start(ChallengeLibrary.DAILY, car, t), "setup: a daily is running")
	assert_false(ChallengeRunMode.is_period_finished(ChallengeLibrary.DAILY, _save.profile, t),
		"setup: the period is not finished while the run is live")
	RunSession.pause_run()

	RunSession.discard_run(t)

	assert_true(ChallengeRunMode.is_period_finished(ChallengeLibrary.DAILY, _save.profile, t),
		"the discarded period counts as attempted — no free retry")
	assert_false(RunSession.start(ChallengeLibrary.DAILY, car, t),
		"and the same period cannot be started again")


func test_discarding_with_no_run_is_a_no_op() -> void:
	var t := int(Time.get_unix_time_from_system())
	RunSession.discard_run(t)  # nothing paused
	assert_false(ChallengeRunMode.is_period_finished(ChallengeLibrary.DAILY, _save.profile, t),
		"discarding nothing does not burn an attempt the player never started")


# --- eligible_cars --------------------------------------------------------------

func test_eligible_cars_admits_under_the_ceiling_and_excludes_over_it() -> void:
	# The whole challenge eligibility rule: a car whose RATING is at or under the period's
	# displayed ceiling can enter, one above it cannot. There is no detune escape any more
	# (design doc D5) — over the ceiling is simply out, and the player brings another car.
	var t := int(Time.get_unix_time_from_system())
	var entry_under := _slow_entry("fx_under")
	var entry_over := _fast_entry("fx_over")
	var roster: Array[Dictionary] = CarFixtures.cars()
	roster.append(entry_under)
	roster.append(entry_over)
	CarLibrary.override_for_test(roster)
	CarPerformance.reset()

	var profile := {
		"cars": [
			{"instance_id": 1, "model_id": "fx_under", "installed_upgrades": [], "detune": 0.0},
			{"instance_id": 2, "model_id": "fx_over", "installed_upgrades": [], "detune": 0.0},
		]
	}
	# Fixture sanity: the two cars straddle the WHOLE band, so the assertions below hold
	# whichever ceiling this period rolled.
	assert_lt(float(_rating_of(profile["cars"][0], entry_under)), CEILING_BAND_MIN,
		"fixture sanity: the slow car is under every ceiling the band can roll")
	assert_gt(float(_rating_of(profile["cars"][1], entry_over)), CEILING_BAND_MAX,
		"fixture sanity: the fast car is over every ceiling the band can roll")

	var ids: Array = []
	for car in ChallengeRunMode.eligible_cars(ChallengeLibrary.WEEKLY, profile, t):
		ids.append(int(car["instance_id"]))
	assert_eq(ids, [1], "only the car under the ceiling is eligible")


# --- the displayed-ceiling boundary (classify_car) -------------------------------
#
# The challenge path must judge a car against the ceiling AS DISPLAYED (rounded). Both
# cases below author their OWN ceiling with a fractional part — nothing is read from
# CEILING_BAND_RATING — and derive it FROM the fixture car's own rating, so no specific
# number is pinned.

# A synthetic owned car + entry pair, returned alongside the rating the challenge path
# judges it by.
func _boundary_car() -> Dictionary:
	var entry := _slow_entry("fx_boundary")
	var owned := {"instance_id": 1, "model_id": "fx_boundary", "installed_upgrades": [], "detune": 0.0}
	CarPerformance.reset()
	return {"entry": entry, "owned": owned, "rating": _rating_of(owned, entry)}


func test_car_at_the_displayed_ceiling_is_ready_even_though_the_raw_ceiling_is_lower() -> void:
	var c := _boundary_car()
	# A ceiling that PRINTS as the car's own rating but is fractionally below it: the two
	# numbers on screen match, so the car must be admitted.
	var raw_ceiling: float = float(c["rating"]) - 0.4
	assert_eq(roundi(raw_ceiling), int(c["rating"]),
		"fixture sanity: this ceiling displays as the car's own rating")
	var verdict := ChallengeRunMode.classify_car(raw_ceiling, c["owned"], c["entry"])
	assert_eq(String(verdict["state"]), ChallengeRunMode.READY,
		"a car whose displayed rating equals the displayed ceiling is admitted")


func test_car_above_the_displayed_ceiling_is_excluded() -> void:
	var c := _boundary_car()
	# Rounds DOWN to one below the car's figure — the car really is over the cap the
	# player is shown, so rounding must not wave it through.
	var raw_ceiling: float = float(c["rating"]) - 0.6
	assert_eq(roundi(raw_ceiling), int(c["rating"]) - 1,
		"fixture sanity: this ceiling displays BELOW the car's own rating")
	var verdict := ChallengeRunMode.classify_car(raw_ceiling, c["owned"], c["entry"])
	assert_eq(String(verdict["state"]), ChallengeRunMode.EXCLUDED,
		"a car over the DISPLAYED ceiling is simply out — there is no detune escape")


# displayed_ceiling is what every challenge label prints, so it must be the rounding of
# the rolled ceiling — a relationship, not a value.
func test_displayed_ceiling_is_the_rounded_rolled_ceiling() -> void:
	var t := int(Time.get_unix_time_from_system())
	for kind in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		assert_eq(ChallengeRunMode.displayed_ceiling(kind, t),
			roundi(ChallengeLibrary.current_ceiling(kind, t)), "%s ceiling is rounded" % kind)


# classify_cars is the ONE place the rule lives — the HQ reads `ready` / `eligible` /
# `ceiling` straight out of it instead of re-deriving the comparison, so the two lists
# must agree with each other and with eligible_cars.
func test_classify_cars_reports_one_consistent_verdict_per_car() -> void:
	var t := int(Time.get_unix_time_from_system())
	var entry_under := _slow_entry("fx_under")
	var entry_over := _fast_entry("fx_over")
	var roster: Array[Dictionary] = CarFixtures.cars()
	roster.append(entry_under)
	roster.append(entry_over)
	CarLibrary.override_for_test(roster)
	CarPerformance.reset()

	var profile := {"cars": [
		{"instance_id": 1, "model_id": "fx_under", "installed_upgrades": [], "detune": 0.0},
		{"instance_id": 2, "model_id": "fx_over", "installed_upgrades": [], "detune": 0.0},
	]}
	assert_lt(float(_rating_of(profile["cars"][0], entry_under)), CEILING_BAND_MIN,
		"fixture sanity: the slow car is under every ceiling the band can roll")
	assert_gt(float(_rating_of(profile["cars"][1], entry_over)), CEILING_BAND_MAX,
		"fixture sanity: the fast car is over every ceiling the band can roll")

	var classified := ChallengeRunMode.classify_cars(ChallengeLibrary.WEEKLY, profile, t)
	assert_eq(classified["ready"], classified["eligible"],
		"ready and eligible hold the same cars — the two keys are for the UI's benefit")
	assert_eq(classified["eligible"], [profile["cars"][0]],
		"only the under-ceiling car is admitted")
	assert_eq(classified["ceiling"],
		ChallengeRunMode.displayed_ceiling(ChallengeLibrary.WEEKLY, t),
		"the reported ceiling is the displayed one")
	assert_eq(ChallengeRunMode.eligible_cars(ChallengeLibrary.WEEKLY, profile, t),
		classified["eligible"], "eligible_cars is the same list")


func test_eligible_cars_ignores_cars_missing_from_the_catalogue() -> void:
	var t := int(Time.get_unix_time_from_system())
	var profile := {"cars": [{"instance_id": 1, "model_id": "no_such_model"}]}
	var eligible := ChallengeRunMode.eligible_cars(ChallengeLibrary.DAILY, profile, t)
	assert_true(eligible.is_empty())


# --- report_event_result --------------------------------------------------------

# A challenge authors NO region — its stages are rolled from the period hash — so
# RunSession.region_id() is empty for one. world.gd::_current_region_look reads exactly
# this to decide whether a stage wears a region's look or the plain home default; pinning
# it here costs nothing, where pinning it against a built challenge world cost ~25 s
# (see test_world_fielding.gd).
func test_a_challenge_run_has_no_region() -> void:
	var t := int(Time.get_unix_time_from_system())
	RunSession.start(ChallengeLibrary.DAILY, _grant(), t)
	assert_eq(RunSession.mode_id(), RunMode.CHALLENGE, "setup: a challenge is live")
	assert_eq(RunSession.region_id(), "",
		"a challenge stage authors no region, so nothing region-scoped applies to it")


func test_report_event_result_appends_to_stage_times() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(ChallengeLibrary.WEEKLY, car, t)  # stage_count 4
	RunSession.report_event_result(50000)
	assert_eq(RunSession.stage_times_ms(), [50000])
	assert_eq(RunSession.events_completed(), 1)
	assert_eq(RunSession.cumulative_ms(), 50000)


func test_a_non_final_stage_continues_the_run_and_leaves_a_field_repair() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	var driven_id := int(car["instance_id"])
	RunSession.start(ChallengeLibrary.WEEKLY, car, t)  # stage_count 4

	# The per-stage upgrade DRAW is gone with the persistent parts model; a stage no
	# longer hands anything to the car. What survives, and is this test's real subject,
	# is the between-stage field repair below.
	RunSession.report_event_result(50000, 100.0)  # non-final: stage 1 of 4

	assert_true(RunSession.is_active(), "the run continues past a non-final stage")

	var repair := RunSession.take_pending_repair()
	assert_false(repair.is_empty(), "a non-final stage leaves a pending field repair")
	assert_true(RunSession.take_pending_repair().is_empty(),
		"the pending repair is consumed once (one-shot)")


func test_final_stage_ends_the_run_and_clears_the_persisted_profile() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(ChallengeLibrary.DAILY, car, t)  # stage_count 1

	var finished: Array = []
	RunSession.run_finished.connect(
		func(result: Dictionary) -> void: finished.append(result), CONNECT_ONE_SHOT)

	RunSession.report_event_result(40000)  # the only stage -> final

	assert_false(RunSession.is_active(), "the final stage ends the run")
	assert_eq(finished.size(), 1, "run_finished emitted exactly once")
	assert_true(bool(finished[0]["completed"]))
	assert_false(bool(finished[0]["dnf"]))
	assert_true(_save.profile[Save.KEY_RUN].is_empty(),
		"the persisted run slot clears once the run is over")
	assert_true(RunSession.take_pending_repair().is_empty(),
		"the final stage leaves no pending repair (no next stage to cushion for)")


# Drive every stage but the last, so the NEXT report_event_result is the final
# one. On a DAILY (one stage) this is a no-op and the very first stage is already
# the final stage — which is exactly the case items 2 and 5 have to survive.
func _run_up_to_the_final_stage() -> void:
	while RunSession.events_completed() < RunSession.stage_count() - 1:
		RunSession.report_event_result(50_000)
		RunSession.continue_to_next_stage()


# --- Item 2: the FINAL stage's interstitial belongs to the CHALLENGE ------------
#
# REMOVED (roguelike pivot, decision 30, todo/roguelike-pivot.md): both tests that
# lived in this section (`..._resolves_against_the_challenge_not_the_career` and
# `..._latched_mode_still_resolves_...`) asserted through `GlobalStandings.
# for_current_stage()`, which is deleted along with `global_standings.gd` /
# `standings.gd`. Their subject — the `standings_ready`-before-`run_finished`
# signal ORDER, and the session-latching fix (re-asking `is_active()` after the
# run ends silently routes to the wrong board) — is still real RunSession
# behaviour and still worth guarding once stage 3 (todo/roguelike-pivot-plan.md)
# gives the challenge run a new interstitial/run-summary host: re-derive
# equivalent coverage against whatever replaces `GlobalStandings.for_current_stage`
# then, rather than reintroducing this dependency now.

# --- Item 5: the final stage repairs, like a career rally's last event ----------

# RallySession._resolve_results applies the partial field repair after the FINAL
# event so its damage isn't left standing; the challenge's final branch used to be
# a literal `pass`. Both now go through the one shared writer
# (Save.apply_field_repair_to), which is what this asserts — an AGREEMENT
# between the two paths, so no repair fraction is pinned.
func test_the_final_stage_repairs_the_cars_damage_the_same_way_career_does() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	var driven_id := int(car["instance_id"])
	# A second, identical car that never enters the challenge: the career-side
	# control the challenge's result is compared against.
	var control_id := int(_grant()["instance_id"])
	var max_hp := float(_save.get_car(driven_id)["hp"])

	RunSession.start(ChallengeLibrary.DAILY, car, t)
	_run_up_to_the_final_stage()
	var hp_before_final := float(_save.get_car(driven_id)["hp"])
	var hp_lost := hp_before_final * 0.25
	var damaged := hp_before_final - hp_lost

	RunSession.report_event_result(45_000, hp_lost)  # the FINAL stage

	var hp_after := float(_save.get_car(driven_id)["hp"])
	assert_gt(hp_after, damaged,
		"the final stage's damage is patched up, not left standing until the next event")
	assert_true(hp_after <= max_hp, "and never beyond the car's own maximum")

	# The career path's final-event repair, applied to the control car from the
	# same damaged HP. Same shared writer, same config fractions -> same result.
	var control: Dictionary = _save.get_car(control_id)
	control["hp"] = damaged
	@warning_ignore("return_value_discarded")
	Save.apply_field_repair_to(control_id)
	assert_almost_eq(hp_after, float(_save.get_car(control_id)["hp"]), 0.001,
		"a challenge's final repair is exactly the repair a career rally's final event applies")

	assert_true(RunSession.take_pending_repair().is_empty(),
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
# standings.gd's Continue had no RunSession counterpart to
# RallySession.continue_to_next_event(), so the interstitial's only exit was a
# no-op. Drives a multi-stage run end to end through the same two calls the
# interstitial makes — report_event_result then continue_to_next_stage — and
# asserts it actually reaches the finish.
func test_a_multi_stage_run_advances_through_every_stage_to_the_finish() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	# Whichever kind currently has the MOST stages — the point is "more than one",
	# not any particular authored count.
	RunSession.start(_longest_kind(), car, t)
	var total := RunSession.stage_count()
	assert_true(total > 1, "the longest kind is multi-stage (else this proves nothing)")

	var finished: Array = []
	RunSession.run_finished.connect(
		func(result: Dictionary) -> void: finished.append(result), CONNECT_ONE_SHOT)
	var entered: Array = []
	RunSession.stage_started.connect(func(idx: int) -> void: entered.append(idx))

	for i in total:
		assert_eq(RunSession.events_completed(), i,
			"stage %d is the one about to run" % (i + 1))
		assert_false(RunSession.current_stage_params().is_empty(),
			"stage %d has a track to generate" % (i + 1))
		RunSession.report_event_result(50000 + i * 1000)
		RunSession.continue_to_next_stage()  # the interstitial's Continue

	assert_eq(RunSession.events_completed(), total, "every stage was driven")
	assert_false(RunSession.is_active(), "the run finished rather than stalling")
	assert_eq(finished.size(), 1, "run_finished fired exactly once, at the end")
	assert_eq(RunSession.stage_times_ms().size(), total, "every stage banked a time")
	# One re-entry per NON-final stage; the final stage ends the run instead, so its
	# continue is a no-op rather than a fifth scene load.
	assert_eq(entered.size(), total - 1, "the run re-entered driving once per remaining stage")


func test_continue_to_next_stage_is_a_no_op_once_the_run_is_over() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(ChallengeLibrary.DAILY, car, t)
	var entered: Array = []
	RunSession.stage_started.connect(func(idx: int) -> void: entered.append(idx))
	while RunSession.is_active():
		RunSession.report_event_result(40000)
		RunSession.continue_to_next_stage()
	var re_entries := entered.size()
	RunSession.continue_to_next_stage()  # must not error or re-enter driving
	assert_eq(entered.size(), re_entries,
		"a finished run never re-enters the driving scene")


# --- Run-summary times --------------------------------------------------------
#
# These two were ranked standings tables (RallyLibrary.build_standings with an empty
# rival field, rendering the player's own row alone). A run has no field to rank
# against, so they are plain ms time lists now: "the stage just finished" and "the
# run so far". What is pinned here is the RELATIONSHIP between them and the times
# reported in — not any particular duration.

func test_run_times_are_the_stage_just_driven_and_the_run_so_far() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(_longest_kind(), car, t)
	assert_eq(RunSession.current_stage_times_ms(), [],
		"no stage time before any stage completes")
	assert_eq(RunSession.run_times_ms(), [],
		"and no run breakdown either")

	RunSession.report_event_result(50000)
	assert_eq(RunSession.current_stage_times_ms(), [50000],
		"the stage just finished reports its own time, alone")
	assert_eq(RunSession.run_times_ms(), [50000],
		"and the run so far is that one stage")

	RunSession.continue_to_next_stage()
	RunSession.report_event_result(40000)
	assert_eq(RunSession.current_stage_times_ms(), [40000],
		"the second stage reports ITS time, not the running total")
	assert_eq(RunSession.run_times_ms(), [50000, 40000],
		"the run breakdown carries both stages, in stage order")
	var summed := 0
	for ms in RunSession.run_times_ms():
		summed += ms
	assert_eq(summed, RunSession.cumulative_ms(),
		"the breakdown sums to the run's cumulative time")


# --- The Phase.RUNNING gate on results -----------------------------------------
#
# A second result for a stage already reported
# (the interstitial is up; nothing is being driven) must not bank a phantom time.
func test_a_second_result_for_the_same_stage_is_ignored() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(_longest_kind(), car, t)
	RunSession.report_event_result(50_000)
	var banked := RunSession.stage_times_ms()
	var done := RunSession.events_completed()

	RunSession.report_event_result(1_000)

	assert_eq(RunSession.stage_times_ms(), banked, "no phantom time is banked")
	assert_eq(RunSession.events_completed(), done, "and the run does not skip a stage")


# --- pause_run: leaving the run is NOT a DNF (item 12) ------------------------
#
# The rule, from the user: nothing DNFs a challenge run any more — damage only ever
# weakens the car (features/damage.md). Everything that leaves the run — the pause
# menu's "Quit to HQ", starting a dev benchmark — pauses it, resumably. Leaving used
# to route to _end_as_dnf, which recorded a terminal per-period outcome, so stepping
# out to the garage permanently burned the period.
func test_pause_run_leaves_the_run_resumable_with_no_outcome_recorded() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(_longest_kind(), car, t)
	assert_gt(RunSession.stage_count(), 1, "setup: a multi-stage kind")
	RunSession.report_event_result(50_000)
	RunSession.continue_to_next_stage()
	var banked := RunSession.stage_times_ms()

	var finished: Array = []
	RunSession.run_finished.connect(
		func(result: Dictionary) -> void: finished.append(result), CONNECT_ONE_SHOT)

	RunSession.pause_run()

	assert_false(RunSession.is_active(), "the run stops being the active session")
	assert_false(RunSession.dnf(), "but it is NOT a DNF")
	assert_eq(finished.size(), 0, "and the run has not finished — no run_finished")
	assert_true(ChallengeRunMode.period_outcome(_save.profile,
		String(ChallengeLibrary.current_period(_longest_kind(), t)["key"])).is_empty(),
		"no terminal outcome is recorded, so the period is not spent")

	var run := RunSession.resumable_run(_save.profile, t)
	assert_false(run.is_empty(), "the stored run survives and is still resumable")
	assert_eq(int(run["stage_index"]), 1, "left on the stage it was paused on")
	assert_eq(run["stage_times_ms"], banked, "with its banked stage times intact")
	assert_eq(int(run["car_instance_id"]), int(car["instance_id"]))

	assert_true(RunSession.resume(t), "and resume picks it straight back up")
	assert_eq(RunSession.events_completed(), 1,
		"landing on the stage the run was paused on")
	assert_eq(RunSession.stage_times_ms(), banked)


func test_pause_run_is_a_no_op_when_not_active() -> void:
	assert_false(RunSession.is_active())
	RunSession.pause_run()  # must not error
	assert_false(RunSession.is_active())


# Starting a dev benchmark clears whatever session is live so world.gd doesn't boot
# the benchmark down the challenge path. That must PAUSE the run, not spend the
# player's one attempt at the period. Benchmark.start() itself is not callable from a
# test (it ends in change_scene_to_file, which would replace the GUT runner scene), so
# this asserts the property its call site depends on: leaving a run active-less costs
# nothing, on any number of repeats.
func test_leaving_and_re_entering_a_run_repeatedly_never_spends_the_period() -> void:
	var t := int(Time.get_unix_time_from_system())
	var car := _grant()
	RunSession.start(ChallengeLibrary.DAILY, car, t)
	for _i in 3:
		RunSession.pause_run()
		assert_false(RunSession.is_active())
		assert_true(RunSession.resume(t), "each pause is followed by a clean resume")
	assert_true(ChallengeRunMode.period_outcome(_save.profile,
		String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"])).is_empty(),
		"no outcome recorded — the period survives leaving the run")
	assert_false(RunSession.dnf())


# --- try_grant_completion_reward: DNF short-circuit (local-only) ---------------

func test_try_grant_completion_reward_returns_empty_on_dnf_without_touching_cloud() -> void:
	# Deliberately no Cloud/Cloud.challenge_leaderboard setup here: the
	# completed:false branch must return before ever reading Cloud, so this
	# call succeeding with no Cloud wired up IS the assertion.
	var result: Dictionary = await ChallengeRunMode.try_grant_completion_reward(
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
	assert_true(RunSession.start(ChallengeLibrary.DAILY, _grant(), t))
	var stage := RunSession.current_stage_params()
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
	assert_true(RunSession.start(ChallengeLibrary.MONTHLY, _grant(), t))
	assert_gt(RunSession.stage_count(), 1, "setup: a multi-stage kind")

	RunSession.report_event_result(60_000, 0.0)
	assert_eq(RunSession.events_completed(), 1, "setup: advanced onto stage 2")
	var stage_two := RunSession.current_stage_params()

	Config.data.track_seed = -1  # a value no roll can produce, so the write is observable
	RunSession.continue_to_next_stage()
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
	assert_true(RunSession.start(ChallengeLibrary.DAILY, _grant(), t))
	var stage := RunSession.current_stage_params()
	assert_false(stage.is_empty(), "setup: an active run exposes its current stage")

	var cfg: GameConfig = (load(Config.CONFIG_PATH) as GameConfig).duplicate()
	DrivingContext.apply_stage_config(cfg)
	var canonical := StageConfig.canonical_event_config(stage)

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
	assert_true(RunSession.start(ChallengeLibrary.DAILY, _grant(), t))
	assert_true(DrivingContext.session_active(),
		"a challenge run counts as an active driving session, same as a career rally")
	RunSession.pause_run()
	assert_false(DrivingContext.session_active(),
		"and it stops counting once the run ends")


# --- One attempt per period ------------------------------------------------------

# A finished run is TERMINAL for its period. _finish_locally clears
# challenge_run, so without a separate outcome record the entry screen would read
# "Not started" again and the player could re-run the period and post a second time.
func test_a_completed_period_cannot_be_started_again() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(RunSession.start(ChallengeLibrary.DAILY, _grant(), t))
	while RunSession.is_active():
		RunSession.report_event_result(60_000, 0.0)
	assert_false(RunSession.is_active(), "setup: the run played through to the end")

	assert_true(ChallengeRunMode.is_period_finished(ChallengeLibrary.DAILY, _save.profile, t),
		"the finished period is recorded as spent")
	var outcome := ChallengeRunMode.period_outcome(_save.profile,
		String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"]))
	assert_false(bool(outcome.get("dnf", true)), "it is recorded as a completion, not a DNF")
	assert_false(RunSession.start(ChallengeLibrary.DAILY, _grant(), t),
		"starting the same period again is refused")


# A DIFFERENT kind's period is untouched by another kind's outcome — they are
# independent runs, and only one can be active at a time.
func test_finishing_one_kind_leaves_the_others_startable() -> void:
	var t := int(Time.get_unix_time_from_system())
	assert_true(RunSession.start(ChallengeLibrary.DAILY, _grant(), t))
	while RunSession.is_active():
		RunSession.report_event_result(60_000, 0.0)
	assert_false(ChallengeRunMode.is_period_finished(ChallengeLibrary.WEEKLY, _save.profile, t),
		"the weekly period is untouched by the daily's outcome")
	assert_true(RunSession.start(ChallengeLibrary.WEEKLY, _grant(), t),
		"another kind can still be started")


# The outcome map must not grow one entry per day forever — only live periods survive
# a write. Uses a synthetic dead key rather than time travel.
func test_recording_an_outcome_prunes_periods_that_have_rolled_over() -> void:
	var t := int(Time.get_unix_time_from_system())
	_save.profile["challenge_results"] = {
		"daily:1999-01-01:e1": {"kind": ChallengeLibrary.DAILY, "dnf": false, "cumulative_ms": 1},
	}
	assert_true(RunSession.start(ChallengeLibrary.DAILY, _grant(), t))
	while RunSession.is_active():
		RunSession.report_event_result(60_000, 0.0)

	var results: Dictionary = _save.profile["challenge_results"]
	assert_false(results.has("daily:1999-01-01:e1"),
		"a period that has long since rolled over is dropped")
	assert_true(results.has(String(ChallengeLibrary.current_period(ChallengeLibrary.DAILY, t)["key"])),
		"the period just played is kept")

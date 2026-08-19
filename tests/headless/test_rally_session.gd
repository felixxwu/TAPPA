extends GutTest
# RallySession: the rally-level orchestrator (features/rally-session.md). Driven
# directly via report_event_result with a precomputed target list
# and a fixed opponent field — no real driving or scene loads. Runs against a
# throwaway Save profile so a real profile is never touched.

const TEST_PATH := "user://test_rally_session_profile.json"
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")

var _save: Node


func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	# Most tests here just need "a rally with events"; install the synthetic rally
	# roster so they don't lean on a shipped rally's identity. The endgame tests (which need
	# the real special ladder) opt back out via RallyFixtures.restore().
	RallyFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	# RallySession is a persistent autoload — make sure no prior test left it mid-
	# rally, and never let it touch scenes during a headless test.
	RallySession.auto_load_scenes = false
	if RallySession.is_active():
		RallySession.abandon()


func after_each() -> void:
	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()
	RallyFixtures.restore()
	UpgradeFixtures.restore()  # idempotent; only the drivetrain test installs it


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# A deterministic opponent field with the given combined times (all non-DNF), so
# placement is decoupled from the RNG-generated field.
func _field(combined: Array) -> Array:
	var f: Array = []
	for c in combined:
		f.append({"name": "Rival", "event_times_ms": [], "dnf": false, "combined_ms": int(c)})
	return f


# Total item count across the inventory (parts + consumables).
func _total_items() -> int:
	var n := 0
	for item_id in _save.profile["inventory"]:
		n += int(_save.profile["inventory"][item_id])
	return n


# GRANT a fresh car of `model_id` to the throwaway profile, then start `rally_id` with it,
# skipping track generation. Returns the owned-car dict that was granted.
#
# THE way to start a rally in this file — do not hand-roll grant-then-start_rally, or the
# next reader learns the long form from you.
#
# Named for what it DOES (it grants a car; the old name `_start` hid that) and both
# parameters are ids, not dicts: this used to shadow RallySession.start_rally(rally: Dictionary,
# owned: Dictionary, ...) positionally while meaning something different in slot 2, and callers
# passed an owned-car Dictionary where a model-id String was wanted.
func _grant_and_start(rally_id: String, model_id: String = "fx_light_rwd") -> Dictionary:
	var owned: Dictionary = _save.grant_car(model_id)
	RallySession.start_rally(RallyLibrary.by_id(rally_id), owned, true)
	return owned


# Drive a full set of events. The rally now PAUSES on a leaderboard after EVERY
# event (including the last — an event-only page that then resolves to the podium),
# so we continue past each one, the final continue triggering resolution.
func _report_events(times: Array) -> void:
	for i in times.size():
		RallySession.report_event_result(int(times[i]))
		RallySession.continue_to_next_event()


# Capture the next rally_finished result (one-shot, so nothing leaks across tests).
#
# Returns a TYPED one-slot box — `Array[Dictionary]`, empty until the rally resolves and
# holding exactly the finish result afterwards. Typed so `:=` infers at every call site.
# Read it with _finish_result(); that is the ONE unboxing idiom in this file (there used to
# be three, one of which — `var r := box[0]` — could not type-infer at all).
func _capture_finish() -> Array[Dictionary]:
	var box: Array[Dictionary] = []
	RallySession.rally_finished.connect(
		func(r: Dictionary) -> void: box.append(r), CONNECT_ONE_SHOT)
	return box


# Unbox a _capture_finish() handle: the finish result, or {} if the rally has not resolved.
# Use `assert_false(r.is_empty(), ...)` to assert that it did.
func _finish_result(box: Array[Dictionary]) -> Dictionary:
	return box[0] if not box.is_empty() else {}


# --- Special-event unlock reveal (todo/special-unlock-reveal.md) --------------

# A synthetic two-rung ladder gated on the fixture special, so none of these tests depend on
# an authored upgrade or on which real rally gates what.
func _install_unlock_ladder() -> void:
	# `free: true` is vestigial here now. It used to keep these parts OUT of the ordinary
	# per-event upgrade draw, which would otherwise have awarded fx_top by the normal path
	# the moment the gate opened and made an "it wasn't re-awarded" assertion fail for the
	# wrong reason. That draw is gone, so nothing competes with the special's direct award
	# any more — the flag is left in place because it is also what makes these fixture rungs
	# selectable without a purchase, which several assertions below rely on.
	var upgrades: Array[Dictionary] = [
		{"id": "fx_base", "name": "Fixture Base", "slot": "fxslot", "consumable": false,
			"cost": 0, "free": true, "power_mult": 1.05},
		{"id": "fx_top", "name": "Fixture Top", "slot": "fxslot", "consumable": false,
			"cost": 0, "free": true, "power_mult": 1.1,
			"requires_upgrade_id": "fx_base", "unlocked_by_rally": "fx_showdown"},
	]
	UpgradeLibrary.override_for_test(upgrades)


# Start `rally_id` against a deliberately SLOW one-rival field, so the player's times place
# P1 and the top-3 gate is satisfied. These tests are about the unlock, not about pace, and
# the generated field is fast enough that plausible times would not reliably win.
func _start_winnable(rally_id: String) -> Dictionary:
	var owned := _grant_and_start(rally_id)
	RallySession._opponent_field = [
		{"name": "Backmarker", "car_id": "fx_light_rwd", "engine_id": "",
			"car_name": "Backmarker", "event_times_ms": [90000, 90000, 90000],
			"dnf": false, "combined_ms": 270000,
			"wreck_event": -1, "wreck_progress": 0.0, "wreck_side": 1.0},
	]
	return owned


# Winning a special for the FIRST time announces the upgrade its star gate opened, hands it
# to the car that just earned it, and — unlike an ordinary rally — pays NO car.
func test_a_first_special_win_unlocks_an_upgrade_and_pays_no_car() -> void:
	_install_unlock_ladder()
	var owned := _start_winnable("fx_showdown")
	var box := _capture_finish()
	_report_events([30000, 30000, 30000])
	var result := _finish_result(box)
	assert_false(result.is_empty(), "the rally resolved")
	assert_true(bool(result["completed"]), "precondition: the fixture times place top-3")

	var unlock: Dictionary = result.get("special_unlock", {})
	assert_false(unlock.is_empty(), "a first special win reports an unlock")
	assert_eq(String(unlock.get("item_id", "")), "fx_top", "it names the part the special gates")
	assert_eq(String(result.get("car_reward", "")), "",
		"a special pays an upgrade INSTEAD of a car")

	# Granted to the driven car, headline enabled, prerequisite fitted-but-parked.
	var car: Dictionary = _save.get_car(int(owned["instance_id"]))
	var installed: Array = car.get("installed_upgrades", [])
	assert_true(installed.has("fx_top"), "the headline part is fitted to the driven car")
	assert_true(installed.has("fx_base"),
		"the missing prerequisite rung was granted too, so the headline is usable")
	assert_true(UpgradeLibrary.prerequisite_met("fx_top", car),
		"the cascade satisfies the headline's prerequisite")
	var disabled: Array = car.get("disabled_upgrades", [])
	assert_false(disabled.has("fx_top"), "the headline is ENABLED on award")
	assert_true(disabled.has("fx_base"),
		"the prerequisite rung stays parked — a ladder shares one slot, so only one runs")
	UpgradeLibrary.reset()


# --- Car-unlock rallies ------------------------------------------------------
# A rally carrying `prize_car` hands that car over on a first podium finish. This is the
# ONLY route to a new car now — nothing is drawn at random and nothing is bought.

# The fixture roster with a car-unlock rally bolted on: fx_prize awards a car the garage
# does not start with. Synthetic throughout — the shipped pairing of car to rally is
# tunable content a designer re-pairs freely.
# How many owned cars are of this catalogue model — the figure a duplicate-prize check
# needs, since the garage total also moves when a test grants a car to drive.
func _owned_count_of(model_id: String) -> int:
	var n := 0
	for car in _save.profile.get("cars", []):
		if String((car as Dictionary).get("model_id", "")) == model_id:
			n += 1
	return n


func _install_car_prize_rally(car_id: String) -> void:
	var rallies := RallyFixtures.rallies()
	var prize := (rallies[0] as Dictionary).duplicate(true)
	prize["id"] = "fx_prize"
	prize["name"] = "Fixture Prize"
	prize["prize_car"] = car_id
	rallies.append(prize)
	RallyLibrary.override_for_test(rallies)


func test_a_first_car_unlock_win_hands_over_the_car() -> void:
	var prize_id := String(CarFixtures.cars()[1]["id"])
	_install_car_prize_rally(prize_id)
	_start_winnable("fx_prize")
	var box := _capture_finish()
	_report_events([30000, 30000, 30000])
	var result := _finish_result(box)
	assert_true(bool(result["completed"]), "precondition: the fixture times place top-3")

	# Reported through the podium's existing CAR_REVEAL pair, so the reveal beat is the
	# same one the retired random draw used.
	assert_eq(String(result.get("car_reward", "")), prize_id,
		"the result names the car the rally advertised")
	assert_true(bool(result.get("car_reward_is_new", false)), "and flags it as new")
	assert_true(_save.owns_model(prize_id), "the garage now holds it")


func test_re_winning_a_car_unlock_rally_pays_no_second_car() -> void:
	# Prize rallies stay re-runnable for stars, but a car is minted ONCE. Otherwise one easy
	# prize rally farms duplicates of the same car for ever — the exact grind the retired
	# random draw allowed, since that fired on re-wins too.
	var prize_id := String(CarFixtures.cars()[1]["id"])
	_install_car_prize_rally(prize_id)
	_start_winnable("fx_prize")
	_report_events([30000, 30000, 30000])
	assert_eq(_owned_count_of(prize_id), 1, "precondition: the first win handed one over")

	_start_winnable("fx_prize")
	var box := _capture_finish()
	_report_events([30000, 30000, 30000])
	assert_eq(String(_finish_result(box).get("car_reward", "")), "",
		"a re-win reports no car")
	# Counts copies of the PRIZE MODEL, not the garage total: _grant_and_start grants a fresh car to
	# drive on every run, so the total legitimately grows and would hide the duplicate.
	assert_eq(_owned_count_of(prize_id), 1, "and mints no duplicate")


func test_an_ordinary_rally_hands_over_no_car() -> void:
	# The counterpart guarantee: cars come ONLY from rallies that advertise one, so a plain
	# win cannot quietly top the garage up the way the old random draw did. That is what
	# keeps the per-rally `restriction` bands meaningful.
	_start_winnable("fx_open")
	var box := _capture_finish()
	# Counted AFTER _start_winnable, which grants the car being driven — so anything the
	# finish adds shows up as a change.
	var owned_before: int = (_save.profile["cars"] as Array).size()
	_report_events([30000, 30000, 30000])
	assert_eq(String(_finish_result(box).get("car_reward", "")), "",
		"an ordinary win reports no car")
	assert_eq((_save.profile["cars"] as Array).size(), owned_before,
		"and the garage is unchanged (the driven car was granted before the count)")


# The gate itself must still be recorded. Dropping the car draw for specials must not take
# Save.complete_rally with it — that is what opens the upgrade for the whole garage.
func test_a_special_win_still_records_completion() -> void:
	_install_unlock_ladder()
	_start_winnable("fx_showdown")
	_report_events([30000, 30000, 30000])
	assert_true(bool((_save.profile.get("rallies", {}) as Dictionary)
		.get("fx_showdown", {}).get("completed", false)),
		"the special is recorded completed, so its upgrade gate is open")
	assert_true(UpgradeLibrary.rally_gate_met("fx_top", _save.profile),
		"and the gated part is now winnable from ordinary rallies")
	UpgradeLibrary.reset()


# Re-winning a special announces nothing and re-awards nothing — the reveal is a
# first-completion beat, and the profile can't distinguish afterwards, so this guards the
# capture-before-complete_rally ordering.
func test_re_winning_a_special_reveals_and_awards_nothing() -> void:
	_install_unlock_ladder()
	_start_winnable("fx_showdown")
	_report_events([30000, 30000, 30000])

	# Second run of the same special, fresh car so a re-award would be visible.
	var owned := _start_winnable("fx_showdown")
	var box := _capture_finish()
	_report_events([30000, 30000, 30000])
	var result := _finish_result(box)
	assert_true((result.get("special_unlock", {}) as Dictionary).is_empty(),
		"a re-win reports no unlock")
	var car: Dictionary = _save.get_car(int(owned["instance_id"]))
	assert_false((car.get("installed_upgrades", []) as Array).has("fx_top"),
		"and hands out nothing a second time")
	UpgradeLibrary.reset()


# The fixture special is re-ided to the gate const, so this leans on the CONST rather than on
# the shipped roster.
func test_winning_the_capability_special_announces_the_unlock_with_nothing_to_grant() -> void:
	var roster: Array[Dictionary] = RallyFixtures.rallies()
	for r in roster:
		if bool(r.get("special", false)):
			r["id"] = RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY
	RallyLibrary.override_for_test(roster)

	_start_winnable(RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY)
	var box := _capture_finish()
	_report_events([30000, 30000, 30000])
	var result := _finish_result(box)
	var unlock: Dictionary = result.get("special_unlock", {})
	assert_eq(String(unlock.get("capability", "")), "engine_swap",
		"the capability unlock is announced even with no part to name")
	assert_eq(String(unlock.get("item_id", "")), "",
		"and it names no catalogue item, because there isn't one")
	# Nothing is HANDED OVER any more. Winning the special unlocks swapping outright and
	# swaps are free and unlimited from then on, so there is no consumable to bank — the
	# announcement is the whole reward.
	assert_eq(unlock.get("granted", []), [] as Array,
		"the unlock grants no item: the capability itself is the prize")
	RallyLibrary.reset()


# An ordinary rally unlocks nothing and — since the star economy — pays no car either.
# Winning pays STARS; cars are bought at the present box (todo/star-economy.md).
func test_an_ordinary_win_reports_no_unlock_and_pays_stars_not_a_car() -> void:
	_install_unlock_ladder()
	_start_winnable("fx_open")
	var box := _capture_finish()
	_report_events([30000, 30000, 30000])
	var result := _finish_result(box)
	assert_true((result.get("special_unlock", {}) as Dictionary).is_empty(),
		"an ordinary rally unlocks nothing")
	assert_eq(String(result.get("car_reward", "")), "",
		"no rally pays a car any more — cars are bought with stars")
	assert_gt(int(result.get("stars_gained", 0)), 0, "a first win credits stars instead")
	UpgradeLibrary.reset()


# The start-line "time to beat" — the fastest non-DNF rival's time for the CURRENT
# event, tracking the event index as the rally advances. -1 when idle.
func test_current_event_target_ms_tracks_fastest_rival_per_event() -> void:
	assert_eq(RallySession.current_event_target_ms(), -1, "idle: no time to beat")
	_grant_and_start("fx_open")
	RallySession._opponent_field = [
		{"name": "A", "event_times_ms": [50000, 82000, 82000], "dnf": false, "combined_ms": 214000},
		{"name": "B", "event_times_ms": [45000, 90000, 90000], "dnf": false, "combined_ms": 225000},
		{"name": "C", "event_times_ms": [-1, 70000, 70000], "dnf": true, "combined_ms": -1},
	]
	# Event 0: C did not set a time (-1, skipped), so the fastest is B's 45000.
	assert_eq(RallySession.current_event_target_ms(), 45000, "event 0 fastest rival time")
	RallySession.report_event_result(60000)   # -> standings
	RallySession.continue_to_next_event()      # -> event 1
	assert_eq(RallySession.event_index(), 1, "advanced to event 1")
	# Event 1: C's 70000 now counts and is the fastest.
	assert_eq(RallySession.current_event_target_ms(), 70000, "event 1 fastest rival time")


# The start-line reveal lists the top three rivals for the CURRENT event — fastest
# first, each with the car they drove — and skips any who DNF'd this event.
func test_current_event_leaders_lists_top_three_with_cars() -> void:
	assert_true(RallySession.current_event_leaders().is_empty(), "idle: no leaders")
	_grant_and_start("fx_open")
	RallySession._opponent_field = [
		{"name": "A", "car_id": "fx_awd", "car_name": "Fixture AWD", "event_times_ms": [50000, 0, 0], "dnf": false, "combined_ms": 1},
		{"name": "B", "car_id": "fx_rwd_coupe", "car_name": "Fixture Coupe", "event_times_ms": [45000, 0, 0], "dnf": false, "combined_ms": 1},
		{"name": "C", "car_id": "fx_fwd_hatch", "car_name": "Fixture Hatch", "event_times_ms": [-1, 0, 0], "dnf": true, "combined_ms": -1},
		{"name": "D", "car_id": "fx_light_rwd", "car_name": "Fixture Roadster", "event_times_ms": [60000, 0, 0], "dnf": false, "combined_ms": 1},
	]
	# Event 0: C set no time (-1, omitted). Fastest-first: B 45k, A 50k, D 60k.
	var leaders := RallySession.current_event_leaders(3)
	assert_eq(leaders.size(), 3, "the top three rivals for the event are returned")
	assert_eq(String(leaders[0]["name"]), "B", "the fastest rival leads")
	assert_eq(String(leaders[0]["car_name"]), "Fixture Coupe", "the leader's car comes through")
	assert_eq(String(leaders[0]["car_id"]), "fx_rwd_coupe", "the leader's car_id (for the grid) comes through")
	assert_eq(int(leaders[0]["time_ms"]), 45000, "the leader's event time comes through")
	assert_eq(String(leaders[2]["name"]), "D", "third fastest is listed third")
	for e in leaders:
		assert_ne(String(e["name"]), "C", "a rival who DNF'd this event is omitted")


# Between-event pit repairs: the fielded car is patched up entering every event
# AFTER the first (never the first), and the summary is exposed once for the popup.
func test_pit_repair_fires_at_each_event_after_the_first() -> void:
	var owned := _grant_and_start("fx_open")
	RallySession._opponent_field = _field([200000, 210000, 220000])
	var id: int = owned["instance_id"]
	# The first event gets no pit repair — the car starts the rally fresh.
	assert_false(RallySession.take_pending_repair().get("repaired", false), "no repair before the first event")
	# Finish event 0 having taken damage, then advance into event 1.
	RallySession.report_event_result(60000, 300.0)
	var hp_after_damage := float(_save.get_car(id)["hp"])
	RallySession.continue_to_next_event()  # -> _enter_event(event 1): repair runs
	assert_eq(RallySession.event_index(), 1, "advanced to event 1")
	var repair := RallySession.take_pending_repair()
	assert_true(repair.get("repaired", false), "the engineers repaired the car entering event 1")
	assert_gt(float(_save.get_car(id)["hp"]), hp_after_damage, "hp climbed back after the pit repair")
	assert_false(RallySession.take_pending_repair().get("repaired", false), "the repair summary is consumed once")


# The final event's damage previously carried forward unrepaired (only events AFTER
# the first got a courtesy repair, and there's no "next event" after the last one to
# trigger it). _resolve_results now applies the same partial field repair the
# between-event transitions get — but silently, with nothing left for the podium's
# repair popup to pick up.
func test_final_event_damage_is_repaired_on_resolve_silently() -> void:
	var owned := _grant_and_start("fx_open")
	RallySession._opponent_field = _field([200000, 210000, 220000])
	var id: int = owned["instance_id"]
	var box := _capture_finish()
	RallySession.report_event_result(60000, 300.0)   # event 0, undamaged repair path
	RallySession.continue_to_next_event()             # -> event 1 (repaired, consumed below)
	RallySession.take_pending_repair()
	RallySession.report_event_result(60000, 300.0)   # event 1
	RallySession.continue_to_next_event()             # -> event 2 (repaired, consumed below)
	RallySession.take_pending_repair()
	RallySession.report_event_result(60000, 300.0)   # event 2 (final): damage taken, never repaired pre-fix
	var hp_after_damage := float(_save.get_car(id)["hp"])
	var max_hp := float(CarLibrary.by_id(_save.get_car(id)["model_id"]).get("max_hp", hp_after_damage))
	assert_lt(hp_after_damage, max_hp, "the final hit actually damaged the car")
	RallySession.continue_to_next_event()             # -> _resolve_results: silent final repair
	assert_false(_finish_result(box).is_empty(), "the rally finished")
	var hp_after_finish := float(_save.get_car(id)["hp"])
	assert_gt(hp_after_finish, hp_after_damage, "the final-event damage was partially repaired on finish")
	assert_lt(hp_after_finish, max_hp, "the repair is partial, not a full heal, matching every other stage-to-stage repair")
	assert_false(RallySession.take_pending_repair().get("repaired", false), "the final-event repair does not surface a repair popup")


# --- The clean-run damage signal ---------------------------------------------
#
# HP cannot answer "did the player take damage this rally": field repairs run at every
# event boundary AND on the first lines of _resolve_results, and a car can enter a rally
# already damaged because HQ repairs cost stars. RallySession latches the fact instead.

func test_a_rally_with_no_damage_reports_a_clean_run() -> void:
	_grant_and_start("fx_open")
	RallySession._opponent_field = _field([200000, 210000, 220000])
	var box := _capture_finish()
	assert_false(RallySession.took_damage_this_rally(), "a fresh rally starts on a clean sheet")
	_report_events([60000, 60000, 60000])
	assert_false(_finish_result(box).get("took_damage", true),
		"a rally driven without a scratch reports took_damage false")


func test_damage_in_any_event_survives_the_repairs_to_resolve_time() -> void:
	# The whole point of the flag: the hit lands in the FIRST event, is partly repaired
	# entering every later event and again on resolve — and is still reported at the finish.
	_grant_and_start("fx_open")
	RallySession._opponent_field = _field([200000, 210000, 220000])
	var box := _capture_finish()
	RallySession.report_event_result(60000, 300.0)
	assert_true(RallySession.took_damage_this_rally(), "the hit is latched immediately")
	RallySession.continue_to_next_event()
	_report_events([60000, 60000])
	assert_true(_finish_result(box).get("took_damage", false),
		"the damage is still reported at the finish, after every repair has run")


func test_a_new_rally_clears_the_damage_flag_from_the_previous_one() -> void:
	_grant_and_start("fx_open")
	RallySession._opponent_field = _field([200000, 210000, 220000])
	RallySession.report_event_result(60000, 300.0)
	RallySession.continue_to_next_event()
	_report_events([60000, 60000])
	assert_true(RallySession.took_damage_this_rally(), "setup: the finished rally was damaging")
	# A car that arrives already damaged is NOT carrying the previous rally's verdict.
	_grant_and_start("fx_open")
	assert_false(RallySession.took_damage_this_rally(),
		"starting a rally resets the clean-run sheet")


# current_event_wreck surfaces the rival who crashed out of the CURRENT event (with the
# actual car they drove), tracking the event index, and is empty for an event nobody
# wrecked in. Built from a synthetic field so it leans on the delegation, not on a roll.
func test_current_event_wreck_tracks_the_crashed_rival_per_event() -> void:
	assert_true(RallySession.current_event_wreck().is_empty(), "idle: no wreck")
	_grant_and_start("fx_open")
	RallySession._opponent_field = [
		{"name": "A", "car_id": "carA", "car_name": "Car A", "event_times_ms": [50000, 82000, 82000],
			"dnf": false, "combined_ms": 214000, "wreck_event": -1, "wreck_progress": 0.0, "wreck_side": 1.0},
		{"name": "B", "car_id": "carB", "car_name": "Car B", "event_times_ms": [45000, -1, -1],
			"dnf": true, "combined_ms": -1, "wreck_event": 1, "wreck_progress": 0.3, "wreck_side": -1.0},
	]
	# Event 0: nobody wrecked.
	assert_true(RallySession.current_event_wreck().is_empty(), "event 0: no wreck to stage")
	RallySession.report_event_result(60000)   # -> standings
	RallySession.continue_to_next_event()      # -> event 1
	assert_eq(RallySession.event_index(), 1, "advanced to event 1")
	# Event 1: B crashed out — surfaced with the actual car B drove.
	var w := RallySession.current_event_wreck()
	assert_false(w.is_empty(), "event 1: a wreck to stage")
	assert_eq(String(w.get("car_id", "")), "carB", "the crashed rival's actual car")
	assert_eq(String(w.get("name", "")), "B", "the crashed rival's name")


# The leaderboard carries the car each entrant drove — the rivals' and the
# player's fielded car.
func test_standings_carry_the_player_and_rival_cars() -> void:
	_grant_and_start("fx_open", "fx_light_rwd")
	RallySession._opponent_field = [
		{"name": "Quick", "car_name": "Fixture Coupe", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
	]
	RallySession.report_event_result(50000)
	var player := {}
	var rival := {}
	for e in RallySession.current_standings():
		if e["is_player"]:
			player = e
		else:
			rival = e
	assert_eq(String(rival["car_name"]), "Fixture Coupe", "the rival's car is in the standings")
	assert_eq(String(player["car_name"]), "Fixture Roadster", "the player's fielded car is in the standings")


func test_standings_carry_the_garage_name_for_a_swapped_engine() -> void:
	# _player_car_name() must report the GARAGE name (EngineSwap.display_name, layout-
	# prefixed) into the standings, not the bare catalogue name — matching what HQ
	# calls the same car one screen earlier. fx_light_rwd's stock engine is "fx_i4"
	# (layout i4); swap it directly to "fx_v8" (layout v8) on the fielded instance.
	var owned := _grant_and_start("fx_open", "fx_light_rwd")
	var car: Dictionary = _save.get_car(int(owned["instance_id"]))
	car["swapped_engine"] = "fx_v8"
	RallySession._opponent_field = [
		{"name": "Quick", "car_name": "Fixture Coupe", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
	]
	RallySession.report_event_result(50000)
	var player := {}
	for e in RallySession.current_standings():
		if e["is_player"]:
			player = e
	assert_eq(String(player["car_name"]), "V8 Fixture Roadster",
		"the swapped-in engine's layout prefixes the garage display name")


func test_idle_when_no_rally() -> void:
	assert_false(RallySession.is_active(), "no session active at rest")
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "phase is IDLE")


func test_happy_path_accumulates_and_places() -> void:
	var finish := _capture_finish()
	_grant_and_start("fx_open")
	RallySession._opponent_field = _field([50000, 60000, 70000, 80000, 90000])
	RallySession.report_event_result(20000)
	RallySession.continue_to_next_event()
	RallySession.report_event_result(20000)
	assert_eq(RallySession.event_times_ms(), [20000, 20000] as Array[int], "times accumulate per event")
	RallySession.continue_to_next_event()
	RallySession.report_event_result(20000)  # 3rd event -> pauses on the event-only standings
	assert_eq(RallySession.phase(), RallySession.Phase.STANDINGS, "the final event pauses on its event standings")
	RallySession.continue_to_next_event()    # -> resolve
	var r := _finish_result(finish)
	assert_false(r.is_empty(), "rally_finished emitted")
	assert_eq(r["combined_ms"], 60000, "combined = sum of event times")
	# Field has one opponent (50000) faster than 60000 -> placed 2nd.
	assert_eq(r["placed"], 2, "placement counts faster non-DNF opponents")
	assert_true(r["completed"], "a top-3 finish completes the rally")
	assert_false(r["dnf"], "not a DNF")
	assert_true(_save.rally_completed("fx_open"), "completion recorded in the save")
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "session returns to IDLE after finishing")


func test_result_carries_rewards_and_standings_for_the_podium() -> void:
	var finish := _capture_finish()
	var driven := _grant_and_start("fx_open")  # the entry rally (a low p/w cap), difficulty 1
	# Player combined 60000; one opponent faster (50000) -> placed 2nd, top-3 win.
	RallySession._opponent_field = _field([50000, 70000, 80000])
	# Snapshot ownership BEFORE the finish: a top-3 win grants the reward car, so the
	# is_new flag (computed at draw time) must be checked against the pre-grant garage.
	var owned_before := {}
	for c in _save.profile.get("cars", []):
		owned_before[String(c.get("model_id", ""))] = true
	_report_events([20000, 20000, 20000])
	var r := _finish_result(finish)
	assert_eq(r["rally_name"], "Fixture Open", "result names the rally for the podium header")
	# No car is drawn by a finish any more — the reward is STARS, and the result carries
	# both what the rally is now RATED and what the ledger actually gained, which the
	# podium's stars beat shows separately (todo/star-economy.md).
	assert_eq(String(r["car_reward"]), "", "a finish pays no car")
	assert_eq(_save.profile["cars"].size(), owned_before.size(),
		"the garage is unchanged by a win")
	assert_gt(int(r["stars_gained"]), 0, "a first top-3 finish credits stars")
	assert_eq(int(r["star_rating"]),
		RallyLibrary.stars_for_placement(_save.best_placement("fx_open")),
		"the rating matches the recorded best placement")
	assert_false(r["game_won"], "an ordinary rally is not the endgame")
	# The result names the owned-car instance the player drove, which the podium needs for
	# the car-reveal and unlock beats.
	assert_eq(int(r["car_instance_id"]), int(driven["instance_id"]),
		"the result carries the driven car's instance id for the apply-upgrade choice")
	# A 2nd-place finish records best placement 2 (drives the world-map stars).
	assert_eq(_save.best_placement("fx_open"), 2, "the best finishing position is recorded")
	# Standings = field (3) + player, ranked, player classified 2nd.
	var standings: Array = r["standings"]
	assert_eq(standings.size(), 4, "standings includes the player plus the opponent field")
	var player: Dictionary = {}
	for e in standings:
		if e["is_player"]:
			player = e
	assert_eq(player["placed"], 2, "the player's standings position matches the placement")


# DEV shortcut: dev_complete_rally credits every event a 0 ms time and resolves
# straight to the podium as a top-3 win, from anywhere mid-rally (here, before a
# single event has run) — so the settings dev button can hand the player the car.
func test_dev_complete_rally_wins_immediately_from_mid_rally() -> void:
	var finish := _capture_finish()
	_grant_and_start("fx_open")
	RallySession._opponent_field = _field([50000, 60000, 70000])
	# No event has been reported yet; complete the whole rally in one shot.
	RallySession.dev_complete_rally()
	var r := _finish_result(finish)
	assert_false(r.is_empty(), "rally_finished emitted straight to the podium")
	assert_eq(r["combined_ms"], 0, "every event is credited a perfect 0 ms time")
	assert_eq(r["placed"], 1, "a 0 ms combined out-runs the whole field -> P1")
	assert_true(r["completed"], "a P1 finish completes the rally (top-3)")
	assert_false(r["dnf"], "not a DNF")
	assert_true(_save.rally_completed("fx_open"), "completion recorded in the save")
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "session returns to IDLE after finishing")


# dev_complete_rally does nothing when no rally is active (the button is hidden in
# HQ, but the brain must be safe if driven directly).
func test_dev_complete_rally_is_a_noop_when_idle() -> void:
	assert_false(RallySession.is_active(), "no rally active to begin with")
	RallySession.dev_complete_rally()
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "stays idle — nothing to complete")


func test_between_event_standings_pause_and_leaderboard() -> void:
	_grant_and_start("fx_open")
	# Two rivals: one quick (40k/event), one slow (80k/event). Player runs 50k/event.
	RallySession._opponent_field = [
		{"name": "Quick", "event_times_ms": [40000, 40000, 40000], "dnf": false, "combined_ms": 120000},
		{"name": "Slow", "event_times_ms": [80000, 80000, 80000], "dnf": false, "combined_ms": 240000},
	]
	RallySession.report_event_result(50000)
	# After event 1 the rally PAUSES on the standings (it does not auto-advance).
	assert_eq(RallySession.phase(), RallySession.Phase.STANDINGS, "the rally pauses on the standings after an event")
	assert_eq(RallySession.events_completed(), 1, "one event completed")
	# Leaderboard so far (cumulative over 1 event): Quick 40k, player 50k, Slow 80k.
	var s := RallySession.current_standings()
	assert_eq(s.size(), 3, "the player + both rivals are ranked")
	assert_eq(String(s[0]["name"]), "Quick", "the quickest rival leads after event 1")
	assert_true(s[1]["is_player"], "the player sits 2nd on cumulative time")
	assert_eq(s[1]["combined_ms"], 50000, "the player's cumulative time is its one event so far")
	# Resume into the next event.
	RallySession.continue_to_next_event()
	assert_eq(RallySession.phase(), RallySession.Phase.RUNNING, "continuing resumes the next event")
	assert_eq(RallySession.event_index(), 1, "now running event index 1")


# Damage can never end a rally: HP bottoms out at 0 and the car drives on, weakened
# (features/damage.md). A run driven to completion on a car that is already at — and stays
# at — 0 HP therefore resolves like any other: no DNF for the player, a real placement and
# a real combined time.
func test_a_rally_driven_out_on_a_zero_hp_car_resolves_normally() -> void:
	var finish := _capture_finish()
	var owned := _grant_and_start("fx_open")
	var id := int(owned["instance_id"])
	_save.apply_damage(id, 999999.0)  # on the floor before the first stage
	RallySession._opponent_field = _field([50000])
	var stages := RallySession.stage_count()
	var times: Array = []
	for _i in stages:
		times.append(20000)
	_report_events(times)
	var r := _finish_result(finish)
	assert_false(r.is_empty(), "the rally resolved")
	assert_false(r["dnf"], "a 0-HP car never DNFs the player")
	assert_gt(int(r["placed"]), 0, "it places like any finish")
	assert_gt(int(r["combined_ms"]), 0, "and carries a real combined time")
	# And the car is still there — nothing wrote it off for being on the floor. (Its HP is
	# NOT asserted at 0: _resolve_results runs the silent final field repair first.)
	assert_false(_save.get_car(id).is_empty(), "the car is kept")
	assert_gte(float(_save.get_car(id)["hp"]), 0.0, "with sane health")


func test_no_retry_reenter_resets_and_field_is_fixed() -> void:
	# What is under test is the RALLY-SEED determinism: the same rally, re-entered with the
	# same car, fields the same grid. Adaptive difficulty is switched off for it because it
	# deliberately breaks that: the three lost stages below move the offset, so the re-draw
	# is matched to a different rating on purpose (see features/adaptive-difficulty.md, and
	# test_refielding_keeps_the_difficulty_offset for the property that replaces it).
	Config.data.ai_adapt_enabled = false
	var owned := _grant_and_start("fx_open")
	var id := int(owned["instance_id"])
	var field1: Array = RallySession.opponent_field().duplicate(true)
	# A slow, non-top-3 finish (slower than every opponent).
	var finish := _capture_finish()
	RallySession._opponent_field = _field([10000, 20000, 30000, 40000, 50000])
	_report_events([1_000_000, 1_000_000, 1_000_000])
	var r := _finish_result(finish)
	assert_false(r["completed"], "a non-top-3 finish does not complete the rally")
	assert_eq(r["placed"], 6, "slower than all 5 opponents -> placed 6th")
	assert_false(_save.rally_completed("fx_open"), "an incomplete rally stays incomplete (no retry)")
	assert_false(_save.get_car(id).is_empty(), "the car survives a non-DNF finish")

	# Re-enter from the map: state resets, the opponent field is unchanged (fixed
	# per rally seed), and persisted HP is untouched.
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), _save.get_car(id), true)
	assert_eq(RallySession.event_index(), 0, "event index resets on re-entry")
	assert_true(RallySession.event_times_ms().is_empty(), "event times reset on re-entry")
	assert_eq(RallySession.opponent_field(), field1, "the opponent field is identical across re-attempts")


# Every special that isn't `keep_id`, marked completed in the profile. Derived from the
# catalogue rather than hardcoding ids, so re-siting or re-rung-ing a special can't
# silently stop these tests exercising what they claim to.
func _complete_other_specials(keep_id: String) -> void:
	for rally in RallyLibrary.all():
		var rid := String(rally.get("id", ""))
		if RallyLibrary.is_special(rally) and rid != keep_id:
			_save.complete_rally(rid, 1000)


# The id of the special the map reaches FIRST — the one a player meets soonest, and so the
# cheapest to make enterable in a test. Reveal is geometric now, so "first" is a
# reachability wave (RallyLibrary.reveal_depths), not an authored rung.
func _lowest_special_id() -> String:
	var depth := RallyLibrary.reveal_depths()
	var best := ""
	var best_wave := 1 << 30
	for rally in RallyLibrary.all():
		var rid := String(rally["id"])
		if RallyLibrary.is_special(rally) and int(depth.get(rid, 1 << 30)) < best_wave:
			best_wave = int(depth.get(rid, 1 << 30))
			best = rid
	return best


func test_win_beat_fires_once_every_special_is_done() -> void:
	# Credits require EVERY special on the ladder completed — no designated finale
	# rally. So win the LAST outstanding special: with all the others already recorded,
	# this finish completes the set and must fire the win beat. Which special is "last"
	# is deliberately not pinned; any one of them completes the set when it's the only
	# one left.
	RallyFixtures.restore()  # this test needs the REAL roster
	var last := _lowest_special_id()
	assert_ne(last, "", "the shipped roster authors at least one special")
	_complete_other_specials(last)
	var won: Array = [false]
	RallySession.game_won.connect(func() -> void: won[0] = true, CONNECT_ONE_SHOT)
	_grant_and_start(last)
	RallySession._opponent_field = _field([90000])  # player will be top-3
	var cars_before: int = _save.profile["cars"].size()
	_report_events([10000, 10000, 10000])
	assert_true(won[0], "completing the final outstanding special fires the win beat")
	assert_eq(_save.profile["cars"].size(), cars_before, "the final special grants no car reward")
	assert_true(_save.rally_completed(last), "the special records completion")


func test_a_special_with_others_outstanding_completes_without_win_beat() -> void:
	# A special won while ANOTHER is still outstanding is just a normal rally win
	# (including a car draw) — it must NOT fire the win/credits beat or flag the endgame
	# podium. Counterpart to the test above: together they pin "credits fire on the LAST
	# special, whichever one that is", with none designated as the finale.
	RallyFixtures.restore()  # this test needs the REAL roster
	var first := _lowest_special_id()
	var specials := 0
	for rally in RallyLibrary.all():
		if RallyLibrary.is_special(rally):
			specials += 1
	if specials < 2:
		return  # a single-special roster has no "others outstanding" case to show
	var won: Array = [false]
	RallySession.game_won.connect(func() -> void: won[0] = true, CONNECT_ONE_SHOT)
	var result_box := _capture_finish()
	_grant_and_start(first)
	RallySession._opponent_field = _field([90000])  # player will be top-3
	_report_events([10000, 10000, 10000])
	assert_false(won[0], "a special with others outstanding does not fire the win beat")
	var result := _finish_result(result_box)
	assert_false(result["game_won"],
		"a special with others outstanding must not flag the endgame/credits podium")
	assert_true(_save.rally_completed(first), "the special still records completion")


# A re-win pays STARS again but still no CAR. The two halves used to move together (the car
# draw fired on every top-3, and stars credited only the improvement on a rally's best
# placement), which closed the replay grind entirely. Stars are re-winnable now — replaying a
# rally is a legitimate way to earn — while the CAR remains a one-time prize, or an easy rally
# would refill the garage indefinitely and make the rallies' restriction bands meaningless.
func test_a_rewin_pays_stars_again_but_never_another_car() -> void:
	_save.complete_rally("fx_open", 999999, 1)  # already won outright
	_grant_and_start("fx_open")
	# Snapshot AFTER _grant_and_start, which grants the car being driven — so anything the
	# finish itself adds shows up as a change.
	var podiums_before: int = _save.podium_rally_count()
	var cars_before: int = _save.profile["cars"].size()
	var stars_before: int = _save.stars_available()
	var box := _capture_finish()
	RallySession._opponent_field = _field([90000])  # top-3 re-win
	_report_events([10000, 10000, 10000])
	var gained := int(_finish_result(box).get("stars_gained", -1))
	assert_eq(_save.podium_rally_count(), podiums_before, "a re-win records no new podium")
	assert_eq(_save.profile["cars"].size(), cars_before, "no car is granted for a re-win")
	assert_eq(gained, RallyLibrary.stars_for_placement(1), "the podium re-win pays its stars")
	assert_eq(_save.stars_available(), stars_before + gained, "and the balance moved by that much")


# --- current_event_p1_car (Task 4) ------------------------------------------

func test_current_event_p1_car_returns_fastest_rivals_car() -> void:
	# Idle: no car.
	assert_true(RallySession.current_event_p1_car().is_empty(), "idle: no P1 car")
	_grant_and_start("fx_open")
	# Inject a field with known car_ids and event times for event 0.
	RallySession._opponent_field = [
		{"name": "A", "car_id": "fx_light_rwd",      "event_times_ms": [55000, 0, 0], "dnf": false, "combined_ms": 1},
		{"name": "B", "car_id": "fx_rwd_coupe","event_times_ms": [48000, 0, 0], "dnf": false, "combined_ms": 1},
		{"name": "C", "car_id": "fx_awd", "event_times_ms": [-1,    0, 0], "dnf": true,  "combined_ms": -1},
	]
	# Event 0: C DNF'd (time -1), so P1 is B with 48000 driving a fx_rwd_coupe.
	var p1: Dictionary = RallySession.current_event_p1_car()
	assert_false(p1.is_empty(), "a classified P1 rival returns a car dict")
	assert_eq(String(p1.get("id", "")), "fx_rwd_coupe", "P1 is the rival with the fastest non-DNF time")


# The event-only leaderboard ranks by the just-completed event's time (not the
# cumulative total), sinks a rival who DNF'd THAT event, and carries the player.
func test_current_event_standings_ranks_by_the_just_completed_event() -> void:
	assert_true(RallySession.current_event_standings().is_empty(), "idle: no event standings")
	_grant_and_start("fx_open", "fx_light_rwd")
	RallySession._opponent_field = [
		# Cumulatively "Quick" leads, but for event 1 alone "Slow" is fastest and
		# "Quick" is slowest — so the event-only ranking differs from the combined one.
		{"name": "Quick", "car_name": "Fixture AWD", "event_times_ms": [10000, 90000, 90000], "dnf": false, "combined_ms": 190000},
		{"name": "Slow", "car_name": "Fixture Coupe", "event_times_ms": [80000, 30000, 30000], "dnf": false, "combined_ms": 140000},
		{"name": "Gone", "car_name": "Fixture Hatch", "event_times_ms": [50000, -1, -1], "dnf": true, "combined_ms": -1},
	]
	RallySession.report_event_result(90000)   # event 0
	RallySession.continue_to_next_event()      # -> event 1 running
	RallySession.report_event_result(40000)   # event 1: player 40k
	var s := RallySession.current_event_standings()
	assert_eq(s.size(), 4, "player + three rivals ranked for the event")
	# Event 1 times: Slow 30k, player 40k, Quick 90k, Gone DNF (sinks last).
	assert_eq(String(s[0]["name"]), "Slow", "fastest THIS event leads (not the combined leader)")
	assert_true(s[1]["is_player"], "the player sits 2nd on this event's time")
	assert_eq(int(s[1]["combined_ms"]), 40000, "the row carries the single-event time, not the cumulative")
	assert_eq(int(s[3]["placed"]), -1, "a rival who DNF'd this event sinks to the bottom")
	assert_true(bool(s[3]["dnf"]), "the event-DNF rival is flagged DNF")


# --- Temporary car-park detune (features/engine-swap.md) --------------------------

func _detune_of(id: int) -> float:
	return float(_save.get_car(id).get("tuning", {}).get("engine_detune", 1.0))


# A car-park "Detune to N% & Start" agreement is temporary, for that rally only:
# the registered prior tune (here a garage-set 0.9) holds NOWHERE mid-rally — not
# at event boundaries — and is restored only when the rally actually resolves.
func test_registered_detune_reverts_to_the_prior_tune_when_the_rally_finishes() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	var id := int(owned["instance_id"])
	# The garage previously detuned this car to 0.9; a caller then registers a further
	# per-rally detune to 0.6 to be reverted when the rally ends (RallySession's revert
	# API, exercised directly here regardless of which UI flow registers it).
	_save.set_engine_detune(id, 0.9)
	RallySession.register_detune_revert(id, _detune_of(id))
	_save.set_engine_detune(id, 0.6)
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	RallySession._opponent_field = _field([100000, 200000])
	# Mid-rally — including the standings pause between events — the temporary
	# detune must hold; the tune never creeps back up before the rally is over.
	RallySession.report_event_result(50000)
	assert_almost_eq(_detune_of(id), 0.6, 0.0001, "the temporary detune holds at the event boundary")
	RallySession.continue_to_next_event()
	assert_almost_eq(_detune_of(id), 0.6, 0.0001, "the temporary detune holds into the next event")
	_report_events([50000, 50000])  # the remaining events -> the rally resolves
	assert_false(RallySession.is_active(), "the rally resolved")
	assert_almost_eq(_detune_of(id), 0.9, 0.0001,
		"finishing restores the garage-set tune the popup temporarily overrode")


# A never-tuned car reverts to the 1.0 (100%) default, and abandoning mid-rally
# counts as the rally ending too — the temporary detune must not outlive the rally.
func test_registered_detune_reverts_to_default_on_abandon() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	var id := int(owned["instance_id"])
	RallySession.register_detune_revert(id, _detune_of(id))
	_save.set_engine_detune(id, 0.7)
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	RallySession._opponent_field = _field([100000])
	RallySession.abandon()
	assert_almost_eq(_detune_of(id), 1.0, 0.0001,
		"abandoning restores the never-tuned car to full power")


# A revert registered for a car that never actually started (the player backed out
# before start_rally): the next start_rally settles it immediately — that car isn't
# racing, so its temporary detune is undone rather than left applied or rewritten
# when the OTHER car's rally later ends.
func test_stale_detune_revert_for_an_unfielded_car_is_settled_at_start() -> void:
	var backed_out: Dictionary = _save.grant_car("fx_rwd_coupe")
	var stale_id := int(backed_out["instance_id"])
	RallySession.register_detune_revert(stale_id, 1.0)
	_save.set_engine_detune(stale_id, 0.5)  # the agreement's detune, never raced
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	assert_almost_eq(_detune_of(stale_id), 1.0, 0.0001,
		"the unraced car's temporary detune is undone as soon as another rally starts")
	RallySession._opponent_field = _field([100000])
	RallySession.abandon()
	assert_almost_eq(_detune_of(stale_id), 1.0, 0.0001,
		"and the later rally end leaves it alone")


# The temporary drivetrain revert is GONE, along with the car-park auto-switch it existed
# to undo. A wrong-drivetrain car is simply ineligible now — the player converts it in the
# garage, permanently, for stars — so there is no per-rally override to put back.
# See features/menus.md (the car park) and features/upgrade-catalogue.md.

func test_a_garage_set_drivetrain_survives_a_rally() -> void:
	var owned: Dictionary = _save.grant_car(String(CarLibrary.all()[0].get("id", "")))
	var id := int(owned["instance_id"])
	_save.set_drivetrain_override(id, CarLibrary.AWD)
	(_save.get_car(id)["drivetrain_modes_bought"] as Array).append(CarLibrary.AWD)
	RallySession._reset_to_idle()
	assert_eq(int(_save.get_car(id).get("drivetrain_override", -1)), CarLibrary.AWD,
		"a layout the player bought and chose is theirs to keep; nothing reverts it")


# --- Per-event config application (apply_event_config) ------------------------
# These test the OVERRIDE/FALLBACK LOGIC, not any authored value: a synthetic
# event dict flows into the config, and omitted keys resolve to the pristine
# baseline — never to a value a prior event left on the shared session config.

func test_event_terrain_override_flows_into_config() -> void:
	var cfg := GameConfig.new()
	RallySession.apply_event_config(cfg, {
		"terrain_layer1_wavelength": 123.0, "terrain_layer1_amplitude": 45.0,
		"terrain_layer3_amplitude": 6.0, "water_level": -20.0,
	})
	assert_eq(cfg.terrain_layer1_wavelength, 123.0, "layer1 wavelength override applied")
	assert_eq(cfg.terrain_layer1_amplitude, 45.0, "layer1 amplitude override applied")
	assert_eq(cfg.terrain_layer3_amplitude, 6.0, "layer3 amplitude override applied")
	assert_eq(cfg.track_water_level_m, -20.0, "water_level override applied")


func test_omitted_keys_fall_back_to_authored_baseline_not_prior_event() -> void:
	var base: GameConfig = load(Config.CONFIG_PATH)
	var cfg := GameConfig.new()
	# Event A overrides two fields on the shared config...
	RallySession.apply_event_config(cfg, {
		"terrain_layer2_wavelength": 999.0, "water_level": -30.0,
	})
	assert_eq(cfg.terrain_layer2_wavelength, 999.0, "event A override took effect")
	# ...event B omits them and must NOT inherit A's values — it gets the baseline.
	RallySession.apply_event_config(cfg, {})
	assert_eq(cfg.terrain_layer2_wavelength, base.terrain_layer2_wavelength,
		"omitted terrain key resolves to the authored baseline, not event A's override")
	assert_eq(cfg.track_water_level_m, base.track_water_level_m,
		"omitted water_level resolves to the authored baseline, not event A's override")


func test_apply_event_config_carries_weather_and_defaults_to_dry() -> void:
	var cfg := GameConfig.new()
	RallySession.apply_event_config(cfg, {"weather": "rain"})
	assert_eq(cfg.weather, RallyLibrary.WEATHER_RAIN, "rain event seats rain onto the config")
	# An event with no weather key at all leaves the config dry.
	RallySession.apply_event_config(cfg, {})
	assert_eq(cfg.weather, RallyLibrary.WEATHER_DRY, "omitted weather key resolves to dry")


# --- Waterline resolution: event -> region -> GameConfig baseline --------------
# Order is the whole contract (CLAUDE.md: never pin the shipped -12/-5/-10
# values). Synthetic regions via the Registry.Seam only.

func test_apply_event_config_event_water_level_beats_its_region() -> void:
	RegionLibrary.override_for_test([{"id": "fx_region", "water_level": -99.0}])
	var cfg := GameConfig.new()
	RallySession.apply_event_config(cfg, {"water_level": -1.0, "region": "fx_region"})
	assert_almost_eq(cfg.track_water_level_m, -1.0, 0.0001,
		"event's own water_level wins over its region")
	RegionLibrary.reset()

func test_apply_event_config_inherits_region_when_event_authors_none() -> void:
	RegionLibrary.override_for_test([{"id": "fx_region", "water_level": -99.0}])
	var cfg := GameConfig.new()
	RallySession.apply_event_config(cfg, {"region": "fx_region"})
	assert_almost_eq(cfg.track_water_level_m, -99.0, 0.0001,
		"an event that authors no water_level inherits its region's")
	RegionLibrary.reset()

func test_apply_event_config_falls_back_to_baseline_with_no_region_context() -> void:
	var base: GameConfig = load(Config.CONFIG_PATH)
	var cfg := GameConfig.new()
	# The challenge / free-roam / dev-page shape: no "region" key at all.
	RallySession.apply_event_config(cfg, {})
	assert_eq(cfg.track_water_level_m, base.track_water_level_m,
		"no region tag and no event override -> GameConfig baseline")

func test_current_event_seats_the_rallys_region_tag() -> void:
	_grant_and_start("fx_open")
	var event := RallySession.current_event()
	assert_eq(String(event.get("region", "")), "home",
		"current_event() carries the owning rally's region so water resolution can use it")


# --- Consume-time config resolution (DrivingContext.apply_stage_config) --------

# The career arm of the one place a run's track parameters reach the live config.
# The config the run scene will read must be FIELD-FOR-FIELD what the canonical
# (lockfile / target-time) path builds for the same event — the two derivations are
# compared to each other, so nothing tunable is pinned and a per-event field added
# later is covered automatically.
func test_an_active_events_resolved_config_equals_its_canonical_config() -> void:
	_grant_and_start("fx_open")
	var event := RallySession.current_event()
	assert_false(event.is_empty(), "setup: an active rally exposes its current event")

	var cfg: GameConfig = (load(Config.CONFIG_PATH) as GameConfig).duplicate()
	DrivingContext.apply_stage_config(cfg)
	var canonical := RallySession.canonical_event_config(event)

	var compared := 0
	for prop in cfg.get_property_list():
		if int(prop.get("usage", 0)) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		compared += 1
		assert_eq(cfg.get(prop["name"]), canonical.get(prop["name"]),
			"%s: the live config must equal the canonical event config" % prop["name"])
	assert_gt(compared, 0, "setup: the GameConfig exposes script variables to diff")


# Session-less entries (free roam, benchmark, dev boot) must be left ALONE: they
# hand-write Config.data deliberately, and applying an empty event would reset every
# field to the authored baseline and wipe those writes.
func test_apply_stage_config_leaves_a_sessionless_config_untouched() -> void:
	RallySession.abandon()
	ChallengeSession.abandon()
	assert_false(RallySession.is_active(), "setup: no career session")
	assert_false(ChallengeSession.is_active(), "setup: no challenge session")

	var cfg: GameConfig = (load(Config.CONFIG_PATH) as GameConfig).duplicate()
	var authored_seed := cfg.track_seed + 7919  # any value the caller could pick
	cfg.track_seed = authored_seed
	cfg.track_forestiness = clampf(cfg.track_forestiness + 0.25, 0.0, 1.0)
	var authored_forestiness := cfg.track_forestiness
	DrivingContext.apply_stage_config(cfg)
	assert_eq(cfg.track_seed, authored_seed, "a session-less caller's seed survives")
	assert_eq(cfg.track_forestiness, authored_forestiness,
		"a session-less caller's hand-written fields survive")


# --- The opening rally (todo/opening-rally.md) --------------------------------
#
# The player is dropped into their starter car's own rally straight from the picker,
# before the map is ever shown, and it completes WHATEVER the result. These tests own the
# only place in the game where `completed` means something other than "podiumed", so they
# check both halves: that the carve-out fires where it should, and that it does not leak
# anywhere else.

# Install a fixture roster where fx_open awards `model` — making it that starter's opening
# rally — and record the pick in the profile, exactly as _confirm_starter does.
func _install_opening_rally(model := "fx_light_rwd") -> void:
	var roster: Array[Dictionary] = RallyFixtures.rallies()
	for i in roster.size():
		if String(roster[i].get("id", "")) == "fx_open":
			roster[i] = roster[i].duplicate(true)
			roster[i]["prize_car"] = model
	RallyLibrary.override_for_test(roster)
	_save.profile["starter_model_id"] = model


# Set up a finish OUTSIDE the top three: a field of five quick rivals the player's slow
# times cannot beat.
func _report_losing_run() -> void:
	RallySession._opponent_field = _field([10000, 20000, 30000, 40000, 50000])
	_report_events([1_000_000, 1_000_000, 1_000_000])


func test_the_opening_rally_completes_on_a_losing_finish() -> void:
	_install_opening_rally()
	_grant_and_start("fx_open")
	var finish := _capture_finish()
	_report_losing_run()
	var r := _finish_result(finish)
	assert_gt(int(r["placed"]), 3, "setup: the player finished outside the podium")
	assert_true(r["completed"], "the opening rally completes on a non-podium finish")
	# Finishing always pays, podium or not — so the player's first drive banks something even
	# when the field beats them.
	assert_eq(int(r["stars_gained"]), RallyLibrary.stars_for_placement(int(r["placed"])),
		"a losing FINISH still pays what finishing is worth")
	assert_gt(int(r["stars_gained"]), 0, "which is more than nothing")


# The whole point of completing it unconditionally: the player arrives at the map with the
# rally done and its neighbours opening around them. Both halves of that arrival are set
# here, so neither can be lost without a test noticing.
func test_finishing_the_opening_rally_routes_to_the_map_and_pre_seeds_its_own_reveal() -> void:
	_install_opening_rally()
	RallySession.return_to_map = false
	_grant_and_start("fx_open")
	_report_losing_run()
	assert_true(RallySession.return_to_map, "HQ is told to open on the map, not the garage")
	# Seen ALREADY, so the arrival parade announces the NEIGHBOURS rather than replaying
	# the rally the player has just this second driven.
	assert_true(_save.rally_revealed_seen("fx_open"),
		"the opening rally is pre-acknowledged")


# The carve-out is FIRST-ATTEMPT ONLY. Once the opening rally is completed it is an
# ordinary rally, so a retry is scored by the normal podium rule — otherwise it would
# become a permanent "this one always counts" the player could re-enter at will.
func test_a_retry_of_a_completed_opening_rally_is_scored_normally() -> void:
	_install_opening_rally()
	_grant_and_start("fx_open")
	_report_losing_run()
	assert_true(_save.rally_completed("fx_open"), "setup: the first attempt completed it")
	RallySession.abandon()

	RallySession.return_to_map = false
	_grant_and_start("fx_open")
	var finish := _capture_finish()
	_report_losing_run()
	var r := _finish_result(finish)
	assert_false(r["completed"], "a losing retry does not count as a completion")
	assert_false(RallySession.return_to_map, "and does not re-route to the map")


# The carve-out is PER PROFILE: it keys on the car the player actually picked, so another
# starter's prize rally is an ordinary rally to this player and stays podium-gated.
func test_another_starters_prize_rally_is_still_podium_gated() -> void:
	_install_opening_rally("fx_light_rwd")
	# The player picked something else, so fx_open is not THEIR opening rally.
	_save.profile["starter_model_id"] = "fx_heavy_fwd"
	_grant_and_start("fx_open")
	var finish := _capture_finish()
	_report_losing_run()
	var r := _finish_result(finish)
	assert_false(r["completed"], "someone else's prize rally still needs a podium")
	assert_false(_save.rally_completed("fx_open"), "and records no completion")


# A profile with no starter recorded (every save made before the picker existed) must not
# turn some arbitrary rally into a free completion.
func test_a_profile_with_no_starter_has_no_opening_carve_out() -> void:
	_install_opening_rally()
	_save.profile.erase("starter_model_id")
	_grant_and_start("fx_open")
	var finish := _capture_finish()
	_report_losing_run()
	assert_false(_finish_result(finish)["completed"],
		"no starter recorded means no opening rally, so the podium rule stands")


# --- Re-fielding the grid after a start-line upgrade edit --------------------
#
# The start line lets the player change upgrades while standing on the grid, AFTER the
# rival field has been drawn. Because the field is matched to the player's
# CarPerformance rating, an edit there has to re-draw it or the matching quietly stops
# meaning anything at the exact moment the player engages with it.

# Move the car's rating without needing the upgrade fixtures installed: a detune scales
# peak torque, which is exactly what the benchmark reads.
func _change_build(instance_id: int) -> void:
	_save.set_engine_detune(instance_id, 0.5)


func test_refielding_redraws_the_grid_when_the_build_changes() -> void:
	var owned := _grant_and_start("fx_open")
	_change_build(int(owned["instance_id"]))
	assert_true(RallySession.refield_opponents(), "a changed build re-draws the field")
	# Deliberately NOT asserting the grid membership changed. The fixture roster yields
	# fewer combos than a field holds, so every combo is fielded whatever the weighting —
	# the pool cannot express matching at all. That the draw actually FOLLOWS the rating
	# is tested where a pool big enough to show it exists
	# (test_rally_library.test_the_field_is_drawn_toward_the_players_rating).


func test_refielding_is_a_no_op_when_the_build_is_unchanged() -> void:
	_grant_and_start("fx_open")
	var before := RallySession.opponent_field().duplicate(true)
	assert_false(RallySession.refield_opponents(), "nothing changed, so nothing is re-drawn")
	assert_eq(str(RallySession.opponent_field()), str(before), "the grid is untouched")


func test_refielding_is_refused_once_a_stage_has_been_raced() -> void:
	# The guard that protects the standings: a rally's results accumulate across its
	# events, so re-drawing mid-rally would rewrite times the rivals have already set.
	var owned := _grant_and_start("fx_open")
	RallySession.report_event_result(60000)
	var before := RallySession.opponent_field().duplicate(true)
	_change_build(int(owned["instance_id"]))
	assert_false(RallySession.refield_opponents(), "mid-rally the grid is locked")
	assert_eq(str(RallySession.opponent_field()), str(before),
		"already-raced standings are not rewritten under the player")


func test_refielding_announces_itself_so_the_ghost_can_rebuild() -> void:
	# The run scene snapshots P1 (for the windscreen ghost and the "vs P1" delta) when the
	# stage BUILDS, which is before the start-line overlay the player edits upgrades on.
	# Without this signal the ghost keeps chasing the leader of the field the player
	# turned up with, not the one they are about to race.
	var owned := _grant_and_start("fx_open")
	var fired := [0]
	RallySession.opponent_field_changed.connect(func(): fired[0] += 1)
	_change_build(int(owned["instance_id"]))
	assert_true(RallySession.refield_opponents(), "the field was re-drawn")
	assert_eq(fired[0], 1, "and it announced the change exactly once")


func test_a_refused_refield_announces_nothing() -> void:
	# A no-op must stay silent, or the run scene would tear down and rebuild the ghost
	# every time the player opened the upgrades page and closed it again unchanged.
	_grant_and_start("fx_open")
	var fired := [0]
	RallySession.opponent_field_changed.connect(func(): fired[0] += 1)
	assert_false(RallySession.refield_opponents(), "nothing changed")
	assert_eq(fired[0], 0, "so nothing was announced")


# --- Adaptive difficulty: the stage-result signal -----------------------------
#
# The session's job is narrow: decide whether the player won the stage, hand that to
# AiDifficulty, and draw the field against the OFFSET rating rather than the raw one.
# The rule itself is tested in test_ai_difficulty.gd.

func test_a_stage_result_moves_the_difficulty_offset() -> void:
	var owned := _grant_and_start("fx_open")
	# One rival, and the player comfortably beats it.
	RallySession._opponent_field = [{
		"name": "Rival", "car_id": "fx_light_rwd", "engine_id": "fx_i4",
		"car_name": "Fixture", "event_times_ms": [90000, 90000, 90000],
		"dnf": false, "combined_ms": 0, "wreck_event": -1, "rating": 400, "skill_k": [],
	}]
	var before := AiDifficulty.steps_of(_save.profile)
	for _i in Config.data.ai_adapt_stages_per_step:
		# Reporting a result advances the phase out of RUNNING and the event index on, so
		# both are rewound to replay the same stage — this test is about the difficulty
		# signal, not about walking a whole rally.
		RallySession._event_index = 0
		RallySession._phase = RallySession.Phase.RUNNING
		RallySession.report_event_result(60000)
	assert_gt(AiDifficulty.steps_of(_save.profile), before,
		"a run of stage wins pushes the field harder")
	assert_eq(int(owned["instance_id"]), RallySession.car_instance_id(),
		"and the fielded car is untouched by it")


func test_losing_a_stage_pushes_the_other_way() -> void:
	_grant_and_start("fx_open")
	RallySession._opponent_field = [{
		"name": "Rival", "car_id": "fx_light_rwd", "engine_id": "fx_i4",
		"car_name": "Fixture", "event_times_ms": [60000, 60000, 60000],
		"dnf": false, "combined_ms": 0, "wreck_event": -1, "rating": 400, "skill_k": [],
	}]
	for _i in Config.data.ai_adapt_stages_per_step:
		RallySession._event_index = 0
		RallySession._phase = RallySession.Phase.RUNNING
		RallySession.report_event_result(90000)   # slower than the rival every time
	assert_lt(AiDifficulty.steps_of(_save.profile), 0,
		"a run of stage losses eases the field")


func test_a_stage_with_no_rivals_is_not_counted_as_a_win() -> void:
	# With nobody to beat there is no evidence the player is quick, and treating an empty
	# field as a win would ratchet difficulty up on no information at all.
	_grant_and_start("fx_open")
	RallySession._opponent_field = []
	for _i in Config.data.ai_adapt_stages_per_step:
		RallySession._event_index = 0
		RallySession._phase = RallySession.Phase.RUNNING
		RallySession.report_event_result(60000)
	assert_lte(AiDifficulty.steps_of(_save.profile), 0,
		"an empty field never hardens the game")


func test_the_field_is_drawn_against_the_offset_rating() -> void:
	# The wiring that matters: if the offset did not reach the draw, the whole system would
	# compute a number nothing ever read.
	var owned := _grant_and_start("fx_open")
	var matched := RallySession._fielded_rating
	assert_gt(matched, 0, "setup: the field was matched to a real rating")
	_save.profile[AiDifficulty.KEY_STEPS] = Config.data.ai_adapt_max_hard_steps
	RallySession.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	assert_gt(RallySession._fielded_rating, matched,
		"a hardened offset asks the matcher for a quicker field")


func test_refielding_keeps_the_difficulty_offset() -> void:
	# A re-draw after a start-line upgrade edit must not silently reset the difficulty.
	var owned := _grant_and_start("fx_open")
	_save.profile[AiDifficulty.KEY_STEPS] = Config.data.ai_adapt_max_hard_steps
	_change_build(int(owned["instance_id"]))
	assert_true(RallySession.refield_opponents(), "the field was re-drawn")
	var raw := RallySession._player_rating(_save.get_car(int(owned["instance_id"])))
	assert_gt(RallySession._fielded_rating, raw,
		"and the re-draw still carries the offset, not the raw rating")


# --- The any-finish bonus-star seam (features/reward-system.md) ---------------
#
# `stars_gained` is the ONLY star channel the podium reads (podium.gd::_show_stars reads
# `star_rating` and `stars_gained`, nothing else). Twice a bonus was added under an invented
# result key: the ledger moved and the player saw nothing. These tests pin the CONTRACT —
# whatever the seam pays reaches that one channel, and an invented key is refused loudly.

# A RallySession whose any-finish seam pays a caller-chosen bonus. The amount is supplied by
# the TEST, not read from config or a library, so nothing here pins a balance value.
class _BonusSession extends "res://scripts/rally_session.gd":
	var bonus := 0

	func _award_any_finish_bonus_stars(_combined: int, _placed: int) -> int:
		return bonus


func test_an_any_finish_bonus_reaches_the_stars_gained_the_podium_reads() -> void:
	var session := _BonusSession.new()
	# An arbitrary positive amount chosen by the test — the assertions compare against this
	# same variable, so retuning any real reward cannot break them.
	session.bonus = 3
	session.auto_load_scenes = false
	add_child_autofree(session)

	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	session.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	# A field the player's slow times cannot beat: a FINISH, but not a podium, so the
	# podium-gated star payout contributes nothing and only the bonus is in play.
	session._opponent_field = _field([10000, 20000, 30000, 40000, 50000])
	var box: Array[Dictionary] = []
	session.rally_finished.connect(
		func(r: Dictionary) -> void: box.append(r), CONNECT_ONE_SHOT)
	var before := int(_save.stars_available())
	for i in session.stage_count():
		session.report_event_result(1_000_000)
		session.continue_to_next_event()

	var r: Dictionary = box[0] if not box.is_empty() else {}
	assert_false(r.is_empty(), "the rally resolved")
	assert_gt(int(r["placed"]), 3, "setup: a finish, but not a podium")
	assert_eq(int(r["stars_gained"]), session.bonus,
		"the bonus arrives in stars_gained — the only star field the podium shows")
	assert_eq(int(_save.stars_available()) - before, session.bonus,
		"and the ledger moved by exactly that, so the podium and the balance agree")


func test_the_seam_pays_nothing_extra_when_it_returns_zero() -> void:
	# The seam is a no-op today; a session whose bonus is 0 must be indistinguishable from
	# the shipped one — no stray credit, no stray field.
	var session := _BonusSession.new()
	session.bonus = 0
	session.auto_load_scenes = false
	add_child_autofree(session)

	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	session.start_rally(RallyLibrary.by_id("fx_open"), owned, true)
	session._opponent_field = _field([10000, 20000, 30000, 40000, 50000])
	var box: Array[Dictionary] = []
	session.rally_finished.connect(
		func(r: Dictionary) -> void: box.append(r), CONNECT_ONE_SHOT)
	var before := int(_save.stars_available())
	for i in session.stage_count():
		session.report_event_result(1_000_000)
		session.continue_to_next_event()

	var r: Dictionary = box[0] if not box.is_empty() else {}
	assert_false(r.is_empty(), "the rally resolved")
	assert_eq(int(r["stars_gained"]), 0, "a zero bonus adds nothing to the star channel")
	assert_eq(int(_save.stars_available()), before, "and nothing to the ledger")


func test_an_unknown_merged_result_key_is_refused_and_announced() -> void:
	# The belt-and-braces guard: a future any-finish field that nothing downstream reads must
	# not slip silently into the result. `clean_run_stars` is the exact key a model invented.
	var result := {"stars_gained": 1}
	RallySession._merge_result_fields(result, {"clean_run_stars": 1})
	assert_false(result.has("clean_run_stars"),
		"a key outside RESULT_FIELDS never reaches the result")
	assert_eq(int(result["stars_gained"]), 1, "and the real fields are left alone")
	# The ANNOUNCEMENT is half the fix — dropping the key silently would repeat the very
	# failure this guard exists to stop. assert_push_error both proves the error fired and
	# marks it handled, so GUT does not count it as an unexpected error.
	assert_push_error("clean_run_stars",
		"and the drop announces itself, naming the offending key")


func test_a_known_merged_result_key_is_accepted() -> void:
	# The guard is an allowlist, not a ban: a field the UI already reads merges as before.
	var result := {"stars_gained": 1}
	RallySession._merge_result_fields(result, {"stars_gained": 2, "game_won": true})
	assert_eq(int(result["stars_gained"]), 2, "a known key merges over the podium value")
	assert_true(bool(result["game_won"]), "as does every other RESULT_FIELDS key")


func test_every_field_the_result_carries_is_in_the_allowlist() -> void:
	# Otherwise the guard would reject the result's own fields the moment the seam returned
	# one — the allowlist and the result literal must not drift apart.
	_grant_and_start("fx_open")
	var box := _capture_finish()
	_report_losing_run()
	var r := _finish_result(box)
	assert_false(r.is_empty(), "the rally resolved")
	for key in r:
		assert_true(RallySession.RESULT_FIELDS.has(String(key)),
			"result field '%s' is listed in RESULT_FIELDS" % key)

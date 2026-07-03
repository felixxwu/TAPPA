extends GutTest
# RallySession: the rally-level orchestrator (features/rally-session.md). Driven
# directly via report_event_result / report_wreck with a precomputed target list
# and a fixed opponent field — no real driving or scene loads. Runs against a
# throwaway Save profile so a real profile is never touched.

const TEST_PATH := "user://test_rally_session_profile.json"
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


# Total item count across the inventory (parts + repair kits).
func _total_items() -> int:
	var n := 0
	for item_id in _save.profile["inventory"]:
		n += int(_save.profile["inventory"][item_id])
	return n


# Start a rally skipping track generation; return the owned car dict.
# Caller may overwrite RallySession._opponent_field for determinism.
func _start(rally_id: String, model := "fx_light_rwd") -> Dictionary:
	var owned: Dictionary = _save.grant_car(model)
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
func _capture_finish() -> Array:
	var box: Array = [null]
	RallySession.rally_finished.connect(
		func(r: Dictionary) -> void: box[0] = r, CONNECT_ONE_SHOT)
	return box


# The start-line "time to beat" — the fastest non-DNF rival's time for the CURRENT
# event, tracking the event index as the rally advances. -1 when idle.
func test_current_event_target_ms_tracks_fastest_rival_per_event() -> void:
	assert_eq(RallySession.current_event_target_ms(), -1, "idle: no time to beat")
	_start("coastal_sprint")
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
	_start("coastal_sprint")
	RallySession._opponent_field = [
		{"name": "A", "car_name": "Fixture AWD", "event_times_ms": [50000, 0, 0], "dnf": false, "combined_ms": 1},
		{"name": "B", "car_name": "Fixture Coupe", "event_times_ms": [45000, 0, 0], "dnf": false, "combined_ms": 1},
		{"name": "C", "car_name": "Fixture Hatch", "event_times_ms": [-1, 0, 0], "dnf": true, "combined_ms": -1},
		{"name": "D", "car_name": "Fixture Roadster", "event_times_ms": [60000, 0, 0], "dnf": false, "combined_ms": 1},
	]
	# Event 0: C set no time (-1, omitted). Fastest-first: B 45k, A 50k, D 60k.
	var leaders := RallySession.current_event_leaders(3)
	assert_eq(leaders.size(), 3, "the top three rivals for the event are returned")
	assert_eq(String(leaders[0]["name"]), "B", "the fastest rival leads")
	assert_eq(String(leaders[0]["car_name"]), "Fixture Coupe", "the leader's car comes through")
	assert_eq(int(leaders[0]["time_ms"]), 45000, "the leader's event time comes through")
	assert_eq(String(leaders[2]["name"]), "D", "third fastest is listed third")
	for e in leaders:
		assert_ne(String(e["name"]), "C", "a rival who DNF'd this event is omitted")


# The leaderboard carries the car each entrant drove — the rivals' and the
# player's fielded car.
func test_standings_carry_the_player_and_rival_cars() -> void:
	_start("shakedown", "fx_light_rwd")
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


func test_idle_when_no_rally() -> void:
	assert_false(RallySession.is_active(), "no session active at rest")
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "phase is IDLE")


func test_happy_path_accumulates_and_places() -> void:
	var finish := _capture_finish()
	_start("shakedown")
	RallySession._opponent_field = _field([50000, 60000, 70000, 80000, 90000])
	RallySession.report_event_result(20000)
	RallySession.continue_to_next_event()
	RallySession.report_event_result(20000)
	assert_eq(RallySession.event_times_ms(), [20000, 20000] as Array[int], "times accumulate per event")
	RallySession.continue_to_next_event()
	RallySession.report_event_result(20000)  # 3rd event -> pauses on the event-only standings
	assert_eq(RallySession.phase(), RallySession.Phase.STANDINGS, "the final event pauses on its event standings")
	RallySession.continue_to_next_event()    # -> resolve
	var r: Dictionary = finish[0]
	assert_not_null(r, "rally_finished emitted")
	assert_eq(r["combined_ms"], 60000, "combined = sum of event times")
	# Field has one opponent (50000) faster than 60000 -> placed 2nd.
	assert_eq(r["placed"], 2, "placement counts faster non-DNF opponents")
	assert_true(r["completed"], "a top-3 finish completes the rally")
	assert_false(r["dnf"], "not a DNF")
	assert_true(_save.rally_completed("shakedown"), "completion recorded in the save")
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "session returns to IDLE after finishing")


func test_result_carries_rewards_and_standings_for_the_podium() -> void:
	var finish := _capture_finish()
	var driven := _start("shakedown")  # the entry rally (a low p/w cap), difficulty 1
	# Player combined 60000; one opponent faster (50000) -> placed 2nd, top-3 win.
	RallySession._opponent_field = _field([50000, 70000, 80000])
	# Snapshot ownership BEFORE the finish: a top-3 win grants the reward car, so the
	# is_new flag (computed at draw time) must be checked against the pre-grant garage.
	var owned_before := {}
	for c in _save.profile.get("cars", []):
		owned_before[String(c.get("model_id", ""))] = true
	_report_events([20000, 20000, 20000])
	var r: Dictionary = finish[0]
	assert_eq(r["rally_name"], "Shakedown", "result names the rally for the podium header")
	assert_eq(r["upgrades"].size(), Config.data.rally_upgrade_reward_count,
		"a finished rally captures rally_upgrade_reward_count upgrade ids for the reveal")
	# The reward must be a real catalogue car (the draw policy itself — garage
	# tier cap, unlock fallback — is covered by test_reward_system.gd with
	# controlled profiles) and the is_new flag must reflect whether the player
	# already owned it. Derived from the library/profile rather than pinning a
	# specific model id, so this survives roster changes.
	var reward := String(r["car_reward"])
	assert_false(CarLibrary.by_id(reward).is_empty(),
		"a top-3 finish records a real catalogue car for the reveal")
	assert_eq(bool(r["car_reward_is_new"]), not owned_before.has(reward),
		"the is_new flag matches whether the player already owned the won car before the win")
	assert_false(r["showdown_won"], "the shakedown is not the showdown")
	# The result names the owned-car instance the player drove, so the podium's
	# upgrade reveal can offer to fit each won part straight onto it.
	assert_eq(int(r["car_instance_id"]), int(driven["instance_id"]),
		"the result carries the driven car's instance id for the apply-upgrade choice")
	# A 2nd-place finish records best placement 2 (drives the world-map stars).
	assert_eq(_save.best_placement("shakedown"), 2, "the best finishing position is recorded")
	# Standings = field (3) + player, ranked, player classified 2nd.
	var standings: Array = r["standings"]
	assert_eq(standings.size(), 4, "standings includes the player plus the opponent field")
	var player: Dictionary = {}
	for e in standings:
		if e["is_player"]:
			player = e
	assert_eq(player["placed"], 2, "the player's standings position matches the placement")


func test_between_event_standings_pause_and_leaderboard() -> void:
	_start("shakedown")
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


func test_upgrades_won_per_rally_bind_to_the_driven_car_without_duplicates() -> void:
	# Upgrades are CAR-BOUND and the multi-reward draw dedups: each won slottable
	# part is fitted (disabled) to the driven car, and no slottable part is won
	# twice in one rally (the re-roll now excludes what's already on the car). Crank
	# the reward count well past the eligible slottable pool so, without dedup, a
	# duplicate would be forced — then assert none occurs.
	var original_count: int = Config.data.rally_upgrade_reward_count
	Config.data.rally_upgrade_reward_count = 8
	var finish := _capture_finish()
	var driven := _start("shakedown")
	var driven_id := int(driven["instance_id"])
	RallySession._opponent_field = _field([90000])  # player will be top-3
	_report_events([10000, 10000, 10000])
	Config.data.rally_upgrade_reward_count = original_count
	var r: Dictionary = finish[0]

	var slottable_wins: Array = []
	var repair_wins := 0
	for item_id in r["upgrades"]:
		if UpgradeLibrary.is_consumable(item_id):
			repair_wins += 1
		else:
			slottable_wins.append(item_id)

	# The re-roll fix: no slottable part is won twice in the same rally.
	var uniq := {}
	for item_id in slottable_wins:
		uniq[item_id] = true
	assert_eq(uniq.size(), slottable_wins.size(), "no slottable upgrade is won twice in one rally")

	# Each won slottable part is bound to the driven car — fitted, and disabled
	# (the podium's Apply is what enables the player's pick).
	var live: Dictionary = _save.get_car(driven_id)
	var installed: Array = live["installed_upgrades"]
	for item_id in slottable_wins:
		assert_true(installed.has(item_id), "the won part is fitted to the driven car")
		assert_false(UpgradeLibrary.is_enabled(live, item_id), "and lands disabled until Apply")
	# Repair kits (consumable, exempt) go to the pooled inventory, not the car.
	assert_eq(int(_save.profile["inventory"].get(UpgradeLibrary.REPAIR_KIT_ID, 0)), repair_wins,
		"won repair kits land in inventory, not on the car")


func test_wreck_midrally_is_dnf_and_grants_no_upgrade() -> void:
	var finish := _capture_finish()
	var owned := _start("shakedown")
	var id := int(owned["instance_id"])
	RallySession._opponent_field = _field([50000])
	RallySession.report_event_result(20000)  # event 1 completes (no per-event upgrade now)
	assert_eq(_total_items(), 0, "no upgrade is granted mid-rally")
	RallySession.continue_to_next_event()  # resume from the standings into event 2
	RallySession.report_wreck()  # wreck during event 2
	var r: Dictionary = finish[0]
	assert_true(r["dnf"], "a wreck is a DNF")
	assert_false(r["completed"], "DNF never completes the rally")
	assert_eq(r["placed"], -1, "DNF does not place")
	assert_eq(r["combined_ms"], -1, "DNF has no combined time")
	# A wrecked car is kept (repairable), not destroyed — it sits at 0 HP in the save.
	assert_false(_save.get_car(id).is_empty(), "the wrecked car is kept, not destroyed")
	assert_eq(float(_save.get_car(id)["hp"]), 0.0, "the wrecked car is left at 0 HP")
	assert_eq(_total_items(), 0, "a DNF rally grants no upgrade (one per FINISHED rally)")
	assert_false(_save.rally_completed("shakedown"), "a DNF leaves the rally incomplete")


func test_no_retry_reenter_resets_and_field_is_fixed() -> void:
	var owned := _start("shakedown")
	var id := int(owned["instance_id"])
	var field1: Array = RallySession.opponent_field().duplicate(true)
	# A slow, non-top-3 finish (slower than every opponent).
	var finish := _capture_finish()
	RallySession._opponent_field = _field([10000, 20000, 30000, 40000, 50000])
	_report_events([1_000_000, 1_000_000, 1_000_000])
	var r: Dictionary = finish[0]
	assert_false(r["completed"], "a non-top-3 finish does not complete the rally")
	assert_eq(r["placed"], 6, "slower than all 5 opponents -> placed 6th")
	assert_false(_save.rally_completed("shakedown"), "an incomplete rally stays incomplete (no retry)")
	assert_false(_save.get_car(id).is_empty(), "the car survives a non-DNF finish")

	# Re-enter from the map: state resets, the opponent field is unchanged (fixed
	# per rally seed), and persisted HP is untouched.
	RallySession.start_rally(RallyLibrary.by_id("shakedown"), _save.get_car(id), true)
	assert_eq(RallySession.event_index(), 0, "event index resets on re-entry")
	assert_true(RallySession.event_times_ms().is_empty(), "event times reset on re-entry")
	assert_eq(RallySession.opponent_field(), field1, "the opponent field is identical across re-attempts")


func test_showdown_win_beat_instead_of_car_draw() -> void:
	var won: Array = [false]
	RallySession.showdown_won.connect(func() -> void: won[0] = true, CONNECT_ONE_SHOT)
	_start("the_showdown")
	RallySession._opponent_field = _field([90000])  # player will be top-3
	var cars_before: int = _save.profile["cars"].size()
	_report_events([10000, 10000, 10000])
	assert_true(won[0], "a top-3 showdown finish fires the win beat")
	assert_eq(_save.profile["cars"].size(), cars_before, "the showdown grants no car reward")
	assert_true(_save.rally_completed("the_showdown"), "the showdown records completion")


func test_farming_rewin_grants_car_without_new_completion() -> void:
	var owned: Dictionary = _save.grant_car("fx_light_rwd")
	_save.complete_rally("shakedown", 999999)  # already won once
	var completed_before: int = _save.completed_rally_count()
	var cars_before: int = _save.profile["cars"].size()
	var rewards: Array = [0]
	RallySession.car_rewarded.connect(func(_m: String) -> void: rewards[0] += 1, CONNECT_ONE_SHOT)
	RallySession.start_rally(RallyLibrary.by_id("shakedown"), owned, true)
	RallySession._opponent_field = _field([90000])  # top-3 re-win
	_report_events([10000, 10000, 10000])
	assert_eq(_save.completed_rally_count(), completed_before, "a re-win records no new completion")
	assert_eq(rewards[0], 1, "a top-3 re-win still draws a car (renewable supply)")
	assert_eq(_save.profile["cars"].size(), cars_before + 1, "the re-won car is granted")


# --- current_event_p1_car (Task 4) ------------------------------------------

func test_current_event_p1_car_returns_fastest_rivals_car() -> void:
	# Idle: no car.
	assert_true(RallySession.current_event_p1_car().is_empty(), "idle: no P1 car")
	_start("coastal_sprint")
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
	_start("shakedown", "fx_light_rwd")
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

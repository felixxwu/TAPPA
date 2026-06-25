extends GutTest
# RallySession: the rally-level orchestrator (todo/rally-event-flow.md). Driven
# directly via report_event_result / report_wreck with a precomputed target list
# and a fixed opponent field — no real driving or scene loads. Runs against a
# throwaway Save profile so a real profile is never touched.

const TEST_PATH := "user://test_rally_session_profile.json"

var _save: Node


func before_each() -> void:
	Config.reset()
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


# Start a rally with a fielded car and fixed per-event targets; return the owned
# car dict. Caller may overwrite RallySession._opponent_field for determinism.
func _start(rally_id: String, model := "mx5") -> Dictionary:
	var owned: Dictionary = _save.grant_car(model, false)
	RallySession.start_rally(RallyLibrary.by_id(rally_id), owned, [60000, 60000, 60000])
	return owned


# Capture the next rally_finished result (one-shot, so nothing leaks across tests).
func _capture_finish() -> Array:
	var box: Array = [null]
	RallySession.rally_finished.connect(
		func(r: Dictionary) -> void: box[0] = r, CONNECT_ONE_SHOT)
	return box


func test_idle_when_no_rally() -> void:
	assert_false(RallySession.is_active(), "no session active at rest")
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "phase is IDLE")


func test_happy_path_accumulates_and_places() -> void:
	var finish := _capture_finish()
	_start("shakedown")
	RallySession._opponent_field = _field([50000, 60000, 70000, 80000, 90000])
	RallySession.report_event_result(20000)
	RallySession.report_event_result(20000)
	assert_eq(RallySession.event_times_ms(), [20000, 20000] as Array[int], "times accumulate per event")
	RallySession.report_event_result(20000)  # combined 60000 -> resolve
	var r: Dictionary = finish[0]
	assert_not_null(r, "rally_finished emitted")
	assert_eq(r["combined_ms"], 60000, "combined = sum of event times")
	# Field has one opponent (50000) faster than 60000 -> placed 2nd.
	assert_eq(r["placed"], 2, "placement counts faster non-DNF opponents")
	assert_true(r["completed"], "a top-3 finish completes the rally")
	assert_false(r["dnf"], "not a DNF")
	assert_true(_save.rally_completed("shakedown"), "completion recorded in the save")
	assert_eq(RallySession.phase(), RallySession.Phase.IDLE, "session returns to IDLE after finishing")


func test_one_upgrade_revealed_per_event() -> void:
	_start("shakedown")
	RallySession._opponent_field = _field([90000])  # player will be top-3
	assert_eq(_total_items(), 0, "no items before the rally")
	RallySession.report_event_result(10000)
	assert_eq(_total_items(), 1, "one upgrade after event 1")
	RallySession.report_event_result(10000)
	assert_eq(_total_items(), 2, "one upgrade after event 2")
	RallySession.report_event_result(10000)
	assert_eq(_total_items(), 3, "three upgrades over a full run")


func test_wreck_midrally_is_dnf_and_keeps_earned_upgrades() -> void:
	var finish := _capture_finish()
	var owned := _start("shakedown")
	var id := int(owned["instance_id"])
	RallySession._opponent_field = _field([50000])
	RallySession.report_event_result(20000)  # event 1 completes -> 1 upgrade
	assert_eq(_total_items(), 1, "earned one upgrade before the wreck")
	RallySession.report_wreck()  # wreck during event 2
	var r: Dictionary = finish[0]
	assert_true(r["dnf"], "a wreck is a DNF")
	assert_false(r["completed"], "DNF never completes the rally")
	assert_eq(r["placed"], -1, "DNF does not place")
	assert_eq(r["combined_ms"], -1, "DNF has no combined time")
	assert_true(_save.get_car(id).is_empty(), "the wrecked car instance is destroyed")
	assert_eq(_total_items(), 1, "upgrades earned before the wreck are kept; no further event upgrade")
	assert_false(_save.rally_completed("shakedown"), "a DNF leaves the rally incomplete")


func test_no_retry_reenter_resets_and_field_is_fixed() -> void:
	var owned := _start("shakedown")
	var id := int(owned["instance_id"])
	var field1: Array = RallySession.opponent_field().duplicate(true)
	# A slow, non-top-3 finish (slower than every opponent).
	var finish := _capture_finish()
	RallySession._opponent_field = _field([10000, 20000, 30000, 40000, 50000])
	for i in 3:
		RallySession.report_event_result(1_000_000)
	var r: Dictionary = finish[0]
	assert_false(r["completed"], "a non-top-3 finish does not complete the rally")
	assert_eq(r["placed"], 6, "slower than all 5 opponents -> placed 6th")
	assert_false(_save.rally_completed("shakedown"), "an incomplete rally stays incomplete (no retry)")
	assert_false(_save.get_car(id).is_empty(), "the car survives a non-DNF finish")

	# Re-enter from the map: state resets, the opponent field is unchanged (fixed
	# per rally seed), and persisted HP is untouched.
	RallySession.start_rally(RallyLibrary.by_id("shakedown"), _save.get_car(id), [60000, 60000, 60000])
	assert_eq(RallySession.event_index(), 0, "event index resets on re-entry")
	assert_true(RallySession.event_times_ms().is_empty(), "event times reset on re-entry")
	assert_eq(RallySession.opponent_field(), field1, "the opponent field is identical across re-attempts")


func test_showdown_win_beat_instead_of_car_draw() -> void:
	var won: Array = [false]
	RallySession.showdown_won.connect(func() -> void: won[0] = true, CONNECT_ONE_SHOT)
	_start("the_showdown")
	RallySession._opponent_field = _field([90000])  # player will be top-3
	var cars_before: int = _save.profile["cars"].size()
	for i in 3:
		RallySession.report_event_result(10000)
	assert_true(won[0], "a top-3 showdown finish fires the win beat")
	assert_eq(_save.profile["cars"].size(), cars_before, "the showdown grants no car reward")
	assert_true(_save.rally_completed("the_showdown"), "the showdown records completion")


func test_farming_rewin_grants_car_without_new_completion() -> void:
	var owned: Dictionary = _save.grant_car("mx5", false)
	_save.complete_rally("shakedown", 999999)  # already won once
	var completed_before: int = _save.completed_rally_count()
	var cars_before: int = _save.profile["cars"].size()
	var rewards: Array = [0]
	RallySession.car_rewarded.connect(func(_m: String) -> void: rewards[0] += 1, CONNECT_ONE_SHOT)
	RallySession.start_rally(RallyLibrary.by_id("shakedown"), owned, [60000, 60000, 60000])
	RallySession._opponent_field = _field([90000])  # top-3 re-win
	for i in 3:
		RallySession.report_event_result(10000)
	assert_eq(_save.completed_rally_count(), completed_before, "a re-win records no new completion")
	assert_eq(rewards[0], 1, "a top-3 re-win still draws a car (renewable supply)")
	assert_eq(_save.profile["cars"].size(), cars_before + 1, "the re-won car is granted")

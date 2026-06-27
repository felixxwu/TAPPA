extends Node
# Autoload "RallySession": the rally-level session orchestrator. One coordinator
# that turns "the player picked rally R with owned car C" into the full loop —
# field the car, run 3 events, accumulate times, place against the fixed opponent
# field, grant rewards, and finish (podium → HQ). It sits one level ABOVE the
# per-stage StageManager (todo/stage-start-and-end.md) and OWNS only the
# rally-level state machine + in-progress state; it CALLS the systems that already
# exist (RallyLibrary, RewardSystem, Save) rather than re-implementing them.
# See todo/rally-event-flow.md.
#
# Like Config / Save it is an autoload (no class_name, reached by the global
# `RallySession`), and it SURVIVES the per-event scene reloads — each event is a
# fresh load of main.tscn with that event's seed written into Config.data first.
#
# This module is the testable BRAIN: it is driven by report_event_result /
# report_wreck (called by the run scene's StageManager / damage model) and emits
# signals the menus layer (todo/menus.md) renders (presence, standings, reward
# reveal, podium). The run-scene fielding + signal wiring lands with menus, where
# there is finally an entry point (the map's start_rally) to exercise it.

enum Phase { IDLE, PRESENCE, RUNNING, STANDINGS, RESULTS, PODIUM }

const EVENTS_PER_RALLY := 3

# End-of-rally summary (todo/rally-event-flow.md API):
#   placed:int (1-based, -1 if DNF), completed:bool (top-3), combined_ms:int
#   (-1 if DNF), dnf:bool
signal rally_finished(result: Dictionary)
# Phase transitions, for menus to react to (fly-throughs / overlays).
signal phase_changed(phase: int)
# An event is about to run (presence beat + StageManager handoff in the run scene).
signal event_started(event_index: int, event: Dictionary)
# A between-event standings interstitial should show (after events 0 and 1).
signal standings_ready(event_index: int)
# A per-event upgrade was drawn + granted — reward reveal hook (menus rig 5).
signal upgrade_revealed(item_id: String)
# A top-3 car reward was drawn + granted — reward reveal (car arrives in HQ).
signal car_rewarded(model_id: String)
# A top-3 showdown finish: the game's win / credits beat fires instead of a draw.
signal showdown_won()

var _phase: int = Phase.IDLE
var _rally: Dictionary = {}            # the RallyDef being run ({} when IDLE)
var _car_instance_id := -1             # the fielded OwnedCar instance
var _event_index := 0                  # 0..2
var _event_times_ms: Array[int] = []   # accumulated, one per completed event
var _event_targets_ms: Array = []      # per-event target time (drives the field)
var _opponent_field: Array = []        # fixed per rally seed (never saved)
var _dnf := false
var _upgrades_won: Array[String] = []  # per-event upgrade ids drawn this rally (reveal)
var _last_result: Dictionary = {}      # the most recent finish, read by the podium

# When true (the default for real play) RallySession performs the per-event scene
# loads itself. Headless tests set it false and drive report_* directly with
# precomputed target times, so no track generation or scene reload happens.
var auto_load_scenes := true


# --- Public API --------------------------------------------------------------

# Begin a rally with the given RallyDef and fielded OwnedCar. `event_targets_ms`
# is optional precomputed per-event target times (ms); when omitted, real play
# derives them by generating each event's track. Resets all per-rally state, so
# re-entering a rally from the map runs fresh (no retry — the opponent field and
# persisted HP are unchanged). Kicks the first event.
func start_rally(rally: Dictionary, owned_car: Dictionary, event_targets_ms: Array = []) -> void:
	_rally = rally
	_car_instance_id = int(owned_car.get("instance_id", -1))
	_event_index = 0
	_event_times_ms = []
	_dnf = false
	_upgrades_won = []
	_event_targets_ms = event_targets_ms if not event_targets_ms.is_empty() else _compute_event_targets(rally)
	_opponent_field = RallyLibrary.generate_opponent_field(rally, _event_targets_ms)
	_enter_event()


# An event finished cleanly (from StageManager.stage_completed in the run scene).
# Accumulate the time, persist chip damage, draw + grant a per-event upgrade, then
# either advance to the next event (via standings) or resolve the rally.
func report_event_result(elapsed_ms: int, hp_lost: float = 0.0) -> void:
	if _phase != Phase.RUNNING:
		return
	_event_times_ms.append(elapsed_ms)
	# HP persists at each event boundary (Save debounces/autosaves). Only a fielded
	# (bound) car has an instance to write back to.
	if _car_instance_id >= 0 and hp_lost > 0.0:
		Save.apply_damage(_car_instance_id, hp_lost)
	# A random upgrade per completed event (gameplay.md); granted + saved at once so
	# the unseeded draw is savescum-proof (reward-system.md).
	var item_id: String = RewardSystem.draw_upgrade(int(_rally.get("difficulty", 1)), Save.profile)
	Save.add_item(item_id)
	Save.save()
	_upgrades_won.append(item_id)
	upgrade_revealed.emit(item_id)
	_event_index += 1
	if _event_index >= EVENTS_PER_RALLY:
		_resolve_results()
	else:
		# Between events the rally PAUSES on a standings interstitial (the leaderboard
		# so far); the player resumes with continue_to_next_event(). In real play the
		# standings scene is loaded; tests drive continue_to_next_event() directly.
		_set_phase(Phase.STANDINGS)
		standings_ready.emit(_event_index)
		if auto_load_scenes:
			_load_standings_scene()


# Resume from the between-event standings interstitial into the next event.
func continue_to_next_event() -> void:
	if _phase != Phase.STANDINGS:
		return
	_enter_event()


# The leaderboard AS OF the events completed so far: each opponent's combined time
# over those events vs the player's, ranked (DNFs sink). Read by the standings
# interstitial. Before any event completes it's just the seeded field at 0.
func current_standings() -> Array:
	var done := _event_times_ms.size()
	var player_combined := 0
	for t in _event_times_ms:
		player_combined += int(t)
	var partial: Array = []
	for opp in _opponent_field:
		var times: Array = opp.get("event_times_ms", [])
		var dnf := false
		var sum := 0
		for i in done:
			if i < times.size() and int(times[i]) < 0:
				dnf = true
			elif i < times.size():
				sum += int(times[i])
		partial.append({"name": opp.get("name", "Rival"), "combined_ms": -1 if dnf else sum, "dnf": dnf})
	return RallyLibrary.build_standings(partial, player_combined, _dnf)


# How many events the player has completed so far (for the interstitial header).
func events_completed() -> int:
	return _event_times_ms.size()


# The fielded car was wrecked (HP→0, from the damage model). Immediate DNF: skip
# the remaining events and resolve. Upgrades already revealed this rally are kept.
func report_wreck() -> void:
	if _phase != Phase.RUNNING:
		return
	_dnf = true
	# The bound damage model already removes the instance; calling again is a
	# harmless no-op, but we own the destruction so report_wreck is correct even
	# when driven directly (tests / an unbound caller).
	if _car_instance_id >= 0:
		Save.wreck_car(_car_instance_id)
		Save.save()
	_resolve_results()


# Abandon mid-rally (from the Pause overlay): end the session back at HQ with the
# rally left incomplete and damage persisted — no penalty, no reward (no retry).
func abandon() -> void:
	if _phase == Phase.IDLE:
		return
	_last_result = {"placed": -1, "completed": false, "combined_ms": -1, "dnf": false, "abandoned": true}
	_reset_to_idle()
	rally_finished.emit(_last_result)


# --- Readouts (menus / tests) ------------------------------------------------

func is_active() -> bool:
	return _phase != Phase.IDLE


func phase() -> int:
	return _phase


func event_index() -> int:
	return _event_index


func event_times_ms() -> Array[int]:
	return _event_times_ms


func car_instance_id() -> int:
	return _car_instance_id


func rally_id() -> String:
	return String(_rally.get("id", ""))


func opponent_field() -> Array:
	return _opponent_field


# The "time to beat" shown at the start line: the fastest non-DNF rival's time (ms)
# for the CURRENT event. The opponents set it (it's a real, beatable stage time),
# unlike the derived par which is faster than the whole field. -1 if no classified
# rival has a time for this event (empty field / before a rally starts).
func current_event_target_ms() -> int:
	if _event_index < 0:
		return -1
	var best := -1
	for opp in _opponent_field:
		var times: Array = opp.get("event_times_ms", [])
		if _event_index < times.size():
			var t := int(times[_event_index])
			if t >= 0 and (best < 0 or t < best):
				best = t
	return best


# The most recent rally's finish summary (for the podium scene). {} before any.
func last_result() -> Dictionary:
	return _last_result


func current_event() -> Dictionary:
	var events: Array = _rally.get("events", [])
	return events[_event_index] if _event_index >= 0 and _event_index < events.size() else {}


# --- Internals ---------------------------------------------------------------

# Enter the current event: announce it (presence + StageManager handoff happen in
# the run scene) and, in real play, load that event's run scene with its seed.
func _enter_event() -> void:
	_set_phase(Phase.RUNNING)
	var event := current_event()
	event_started.emit(_event_index, event)
	if auto_load_scenes:
		_load_event_scene(event)


# Total the events, place against the field, record completion + grant rewards on
# a top-3 finish (showdown wins instead of a car draw), then finish back to IDLE.
func _resolve_results() -> void:
	_set_phase(Phase.RESULTS)
	var combined := -1
	var placed := -1
	if not _dnf:
		combined = 0
		for t in _event_times_ms:
			combined += int(t)
		placed = RallyLibrary.placement(_opponent_field, combined)
	var top3 := not _dnf and placed >= 1 and placed <= 3

	_set_phase(Phase.PODIUM)
	# Reward outcome, captured for the podium reveal (todo/menus.md rig 5).
	var car_reward := ""
	var car_reward_is_new := false
	var showdown_done := false
	if top3:
		# complete_rally records the FIRST completion (idempotent); the car reward
		# fires on EVERY top-3 finish, including re-wins (renewable supply).
		Save.complete_rally(String(_rally.get("id", "")), combined, placed)
		if bool(_rally.get("showdown", false)):
			showdown_done = true
			showdown_won.emit()
		else:
			var model: Variant = RewardSystem.draw_car(int(_rally.get("difficulty", 1)), Save.profile)
			if model != null:
				car_reward = String(model)
				# "New" iff the player didn't already own this model before the grant.
				car_reward_is_new = not _owns_model(car_reward)
				Save.grant_car(car_reward)
				car_rewarded.emit(car_reward)
		Save.save()

	var result := {
		"placed": placed,
		"completed": top3,
		"combined_ms": combined,
		"dnf": _dnf,
		"rally_id": String(_rally.get("id", "")),
		"rally_name": String(_rally.get("name", "")),
		# Full ranked field for the standings overlay (built before _reset clears it).
		"standings": RallyLibrary.build_standings(_opponent_field, combined, _dnf),
		# Reward reveal data (todo/menus.md): per-event upgrades + the top-3 car.
		"upgrades": _upgrades_won.duplicate(),
		"car_reward": car_reward,
		"car_reward_is_new": car_reward_is_new,
		"showdown_won": showdown_done,
	}
	_last_result = result
	_reset_to_idle()
	rally_finished.emit(result)


# Whether the player already owns at least one instance of `model_id` (used to
# flag a car reward as "new" before it is granted).
func _owns_model(model_id: String) -> bool:
	for car in Save.profile.get("cars", []):
		if String(car.get("model_id", "")) == model_id:
			return true
	return false


func _reset_to_idle() -> void:
	_rally = {}
	_car_instance_id = -1
	_event_index = 0
	_event_times_ms = []
	_event_targets_ms = []
	_opponent_field = []
	_dnf = false
	_upgrades_won = []
	_set_phase(Phase.IDLE)


func _set_phase(p: int) -> void:
	_phase = p
	phase_changed.emit(p)


# Per-event target times (ms) for the opponent field, derived by generating each
# event's seeded track (deterministic for the seed). Only used in real play; tests
# pass precomputed targets to start_rally so no track generation happens.
func _compute_event_targets(rally: Dictionary) -> Array:
	var cfg: GameConfig = Config.data
	var targets: Array = []
	for event in rally.get("events", []):
		var width := RallyLibrary.event_width(event)
		var result := TrackGenerator.generate(
			Vector2.ZERO, Vector2(0.0, -1.0), int(event.get("seed", 0)),
			int(event.get("turn_count", 10)), width, cfg.track_clearance)
		targets.append(RallyLibrary.derive_target_ms(result, event))
	return targets


# Write the event's track parameters into the live config and reload the run
# scene. The load hides under the menus fly-through/fade (todo/menus.md). Mirrors
# apply_car's runtime Config.data mutation.
func _load_event_scene(event: Dictionary) -> void:
	var cfg: GameConfig = Config.data
	cfg.track_seed = int(event.get("seed", cfg.track_seed))
	cfg.track_turn_count = int(event.get("turn_count", cfg.track_turn_count))
	cfg.track_width = RallyLibrary.event_width(event)
	get_tree().change_scene_to_file("res://main.tscn")


# Show the between-event standings interstitial; its Continue calls
# continue_to_next_event() to load the next event.
func _load_standings_scene() -> void:
	get_tree().change_scene_to_file("res://standings.tscn")

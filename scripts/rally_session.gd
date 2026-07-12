extends Node
# Autoload "RallySession": the rally-level session orchestrator. One coordinator
# that turns "the player picked rally R with owned car C" into the full loop —
# field the car, run 3 events, accumulate times, place against the fixed opponent
# field, grant rewards, and finish (podium → HQ). It sits one level ABOVE the
# per-stage StageManager (todo/stage-start-and-end.md) and OWNS only the
# rally-level state machine + in-progress state; it CALLS the systems that already
# exist (RallyLibrary, RewardSystem, Save) rather than re-implementing them.
# See features/rally-session.md.
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

# End-of-rally summary (features/rally-session.md API):
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
var _car_model_id := ""                # the fielded car's CarLibrary model id (for the player's standings car)
var _event_index := 0                  # 0..2
var _event_times_ms: Array[int] = []   # accumulated, one per completed event
var _opponent_field: Array = []        # fixed per rally seed (never saved)
var _dnf := false
var _upgrades_won: Array[String] = []  # the single upgrade id drawn this rally (reveal)
var _last_result: Dictionary = {}      # the most recent finish, read by the podium
# Car-park detune-to-enter agreements are TEMPORARY, for this rally only:
# instance_id -> the engine_detune to restore once the rally ENDS (finish, wreck
# or abandon — all funnel through _reset_to_idle, which never runs mid-rally, so
# the tune can't creep back up between events). Registered by hq's detune confirm
# (register_detune_revert); a garage-lift detune never touches this.
var _detune_revert: Dictionary = {}

# One-shot navigation flag set by the podium's final "Continue": tells HQ to open
# straight on the GARAGE view (not the exterior title) when it next boots. NOT
# cleared by _reset_to_idle — it's read + cleared by hq.gd on its next _ready.
var return_to_garage := false

# Free-roam handoff: the owned-car instance the player picked for a session-LESS free
# roam drive (hq.gd → Free Roam). world.gd fields this car when no rally is active
# instead of the default library car. -1 = a plain dev boot (field library car 0).
# Cleared when a real rally starts so it can't leak into a rally event's fielding.
var free_roam_instance_id := -1

# When true (the default for real play) RallySession performs the per-event scene
# loads itself. Headless tests set it false and drive report_* directly with
# precomputed target times, so no track generation or scene reload happens.
var auto_load_scenes := true

# When a live scene (world.gd) will present the standings as an in-world overlay
# (so the run world stays alive for the replay), it sets this and _load_standings_scene
# becomes a no-op — the host owns showing the panel. continue_to_next_event still
# changes scene as usual. See features/event-replay.md.
var standings_overlay_host := false


# --- Public API --------------------------------------------------------------

# Begin a rally with the given RallyDef and fielded OwnedCar. `skip_track_gen`
# skips expensive per-event track generation (tests set it true and overwrite
# _opponent_field themselves before making assertions). When false (real play),
# tracks are generated and the real opponent field is built. Resets all per-rally
# state so re-entering a rally from the map runs fresh (no retry — the opponent
# field and persisted HP are unchanged). Kicks the first event.
func start_rally(rally: Dictionary, owned_car: Dictionary, skip_track_gen := false) -> void:
	_rally = rally
	# A real rally supersedes any pending free-roam pick (world fields the session car).
	free_roam_instance_id = -1
	_car_instance_id = int(owned_car.get("instance_id", -1))
	_car_model_id = String(owned_car.get("model_id", ""))
	# Keep only the fielded car's pending detune revert. An agreement whose start
	# was then backed out of (it never reached start_rally) is settled NOW: that
	# car isn't racing, so its temporary detune is undone immediately rather than
	# lingering to rewrite its tuning when THIS rally ends.
	for id in _detune_revert:
		if int(id) != _car_instance_id:
			Save.set_engine_detune(int(id), float(_detune_revert[id]))
	var pending: Variant = _detune_revert.get(_car_instance_id)
	_detune_revert = {} if pending == null else {_car_instance_id: pending}
	_event_index = 0
	_event_times_ms = []
	_dnf = false
	_upgrades_won = []
	if skip_track_gen:
		# TEST-ONLY path: no real track results are available; generate_opponent_field
		# gets empty lists so rivals have empty event_times_ms and combined_ms=0
		# (placeholder). Tests MUST overwrite _opponent_field before making assertions.
		_opponent_field = RallyLibrary.generate_opponent_field(rally, [], [])
	else:
		var results := _generate_event_tracks(rally)
		_opponent_field = RallyLibrary.generate_opponent_field(rally, results, rally.get("events", []))
	_enter_event()


# An event finished cleanly (from StageManager.stage_completed in the run scene).
# Accumulate the time, persist chip damage, then either advance to the next event
# (via standings) or resolve the rally. The reward upgrades are drawn at rally
# resolution (cfg.rally_upgrade_reward_count per rally, not per event) — see
# _resolve_results.
func report_event_result(elapsed_ms: int, hp_lost: float = 0.0) -> void:
	if _phase != Phase.RUNNING:
		return
	_event_times_ms.append(elapsed_ms)
	# HP persists at each event boundary (Save debounces/autosaves). Only a fielded
	# (bound) car has an instance to write back to.
	if _car_instance_id >= 0 and hp_lost > 0.0:
		Save.apply_damage(_car_instance_id, hp_lost)
		Save.save()
	_event_index += 1
	# The rally now PAUSES on a standings interstitial after EVERY event — including
	# the last, which shows an event-only leaderboard and then resolves to the podium.
	# The player resumes / finishes with continue_to_next_event().
	_set_phase(Phase.STANDINGS)
	standings_ready.emit(_event_index)
	if auto_load_scenes:
		_load_standings_scene()


# Resume from the standings interstitial: into the next event, or — after the final
# event — into results/podium.
func continue_to_next_event() -> void:
	if _phase != Phase.STANDINGS:
		return
	if _event_index >= EVENTS_PER_RALLY:
		_resolve_results()
	else:
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
		partial.append({"name": opp.get("name", "Rival"), "car_name": opp.get("car_name", ""), "combined_ms": -1 if dnf else sum, "dnf": dnf})
	return RallyLibrary.build_standings(partial, player_combined, _dnf, "You", _player_car_name())


# The leaderboard for the JUST-COMPLETED event alone: each racer's time for that
# one event, ranked fastest-first (a rival who DNF'd that event sinks). Read by the
# standings interstitial's first page. The row `combined_ms` carries the single
# event's time (ms). Empty before any event completes.
func current_event_standings() -> Array:
	var idx := _event_times_ms.size() - 1
	if idx < 0:
		return []
	var player_time := int(_event_times_ms[idx])
	var partial: Array = []
	for opp in _opponent_field:
		var times: Array = opp.get("event_times_ms", [])
		var t := -1
		if idx < times.size():
			t = int(times[idx])
		var dnf := t < 0
		partial.append({"name": opp.get("name", "Rival"), "car_name": opp.get("car_name", ""), "car_id": opp.get("car_id", ""), "combined_ms": -1 if dnf else t, "dnf": dnf})
	return RallyLibrary.build_standings(partial, player_time, _dnf, "You", _player_car_name(), _car_model_id)


# The player's fielded car name, for their row in the leaderboards. "" when no car
# is fielded or the model id resolves to nothing (e.g. headless tests).
func _player_car_name() -> String:
	return String(CarLibrary.by_id(_car_model_id).get("name", ""))


# The top `n` rivals for the CURRENT event — each rival's time for THIS event with
# the car they drove, fastest first — shown on the start-line reveal in place of a
# single "time to beat". Rivals who DNF'd this event (no time set) are omitted.
# Returns up to n entries: { name:String, car_name:String, time_ms:int }. Empty
# before a rally starts / when no rival has a time for this event.
func current_event_leaders(n: int = 3) -> Array:
	if _event_index < 0:
		return []
	var rows: Array = []
	for opp in _opponent_field:
		var times: Array = opp.get("event_times_ms", [])
		if _event_index < times.size():
			var t := int(times[_event_index])
			if t >= 0:
				rows.append({
					"name": String(opp.get("name", "Rival")),
					"car_name": String(opp.get("car_name", "")),
					"time_ms": t,
				})
	rows.sort_custom(func(a, b): return int(a["time_ms"]) < int(b["time_ms"]))
	return rows.slice(0, n)


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


# The rival (if any) who crashed out of the CURRENT event, so the run scene can stage
# a wrecked opponent car by the roadside (features/opponent-wrecks.md). Carries the
# crashed rival's name, the ACTUAL car they drove (car_id/car_name), and the seeded
# roadside placement (progress along the track + which verge). {} when no rival wrecked
# this event (at most one ever does). Empty before a rally starts.
func current_event_wreck() -> Dictionary:
	return RallyLibrary.event_wreck(_opponent_field, _event_index)


# The car_meta of the opponent posting the fastest non-DNF time for the CURRENT
# event (the rival the "vs P1" popup tracks). {} if no classified rival has a time.
func current_event_p1_car() -> Dictionary:
	if _event_index < 0:
		return {}
	var best := -1
	var best_id := ""
	for opp in _opponent_field:
		var times: Array = opp.get("event_times_ms", [])
		if _event_index < times.size():
			var tm := int(times[_event_index])
			if tm >= 0 and (best < 0 or tm < best):
				best = tm
				best_id = String(opp.get("car_id", ""))
	return CarLibrary.by_id(best_id) if best_id != "" else {}


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

	# Reward upgrades per FINISHED rally — cfg.rally_upgrade_reward_count of them, each
	# drawn independently and revealed with its own slot-machine spin on the podium. A
	# DNF rally earns nothing. Granted + saved at once so the unseeded draws are
	# savescum-proof (reward-system.md).
	if not _dnf:
		var difficulty := int(_rally.get("difficulty", 1))
		var count: int = maxi(Config.data.rally_upgrade_reward_count, 0)
		# Upgrades are CAR-BOUND: each won part is fitted straight onto the driven
		# car (disabled — the podium's Apply enables the player's pick). Fitting it
		# before the next draw is also what dedups the multi-reward draw: draw_upgrade
		# excludes the car's installed parts, so re-reading the live car each pass
		# stops the same slottable part being won twice in one rally. Repair kits
		# (consumable, exempt from dedup) go to the pooled inventory and may repeat.
		for _i in count:
			var driven: Dictionary = Save.get_car(_car_instance_id)
			var item_id: String = RewardSystem.draw_upgrade(difficulty, Save.profile, null, driven)
			if UpgradeLibrary.is_consumable(item_id):
				Save.add_item(item_id, 1, false)
			else:
				Save.install_upgrade(_car_instance_id, item_id, false)
			_upgrades_won.append(item_id)
			upgrade_revealed.emit(item_id)
		Save.save()

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
			var model: Variant = RewardSystem.draw_car(Save.profile)
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
		# The owned-car instance the player just drove — the podium's upgrade reveal
		# offers to fit each won part straight onto it (features/reward-system.md).
		"car_instance_id": _car_instance_id,
		# Full ranked field for the standings overlay (built before _reset clears it).
		# Carries each entrant's car_id too, so the podium can spawn the top-3 cars.
		"standings": RallyLibrary.build_standings(_opponent_field, combined, _dnf, "You", _player_car_name(), _car_model_id),
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


# A car-park "Detune to N% & Start" agreement is only for the rally being entered:
# remember the tune to put back afterwards (the garage-set value, or the 1.0
# default if the car was never tuned). Called by hq's detune confirm just before
# it applies the temporary detune; the restore happens in _reset_to_idle.
func register_detune_revert(instance_id: int, prior_frac: float) -> void:
	if instance_id < 0:
		return
	_detune_revert[instance_id] = clampf(prior_frac, 0.0, 1.0)


func _reset_to_idle() -> void:
	# The rally is over (finish, wreck or abandon): put back the engine tune the
	# car-park detune agreement temporarily overrode. Only here — never at an
	# event boundary — so the tune can't go back up mid-rally.
	for id in _detune_revert:
		Save.set_engine_detune(int(id), float(_detune_revert[id]))
	_detune_revert = {}
	_rally = {}
	_car_instance_id = -1
	_car_model_id = ""
	_event_index = 0
	_event_times_ms = []
	_opponent_field = []
	_dnf = false
	_upgrades_won = []
	_set_phase(Phase.IDLE)


func _set_phase(p: int) -> void:
	_phase = p
	phase_changed.emit(p)


# Per-event track results for the opponent field, derived by generating each event's
# seeded track (deterministic for the seed). Only used in real play; tests pass
# skip_track_gen=true to start_rally so no track generation happens.
func _generate_event_tracks(rally: Dictionary) -> Array:
	var cfg: GameConfig = Config.data
	# Match the run scene's start-line lead-in reservation (world.gd) so the
	# track shape — and thus the rival times — equal what the player drives.
	var reserve_behind := 0.0
	if cfg.start_line_enabled:
		reserve_behind = cfg.start_lead_in_ahead_m + cfg.start_lead_in_behind_m
	var results: Array = []
	for event in rally.get("events", []):
		var width := RallyLibrary.event_width(event)
		var result := TrackGenerator.generate(
			Vector2.ZERO, Vector2(0.0, -1.0), int(event.get("seed", 0)),
			int(event.get("turn_count", 10)), width, cfg.track_clearance, reserve_behind,
			RallyLibrary.event_straightness(event), cfg.track_runoff_m)
		results.append(result)
	return results


# Write the event's track parameters into the live config and reload the run
# scene. The load hides under the menus fly-through/fade (todo/menus.md). Mirrors
# apply_car's runtime Config.data mutation.
func _load_event_scene(event: Dictionary) -> void:
	var cfg: GameConfig = Config.data
	cfg.track_seed = int(event.get("seed", cfg.track_seed))
	cfg.track_turn_count = int(event.get("turn_count", cfg.track_turn_count))
	cfg.track_straightness = RallyLibrary.event_straightness(event)
	cfg.track_width = RallyLibrary.event_width(event)
	cfg.track_forestiness = RallyLibrary.event_forestiness(event)
	cfg.track_tarmac_fraction = RallyLibrary.event_tarmac_fraction(event)
	cfg.cliff_amount = RallyLibrary.event_cliffiness(event)   # [0,1], scales cliff_max_height_m
	get_tree().change_scene_to_file("res://main.tscn")


# Show the between-event standings interstitial; its Continue calls
# continue_to_next_event() to load the next event.
func _load_standings_scene() -> void:
	if standings_overlay_host:
		return
	get_tree().change_scene_to_file("res://standings.tscn")

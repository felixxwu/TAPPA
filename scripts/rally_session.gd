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

# The stage count a rally has UNLESS it authors otherwise — the default, not the rule.
# Ask stage_count() for the active rally's real figure: opening rallies run a single stage
# (todo/opening-rally.md), and anything reading this constant as "how many stages are we
# running" will overrun them.
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

# The rival grid was RE-DRAWN mid-flow (refield_opponents), so anything derived from it
# is now stale. The run scene listens: it snapshots P1 for the ghost and the "vs P1"
# popup when the stage builds, which is BEFORE the start-line overlay the player can
# edit upgrades on — so without this the ghost would keep racing the field the player
# turned up with rather than the one they are actually about to race.
signal opponent_field_changed()
# A per-event upgrade was drawn + granted — reward reveal hook (menus rig 5).
signal upgrade_revealed(item_id: String)
# A top-3 car reward was drawn + granted — reward reveal (car arrives in HQ).
signal car_rewarded(model_id: String)
# The final special event won: the game's win / credits beat fires instead of a draw.
signal game_won()

var _phase: int = Phase.IDLE
var _rally: Dictionary = {}            # the RallyDef being run ({} when IDLE)
var _car_instance_id := -1             # the fielded OwnedCar instance
var _car_model_id := ""                # the fielded car's CarLibrary model id (for the player's standings car)
var _event_index := 0                  # 0..2
var _event_times_ms: Array[int] = []   # accumulated, one per completed event
var _opponent_field: Array = []        # drawn per rally seed + the player's rating (never saved)
var _event_results: Array = []         # this rally's generated track results, kept so the field
                                       # can be re-drawn without regenerating terrain (refield_opponents)
var _fielded_rating := 0               # the player rating _opponent_field was matched to
var _dnf := false
var _upgrades_won: Array[String] = []  # every per-event upgrade id drawn this rally (record)
var _event_upgrade := ""               # the upgrade id won for the just-completed event ("" if none)
var _pending_repair: Dictionary = {}   # between-event pit-repair summary, shown once by the run scene (take_pending_repair)
var _last_result: Dictionary = {}      # the most recent finish, read by the podium
# Car-park detune-to-enter agreements are TEMPORARY, for this rally only:
# instance_id -> the engine_detune to restore once the rally ENDS (finish, wreck
# or abandon — all funnel through _reset_to_idle, which never runs mid-rally, so
# the tune can't creep back up between events). Registered by hq's detune confirm
# (register_detune_revert); a garage-lift detune never touches this.
var _detune_revert: Dictionary = {}
# Car-park drivetrain-to-enter agreements are TEMPORARY, for this rally only:
# instance_id -> the drive_mode override to restore once the rally ENDS. Mirrors
# _detune_revert; a garage-set drivetrain choice never touches this.
var _drivetrain_revert: Dictionary = {}

# One-shot navigation flag set by the podium's final "Continue": tells HQ to open
# straight on the GARAGE view (not the exterior title) when it next boots. NOT
# cleared by _reset_to_idle — it's read + cleared by hq.gd on its next _ready.
var return_to_garage := false

# One-shot navigation flag, same lifecycle as `return_to_garage` but pointing at the MAP
# TABLE instead, and taking priority over it when both are set. Raised when the finished
# rally was the player's OPENING rally (todo/opening-rally.md): that run happens before
# the map has ever been seen, and its whole point is the arrival — the player lands on the
# table with their first rally already complete and its neighbours lighting up around it.
# Sending them to the garage instead would bury the one beat the flow exists to deliver.
var return_to_map := false

# The owned-car instance the player has just WON, waiting to be revealed at HQ (-1 when
# nothing is pending). One-shot, same lifecycle as the flags above: read and cleared by
# hq.gd on its next _ready.
#
# The reveal is the PRESENT BOX in the car park, not a podium stage: winning a car is the
# biggest thing that happens in this game and it deserves the beat where the car physically
# is, rather than a slot-machine reel on the results screen. See hq.gd::_enter_present_box.
var pending_car_reveal_instance_id := -1

# Free-roam handoff: the car the player picked for a session-LESS free-roam drive.
#   free_roam_instance_id — an OWNED instance (Test Drive of the tuned car on the lift,
#     or an owned car picked in Free Roam). world.gd fields it with upgrades + saved HP.
#   free_roam_model_id     — a bare catalogue MODEL id (a not-yet-owned car picked in
#     Free Roam). world.gd fields the base model when no owned instance is set.
# world.gd fields one of these when no rally is active, else the default library car.
# -1 / "" = a plain dev boot (field library car 0). Both are cleared when a real rally
# starts so they can't leak into a rally event's fielding.
var free_roam_instance_id := -1
var free_roam_model_id := ""

# Region the current free-roam drive should wear (id from RegionLibrary). Chosen at
# random when hq.gd prepares free roam; "" / a plain dev boot falls back to home.
# Only consulted while a free-roam car is set (see world.gd _current_region_look).
var free_roam_region_id := ""


# THE one place "a real session supersedes a pending free-roam pick" is spelled
# out. Called by start_rally, ChallengeSession.start/resume and Benchmark.start —
# all three field their own car and author their own region, so a leftover
# free-roam pick must never survive into them. Clearing the REGION too (which the
# old inline copy in start_rally forgot) is what stops a free-roam drive's random
# sky/ground/tree mix leaking into the next session's stage: world.gd
# _current_region_look only consults free_roam_region_id while a free-roam car is
# set, but a Pause -> Quit from free roam leaves BOTH set. See
# todo/challenge-career-reuse-drift.md item 9.
func clear_free_roam_handoff() -> void:
	free_roam_instance_id = -1
	free_roam_model_id = ""
	free_roam_region_id = ""

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
	clear_free_roam_handoff()
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
	# Keep only the fielded car's pending drivetrain revert. An agreement whose start
	# was then backed out of (it never reached start_rally) is settled NOW: that
	# car isn't racing, so its temporary drivetrain switch is undone immediately rather than
	# lingering to rewrite its override when THIS rally ends.
	for id in _drivetrain_revert:
		if int(id) != _car_instance_id:
			Save.set_drivetrain_override(int(id), int(_drivetrain_revert[id]))
	var pending_dm: Variant = _drivetrain_revert.get(_car_instance_id)
	_drivetrain_revert = {} if pending_dm == null else {_car_instance_id: pending_dm}
	_event_index = 0
	_event_times_ms = []
	_dnf = false
	_upgrades_won = []
	_pending_repair = {}
	if skip_track_gen:
		# TEST-ONLY path: no real track results are available; generate_opponent_field
		# gets empty lists so rivals have empty event_times_ms and combined_ms=0
		# (placeholder). Tests MUST overwrite _opponent_field before making assertions.
		_event_results = []
		_fielded_rating = _field_rating(owned_car)
		_opponent_field = RallyLibrary.generate_opponent_field(
			rally, [], [], _fielded_rating)
		_log_opponent_field("drawn (no tracks — test path)")
	else:
		# results feed the run scene / target-time path.
		var results := await _generate_event_tracks(rally)
		_event_results = results
		# ALWAYS generated live. There used to be a committed lockfile
		# (data/opponent_cache.json) consulted here, keyed on rally properties; it went
		# with the car-performance rating rework, because the grid is now drawn matched
		# to the PLAYER'S car rating and so is a function of the player, not the rally.
		_fielded_rating = _field_rating(owned_car)
		_opponent_field = RallyLibrary.generate_opponent_field(
			rally, results, rally.get("events", []), _fielded_rating)
		_log_opponent_field("drawn at rally start")
	_enter_event()


# Re-draw the rival grid against the player's CURRENT build, and report whether it
# actually changed.
#
# WHY THIS EXISTS: the grid is matched to the player's rating, and the start line lets
# the player edit upgrades AFTER the field was drawn. Without this, fitting a turbo on
# the grid would leave you racing a field picked for the car you turned up in — the
# matching silently stops meaning anything at exactly the moment the player engages with
# it. Recomputing is cheap (the tracks are already generated and held in _event_results;
# this only re-solves point-mass times), which is why it can run on a menu close.
#
# ONLY BEFORE THE FIRST STAGE. A rally's standings accumulate across its events, so
# re-drawing at stage 2 would rewrite times the rivals have already "set" and silently
# rewrite the leaderboard the player has been racing against. Mid-rally the grid is
# locked, which is also the honest reading of a rally: you enter it with a car.
func refield_opponents() -> bool:
	if _event_index != 0 or not _event_times_ms.is_empty():
		return false
	if _rally.is_empty():
		return false
	var rating := _field_rating(Save.get_car(_car_instance_id))
	if rating == _fielded_rating:
		return false
	_fielded_rating = rating
	_opponent_field = RallyLibrary.generate_opponent_field(
		_rally, _event_results, _rally.get("events", []), rating)
	_log_opponent_field("re-drawn after a start-line build change")
	opponent_field_changed.emit()
	return true


# Print the grid and what it was matched against. The field is now a function of the
# PLAYER'S car, so "why am I racing these cars" is a question with an actual answer —
# this is that answer, in the one place it can be read against the player's own rating.
# Sorted fastest-first so the shape of the match is visible at a glance rather than
# having to be reconstructed from the draw order.
func _log_opponent_field(context: String) -> void:
	var rows: Array = []
	for rival in _opponent_field:
		rows.append({
			"rating": int((rival as Dictionary).get("rating", 0)),
			"name": String((rival as Dictionary).get("car_name", "?")),
			"driver": String((rival as Dictionary).get("name", "?")),
		})
	rows.sort_custom(func(a, b): return int(a["rating"]) > int(b["rating"]))
	print("[opponent field] %s — %s | target rating %d (%s) | %d rivals"
		% [String(_rally.get("id", "?")), context, _fielded_rating,
			AiDifficulty.describe(Save.profile), rows.size()])
	for row in rows:
		var delta: int = int(row["rating"]) - _fielded_rating
		print("  %4d  (%+5d)  %-28s %s" % [int(row["rating"]), delta, row["name"], row["driver"]])


# Fold the stage into the difficulty offset and say so on the console.
#
# The system is SILENT to the player, so this log is the only way to see it working — and
# it deliberately reports the DIRECTION OF TRAVEL, not just the current state: two stages
# out of every three change nothing, and without the streak fraction those look identical
# to a system that has stopped responding.
#
# The margin is printed because it is the thing the offset is reacting to: losing by 0.2 s
# and losing by 30 s both read as "LOST" to the rule, and only the log can tell you which
# kind of trouble the player is in.
func _record_and_log_stage_result(elapsed_ms: int) -> void:
	var before := {
		AiDifficulty.KEY_STEPS: Save.profile.get(AiDifficulty.KEY_STEPS, 0),
		AiDifficulty.KEY_WIN_STREAK: Save.profile.get(AiDifficulty.KEY_WIN_STREAK, 0),
		AiDifficulty.KEY_LOSS_STREAK: Save.profile.get(AiDifficulty.KEY_LOSS_STREAK, 0),
	}
	var won := _won_stage(elapsed_ms)
	Save.record_stage_result(won)
	if not Config.data.ai_adapt_enabled:
		return
	var leaders := current_event_leaders(1)
	var margin := ""
	if not leaders.is_empty():
		var p1 := int((leaders[0] as Dictionary).get("time_ms", 0))
		margin = "  (%s%.1fs vs P1)" % ["+" if elapsed_ms > p1 else "", (elapsed_ms - p1) / 1000.0]
	print("[difficulty] %s stage %d — %s%s" % [String(_rally.get("id", "?")),
		_event_index + 1, AiDifficulty.describe_result(before, Save.profile, won), margin])


# Did the player beat every rival on the stage that just finished?
#
# The whole input to adaptive difficulty. Deliberately per-STAGE rather than per-rally: a
# rally is three stages, so stage-level results give the system three times the evidence
# and let it respond within a single event rather than after a whole rally has gone badly.
#
# An empty field (a rally with no rivals, or the test path) counts as NOT won: with nobody
# to beat there is no evidence the player is fast, and treating it as a win would ratchet
# the difficulty up on no information at all.
func _won_stage(elapsed_ms: int) -> bool:
	var leaders := current_event_leaders(1)
	if leaders.is_empty():
		return false
	return elapsed_ms > 0 and elapsed_ms < int((leaders[0] as Dictionary).get("time_ms", 0))


# The rating the FIELD is matched to: the player's own, pushed up or down by the adaptive
# offset. Everything that draws a field goes through here so a re-draw cannot silently
# reset the difficulty back to a plain match.
func _field_rating(owned_car: Dictionary) -> int:
	return AiDifficulty.target_rating(_player_rating(owned_car), Save.profile)


# The fielded car's CarPerformance rating, used to match the rival grid to the player's
# pace. 0 (unmatched draw) when the car doesn't resolve to a catalogue entry — a
# synthetic/free-roam handoff in a test, say — so the field still forms.
func _player_rating(owned_car: Dictionary) -> int:
	var entry := CarLibrary.by_id(String(owned_car.get("model_id", "")))
	if entry.is_empty():
		return 0
	return CarPerformance.rating(CarPerformance.merged_meta(owned_car, entry))


# An event finished cleanly (from StageManager.stage_completed in the run scene).
# Accumulate the time, persist chip damage, award one upgrade for a NON-FINAL event,
# then pause on the standings interstitial. The player resumes / finishes with
# continue_to_next_event().
func report_event_result(elapsed_ms: int, hp_lost: float = 0.0) -> void:
	if _phase != Phase.RUNNING:
		return
	_event_times_ms.append(elapsed_ms)
	# Adaptive difficulty (features/adaptive-difficulty.md). Read the stage BEFORE
	# _event_index advances, because current_event_leaders() answers for the current index.
	# A DNF is not a measurement of pace or skill, so it moves nothing.
	if not _dnf:
		_record_and_log_stage_result(elapsed_ms)
	elif Config.data.ai_adapt_enabled:
		print("[difficulty] %s stage %d — DNF, ignored | %s"
			% [String(_rally.get("id", "?")), _event_index + 1, AiDifficulty.describe(Save.profile)])
	# HP persists at each event boundary. Only a fielded (bound) car has an instance
	# to write back to. The damage + the upgrade write below share a single Save.save()
	# at the end so a damaged non-final event doesn't serialise/write the file twice.
	var damaged := _car_instance_id >= 0 and hp_lost > 0.0
	if damaged:
		Save.apply_damage(_car_instance_id, hp_lost)
	_event_index += 1
	# One upgrade is awarded for FINISHING each NON-FINAL event (events before the
	# last). Earned by completing the event — kept even if the player later DNFs.
	# Drawn + installed + saved here so the standings reveal only enables the pick,
	# and so the unseeded draw is savescum-proof (reward-system.md). The final event
	# awards no upgrade (the podium reveals the car instead).
	_event_upgrade = ""
	# Two SEPARATE questions, deliberately not one flag. `at_award_boundary` is about the
	# flow (only non-final events pay out at all); `_event_upgrade` non-empty is about the
	# draw actually yielding something. A maxed-out car can now legitimately win NOTHING
	# (RewardSystem.NO_REWARD) — in that case we install nothing, record nothing, and fire
	# no reveal, so the flow runs straight on to the standings interstitial.
	var at_award_boundary := _event_index < stage_count()
	if at_award_boundary:
		_event_upgrade = RewardSystem.draw_and_grant_upgrade(_car_instance_id, Save.profile)
		if _event_upgrade != "":
			_upgrades_won.append(_event_upgrade)
	if damaged or _event_upgrade != "":
		Save.save()
	if _event_upgrade != "":
		upgrade_revealed.emit(_event_upgrade)
	# The rally now PAUSES on a standings interstitial after EVERY event — including
	# the last, which shows an event-only leaderboard and then resolves to the podium.
	_set_phase(Phase.STANDINGS)
	standings_ready.emit(_event_index)
	if auto_load_scenes:
		_load_standings_scene()


# Resume from the standings interstitial: into the next event, or — after the final
# event — into results/podium.
func continue_to_next_event() -> void:
	if _phase != Phase.STANDINGS:
		return
	if _event_index >= stage_count():
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
	return RallyLibrary.build_standings(partial, player_time, _dnf, "You", _player_car_name(),
		_car_model_id, _player_engine_id())


# The player's fielded car name, for their row in the leaderboards. "" when no car
# is fielded or the model id resolves to nothing (e.g. headless tests).
func _player_car_name() -> String:
	var entry := CarLibrary.by_id(_car_model_id)
	return EngineSwap.display_name(entry, Save.get_car(_car_instance_id))


# The engine the player's fielded car is actually running — its swapped-in engine when it
# has one, else the model's stock engine. Mirrors _player_car_name: "" when nothing resolves
# (headless), which CarProp.spawn reads as "use the catalogue stock engine".
func _player_engine_id() -> String:
	var entry := CarLibrary.by_id(_car_model_id)
	if entry.is_empty():
		return ""
	return EngineSwap.current_engine_id(Save.get_car(_car_instance_id), String(entry.get("engine", "")))


# The top `n` rivals for the CURRENT event — each rival's time for THIS event with
# the car they drove, fastest first — shown on the start-line reveal in place of a
# single "time to beat". Rivals who DNF'd this event (no time set) are omitted.
# Returns up to n entries:
# { name:String, car_id:String, engine_id:String, car_name:String, time_ms:int }.
# `car_id` lets the start-line grid spawn each leader's actual car, and `engine_id` its
# FITTED engine — rivals run engine swaps (features/rally-roster.md), so without it the
# grid prop would idle and pull away on the car's STOCK engine while the reveal card
# named the swapped one. Empty before a rally starts / when no rival has a time for
# this event.
func current_event_leaders(n: int = 3) -> Array:
	if _event_index < 0:
		return []
	var rows: Array = []
	for opp in _opponent_field:
		var times: Array = opp.get("event_times_ms", [])
		if _event_index < times.size():
			var t := int(times[_event_index])
			if t >= 0:
				var row := RallyLibrary.identity_of(opp)
				if String(row["name"]) == "":
					row["name"] = "Rival"
				row["time_ms"] = t
				rows.append(row)
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
		Save.record_wreck(_car_instance_id)
		Save.save()
	_resolve_results()


# DEV: instantly finish the whole rally. Every event (already-run or not) is
# credited a perfect 0 ms time and the rally resolves STRAIGHT to the podium —
# skipping the remaining events and the standings interstitials. A combined time
# of 0 out-runs any rival, so it always places P1 (top-3) and the podium grants
# the car reward. Surfaced only while a rally is active (settings dev page); the
# emitted rally_finished routes to the podium exactly like a real finish.
func dev_complete_rally() -> void:
	if _phase == Phase.IDLE:
		return
	_dnf = false
	_event_times_ms = []
	for _i in stage_count():
		_event_times_ms.append(0)
	_event_index = stage_count()
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


# How many stages THIS rally runs — its own authored `events` list. Falls back to
# EVENTS_PER_RALLY only when there is no rally (session-less callers), so a rally that
# authors one stage runs one and a rally that authors three runs three.
#
# Every "are we done" and "how far through" question must come here rather than to the
# constant: the opening rallies author a single stage, and reading a hardcoded 3 would run
# the session past the end of the events array.
func stage_count() -> int:
	var events: Array = _rally.get("events", [])
	return events.size() if events.size() > 0 else EVENTS_PER_RALLY


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
	var p1 := current_event_p1()
	return int(p1["time_ms"]) if not p1.is_empty() else -1


# ONE snapshot of the event's P1: the leader row AND its effective car meta, resolved
# together from a single current_event_leaders(1) read.
#
# Exists because P1 now has three consumers — the HUD's target readout, the in-stage
# "vs P1" split popup, and the rival ghost (features/rival-ghost.md) — and the ghost has
# to show the SAME car and the SAME time the standings will report. Three independent
# lookups agree today only because event times are fixed at field generation; one shared
# snapshot makes that structural instead of incidental.
#
# Returns {} when no rival has a classified time this event (all DNF, or no field).
# Keys: name, car_id, engine_id, car_name, time_ms, meta.
func current_event_p1() -> Dictionary:
	var leaders := current_event_leaders(1)
	if leaders.is_empty():
		return {}
	var row: Dictionary = (leaders[0] as Dictionary).duplicate()
	row["time_ms"] = int(leaders[0]["time_ms"])
	row["meta"] = _effective_meta_for(row)
	# This event's baked rival-ghost pace seed, if the cache carried one. -1 = solve from
	# scratch (a live-generated field, or a cache written before the field existed).
	row["skill_k"] = _p1_skill_seed(int(row["time_ms"]))
	return row


# The cached pace seed for the current event's P1, or -1.0 when there isn't one.
#
# Takes the time as an ARGUMENT rather than reading current_event_target_ms(): that
# delegates to current_event_p1(), which calls this — straight into infinite recursion.
func _p1_skill_seed(target_ms: int) -> float:
	for opp in _opponent_field:
		var times: Array = opp.get("event_times_ms", [])
		if _event_index >= times.size():
			continue
		var seeds: Array = opp.get("skill_k", [])
		if _event_index >= seeds.size():
			continue
		# Match the row identity_of would carry, not object identity: current_event_leaders
		# returns copies.
		if int(times[_event_index]) == target_ms:
			return float(seeds[_event_index])
	return -1.0


# The car meta for a leader row: the catalogue entry run through effective_meta with the
# rival's FITTED engine. Resolving from the row's car_id is required, not forbidden —
# it is the only path to a meta — but it must happen ONCE, from the snapshotted row,
# rather than via a second independent leaders() lookup.
#
# Using the bare catalogue entry here is a bug with history: it derives a profile for a
# car that wasn't racing, while the time it is compared against came from the swapped
# build in generate_opponent_field.
func _effective_meta_for(row: Dictionary) -> Dictionary:
	var entry := CarLibrary.by_id(String(row.get("car_id", "")))
	if entry.is_empty():
		return {}
	var eid := String(row.get("engine_id", ""))
	var owned: Dictionary = {"swapped_engine": eid} if eid != "" else {}
	# Rivals also run a BUILD LEVEL (RallyLibrary._build_levels), and their times were drawn
	# off a meta that includes those parts — so the parts have to come back with the row or
	# the ghost solves a slower car than the one that set the time and RivalPace clamps.
	owned["installed_upgrades"] = (row.get("upgrades", []) as Array).duplicate()
	owned["disabled_upgrades"] = []
	# merged_meta, not effective_meta: a build level can carry tyres and a wing, which reach
	# the lap-time model only through the grip fields effective_meta withholds. Same builder
	# the field generator rated the combo with.
	return CarPerformance.merged_meta(owned, entry)


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
	var p1 := current_event_p1()
	return p1.get("meta", {}) if not p1.is_empty() else {}


# The most recent rally's finish summary (for the podium scene). {} before any.
func last_result() -> Dictionary:
	return _last_result


# Seats the owning rally's "region" tag onto the returned dict (a shallow copy,
# never mutating the authored event) so downstream water-level resolution
# (TrackGenParams.resolve_water_level, via apply_event_config) can fall back to the
# region's waterline for an event that authors none — see features/lakes.md.
func current_event() -> Dictionary:
	var events: Array = _rally.get("events", [])
	if _event_index < 0 or _event_index >= events.size():
		return {}
	var event: Dictionary = (events[_event_index] as Dictionary).duplicate()
	event["region"] = _rally.get("region", "")
	return event


# The upgrade id won for the just-completed non-final event, read by the standings
# reveal. "" after the final event (no per-event award) or before any draw.
func current_event_upgrade() -> String:
	return _event_upgrade


# --- Internals ---------------------------------------------------------------

# Enter the current event: announce it (presence + StageManager handoff happen in
# the run scene) and, in real play, load that event's run scene with its seed.
func _enter_event() -> void:
	_event_upgrade = ""
	# Between-event pit repairs: at the start of EVERY event after the first, the
	# engineers patch the fielded car up — restore a slice of the lost HP and bend the
	# bent wheels part-way back toward straight. This mutates the OwnedCar BEFORE the
	# scene reloads, so world.gd fields the already-repaired car (and shows the popup
	# from take_pending_repair). See features/damage.md.
	if _event_index >= 1 and _car_instance_id >= 0:
		_pending_repair = _apply_field_repair()
	_set_phase(Phase.RUNNING)
	var event := current_event()
	event_started.emit(_event_index, event)
	if auto_load_scenes:
		_load_event_scene(event)


# The between-event repair summary for the event about to run (see _enter_event /
# Save.field_repair), consumed ONCE by the run scene to show the repair popup. Cleared
# on read so a scene regeneration (pause → reset) doesn't replay the popup. Returns
# {"repaired": false} when nothing was repaired (first event, or a pristine car).
func take_pending_repair() -> Dictionary:
	var r := _pending_repair
	_pending_repair = {}
	return r


# Shared repair-application: patch the fielded car up by the same partial fraction
# used at every stage-to-stage transition (Save.field_repair with cfg's
# field_repair_hp_fraction / field_repair_toe_fraction). Extracted so the
# between-event repair (_enter_event) and the final-event repair (_resolve_results)
# can't drift apart on which fractions they apply. Caller decides what (if
# anything) to do with the returned summary.
#
# STATIC, and public, because ChallengeSession's stage-to-stage and final-stage
# repairs go through it too (todo/challenge-career-reuse-drift.md item 5) — it
# used to hand-roll the same two config reads as _field_repair_for_next_stage,
# which is exactly the one-rule-two-places drift this fold removes.
static func apply_field_repair_to(instance_id: int) -> Dictionary:
	if instance_id < 0:
		return {"repaired": false}
	var cfg := Config.data
	return Save.field_repair(instance_id,
		cfg.field_repair_hp_fraction, cfg.field_repair_toe_fraction)


func _apply_field_repair() -> Dictionary:
	return apply_field_repair_to(_car_instance_id)


# Total the events, place against the field, record completion + grant rewards on
# a top-3 finish (the final special wins instead of a car draw), then finish back to IDLE.
func _resolve_results() -> void:
	# The same partial pit repair every other stage-to-stage transition gets — applied
	# here too, since the final event's damage would otherwise never be repaired (it
	# has no "next event" for _enter_event to patch it up before). Applied SILENTLY:
	# the result is discarded rather than stashed in _pending_repair, so it never
	# surfaces the between-event repair popup during the podium/results flow, which
	# has its own reveal UI. See features/damage.md.
	if _car_instance_id >= 0:
		_apply_field_repair()
	_set_phase(Phase.RESULTS)
	var combined := -1
	var placed := -1
	if not _dnf:
		combined = 0
		for t in _event_times_ms:
			combined += int(t)
		placed = RallyLibrary.placement(_opponent_field, combined)
	var top3 := not _dnf and placed >= 1 and placed <= 3
	# THE ONE PLACE `completed` DIVERGES FROM "PODIUMED" (todo/opening-rally.md).
	#
	# The opening rally — the event awarding the car the player chose in the starter
	# picker, which they are dropped straight into before the map exists — is recorded
	# complete whatever the result, DNF included. Placement still decides the stars, via
	# the same complete_rally delta as everywhere else; only the `completed` flag is given.
	#
	# It is an introduction, not a test: a first-time player who comes 4th would otherwise
	# land on a map lit by nothing but HQ and the rally they just failed, a dead end
	# produced by the one run they had no way to prepare for.
	#
	# FIRST attempt only. Once it is completed the rally is an ordinary one — a retry is
	# scored by the normal podium rule, so the carve-out cannot become a permanent
	# "this rally always counts" that quietly launders DNFs into best times.
	#
	# The exception lives HERE, at the call site, rather than as a parameter on
	# Save.complete_rally: every other caller must keep the podium rule, and a flag on the
	# shared function is an invitation to misuse it.
	var opening_first := _is_opening_first_attempt()
	var record_completion := top3 or opening_first

	# Upgrades are awarded per NON-FINAL event (in report_event_result), not at
	# resolve. The podium reveals only the car reward below.
	_set_phase(Phase.PODIUM)
	# The car a CAR-UNLOCK rally hands over, captured for the podium's CAR_REVEAL stage
	# (the slot-machine reel + showroom turntable). "" for every other rally and for a
	# re-win, which is what keeps the stage out of the podium's list.
	#
	# This is the SAME pair the retired random draw fed, deliberately reused: the reveal
	# beat is identical — a car you did not have is being delivered — so a second parallel
	# result field would have meant two ways to say one thing and two podium code paths.
	var car_reward := ""
	var car_reward_is_new := false
	var game_won_now := false
	var special_unlock := {}
	# Stars this finish added to the ledger, and what the rally is now RATED. The two
	# differ on a re-win: rating is what best_placed is worth, gained is the improvement
	# (0 when the placement did not beat the previous best). The podium's stars beat shows
	# the rating as gold stars and the gained figure as text — see todo/star-economy.md.
	var stars_gained := 0
	var star_rating := 0

	if record_completion:
		var rally_id := String(_rally.get("id", ""))
		# Captured BEFORE complete_rally, which is what sets `completed` — afterwards the
		# profile can no longer tell a first win from a re-win, and the unlock reveal must
		# fire exactly once (todo/special-unlock-reveal.md).
		var was_completed: bool = bool((Save.profile.get(Save.KEY_RALLIES, {}) as Dictionary)
			.get(rally_id, {}).get("completed", false))
		# complete_rally records the FIRST completion (idempotent) and returns the STARS it
		# credited for THIS finish — every finish pays, so a replay pays again.
		stars_gained = Save.complete_rally(rally_id, combined, placed)
		star_rating = RallyLibrary.stars_for_placement(Save.best_placement(rally_id))
		# A PART-UNLOCK rally's first win discovers the part garage-wide and hands one copy
		# to the car that just earned it — cascading any prerequisite rungs that car is
		# missing, so the award is usable (RewardSystem.grant_special_unlock).
		#
		# Keyed on the rally having a PART PRIZE (RallyLibrary.prize_part_id, derived from
		# the upgrade's own unlocked_by_rally gate) rather than on `special`: what a rally
		# awards is now its own property, and an ordinary rally may carry a part prize just
		# as a special may carry none. `special` is a MARKER, not a reward tier.
		#
		# Discovery itself needs no new save state: UpgradeLibrary.rally_gate_met already
		# reads "is the gating rally completed", and complete_rally above has just recorded
		# exactly that. One fact, one place.
		if not was_completed:
			var unlocked := UpgradeLibrary.unlocked_by(rally_id)
			if not unlocked.is_empty():
				var item_id := String(unlocked.get("id", ""))
				special_unlock = {
					"item_id": item_id,
					"granted": RewardSystem.grant_special_unlock(_car_instance_id, item_id),
				}
			elif rally_id == RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY:
				# A special may gate a CAPABILITY rather than a catalogue part, authored the
				# other way round (RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY) so it is not in
				# UpgradeLibrary's index. It still gets announced — and it is the LOWEST rung,
				# so without this branch the very first unlock a player earns would pass in
				# silence. The map pin has always handled this case
				# (hq.gd::_special_unlock_line); this mirrors it.
				#
				# It also hands over ONE swap token, so the capability is usable the moment
				# it is announced. Unlocking the station and then making the player wait on a
				# rare drop (RewardSystem.ENGINE_SWAP_TOKEN_DROP_CHANCE) before they can
				# try it would make the reveal a promise rather than a reward.
				Save.add_item(UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, 1, false)
				special_unlock = {
					"item_id": "",
					"capability": "engine_swap",
					"granted": [UpgradeLibrary.ENGINE_SWAP_TOKEN_ID],
				}
		# The endgame is completing EVERY special event on the star ladder — no designated
		# final region (todo/star-gated-special-events.md). complete_rally() above has
		# already recorded THIS special, so the last one to be won sees itself counted here
		# and fires the credits; ordering matters and is why the check sits after it.
		var is_final_special := RallyLibrary.is_special(_rally) \
			and RallyLibrary.all_specials_completed(Save.profile)
		if is_final_special:
			# Every special is now done: fire the win/credits beat.
			game_won_now = true
			game_won.emit()
		# A CAR-UNLOCK rally's first win hands over the car the whole field was driving.
		# This is the ONLY way a car is earned: nothing is drawn at random and nothing is
		# bought, so what the player owns is exactly what they went out and won.
		#
		# FIRST win only (`was_completed`), like the part award — re-running a prize rally
		# pays stars again but cannot mint duplicate cars. The old model drew a random car
		# on every top-3 INCLUDING re-wins, which both farmed cars off one easy rally and
		# filled the garage with something for every class by about the fifth rally, after
		# which no `restriction` band ever excluded the player from anything again.
		# Simulation confirmed it — `revealed` and `eligible` were identical from rally 5 on.
		var prize_car_id := RallyLibrary.prize_car_id(_rally)
		if prize_car_id != "" and not was_completed:
			# Guard the duplicate anyway: a re-authored roster could point two rallies at
			# one car, and a garage holding the same model twice is a content bug the
			# player would carry for good. test_no_two_rallies_award_the_same_car covers
			# the roster; this covers the runtime.
			if not Save.owns_model(prize_car_id):
				var won_car := Save.grant_car(prize_car_id)
				# Hand the new car to HQ to reveal in the present box. The car is already
				# GRANTED here — the box is a presentation of something the player owns,
				# not the transaction itself, so quitting before opening it cannot cost
				# them the car.
				pending_car_reveal_instance_id = int(won_car.get("instance_id", -1))
				car_reward = prize_car_id
				# Always NEW: the duplicate guard above means a car only ever arrives here
				# the first time the player wins it.
				car_reward_is_new = true
				car_rewarded.emit(prize_car_id)
		if opening_first:
			# Arrive on the MAP, not the garage — the reveal is the point of this run.
			return_to_map = true
			# Mark the opening rally itself as already SEEN, so the arrival parade
			# announces its NEIGHBOURS rather than replaying the rally the player has
			# this second finished driving. Without this it would be first in the queue,
			# and the map's opening beat would be news the player already has.
			Save.mark_rally_revealed(rally_id, false)
		Save.save()

	var result := {
		"placed": placed,
		"completed": record_completion,
		"combined_ms": combined,
		"dnf": _dnf,
		"rally_id": String(_rally.get("id", "")),
		"rally_name": String(_rally.get("name", "")),
		# The owned-car instance the player just drove — the podium's upgrade reveal
		# offers to fit each won part straight onto it (features/reward-system.md).
		"car_instance_id": _car_instance_id,
		# Full ranked field for the standings overlay (built before _reset clears it).
		# Carries each entrant's car_id too, so the podium can spawn the top-3 cars.
		"standings": RallyLibrary.build_standings(_opponent_field, combined, _dnf, "You",
			_player_car_name(), _car_model_id, _player_engine_id()),
		# The upgrade a first-won SPECIAL unlocked: {item_id, granted:[ids, headline first]}
		# or {} for an ordinary rally / a re-win / a special that gates nothing. The podium
		# reveals it as its own stage; `granted` is empty when the driven car already had it.
		"special_unlock": special_unlock,
		# The stars beat (podium Stage.STARS): `star_rating` is what this rally is worth at
		# the player's best-ever placement (the gold star count), `stars_gained` is what the
		# ledger actually moved by. They diverge on a re-win, and showing only the rating
		# would tell the player they won stars when the balance did not change.
		"star_rating": star_rating,
		"stars_gained": stars_gained,
		# Reward reveal data (todo/menus.md): per-event upgrades + the top-3 car.
		"upgrades": _upgrades_won.duplicate(),
		"car_reward": car_reward,
		"car_reward_is_new": car_reward_is_new,
		"game_won": game_won_now,
	}
	_last_result = result
	_reset_to_idle()
	rally_finished.emit(result)


# Is the rally being resolved this player's OPENING rally, on its first attempt?
#
# "Their" opening rally is the event awarding the model they chose in the starter picker
# (RallyLibrary.opening_rally_id_for) — so it is per-profile, and every other player's
# opening rally is an ordinary prize rally to this one.
#
# Must be asked BEFORE Save.complete_rally runs: it is the un-completed state that marks
# the first attempt, and complete_rally is exactly what erases it.
func _is_opening_first_attempt() -> bool:
	var rally_id := String(_rally.get("id", ""))
	if rally_id == "":
		return false
	var starter := String(Save.profile.get("starter_model_id", ""))
	if RallyLibrary.opening_rally_id_for(starter) != rally_id:
		return false
	return not Save.rally_completed(rally_id)


# A car-park "Detune to N% & Start" agreement is only for the rally being entered:
# remember the tune to put back afterwards (the garage-set value, or the 1.0
# default if the car was never tuned). Called by hq's detune confirm just before
# it applies the temporary detune; the restore happens in _reset_to_idle.
func register_detune_revert(instance_id: int, prior_frac: float) -> void:
	if instance_id < 0:
		return
	_detune_revert[instance_id] = clampf(prior_frac, 0.0, 1.0)


# Remember a car's pre-agreement drivetrain (the garage-set override, or -1) so it's
# restored when the rally ends. Called by hq's drivetrain confirm before it applies the
# temporary switch; a garage-lift choice never registers here.
func register_drivetrain_revert(instance_id: int, prior_mode: int) -> void:
	_drivetrain_revert[instance_id] = prior_mode


func _reset_to_idle() -> void:
	# The rally is over (finish, wreck or abandon): put back the engine tune the
	# car-park detune agreement temporarily overrode. Only here — never at an
	# event boundary — so the tune can't go back up mid-rally.
	for id in _detune_revert:
		Save.set_engine_detune(int(id), float(_detune_revert[id]))
	_detune_revert = {}
	# The rally is over: put back the drivetrain override the car-park agreement
	# temporarily overrode. Only here — never at an event boundary — so the
	# drivetrain can't change mid-rally.
	for id in _drivetrain_revert:
		Save.set_drivetrain_override(int(id), int(_drivetrain_revert[id]))
	_drivetrain_revert = {}
	_rally = {}
	_car_instance_id = -1
	_car_model_id = ""
	_event_index = 0
	_event_times_ms = []
	_opponent_field = []
	_dnf = false
	_upgrades_won = []
	_event_upgrade = ""
	_set_phase(Phase.IDLE)


func _set_phase(p: int) -> void:
	_phase = p
	phase_changed.emit(p)


# Per-event track results for the opponent field, derived by generating each event's
# seeded track (deterministic for the seed). Only used in real play; tests pass
# skip_track_gen=true to start_rally so no track generation happens.
func _generate_event_tracks(rally: Dictionary) -> Array:
	var results: Array = []
	for stage_event in rally.get("events", []):
		# Resolve each event's own canonical config (previously this used the shared
		# Config.data WITHOUT per-event overrides, so terrain-override events desynced
		# from the run scene). Now it matches world.gd + the lockfile exactly, and the
		# rival times come from the committed cache (falling back to live on a miss).
		# Seat the rally's region the same way current_event() does, so an event that
		# authors no water_level resolves against the SAME region here as it does in
		# the run scene (see TrackGenParams.resolve_water_level).
		var event: Dictionary = stage_event.duplicate()
		event["region"] = rally.get("region", "")
		var cfg := canonical_event_config(event)
		var params := TrackGenParams.for_event(event, cfg)
		var result := await TrackGenerator.generate_cached(params, cfg)
		results.append(result)
	return results


# Reload the run scene for `event`. The load hides under the menus fly-through/fade
# (todo/menus.md). The event's track parameters are NOT written here: world.gd._ready
# pulls them via DrivingContext.apply_stage_config from whichever session is active,
# so scene entry has no ordering dependency on a producer remembering to seat them.
func _load_event_scene(_event: Dictionary) -> void:
	get_tree().change_scene_to_file("res://main.tscn")


# Write an event's track parameters into `cfg`. Extracted from _load_event_scene
# as a pure (scene-free) seam so the fallback semantics can be tested directly.
#
# Fields an event may OMIT fall back to the AUTHORED baseline (the pristine cached
# .tres — Config.data is a duplicate of it), NOT the current cfg value. Config.data
# is a persistent session working copy that's never reset between events, so a
# cfg-value fallback would let one event's override leak into a later event that
# omits the key. `base` pins every omitted field to its global default.
static func apply_event_config(cfg: GameConfig, event: Dictionary) -> void:
	var base: GameConfig = load(Config.CONFIG_PATH)
	cfg.track_seed = int(event.get("seed", base.track_seed))
	cfg.track_turn_count = int(event.get("turn_count", base.track_turn_count))
	cfg.track_straightness = RallyLibrary.event_straightness(event)
	cfg.track_width = RallyLibrary.event_width(event)
	cfg.track_forestiness = RallyLibrary.event_forestiness(event)
	cfg.track_tarmac_fraction = RallyLibrary.event_tarmac_fraction(event)
	cfg.weather = RallyLibrary.event_weather(event)   # WEATHER_DRY / WEATHER_RAIN; see features/weather.md
	cfg.cliff_amount = RallyLibrary.event_cliffiness(event)   # [0,1], scales cliff_max_height_m
	cfg.water_enabled = bool(event.get("water_enabled", base.water_enabled))
	# event -> event's region (if the caller seated one, see current_event() /
	# _generate_event_tracks) -> the authored baseline. See TrackGenParams.resolve_water_level.
	cfg.track_water_level_m = TrackGenParams.resolve_water_level(event, base.track_water_level_m)
	# Per-region HANDLING overrides (features/snow-region.md). The snow region drops
	# every surface's grip and adds deep snow at the roadside; every other region
	# authors neither, so these resolve to the authored baseline and a zero deep-snow
	# block — an exact no-op. Read off the event's own region, which the caller already
	# seated for resolve_water_level above, so no signature change was needed.
	#
	# Note the grip is seated onto the SAME live fields the lap-time model reads
	# (LapTimeModel._surface_grip), so the rival field scales with the player
	# automatically: snow is a variety lever, not a difficulty one. CarPerformance is
	# unaffected — it benchmarks at a frozen mu, so ratings cannot drift.
	var region_id := String(event.get("region", ""))
	var sgrip := RegionLibrary.surface_grip_of(base, region_id)
	cfg.grass_grip = float(sgrip.get("grass", base.grass_grip))
	cfg.gravel_grip = float(sgrip.get("gravel", base.gravel_grip))
	cfg.tarmac_grip = float(sgrip.get("tarmac", base.tarmac_grip))
	var deep_snow := RegionLibrary.deep_snow_of(base, region_id)
	cfg.deep_snow_drag = float(deep_snow.get("drag", 0.0))
	cfg.deep_snow_depth_m = float(deep_snow.get("depth", 0.0))
	# Frozen lakes: 0.0 means liquid, which is every region but the Alps, so the lake
	# stays the soft drag hazard it has always been unless a region says otherwise.
	cfg.frozen_water_grip = float(
		RegionLibrary.frozen_water_of(base, region_id).get("grip", 0.0))
	# Per-event terrain hill shape: any of the 3 Perlin layers' wavelength/amplitude
	# may be overridden; omitted ones use the authored global default (features/terrain.md).
	cfg.terrain_layer1_wavelength = float(event.get("terrain_layer1_wavelength", base.terrain_layer1_wavelength))
	cfg.terrain_layer1_amplitude = float(event.get("terrain_layer1_amplitude", base.terrain_layer1_amplitude))
	cfg.terrain_layer2_wavelength = float(event.get("terrain_layer2_wavelength", base.terrain_layer2_wavelength))
	cfg.terrain_layer2_amplitude = float(event.get("terrain_layer2_amplitude", base.terrain_layer2_amplitude))
	cfg.terrain_layer3_wavelength = float(event.get("terrain_layer3_wavelength", base.terrain_layer3_wavelength))
	cfg.terrain_layer3_amplitude = float(event.get("terrain_layer3_amplitude", base.terrain_layer3_amplitude))


# The canonical, event-resolved config for track generation: a fresh duplicate of
# the authored base with this event's overrides applied. Every generation site (the
# lockfile generator, target-time derivation, the run scene) must resolve params
# from THIS so their cache keys match. Standalone (no shared Config.data mutation).
# Instance method (called via the RallySession autoload) — apply_event_config stays
# static so it can be unit-tested scene-free.
func canonical_event_config(event: Dictionary) -> GameConfig:
	var cfg := (load(Config.CONFIG_PATH) as GameConfig).duplicate() as GameConfig
	apply_event_config(cfg, event)
	return cfg


# Show the between-event standings interstitial; its Continue calls
# continue_to_next_event() to load the next event.
func _load_standings_scene() -> void:
	if standings_overlay_host:
		return
	get_tree().change_scene_to_file("res://standings.tscn")

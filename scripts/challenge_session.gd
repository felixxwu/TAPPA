extends Node
# Autoload "ChallengeSession" — the Daily/Weekly/Monthly Rally Challenge's own
# small state machine, parallel to RallySession rather than a reuse of it (a
# challenge has no rival/OpponentCache, no special/star unlock, no
# Save.complete_rally bookkeeping). See
# docs/superpowers/specs/2026-07-31-rally-challenge-design.md §3-4-6 and
# features/rally-challenge.md.
#
# Mirrors RallySession's shape for the two call sites world.gd/GlobalStandings
# need to branch on: report_event_result / take_pending_repair, and a small
# read surface (is_active/car_instance_id/events_completed/...). Every stage is
# driven by the SAME StageManager/TrackProgress/etc. as a normal rally — this
# autoload only decides what happens BETWEEN stages.

signal standings_ready(stage_index: int)
# The run has resumed into stage `stage_index` (0-based) — mirrors
# RallySession.event_started, and is emitted whether or not the scene load is
# enabled so the advance is observable with auto_load_scenes off.
signal stage_started(stage_index: int)
signal run_finished(result: Dictionary)

# Test seam mirroring RallySession.auto_load_scenes — tests drive
# report_event_result directly with no scene loads.
var auto_load_scenes := true

var _active := false
# A stage is currently being DRIVEN. RallySession's Phase.RUNNING gate, carried
# over (todo/challenge-career-reuse-drift.md item 8): the standings interstitial
# keeps the run world and $Car alive with begin_replay running, so a `wrecked`
# emission in that window would otherwise DNF a run that is already finished with
# the stage. Set by start/resume/continue_to_next_stage, cleared the moment a
# result or a wreck is reported.
var _stage_running := false
var _period_key := ""
var _kind := ""
var _stage_count := 0
var _stages: Array = []
var _car_instance_id := -1
var _stage_index := 0          # stages completed so far
var _stage_times_ms: Array = []
var _dnf := false
var _pending_repair: Dictionary = {}
var _stage_upgrade := ""
var _last_result: Dictionary = {}


# --- Read surface --------------------------------------------------------------

func is_active() -> bool:
	return _active


func car_instance_id() -> int:
	return _car_instance_id


func period_key() -> String:
	return _period_key


func kind() -> String:
	return _kind


func stage_count() -> int:
	return _stage_count


# Stages COMPLETED so far (0 before the first, stage_count once the run has
# finished) — mirrors RallySession.events_completed().
func events_completed() -> int:
	return _stage_index


# The per-stage reward drawn by the stage that just finished ("" on the final
# stage, which draws none, and before any stage completes) — mirrors
# RallySession.current_event_upgrade(), and is what the standings interstitial
# reveals. Exposed as a getter because the interstitial does not exist yet when
# report_event_result runs (the scene is loaded afterwards), so it can only
# READ the state.
func stage_upgrade() -> String:
	return _stage_upgrade


func stage_times_ms() -> Array:
	return _stage_times_ms.duplicate()


func cumulative_ms() -> int:
	var total := 0
	for t in _stage_times_ms:
		total += int(t)
	return total


func dnf() -> bool:
	return _dnf


func last_result() -> Dictionary:
	return _last_result


# TrackGenParams-shaped params for the CURRENT stage (events_completed()'s
# index into the period's rolled stage list), or {} once the run is over.
func current_stage_params() -> Dictionary:
	if _stage_index < 0 or _stage_index >= _stages.size():
		return {}
	return _stages[_stage_index]


# NOTE: there is deliberately no apply_stage_config here. A stage's rolled track
# parameters reach the live config in exactly ONE place — world.gd._ready calls
# DrivingContext.apply_stage_config, which pulls current_stage_params() from
# whichever session is active and forwards it to RallySession.apply_event_config.
# A challenge stage dict is TrackGenParams-shaped by construction
# (ChallengeLibrary.stages_for authors exactly the fields a RALLIES event does),
# so that shared writer's "omitted fields fall back to the AUTHORED baseline,
# never the live cfg" semantics apply field for field.


# --- Period / eligibility (pure, no Save dependency — testable with a
# synthetic profile) --------------------------------------------------------

# The stored run in `profile`, or {} if none or if it belongs to a period that
# has since rolled over (a stale run is never resumable — §3: "the run is
# discarded locally, no further posts"). Pure read.
static func resumable_run(profile: Dictionary, unix_time: int) -> Dictionary:
	var run: Dictionary = profile.get("challenge_run", {})
	if run.is_empty():
		return {}
	var current := ChallengeLibrary.current_period(String(run.get("kind", "")), unix_time)
	if current.is_empty() or String(current.get("key", "")) != String(run.get("period_key", "")):
		return {}
	return run


# True when `profile` holds a challenge_run whose period has rolled over (so it
# should be silently discarded, per §3) — the inverse of resumable_run's
# "still current" check, but distinguishing "no run at all" from "stale run".
static func has_stale_run(profile: Dictionary, unix_time: int) -> bool:
	var run: Dictionary = profile.get("challenge_run", {})
	if run.is_empty():
		return false
	return resumable_run(profile, unix_time).is_empty()


# Owned cars eligible for `kind_str` at `unix_time`: current effective p/w
# (installed upgrades + current detune) at/under the period's rolled ceiling —
# OR reachable by lowering detune, same as a career rally's over-the-cap car
# (RallyLibrary.qualifying_detune / hq_carpark.gd._qualifying_detune_for): a car isn't
# excluded just because its slider happens to sit above what the ceiling
# needs right now, it shows up "eligible with a note" per spec §2, and the
# player tunes down before starting (Start still re-checks the CURRENT p/w —
# eligible_cars only answers "is there a path in for this car", not "is it
# ready to start AS TUNED"). Recomputed live, never cached at grant time.
static func eligible_cars(kind_str: String, profile: Dictionary, unix_time: int) -> Array:
	return classify_cars(kind_str, profile, unix_time)["eligible"]


# The period's p/w ceiling AS THE PLAYER SEES IT — hp/tonne, rounded to a whole
# number, which is how every challenge label prints it ("%d hp/t max"). Eligibility
# is judged against THIS, never the raw float: CarLibrary.power_to_weight_hp_tonne is
# itself rounded, so comparing a rounded figure to an unrounded ceiling would reject a
# car whose displayed hp/tonne exactly equals the displayed cap. Same rule (and same
# reason) as hq_carpark.gd._qualifying_detune_for and RallyLibrary.ineligibility_reason,
# which round `pw_max` before comparing.
# classify_car verdicts. READY/NEEDS_TUNE double as the classify_cars bucket keys.
const READY := "ready"
const NEEDS_TUNE := "needs_tune"
const EXCLUDED := "excluded"


static func displayed_ceiling(kind_str: String, unix_time: int) -> int:
	return roundi(ChallengeLibrary.current_ceiling(kind_str, unix_time))


# The ONE place the challenge eligibility rule lives. Classifies every owned car in
# `profile` against `kind_str`'s current period and returns
#   {"ceiling": int, "eligible": Array, "ready": Array, "needs_tune": Array,
#    "detune": {instance_id: qualifying absolute detune fraction}}
# `ready` = at/under the displayed ceiling as currently tuned; `needs_tune` = over it
# but reachable by lowering the engine detune; `eligible` = both, in the profile's own
# car order (what the car park parks). The UI reads these lists rather than re-deriving
# the comparison, so the "compare against the DISPLAYED ceiling" rule can't drift.
static func classify_cars(kind_str: String, profile: Dictionary, unix_time: int) -> Dictionary:
	var out := {"ceiling": 0, "eligible": [], "ready": [], "needs_tune": [], "detune": {}}
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	if period.is_empty():
		return out
	var raw_ceiling := ChallengeLibrary.ceiling_for(String(period["key"]))
	out["ceiling"] = roundi(raw_ceiling)
	for car in profile.get(Save.KEY_CARS, []):
		var entry := CarLibrary.for_owned(car)
		if entry.is_empty():
			continue
		var verdict := classify_car(raw_ceiling, car, entry)
		var state := String(verdict["state"])
		if state == EXCLUDED:
			continue
		out[state].append(car)
		out["eligible"].append(car)
		if state == NEEDS_TUNE:
			out["detune"][int(car.get("instance_id", -1))] = float(verdict["detune"])
	return out


# classify_cars' per-car verdict, and the ONE implementation of the challenge
# eligibility comparison: {"state": READY|NEEDS_TUNE|EXCLUDED, "detune": frac}.
# `raw_ceiling` is the period's rolled hp/tonne as ChallengeLibrary returns it; it is
# ROUNDED here before anything is compared against it (see displayed_ceiling), so the
# whole challenge path judges a car against the same number the screen prints.
static func classify_car(raw_ceiling: float, owned: Dictionary, entry: Dictionary) -> Dictionary:
	var ceiling := float(roundi(raw_ceiling))
	var meta := UpgradeLibrary.effective_meta(owned, entry)
	if CarLibrary.power_to_weight_hp_tonne(meta) <= ceiling:
		return {"state": READY, "detune": -1.0}
	var frac := qualifying_detune_for({"restriction": {"pw_max": ceiling}}, owned, entry)
	if frac > 0.0:
		return {"state": NEEDS_TUNE, "detune": frac}
	return {"state": EXCLUDED, "detune": -1.0}


# The largest engine-detune fraction (an ABSOLUTE slider setting, 0..1) at
# which `owned` would qualify under `synthetic_rally`'s `{"restriction": {
# "pw_max": ceiling}}` shape, or -1.0 if no detune helps. Judged at the car's
# FULL power (detune 1.0), mirroring hq_carpark.gd._full_power_meta / hq.gd._detuned_to_full —
# duplicated here rather than reused since ChallengeSession stays a pure,
# Save-free static surface (testable with a synthetic profile, per CLAUDE.md).
static func qualifying_detune_for(synthetic_rally: Dictionary, owned: Dictionary, entry: Dictionary) -> float:
	var full := owned.duplicate(true)
	var tuning: Dictionary = (full.get("tuning", {}) as Dictionary).duplicate()
	tuning["engine_detune"] = 1.0
	full["tuning"] = tuning
	var full_meta := UpgradeLibrary.effective_meta(full, entry)
	return RallyLibrary.qualifying_detune(synthetic_rally, full_meta)


# --- Lifecycle -----------------------------------------------------------------

# Start a fresh run for `kind_str` with `owned_car` (should be one of
# eligible_cars' results — not re-checked here, the entry screen is the gate).
# Fails harmlessly (false, no state change) if a run is already active. Rolls
# this period's stages from ChallengeLibrary and persists immediately (stage
# 0) so quitting right after starting still resumes correctly.
func start(kind_str: String, owned_car: Dictionary, unix_time: int) -> bool:
	if _active:
		return false
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	if period.is_empty():
		return false
	# One attempt per period. A finished run — completed OR DNF'd — is terminal until
	# the period rolls over (§3's no-retry rule); without this the run record is
	# cleared on finish, so the entry screen would re-offer Start and a player could
	# post a second time for the same period.
	if not period_outcome(Save.profile, String(period["key"])).is_empty():
		return false
	var car_id := int(owned_car.get("instance_id", -1))
	if car_id < 0:
		return false
	_period_key = String(period["key"])
	_kind = kind_str
	_stage_count = int(period["stage_count"])
	_stages = ChallengeLibrary.stages_for(_period_key, _stage_count)
	_car_instance_id = car_id
	_stage_index = 0
	_stage_times_ms = []
	_dnf = false
	_pending_repair = {}
	_stage_upgrade = ""
	_last_result = {}
	_active = true
	_stage_running = true
	# A challenge stage fields its own car and authors no region, so it supersedes
	# any pending free-roam pick exactly as start_rally does — otherwise a
	# free-roam drive quit at the pause menu leaves free_roam_region_id set and the
	# stage wears that region's sky/ground/tree mix (item 9).
	RallySession.clear_free_roam_handoff()
	_persist()
	return true


# Resume the run stored in Save.profile["challenge_run"], if any and still
# current. Returns true iff a run is now active (whether it was already active
# or freshly resumed).
func resume(unix_time: int) -> bool:
	if _active:
		return true
	var run := resumable_run(Save.profile, unix_time)
	if run.is_empty():
		return false
	_period_key = String(run["period_key"])
	_kind = String(run["kind"])
	var period := ChallengeLibrary.current_period(_kind, unix_time)
	_stage_count = int(period.get("stage_count", 0))
	_stages = ChallengeLibrary.stages_for(_period_key, _stage_count)
	_car_instance_id = int(run.get("car_instance_id", -1))
	_stage_index = int(run.get("stage_index", 0))
	_stage_times_ms = (run.get("stage_times_ms", []) as Array).duplicate()
	_dnf = bool(run.get("dnf", false))
	_pending_repair = {}
	_stage_upgrade = ""
	_last_result = {}
	_active = true
	_stage_running = true
	RallySession.clear_free_roam_handoff()  # same supersede rule as start() (item 9)
	return true


# Discard a stale stored run (period rolled over) with no further posting —
# §3: "the run is discarded locally (no further posts)". No-op if the stored
# run is empty or still current.
func discard_stale_run(unix_time: int) -> void:
	if not has_stale_run(Save.profile, unix_time):
		return
	Save.clear_challenge_run()


func _persist() -> void:
	Save.set_challenge_run({
		"period_key": _period_key, "kind": _kind, "car_instance_id": _car_instance_id,
		"stage_index": _stage_index, "stage_times_ms": _stage_times_ms.duplicate(), "dnf": _dnf,
	})


func _clear_persisted() -> void:
	Save.clear_challenge_run()


# --- Terminal per-period outcome (one attempt per period) ------------------------

# The finished outcome for `period_key` in `profile`, or {} if that period has not
# been played to an end. Pure read, mirroring resumable_run's shape.
static func period_outcome(profile: Dictionary, period_key_str: String) -> Dictionary:
	var results: Dictionary = profile.get("challenge_results", {})
	return results.get(period_key_str, {})


# True when `kind_str`'s CURRENT period has already been finished — completed or
# DNF'd. Both are terminal: a challenge is one attempt per period, and a wreck ends
# the run with no retry (§3), so neither can be started again until the period rolls.
static func is_period_finished(kind_str: String, profile: Dictionary, unix_time: int) -> bool:
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	if period.is_empty():
		return false
	return not period_outcome(profile, String(period["key"])).is_empty()


# Record this run's terminal outcome against its period, so it can't be re-run.
# Also PRUNES every stored period that is no longer live: the map would otherwise
# gain an entry every day forever. Only the three current period keys can survive,
# so it holds at most three records.
func _record_outcome(unix_time: int) -> void:
	var results: Dictionary = Save.profile.get("challenge_results", {})
	results[_period_key] = {
		"kind": _kind, "dnf": _dnf, "cumulative_ms": cumulative_ms(),
	}
	var live := {}
	for k in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		var period := ChallengeLibrary.current_period(k, unix_time)
		if not period.is_empty():
			live[String(period["key"])] = true
	var pruned := {}
	for key in results:
		if live.has(key):
			pruned[key] = results[key]
	Save.set_challenge_results(pruned)


# --- Per-stage flow ------------------------------------------------------------

# Mirrors RallySession.report_event_result: append the stage time, persist
# damage, draw the per-stage reward on a non-final stage (car-bound, installed
# DISABLED, exactly like a normal rally event — §6), persist challenge_run,
# then end the run on the final stage. Does its OWN local bookkeeping only —
# it does not talk to the cloud board itself; that happens in the interstitial
# page (mirroring how GlobalStandings, not RallySession, owns stage_times
# posting) via the checkpoint fetch/post surface in Cloud.challenge_leaderboard.
func report_event_result(elapsed_ms: int, hp_lost: float = 0.0) -> void:
	if not _active or not _stage_running:
		return
	_stage_running = false
	_stage_times_ms.append(elapsed_ms)
	if _car_instance_id >= 0 and hp_lost > 0.0:
		Save.apply_damage(_car_instance_id, hp_lost)
	_stage_index += 1
	_stage_upgrade = ""
	var is_final := _stage_index >= _stage_count
	if not is_final:
		# The draw can legitimately come up empty for a maxed-out car (NO_REWARD) — then
		# nothing is granted and _stage_upgrade stays "" so no reveal fires.
		_stage_upgrade = RewardSystem.draw_and_grant_upgrade(_car_instance_id, Save.profile)
	Save.save()
	# The same partial pit repair a career rally gets — between stages via
	# _pending_repair (the run scene shows the popup on boot), and on the FINAL
	# stage SILENTLY, discarding the summary. That final repair mirrors
	# RallySession._resolve_results exactly (item 5): the last stage's damage would
	# otherwise never be patched up, since there is no next stage to cushion for,
	# and there is no scene left to show a popup in. Both go through the ONE shared
	# writer so the fractions can never drift apart.
	if is_final:
		@warning_ignore("return_value_discarded")
		RallySession.apply_field_repair_to(_car_instance_id)
	else:
		_pending_repair = RallySession.apply_field_repair_to(_car_instance_id)
	_persist()
	# ORDER MATTERS, and this is the fix for item 2. standings_ready is emitted
	# while the run is STILL ACTIVE, so every consumer that branches on
	# is_active() — world.gd._present_standings_overlay, and standings.gd, which
	# latches the session at construction — resolves against the CHALLENGE, not the
	# idle career session. Emitting after _finish_locally() meant a Daily (whose
	# only stage is also its final stage) rendered the career leaderboard, offered a
	# dead Continue, and never posted its time to the challenge board at all.
	# _finish_locally() then follows, so world.gd's run_finished handler sees an
	# overlay that already exists and can wait for the player to dismiss it.
	standings_ready.emit(_stage_index)
	if is_final:
		_finish_locally()


# --- Local standings (a field of one) ------------------------------------------
#
# A challenge has NO rival field (spec §3), so both leaderboards the standings
# interstitial stacks degrade to the player's own row. Rather than inventing a
# "no standings" UI state, these feed RallyLibrary.build_standings the SAME way
# RallySession does with an empty field — the exact rendering a rally with zero
# rivals would produce — so standings.gd's section builder is reused verbatim.

# The just-finished stage's time alone, ranked. Empty before any stage completes.
func current_event_standings() -> Array:
	var idx := _stage_times_ms.size() - 1
	if idx < 0:
		return []
	return RallyLibrary.build_standings([], int(_stage_times_ms[idx]), _dnf, "You",
		_player_car_name(), _player_car_model_id())


# The cumulative time over the stages completed so far, ranked.
func current_standings() -> Array:
	return RallyLibrary.build_standings([], cumulative_ms(), _dnf, "You",
		_player_car_name(), _player_car_model_id())


func _player_car_model_id() -> String:
	return String(Save.get_car(_car_instance_id).get("model_id", ""))


# Mirrors RallySession._player_car_name — "" when nothing resolves (headless).
func _player_car_name() -> String:
	var owned := Save.get_car(_car_instance_id)
	return EngineSwap.display_name(CarLibrary.for_owned(owned), owned)


# --- Stage-to-stage advancement -------------------------------------------------

# Resume from the standings interstitial into the NEXT stage — the challenge's
# counterpart to RallySession.continue_to_next_event(), and standings.gd's single
# exit when a challenge is the active session.
#
# There is deliberately no "or resolve results" arm: report_event_result already
# ends the run on the FINAL stage (_finish_locally), so by the time a final
# stage's interstitial could ask, `_active` is false and this is a no-op. The
# interstitial detects that and emits Standings.run_completed instead, which
# world.gd's parked run_finished handler resumes on — so the run's end is still
# owned by that handler, but the PLAYER decides when it happens.
#
# _stage_index was already advanced (and the field repair already applied +
# parked in _pending_repair) by report_event_result, so the whole of "enter the
# next stage" is re-entering the driving scene: world.gd._ready seats the new
# stage's config (via DrivingContext.apply_stage_config) and reads
# current_stage_params() / take_pending_repair() on boot, exactly as it did for
# stage 1. This mirrors RallySession._load_event_scene, which is likewise a bare
# scene change.
func continue_to_next_stage() -> void:
	if not _active:
		return
	_stage_running = true
	stage_started.emit(_stage_index)
	if auto_load_scenes:
		get_tree().change_scene_to_file("res://main.tscn")


# One-shot, cleared on read — mirrors RallySession.take_pending_repair().
func take_pending_repair() -> Dictionary:
	var r := _pending_repair
	_pending_repair = {}
	return r


func _finish_locally() -> void:
	_last_result = {
		"period_key": _period_key, "kind": _kind, "car_instance_id": _car_instance_id,
		"stage_times_ms": _stage_times_ms.duplicate(), "cumulative_ms": cumulative_ms(),
		"dnf": _dnf, "completed": not _dnf,
	}
	_active = false
	_stage_running = false
	_record_outcome(int(Time.get_unix_time_from_system()))
	_clear_persisted()
	run_finished.emit(_last_result)


# A wreck ends the whole run immediately — no-retry, matching the rest of the
# game (§3). Whatever stage_times_ms were already posted stand.
func report_wreck() -> void:
	# Same gate RallySession.report_wreck applies (_phase == RUNNING, item 8): the
	# standings interstitial keeps $Car alive replaying the run, and a `wrecked`
	# emission from that replay must not DNF a stage the player already finished.
	if not _stage_running:
		return
	_end_as_dnf()


# Leave the run WITHOUT ending it (item 12). ONLY a wreck DNFs a challenge —
# everything else that needs the run to stop being active (the pause menu's
# "Quit to HQ", starting a dev benchmark) pauses it instead. Clears _active /
# _stage_running so nothing keeps driving the run, leaves challenge_run PERSISTED
# at its current stage_index / stage_times_ms / car_instance_id, and records NO
# outcome — so the entry screen's Resume path picks it straight back up and the
# period is not spent. The in-progress stage's partial time is discarded; the
# player re-drives that stage on resume, which is how resume has always worked.
#
# Deliberately does NOT emit run_finished: that signal means "this run is over"
# and world.gd's handler posts a DNF to the board on it. The caller owns the
# transition back to the HQ.
func pause_run() -> void:
	if not _active:
		return
	_active = false
	_stage_running = false
	_pending_repair = {}
	_stage_upgrade = ""
	_persist()


# DEPRECATED alias for pause_run(). Every remaining caller wants "stop being the
# active session", never "DNF" — the terminal path is now reachable ONLY through
# report_wreck(), which is what makes the "only a wreck DNFs a challenge" rule
# unmissable. Kept solely so existing `if is_active(): abandon()` test teardowns
# keep compiling; new code should call pause_run().
func abandon() -> void:
	pause_run()


func _end_as_dnf() -> void:
	if not _active:
		return
	_stage_running = false
	_dnf = true
	_last_result = {
		"period_key": _period_key, "kind": _kind, "car_instance_id": _car_instance_id,
		"stage_times_ms": _stage_times_ms.duplicate(), "cumulative_ms": cumulative_ms(),
		"dnf": true, "completed": false,
	}
	_active = false
	_record_outcome(int(Time.get_unix_time_from_system()))
	_clear_persisted()
	run_finished.emit(_last_result)


# --- Completion reward (placement-gated, §6) -----------------------------------

# Per-kind completion reward table — TUNABLE, change the numbers here.
#
# `boxes` is a count of the mystery-box consumable. The car draw that used to sit here is
# GONE: cars are bought with stars at the present box now, so a challenge pays STARS
# instead (todo/star-economy.md, change 5). Stars are credited by placement through the
# same RallyLibrary.stars_for_placement curve career rallies use, so a star earned in a
# challenge is worth exactly what one earned in a rally is.
#
# One attempt per period and the outcome is terminal, so a period cannot be re-farmed —
# but unlike career stars this income IS renewable over real time, which is deliberate:
# it is the only star source that keeps flowing once the roster is complete.
# The single source of truth for "how much of the board counts as PLACING" — the reward
# RULE below (`rank > ceili(float(total) * CHALLENGE_TOP_FRACTION)`) and the win-condition
# label the HQ entry screen shows (hq_challenge.gd -> _CHALLENGE_WIN_CONDITION, formatted
# from this) both read it, so the rule and its label cannot silently disagree. It lives
# here as a const rather than in game_config.tres because it is a REWARD RULE, not a look
# or feel tunable: moving it changes who gets paid.
const CHALLENGE_TOP_FRACTION := 0.5

const _COMPLETION_REWARD := {
	ChallengeLibrary.DAILY: {"boxes": 2},
	ChallengeLibrary.WEEKLY: {"boxes": 3},
	ChallengeLibrary.MONTHLY: {"boxes": 4},
}


# Finishing every stage (no DNF) is eligible for one placement-gated reward:
# top ceil(total_entries/2) of that period's board, checked AGAINST THE BOARD
# AS IT STANDS AT THIS MOMENT (an early finisher is compared to a smaller
# field — accepted as a deliberate generous quirk, not a bug, per spec §6).
# Requires a cloud rank to exist at all — skipped entirely if signed out /
# no username / the final checkpoint never posted (all read the same way:
# Cloud.challenge_leaderboard.fetch_final_rank returning not-ok). Grants via
# the same RewardSystem the per-stage draws use and returns what (if
# anything) was granted.
func try_grant_completion_reward(result: Dictionary) -> Dictionary:
	if not bool(result.get("completed", false)):
		return {}  # DNF gets nothing from this path (§6)
	if Cloud == null or Cloud.challenge_leaderboard == null:
		return {}
	var kind_str := String(result.get("kind", ""))
	var stage_count_val: int = int(ChallengeLibrary.STAGE_COUNTS.get(kind_str, 0))
	var rank_info := await Cloud.challenge_leaderboard.fetch_final_rank(
		String(result.get("period_key", "")), stage_count_val)
	if not bool(rank_info.get("ok", false)):
		return {}  # no cloud rank available — same graceful skip as a signed-out finish
	var rank := int(rank_info["rank"])
	var total := int(rank_info["total_entries"])
	if rank > ceili(float(total) * CHALLENGE_TOP_FRACTION):
		return {"placed": false, "rank": rank, "total_entries": total}
	var reward: Dictionary = _COMPLETION_REWARD.get(kind_str, {})
	if reward.is_empty():
		return {"placed": true, "rank": rank, "total_entries": total}
	var boxes := int(reward.get("boxes", 0))
	if boxes > 0:
		Save.add_item(UpgradeLibrary.MYSTERY_BOX_ID, boxes)
	# Stars by placement, on the SAME curve as a career rally (1st/2nd/3rd -> 3/2/1). Note
	# "placed" here is the top HALF of the board, which is far more lenient than the podium
	# the star curve pays out to — so a mid-table finish legitimately banks 0 stars and walks
	# away with the boxes above. That is why the boxes are granted unconditionally.
	var stars := RallyLibrary.stars_for_placement(rank)
	if stars > 0:
		Save.award_stars(stars, false)
	return {"placed": true, "rank": rank, "total_entries": total,
		"item_id": "", "boxes": boxes, "stars": stars}

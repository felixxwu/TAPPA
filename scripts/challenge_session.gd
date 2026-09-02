extends Node
# Autoload "ChallengeSession" — the Daily/Weekly/Monthly Rally Challenge's own
# small state machine, parallel to RallySession rather than a reuse of it (a
# challenge has no rival field, no special/star unlock, no
# Save.record_podium_rally bookkeeping). See
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
# over (todo/challenge-career-reuse-drift.md item 8): the standings interstitial keeps the
# run world and $Car alive with begin_replay running, so nothing from that replay may be
# taken as an event on a stage the player already finished. Set by
# start/resume/continue_to_next_stage, cleared the moment a result is reported.
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
# whichever session is active and forwards it to StageConfig.apply_event_config.
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


# Owned cars eligible for `kind_str` at `unix_time`: cars whose CURRENT build rates
# at/under the period's rolled rating ceiling. There is no detune escape — an
# over-ceiling build is plainly ineligible and the player picks or builds another car
# (the rating design doc's D5). Recomputed live, never cached at grant time.
static func eligible_cars(kind_str: String, profile: Dictionary, unix_time: int) -> Array:
	return classify_cars(kind_str, profile, unix_time)["eligible"]


# classify_car verdicts. READY doubles as the classify_cars bucket key.
const READY := "ready"
const EXCLUDED := "excluded"


# The period's rating ceiling AS THE PLAYER SEES IT — rounded to a whole number, which
# is how every challenge label prints it. Eligibility is judged against THIS, never the
# raw float: CarPerformance.rating is itself an int, so comparing it to an unrounded
# ceiling would reject a car whose displayed rating exactly equals the displayed cap.
static func displayed_ceiling(kind_str: String, unix_time: int) -> int:
	return roundi(ChallengeLibrary.current_ceiling(kind_str, unix_time))


# The ONE place the challenge eligibility rule lives. Classifies every owned car in
# `profile` against `kind_str`'s current period and returns
#   {"ceiling": int, "eligible": Array, "ready": Array}
# `ready` and `eligible` hold the same cars (in the profile's own car order, which is
# what the car park parks) — the two keys are kept distinct because the UI reads
# `eligible` as "what can enter" and `ready` as "what to name on the screen". The UI
# reads these lists rather than re-deriving the comparison, so the "compare against the
# DISPLAYED ceiling" rule can't drift.
static func classify_cars(kind_str: String, profile: Dictionary, unix_time: int) -> Dictionary:
	var out := {"ceiling": 0, "eligible": [], "ready": []}
	var period := ChallengeLibrary.current_period(kind_str, unix_time)
	if period.is_empty():
		return out
	var raw_ceiling := ChallengeLibrary.ceiling_for(String(period["key"]))
	out["ceiling"] = roundi(raw_ceiling)
	for car in profile.get(Save.KEY_CARS, []):
		var entry := CarLibrary.for_owned(car)
		if entry.is_empty():
			continue
		if String(classify_car(raw_ceiling, car, entry)["state"]) == EXCLUDED:
			continue
		out["ready"].append(car)
		out["eligible"].append(car)
	return out


# classify_cars' per-car verdict, and the ONE implementation of the challenge
# eligibility comparison: {"state": READY|EXCLUDED}.
#
# A plain rating comparison, deliberately NOT routed through
# RallyLibrary.ineligibility_reason: rally restrictions are purely categorical now, and
# the challenge's numeric ceiling stays on its own path rather than reintroducing a
# numeric key into the shared restriction schema. Over the ceiling means simply
# ineligible — there is no detune escape and no auto-disabling of parts (design doc D5);
# the player picks or builds another car.
#
# `raw_ceiling` is the period's rolled rating as ChallengeLibrary returns it; it is
# ROUNDED here before anything is compared against it (see displayed_ceiling), so the
# whole challenge path judges a car against the same number the screen prints.
static func classify_car(raw_ceiling: float, owned: Dictionary, entry: Dictionary) -> Dictionary:
	# merged_meta, not effective_meta: the rating must see tyres and aero, which
	# effective_meta deliberately withholds (they never fed power-to-weight).
	var meta := CarPerformance.merged_meta(owned, entry)
	if CarPerformance.rating(meta) <= roundi(raw_ceiling):
		return {"state": READY}
	return {"state": EXCLUDED}


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
# DNF'd (a DNF is only reachable on a run persisted by an older build — nothing DNFs a
# challenge now). Both are terminal: a challenge is one attempt per period, so neither can
# be started again until the period rolls.
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
	var is_final := _stage_index >= _stage_count
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
		Save.apply_field_repair_to(_car_instance_id)
	else:
		_pending_repair = Save.apply_field_repair_to(_car_instance_id)
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


# --- Run-summary times ---------------------------------------------------------
#
# These were a pair of RANKED STANDINGS TABLES: a challenge has no rival field
# (spec §3), so both handed RallyLibrary.build_standings an empty field and got
# back the player's own row alone, which standings.gd then rendered as a
# one-entrant leaderboard. Nothing wants a ranking any more — there is no field to
# rank against and standings.tscn is going — so what is left is what a run summary
# actually reads: TIMES, in milliseconds, in stage order.
#
# Both return plain int lists so a summary can render "this stage" and "the run so
# far" through one code path.

# The just-finished stage's time, as a one-element list. [] before any stage
# completes (nothing has been driven yet), which is the emptiness the run summary
# branches on rather than a sentinel time.
func current_stage_times_ms() -> Array[int]:
	var out: Array[int] = []
	var idx := _stage_times_ms.size() - 1
	if idx >= 0:
		out.append(int(_stage_times_ms[idx]))
	return out


# Every completed stage's time, in stage order — the run summary's per-stage
# breakdown. [] before any stage completes; the entries sum to cumulative_ms().
#
# The typed twin of stage_times_ms(), which stays UNTYPED and unchanged because a
# resumed run's times come back out of JSON as floats and its callers (persistence,
# _finish_locally's result dict) pass them straight back through.
func run_times_ms() -> Array[int]:
	var out: Array[int] = []
	for t in _stage_times_ms:
		out.append(int(t))
	return out


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
		Scenes.change_to(get_tree(), Scenes.MAIN)


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


# Leave the run WITHOUT ending it (item 12). NOTHING DNFs a challenge run any more —
# damage can never wreck the car (features/damage.md), so every path that needs the run to
# stop being active (the pause menu's "Quit to HQ", starting a dev benchmark) pauses it. Clears _active /
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
	_persist()


# DEPRECATED alias for pause_run(). Every remaining caller wants "stop being the
# active session", never "DNF" — and since the wreck path was removed there IS no
# terminal DNF path left to reach. Kept solely so existing `if is_active(): abandon()`
# test teardowns keep compiling; new code should call pause_run().
func abandon() -> void:
	pause_run()


# --- Completion reward (placement-gated, §6) -----------------------------------

# Per-kind completion reward table — TUNABLE, change the numbers here.
#
# `stars` is a flat completion payout, and it REPLACED the mystery-box payout this table
# used to carry: boxes (and the random draw behind them) are gone, parts and cars are
# bought with stars now, so the only currency a challenge can pay in is stars. The car
# draw that used to sit here is long gone for the same reason (todo/star-economy.md,
# change 5). Ordering is deliberate — Daily < Weekly < Monthly — because a longer period
# is a scarcer, bigger prize.
#
# This flat amount is paid on TOP of the placement stars below, which are credited through
# the same RallyLibrary.stars_for_placement curve career rallies use, so a star earned in a
# challenge is worth exactly what one earned in a rally is. The flat part exists because
# "placed" here is only the top HALF of the board, far more lenient than the podium the
# star curve pays out to — without it a mid-table finish would bank nothing at all, which
# is exactly what the boxes used to cover.
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
	ChallengeLibrary.DAILY: {"stars": 2},
	ChallengeLibrary.WEEKLY: {"stars": 4},
	ChallengeLibrary.MONTHLY: {"stars": 8},
}


# Finishing every stage (no DNF) is eligible for one placement-gated reward:
# top ceil(total_entries/2) of that period's board, checked AGAINST THE BOARD
# AS IT STANDS AT THIS MOMENT (an early finisher is compared to a smaller
# field — accepted as a deliberate generous quirk, not a bug, per spec §6).
# Requires a cloud rank to exist at all — skipped entirely if signed out /
# no username / the final checkpoint never posted (all read the same way:
# Cloud.challenge_leaderboard.fetch_final_rank returning not-ok). Grants via
# the same Save star ledger a career rally uses, and returns what (if
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
	# The flat completion payout (which replaced the mystery boxes) plus the placement
	# bonus on the SAME curve as a career rally (1st/2nd/3rd -> 3/2/1). Granted as ONE
	# credit so the ledger is written once, and reported split so the card can say where
	# each part came from.
	var base_stars := int(reward.get("stars", 0))
	var placement_stars := RallyLibrary.stars_for_placement(rank)
	var stars := base_stars + placement_stars
	if stars > 0:
		Save.award_stars(stars)
	return {"placed": true, "rank": rank, "total_entries": total,
		"item_id": "", "stars": stars, "placement_stars": placement_stars}

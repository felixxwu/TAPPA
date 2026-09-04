extends Node
# Docs: features/rally-challenge.md, features/region-runs.md, features/lifetime-stats.md, features/collectables.md — update in the same change as this file.
# Tests: tests/headless/test_challenge_session.gd, tests/headless/test_region_run.gd, tests/headless/test_challenge_run_end.gd — extend in the same change.
#
# Autoload "RunSession" — the ONE session type in the game. A run is N sequential
# stages driven back to back by one car, persisted between stages and resumable.
# Generalised from `ChallengeSession` (todo/roguelike-pivot.md stage 3, item 1):
# everything that used to be challenge-specific now comes from a `RunMode` strategy
# (scripts/run_mode.gd), with two callers —
#
#   * ChallengeRunMode — the retained Daily/Weekly/Monthly Rally Challenge
#     (decision 15). No target time, no fail state, one placement-gated payout.
#   * RegionRunMode    — the roguelike region run. A fixed reference-car target per
#     stage, run-over the moment one is missed, money banked per stage clear.
#
# WHAT LIVES HERE (shared by both): the stage cursor, the banked stage times, the
# persisted run slot, the between-stage field repair, the car lock, and the terminal
# result. WHAT LIVES IN THE MODE: which stages, whether a stage ends the run, what a
# cleared stage pays, what is persisted, what a finished run records.
#
# Every stage is driven by the SAME StageManager/TrackProgress/etc. as any other
# event — this autoload only decides what happens BETWEEN stages.
#
# ONE RUN SLOT (decision 27). `Save.KEY_RUN` holds a run record of EITHER kind, so
# starting a run discards a paused run of the other kind. That keeps the car-lock
# query (`Save.is_challenge_locked` -> `DrivingContext.is_car_locked`) working with
# no discriminator.

signal standings_ready(stage_index: int)
# The run has resumed into stage `stage_index` (0-based). Emitted whether or not the
# scene load is enabled, so the advance is observable with auto_load_scenes off.
signal stage_started(stage_index: int)
signal run_finished(result: Dictionary)

# Test seam — tests drive report_event_result directly with no scene loads.
var auto_load_scenes := true

var _active := false
# A stage is currently being DRIVEN. The standings interstitial keeps the run world
# and $Car alive with begin_replay running, so nothing from that replay may be taken
# as an event on a stage the player already finished. Set by
# start/resume/continue_to_next_stage, cleared the moment a result is reported.
var _stage_running := false
var _mode: RunMode = null
var _stages: Array = []
var _car_instance_id := -1
var _stage_index := 0          # stages completed so far
var _stage_times_ms: Array = []
var _dnf := false
# The run ended because a stage's target time was missed — the roguelike run's one
# hard fail state (decision 4). Distinct from _dnf, which is the challenge's legacy
# wreck flag and is never set by anything today.
var _failed := false
var _money_earned := 0
# The current stage's target time in ms, seated by set_stage_track() once the track
# has actually been generated. 0 = no target (a challenge stage, or a track that
# failed to solve) — the fail rule can never fire on it.
var _stage_target_ms := 0
var _pending_repair: Dictionary = {}
var _last_result: Dictionary = {}
# --- The between-stage pick (todo/roguelike-pivot.md "Between stages: repair or
# boost", stage 5) ---------------------------------------------------------------
# The boosts drawn for the pick currently awaiting a choice — BoostLibrary entries,
# {"id","effect"}. Empty when no pick is outstanding (every mode that answers false
# to RunMode.offers_boost_pick, and this run's own final/failed stage).
var _pending_pick: Array = []
# True while _pending_pick is awaiting choose_repair()/choose_boost(). Blocks
# continue_to_next_stage() — the player picks exactly one before the run advances.
var _pick_awaiting := false
# This run's OWN picked boosts, in pick order — {"id","effect"}, UpgradeLibrary's
# shape. RUN-SCOPED: never written to Save's persisted car (world.gd._field_car
# merges this onto a DUPLICATED owned-car dict at fielding time), so nothing here can
# leak past the run it was picked in. Reset only by begin() (a fresh run) and
# _finish_locally() (the run just ended, win or lose) — see boosts() below.
var _boosts: Array = []


# --- Read surface --------------------------------------------------------------

func is_active() -> bool:
	return _active


func mode() -> RunMode:
	return _mode


# RunMode.CHALLENGE / RunMode.REGION, or "" when no run is active.
func mode_id() -> String:
	return _mode.mode_id() if _mode != null else ""


func car_instance_id() -> int:
	return _car_instance_id


# The challenge period key, or "" for any other kind of run.
func period_key() -> String:
	var m := _mode as ChallengeRunMode
	return m.period_key if m != null else ""


# The challenge kind (daily/weekly/monthly), or "" for any other kind of run.
func kind() -> String:
	var m := _mode as ChallengeRunMode
	return m.kind if m != null else ""


# The region id for a region run, or "" for any other kind of run.
func region_id() -> String:
	var m := _mode as RegionRunMode
	return m.region_id if m != null else ""


func stage_count() -> int:
	return _mode.stage_count() if _mode != null else 0


# Stages COMPLETED so far (0 before the first, stage_count once the run has finished).
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


# True once a missed target has ended the run.
func failed() -> bool:
	return _failed


# Money banked by this run so far. Already on the profile — banking happens at each
# stage clear (decision 36), not at run end, so a failed run keeps every penny.
func money_earned() -> int:
	return _money_earned


func last_result() -> Dictionary:
	return _last_result


# The boosts drawn for the pick currently awaiting a choice, or [] when none is
# outstanding. world.gd's between-stage interstitial reads this to decide what to
# show — the pick rows plus repair, or a bare Continue.
func pending_pick() -> Array:
	return _pending_pick.duplicate(true)


# True while a between-stage pick is drawn and unresolved (see choose_repair /
# choose_boost). continue_to_next_stage() refuses to advance while this holds.
func pick_awaiting() -> bool:
	return _pick_awaiting


# This run's picked boosts so far, in pick order — the exact shape
# UpgradeLibrary.active_effects reads off an owned car's "boosts" key. world.gd
# merges this onto the fielded car; it is never written to Save.
func boosts() -> Array:
	return _boosts.duplicate(true)


# Drop the terminal result once a screen has SHOWN it. The hub shell reads last_result()
# on boot to decide whether to open the run summary instead of the main menu, so a result
# left standing traps the player on that summary every time they return to the hub.
#
# Deliberately NOT cleared by start()/begin(): a run's outcome has to outlive the run
# object itself, because the scene change back to the hub happens after the session has
# already gone idle. Only the screen that displayed it may clear it.
func clear_last_result() -> void:
	_last_result = {}


# The current stage's target time in ms, or 0 when the run has no target. Valid only
# after set_stage_track() has been handed the generated track for this stage.
func stage_target_ms() -> int:
	return _stage_target_ms


# A human label for the run, for the arch banner and the run summary.
func display_name() -> String:
	return _mode.display_name() if _mode != null else ""


# TrackGenParams-shaped params for the CURRENT stage (events_completed()'s index
# into the run's stage list), or {} once the run is over.
func current_stage_params() -> Dictionary:
	if _stage_index < 0 or _stage_index >= _stages.size():
		return {}
	return _stages[_stage_index]


# NOTE: there is deliberately no apply_stage_config here. A stage's track parameters
# reach the live config in exactly ONE place — world.gd._ready calls
# DrivingContext.apply_stage_config, which pulls current_stage_params() from this
# session and forwards it to StageConfig.apply_event_config. Every mode's stage dict
# is TrackGenParams-shaped by construction (ChallengeLibrary.stages_for authors the
# same fields a RALLIES event does; RegionStagePool hands back the authored event
# itself), so that shared writer's "omitted fields fall back to the AUTHORED
# baseline, never the live cfg" semantics apply field for field.


# Seat the target time for the stage about to be driven, from the track that was
# actually generated for it (world.gd, once TrackGenerator returns). Returns the
# target so the caller can frame it without a second read.
#
# It has to be pushed in rather than pulled: the target is a solve over the REAL
# generated centreline, and the only place that dict exists is the run scene.
func set_stage_track(track_result: Dictionary) -> int:
	if not _active or _mode == null:
		_stage_target_ms = 0
		return 0
	_stage_target_ms = _mode.stage_target_ms(_stage_index, track_result)
	return _stage_target_ms


# --- The persisted run slot (pure, no Save dependency — testable with a
# synthetic profile) --------------------------------------------------------

# The stored run in `profile`, or {} if there is none or it can no longer be
# resumed. Pure read.
#
# Only a CHALLENGE run has a stale state: once its period rolls over the run is
# discarded locally with no further posts (spec §3). A region run never expires.
static func resumable_run(profile: Dictionary, unix_time: int) -> Dictionary:
	var run: Dictionary = profile.get(Save.KEY_RUN, {})
	if run.is_empty():
		return {}
	var m := _mode_from_record(run, unix_time)
	if m == null or not m.is_resumable(unix_time):
		return {}
	return run


# True when `profile` holds a run that can no longer be resumed (so it should be
# silently discarded) — the inverse of resumable_run's check, but distinguishing
# "no run at all" from "stale run".
static func has_stale_run(profile: Dictionary, unix_time: int) -> bool:
	var run: Dictionary = profile.get(Save.KEY_RUN, {})
	if run.is_empty():
		return false
	return resumable_run(profile, unix_time).is_empty()


# The one factory: a persisted run record -> its RunMode. Lives here rather than on
# RunMode so the base class never has to name its own subclasses. Records written
# before the run slot carried a "mode" key are read as challenge runs, which is what
# every record in the wild is.
static func _mode_from_record(rec: Dictionary, unix_time: int) -> RunMode:
	match String(rec.get("mode", RunMode.CHALLENGE)):
		RunMode.REGION:
			return RegionRunMode.from_record(rec)
		RunMode.CHALLENGE:
			return ChallengeRunMode.from_record(rec, unix_time)
		_:
			return null


# --- Lifecycle -----------------------------------------------------------------

# THE GENERIC ENTRY POINT. Start `run_mode` with `owned_car`. Fails harmlessly
# (false, no state change) if a run is already ACTIVE; a merely PAUSED run of either
# kind is DISCARDED (decision 27 — one run slot, and the confirm that guards the
# discard belongs to the screen offering the start, not to the session).
#
# Persists immediately at stage 0 so quitting right after starting still resumes.
func begin(run_mode: RunMode, owned_car: Dictionary) -> bool:
	if _active or run_mode == null:
		return false
	var car_id := int(owned_car.get("instance_id", -1))
	if car_id < 0:
		return false
	if run_mode.stage_count() <= 0:
		return false
	var rolled := run_mode.stages()
	if rolled.is_empty():
		return false
	_mode = run_mode
	_stages = rolled
	_car_instance_id = car_id
	_stage_index = 0
	_stage_times_ms = []
	_dnf = false
	_failed = false
	_money_earned = 0
	_stage_target_ms = 0
	_pending_repair = {}
	_last_result = {}
	_pending_pick = []
	_pick_awaiting = false
	_boosts = []
	_active = true
	_stage_running = true
	# Written HERE, the one shared entry point BOTH callers (region + challenge) pass
	# through, so LifetimeStats.RUNS_STARTED counts every run of either kind without a
	# second call site (todo/roguelike-pivot.md "Lifetime global stats").
	Save.add_lifetime_stat(LifetimeStats.RUNS_STARTED)
	_persist()
	return true


# CALLER ONE — the Daily/Weekly/Monthly challenge. `owned_car` should be one of
# ChallengeRunMode.eligible_cars' results (not re-checked here; the entry screen is
# the gate).
func start(kind_str: String, owned_car: Dictionary, unix_time: int) -> bool:
	if _active:
		return false
	var m := ChallengeRunMode.for_kind(kind_str, unix_time)
	if m == null:
		return false
	# One attempt per period. A finished run — completed OR DNF'd — is terminal until
	# the period rolls over (§3's no-retry rule); without this the run record is
	# cleared on finish, so the entry screen would re-offer Start and a player could
	# post a second time for the same period.
	if not ChallengeRunMode.period_outcome(Save.profile, m.period_key).is_empty():
		return false
	return begin(m, owned_car)


# CALLER TWO — a roguelike region run. `run_seed` 0 rolls a fresh seed; pass one to
# reproduce a run exactly.
func start_region(region_id_str: String, owned_car: Dictionary, run_seed := 0) -> bool:
	if _active:
		return false
	return begin(RegionRunMode.for_region(region_id_str, run_seed), owned_car)


# Resume the run stored in the profile's run slot, if any and still resumable.
# Returns true iff a run is now active (whether it was already active or freshly
# resumed).
func resume(unix_time: int) -> bool:
	if _active:
		return true
	var run := resumable_run(Save.profile, unix_time)
	if run.is_empty():
		return false
	var m := _mode_from_record(run, unix_time)
	if m == null:
		return false
	_mode = m
	_stages = m.stages()
	_car_instance_id = int(run.get("car_instance_id", -1))
	_stage_index = int(run.get("stage_index", 0))
	_stage_times_ms = (run.get("stage_times_ms", []) as Array).duplicate()
	_dnf = bool(run.get("dnf", false))
	_failed = false
	_money_earned = int(run.get("money_earned", 0))
	_stage_target_ms = 0
	_pending_repair = {}
	_last_result = {}
	_boosts = (run.get("boosts", []) as Array).duplicate(true)
	# A pick that was still awaiting a choice when this run was last persisted
	# RE-DERIVES rather than being stored verbatim — boost_choices is a pure function
	# of (the mode's own seed, stage_index), so this always matches what was offered
	# before (todo/roguelike-pivot.md: "a resumed run offers the same choice it
	# offered before").
	_pick_awaiting = bool(run.get("pick_awaiting", false))
	_pending_pick = _mode.boost_choices(_stage_index) if _pick_awaiting else []
	_active = true
	_stage_running = true
	return true


# Discard a stored run that can no longer be resumed, with no further posting —
# §3: "the run is discarded locally (no further posts)". No-op if the stored run is
# empty or still resumable.
# Throw away a paused run without finishing it. THE ATTEMPT IS BURNED, not refunded
# (decision 48): the mode records a DNF outcome first, so a challenge period the player
# started and walked away from cannot be restarted from stage 1.
#
# Without this, decision 27's one-slot rule hands out a free retry — starting a region run
# discards the paused challenge, which used to write no outcome at all, so the player could
# reroll a daily until they liked their opening stage. The UI must say plainly that
# quitting costs the attempt; a silent burn is the version of this rule that is unfair.
func discard_run(unix_time: int) -> void:
	var record: Dictionary = Save.profile.get(Save.KEY_RUN, {})
	if record.is_empty():
		return
	var run_mode := _mode_from_record(record, unix_time)
	if run_mode != null:
		run_mode.record_outcome({"dnf": true, "completed": false,
			"cumulative_ms": 0, "abandoned": true}, unix_time)
	Save.clear_run()


# Back-compat name for the stale-run path (a run whose period has since rolled over).
# Same rule: a stale run has still been attempted.
func discard_stale_run(unix_time: int) -> void:
	if not has_stale_run(Save.profile, unix_time):
		return
	discard_run(unix_time)


func _persist() -> void:
	var record := {
		"mode": _mode.mode_id(), "car_instance_id": _car_instance_id,
		"stage_index": _stage_index, "stage_times_ms": _stage_times_ms.duplicate(),
		"dnf": _dnf, "money_earned": _money_earned,
		"boosts": _boosts.duplicate(true), "pick_awaiting": _pick_awaiting,
	}
	record.merge(_mode.to_record(), true)
	Save.set_run(record)


func _clear_persisted() -> void:
	Save.clear_run()


# --- Per-stage flow ------------------------------------------------------------

# The stage just driven is over: bank its time, persist the damage, pay for a clear,
# apply the between-stage field repair, and end the run if this was the last stage
# OR if the target time was missed.
#
# Does its OWN local bookkeeping only — it does not talk to the cloud board itself;
# that happens in the interstitial page via Cloud.challenge_leaderboard.
func report_event_result(elapsed_ms: int, hp_lost: float = 0.0, coins_collected: int = 0) -> void:
	if not _active or not _stage_running:
		return
	_stage_running = false
	_stage_times_ms.append(elapsed_ms)
	if _car_instance_id >= 0 and hp_lost > 0.0:
		Save.apply_damage(_car_instance_id, hp_lost)
		# Rounded to the nearest whole point — the lifetime counter is an int ledger,
		# same as money (todo/roguelike-pivot.md "Lifetime global stats").
		Save.add_lifetime_stat(LifetimeStats.DAMAGE_TAKEN, int(round(hp_lost)))
	if coins_collected > 0:
		# Counted UNCONDITIONALLY, like DAMAGE_TAKEN above — a coin picked up on a
		# missed stage was still a real detour the player drove (decision 35's
		# gamble), even though decision 36 means the MONEY for it doesn't bank below.
		Save.add_lifetime_stat(LifetimeStats.COINS_COLLECTED, coins_collected)
	# THE ONE FAIL STATE (decision 4), asked of the mode BEFORE the cursor moves so
	# the failing stage's own index is what is judged. A challenge always says no.
	var driven_index := _stage_index
	var missed := _mode.stage_failed(driven_index, elapsed_ms, _stage_target_ms)
	_stage_index += 1
	var is_final := _stage_index >= stage_count()
	if not missed:
		Save.add_lifetime_stat(LifetimeStats.STAGES_CLEARED)
		# MONEY BANKS AT STAGE CLEAR, not at run end (decision 36), so a run that dies
		# later keeps everything the earlier stages paid — coins included: a missed
		# stage's coins earn the lifetime credit above but pay nothing here.
		var earned := _mode.stage_money(driven_index, elapsed_ms, _stage_target_ms, coins_collected)
		if earned > 0:
			_money_earned += earned
			Save.add_money(earned)
	_stage_target_ms = 0
	var over := missed or is_final
	Save.save()
	# The same partial pit repair between stages via _pending_repair (the run scene
	# shows the popup on boot), and on the LAST stage of the run SILENTLY, discarding
	# the summary: that damage would otherwise never be patched up, since there is no
	# next stage to cushion for and no scene left to show a popup in. Both go through
	# the ONE shared writer so the fractions can never drift apart.
	if over:
		@warning_ignore("return_value_discarded")
		Save.apply_field_repair_to(_car_instance_id)
	elif _mode.offers_boost_pick():
		# THE PICK (todo/roguelike-pivot.md, "Between stages: repair or boost"). Repair
		# stops being automatic and becomes ONE option among the drawn boosts — the
		# player gives up a boost to take it. Nothing is applied until choose_repair()
		# / choose_boost() resolves the pick; continue_to_next_stage() refuses to
		# advance until one of them has.
		_pending_pick = _mode.boost_choices(_stage_index)
		_pick_awaiting = true
	else:
		# Every mode that does not opt into the pick (the challenge) keeps the old
		# automatic behaviour, unchanged.
		_pending_repair = Save.apply_field_repair_to(_car_instance_id)
	_persist()
	# ORDER MATTERS. standings_ready is emitted while the run is STILL ACTIVE, so
	# every consumer that branches on is_active() resolves against THIS run rather
	# than an idle session. _finish_locally() then follows, so world.gd's
	# run_finished handler sees an overlay that already exists and can wait for the
	# player to dismiss it.
	standings_ready.emit(_stage_index)
	if over:
		_failed = missed
		_finish_locally()


# --- Run-summary times ---------------------------------------------------------
#
# Both return plain int lists so a summary can render "this stage" and "the run so
# far" through one code path.

# The just-finished stage's time, as a one-element list. [] before any stage
# completes, which is the emptiness the run summary branches on rather than a
# sentinel time.
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

# Resume from the between-stage interstitial into the NEXT stage.
#
# There is deliberately no "or resolve results" arm: report_event_result already
# ends the run on the final stage (and on a missed target), so by the time that
# stage's interstitial could ask, `_active` is false and this is a no-op.
#
# _stage_index was already advanced (and the field repair already applied + parked
# in _pending_repair) by report_event_result, so the whole of "enter the next stage"
# is re-entering the driving scene: world.gd._ready seats the new stage's config
# (via DrivingContext.apply_stage_config) and reads current_stage_params() /
# take_pending_repair() on boot, exactly as it did for stage 1.
#
# Refuses while a between-stage pick is still awaiting a choice (_pick_awaiting) —
# choose_repair() / choose_boost() must resolve it first. "The player picks exactly
# one" (todo/roguelike-pivot.md) is enforced HERE, not just by the UI only offering
# those two actions.
func continue_to_next_stage() -> void:
	if not _active or _pick_awaiting:
		return
	_stage_running = true
	stage_started.emit(_stage_index)
	if auto_load_scenes:
		Scenes.change_to(get_tree(), Scenes.MAIN)


# One-shot, cleared on read.
func take_pending_repair() -> Dictionary:
	var r := _pending_repair
	_pending_repair = {}
	return r


# --- Resolving the between-stage pick -------------------------------------------

# Resolve the pending pick by taking the repair. Exactly the SAME field repair every
# other stage transition applies (Save.apply_field_repair_to) — the only change from
# before this stage landed is that it is now a CHOICE instead of automatic, and
# choosing it costs the boost the player didn't take. world.gd's between-stage boot
# still consumes it via take_pending_repair(), unchanged. No-op if no pick is
# outstanding (a stray second call, or a mode that never draws one).
func choose_repair() -> void:
	if not _pick_awaiting:
		return
	_pending_repair = Save.apply_field_repair_to(_car_instance_id)
	_pending_pick = []
	_pick_awaiting = false
	_persist()


# Resolve the pending pick by taking boost `id` — one of the entries pending_pick()
# just offered. Appended to THIS RUN's own boost list (never Save's persisted car —
# see boosts() / world.gd._field_car), so it is visible to UpgradeLibrary.apply the
# moment the next stage fields the car, and gone the moment the run ends (win or
# lose). An id that isn't in the current pick (a stale button press, a miskeyed id)
# still resolves the pick — the player has made a choice, even if it landed on
# nothing — rather than leaving the run stuck unable to advance.
func choose_boost(id: String) -> void:
	if not _pick_awaiting:
		return
	for entry in _pending_pick:
		if String((entry as Dictionary).get("id", "")) == id:
			_boosts.append((entry as Dictionary).duplicate(true))
			break
	_pending_pick = []
	_pick_awaiting = false
	_persist()


func _finish_locally() -> void:
	_last_result = {
		"mode": mode_id(), "period_key": period_key(), "kind": kind(),
		"region_id": region_id(), "car_instance_id": _car_instance_id,
		"stage_times_ms": _stage_times_ms.duplicate(), "cumulative_ms": cumulative_ms(),
		"stages_completed": _stage_index, "stage_count": stage_count(),
		"money_earned": _money_earned,
		"dnf": _dnf, "failed": _failed, "completed": not _dnf and not _failed,
	}
	_active = false
	_stage_running = false
	# BOOSTS ARE WIPED HERE, WIN OR LOSE (todo/roguelike-pivot.md, "Soft permadeath" +
	# this stage's own "gone when the run ends"). _clear_persisted() below already
	# deletes the whole run record — boosts included — from Save, so this in-memory
	# clear is belt-and-braces: the one place that answers "what wipes them", named
	# explicitly rather than left to fall out of begin() resetting it for the NEXT run.
	_boosts = []
	_pending_pick = []
	_pick_awaiting = false
	if _mode != null:
		_mode.record_outcome(_last_result, int(Time.get_unix_time_from_system()))
	# THE ONE HARD FAIL STATE (decision 4) — a challenge run never sets _failed (its
	# mode's stage_failed always returns false), so this counter is region-run-only by
	# construction, matching what LifetimeStats.RUNS_FAILED's own comment promises.
	if _failed:
		Save.add_lifetime_stat(LifetimeStats.RUNS_FAILED)
	_clear_persisted()
	run_finished.emit(_last_result)


# Leave the run WITHOUT ending it. Every path that needs the run to stop being
# active (the pause menu's "Quit", starting a dev benchmark) pauses it. Clears
# _active / _stage_running so nothing keeps driving the run, leaves the run slot
# PERSISTED at its current stage_index / stage_times_ms / car_instance_id, and
# records NO outcome — so the entry screen's Resume path picks it straight back up
# and a challenge period is not spent. The in-progress stage's partial time is
# discarded; the player re-drives that stage on resume.
#
# Deliberately does NOT emit run_finished: that signal means "this run is over" and
# world.gd's handler posts a DNF to the board on it. The caller owns the transition
# back to the hub.
func pause_run() -> void:
	if not _active:
		return
	_active = false
	_stage_running = false
	_pending_repair = {}
	_stage_target_ms = 0
	_persist()

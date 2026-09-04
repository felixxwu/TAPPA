class_name DrivingContext
extends RefCounted
# The ONE place the game answers "which session is fielding a car, and what
# constraints does it impose right now". `RunSession` feeds this — for EITHER kind
# of run (the roguelike region run or the retained Daily/Weekly/Monthly challenge),
# since which kind is live is a RunMode question inside the session rather than a
# second autoload. Screens that read RunSession directly for these questions are
# exactly how a past bug (a challenge car's detune slider got a redundant,
# undocumented hard lock instead of reusing the existing rating_limit/close-button
# gate) happened. A dev boot / benchmark is session-less and answers "no context".
#
# Static-only, no autoload (same shape as RallyLibrary / ChallengeLibrary).

# Sentinel for "no performance ceiling applies". Mirrored locally by
# UpgradesGrid.NO_LIMIT (that component takes a bare limit and knows nothing
# about sessions).
const NO_LIMIT := -1.0


# The instance id of the car actively being driven/fielded by RunSession, if
# it is running — else -1.
# True when a session is fielding a run right now — the "is the player driving a
# real event" question, as opposed to free roam / benchmark / dev boot. Use this
# rather than reading RunSession.is_active() inline at each call site, so a
# future second session caller (the roguelike run) has one place to join.
static func session_active() -> bool:
	return RunSession.is_active()


static func active_car_instance_id() -> int:
	if RunSession.is_active():
		return RunSession.car_instance_id()
	return -1


# The OwnedCar dict for active_car_instance_id(), or {} when nothing is fielded.
static func driven_car() -> Dictionary:
	var iid := active_car_instance_id()
	if iid < 0:
		return {}
	return Save.get_car(iid)


# The CarPerformance RATING ceiling that applies to whichever session is currently
# active, or NO_LIMIT if none.
#
# Only the Rally Challenge has one, and rating_limit() reads "" back from period_key()
# for any other kind of run, so a region run resolves to NO_LIMIT for free. A region
# run deliberately has no ceiling: its difficulty is the CLOCK (decision 11), and
# capping the car as well would undo the whole point of buying a faster one.
static func rating_limit() -> float:
	if RunSession.is_active():
		var key := RunSession.period_key()
		if key == "":
			return NO_LIMIT
		return ChallengeLibrary.ceiling_for(key)
	return NO_LIMIT


# rating_limit() if `instance_id` is the car actually fielded by the active session,
# else NO_LIMIT (a car that ISN'T the active one has no ceiling from this).
static func rating_limit_for_car(instance_id: int) -> float:
	if instance_id < 0 or instance_id != active_car_instance_id():
		return NO_LIMIT
	return rating_limit()


# The ONE place a stage's/event's track parameters reach the live config, pulled
# at CONSUME time (world.gd._ready) rather than pushed by each scene producer —
# so "a new scene-entry site forgot to seat the config" stops being expressible.
#
# Safe to call at consume time because StageConfig.apply_event_config is pure and
# idempotent: it reloads the authored baseline on every call and pins every omitted
# field to it, so applying here is identical to applying before the scene load.
#
# Load-bearing: TrackGenParams.for_event reads only seed/turn_count/width/
# straightness/water_* out of the stage dict — forestiness, cliffiness, surface_mix
# and the terrain_layer* amplitudes reach generation ONLY through cfg, and the lake
# actually rendered and collided against is built from cfg.track_water_level_m
# (world.gd._build_lakes), not from params.water_level.
#
# An active session with an empty stage dict (a run already over) and the
# session-less callers — free roam, benchmark, dev boot — leave cfg exactly as the
# caller authored it; applying {} would reset every field to the baseline and wipe
# those deliberate writes.
static func apply_stage_config(cfg: GameConfig) -> void:
	if RunSession.is_active():
		var stage := RunSession.current_stage_params()
		if not stage.is_empty():
			StageConfig.apply_event_config(cfg, stage)


# Whether `instance_id` is the car the stored run — of EITHER kind — is COMMITTED to.
#
# Scope, deliberately narrow: this answers "is this run fixed to this car", NOT
# "is this car reserved". A run locks the RUN, not the CAR — the car stays fully
# usable in the garage, in engine swaps and in tuning while a run is in progress, and
# repairing it between stages is an accepted consequence.
#
# So do NOT use this to exclude a car from any picker or action outside the run
# itself. It previously gated the garage picker, the engine-swap partner list, the
# career rally lineup and the mid-run repair-kit offer; all four were removed as bugs,
# not features. "You can't switch cars mid-run" is already enforced by
# RunSession.begin refusing while a run is active.
# Save.is_challenge_locked stays the storage-level predicate underneath.
static func is_car_locked(instance_id: int) -> bool:
	return Save.is_challenge_locked(instance_id)

class_name DrivingContext
extends RefCounted
# The ONE place the game answers "which session is fielding a car, and what
# constraints does it impose right now". Career (RallySession) and Rally
# Challenge (ChallengeSession) both feed this identically — screens that read
# RallySession/ChallengeSession directly for these questions are exactly how a
# past bug (a challenge car's detune slider got a redundant, undocumented hard
# lock instead of reusing the existing pw_limit/close-button gate) happened.
# Free roam is session-less and has no equivalent — it answers "no context"
# (see world.gd's car-fielding chain for how free roam resolves its own car).
#
# Static-only, no autoload (same shape as RallyLibrary / ChallengeLibrary).

# Sentinel for "no power-to-weight ceiling applies". Mirrored locally by
# UpgradesMenu.NO_LIMIT (that component takes a bare limit and knows nothing
# about sessions).
const NO_LIMIT := -1.0

# RallySession is an autoload with no class_name, so its STATIC members must be
# reached through the script resource (calling a static via the instance warns).
const RallySessionScript = preload("res://scripts/rally_session.gd")


# The instance id of the car actively being driven/fielded by whichever session
# (if any) is running — ChallengeSession first (only one can be active at a
# time), else RallySession, else -1.
# True when EITHER session is fielding a run right now — the "is the player driving
# a real event" question, as opposed to free roam / benchmark / dev boot. Use this
# instead of testing RallySession.is_active() alone: doing that silently excludes
# challenges, which is how the F-to-finish dev cheat ended up dead in challenge mode.
static func session_active() -> bool:
	return ChallengeSession.is_active() or RallySession.is_active()


static func active_car_instance_id() -> int:
	if ChallengeSession.is_active():
		return ChallengeSession.car_instance_id()
	if RallySession.is_active():
		return RallySession.car_instance_id()
	return -1


# The OwnedCar dict for active_car_instance_id(), or {} when nothing is fielded.
static func driven_car() -> Dictionary:
	var iid := active_car_instance_id()
	if iid < 0:
		return {}
	return Save.get_car(iid)


# The p/w ceiling (hp/tonne) that applies to whichever session is currently
# active, or NO_LIMIT if none / no restriction. Career reads the authored
# rally's restriction; a challenge reads its period's rolled ceiling from the
# period key the running session already knows.
static func pw_limit() -> float:
	if ChallengeSession.is_active():
		var key := ChallengeSession.period_key()
		if key == "":
			return NO_LIMIT
		return ChallengeLibrary.ceiling_for(key)
	if RallySession.is_active():
		var rally := RallyLibrary.by_id(RallySession.rally_id())
		var restriction: Dictionary = rally.get("restriction", {})
		return float(restriction.get("pw_max", NO_LIMIT))
	return NO_LIMIT


# pw_limit() if `instance_id` is the car actually fielded by the active session,
# else NO_LIMIT (a car that ISN'T the active one has no ceiling from this).
static func pw_limit_for_car(instance_id: int) -> float:
	if instance_id < 0 or instance_id != active_car_instance_id():
		return NO_LIMIT
	return pw_limit()


# The ONE place a stage's/event's track parameters reach the live config, pulled
# at CONSUME time (world.gd._ready) rather than pushed by each scene producer —
# so "a new scene-entry site forgot to seat the config" stops being expressible.
# Same session precedence as active_car_instance_id(): challenge first, then career.
#
# Safe to call at consume time because RallySession.apply_event_config is pure and
# idempotent: it reloads the authored baseline on every call and pins every omitted
# field to it, so applying here is identical to applying before the scene load.
#
# Load-bearing: TrackGenParams.for_event reads only seed/turn_count/width/
# straightness/water_* out of the stage dict — forestiness, cliffiness, surface_mix
# and the terrain_layer* amplitudes reach generation ONLY through cfg, and the lake
# actually rendered and collided against is built from cfg.track_water_level_m
# (world.gd._build_lakes), not from params.water_level.
#
# An active session with an empty stage/event dict (a run already over) and the
# session-less callers — free roam, benchmark, dev boot — leave cfg exactly as the
# caller authored it; applying {} would reset every field to the baseline and wipe
# those deliberate writes.
static func apply_stage_config(cfg: GameConfig) -> void:
	if ChallengeSession.is_active():
		var stage := ChallengeSession.current_stage_params()
		if not stage.is_empty():
			RallySessionScript.apply_event_config(cfg, stage)
	elif RallySession.is_active():
		var event := RallySession.current_event()
		if not event.is_empty():
			RallySessionScript.apply_event_config(cfg, event)


# Whether `instance_id` is the car an active challenge run is COMMITTED to.
#
# Scope, deliberately narrow: this answers "is this run fixed to this car", NOT
# "is this car reserved". A challenge locks the RUN, not the CAR — the car stays
# fully usable in career rallies, free roam, the garage, engine swaps and
# upgrades while a run is in progress, and repairing it between stages is an
# accepted consequence (a challenge is a time competition, not a survival one).
#
# So do NOT use this to exclude a car from any picker or action outside the
# challenge run itself. It previously gated the garage picker, the engine-swap
# partner list, the career rally lineup and the mid-run repair-kit offer; all
# four were removed as bugs, not features. "You can't switch cars mid-run" is
# already enforced by ChallengeSession.start refusing while a run is active.
# Save.is_challenge_locked stays the storage-level predicate underneath.
static func is_car_locked(instance_id: int) -> bool:
	return Save.is_challenge_locked(instance_id)

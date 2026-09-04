class_name RunMode
extends RefCounted
# Docs: features/rally-challenge.md, features/region-runs.md — update in the same change as this file.
# Tests: tests/headless/test_region_run.gd, tests/headless/test_challenge_session.gd — extend in the same change.
#
# THE STRATEGY BEHIND `RunSession`. A "run" is N sequential stages driven back to
# back by one car, persisted between stages and resumable. Everything that is the
# SAME for every kind of run — the stage cursor, the banked times, the persisted
# run slot, the between-stage field repair, the car lock, the terminal record —
# lives in `RunSession` (scripts/run_session.gd). Everything that DIFFERS lives
# behind this class:
#
#   * WHICH STAGES are driven          -> stages() / stage_count()
#   * WHETHER A STAGE ENDS THE RUN     -> stage_target_ms() + stage_failed()
#   * WHAT A CLEARED STAGE PAYS        -> stage_money()
#   * WHAT IS PERSISTED AND RESUMED    -> to_record() / is_resumable()
#   * WHAT A FINISHED RUN RECORDS      -> record_outcome()
#
# Two subclasses ship (todo/roguelike-pivot.md decision 15 + the region run):
#   * ChallengeRunMode — the retained Daily/Weekly/Monthly Rally Challenge. Rolled
#     stages, NO target time (a challenge is scored by cumulative time on a cloud
#     board, so nothing can end it early), no per-stage money.
#   * RegionRunMode    — the roguelike region run. Stages drawn from the region's
#     AUTHORED event pool, a fixed reference-car target time per stage, and the
#     one hard fail state in the game: miss it and the run is over.
#
# Adding a third kind of run means adding a subclass here and a factory arm in
# RunSession._mode_from_record — NOT another branch inside the session.

# to_record()["mode"] values. On-disk strings: changing one orphans a paused run.
const CHALLENGE := "challenge"
const REGION := "region"


# Which subclass this is (CHALLENGE / REGION). RunSession persists it so a stored
# run can be rebuilt into the right mode on resume.
func mode_id() -> String:
	return ""


# How many stages the whole run is.
func stage_count() -> int:
	return 0


# The run's stages, in order: TrackGenParams-shaped event dicts, exactly the shape
# `RallyLibrary.RALLIES` events author and `StageConfig.apply_event_config` reads.
# Must be deterministic for a given record, because a resumed run re-derives it.
func stages() -> Array:
	return []


# A short human label for the run ("Daily Challenge", "Rally Country"). UI only.
func display_name() -> String:
	return ""


# The time, in ms, that stage `stage_index` must be beaten in on the track that was
# actually generated for it. <= 0 means THIS RUN HAS NO TARGET — the fail rule can
# never fire and the arch shows no time row. `track_result` is the dict
# `TrackGenerator.generate` returned for this stage (world.gd hands it over through
# RunSession.set_stage_track once generation completes).
func stage_target_ms(_stage_index: int, _track_result: Dictionary) -> int:
	return 0


# Does finishing stage `stage_index` in `elapsed_ms` END THE RUN? `target_ms` is
# whatever stage_target_ms returned for this stage (0 when there is no target).
func stage_failed(_stage_index: int, _elapsed_ms: int, _target_ms: int) -> bool:
	return false


# Money banked the moment stage `stage_index` is CLEARED (decision 36 — at stage
# clear, not at run end, so a run that dies later keeps it). Only called for a stage
# that did NOT fail.
func stage_money(_stage_index: int, _elapsed_ms: int, _target_ms: int) -> int:
	return 0


# The mode-specific half of the persisted run slot. RunSession merges the shared
# half (car_instance_id / stage_index / stage_times_ms) on top and adds "mode".
func to_record() -> Dictionary:
	return {}


# Can a run rebuilt from this record still be resumed at `unix_time`? False means
# the stored run is STALE and should be discarded rather than offered. Only the
# challenge has a stale state (its period rolls over); a region run never expires.
func is_resumable(_unix_time: int) -> bool:
	return true


# Record whatever a FINISHED run of this kind leaves behind on the profile.
# `result` is RunSession's terminal result dict. The challenge writes its
# one-attempt-per-period outcome here; a region run records nothing (its progress
# ledger is `Save.KEY_REGIONS_CLEARED`, written by the region-select stage).
func record_outcome(_result: Dictionary, _unix_time: int) -> void:
	pass

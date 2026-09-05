class_name RegionRunMode
extends RunMode
# Docs: features/region-runs.md, features/lifetime-stats.md, features/collectables.md — update in the same change as this file.
# Tests: tests/headless/test_region_run.gd, tests/headless/test_region_stage_pool.gd, tests/headless/test_boost_library.gd — extend in the same change.
#
# THE ROGUELIKE RUN (todo/roguelike-pivot.md) — caller TWO of `RunSession`. Eight
# stages drawn from one region's authored event pool, driven back to back by one
# car, against a fixed clock. Missing that clock is the ONLY hard fail state in the
# game (decision 4): there are no rivals to lose to and damage can never wreck the
# car, it only makes the clock harder to beat (decision 6).
#
# THE TIMER IS A PROPERTY OF THE STAGE, NOT OF THE CAR (decision 11). The target is
# `LapTimeModel.optimum_ms` solved against `CarPerformance.REFERENCE_CAR` — the same
# reference the rating system normalises against — so every player and every car
# faces the identical number on a given stage. That is what makes the car shop
# matter: a faster car genuinely beats the clock more easily instead of having the
# bar raised to match it.
#
# REGION DIFFICULTY IS ONE TUNABLE (decision 22). `target_pace` tightens with the
# stage index within a run AND with the region's index in the unlock order, so a
# later region simply demands a faster time on the same kind of stage. Money scales
# the same way (decision 31), so grinding region 1 pays worse per unit time than
# progressing — which is what stops "farm the first region forever" without taking
# the repeatable-region grind valve away (decision 12).

# A run is 8 stages (RR's TOTAL_STAGES). Not a GameConfig tunable: the whole
# progression — the money curve's exponent, the pace ramp, decision 32's 16-event
# pool floor ("two runs with no repeats") — is authored against this number, so it
# is a design constant, not a knob.
const STAGE_COUNT := 8

var region_id := ""
var run_seed := 0
var _stage_count := STAGE_COUNT
var _stages_cache: Array = []


func _init(region_id_str := "", seed_value := 0, stage_count_val := STAGE_COUNT) -> void:
	region_id = region_id_str
	run_seed = seed_value
	_stage_count = stage_count_val


# A fresh run of `region_id`. `seed_value` 0 rolls one, so a caller that does not
# care gets a different run each time; pass a seed to reproduce one exactly.
static func for_region(region_id_str: String, seed_value := 0) -> RegionRunMode:
	var s := seed_value
	if s == 0:
		s = int(randi()) | 1  # never 0, so "0 means roll me" stays unambiguous
	return RegionRunMode.new(region_id_str, s, STAGE_COUNT)


static func from_record(rec: Dictionary) -> RegionRunMode:
	return RegionRunMode.new(String(rec.get("region_id", "")), int(rec.get("run_seed", 0)),
		int(rec.get("stage_count", STAGE_COUNT)))


func mode_id() -> String:
	return RunMode.REGION


func stage_count() -> int:
	return _stage_count


# Cached because the draw is called on every stage boot (world.gd asks the session
# for the current stage's params) and re-flattening the region's rallies each time
# is pure waste. Deterministic in (region_id, stage_count, run_seed), so the cache
# can never disagree with a fresh draw.
func stages() -> Array:
	if _stages_cache.is_empty():
		_stages_cache = RegionStagePool.draw(region_id, _stage_count, run_seed)
	return _stages_cache


func display_name() -> String:
	var region := RegionLibrary.by_id(region_id)
	return String(region.get("name", region_id))


func to_record() -> Dictionary:
	return {"region_id": region_id, "run_seed": run_seed, "stage_count": _stage_count}


# How far through the game this region sits — its AUTHORED `order`, not its position in
# the REGIONS array. The array's order is deliberately meaningless (RegionLibrary's header
# says so), so reading index_of() here made a table reorder silently re-rank difficulty
# and payout. Clamped at 0 so an unknown id reads as the FIRST region rather than as the
# hardest and best-paid one.
func region_index() -> int:
	return maxi(0, RegionLibrary.order_of(region_id))


# The multiplier applied to the reference-car optimum to get this stage's target.
# > 1.0 is slower than the point-mass optimum, i.e. beatable. See
# GameConfig.run_target_pace_base for why the shipped values sit where they do.
func target_pace(stage_index: int) -> float:
	var cfg: GameConfig = Config.data
	var pace := cfg.run_target_pace_base \
		- cfg.run_target_pace_stage_step * float(maxi(0, stage_index)) \
		- cfg.run_target_pace_region_step * float(region_index())
	return maxf(pace, cfg.run_target_pace_min)


# The pace-scaled distance/time profile behind `stage_target_ms` — the rival ghost's
# pace line (features/rival-ghost.md: RivalGhost poses a second car along it, and the
# HUD delta compares the player's live time-at-distance against it). `t` is
# LapTimeModel's reference-car time profile, scaled by the SAME `target_pace()`
# factor `stage_target_ms` applies to the total (uniformly, not just at the end) —
# so `profile["t"][-1] * 1000.0` is within float rounding of
# `stage_target_ms(stage_index, track_result)` for any solvable track (the two are
# computed separately, each rounding once at its own single scalar, rather than one
# building on the other's already-rounded output — chaining the roundings would drift
# stage_target_ms's pinned "reference optimum x pace" value by a millisecond here and
# there). Empty for a degenerate track, exactly like stage_target_ms returning 0.
func stage_target_profile(stage_index: int, track_result: Dictionary) -> Dictionary:
	if track_result.is_empty():
		return {}
	var all_stages := stages()
	var event: Dictionary = all_stages[stage_index] if stage_index >= 0 \
		and stage_index < all_stages.size() else {}
	var profile := LapTimeModel.optimum_profile(track_result, CarPerformance.REFERENCE_CAR, event)
	var t: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	if t.is_empty() or t[t.size() - 1] <= 0.0:
		return {}
	var pace := target_pace(stage_index)
	var scaled := PackedFloat32Array()
	scaled.resize(t.size())
	for i in t.size():
		scaled[i] = t[i] * pace
	return {"s": profile.get("s", PackedFloat32Array()), "t": scaled}


# The fixed target for `stage_index` on the track that was actually generated for
# it. `track_result` is TrackGenerator's own result dict; an empty/degenerate one
# yields 0, i.e. NO TARGET — a stage whose track failed to solve must not be
# unwinnable, it just cannot be failed. Computed the same way `stage_target_profile`
# is (same LapTimeModel call, same `target_pace`), not by reading its last sample —
# see that function's comment for why chaining the two would drift this pinned value.
func stage_target_ms(stage_index: int, track_result: Dictionary) -> int:
	if track_result.is_empty():
		return 0
	var all_stages := stages()
	var event: Dictionary = all_stages[stage_index] if stage_index >= 0 \
		and stage_index < all_stages.size() else {}
	var optimum := LapTimeModel.optimum_ms(track_result, CarPerformance.REFERENCE_CAR, event)
	if optimum <= 0:
		return 0
	return int(round(float(optimum) * target_pace(stage_index)))


# THE ONE FAIL STATE. A target of 0 (no solvable track) can never fail.
func stage_failed(_stage_index: int, elapsed_ms: int, target_ms: int) -> bool:
	return target_ms > 0 and elapsed_ms > target_ms


# Banked the moment the stage is cleared (decision 36), so a run that dies on stage
# 6 keeps everything stages 1-5 paid. All three of the pivot's money sources live
# here — a completion amount that grows with stages cleared, a bonus proportional to
# the time saved against the target, and (stage 8) `coins_collected` * GameConfig
# .coin_money. Coins are added AFTER the region scale, not inside it: a coin is
# worth a flat amount everywhere — decision 31's "later region pays more" story is
# about the stage-clear reward, not the collectable gamble on top of it.
func stage_money(stage_index: int, elapsed_ms: int, target_ms: int,
		coins_collected: int = 0) -> int:
	var cfg: GameConfig = Config.data
	var completion := cfg.run_stage_money_base \
		* pow(cfg.run_stage_money_growth, float(maxi(0, stage_index)))
	var bonus := 0.0
	if target_ms > 0 and elapsed_ms < target_ms:
		var saved := clampf(float(target_ms - elapsed_ms) / float(target_ms), 0.0, 1.0)
		bonus = cfg.run_fast_bonus_money * saved
	var region_scale := 1.0 + cfg.run_money_region_step * float(region_index())
	var coin_total := float(maxi(0, coins_collected)) * cfg.coin_money
	return maxi(0, int(round((completion + bonus) * region_scale + coin_total)))


# Record a CLEARED region on the profile. This is the ledger RegionLibrary.is_unlocked
# reads, so it is what actually opens the next region.
#
# Only a run that cleared every stage counts: a run stopped by the clock has not cleared
# the region, however far it got. Deliberately idempotent (a region is listed once), since
# a region stays replayable after it is cleared — decision 45 leaves every region unlocked
# and repeatable, so a second clear must not append a duplicate.
func record_outcome(result: Dictionary, _unix_time: int) -> void:
	if not bool(result.get("completed", false)):
		return
	# LIFETIME STATS (todo/roguelike-pivot.md), written BEFORE the dedupe check below on
	# purpose: REGIONS_CLEARED_TOTAL counts every completed run, repeats included
	# (decision 12's grind valve), which is exactly what distinguishes it from the
	# unique KEY_REGIONS_CLEARED unlock ledger this function also writes.
	# BEST_REGION_ORDER is a high-water mark, ratcheted rather than added — a repeat
	# clear of an earlier region must not read as new progress.
	Save.add_lifetime_stat(LifetimeStats.REGIONS_CLEARED_TOTAL)
	Save.raise_lifetime_stat(LifetimeStats.BEST_REGION_ORDER, region_index())
	var cleared: Array = Save.profile.get(Save.KEY_REGIONS_CLEARED, [])
	if cleared.has(region_id):
		return
	cleared.append(region_id)
	Save.profile[Save.KEY_REGIONS_CLEARED] = cleared
	Save.save_now()


# --- The between-stage pick (see run_mode.gd) -----------------------------------

func offers_boost_pick() -> bool:
	return true


# BoostLibrary.draw is seeded from THIS RUN, never the wall clock — see _boost_seed.
func boost_choices(stage_index: int) -> Array:
	return BoostLibrary.draw(_boost_seed(stage_index), Config.data.run_boost_choices)


# The run's own seed, offset by the stage the pick is FOR — the same "bump by a large
# prime stride" convention world.gd already uses to re-roll a challenge stage's seed on
# retry (features/rally-challenge.md -> "Stage-generation retry"), reused here so a
# resumed run's pick matches what it drew the first time (deterministic in
# (run_seed, stage_index), nothing else). Distinct from RegionStagePool's own stage
# draw, which is keyed on run_seed alone — this needs a SECOND, independent seed per
# stage so the two draws (which stage, which boosts) can't accidentally correlate.
func _boost_seed(stage_index: int) -> int:
	return run_seed + stage_index * 104729

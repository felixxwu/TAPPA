class_name LifetimeStats
extends RefCounted
# Docs: features/lifetime-stats.md — update in the same change as this file.
# Tests: tests/headless/test_lifetime_stats.gd — extend in the same change.
#
# THE STAT REGISTRY (todo/roguelike-pivot.md "Lifetime global stats", stage 7 of
# todo/roguelike-pivot-plan.md). One authored dict, mirroring RR's
# `GLOBAL_STAT_DEFINITIONS` (roguelike-rally/src/game/constants.ts) and its own
# CLAUDE.md rule: adding a stat is a change in ONE place, not a parallel id list, a
# display-name map and a switch statement.
#
# Every counter here lives on `Save.profile[Save.KEY_LIFETIME]`, keyed by its id
# string, and ONLY EVER GROWS — soft permadeath wipes the run (stage progress, this
# run's boosts, the car's accrued damage), never this ledger. Save owns the two
# mutators (`add_lifetime_stat` for a running sum, `raise_lifetime_stat` for a
# high-water mark) and the reader (`lifetime_stat`); this file is pure content plus
# lookup, exactly the CarLibrary/RallyLibrary/BoostLibrary split.
#
# unlock.stat ON A PerkLibrary ENTRY NAMES AN ID FROM THIS TABLE — `is_known()` is
# the contract `test_perk_library.gd -> test_every_unlock_stat_is_a_real_lifetime_stat`
# checks.
#
# WHICH COUNTERS ARE ACTUALLY WRITTEN, AND WHERE (see each stat's own comment below
# for the call site):
#   EVERY stat here is written — STAGES_CLEARED, RUNS_STARTED, RUNS_FAILED,
#   REGIONS_CLEARED_TOTAL, DAMAGE_TAKEN, MONEY_EARNED, MONEY_SPENT, BEST_REGION_ORDER,
#   COINS_COLLECTED, DISTANCE_DRIVEN_M. A DECLARED-BUT-UNWRITTEN stat is a row on the
#   Stats page pinned at zero forever, which reads as a broken counter rather than an
#   unfinished feature: if you add an id here, wire its writer in the same change.

const STAGES_CLEARED := "stages_cleared"
const RUNS_STARTED := "runs_started"
const RUNS_FAILED := "runs_failed"
const REGIONS_CLEARED_TOTAL := "regions_cleared_total"
const DAMAGE_TAKEN := "damage_taken"
const MONEY_EARNED := "money_earned"
const MONEY_SPENT := "money_spent"
const DISTANCE_DRIVEN_M := "distance_driven_m"
const BEST_REGION_ORDER := "best_region_order"
const COINS_COLLECTED := "coins_collected"

const STATS := {
	STAGES_CLEARED: {
		"label": "Stages cleared",
		"description": "Every stage cleared, in any run — region or challenge. " +
			"Written by RunSession.report_event_result on every stage that is not missed.",
	},
	RUNS_STARTED: {
		"label": "Runs started",
		"description": "Every run begun, whatever kind, however it ends. " +
			"Written by RunSession.begin().",
	},
	RUNS_FAILED: {
		"label": "Runs failed",
		"description": "Runs that ended on a missed stage timer — decision 4's one " +
			"hard fail state. A challenge run never sets this (its mode always " +
			"reports stage_failed() as false). Written by RunSession._finish_locally().",
	},
	REGIONS_CLEARED_TOTAL: {
		"label": "Regions cleared",
		"description": "Every completed 8-stage region run, REPEATS INCLUDED " +
			"(decision 12's grind valve keeps a cleared region replayable) — " +
			"distinct from the unique Save.KEY_REGIONS_CLEARED unlock ledger, which " +
			"only ever lists an id once. Written by RegionRunMode.record_outcome().",
	},
	DAMAGE_TAKEN: {
		"label": "Damage taken",
		"description": "Total HP lost to impacts across every run, rounded to the " +
			"nearest whole point per stage. Written by RunSession.report_event_result " +
			"alongside Save.apply_damage.",
	},
	MONEY_EARNED: {
		"label": "Money earned",
		"description": "Every dollar ever banked — stage payouts, fast-completion " +
			"bonuses, challenge rewards. Written once, in Save.add_money, so every " +
			"present and future money source is covered without a second call site.",
	},
	MONEY_SPENT: {
		"label": "Money spent",
		"description": "Every dollar ever spent in the meta shop. Written once, in " +
			"Save.spend_money, so cars/boost levels/the engine-swap unlock/perks all " +
			"feed it through the one funnel every purchase already goes through.",
	},
	DISTANCE_DRIVEN_M: {
		"label": "Distance driven",
		"description": "Metres driven across every stage, missed stages included — " +
			"the distance was driven either way. world.gd snapshots " +
			"TrackProgress.progress_offset() at the finish crossing (a BEST-offset " +
			"odometer: forward progress down the centreline, never rewarding a " +
			"reverse or a wander off it) and passes it to " +
			"RunSession.report_event_result, which writes it here.",
	},
	BEST_REGION_ORDER: {
		"label": "Deepest region reached",
		"description": "The highest region `order` (RegionLibrary.order_of) ever " +
			"CLEARED. A HIGH-WATER MARK, not a running sum — ratcheted with " +
			"Save.raise_lifetime_stat rather than added to, since a repeat clear of " +
			"an earlier region must not count as progress. Written by " +
			"RegionRunMode.record_outcome().",
	},
	COINS_COLLECTED: {
		"label": "Coins collected",
		"description": "Every coin picked up in any run, region stage cleared or " +
			"missed alike (decision 35's off-line detour is scored even when the " +
			"stage's own money doesn't bank — decision 36). Written by " +
			"RunSession.report_event_result().",
	},
}

# Every declared stat id, in table order — the STATS page's row order.
const IDS: Array = [
	STAGES_CLEARED, RUNS_STARTED, RUNS_FAILED, REGIONS_CLEARED_TOTAL,
	DAMAGE_TAKEN, MONEY_EARNED, MONEY_SPENT, DISTANCE_DRIVEN_M, BEST_REGION_ORDER,
	COINS_COLLECTED,
]


static func label_for(id: String) -> String:
	return String(STATS.get(id, {}).get("label", id))


static func is_known(id: String) -> bool:
	return STATS.has(id)

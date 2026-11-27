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
# string, and ONLY EVER GROWS. Save owns the mutator (`add_lifetime_stat`) and the
# reader (`lifetime_stat`); this file is pure content plus lookup.
#
# These three were written by the deleted free-roam island and have no writer or Stats page
# today; saved counts are kept. Wiring them into the level (or dropping them) is still open.

const DISTANCE_DRIVEN_M := "distance_driven_m"
const REST_STOPS_LIT := "rest_stops_lit"
const TIMES_GAVE_UP := "times_gave_up"

const STATS := {
	DISTANCE_DRIVEN_M: {
		"label": "Distance driven",
		"description": "Metres driven (teleports excluded).",
	},
	REST_STOPS_LIT: {
		"label": "Checkpoints reached",
		"description": "Checkpoints reached for the first time.",
	},
	TIMES_GAVE_UP: {
		"label": "Times the car gave up",
		"description": "Respawns after the car hit 0 HP (a crash or an overheat).",
	},
}

# Every declared stat id, in table order — the STATS page's row order.
const IDS: Array = [
	DISTANCE_DRIVEN_M, REST_STOPS_LIT, TIMES_GAVE_UP,
]


static func label_for(id: String) -> String:
	return String(STATS.get(id, {}).get("label", id))

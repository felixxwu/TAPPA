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
# Every stat here is written (each entry's description names the call site). A
# declared-but-unwritten stat is a Stats page row pinned at zero forever, which reads as
# a broken counter: if you add an id here, wire its writer in the same change.

const DISTANCE_DRIVEN_M := "distance_driven_m"
const REST_STOPS_LIT := "rest_stops_lit"
const TIMES_GAVE_UP := "times_gave_up"

const STATS := {
	DISTANCE_DRIVEN_M: {
		"label": "Distance driven",
		"description": "Metres driven in free roam (teleports excluded). Written by " +
			"free_roam.gd's odometer every few seconds.",
	},
	REST_STOPS_LIT: {
		"label": "Rest stops lit",
		"description": "Free-roam rest stops lit for the first time. Written by WorldSession.light().",
	},
	TIMES_GAVE_UP: {
		"label": "Times the car gave up",
		"description": "Free-roam respawns: the car hit 0 HP (a crash or an overheat). " +
			"Written by free_roam.gd on RestStops.respawned.",
	},
}

# Every declared stat id, in table order — the STATS page's row order.
const IDS: Array = [
	DISTANCE_DRIVEN_M, REST_STOPS_LIT, TIMES_GAVE_UP,
]


static func label_for(id: String) -> String:
	return String(STATS.get(id, {}).get("label", id))


static func is_known(id: String) -> bool:
	return STATS.has(id)

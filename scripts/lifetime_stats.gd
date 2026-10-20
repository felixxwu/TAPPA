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
# unlock.stat ON A SkillLibrary ENTRY NAMES AN ID FROM THIS TABLE — `is_known()` is
# the contract `test_skill_library.gd -> test_every_unlock_stat_is_a_real_lifetime_stat`
# checks.
#
# WHICH COUNTERS ARE ACTUALLY WRITTEN, AND WHERE (see each stat's own comment below
# for the call site):
#   EVERY stat here is written — STAGES_CLEARED, RUNS_STARTED, RUNS_FAILED,
#   REGIONS_CLEARED_TOTAL, DAMAGE_TAKEN, MONEY_EARNED, MONEY_SPENT, BEST_REGION_ORDER,
#   COINS_COLLECTED, DISTANCE_DRIVEN_M. A DECLARED-BUT-UNWRITTEN stat is a row on the
#   Stats page pinned at zero forever, which reads as a broken counter rather than an
#   unfinished feature: if you add an id here, wire its writer in the same change.

const DISTANCE_DRIVEN_M := "distance_driven_m"
const REST_STOPS_LIT := "rest_stops_lit"
const TIMES_GAVE_UP := "times_gave_up"

const STATS := {
	DISTANCE_DRIVEN_M: {
		"label": "Distance driven",
		# IMPERATIVE unlock phrasing for the skills page — "take 300 damage",
		# an instruction, not the stats page's read-out label ("Damage taken: 300").
		"goal": "drive %d m",
		"description": "Metres driven in free roam (teleports excluded). Written by " +
			"free_roam.gd's odometer every few seconds.",
	},
	REST_STOPS_LIT: {
		"label": "Rest stops lit",
		"goal": "light %d rest stops",
		"description": "Free-roam rest stops lit for the first time. Written by WorldSession.light().",
	},
	TIMES_GAVE_UP: {
		"label": "Times the car gave up",
		"goal": "give up %d times",
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


# HOW FAR ALONG a gate the player is, as "150/800" — the counter's current value over the
# threshold it has to reach. What the between-stage skill-progress screen shows against
# each locked skill, so the run just driven is visibly moving the player toward something
# rather than only toward the next stage.
#
# Deliberately the BARE FRACTION with no label, unlike `goal_for`: the caller pairs it with
# whichever name its layout wants in the adjacent column (the stat's own `label_for`, or
# the skill's), and a fraction that arrived with "Damage taken: " already glued on could
# not be placed in a second column.
#
# `current` is CLAMPED to `threshold` for display only. A lifetime counter keeps growing
# after a gate is met, and "1240/800" reads as a broken progress bar; the gate itself is
# still decided by SkillLibrary.is_unlocked off the real value, never by this text.
static func progress_text(current: int, threshold: int) -> String:
	return "%d/%d" % [mini(maxi(current, 0), maxi(threshold, 0)), maxi(threshold, 0)]


# The IMPERATIVE phrase a skill's unlock gate renders as — goal_for(DAMAGE_TAKEN, 300)
# is "take 300 damage", an instruction to the player rather than the stats page's
# "Damage taken" read-out name. `threshold` lands wherever the entry's "goal" template
# puts its %d. Falls back to "Stat label: N" for a stat with no goal template (or an
# unknown id — same visible-ugliness-not-crash rule as label_for).
static func goal_for(id: String, threshold: int) -> String:
	var entry: Dictionary = STATS.get(id, {})
	var template := String(entry.get("goal", ""))
	if template.is_empty():
		return "%s: %d" % [label_for(id), threshold]
	return template % threshold


static func is_known(id: String) -> bool:
	return STATS.has(id)

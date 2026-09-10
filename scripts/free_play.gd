class_name FreePlay
extends RefCounted
# Docs: features/hub-shell.md — update in the same change as this file.
# Tests: tests/headless/test_hub_shell.gd (the flow + plan shape) — extend in the
# same change.
#
# FREE PLAY — a session-less sandbox drive, reachable from the hub's MAIN page: any
# catalogue car (owned or not), any region's stage pool (locked or not), and any
# combination of the in-run boosts, started straight onto a stage with no clock to
# beat and nothing at stake. The hub writes the plan here; world.gd consumes it on
# boot when RunSession is NOT active (the same session-less dev-boot path free roam
# always used); the run-session entry points clear it so a real run never inherits
# a stale sandbox car.
#
# WHY A STATIC HOLDER RATHER THAN A RUNSESSION MODE: a free-play drive is
# deliberately NOT a run — no attempt is spent, nothing persists, no target time
# exists to miss, and the finish panel's Next returns to the hub through the
# session-less branch world.gd already has. Making it a run mode would entangle it
# with the persisted run slot, the fail state and the attempt economy the roguelike
# loop is built on; a plan dict consumed by the session-less boot adds the feature
# without touching any of that.
#
# THE PLAN is one Dictionary, held at class level so it survives the scene change
# from hub to world (an autoload would also work; this is one static var on a
# RefCounted, the lightest shape that does the job):
#   "car_index"  int            — CarLibrary catalogue index (ANY car; ownership
#                                 is not consulted, that is the point)
#   "event"      Dictionary     — the TrackGenParams-shaped stage dict the drive
#                                 generates from (RegionStagePool.draw(region, 1,
#                                 seed)[0] at setup time, so the player can re-enter
#                                 free play for a fresh roll)
#   "boost_ids"  Array[String]  — the BoostLibrary ids to apply for the drive


static var _plan := {}


# Record the plan the hub's Free Play setup page confirmed. `boost_ids` are applied
# at each boost's CURRENT purchased level (BoostLibrary.effect_for — the same
# magnitude a real run's pick would roll), so free play previews what the player
# actually has rather than a hypothetical maxed build.
static func begin(car_index: int, event: Dictionary, boost_ids: Array) -> void:
	_plan = {
		"car_index": car_index,
		"event": event.duplicate(true),
		"boost_ids": boost_ids.duplicate(),
	}


static func has_plan() -> bool:
	return not _plan.is_empty()


static func car_index() -> int:
	return int(_plan.get("car_index", 0))


# The stage dict world.gd's generation should use, or {} when no plan is set (the
# session-less dev boot's for_config fallback).
static func event() -> Dictionary:
	return _plan.get("event", {}) if has_plan() else {}


# The chosen boosts in the exact shape world.gd::_field_car already merges onto a
# car's `boosts` list ({"id": String, "effect": Dictionary}) — free play rides the
# SAME UpgradeLibrary.EFFECTS funnel as run boosts and equipped skills, never a
# parallel modifier path.
static func boost_effects() -> Array:
	var out: Array = []
	for id in (_plan.get("boost_ids", []) as Array):
		var effect := BoostLibrary.effect_for(String(id))
		if effect.is_empty():
			continue
		out.append({"id": String(id), "effect": effect})
	return out


static func clear() -> void:
	_plan = {}

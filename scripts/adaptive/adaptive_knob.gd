class_name AdaptiveKnob
extends RefCounted
# Docs: features/adaptive-graphics.md — update in the same change as this file.
## One setting the adaptive controller turns up and down live, with what it has learned about its cost.

var id: StringName
var name := ""
var levels := 2
var level := 1
## func(level: int) -> float: how much the look loses going from `level` down to `level - 1`.
var weight := Callable()
var prior_ms := 0.3
var cost_ms := 0.3  # learned milliseconds one step costs
var samples := 0
var from_fit := false  # the last estimate leant on the draw-call fit rather than timing alone
## Cut only once every other setting is at its lowest, raised before any other.
var last_resort := false
## Cut when the terrain streamer falls behind the car.
var miss_target := false
## func(level: int) -> void: puts the level into effect in the running game.
var apply := Callable()
var backoff_until_s := 0.0
var fails := 0
var last_fail_s := 0.0


func top() -> int:
	return levels - 1


func step_weight(at: int) -> float:
	return float(weight.call(at)) if weight.is_valid() else 1.0


func set_level(to: int) -> void:
	level = clampi(to, 0, top())
	if apply.is_valid():
		apply.call(level)

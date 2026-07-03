class_name ButtonCursor
extends RefCounted
# A manual left/right selection cursor over a fixed row of FOCUS_NONE buttons — the
# idiom the diegetic HQ stations use where "left/right" means *cycle this action row*,
# not "move native focus to the neighbouring widget" (so the 3D station can keep
# left/right for cycling the car / map pin). The cursor is painted by hand with
# `UITheme.mark_focused` (mirroring the theme's real focus look) rather than via
# Godot's focus system.
#
# hq.gd owns the CURRENT INDEX (its `_garage_focus` / `_hub_focus` members, read by
# tests); this helper owns the shared behaviour that was copy-pasted per station:
# wrapping the index, repainting the whole row, and firing the action for an index.
# The action list is the SAME callables the buttons' `pressed` signals connect to, so
# a keyboard/gamepad select and a mouse click can never fall out of step.

var buttons: Array[Button] = []
var actions: Array[Callable] = []


# Wire the cursor to a row of buttons and the callable each one fires (parallel arrays,
# in cursor order). Typically the actions are the very callables passed to each button's
# `pressed.connect(...)`, so click and cursor-select share one path.
func setup(btns: Array, acts: Array) -> void:
	buttons.assign(btns)
	actions.assign(acts)


# The index `step` places away from `index`, wrapping at both ends of the row.
func wrapped(index: int, step: int) -> int:
	if buttons.is_empty():
		return index
	return wrapi(index + step, 0, buttons.size())


# Paint the cursor at `index`: the button at `index` gets the highlight, the rest are
# cleared (see UITheme.mark_focused). No-op before the row is set up.
func refresh(index: int) -> void:
	for i in buttons.size():
		UITheme.mark_focused(buttons[i], i == index)


# Fire the action the cursor sits on. No-op for an out-of-range index.
func activate(index: int) -> void:
	if index >= 0 and index < actions.size():
		actions[index].call()

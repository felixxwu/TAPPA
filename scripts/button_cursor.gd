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


# The index `step` places away from `index`, skipping DISABLED buttons (a disabled
# item — e.g. Change Car with only one owned car — is not a valid cursor stop, same as
# native focus skips disabled controls), wrapping at both ends. Returns `index` unchanged
# if the row is empty or every button is disabled.
func wrapped(index: int, step: int) -> int:
	if buttons.is_empty():
		return index
	var dir := signi(step) if step != 0 else 1
	var next := wrapi(index + step, 0, buttons.size())
	# Walk in the travel direction until we land on an enabled button; the guard stops us
	# after a full loop when the whole row is disabled.
	for _i in buttons.size():
		if not buttons[next].disabled:
			return next
		next = wrapi(next + dir, 0, buttons.size())
	return index


# The nearest enabled index at or after `index` (searching forward, wrapping) — used to
# re-seat the cursor off a button that just became disabled. Returns `index` unchanged if
# the row is empty or every button is disabled.
func settled(index: int) -> int:
	if buttons.is_empty():
		return index
	var i := clampi(index, 0, buttons.size() - 1)
	for _n in buttons.size():
		if not buttons[i].disabled:
			return i
		i = wrapi(i + 1, 0, buttons.size())
	return index


# Paint the cursor at `index`: the button at `index` gets the highlight, the rest are
# cleared (see UITheme.mark_focused). No-op before the row is set up.
func refresh(index: int) -> void:
	for i in buttons.size():
		UITheme.mark_focused(buttons[i], i == index)


# Fire the action the cursor sits on. No-op for an out-of-range or disabled index.
func activate(index: int) -> void:
	if index >= 0 and index < actions.size() and not buttons[index].disabled:
		actions[index].call()

extends Node
# Autoload "InputRemap": lets the player rebind the keyboard and controller
# bindings for the driving controls, and applies their saved choices on top of the
# project.godot defaults at boot. It is the model behind the settings "Key bindings"
# page (scripts/settings_menu.gd) — that page reads `ACTIONS` for the rows, asks for
# the current binding of each device slot (`current_event` + `describe`), and calls
# `rebind` / `reset_defaults` when the player changes something.
#
# Each rebindable action carries up to two editable slots: a "keyboard" slot (an
# InputEventKey) and a "controller" slot (an InputEventJoypadButton or
# InputEventJoypadMotion). Overrides are persisted in the Save profile under
# SETTING_KEY as { action: { "keyboard": <event-dict>, "controller": <event-dict> } }
# and re-applied over the captured factory defaults on every change, so a partial
# override (e.g. only the keyboard key changed) keeps the untouched slot's default.
#
# This is deliberately a SEPARATE autoload from CameraManager / MobileControls (which
# own their own settings keys): those are scene nodes, but the input map must be
# patched globally at boot before any scene reads input — see features/controls.md.

# Save-profile key the override dictionary is stored under (Save.get_setting).
const SETTING_KEY := "input_bindings"

# A joypad-axis deflection past this magnitude counts as "the player chose this axis"
# when listening for a controller binding (ignores stick drift / partial triggers).
const AXIS_THRESHOLD := 0.5

# The two editable device slots.
const SLOT_KEYBOARD := "keyboard"
const SLOT_CONTROLLER := "controller"

# The driving/menu actions exposed on the rebinding page, in display order. Every
# one has both a keyboard and a controller binding in project.godot. The pure
# keyboard debug toggles (toggle_debug_arrows / toggle_perf_overlay) and the ui_*
# menu actions are intentionally omitted — see features/controls.md.
const ACTIONS := [
	{"action": "accelerate", "name": "Accelerate"},
	{"action": "brake_reverse", "name": "Brake / Reverse"},
	{"action": "steer_left", "name": "Steer left"},
	{"action": "steer_right", "name": "Steer right"},
	{"action": "shift_up", "name": "Shift up"},
	{"action": "shift_down", "name": "Shift down"},
	{"action": "handbrake", "name": "Handbrake"},
	{"action": "toggle_gearbox", "name": "Toggle gearbox"},
	{"action": "cycle_drive_mode", "name": "Cycle drive mode"},
	{"action": "reset_car", "name": "Reset car"},
	{"action": "cycle_camera", "name": "Cycle camera"},
]

# Human labels for joypad buttons (SDL standard layout — Xbox / PlayStation glyphs),
# matching the JoyButton enum used in project.godot.
const _BUTTON_NAMES := {
	JOY_BUTTON_A: "A / Cross",
	JOY_BUTTON_B: "B / Circle",
	JOY_BUTTON_X: "X / Square",
	JOY_BUTTON_Y: "Y / Triangle",
	JOY_BUTTON_BACK: "Back",
	JOY_BUTTON_GUIDE: "Guide",
	JOY_BUTTON_START: "Start",
	JOY_BUTTON_LEFT_STICK: "L. Stick",
	JOY_BUTTON_RIGHT_STICK: "R. Stick",
	JOY_BUTTON_LEFT_SHOULDER: "Left Bumper",
	JOY_BUTTON_RIGHT_SHOULDER: "Right Bumper",
	JOY_BUTTON_DPAD_UP: "D-Pad Up",
	JOY_BUTTON_DPAD_DOWN: "D-Pad Down",
	JOY_BUTTON_DPAD_LEFT: "D-Pad Left",
	JOY_BUTTON_DPAD_RIGHT: "D-Pad Right",
}

# The factory-default events per action, deep-copied from the InputMap at boot (i.e.
# straight from project.godot) BEFORE any override is applied — so reset / partial
# overrides can rebuild from a clean baseline without re-reading project settings.
# action -> Array[InputEvent].
var _defaults: Dictionary = {}


func _ready() -> void:
	_capture_defaults()
	apply_saved()


# Snapshot the pristine project.godot bindings for every rebindable action.
func _capture_defaults() -> void:
	_defaults.clear()
	for entry in ACTIONS:
		var action: String = entry["action"]
		if not InputMap.has_action(action):
			continue
		var events: Array = []
		for e in InputMap.action_get_events(action):
			events.append(e.duplicate())
		_defaults[action] = events


# --- Applying ----------------------------------------------------------------

# Rebuild every rebindable action's InputMap events from the captured defaults plus
# the player's saved overrides. Idempotent — also the path "reset to defaults" takes
# (with an empty override dict).
func apply_saved() -> void:
	var bindings := _bindings()
	for entry in ACTIONS:
		var action: String = entry["action"]
		_apply_action(action, bindings.get(action, {}))


# Rebuild one action: keep the default events for any slot the player hasn't
# overridden, and substitute the chosen event for any slot they have.
func _apply_action(action: String, overrides: Dictionary) -> void:
	if not _defaults.has(action) or not InputMap.has_action(action):
		return
	var kb_default: Array = []
	var ctrl_default: Array = []
	for e in _defaults[action]:
		if e is InputEventKey:
			kb_default.append(e)
		elif e is InputEventJoypadButton or e is InputEventJoypadMotion:
			ctrl_default.append(e)

	var events: Array = []
	events.append_array(_slot_events(overrides, SLOT_KEYBOARD, kb_default))
	events.append_array(_slot_events(overrides, SLOT_CONTROLLER, ctrl_default))

	var deadzone := InputMap.action_get_deadzone(action)
	InputMap.action_erase_events(action)
	InputMap.action_set_deadzone(action, deadzone)
	for e in events:
		InputMap.action_add_event(action, e.duplicate())


# The events to use for one slot: the player's override if present, else the
# captured defaults for that slot.
func _slot_events(overrides: Dictionary, slot: String, defaults: Array) -> Array:
	if overrides.has(slot):
		var e := _dict_to_event(overrides[slot])
		return [e] if e != null else []
	return defaults


# --- Editing -----------------------------------------------------------------

# Bind `event` to `action`'s `slot`, persist it, and re-apply. The event must match
# the slot (a key for "keyboard", a joypad button/motion for "controller"). Returns
# false (a no-op) on a mismatch.
func rebind(action: String, slot: String, event: InputEvent) -> bool:
	if slot_for_event(event) != slot:
		return false
	var bindings := _bindings().duplicate(true)
	var per: Dictionary = bindings.get(action, {})
	per[slot] = _event_to_dict(event)
	bindings[action] = per
	Save.set_setting(SETTING_KEY, bindings)
	apply_saved()
	return true


# Drop all overrides and restore the project.godot defaults.
func reset_defaults() -> void:
	Save.set_setting(SETTING_KEY, {})
	apply_saved()


# --- Queries (used by the settings page) -------------------------------------

# Which editable slot an event belongs to, or "" if it isn't rebindable.
func slot_for_event(event: InputEvent) -> String:
	if event is InputEventKey:
		return SLOT_KEYBOARD
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return SLOT_CONTROLLER
	return ""


# The event currently bound to `action`'s `slot` (first match), or null if none.
func current_event(action: String, slot: String) -> InputEvent:
	if not InputMap.has_action(action):
		return null
	for e in InputMap.action_get_events(action):
		if slot_for_event(e) == slot:
			return e
	return null


# A short human label for a binding ("W", "Right Trigger", "Y / Triangle"), for the
# settings buttons. null reads as "Unbound".
func describe(event: InputEvent) -> String:
	if event == null:
		return "Unbound"
	if event is InputEventKey:
		var s := OS.get_keycode_string(event.physical_keycode)
		return s if s != "" else "Key %d" % event.physical_keycode
	if event is InputEventJoypadButton:
		return _BUTTON_NAMES.get(event.button_index, "Button %d" % event.button_index)
	if event is InputEventJoypadMotion:
		return _axis_label(event.axis, event.axis_value)
	return "?"


func _axis_label(axis: int, value: float) -> String:
	match axis:
		JOY_AXIS_LEFT_X:
			return "Left Stick " + ("Left" if value < 0.0 else "Right")
		JOY_AXIS_LEFT_Y:
			return "Left Stick " + ("Up" if value < 0.0 else "Down")
		JOY_AXIS_RIGHT_X:
			return "Right Stick " + ("Left" if value < 0.0 else "Right")
		JOY_AXIS_RIGHT_Y:
			return "Right Stick " + ("Up" if value < 0.0 else "Down")
		JOY_AXIS_TRIGGER_LEFT:
			return "Left Trigger"
		JOY_AXIS_TRIGGER_RIGHT:
			return "Right Trigger"
	return "Axis %d" % axis


# --- Serialisation -----------------------------------------------------------
# InputEvent <-> plain Dictionary, so overrides round-trip through the JSON save.

func _event_to_dict(event: InputEvent) -> Dictionary:
	if event is InputEventKey:
		return {"type": "key", "keycode": event.physical_keycode}
	if event is InputEventJoypadButton:
		return {"type": "button", "button_index": event.button_index}
	if event is InputEventJoypadMotion:
		return {"type": "motion", "axis": event.axis, "axis_value": event.axis_value}
	return {}


func _dict_to_event(d: Variant) -> InputEvent:
	if typeof(d) != TYPE_DICTIONARY:
		return null
	match d.get("type", ""):
		"key":
			var k := InputEventKey.new()
			k.physical_keycode = int(d.get("keycode", 0)) as Key
			return k
		"button":
			var b := InputEventJoypadButton.new()
			b.button_index = int(d.get("button_index", 0)) as JoyButton
			return b
		"motion":
			var m := InputEventJoypadMotion.new()
			m.axis = int(d.get("axis", 0)) as JoyAxis
			m.axis_value = float(d.get("axis_value", 0.0))
			return m
	return null


func _bindings() -> Dictionary:
	var raw: Variant = Save.get_setting(SETTING_KEY, {})
	return raw if raw is Dictionary else {}

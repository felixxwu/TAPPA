extends CanvasLayer
# On-screen touch controls for phones: equal-width buttons along the bottom —
# steer left, steer right, throttle, brake.
#
# These drive the SAME input actions as the keyboard (steer_left, steer_right,
# accelerate, brake_reverse) via Input.action_press/release, so car.gd needs no
# knowledge of touch input. Raw touch events are handled here (rather than using
# Control buttons) so multiple buttons register at once — you must be able to
# steer and use the throttle/brake simultaneously.
#
# Shown only on touch devices, or when mobile_controls_force is set (testing).

# Buttons, left-to-right. Region index == position in this list.
const STEER_LEFT := 0
const STEER_RIGHT := 1
const BRAKE := 2
const THROTTLE := 3
const _BUTTONS := [
	# ASCII labels — the project font has no glyphs for arrow symbols (they render
	# as tofu boxes), so steering uses "<"/">" to match the BRAKE/GAS text buttons.
	{"label": "<", "action": &"steer_left"},
	{"label": ">", "action": &"steer_right"},
	{"label": "BRAKE", "action": &"brake_reverse"},
	{"label": "GAS", "action": &"accelerate"},
]

# Fraction of the viewport height the button strip occupies, anchored to the
# bottom. Touches above the strip are ignored (they fall through to the game).
const _STRIP_HEIGHT_RATIO := 0.15

var _active := false
# pointer index -> region (or -1 if outside the strip). Index -1 is the mouse,
# kept so the controls are also drivable with a mouse when force-enabled.
var _pointers := {}
# Per-button: whether we currently hold its action, so we only press/release on
# transitions instead of every frame.
var _held := []

var _panels: Array[ColorRect] = []
const _IDLE_COLOR := Color(1, 1, 1, 0.12)
const _PRESSED_COLOR := Color(1, 1, 1, 0.35)


func _ready() -> void:
	_held.resize(_BUTTONS.size())
	_held.fill(false)
	_active = Config.data.mobile_controls_force or DisplayServer.is_touchscreen_available()
	visible = _active
	if not _active:
		set_process(false)
		set_process_input(false)
		return
	_build_buttons()
	get_viewport().size_changed.connect(_layout_buttons)


func _build_buttons() -> void:
	for i in _BUTTONS.size():
		var panel := ColorRect.new()
		panel.color = _IDLE_COLOR
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  # we read raw touch ourselves
		var label := Label.new()
		label.text = _BUTTONS[i]["label"]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.add_theme_font_size_override("font_size", 16)
		panel.add_child(label)
		add_child(panel)
		_panels.append(panel)
	_layout_buttons()


func _layout_buttons() -> void:
	var size := get_viewport().get_visible_rect().size
	var col := size.x / _BUTTONS.size()
	var strip_h := size.y * _STRIP_HEIGHT_RATIO
	var top := size.y - strip_h
	for i in _BUTTONS.size():
		_panels[i].position = Vector2(col * i, top)
		_panels[i].size = Vector2(col, strip_h)


# Which button region a screen position falls in, or -1 if it's outside the
# bottom strip (and thus not a control press).
func _region_for_position(pos: Vector2) -> int:
	var size := get_viewport().get_visible_rect().size
	if pos.y < size.y - size.y * _STRIP_HEIGHT_RATIO:
		return -1
	var region := int(pos.x / (size.x / _BUTTONS.size()))
	return clampi(region, 0, _BUTTONS.size() - 1)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_pointers[event.index] = _region_for_position(event.position)
		else:
			_pointers.erase(event.index)
	elif event is InputEventScreenDrag:
		_pointers[event.index] = _region_for_position(event.position)
	elif event is InputEventMouseButton:
		if event.pressed:
			_pointers[-1] = _region_for_position(event.position)
		else:
			_pointers.erase(-1)
	elif event is InputEventMouseMotion and _pointers.has(-1):
		_pointers[-1] = _region_for_position(event.position)


# True if any active pointer is currently on the given button region.
func _region_pressed(region: int) -> bool:
	for r in _pointers.values():
		if r == region:
			return true
	return false


func _set_held(i: int, on: bool) -> void:
	if on == _held[i]:
		return
	_held[i] = on
	if on:
		Input.action_press(_BUTTONS[i]["action"])
	else:
		Input.action_release(_BUTTONS[i]["action"])


# Translate the current button state into held input actions. Called every
# frame; also called directly by tests.
func _apply_actions() -> void:
	for i in _BUTTONS.size():
		var on := _region_pressed(i)
		_set_held(i, on)
		if not _panels.is_empty():
			_panels[i].color = _PRESSED_COLOR if on else _IDLE_COLOR


func _process(_delta: float) -> void:
	_apply_actions()


func _exit_tree() -> void:
	# Release anything we were holding so we don't leave phantom input pressed.
	for i in _BUTTONS.size():
		if _held[i]:
			Input.action_release(_BUTTONS[i]["action"])

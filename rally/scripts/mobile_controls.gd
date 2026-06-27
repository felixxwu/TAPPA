extends CanvasLayer
# On-screen touch controls for phones:
#   * RIGHT side — GAS (top) and BRAKE (below) stacked, right-aligned. Digital
#     buttons: touching one holds its input action.
#   * LEFT side — a horizontal STEERING SLIDER. Drag the thumb left/right for analog
#     steering; lift your finger and it springs back to centre (straight).
#
# These drive the SAME input actions as the keyboard. Gas/brake press
# accelerate/brake_reverse; the slider feeds ANALOG strength into steer_left /
# steer_right via Input.action_press(action, strength) — car.gd reads steering as
# Input.get_axis("steer_right", "steer_left"), which is strength-based, so a partial
# slider gives partial steering. car.gd needs no knowledge of touch input.
#
# Raw touch events are handled here (not Control buttons) so several pointers
# register at once — you must steer and use the throttle/brake simultaneously.
#
# Shown only on touch devices, or when mobile_controls_force is set (testing).

# Digital button regions (index into _BUTTONS / _held).
const GAS := 0
const BRAKE := 1
const _BUTTONS := [
	{"label": "GAS", "action": &"accelerate"},
	{"label": "BRAKE", "action": &"brake_reverse"},
]

const _IDLE_COLOR := Color(1, 1, 1, 0.12)
const _PRESSED_COLOR := Color(1, 1, 1, 0.35)
const _TRACK_COLOR := Color(1, 1, 1, 0.10)
const _THUMB_COLOR := Color(1, 1, 1, 0.30)

var _active := false

# Digital buttons: pointer index -> region (GAS/BRAKE). Index -1 is the mouse, kept
# so the controls are drivable with a mouse when force-enabled. The steering slider
# is owned separately (a captured pointer), so it never appears here.
var _pointers := {}
var _held := [false, false]

# Steering slider state: which pointer is dragging it (null = none, so it recentres),
# that pointer's latest X, and the resulting steer in [-1 (full left), +1 (full right)].
var _slider_owner = null
var _slider_x := 0.0
var _steer := 0.0

# Layout rects (recomputed on resize); the slider thumb width.
var _gas_rect := Rect2()
var _brake_rect := Rect2()
var _slider_rect := Rect2()
var _thumb_w := 40.0

var _gas_panel: ColorRect
var _brake_panel: ColorRect
var _slider_track: ColorRect
var _slider_thumb: ColorRect


func _ready() -> void:
	_active = Config.data.mobile_controls_force or DisplayServer.is_touchscreen_available()
	visible = _active
	if not _active:
		set_process(false)
		set_process_input(false)
		return
	_build()
	get_viewport().size_changed.connect(_layout)


func _build() -> void:
	_gas_panel = _make_button("GAS")
	_brake_panel = _make_button("BRAKE")
	_slider_track = ColorRect.new()
	_slider_track.color = _TRACK_COLOR
	_slider_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_slider_track)
	_slider_thumb = ColorRect.new()
	_slider_thumb.color = _THUMB_COLOR
	_slider_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_slider_thumb)
	_layout()


func _make_button(text: String) -> ColorRect:
	var panel := ColorRect.new()
	panel.color = _IDLE_COLOR
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  # we read raw touch ourselves
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", 16)
	panel.add_child(label)
	add_child(panel)
	return panel


# Lay out the two stacked buttons (bottom-right, gas above brake) and the steering
# slider (bottom-left), as fractions of the viewport so it scales across screens.
func _layout() -> void:
	var size := get_viewport().get_visible_rect().size
	var m := size.x * 0.03

	var btn_w := clampf(size.x * 0.26, 60.0, 260.0)
	var btn_h := size.y * 0.16
	var gap := size.y * 0.02
	var bx := size.x - m - btn_w
	var brake_y := size.y - m - btn_h
	var gas_y := brake_y - gap - btn_h
	_gas_rect = Rect2(bx, gas_y, btn_w, btn_h)
	_brake_rect = Rect2(bx, brake_y, btn_w, btn_h)

	var sl_w := size.x * 0.42
	var sl_h := size.y * 0.12
	_slider_rect = Rect2(m, size.y - m - sl_h, sl_w, sl_h)
	_thumb_w = sl_h

	if _gas_panel != null:
		_gas_panel.position = _gas_rect.position
		_gas_panel.size = _gas_rect.size
		_brake_panel.position = _brake_rect.position
		_brake_panel.size = _brake_rect.size
		_slider_track.position = _slider_rect.position
		_slider_track.size = _slider_rect.size
		_slider_thumb.size = Vector2(_thumb_w, _slider_rect.size.y)
		_position_thumb()


# Which DIGITAL button a screen position falls in, or -1 (the slider is captured
# separately, not via this).
func _button_region(pos: Vector2) -> int:
	if _gas_rect.has_point(pos):
		return GAS
	if _brake_rect.has_point(pos):
		return BRAKE
	return -1


# Steer value [-1, +1] for a thumb at screen X. Centre of the track is straight; the
# usable travel is the half-track minus half the thumb so the thumb stays on the rail.
func _steer_from_x(x: float) -> float:
	var usable := _slider_rect.size.x * 0.5 - _thumb_w * 0.5
	if usable <= 0.0:
		return 0.0
	var center_x := _slider_rect.position.x + _slider_rect.size.x * 0.5
	return clampf((x - center_x) / usable, -1.0, 1.0)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_press(event.index, event.position)
		else:
			_release(event.index)
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position)
	elif event is InputEventMouseButton:
		if event.pressed:
			_press(-1, event.position)
		else:
			_release(-1)
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		_drag(-1, event.position)


func _press(idx: int, pos: Vector2) -> void:
	# A press inside the slider captures that pointer for steering (until it lifts);
	# otherwise it's a digital button press.
	if _slider_owner == null and _slider_rect.has_point(pos):
		_slider_owner = idx
		_slider_x = pos.x
		return
	var r := _button_region(pos)
	if r >= 0:
		_pointers[idx] = r


func _drag(idx: int, pos: Vector2) -> void:
	# The captured slider pointer keeps steering even if it slides off the rail
	# (clamped); any other pointer re-tests which button it's over.
	if idx == _slider_owner:
		_slider_x = pos.x
		return
	var r := _button_region(pos)
	if r >= 0:
		_pointers[idx] = r
	else:
		_pointers.erase(idx)


func _release(idx: int) -> void:
	if idx == _slider_owner:
		_slider_owner = null  # spring the steering back to centre
		return
	_pointers.erase(idx)


# True if any active pointer is on the given button region.
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


# Feed the slider's steer value into the analog steer actions. Left of centre presses
# steer_left, right presses steer_right, both with proportional strength; centre (or
# no finger) releases both. (car.gd: positive get_axis = steer left, so steer_left is
# the left action — matches a thumb dragged left giving _steer < 0.)
func _apply_steer() -> void:
	if _steer < 0.0:
		Input.action_press(&"steer_left", -_steer)
	else:
		Input.action_release(&"steer_left")
	if _steer > 0.0:
		Input.action_press(&"steer_right", _steer)
	else:
		Input.action_release(&"steer_right")


# Translate the current pointer state into held input actions + visuals. Called every
# frame; also called directly by tests.
func _apply_actions() -> void:
	_steer = _steer_from_x(_slider_x) if _slider_owner != null else 0.0
	_apply_steer()
	for i in _BUTTONS.size():
		var on := _region_pressed(i)
		_set_held(i, on)
	if _gas_panel != null:
		_gas_panel.color = _PRESSED_COLOR if _held[GAS] else _IDLE_COLOR
		_brake_panel.color = _PRESSED_COLOR if _held[BRAKE] else _IDLE_COLOR
		_position_thumb()


# Slide the thumb to match the current steer (centre when idle).
func _position_thumb() -> void:
	if _slider_thumb == null:
		return
	var usable := _slider_rect.size.x * 0.5 - _thumb_w * 0.5
	var center_x := _slider_rect.position.x + _slider_rect.size.x * 0.5
	_slider_thumb.position = Vector2(center_x + _steer * usable - _thumb_w * 0.5, _slider_rect.position.y)


func _process(_delta: float) -> void:
	_apply_actions()


func _exit_tree() -> void:
	# Release anything we were holding so we don't leave phantom input pressed.
	for i in _BUTTONS.size():
		if _held[i]:
			Input.action_release(_BUTTONS[i]["action"])
	Input.action_release(&"steer_left")
	Input.action_release(&"steer_right")

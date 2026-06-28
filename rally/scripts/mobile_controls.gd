class_name MobileControls
extends CanvasLayer
# On-screen touch controls for phones, with SIX selectable schemes (chosen on the
# title screen's Settings page, persisted in the save profile under
# SETTING_KEY). All drive the SAME input actions as the keyboard
# (accelerate / brake_reverse / steer_left / steer_right) via
# Input.action_press/release, so car.gd needs no knowledge of touch input.
#
# Schemes (see SCHEMES, order matches the enum):
#   0 SLIDER_GAS_BRAKE  — steering slider (left) + GAS/BRAKE pedals (right). [default]
#   1 BUTTONS_GAS_BRAKE — left/right steer buttons (left) + GAS/BRAKE pedals (right).
#   2 SLIDER_BRAKE_AUTO — steering slider + BRAKE only; throttle is automatic.
#   3 BUTTONS_BRAKE_AUTO— left/right steer buttons + BRAKE only; throttle automatic.
#   4 SIMPLE_LR_AUTO     — tap the left/right half to steer; BOTH at once = brake;
#                          throttle automatic.
#   5 TILT_GAS_BRAKE    — tilt the phone to steer (accelerometer) + GAS/BRAKE pedals.
#
# "Auto gas" (schemes 2/3/4) means FULL THROTTLE UNLESS BRAKING — the accelerate
# action is held whenever the brake isn't.
#
# Raw touch events are handled here (not Control buttons) so several pointers
# register at once — you must steer and use the throttle/brake simultaneously.
#
# Shown only on touch devices, or when mobile_controls_force is set (testing).

# Scheme ids (indices into SCHEMES). Kept as plain ints so Save can persist them.
const SCHEME_SLIDER_GAS_BRAKE := 0
const SCHEME_BUTTONS_GAS_BRAKE := 1
const SCHEME_SLIDER_BRAKE_AUTO := 2
const SCHEME_BUTTONS_BRAKE_AUTO := 3
const SCHEME_SIMPLE_LR_AUTO := 4
const SCHEME_TILT_GAS_BRAKE := 5

const DEFAULT_SCHEME := SCHEME_SLIDER_GAS_BRAKE
# Save-profile settings key the chosen scheme is stored under (Save.get_setting).
const SETTING_KEY := "mobile_control_scheme"

# Display metadata for the Settings page (name + one-line how-to). `id` is the
# scheme constant; order matches the SCHEME_* values so SCHEMES[id] is the entry.
const SCHEMES := [
	{"id": 0, "name": "Slider + Gas/Brake",
		"desc": "Drag the slider to steer; tap Gas and Brake."},
	{"id": 1, "name": "Steer buttons + Gas/Brake",
		"desc": "Left/Right buttons steer; tap Gas and Brake."},
	{"id": 2, "name": "Slider + Brake (auto gas)",
		"desc": "Drag the slider to steer; auto throttle, tap Brake."},
	{"id": 3, "name": "Steer buttons + Brake (auto gas)",
		"desc": "Left/Right buttons steer; auto throttle, tap Brake."},
	{"id": 4, "name": "Simple Left / Right (auto gas)",
		"desc": "Tap the left/right side to steer; both = brake; auto throttle."},
	{"id": 5, "name": "Tilt steering + Gas/Brake",
		"desc": "Tilt the phone to steer; tap Gas and Brake."},
]

const _IDLE_COLOR := Color(1, 1, 1, 0.12)
const _PRESSED_COLOR := Color(1, 1, 1, 0.35)
const _TRACK_COLOR := Color(1, 1, 1, 0.10)
const _THUMB_COLOR := Color(1, 1, 1, 0.30)

# Region screen label (digital buttons). ASCII arrows for steering — the bundled
# font lacks ◄/► glyphs (same reason the menus use < / >).
const _REGION_LABEL := {
	"gas": "GAS", "brake": "BRAKE",
	"steer_left": "<", "steer_right": ">",
	"simple_left": "<", "simple_right": ">",
}

var _active := false
var _scheme := DEFAULT_SCHEME

# Digital regions: pointer index -> region name. Index -1 is the mouse, kept so the
# controls are drivable with a mouse when force-enabled. The steering slider is
# owned separately (a captured pointer), so it never appears here.
var _pointers := {}
# Held input actions, so we only press/release on transitions (and can release all
# on exit). action StringName -> bool.
var _action_held := {}

# Steering slider state: which pointer is dragging it (null = none, so it recentres),
# that pointer's latest X, and the resulting steer in [-1 (full left), +1 (full right)].
var _slider_owner = null
var _slider_x := 0.0
var _steer := 0.0

# Layout: region name -> hit Rect2 (digital buttons / simple halves), plus the
# slider rect + thumb width (slider schemes only). Recomputed on resize.
var _rects := {}
var _slider_rect := Rect2()
var _thumb_w := 40.0

# Visual nodes, rebuilt per scheme: region name -> ColorRect, plus the slider.
var _panels := {}
var _slider_track: ColorRect
var _slider_thumb: ColorRect


func _ready() -> void:
	_active = Config.data.mobile_controls_force or DisplayServer.is_touchscreen_available()
	visible = _active
	if not _active:
		set_process(false)
		set_process_input(false)
		return
	_scheme = _scheme_from_save()
	_build()
	get_viewport().size_changed.connect(_layout)


# The persisted scheme (clamped to a valid id), or the default when unset. Save is
# the autoload; if it isn't present (bare-logic harness), fall back to the default.
func _scheme_from_save() -> int:
	var save := get_node_or_null("/root/Save")
	if save == null:
		return DEFAULT_SCHEME
	return clampi(int(save.get_setting(SETTING_KEY, DEFAULT_SCHEME)), 0, SCHEMES.size() - 1)


# Switch scheme at runtime (rebuilds the overlay). Releases anything held first so
# no input from the old scheme lingers.
func set_scheme(id: int) -> void:
	_release_all()
	_scheme = clampi(id, 0, SCHEMES.size() - 1)
	if _active and is_inside_tree():
		_build()


# --- Scheme feature flags (no allocation; read off _scheme) -------------------

func _has_slider() -> bool:
	return _scheme == SCHEME_SLIDER_GAS_BRAKE or _scheme == SCHEME_SLIDER_BRAKE_AUTO

func _has_steer_buttons() -> bool:
	return _scheme == SCHEME_BUTTONS_GAS_BRAKE or _scheme == SCHEME_BUTTONS_BRAKE_AUTO

func _is_simple() -> bool:
	return _scheme == SCHEME_SIMPLE_LR_AUTO

func _is_tilt() -> bool:
	return _scheme == SCHEME_TILT_GAS_BRAKE

# Throttle is automatic (held unless braking) for the brake-only / simple schemes.
func _is_auto_gas() -> bool:
	return _scheme == SCHEME_SLIDER_BRAKE_AUTO or _scheme == SCHEME_BUTTONS_BRAKE_AUTO \
		or _scheme == SCHEME_SIMPLE_LR_AUTO

func _has_gas_button() -> bool:
	return _scheme == SCHEME_SLIDER_GAS_BRAKE or _scheme == SCHEME_BUTTONS_GAS_BRAKE \
		or _scheme == SCHEME_TILT_GAS_BRAKE

# A dedicated BRAKE button exists in every scheme except the simple one (where
# brake is "both halves at once").
func _has_brake_button() -> bool:
	return not _is_simple()


# --- Build / layout ----------------------------------------------------------

func _build() -> void:
	# Tear down any previous scheme's nodes.
	for p in _panels.values():
		p.queue_free()
	_panels.clear()
	if _slider_track != null:
		_slider_track.queue_free()
		_slider_track = null
	if _slider_thumb != null:
		_slider_thumb.queue_free()
		_slider_thumb = null
	_pointers.clear()
	_slider_owner = null

	# Digital button panels for every region this scheme uses.
	if _has_gas_button():
		_panels["gas"] = _make_button(_REGION_LABEL["gas"])
	if _has_brake_button():
		_panels["brake"] = _make_button(_REGION_LABEL["brake"])
	if _has_steer_buttons():
		_panels["steer_left"] = _make_button(_REGION_LABEL["steer_left"])
		_panels["steer_right"] = _make_button(_REGION_LABEL["steer_right"])
	if _is_simple():
		_panels["simple_left"] = _make_button(_REGION_LABEL["simple_left"])
		_panels["simple_right"] = _make_button(_REGION_LABEL["simple_right"])

	if _has_slider():
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


# Compute hit rects (as fractions of the viewport so it scales across screens) for
# the active scheme, then position the visual nodes to match.
func _layout() -> void:
	var size := get_viewport().get_visible_rect().size
	_compute_rects(size)
	for region in _panels:
		var panel: ColorRect = _panels[region]
		var r: Rect2 = _rects.get(region, Rect2())
		panel.position = r.position
		panel.size = r.size
	if _slider_track != null:
		_slider_track.position = _slider_rect.position
		_slider_track.size = _slider_rect.size
		_slider_thumb.size = Vector2(_thumb_w, _slider_rect.size.y)
		_position_thumb()


# Fill _rects (and _slider_rect/_thumb_w for slider schemes) for the given viewport.
func _compute_rects(size: Vector2) -> void:
	_rects.clear()
	var m := size.x * 0.03
	var gap := size.y * 0.02

	# Right-hand pedal stack: BRAKE at the bottom, GAS above it (when present).
	var btn_w := clampf(size.x * 0.26, 60.0, 260.0)
	var btn_h := size.y * 0.16
	var bx := size.x - m - btn_w
	if _has_brake_button():
		var brake_y := size.y - m - btn_h
		_rects["brake"] = Rect2(bx, brake_y, btn_w, btn_h)
		if _has_gas_button():
			_rects["gas"] = Rect2(bx, brake_y - gap - btn_h, btn_w, btn_h)
	elif _has_gas_button():
		_rects["gas"] = Rect2(bx, size.y - m - btn_h, btn_w, btn_h)

	# Left side: a slider, two steer buttons, or full-height left/right halves.
	if _has_slider():
		var sl_w := size.x * 0.42
		var sl_h := size.y * 0.12
		_slider_rect = Rect2(m, size.y - m - sl_h, sl_w, sl_h)
		_thumb_w = sl_h
	elif _has_steer_buttons():
		var sbw := clampf(size.x * 0.18, 50.0, 180.0)
		var hgap := size.x * 0.02
		var ly := size.y - m - btn_h
		_rects["steer_left"] = Rect2(m, ly, sbw, btn_h)
		_rects["steer_right"] = Rect2(m + sbw + hgap, ly, sbw, btn_h)
	elif _is_simple():
		# The whole lower screen split down the middle, so a tap anywhere on a side
		# steers that way (both sides at once = brake). A top band is left free.
		var top := size.y * 0.2
		var h := size.y - top
		_rects["simple_left"] = Rect2(0.0, top, size.x * 0.5, h)
		_rects["simple_right"] = Rect2(size.x * 0.5, top, size.x * 0.5, h)


# Which digital region a screen position falls in, or "" (the slider is captured
# separately). Simple halves are tested last so the pedals win any overlap.
func _button_region(pos: Vector2) -> String:
	for region in ["gas", "brake", "steer_left", "steer_right", "simple_left", "simple_right"]:
		if _rects.has(region) and (_rects[region] as Rect2).has_point(pos):
			return region
	return ""


# Steer value [-1, +1] for a thumb at screen X. Centre of the track is straight; the
# usable travel is the half-track minus half the thumb so the thumb stays on the rail.
func _steer_from_x(x: float) -> float:
	var usable := _slider_rect.size.x * 0.5 - _thumb_w * 0.5
	if usable <= 0.0:
		return 0.0
	var center_x := _slider_rect.position.x + _slider_rect.size.x * 0.5
	return clampf((x - center_x) / usable, -1.0, 1.0)


# --- Tilt --------------------------------------------------------------------

# Steer [-1, +1] from the device gravity/accelerometer vector. The device's X axis
# rolls left/right when held in landscape; normalise by g, apply a deadzone, then
# scale by sensitivity. Pure + static so it's unit-testable without a sensor.
static func tilt_steer(gravity: Vector3, sensitivity: float, deadzone: float) -> float:
	var raw := gravity.x / 9.80665  # ~[-1, 1] per g of tilt
	if absf(raw) <= deadzone:
		return 0.0
	var span := maxf(1.0 - deadzone, 1e-6)
	var mag := (absf(raw) - deadzone) / span
	return clampf(signf(raw) * mag * sensitivity, -1.0, 1.0)


func _poll_tilt() -> float:
	var cfg: GameConfig = Config.data
	return tilt_steer(Input.get_gravity(), cfg.tilt_sensitivity, cfg.tilt_deadzone)


# --- Input -------------------------------------------------------------------

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
	if _has_slider() and _slider_owner == null and _slider_rect.has_point(pos):
		_slider_owner = idx
		_slider_x = pos.x
		return
	var r := _button_region(pos)
	if r != "":
		_pointers[idx] = r


func _drag(idx: int, pos: Vector2) -> void:
	# The captured slider pointer keeps steering even if it slides off the rail
	# (clamped); any other pointer re-tests which region it's over.
	if idx == _slider_owner:
		_slider_x = pos.x
		return
	var r := _button_region(pos)
	if r != "":
		_pointers[idx] = r
	else:
		_pointers.erase(idx)


func _release(idx: int) -> void:
	if idx == _slider_owner:
		_slider_owner = null  # spring the steering back to centre
		return
	_pointers.erase(idx)


# True if any active pointer is on the given region.
func _region_pressed(region: String) -> bool:
	for r in _pointers.values():
		if r == region:
			return true
	return false


func _set_action(action: StringName, on: bool) -> void:
	if _action_held.get(action, false) == on:
		return
	_action_held[action] = on
	if on:
		Input.action_press(action)
	else:
		Input.action_release(action)


# Feed the current steer value into the analog steer actions. Left of centre presses
# steer_left, right presses steer_right (proportional strength); centre releases both.
# (car.gd: positive get_axis = steer left, so a thumb dragged left gives _steer < 0.)
func _apply_steer() -> void:
	if _steer < 0.0:
		Input.action_press(&"steer_left", -_steer)
	else:
		Input.action_release(&"steer_left")
	if _steer > 0.0:
		Input.action_press(&"steer_right", _steer)
	else:
		Input.action_release(&"steer_right")


# Translate the current pointer / tilt state into held input actions + visuals for
# the active scheme. Called every frame; also called directly by tests.
func _apply_actions() -> void:
	# Steering, per scheme.
	if _has_slider():
		_steer = _steer_from_x(_slider_x) if _slider_owner != null else 0.0
	elif _has_steer_buttons():
		_steer = (1.0 if _region_pressed("steer_right") else 0.0) \
			- (1.0 if _region_pressed("steer_left") else 0.0)
	elif _is_simple():
		var sl := _region_pressed("simple_left")
		var sr := _region_pressed("simple_right")
		# Exactly one side steers; both together is the brake (no steer).
		_steer = (-1.0 if sl and not sr else (1.0 if sr and not sl else 0.0))
	elif _is_tilt():
		_steer = _poll_tilt()
	else:
		_steer = 0.0
	_apply_steer()

	# Brake.
	var brake := false
	if _is_simple():
		brake = _region_pressed("simple_left") and _region_pressed("simple_right")
	elif _has_brake_button():
		brake = _region_pressed("brake")
	_set_action(&"brake_reverse", brake)

	# Throttle: automatic (unless braking) for auto-gas schemes, else the GAS button.
	var gas := false
	if _is_auto_gas():
		gas = not brake
	elif _has_gas_button():
		gas = _region_pressed("gas")
	_set_action(&"accelerate", gas)

	_update_visuals(brake, gas)


# Tint pressed panels and slide the thumb. Cheap; runs each frame.
func _update_visuals(brake: bool, gas: bool) -> void:
	for region in _panels:
		var held := false
		match region:
			"gas": held = gas
			"brake": held = brake
			_: held = _region_pressed(region)
		(_panels[region] as ColorRect).color = _PRESSED_COLOR if held else _IDLE_COLOR
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


# Release every action we might be holding (used on scheme switch + exit) so no
# phantom input lingers.
func _release_all() -> void:
	for action in [&"accelerate", &"brake_reverse"]:
		_set_action(action, false)
	Input.action_release(&"steer_left")
	Input.action_release(&"steer_right")
	_steer = 0.0


func _exit_tree() -> void:
	_release_all()

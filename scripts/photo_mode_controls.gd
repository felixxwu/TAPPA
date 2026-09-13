class_name PhotoModeControls
extends CanvasLayer
# Docs: features/camera.md, features/mobile-controls.md — update in the same change as this file.
# Tests: tests/headless/test_photo_mode.gd, tests/headless/test_photo_mode_controls.gd — extend in the same change.
#
# On-screen touch controls for PHOTO MODE (scripts/photo_mode.gd). Photo mode existed
# with no touch story at all: it hides MobileControls and disarms the pause menu (which
# hides the Pause button), leaving Esc — a keyboard-only key — as the sole way out on a
# phone. This file is that missing control surface, built ONLY when Platform.is_touch()
# is true (see world.gd's _on_photo_mode_requested) and driven straight off the same
# PhotoModeCamera every other input path uses.
#
# process_mode is ALWAYS: exactly like the camera it drives, this whole overlay has to
# keep working while the tree is PAUSED (that's the entire point of photo mode).
#
# Follows the mobile_controls.gd idiom throughout: raw InputEventScreenTouch/ScreenDrag
# in _input (never Control buttons — several fingers must register at once: dragging to
# look, holding Up/Down, and eventually releasing Back all at once must all work),
# pointer-index -> region-name tracking, Rect2 hit regions recomputed on resize, and
# semi-transparent ColorRect panels so the widgets don't dominate the shot the player is
# framing.
#
# Widgets (bottom-left thumbstick, bottom-right Up/Down, top-left Back, top-right Hide)
# plus two full-screen gestures layered underneath them:
#   - a one-finger drag anywhere NOT on a widget looks around (camera.look_by), and
#   - a two-finger pinch anywhere zooms the fov (camera.zoom_by),
#   - and while the widgets are hidden, a plain TAP (not a drag, not a pinch) restores
#     them — see _classify_tap for why a tap needs its own thresholds.

# --- Layout constants (pure pixel/fraction sizing, not tunable behaviour — CLAUDE.md
# treats these like mobile_controls.gd's own layout consts, not GameConfig material). ---
const _MARGIN_FRAC := 0.03
const _STICK_RADIUS_FRAC := 0.11   # thumbstick base radius, as a fraction of the SHORT side
const _STICK_KNOB_FRAC := 0.45     # knob radius as a fraction of the base radius
const _ALT_BTN_W_FRAC := 0.16
const _ALT_BTN_H_FRAC := 0.10
const _CORNER_BTN_W := 96.0
const _CORNER_BTN_H := 56.0

const _IDLE_COLOR := Color(1, 1, 1, 0.10)
const _PRESSED_COLOR := Color(1, 1, 1, 0.30)
const _STICK_BASE_COLOR := Color(1, 1, 1, 0.08)
const _STICK_KNOB_COLOR := Color(1, 1, 1, 0.28)

# Tap-vs-drag classification thresholds. A "tap" (restores the hidden UI) must be a
# press+release that barely moved and didn't linger — anything else has to keep looking
# around or mid-pinch, never snap the UI back over the shot the player is framing.
# Distance in pixels, duration in seconds; both deliberately generous-but-small: real
# fingers wobble a few pixels even on a deliberate tap, and a slow tap is still a tap.
const _TAP_MAX_DIST_PX := 18.0
const _TAP_MAX_DURATION_S := 0.35

var _camera: PhotoModeCamera

# Digital regions: pointer index -> region name ("up", "down", "back", "hide"). Mirrors
# mobile_controls.gd's `_pointers`. The stick and any look/pinch pointers are tracked
# separately below since they aren't simple held buttons.
var _pointers := {}
var _rects := {}  # region name -> Rect2, recomputed on resize

# Thumbstick: which pointer (if any) owns it, the base/knob geometry, and the resulting
# analogue output in [-1, 1] per axis (x = strafe right, y = forward — see
# _stick_output). `_stick_base_center`/`_stick_radius` are recomputed on resize.
var _stick_owner = null
var _stick_base_center := Vector2.ZERO
var _stick_radius := 1.0
var _stick_knob_pos := Vector2.ZERO  # relative to _stick_base_center, clamped to radius

# One-finger look: which pointer is doing it and its last position (for the delta fed
# to camera.look_by). Cleared the instant a second finger goes down — see _input.
var _look_owner = null
var _look_last_pos := Vector2.ZERO
# Per-pointer press bookkeeping, used only for tap classification: index -> {pos, t}.
var _press_info := {}

# Two-finger pinch: the pointer indices and last-seen positions once exactly two
# fingers are down anywhere. `_pinch_active` gates _input's one-finger look path off
# for the duration, so a pinch can never also swing the camera.
var _pinch_active := false
var _pinch_a = null
var _pinch_b = null
var _pinch_a_pos := Vector2.ZERO
var _pinch_b_pos := Vector2.ZERO

var _hidden := false

var _up_panel: ColorRect
var _down_panel: ColorRect
var _back_panel: ColorRect
var _hide_panel: ColorRect
var _stick_base: ColorRect
var _stick_knob: ColorRect
var _all_widgets: Array = []


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# Wire this overlay to the live camera and build the widgets. Called once by world.gd
# right after the camera itself is created (see _on_photo_mode_requested).
func setup(camera: PhotoModeCamera) -> void:
	_camera = camera
	_build()
	get_viewport().size_changed.connect(_layout)
	_layout()


func _build() -> void:
	_back_panel = _make_button("BACK")
	_hide_panel = _make_button("HIDE")
	_up_panel = _make_button("UP")
	_down_panel = _make_button("DOWN")
	_stick_base = ColorRect.new()
	_stick_base.color = _STICK_BASE_COLOR
	_stick_base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stick_base)
	_stick_knob = ColorRect.new()
	_stick_knob.color = _STICK_KNOB_COLOR
	_stick_knob.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stick_knob)
	_all_widgets = [_back_panel, _hide_panel, _up_panel, _down_panel, _stick_base, _stick_knob]


func _make_button(text: String) -> ColorRect:
	var panel := ColorRect.new()
	panel.color = _IDLE_COLOR
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  # raw touch is read ourselves
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	label.add_theme_font_size_override("font_size", UITheme.px(14))
	panel.add_child(label)
	add_child(panel)
	return panel


# --- Layout --------------------------------------------------------------------------

func _layout() -> void:
	var vp := get_viewport()
	if vp == null:
		return  # headless / no-viewport safety: nothing to lay out against yet
	var size := vp.get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	_compute_rects(size)
	_back_panel.position = _rects["back"].position
	_back_panel.size = _rects["back"].size
	_hide_panel.position = _rects["hide"].position
	_hide_panel.size = _rects["hide"].size
	_up_panel.position = _rects["up"].position
	_up_panel.size = _rects["up"].size
	_down_panel.position = _rects["down"].position
	_down_panel.size = _rects["down"].size
	_stick_base.size = Vector2.ONE * _stick_radius * 2.0
	_stick_base.position = _stick_base_center - _stick_base.size * 0.5
	_position_knob()
	_apply_hidden()


func _compute_rects(size: Vector2) -> void:
	_rects.clear()
	var m := size.x * _MARGIN_FRAC
	_rects["back"] = Rect2(Vector2(m, m), Vector2(_CORNER_BTN_W, _CORNER_BTN_H))
	_rects["hide"] = Rect2(Vector2(size.x - m - _CORNER_BTN_W, m), Vector2(_CORNER_BTN_W, _CORNER_BTN_H))

	var alt_w := size.x * _ALT_BTN_W_FRAC
	var alt_h := size.y * _ALT_BTN_H_FRAC
	var alt_gap := size.y * 0.02
	var down_y := size.y - m - alt_h
	_rects["down"] = Rect2(Vector2(size.x - m - alt_w, down_y), Vector2(alt_w, alt_h))
	_rects["up"] = Rect2(Vector2(size.x - m - alt_w, down_y - alt_gap - alt_h), Vector2(alt_w, alt_h))

	_stick_radius = minf(size.x, size.y) * _STICK_RADIUS_FRAC
	_stick_base_center = Vector2(m + _stick_radius, size.y - m - _stick_radius)


# --- Pure/testable seams ---------------------------------------------------------------

# Which region a screen position hits, or "" for none. Tested last-writer-wins order
# doesn't matter here (regions never overlap), unlike mobile_controls.gd's shared corner.
func hit_test(pos: Vector2) -> String:
	# HIDDEN MEANS GONE, not merely invisible. Every widget stops hit-testing while the
	# UI is hidden — otherwise the player who hid the chrome to frame a shot taps near
	# the top-left to bring it back and instead hits the invisible BACK button, leaving
	# photo mode entirely. While hidden the ONLY meanings a touch has are look, pinch,
	# and the tap that restores the UI (_release).
	if _hidden:
		return ""
	for region in ["back", "hide", "up", "down"]:
		if _rects.has(region) and (_rects[region] as Rect2).has_point(pos):
			return region
	if _rects.is_empty():
		return ""
	if _stick_radius > 0.0 and pos.distance_to(_stick_base_center) <= _stick_radius:
		return "stick"
	return ""


# Pure conversion: a touch position + the stick's base center/radius -> the clamped
# knob offset (relative to center) and the analogue [-1,1] output vector (x = right,
# y = forward — UP the screen, i.e. negative Y on screen, is forward). Static so the
# suite can drive it with synthetic geometry, no live overlay required.
static func stick_output_for(touch_pos: Vector2, base_center: Vector2, radius: float) -> Dictionary:
	if radius <= 0.0:
		return {"knob_offset": Vector2.ZERO, "output": Vector2.ZERO}
	var offset := touch_pos - base_center
	if offset.length() > radius:
		offset = offset.normalized() * radius
	var output := Vector2(offset.x / radius, -offset.y / radius)  # screen-up = forward
	return {"knob_offset": offset, "output": output}


# Current thumbstick output as a Vector2 (x = strafe right, y = forward), zero when
# nobody is holding it.
func stick_output() -> Vector2:
	if _stick_owner == null or _stick_radius <= 0.0:
		return Vector2.ZERO
	return Vector2(_stick_knob_pos.x / _stick_radius, -_stick_knob_pos.y / _stick_radius)


# Tap-vs-drag classification, pure: a genuine tap is short AND barely moved. Static so
# it's testable with plain numbers instead of synthesized touch timing.
static func is_tap(distance_moved_px: float, duration_held_s: float) -> bool:
	return distance_moved_px <= _TAP_MAX_DIST_PX and duration_held_s <= _TAP_MAX_DURATION_S


# Pinch fov factor from a previous and current two-finger separation: >1 means the
# fingers moved apart (zoom in), <1 means they moved together (zoom out). Static + pure;
# feeds straight into camera.zoom_by(factor).
static func pinch_zoom_factor(prev_separation: float, cur_separation: float) -> float:
	if prev_separation <= 0.0:
		return 1.0
	return cur_separation / prev_separation


# Whether the widgets are currently hidden (HIDE button, or a prior tap-to-restore).
func is_hidden() -> bool:
	return _hidden


# --- Input -----------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if _camera == null or not _camera.is_active():
		return
	if event is InputEventScreenTouch:
		if event.pressed:
			_press(event.index, event.position)
		else:
			_release(event.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		_drag(event.index, event.position)
		get_viewport().set_input_as_handled()


func _press(idx: int, pos: Vector2) -> void:
	_pointers.erase(idx)
	_press_info[idx] = {"pos": pos, "t": Time.get_ticks_msec()}

	# A tap while hidden restores the UI instead of doing anything else — handled on
	# RELEASE (see _release), once we know it really was a tap and not the start of a
	# drag/pinch. Nothing to capture here in that case; region hit-testing below still
	# runs (hit_test already refuses "stick" while hidden) so a press elsewhere can
	# still start a look.
	var region := hit_test(pos)
	if region == "stick":
		_stick_owner = idx
		_stick_knob_pos = Vector2.ZERO
		return
	if region != "":
		_pointers[idx] = region
		return

	# Not on a widget: this pointer is a look/pinch candidate. Track every down finger
	# that isn't a button/stick so a second finger promotes the pair into a pinch.
	_register_free_pointer(idx, pos)


# Track pointers that landed off every widget, promoting to pinch once a second lands.
func _register_free_pointer(idx: int, pos: Vector2) -> void:
	if _pinch_a == null and _look_owner == null:
		_look_owner = idx
		_look_last_pos = pos
		return
	if _pinch_active:
		return  # a third finger changes nothing; the first two still drive the pinch
	if _look_owner != null and _look_owner != idx:
		# Second free finger: promote to pinch, dropping the one-finger look so a pinch
		# can never also swing the camera (see class doc).
		_pinch_active = true
		_pinch_a = _look_owner
		_pinch_a_pos = _look_last_pos
		_pinch_b = idx
		_pinch_b_pos = pos
		_look_owner = null


func _drag(idx: int, pos: Vector2) -> void:
	if idx == _stick_owner:
		var r := stick_output_for(pos, _stick_base_center, _stick_radius)
		_stick_knob_pos = r["knob_offset"]
		_position_knob()
		return
	if idx in _press_info:
		# Any real movement disqualifies this pointer from being classified as a tap on
		# release, even if it snaps back near its start (a wobble-then-settle drag).
		var info: Dictionary = _press_info[idx]
		if (pos - (info["pos"] as Vector2)).length() > (info.get("max_dist", 0.0) as float):
			info["max_dist"] = (pos - (info["pos"] as Vector2)).length()
			_press_info[idx] = info
	if _pinch_active and (idx == _pinch_a or idx == _pinch_b):
		var prev_sep := _pinch_a_pos.distance_to(_pinch_b_pos)
		if idx == _pinch_a:
			_pinch_a_pos = pos
		else:
			_pinch_b_pos = pos
		var cur_sep := _pinch_a_pos.distance_to(_pinch_b_pos)
		if _camera != null:
			_camera.zoom_by(pinch_zoom_factor(prev_sep, cur_sep))
		return
	if idx == _look_owner:
		var delta := pos - _look_last_pos
		_look_last_pos = pos
		if _camera != null:
			var sens: float = Config.data.photo_touch_look_sensitivity
			# Same sign convention as the mouse path (photo_mode.gd's _input): dragging
			# right turns the view LEFT.
			_camera.look_by(-delta.x * sens, -delta.y * sens)
		return
	# A drag over a digital button re-tests which region it's over, matching
	# mobile_controls.gd's sliding-finger behaviour.
	var region := hit_test(pos)
	if region != "" and region != "stick":
		_pointers[idx] = region
	else:
		_pointers.erase(idx)


func _release(idx: int) -> void:
	if idx == _stick_owner:
		_stick_owner = null
		_stick_knob_pos = Vector2.ZERO
		_position_knob()
		_press_info.erase(idx)
		return
	var region: String = _pointers.get(idx, "")
	_pointers.erase(idx)

	if idx == _pinch_a or idx == _pinch_b:
		_pinch_active = false
		_pinch_a = null
		_pinch_b = null
	if idx == _look_owner:
		_look_owner = null

	var info: Variant = _press_info.get(idx, null)
	_press_info.erase(idx)
	if region == "back":
		if _camera != null:
			_camera.exit()
		return
	if region == "hide":
		set_hidden(true)
		return
	if _hidden and info != null:
		var d: Dictionary = info
		var dist: float = d.get("max_dist", 0.0)
		var duration := float(Time.get_ticks_msec() - int(d.get("t", 0))) / 1000.0
		if is_tap(dist, duration):
			set_hidden(false)


# --- Per-frame: held Up/Down + stick feed into the camera's touch axis -----------------

func _process(_delta: float) -> void:
	if _camera == null or not _camera.is_active():
		return
	var out := stick_output()
	var y := 0.0
	if _region_held("up"):
		y += 1.0
	if _region_held("down"):
		y -= 1.0
	_camera.touch_axis = Vector3(out.x, y, out.y)
	_update_visuals()


func _region_held(region: String) -> bool:
	for idx in _pointers:
		if _pointers[idx] == region:
			return true
	return false


# --- Visuals -----------------------------------------------------------------------

func _position_knob() -> void:
	if _stick_knob == null:
		return
	var knob_radius := _stick_radius * _STICK_KNOB_FRAC
	_stick_knob.size = Vector2.ONE * knob_radius * 2.0
	_stick_knob.position = _stick_base_center + _stick_knob_pos - _stick_knob.size * 0.5


func _update_visuals() -> void:
	if _hidden:
		return
	_up_panel.color = _PRESSED_COLOR if _region_held("up") else _IDLE_COLOR
	_down_panel.color = _PRESSED_COLOR if _region_held("down") else _IDLE_COLOR
	# The knob brightens while held — the one bit of feedback that tells the player the
	# stick actually caught their finger, on a screen where nothing else moves.
	_stick_knob.color = _PRESSED_COLOR if _stick_owner != null else _STICK_KNOB_COLOR


# Hide or show every widget. While hidden, hit_test refuses "stick" (nothing left to
# capture) and a plain tap anywhere restores the UI (_release). HELD input (stick,
# up/down) is force-released on hide so nothing keeps flying with the controls gone.
func set_hidden(hide: bool) -> void:
	if _hidden == hide:
		return
	_hidden = hide
	if hide:
		_pointers.clear()
		_stick_owner = null
		_stick_knob_pos = Vector2.ZERO
	_apply_hidden()


func _apply_hidden() -> void:
	for w in _all_widgets:
		(w as CanvasItem).visible = not _hidden

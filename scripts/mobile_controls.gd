class_name MobileControls
extends CanvasLayer
# On-screen touch controls for phones, with SIX selectable schemes (chosen on the
# title screen's Settings page, persisted in the save profile under
# SETTING_KEY). All drive the SAME input actions as the keyboard
# (accelerate / brake_reverse / steer_left / steer_right, plus nitrous when the
# driven car has any fitted) via
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
# On the web, held pointers are also reconciled every frame against the browser's
# own list of fingers currently down, because mobile browsers drop `touchend`
# events (see _install_touch_watchdog).
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
	"nitrous": "NOS",
	"steer_left": "<", "steer_right": ">",
	"simple_left": "<", "simple_right": ">",
}

# Smallest nitrous button we're willing to draw, in pixels. On a realistic viewport
# there is plenty of room between the steering cluster and the pedal column; on an
# absurdly narrow one the gap can close, and then we drop the button rather than let
# it overlap the steering (which would steal steering input).
const _MIN_NITROUS_W := 8.0

var _active := false
var _scheme := DEFAULT_SCHEME

# Digital regions: pointer index -> region name. Index -1 is the mouse, kept so the
# controls are drivable with a mouse when force-enabled. The steering slider is
# owned separately (a captured pointer), so it never appears here. Entries are NOT
# trusted to be cleared by a release event on the web — see _reconcile_pointers.
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
# Last held state pushed to each panel's tint, so _update_visuals only touches a
# ColorRect's colour on a transition. region name -> bool.
var _panel_held := {}
var _slider_track: ColorRect
var _slider_thumb: ColorRect

# Web only, and all deliberately UNTYPED — JavaScriptObject property access is
# dynamic, and the engine's own documented pattern uses untyped locals for it.
# `_touch_sync_cb` is the JS -> GDScript callback the watchdog PUSHES snapshots
# through; it lives in a member so the reference survives for the node's lifetime.
# `_js_window` backs the redundant per-frame PULL of the same snapshot.
var _touch_sync_cb = null
var _js_window = null
# Sequence number of the newest snapshot we've adopted (-1 = none yet; JS starts its
# counter at 0 and only bumps it when the set of fingers down actually changes), so
# the push and the pull can't apply the same snapshot twice or go backwards.
var _touch_seq := -1
# The browser's authoritative set of fingers CURRENTLY down: touch index -> true.
# `null` means "no snapshot" — the state off the web build and in tests — and
# disables reconciliation entirely, so nothing there is ever released behind our back.
var _live_touches = null
# One-shot logging latch, so the browser console records that the watchdog is
# actually feeding us (and by which path) without spamming a line per frame.
var _logged_first_snapshot := false


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
	_install_touch_watchdog()


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

# The NOS button exists only when nitrous is actually fitted to the driven car
# (GameConfig.has_nitrous(), the same gate the HUD gauge and the sim use). Independent
# of the scheme — every scheme gets one, sited next to the pedal column.
func _has_nitrous_button() -> bool:
	var cfg: GameConfig = Config.data
	return cfg != null and cfg.has_nitrous()


# --- Build / layout ----------------------------------------------------------

func _build() -> void:
	# Tear down any previous scheme's nodes.
	for p in _panels.values():
		p.queue_free()
	_panels.clear()
	_panel_held.clear()
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
	if _has_nitrous_button():
		_panels["nitrous"] = _make_button(_REGION_LABEL["nitrous"])
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
	var hgap := size.x * 0.02

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

	# NOS: a SMALL button immediately left of the pedal column, half a pedal tall, only
	# when nitrous is fitted. Anchored to the GAS pedal where there is one; the auto-gas
	# schemes (2/3) have none, so it anchors to BRAKE instead, and the simple scheme (4)
	# has neither pedal, so it uses the slot a bottom pedal WOULD occupy — that keeps the
	# button in the same corner of the screen in every scheme.
	#
	# In scheme 4 the left/right steering halves cover the whole lower screen, so the NOS
	# rect necessarily sits inside one of them; _button_region tests "nitrous" FIRST, so
	# the button wins and does not steer. Against every other region it must not overlap
	# at all, so its width is capped by the gap to the steering cluster (slider / steer
	# buttons) and the button is dropped outright if that gap has closed.
	if _has_nitrous_button():
		var anchor: Rect2
		if _rects.has("gas"):
			anchor = _rects["gas"]
		elif _rects.has("brake"):
			anchor = _rects["brake"]
		else:
			anchor = Rect2(bx, size.y - m - btn_h, btn_w, btn_h)
		var left_limit := 0.0
		if _has_slider():
			left_limit = _slider_rect.end.x
		elif _has_steer_buttons():
			left_limit = (_rects["steer_right"] as Rect2).end.x
		var avail := anchor.position.x - hgap - (left_limit + hgap)
		var nw := minf(btn_w * 0.45, avail)
		if nw >= _MIN_NITROUS_W:
			var nh := anchor.size.y * 0.5
			_rects["nitrous"] = Rect2(anchor.position.x - hgap - nw, anchor.position.y, nw, nh)


# Which digital region a screen position falls in, or "" (the slider is captured
# separately). Simple halves are tested last so the pedals — and the NOS button, which
# in the simple scheme sits INSIDE a steering half — win any overlap.
func _button_region(pos: Vector2) -> String:
	for region in ["nitrous", "gas", "brake", "steer_left", "steer_right", "simple_left", "simple_right"]:
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
		if _is_emulated_mouse(event):
			return
		if event.pressed:
			_press(-1, event.position)
		else:
			_release(-1)
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		if _is_emulated_mouse(event):
			return
		_drag(-1, event.position)


# True for a mouse event the engine SYNTHESISED from a touch (the project setting
# `input_devices/pointing/emulate_mouse_from_touch` is on by default). The real
# InputEventScreenTouch/Drag is handled above, so acting on the emulated twin too
# would process every finger TWICE — once at its own index, once at -1. Godot tags
# synthesised events with device == InputEvent.DEVICE_ID_EMULATION; a real mouse
# reports its own (non-negative) device id, so a desktop tester running with
# mobile_controls_force still drives the overlay normally.
func _is_emulated_mouse(event: InputEvent) -> bool:
	return event.device == InputEvent.DEVICE_ID_EMULATION


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
	# NOTE: deliberately does NOT gate on the browser's live-touch snapshot. A drag
	# for a finger that has already lifted CAN arrive (Godot flushes buffered input a
	# frame late), but discarding it here means judging a just-flushed press against a
	# snapshot that is newer than the event stream — which silently swallows the first
	# drag of a press-and-slide that lands in one frame. The per-frame reconcile in
	# _timed_process undoes such a resurrection before it can reach the car anyway, so
	# this path stays purely additive. See _install_touch_watchdog.
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


# --- Web: stuck-touch watchdog ------------------------------------------------
#
# Mobile browsers sometimes never deliver the `touchend` for a finger that is
# lifted while OTHER fingers are still down, so the button stays held and the car
# keeps steering / accelerating on its own. Two documented causes:
#   * iOS Safari/Chrome drop one of a touchstart/touchend pair that land in the
#     same frame (one hand pressing as the other lifts).
#   * Blink/older WebKit can end a slightly-moved touch with `touchcancel` and
#     then dispatch nothing further at all.
# Neither is something Godot can fix from its side: the engine's web input layer
# only ever reads `evt.changedTouches`, never `evt.touches` — the browser's
# authoritative list of fingers CURRENTLY down — so a dropped release leaves
# _pointers/_slider_owner populated with no event that would ever clear them.
#
# So we stop trusting `touchend` and RECONCILE instead. The JS below publishes the
# live `evt.touches` identifiers to `window.__rallyTouchIds` (plus a change counter,
# `__rallyTouchSeq`, so the poll below is a single cheap int read on a quiet frame),
# and _reconcile_pointers drops any pointer missing from that set. Browser touch
# identifiers are what the engine passes straight through as the Godot touch index,
# so no translation is needed. Inert off the web build.
#
# The snapshot reaches GDScript by TWO independent paths, because neither is worth
# betting the controls on alone and they cost almost nothing together:
#   * PUSH — JS calls `window.godotTouchSync(seq, ids)`, a JavaScriptBridge callback.
#     This is the engine's documented JS -> GDScript mechanism.
#   * PULL — _poll_live_touches reads `window.__rallyTouchSeq` / `__rallyTouchIds`
#     back through the `window` wrapper once a frame.
# `_touch_seq` makes them idempotent, so whichever arrives first wins and the other
# is a no-op. If one path is unavailable on a given browser/export, the other still
# feeds reconciliation.
#
# Two properties of the DESIGN matter, and the first version of this fix had neither
# — which is why it didn't work:
#
#   1. Reconciliation is SELF-CORRECTING, run from _process rather than from the DOM
#      handler. The old version force-released once, synchronously inside the JS
#      event — i.e. AHEAD of Godot's buffered-input flush for that frame. Any drag
#      already queued for the lifted finger was then flushed on top and re-added the
#      pointer, and because that finger sends no further events, the one-shot
#      watchdog never reconciled again. That's exactly the first reported symptom: a
#      finger only stuck if it had MOVED slightly before release, because a
#      stationary finger queues no drag to resurrect it. So the push path here only
#      ever STORES the snapshot; _timed_process re-checks it every frame, before
#      _apply_actions, so a resurrected pointer dies before it can reach the car.
#   2. The listeners are on `window` AND `document`, capture phase, rather than on
#      the canvas element found by id — fewer assumptions about the page, and capture
#      at the top of the propagation path means nothing downstream can hide an event
#      from us. Both registrations firing is harmless; publish() dedupes.
#
# Pointer Events are watched as well. They are a SEPARATE browser code path from
# touch events, so they still fire when a `touchend` is dropped. Their ids can't be
# mapped onto touch identifiers, but "every pointer is now up" needs no mapping and
# is precisely the state a stuck button contradicts.
func _install_touch_watchdog() -> void:
	if not OS.has_feature("web"):
		return
	_js_window = JavaScriptBridge.get_interface("window")
	if _js_window == null:
		return
	_touch_sync_cb = JavaScriptBridge.create_callback(_on_touch_sync)
	_js_window.godotTouchSync = _touch_sync_cb
	JavaScriptBridge.eval(_TOUCH_WATCHDOG_JS, true)


# PUSH path. Args arrive from JS as an array: [seq, comma-separated ids]. Guarded so
# a malformed call can't break input handling. Deliberately does NOT reconcile — this
# runs synchronously inside a DOM event, ahead of Godot's input flush; see above.
func _on_touch_sync(args: Array) -> void:
	# Type-checked rather than blind-converted: a GDScript error raised in here (or in
	# the per-frame pull) would abort the caller, and if that caller is _timed_process
	# then _apply_actions never runs and every held action FREEZES — a stuck button by
	# a different route. Both readers must fail by doing nothing.
	if args.size() < 2 or not _is_number(args[0]) or typeof(args[1]) != TYPE_STRING:
		return
	_adopt_live_touches(int(args[0]), args[1])


# PULL path. Cheap enough for every frame: one int property read while nothing
# changes (the counter doesn't move as fingers merely slide around), and the id list
# is only fetched + parsed on an actual change.
func _poll_live_touches() -> void:
	if _js_window == null:
		return
	# Missing / wrong-typed when the eval never ran, or when this browser or export
	# can't read window properties back through the bridge — in which case the push
	# path carries us. Bail rather than convert; see _on_touch_sync.
	var raw_seq = _js_window.__rallyTouchSeq
	if not _is_number(raw_seq):
		return
	var seq := int(raw_seq)
	# seq 0 is JS's initial "no touch has happened yet" value: leave _live_touches
	# null rather than treating "no snapshot" as "no fingers down".
	if seq <= 0 or seq <= _touch_seq:
		return
	var raw_ids = _js_window.__rallyTouchIds
	if typeof(raw_ids) != TYPE_STRING:
		return
	_adopt_live_touches(seq, raw_ids)


func _is_number(v) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


# Store a newer snapshot of the fingers currently down. `ids` is the comma-separated
# list JS publishes ("" = nothing down). Older/duplicate sequence numbers are ignored,
# which is what lets the push and pull paths run side by side.
func _adopt_live_touches(seq: int, ids: String) -> void:
	if seq <= _touch_seq:
		return
	_touch_seq = seq
	var live := {}
	for id in ids.split(",", false):
		live[int(id)] = true
	_live_touches = live
	# Logged once, and only when the watchdog is really installed (so headless tests
	# driving this seam stay quiet): confirms on a real phone, over chrome://inspect,
	# that a snapshot path is actually plumbed through.
	if not _logged_first_snapshot and _js_window != null:
		_logged_first_snapshot = true
		print("[rally] touch watchdog feeding: seq=", seq, " fingers=", live.size())


# Drop every tracked pointer the browser says is no longer down. Runs each frame
# before _apply_actions, so a stuck pointer costs at most one frame and a pointer
# resurrected by a late-flushed drag is dropped again rather than sticking forever.
func _reconcile_pointers() -> void:
	if _live_touches == null:
		return
	var live: Dictionary = _live_touches
	# Two passes so the common (nothing lost) case allocates nothing: iterating the
	# Dictionary directly is allocation-free, .keys() is not, and this runs per frame
	# on exactly the platform where GC churn hurts most.
	var lost := false
	for idx in _pointers:
		if _is_lifted_in(live, idx):
			lost = true
			break
	if lost:
		for idx in _pointers.keys():
			if _is_lifted_in(live, idx):
				# Rare, and the single most useful thing to see in the browser console
				# when diagnosing a stuck button on a real phone. Web-only, so the
				# headless tests that drive this seam don't print.
				if _js_window != null:
					print("[rally] touch watchdog dropped stuck pointer ", idx,
						" (", live.size(), " finger(s) actually down)")
				_pointers.erase(idx)
	if _slider_owner != null and _is_lifted_in(live, _slider_owner):
		_slider_owner = null  # spring the steering back to centre


# True when `idx` is a touch pointer missing from the browser's live set. The mouse is
# index -1 and never appears in a touch list, so it's excluded — a real mouse must
# keep working for desktop testing with mobile_controls_force.
func _is_lifted_in(live: Dictionary, idx: int) -> bool:
	return idx >= 0 and not live.has(idx)


const _TOUCH_WATCHDOG_JS := """
(function () {
	if (window.__rallyTouchWatchdog) { return; }
	window.__rallyTouchWatchdog = true;
	window.__rallyTouchIds = '';
	window.__rallyTouchSeq = 0;
	// Published for BOTH readers: stored on window for the per-frame pull, and pushed
	// straight to GDScript. Deduped, so double-registered listeners are harmless.
	function publish(ids) {
		var s = ids.join(',');
		if (s === window.__rallyTouchIds) { return; }
		window.__rallyTouchIds = s;
		window.__rallyTouchSeq++;
		if (window.godotTouchSync) { window.godotTouchSync(window.__rallyTouchSeq, s); }
	}
	function dropAll() { publish([]); }
	// evt.touches is the browser's authoritative list of fingers currently down —
	// unlike changedTouches (all the engine reads) it can't miss a dropped release.
	function sync(e) {
		var now = [];
		for (var i = 0; i < e.touches.length; i++) { now.push(e.touches[i].identifier); }
		publish(now);
	}
	['touchstart', 'touchmove', 'touchend', 'touchcancel'].forEach(function (t) {
		window.addEventListener(t, sync, true);
		document.addEventListener(t, sync, true);
	});
	// Pointer Events: a separate browser code path, so they still fire when a
	// touchend is dropped. pointerId can't be mapped onto a touch identifier, but
	// "everything is up" needs no mapping — and that's the state a stuck button
	// contradicts. Tracked as a set rather than a count so a missed event can't
	// leave a permanent drift.
	var down = {};
	var sawPointer = false;
	window.addEventListener('pointerdown', function (e) {
		down[e.pointerId] = true;
		sawPointer = true;
	}, true);
	function pointerUp(e) {
		delete down[e.pointerId];
		if (!sawPointer) { return; }
		for (var k in down) { return; }
		dropAll();
	}
	window.addEventListener('pointerup', pointerUp, true);
	window.addEventListener('pointercancel', pointerUp, true);
	// Backgrounding the page ends every touch with no per-id event to observe.
	window.addEventListener('blur', dropAll);
	window.addEventListener('pagehide', dropAll);
	document.addEventListener('visibilitychange', function () {
		if (document.hidden) { dropAll(); }
	});
	console.log('[rally] touch watchdog installed');
})();
"""


# True if any active pointer is on the given region.
func _region_pressed(region: String) -> bool:
	# Iterate the Dictionary directly — .values() would allocate a fresh Array on
	# every call, and this runs several times per frame (_apply_actions +
	# _update_visuals) on exactly the platform where GC churn hurts most.
	for idx in _pointers:
		if _pointers[idx] == region:
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
	_apply_steer_side(&"steer_left", -_steer)
	_apply_steer_side(&"steer_right", _steer)


# Press one steer action at `strength` while positive, release it otherwise. The
# RELEASE is change-guarded (the same pattern as _set_action) so a centred stick
# doesn't fire an action_release event every single frame. The PRESS is not: the
# strength is analog and has to be re-pushed whenever it moves, exactly as Godot's
# own analog input does — re-pressing a held action doesn't change its held-ness.
func _apply_steer_side(action: StringName, strength: float) -> void:
	if strength > 0.0:
		_action_held[action] = true
		Input.action_press(action, strength)
	elif _action_held.get(action, false):
		_action_held[action] = false
		Input.action_release(action)


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

	# Nitrous: a plain held button (car.gd reads Input.is_action_pressed("nitrous")).
	# Absent when nitrous isn't fitted, in which case the region simply never matches.
	var nos := _region_pressed("nitrous")
	_set_action(&"nitrous", nos)

	# Throttle: automatic (unless braking) for auto-gas schemes, else the GAS button — and
	# NOS implies gas. There is no reason to hold nitrous without throttle (the sim refuses
	# to deliver or drain off-throttle anyway), and on touch the two buttons are adjacent, so
	# requiring both thumbs would just make the boost feel broken. Holding NOS therefore
	# presses accelerate too; releasing it leaves a separately-held GAS untouched, since this
	# is an OR over the two regions rather than a write.
	var gas := false
	if _is_auto_gas():
		gas = not brake
	elif _has_gas_button():
		gas = _region_pressed("gas") or nos
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
		# Only write on a change: assigning ColorRect.color dirties the canvas item
		# even when the value is identical, and that's 2-4 panels every frame.
		if _panel_held.get(region, null) != held:
			_panel_held[region] = held
			(_panels[region] as ColorRect).color = _PRESSED_COLOR if held else _IDLE_COLOR
	_position_thumb()


# Slide the thumb to match the current steer (centre when idle).
func _position_thumb() -> void:
	if _slider_thumb == null:
		return
	var usable := _slider_rect.size.x * 0.5 - _thumb_w * 0.5
	var center_x := _slider_rect.position.x + _slider_rect.size.x * 0.5
	_slider_thumb.position = Vector2(center_x + _steer * usable - _thumb_w * 0.5, _slider_rect.position.y)


func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"mobile_controls", Time.get_ticks_usec() - __t)


func _timed_process(_delta: float) -> void:
	# Reconcile BEFORE applying: a pointer the browser says is up must never reach
	# the car's input actions, not even for a single frame.
	_poll_live_touches()
	_reconcile_pointers()
	_sync_nitrous_button()
	_apply_actions()


# Nitrous is fitted per CAR (car.gd's apply_owned retunes Config.data), and a car swap
# raises no signal, so the overlay polls the same gate the HUD gauge does and rebuilds
# when it flips. Cheap: two float compares on a frame where nothing changed.
func _sync_nitrous_button() -> void:
	if _panels.has("nitrous") == _has_nitrous_button():
		return
	_set_action(&"nitrous", false)
	_build()


# Release every action we might be holding (used on scheme switch + exit) so no
# phantom input lingers.
func _release_all() -> void:
	for action in [&"accelerate", &"brake_reverse", &"nitrous"]:
		_set_action(action, false)
	_steer = 0.0
	# Through the same helper, so the held-state cache can never be left claiming a
	# steer action is down after we've released it.
	_apply_steer_side(&"steer_left", 0.0)
	_apply_steer_side(&"steer_right", 0.0)


func _exit_tree() -> void:
	_release_all()

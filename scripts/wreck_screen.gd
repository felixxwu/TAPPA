class_name WreckScreen
extends Node3D
# The mid-event WRECK sequence — the diegetic moment when the fielded car's HP hits
# 0. Rather than cutting straight to the podium (too abrupt), the crash is allowed
# to play out, then an orbit camera circles the wrecked car (the same slow orbit as
# the start-line reveal, scripts/start_line.gd) while a menu tells the player the car
# is wrecked and offers to return to HQ:
#
#   1. CRASHING — the car's controls are locked (so it can't be driven away) and the
#      chase camera stays on it while it tumbles to rest. Once it has settled (or a
#      safety cap elapses) we move on.
#   2. ORBIT    — the orbit camera takes over, the driving HUD is hidden, and a flat
#      "CAR WRECKED" menu shows a Return to HQ button. Pressing it emits
#      `return_requested`, which world.gd routes to RallySession.report_wreck (DNF).
#
# Created and wired by world.gd (session runs only, on a real display). It owns the
# orbit camera + overlay; both are freed with the scene when the rally resolves.

# Speed (m/s) below which the wrecked car counts as settled — the orbit/menu waits
# for this so it never appears while the car is still sliding/rolling.
const STOP_SPEED_EPS := 0.5

# A minimum beat (s) we always stay in CRASHING, so even a low-speed wreck shows a
# moment of the crash before the menu rather than snapping straight to the orbit.
const SETTLE_MIN_SECONDS := 0.8

# Sequence phases. CRASHING waits for the car to settle; ORBIT is the menu state.
enum Seq { CRASHING, ORBIT }

# Emitted when the player presses Return to HQ — world.gd reports the wreck (DNF).
signal return_requested()

var _seq: int = Seq.CRASHING
var _settle_t := 0.0
var _orbit_angle := 0.0

# Refs handed in by world.gd (camera/HUD optional so tests can omit them).
var _player: Node3D
var _chase_camera: Camera3D
var _hud: CanvasLayer
var _mobile: CanvasLayer

# Nodes this scene owns.
var _orbit_cam: Camera3D
var _overlay: CanvasLayer
var _return_button: Button


func _cfg() -> GameConfig:
	return Config.data


# Begin the wreck sequence around the (just-wrecked) fielded car. Locks the car so
# it can't be driven, keeps the chase camera on the crash, and builds the orbit
# camera + menu ready for the ORBIT phase. `chase_camera` / `hud` / `mobile` are
# optional (tests omit them).
func setup(player: Node3D, chase_camera: Camera3D = null, hud: CanvasLayer = null,
		mobile: CanvasLayer = null) -> void:
	_player = player
	_chase_camera = chase_camera
	_hud = hud
	_mobile = mobile
	# Hold the wreck still: forced handbrake, no driver input (car.gd reads this).
	if _player != null and "controls_locked" in _player:
		_player.controls_locked = true
	_build_orbit_camera()
	_build_overlay()


# --- Orbit camera ------------------------------------------------------------

func _build_orbit_camera() -> void:
	_orbit_cam = Camera3D.new()
	_orbit_cam.fov = 70.0
	add_child(_orbit_cam)  # not current yet — the chase cam shows the crash first


# Place the orbit camera on its circle around the car at the current angle (mirrors
# StartLine._update_orbit so the wreck orbit matches the start-line reveal).
func _update_orbit() -> void:
	if _orbit_cam == null:
		return
	var cfg := _cfg()
	var center := _player.global_position if _player != null else Vector3.ZERO
	center += Vector3.UP * (cfg.start_orbit_height * 0.4)
	var eye := center + Vector3(
		cos(_orbit_angle) * cfg.start_orbit_radius,
		cfg.start_orbit_height,
		sin(_orbit_angle) * cfg.start_orbit_radius)
	_orbit_cam.look_at_from_position(eye, center, Vector3.UP)


# --- Overlay (flat "car wrecked" menu over the orbiting scene) ---------------

func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 6  # above the HUD (2) / mobile (3) / start-line overlay (5)
	_overlay.visible = false  # shown when the crash settles and the orbit takes over
	add_child(_overlay)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UITheme.PANEL_DIM
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 10)
	_overlay.add_child(root)

	var heading := Label.new()
	heading.text = "CAR WRECKED"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 40)
	heading.add_theme_color_override("font_color", UITheme.RED)
	root.add_child(heading)

	var body := Label.new()
	body.text = "Your car is too damaged to continue — the rally is a DNF.\nIt's kept in your garage: repair it with a Repair Kit to race it again."
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_theme_font_size_override("font_size", 16)
	body.modulate = Color(1, 1, 1, 0.9)
	root.add_child(body)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	root.add_child(spacer)

	_return_button = Button.new()
	_return_button.text = "Return to HQ"
	_return_button.focus_mode = Control.FOCUS_NONE
	_return_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_return_button.custom_minimum_size = Vector2(220, 52)
	_return_button.pressed.connect(_on_return_pressed)
	root.add_child(_return_button)

	UITheme.enforce(self)  # house rules: uppercase + one font size + button height


func _on_return_pressed() -> void:
	return_requested.emit()


# --- Sequence ----------------------------------------------------------------

func _process(delta: float) -> void:
	match _seq:
		Seq.CRASHING:
			_settle_t += delta
			# Wait for the wreck to come to rest (a minimum beat first), with a safety
			# cap so it can't wait forever if the car never fully settles.
			var settled := _settle_t >= SETTLE_MIN_SECONDS and _player_stopped()
			if settled or _settle_t >= _cfg().wreck_settle_max_seconds:
				_enter_orbit()
		Seq.ORBIT:
			_orbit_angle += delta * _cfg().start_orbit_speed
			_update_orbit()


# Hand the camera to the slow orbit, hide the driving UI and reveal the menu.
func _enter_orbit() -> void:
	_seq = Seq.ORBIT
	_update_orbit()
	if _orbit_cam != null:
		_orbit_cam.current = true
	if _hud != null:
		_hud.visible = false
	if _mobile != null:
		_mobile.visible = false
	if _overlay != null:
		_overlay.visible = true


# Whether the wrecked car has effectively come to rest. Non-Car players (test stubs
# without physics) read as stopped immediately.
func _player_stopped() -> bool:
	if not (_player is VehicleBody3D):
		return true
	return (_player as VehicleBody3D).linear_velocity.length() < STOP_SPEED_EPS


func _unhandled_input(event: InputEvent) -> void:
	# Once the menu is up, ENTER / a tap also returns to HQ (matches the start line).
	if _seq != Seq.ORBIT:
		return
	if event.is_action_pressed("menu_select") \
			or (event is InputEventScreenTouch and event.pressed) \
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		_on_return_pressed()


# --- Readouts (for tests) ----------------------------------------------------

func sequence_phase() -> int:
	return _seq

class_name StartLine
extends Node3D
# The pre-event start-line sequence (todo/menus.md location 2) — the cinematic
# moment between picking a car in HQ and the 3·2·1·GO countdown. It runs inside the
# live run scene (main.tscn) once the world is built and a RallySession is active,
# while the car is held locked by the StageManager's STAGING phase:
#
#   1. REVEAL  — a flat overlay shows the "TIMES TO BEAT" (the top three rivals'
#      stage times for this event, with each driver's name and the car they drove)
#      while an orbit camera circles the car, which is queued between a LEADER car
#      ahead and a TRAILING car behind. The driving HUD is hidden. The player
#      launches with the Start button, menu_select or a tap.
#   2. LAUNCH  — the leader "drives off" ahead and the trailing car scoots up toward
#      the line over start_drive_off_seconds.
#   3. FADE    — the screen fades to black; at full black the camera hands back to
#      the chase camera, the driving UI returns and StageManager.begin_countdown()
#      starts the countdown; then it fades back in.
#
# Created and wired by world.gd (session runs only). A plain dev boot of main.tscn
# never builds a StartLine and the StageManager goes straight to the countdown.

const CAR_SCENE := preload("res://car.tscn")

# Speed (m/s) below which the player counts as stopped at the line — the fade to the
# chase cam waits for this so the transition never happens while the car is rolling.
const STOP_SPEED_EPS := 0.4

# Sequence phases. ORBIT waits for the launch; the rest are time-driven in _process.
enum Seq { ORBIT, DRIVE_OFF, FADE_OUT, FADE_IN, DONE }

var _seq: int = Seq.ORBIT
var _seq_t := 0.0          # seconds into the current timed phase
var _orbit_angle := 0.0    # accumulated orbit camera angle (rad)
var _launched := false

# Refs handed in by world.gd (camera/HUD optional so tests can omit them).
var _player: Node3D
var _stage_manager: Node
var _chase_camera: Camera3D
var _hud: CanvasLayer
var _mobile: CanvasLayer

# Nodes this scene owns.
var _orbit_cam: Camera3D
var _overlay: CanvasLayer
var _start_button: Button
var _leaders_box: VBoxContainer
var _leader_rows: Array[Label] = []   # one row per shown rival (or a single dash)
var _subtitle_label: Label
var _fade: CanvasLayer
var _fade_rect: ColorRect
var _leader: Node3D     # the car ahead — drives off on launch
var _trailer: Node3D    # the car behind — rolls up on launch

# The player's start pose, captured at setup (the queue lays out around it). The
# player is staged half a gap behind this line and rolls UP to it on launch.
var _start_xform: Transform3D
var _player_staged := false   # true once the player is scripted for the roll-up
var _player_auto_was := false # the player's gearbox auto flag, restored at hand-off


func _cfg() -> GameConfig:
	return Config.data


# Build the start-line sequence around the fielded car. `leaders` is the top-three
# rivals to beat for this event (RallySession.current_event_leaders()), each
# { name, car_name, time_ms }; `terrain` (optional) sits the queue cars on the
# ground; `chase_camera` / `hud` / `mobile` are handed back at the fade.
func setup(player: Node3D, terrain: Node, stage_manager: Node, rally: Dictionary,
		event_index: int, leaders: Array, chase_camera: Camera3D = null,
		hud: CanvasLayer = null, mobile: CanvasLayer = null) -> void:
	_player = player
	_stage_manager = stage_manager
	_chase_camera = chase_camera
	_hud = hud
	_mobile = mobile
	_start_xform = player.global_transform
	# Hide the driving UI; the reveal is camera-only until the fade hands it back.
	if _hud != null:
		_hud.visible = false
	if _mobile != null:
		_mobile.visible = false
	_build_orbit_camera()
	_build_overlay(rally, event_index, leaders)
	_build_fade()
	_stage_player(terrain)
	_spawn_queue(rally, terrain)
	_update_orbit()


# Roll-up start: stage the player half a gap BEHIND the line so it rolls up to the
# line with the field (instead of sitting still and getting rear-ended). Scripted +
# axis-locked like the queue cars while staging; cleared at the hand-off so the run
# drives normally. No-op for a non-Car player (test stubs without the hook).
func _stage_player(terrain: Node) -> void:
	if not (_player is VehicleBody3D) or not ("ai_controlled" in _player):
		return
	var setback := _cfg().start_queue_gap * 0.5
	_player.global_transform = Transform3D(_start_xform.basis, _ground(_start_xform * Vector3(0, 0, setback), terrain))
	_player.ai_controlled = true
	_player.ai_throttle = 0.0
	_player.ai_steer = 0.0
	_player.ai_handbrake = false
	_player.axis_lock_linear_x = true
	_player.axis_lock_angular_y = true
	if "drivetrain" in _player and _player.drivetrain != null and _player.drivetrain.engine != null:
		_player_auto_was = _player.drivetrain.engine.auto
		_player.drivetrain.engine.auto = true  # so throttle pulls forward; restored at hand-off
	_player_staged = true


# --- Orbit camera ------------------------------------------------------------

func _build_orbit_camera() -> void:
	_orbit_cam = Camera3D.new()
	_orbit_cam.fov = 70.0
	_orbit_cam.current = true  # take over from the chase camera for the reveal
	add_child(_orbit_cam)


# Place the orbit camera on its circle around the car at the current angle.
func _update_orbit() -> void:
	if _orbit_cam == null:
		return
	var cfg := _cfg()
	var center := _player.global_position if _player != null else _start_xform.origin
	center += Vector3.UP * (cfg.start_orbit_height * 0.4)
	var eye := center + Vector3(
		cos(_orbit_angle) * cfg.start_orbit_radius,
		cfg.start_orbit_height,
		sin(_orbit_angle) * cfg.start_orbit_radius)
	_orbit_cam.look_at_from_position(eye, center, Vector3.UP)


# --- Overlay (flat "times to beat" card over the orbiting scene) -------------

func _build_overlay(rally: Dictionary, event_index: int, leaders: Array) -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 5  # above the HUD (2) / mobile (3), below the fade
	add_child(_overlay)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 6)
	_overlay.add_child(root)

	var heading := Label.new()
	heading.text = "TIMES TO BEAT"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 20)
	heading.modulate = Color(1, 1, 1, 0.85)
	root.add_child(heading)

	# Top-three rivals for this event: rank, driver, car and time. The leader (the
	# actual time to beat) is highlighted; if no rival set a time yet, a single dash
	# stands in.
	_leaders_box = VBoxContainer.new()
	_leaders_box.add_theme_constant_override("separation", 2)
	root.add_child(_leaders_box)
	_leader_rows = []
	if leaders.is_empty():
		var dash := _leader_row_label("—")
		dash.add_theme_font_size_override("font_size", 44)
		dash.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
		_leaders_box.add_child(dash)
		_leader_rows.append(dash)
	else:
		for i in leaders.size():
			var row := _leader_row_label(_format_leader(i + 1, leaders[i]))
			if i == 0:
				row.add_theme_font_size_override("font_size", 30)
				row.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
			else:
				row.add_theme_font_size_override("font_size", 22)
				row.modulate = Color(1, 1, 1, 0.9)
			_leaders_box.add_child(row)
			_leader_rows.append(row)

	var total: int = rally.get("events", []).size()
	if total <= 0:
		total = RallySession.EVENTS_PER_RALLY
	_subtitle_label = Label.new()
	_subtitle_label.text = "%s — Event %d of %d" % [String(rally.get("name", "Rally")), event_index + 1, total]
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.add_theme_font_size_override("font_size", 16)
	root.add_child(_subtitle_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	root.add_child(spacer)

	_start_button = Button.new()
	_start_button.text = "Start"
	_start_button.focus_mode = Control.FOCUS_NONE
	_start_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_start_button.custom_minimum_size = Vector2(220, 52)
	_start_button.pressed.connect(launch)
	root.add_child(_start_button)

	var hint := Label.new()
	hint.text = "Press ENTER or tap to launch"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	hint.modulate = Color(0.7, 0.9, 1.0)
	root.add_child(hint)


# A centered leaderboard row label (styling applied by the caller).
func _leader_row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


# One rival row: "P1   Rival 3 — Porsche 911 — 1:15.43". The car is dropped when
# unknown (empty), leaving "P1   Rival 3 — 1:15.43".
func _format_leader(pos: int, entry: Dictionary) -> String:
	var car := String(entry.get("car_name", ""))
	var car_part := " — %s" % car if car != "" else ""
	return "P%d   %s%s — %s" % [
		pos, String(entry.get("name", "Rival")), car_part, _format_ms(int(entry.get("time_ms", -1)))]


# m:ss.cc, or an em dash when there's no rival time to show.
func _format_ms(ms: int) -> String:
	if ms < 0:
		return "—"
	var seconds := ms / 1000.0
	var minutes := int(seconds / 60.0)
	var rem := seconds - minutes * 60.0
	return "%d:%05.2f" % [minutes, rem]


# --- Fade-to-black overlay ---------------------------------------------------

func _build_fade() -> void:
	_fade = CanvasLayer.new()
	_fade.layer = 100  # above everything, so the transition fully covers the screen
	add_child(_fade)
	_fade_rect = ColorRect.new()
	_fade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade_rect.color = Color(0, 0, 0, 0)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.add_child(_fade_rect)


# --- Queue cars (leader ahead, trailer behind) -------------------------------

# Spawn the two atmosphere cars that bookend the player in the start queue. They are
# LIVE, scripted, silenced car props (so they drive off with real suspension load);
# models are picked deterministically from the rally seed so the queue is stable.
func _spawn_queue(rally: Dictionary, terrain: Node) -> void:
	var cfg := _cfg()
	var gap := cfg.start_queue_gap
	# Local -Z is the car's nose. Leader is ahead of the line (negative Z); the player
	# is staged half a gap behind (see _stage_player), so the trailer sits a full gap
	# behind the player.
	var leader_pos := _ground(_start_xform * Vector3(0, 0, -gap), terrain)
	var trailer_pos := _ground(_start_xform * Vector3(0, 0, gap * 0.5 + gap), terrain)
	var seed_base := _queue_seed(rally)
	_leader = _spawn_prop(seed_base % CarLibrary.CARS.size(), leader_pos)
	_trailer = _spawn_prop((seed_base + 1) % CarLibrary.CARS.size(), trailer_pos)
	# Drive on the terrain, but never shove (or get shoved by) the player or each
	# other — they're flavour, not a real field.
	if _player is PhysicsBody3D:
		for prop in [_leader, _trailer]:
			if prop != null:
				(prop as PhysicsBody3D).add_collision_exception_with(_player)
	if _leader != null and _trailer != null:
		(_leader as PhysicsBody3D).add_collision_exception_with(_trailer)


# Drop a world point onto the terrain, keeping the player's ride height above it.
func _ground(pos: Vector3, terrain: Node) -> Vector3:
	if terrain != null and terrain.has_method("height_at"):
		var ride: float = _start_xform.origin.y - terrain.height_at(_start_xform.origin.x, _start_xform.origin.z)
		pos.y = terrain.height_at(pos.x, pos.z) + ride
	return pos


# A live, scripted, silent car prop facing the start heading, with its own mesh
# copies so a mixed queue keeps each body at its true size (car.tscn shares mesh
# sub-resources between instances). It runs full physics (real suspension load /
# squat) but reads scripted throttle/steer instead of player Input, and is axis-
# locked to a straight line so it can't veer (the start heading is world -Z, so
# lock lateral world-X + yaw world-Y; suspension world-Y and pitch world-X stay free).
func _spawn_prop(model_index: int, pos: Vector3) -> Node3D:
	var car := CAR_SCENE.instantiate()
	add_child(car)
	if car.has_method("apply_car"):
		car.apply_car(model_index)
	_dup_meshes(car)
	car.global_transform = Transform3D(_start_xform.basis, pos)
	car.freeze = false
	car.ai_controlled = true
	car.ai_throttle = 0.0
	car.ai_steer = 0.0
	car.ai_handbrake = false
	car.axis_lock_linear_x = true
	car.axis_lock_angular_y = true
	# Auto gearbox so throttle pulls away without manual shifting.
	if car.drivetrain != null and car.drivetrain.engine != null:
		car.drivetrain.engine.auto = true
	# Silence its engine — no audio clutter from the atmosphere cars.
	var audio := car.get_node_or_null("EngineAudio")
	if audio != null:
		audio.process_mode = Node.PROCESS_MODE_DISABLED
		if audio is AudioStreamPlayer:
			audio.playing = false
			audio.volume_db = -80.0
	return car


func _dup_meshes(car: Node) -> void:
	for mi in car.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh != null:
			m.mesh = m.mesh.duplicate()


# Deterministic per-rally seed for the queue line-up (stable across re-entries).
func _queue_seed(rally: Dictionary) -> int:
	var events: Array = rally.get("events", [])
	if not events.is_empty():
		return int(events[0].get("seed", 0))
	return 0


# --- Sequence ----------------------------------------------------------------

func _process(delta: float) -> void:
	match _seq:
		Seq.ORBIT:
			_advance_orbit(delta)
		Seq.DRIVE_OFF:
			_advance_orbit(delta)
			_seq_t += delta
			var cfg := _cfg()
			# Staggered roll-off: the leader pulls away first (full throttle, set at
			# launch); the player rolls up one stagger later; the trailer one stagger
			# after that. Each holds throttle for the scoot window then eases off so
			# the parking brake settles it.
			var stagger := cfg.start_queue_stagger_seconds
			var scoot := cfg.start_trailer_scoot_seconds
			if _player_staged and _player is VehicleBody3D and "ai_controlled" in _player:
				_player.ai_throttle = 1.0 if (_seq_t >= stagger and _seq_t < stagger + scoot) else 0.0
			if _trailer != null and is_instance_valid(_trailer):
				_trailer.ai_throttle = 1.0 if (_seq_t >= 2.0 * stagger and _seq_t < 2.0 * stagger + scoot) else 0.0
			# Don't cut to the chase cam until the player has finished rolling up AND
			# come to a COMPLETE stop, so the transition never happens mid-roll;
			# start_drive_off_seconds is a safety cap so it can't wait forever.
			var rolled := _seq_t >= stagger + scoot
			if (rolled and _player_stopped()) or _seq_t >= cfg.start_drive_off_seconds:
				_seq = Seq.FADE_OUT
				_seq_t = 0.0
		Seq.FADE_OUT:
			_seq_t += delta
			var fade := maxf(_cfg().start_fade_seconds, 0.0001)
			_fade_rect.color.a = clampf(_seq_t / fade, 0.0, 1.0)
			if _seq_t >= _cfg().start_fade_seconds:
				_handoff()
				_seq = Seq.FADE_IN
				_seq_t = 0.0
		Seq.FADE_IN:
			_seq_t += delta
			var fade := maxf(_cfg().start_fade_seconds, 0.0001)
			_fade_rect.color.a = clampf(1.0 - _seq_t / fade, 0.0, 1.0)
			if _seq_t >= _cfg().start_fade_seconds:
				_fade.visible = false
				_seq = Seq.DONE
		Seq.DONE:
			pass


func _advance_orbit(delta: float) -> void:
	_orbit_angle += delta * _cfg().start_orbit_speed
	_update_orbit()


# Whether the player has effectively stopped (settled at the line). Non-Car players
# (test stubs without physics) read as stopped.
func _player_stopped() -> bool:
	if not (_player is VehicleBody3D):
		return true
	return (_player as VehicleBody3D).linear_velocity.length() < STOP_SPEED_EPS


func _unhandled_input(event: InputEvent) -> void:
	if _seq != Seq.ORBIT:
		return
	if event.is_action_pressed("menu_select") \
			or (event is InputEventScreenTouch and event.pressed) \
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		launch()


# Begin the launch animation (leader drives off, field scoots up). Idempotent — only
# fires from the waiting ORBIT phase, so a second tap during the sequence is ignored.
func launch() -> void:
	if _launched or _seq != Seq.ORBIT:
		return
	_launched = true
	if _overlay != null:
		_overlay.visible = false
	# The leader goes first and keeps pulling away; the player and trailer roll up on
	# a stagger (see _process DRIVE_OFF).
	if _leader != null and is_instance_valid(_leader):
		_leader.ai_throttle = 1.0
	_seq = Seq.DRIVE_OFF
	_seq_t = 0.0


# At full black: hand the camera back to the chase camera, restore the driving UI,
# and start the countdown. (The StageManager has been waiting in STAGING.)
func _handoff() -> void:
	if _orbit_cam != null:
		_orbit_cam.current = false
	if _chase_camera != null:
		_chase_camera.current = true
	if _hud != null:
		_hud.visible = Config.data.hud_enabled
	if _mobile != null:
		_mobile.visible = true
	_release_player()  # hand the player back to normal driving for the run
	_despawn_queue()   # gone under cover of the black, so they cost nothing during the run
	if _stage_manager != null and _stage_manager.has_method("begin_countdown"):
		_stage_manager.begin_countdown()


# Undo the roll-up scripting so the run drives normally: clear the AI override and
# axis locks (else the player couldn't turn) and restore the gearbox auto flag. The
# StageManager keeps controls_locked through the countdown, so the car holds at the
# line until GO.
func _release_player() -> void:
	if not _player_staged or not (_player is VehicleBody3D) or not ("ai_controlled" in _player):
		return
	_player.ai_controlled = false
	_player.ai_throttle = 0.0
	_player.ai_steer = 0.0
	_player.axis_lock_linear_x = false
	_player.axis_lock_angular_y = false
	if "drivetrain" in _player and _player.drivetrain != null and _player.drivetrain.engine != null:
		_player.drivetrain.engine.auto = _player_auto_was
	_player_staged = false


# Free the queue cars (they've driven off / rolled up and the screen is black).
func _despawn_queue() -> void:
	for prop in [_leader, _trailer]:
		if prop != null and is_instance_valid(prop):
			prop.queue_free()
	_leader = null
	_trailer = null


# --- Readouts (for tests) ----------------------------------------------------

func sequence_phase() -> int:
	return _seq


func has_launched() -> bool:
	return _launched


func queue_count() -> int:
	var n := 0
	if _leader != null:
		n += 1
	if _trailer != null:
		n += 1
	return n

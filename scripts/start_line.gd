class_name StartLine
extends Node3D
# The pre-event start-line sequence (todo/menus.md location 2) — the cinematic
# moment between picking a car in HQ and the 3·2·1·GO countdown. It runs inside the
# live run scene (main.tscn) once the world is built and a RallySession is active,
# while the car is held locked by the StageManager's STAGING phase:
#
#   1. MENU     — black house-style panels offer Start / Tune Car / Upgrades under a
#      rally/event header, while an orbit camera idles on the player's car. The player
#      launches with the Start button, menu_select or a tap (eligibility gates first).
#   2. FLY_IN   — the camera flies from the orbit pose to a fixed low 3/4 shot in front
#      of the start line, facing the car on the line, and holds there.
#   3. REVEAL   — the three cars ahead of the player are the REAL top-three rivals for
#      this event (their actual cars). A card shows the front car's driver, the car and
#      the time to beat, with a Next button. Next sends that car off the line and scoots
#      the rest up one gap; repeat P1 → P2 → P3 until the player is on the line.
#   4. FADE     — the screen fades to black; at full black the camera hands back to the
#      player's SELECTED camera (via the CameraManager), the driving UI returns and
#      StageManager.begin_countdown() starts the countdown; then it fades back in.
#
# Created and wired by world.gd (session runs only). A plain dev boot of main.tscn
# never builds a StartLine and the StageManager goes straight to the countdown.

const CAR_SCENE := preload("res://car.tscn")

# How many cars line up ahead of the player (the real top-N rivals). Fewer if the
# field can't field this many (dev/test harnesses pass an empty leaders list).
const GRID_AHEAD := 3
# A departed car is despawned once it has driven this far past the start line (down
# the lead-in, before the first corner), so it never fights its axis-lock into a bend.

# Sequence phases. MENU/REVEAL wait for a press; the rest are time-driven in _process.
enum Seq { MENU, FLY_IN, REVEAL, DRIVE_OFF, FADE_OUT, FADE_IN, DONE }

var _seq: int = Seq.MENU
var _seq_t := 0.0          # seconds into the current timed phase
var _orbit_angle := 0.0    # accumulated orbit camera angle (rad), the MENU idle
var _launched := false     # Start pressed (past the eligibility gates)
var _underpower_acked := false   # player confirmed the "underpowered" start warning

# Refs handed in by world.gd (camera/HUD optional so tests can omit them).
var _player: Node3D
var _terrain: Node
var _stage_manager: Node
var _camera_manager: CameraManager
var _hud: CanvasLayer
var _mobile: CanvasLayer

# Nodes this scene owns.
var _orbit_cam: Camera3D
var _overlay: CanvasLayer
var _start_button: Button
var _tune_button: Button
var _tune_layer: CanvasLayer         # the pre-race tuning overlay (built lazily)
var _tune_panel: TuningPanel         # the shared handling-axis tuning sliders (detune is in Upgrades)
var _upgrades_button: Button
var _upgrades_layer: CanvasLayer     # the pre-race upgrades overlay (built lazily)
var _upgrades_menu: UpgradesMenu     # the shared upgrades menu (same as the HQ garage)
var _upgrades_back: Button           # the upgrades overlay's Back/Done button (p/w-gated)
var _menu_last_back: Button          # back button _build_menu_overlay just created
var _rally: Dictionary = {}          # this event's rally (for the Tune Car detune cap)
var _subtitle_label: Label
var _fade: CanvasLayer
var _fade_rect: ColorRect

# The reveal card (shown per opponent during REVEAL).
var _reveal_overlay: CanvasLayer
var _reveal_name_label: Label
var _reveal_time_label: Label
var _next_button: Button

# The leaders (top-three rivals for this event), each { name, car_id, car_name, time_ms }.
var _leaders: Array = []
# The grid, front-first: the opponent cars ahead of the player followed by the player
# itself as the tail. On each Next the front car drives off and is removed; the rest
# (incl. the player) roll up one slot. When only the player remains, the fade begins.
var _grid: Array[Node3D] = []
var _grid_car_ids: Array[String] = []   # ids of the opponent grid cars (test readout)
var _departed: Array[Node3D] = []        # cars driving off, despawned past the line
var _reveal_index := 0                   # which leader is currently on the line

# Camera fly: the orbit pose captured when Start is pressed, and the anchored target.
var _fly_from := Transform3D.IDENTITY
var _fly_from_fov := 70.0
var _anchor_xform := Transform3D.IDENTITY

# The player's start pose, captured at setup (the grid lays out around it). The player
# is staged GRID_AHEAD gaps behind this line and rolls up to it as the field departs.
var _start_xform: Transform3D
var _player_staged := false   # true once the player is scripted for the roll-up
var _player_auto_was := false # the player's gearbox auto flag, restored at hand-off


func _cfg() -> GameConfig:
	return Config.data


# Build the start-line sequence around the fielded car. `leaders` is the top-three
# rivals to beat for this event (RallySession.current_event_leaders()), each
# { name, car_id, car_name, time_ms }; `terrain` (optional) sits the grid cars on the
# ground; `camera_manager` / `hud` / `mobile` are handed back at the fade (the
# camera via the manager, so the player's chosen mode — not always chase — resumes).
func setup(player: Node3D, terrain: Node, stage_manager: Node, rally: Dictionary,
		event_index: int, leaders: Array, camera_manager: CameraManager = null,
		hud: CanvasLayer = null, mobile: CanvasLayer = null) -> void:
	_player = player
	_terrain = terrain
	_rally = rally  # kept so Tune Car can cap detune at the rally's qualifying power
	_stage_manager = stage_manager
	_camera_manager = camera_manager
	_hud = hud
	_mobile = mobile
	_leaders = leaders
	_start_xform = player.global_transform
	# Seat the start-line cars a small clearance ABOVE the road at spawn so they settle
	# onto their wheels instead of spawning clipped into the ground. Anchoring it on
	# _start_xform here cascades everywhere: the staged player and the grid props read
	# their ride height off it (via _ground), and the countdown pose is reset_to it at
	# the hand-off — so the player is clear before AND during the countdown.
	if terrain != null and terrain.has_method("height_at"):
		_start_xform.origin.y = terrain.height_at(_start_xform.origin.x, _start_xform.origin.z) + _cfg().start_spawn_clearance
	# Hide the driving UI; the reveal is camera-only until the fade hands it back.
	if _hud != null:
		_hud.visible = false
	if _mobile != null:
		_mobile.visible = false
	_build_orbit_camera()
	_build_overlay(rally, event_index)
	_build_reveal_overlay()
	_build_fade()
	_stage_player(terrain)
	_spawn_grid(rally, terrain)
	_update_orbit()


# How many opponent cars actually line up ahead of the player: the top three, or fewer
# if the field is short (dev/test harnesses pass an empty leaders list).
func _grid_ahead_count() -> int:
	return mini(GRID_AHEAD, _leaders.size())


# Roll-up start: stage the player a full grid of gaps BEHIND the line (directly behind
# the last opponent) so it rolls the whole way up as the field departs instead of
# sitting still. Scripted + axis-locked like the grid cars while staging; cleared at the
# hand-off so the run drives normally. No-op for a non-Car player (test stubs).
func _stage_player(terrain: Node) -> void:
	if not (_player is VehicleBody3D) or not ("ai_controlled" in _player):
		return
	var setback := _cfg().start_queue_gap * float(_grid_ahead_count())
	# reset_to (pending teleport) so the staged pose survives the physics server; a bare
	# global_transform write on a VehicleBody3D is discarded (see car.gd reset_to). The
	# test stub has no reset_to, so fall back to the bare write there.
	var staged := Transform3D(_start_xform.basis, _ground(_start_xform * Vector3(0, 0, setback), terrain))
	if _player.has_method("reset_to"):
		_player.reset_to(staged)
	else:
		_player.global_transform = staged
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


# --- Camera (orbit idle → fly-in → anchored reveal shot) ---------------------

func _build_orbit_camera() -> void:
	_orbit_cam = Camera3D.new()
	_orbit_cam.fov = _cfg().start_orbit_fov
	_orbit_cam.current = true  # take over from the chase camera for the reveal
	add_child(_orbit_cam)


# Place the orbit camera on its idle circle around the car (the MENU phase only).
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


func _advance_orbit(delta: float) -> void:
	_orbit_angle += delta * _cfg().start_orbit_speed
	_update_orbit()


# The fixed low 3/4 shot in front of the start line, looking back at the car on the
# line. Local −Z is down the lead-in (ahead of the line), so a negative Z places the
# camera AHEAD of the line; a lateral offset gives the 3/4 angle; a low height keeps it
# close to the ground.
func _compute_anchor() -> Transform3D:
	var cfg := _cfg()
	var eye := _start_xform * Vector3(cfg.start_reveal_cam_side_m, cfg.start_reveal_cam_height_m, -cfg.start_reveal_cam_front_m)
	var look := _start_xform.origin + Vector3.UP * cfg.start_reveal_cam_look_height_m
	return Transform3D(Basis(), eye).looking_at(look, Vector3.UP)


# --- Overlay (MENU: Start / Tune Car / Upgrades) -----------------------------

# The MENU UI follows the design system (UITheme): pure-black, sharp-cornered panels,
# the one house font size, uppercase text. It hugs the TOP (a rally/event header) and
# BOTTOM (the action buttons) of the screen, leaving the centre band clear so the
# orbiting car shows through.
func _build_overlay(rally: Dictionary, event_index: int) -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 5  # above the HUD (2) / mobile (3), below the fade
	add_child(_overlay)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = UITheme.MARGIN
	root.offset_top = UITheme.MARGIN
	root.offset_right = -UITheme.MARGIN
	root.offset_bottom = -UITheme.MARGIN
	root.add_theme_constant_override("separation", UITheme.GAP)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(root)

	# --- TOP card: the rally + event header ----------------------------------
	var top_panel := UITheme.panel(UITheme.PANEL.a)
	top_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.add_child(top_panel)

	var top_box := VBoxContainer.new()
	top_box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	top_panel.add_child(top_box)

	var total: int = rally.get("events", []).size()
	if total <= 0:
		total = RallySession.EVENTS_PER_RALLY
	_subtitle_label = UITheme.title("%s — Event %d of %d" % [String(rally.get("name", "Rally")), event_index + 1, total])
	top_box.add_child(_subtitle_label)

	# --- Clear band: lets the orbiting car show between the cards -------------
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)

	# --- BOTTOM: the launch button + pre-race menus --------------------------
	_start_button = UITheme.button("Start")
	_start_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_start_button.pressed.connect(launch)
	root.add_child(_start_button)

	_tune_button = UITheme.button("Tune Car")
	_tune_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_tune_button.pressed.connect(_open_tune)
	root.add_child(_tune_button)

	_upgrades_button = UITheme.button("Upgrades")
	_upgrades_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_upgrades_button.pressed.connect(_open_upgrades)
	root.add_child(_upgrades_button)

	UITheme.enforce(_overlay)  # house rules: uppercase + one font size + fixed button height
	MenuNav.attach(root, {"first": _start_button})


# --- Reveal card (shown per opponent during REVEAL) --------------------------

# A house-style card at the bottom of the screen naming the front opponent, their car and
# the time to beat, with a Next button to send them off the line. Built once, hidden
# until the first reveal, its text refreshed per opponent.
func _build_reveal_overlay() -> void:
	_reveal_overlay = CanvasLayer.new()
	_reveal_overlay.layer = 5
	_reveal_overlay.visible = false
	add_child(_reveal_overlay)

	# Full-rect column: an expanding spacer (the clear band the car shows through) then the
	# card hugging the bottom edge, so the panel is laid out on-screen rather than
	# overflowing past the bottom.
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = UITheme.MARGIN
	root.offset_top = UITheme.MARGIN
	root.offset_right = -UITheme.MARGIN
	root.offset_bottom = -UITheme.MARGIN
	root.add_theme_constant_override("separation", UITheme.GAP)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_reveal_overlay.add_child(root)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(spacer)

	var panel := UITheme.panel(UITheme.PANEL.a)
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	panel.add_child(box)

	_reveal_name_label = UITheme.label("", "ink")
	_reveal_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_reveal_name_label)

	_reveal_time_label = UITheme.label("", "gold")
	_reveal_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_reveal_time_label)

	_next_button = UITheme.button("Next")
	_next_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_next_button.pressed.connect(next_car)
	box.add_child(_next_button)

	UITheme.enforce(_reveal_overlay)


# Show the reveal card for the opponent currently on the line (`_reveal_index`). The
# name row is "P{n}  Driver — Car"; the time row is the gold "TIME TO BEAT  m:ss.cc".
func _show_reveal_card() -> void:
	if _reveal_index >= _leaders.size():
		return
	var e: Dictionary = _leaders[_reveal_index]
	var car := String(e.get("car_name", ""))
	var car_part := " — %s" % car if car != "" else ""
	_reveal_name_label.text = "P%d   %s%s" % [_reveal_index + 1, String(e.get("name", "Rival")), car_part]
	_reveal_time_label.text = "TIME TO BEAT   %s" % UITheme.format_time(int(e.get("time_ms", -1)), "—")
	UITheme.enforce(_reveal_overlay)  # re-uppercase the freshly-set text
	_reveal_overlay.visible = true
	get_viewport().gui_release_focus()
	MenuNav.attach(_reveal_overlay.get_child(0), {"first": _next_button})
	_next_button.grab_focus.call_deferred()


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


# --- Grid cars (the real top-three rivals ahead of the player) ---------------

# Spawn the opponent cars that line up ahead of the player: the real top-N rivals for
# this event, each in its ACTUAL car. They are LIVE, scripted, silenced car props (so
# they load their suspension as they drive off / roll up). Front-first: grid[0] sits on
# the line and drives off first.
func _spawn_grid(rally: Dictionary, terrain: Node) -> void:
	_grid = []
	_grid_car_ids = []
	var gap := _cfg().start_queue_gap
	var n := _grid_ahead_count()
	# Each prop's apply_car() mutates the SHARED global Config.data (gearbox, mass,
	# grip, …). The player is already fielded, so letting a prop's spec leak into
	# Config.data would corrupt the player's live drivetrain. Snapshot the player's
	# config and restore it after the props are built.
	var player_cfg: GameConfig = Config.data.duplicate(true)
	for i in n:
		var car_id := String((_leaders[i] as Dictionary).get("car_id", ""))
		var index := CarLibrary.index_of(car_id)
		if index < 0:
			continue  # unknown id (fixture/synthetic leaders) — skip rather than spawn a bogus car
		var pos := _ground(_start_xform * Vector3(0, 0, gap * float(i)), terrain)
		var car := _spawn_prop(index, pos)
		_grid.append(car)
		_grid_car_ids.append(car_id)
	Config.data = player_cfg
	# The player is the tail of the grid — it rolls up as the opponents depart.
	if _player != null:
		_grid.append(_player)
	# Drive on the terrain, but never shove (or get shoved by) the player or each other.
	if _player is PhysicsBody3D:
		for car in _grid:
			if car != _player and car is PhysicsBody3D:
				(car as PhysicsBody3D).add_collision_exception_with(_player)
	for a in _grid.size():
		for b in range(a + 1, _grid.size()):
			if _grid[a] is PhysicsBody3D and _grid[b] is PhysicsBody3D:
				(_grid[a] as PhysicsBody3D).add_collision_exception_with(_grid[b])


# Drop a world point onto the terrain, keeping the player's ride height above it.
func _ground(pos: Vector3, terrain: Node) -> Vector3:
	if terrain != null and terrain.has_method("height_at"):
		var ride: float = _start_xform.origin.y - terrain.height_at(_start_xform.origin.x, _start_xform.origin.z)
		pos.y = terrain.height_at(pos.x, pos.z) + ride
	return pos


# A live, scripted, silent car prop facing the start heading. Runs full physics but
# reads scripted throttle/steer instead of player Input, axis-locked to a straight line
# so it can't veer (start heading is world −Z, so lock lateral world-X + yaw world-Y).
func _spawn_prop(model_index: int, pos: Vector3) -> Node3D:
	var car := CAR_SCENE.instantiate()
	add_child(car)
	if car.has_method("apply_car"):
		# Isolate this prop's config so its reshape can't clobber the player car's
		# engine/gearbox in the shared global Config.data (see car.gd `config`).
		car.use_isolated_config()
		car.apply_car(model_index)
	# Place via reset_to (the pending-teleport path), NOT a bare global_transform write:
	# car._ready() captures its spawn pose at ADD-CHILD time (the origin), and a plain
	# global_transform write on a VehicleBody3D is discarded by the physics server (see
	# car.gd reset_to), so every prop would otherwise snap back to the origin and stack.
	var place := Transform3D(_start_xform.basis, pos)
	if car.has_method("reset_to"):
		car.reset_to(place)
	else:
		car.global_transform = place
	car.freeze = false
	car.ai_controlled = true
	car.ai_throttle = 0.0
	car.ai_steer = 0.0
	car.ai_handbrake = false
	car.axis_lock_linear_x = true
	car.axis_lock_angular_y = true
	if car.drivetrain != null and car.drivetrain.engine != null:
		car.drivetrain.engine.auto = true  # auto box so throttle pulls away
	# Silence its engine — no audio clutter from the atmosphere cars.
	var audio := car.get_node_or_null("EngineAudio")
	if audio != null:
		audio.process_mode = Node.PROCESS_MODE_DISABLED
		if audio is AudioStreamPlayer:
			audio.playing = false
			audio.volume_db = -80.0
	return car


# --- Sequence ----------------------------------------------------------------

func _process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_process(delta)
	PerfLog.track(&"start_line", Time.get_ticks_usec() - __t)


func _timed_process(delta: float) -> void:
	match _seq:
		Seq.MENU:
			_advance_orbit(delta)
		Seq.FLY_IN:
			_seq_t += delta
			var fly := maxf(_cfg().start_reveal_fly_seconds, 0.0001)
			var s := smoothstep(0.0, 1.0, clampf(_seq_t / fly, 0.0, 1.0))
			_orbit_cam.global_transform = Transform3D(
				_fly_from.basis.slerp(_anchor_xform.basis, s),
				_fly_from.origin.lerp(_anchor_xform.origin, s))
			_orbit_cam.fov = lerpf(_fly_from_fov, _cfg().start_reveal_cam_fov, s)
			if _seq_t >= fly:
				_orbit_cam.global_transform = _anchor_xform
				_orbit_cam.fov = _cfg().start_reveal_cam_fov
				_enter_reveal()
		Seq.REVEAL:
			pass  # waits for Next (or a tap)
		Seq.DRIVE_OFF:
			_seq_t += delta
			# Roll every remaining grid car up to its slot (front-first: grid[i] → slot i).
			for i in _grid.size():
				_roll_car_to(_grid[i], _ground(_start_xform * Vector3(0, 0, _cfg().start_queue_gap * float(i)), _terrain))
			_prune_departed()
			# Settle once the front car (or the player, on the final scoot) has stopped on
			# its slot; start_drive_off_seconds is a safety cap.
			var rolled := _seq_t >= _cfg().start_trailer_scoot_seconds
			var front: Node3D = _grid[0] if not _grid.is_empty() else null
			if (rolled and _car_stopped(front)) or _seq_t >= _cfg().start_drive_off_seconds:
				if front == _player or front == null:
					_seq = Seq.FADE_OUT
				else:
					_enter_reveal()
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


# Enter the REVEAL phase for the opponent now on the line: show the card and wait.
func _enter_reveal() -> void:
	_seq = Seq.REVEAL
	_seq_t = 0.0
	_show_reveal_card()


# Roll a scripted car UP TO `target` and brake to a stop ON it, instead of flooring it
# and coasting past. Drives forward while well behind, coasts into a speed-aware brake
# point, then brakes+holds — easing to a halt at it.
func _roll_car_to(car, target: Vector3) -> void:
	if car == null or not is_instance_valid(car) or not ("ai_controlled" in car):
		return
	var cfg := _cfg()
	var fwd := (-_start_xform.basis.z).normalized()
	var dist: float = (target - car.global_position).dot(fwd)
	var v: float = car.linear_velocity.length()
	var brake_dist: float = v * v / cfg.start_roll_decel_divisor + cfg.start_roll_brake_margin_m
	if dist <= brake_dist:
		# On/at the target: brake to a stop, then hold on the handbrake. Cut the brake
		# pedal once nearly stopped so the auto box doesn't grab reverse against the hold.
		car.ai_throttle = -1.0 if v > cfg.start_roll_creep_speed else 0.0
		car.ai_handbrake = true
	elif dist > brake_dist + cfg.start_roll_coast_band_m:
		car.ai_throttle = 1.0    # well behind: roll up
		car.ai_handbrake = false
	else:
		car.ai_throttle = 0.0    # coast into the brake point
		car.ai_handbrake = false


# Whether a car has effectively stopped (settled on its slot). Non-VehicleBody3D cars
# (test stubs without physics) read as stopped so headless flows don't hang.
func _car_stopped(car: Node3D) -> bool:
	if not (car is VehicleBody3D):
		return true
	return (car as VehicleBody3D).linear_velocity.length() < _cfg().start_stop_speed_eps


# Despawn departed cars once they've driven past the start line down the lead-in (before
# the first corner), so they never fight their axis-lock into a bend and cost nothing.
func _prune_departed() -> void:
	var margin := _cfg().start_lead_in_ahead_m
	var kept: Array[Node3D] = []
	for car in _departed:
		if car == null or not is_instance_valid(car):
			continue
		var local := _start_xform.affine_inverse() * car.global_position
		if local.z < -margin:  # driven past the lead-in ahead of the line
			car.queue_free()
		else:
			kept.append(car)
	_departed = kept


func _unhandled_input(event: InputEvent) -> void:
	# A pointer tap advances the waiting phases (MENU launches, REVEAL sends the front
	# car off) for touch/mouse players; keyboard/gamepad use the focused buttons.
	if not ((event is InputEventScreenTouch and event.pressed) \
			or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT)):
		return
	if _seq == Seq.MENU:
		launch()
	elif _seq == Seq.REVEAL:
		next_car()


# Begin the launch: run the eligibility gates, then fly the camera to the reveal shot
# (or, with no opponents to reveal, straight to the fade). Idempotent — only fires from
# the waiting MENU phase, so a second tap during the sequence is ignored.
func launch() -> void:
	if _launched or _seq != Seq.MENU:
		return
	if not _rally.is_empty():
		var owned: Dictionary = Save.get_car(RallySession.car_instance_id())
		if not owned.is_empty():
			var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
			var meta := UpgradeLibrary.effective_meta(owned, entry)
			var reason := RallyLibrary.ineligibility_reason(_rally, meta)
			if reason != "":
				var frac := _rally_qualifying_detune(owned)
				var over_power := frac > 0.0 and frac < 1.0
				if over_power:
					ConfirmPopup.open(self, "Too powerful",
						"Change your upgrades to get under the power-to-weight limit.",
						[ {"label": "Change Upgrades", "callback": _open_upgrades},
						  {"label": "Cancel", "callback": Callable()} ], 0)
				else:
					ConfirmPopup.open(self, "Can't start", reason,
						[ {"label": "Change Upgrades", "callback": _open_upgrades},
						  {"label": "Cancel", "callback": Callable()} ])
				return
			if not _underpower_acked:
				var warn := RallyLibrary.underpower_warning(_rally, meta)
				if warn != "":
					ConfirmPopup.open(self, "Underpowered", "%s\n\nStart anyway?" % warn,
						[ {"label": "Start Anyway", "callback": _confirm_underpower_launch},
						  {"label": "Change Upgrades", "callback": _open_upgrades},
						  {"label": "Cancel", "callback": Callable()} ], 0)
					return
	_launched = true
	if _overlay != null:
		_overlay.visible = false
	if _grid_ahead_count() <= 0:
		# No opponents to reveal — the player is already on the line. Straight to the fade.
		_seq = Seq.FADE_OUT
		_seq_t = 0.0
		return
	# Fly the camera from the (now frozen) orbit pose to the anchored reveal shot.
	_fly_from = _orbit_cam.global_transform
	_fly_from_fov = _orbit_cam.fov
	_anchor_xform = _compute_anchor()
	_seq = Seq.FLY_IN
	_seq_t = 0.0


# Next: send the front car off the line and scoot the rest up one slot. Only from the
# waiting REVEAL phase.
func next_car() -> void:
	if _seq != Seq.REVEAL or _grid.size() <= 1:
		return
	if _reveal_overlay != null:
		_reveal_overlay.visible = false
	var front := _grid.pop_front() as Node3D
	if front != null and "ai_controlled" in front:
		front.ai_throttle = 1.0
		front.ai_handbrake = false
	if front != null:
		_departed.append(front)
	_reveal_index += 1
	_seq = Seq.DRIVE_OFF
	_seq_t = 0.0


# "Start Anyway" from the underpowered warning: remember the ack so it doesn't re-pop,
# then re-run launch (which now passes the warning gate).
func _confirm_underpower_launch() -> void:
	_underpower_acked = true
	launch()


# At full black: hand the camera back to the player's selected mode, restore the driving
# UI, and start the countdown. (The StageManager has been waiting in STAGING.)
func _handoff() -> void:
	if _orbit_cam != null:
		_orbit_cam.current = false
	if _camera_manager != null:
		_camera_manager.activate_current()
	if _hud != null:
		_hud.visible = Config.data.hud_enabled
	if _mobile != null:
		_mobile.visible = true
	_release_player()  # hand the player back to normal driving for the run
	_despawn_grid()    # gone under cover of the black, so they cost nothing during the run
	if _stage_manager != null and _stage_manager.has_method("begin_countdown"):
		_stage_manager.begin_countdown()


# Undo the roll-up scripting so the run drives normally, and snap the player exactly onto
# the start line (hidden by the fade). The StageManager forces the handbrake through the
# countdown, so the car holds at the line until GO.
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
	if _player.has_method("reset_to"):
		_player.reset_to(_start_xform)
	_player_staged = false


# Free every opponent car (grid remainder + departed). The player is never freed.
func _despawn_grid() -> void:
	for car in _grid + _departed:
		if car != null and car != _player and is_instance_valid(car):
			car.queue_free()
	_grid = []
	_departed = []


# --- Pre-race menus (Tune Car / Upgrades) ------------------------------------

# The rally's power-to-weight ceiling for the pre-race tune / upgrades menus (-1 = no
# cap): the restriction's pw_max, or -1 when there's no active rally restriction.
func _pw_limit() -> float:
	var restriction: Dictionary = _rally.get("restriction", {}) if not _rally.is_empty() else {}
	return float(restriction.get("pw_max", -1.0))


# Build a pre-race menu overlay: a CanvasLayer (layer 6, above the start overlay) with a
# centred house panel wrapping a titled `component` and a Back button wired to `on_back`.
func _build_menu_overlay(title: String, component: Control, on_back: Callable, connect_back := true) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 6   # above the start overlay (layer 5)
	add_child(layer)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)
	var panel := UITheme.panel(UITheme.PANEL.a)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UITheme.GAP)
	col.custom_minimum_size = Vector2(520, 0)
	panel.add_child(col)
	col.add_child(UITheme.title(title))
	col.add_child(component)
	var back := UITheme.button("Back")
	back.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	if connect_back:
		back.pressed.connect(on_back)
	col.add_child(back)
	_menu_last_back = back
	UITheme.enforce(layer)
	return layer


# Show a pre-race menu overlay: hide the start overlay, reveal the page, release focus,
# and wire its MenuNav so it's keyboard/gamepad navigable.
func _open_menu(layer: CanvasLayer, first: Control, on_back: Callable) -> void:
	if _overlay != null:
		_overlay.visible = false
	layer.visible = true
	get_viewport().gui_release_focus()
	MenuNav.attach(layer.get_child(0), {"first": first, "on_back": on_back})


# Close a pre-race menu overlay: hide the page, restore the start overlay, re-focus the
# button that opened it.
func _close_menu(layer: CanvasLayer, return_button: Button) -> void:
	if layer != null:
		layer.visible = false
	if _overlay != null:
		_overlay.visible = true
	if return_button != null:
		return_button.grab_focus.call_deferred()


func _open_tune() -> void:
	if _seq != Seq.MENU:
		return
	if _tune_layer == null:
		_build_tune_overlay()
	var owned: Dictionary = Save.get_car(RallySession.car_instance_id())
	_tune_panel.setup(owned, _on_tune_changed.bind(owned))
	_tune_panel.refresh()
	_open_menu(_tune_layer, _tune_panel.first_slider(), _close_tune)


func _close_tune() -> void:
	_close_menu(_tune_layer, _tune_button)


func _build_tune_overlay() -> void:
	_tune_panel = TuningPanel.new()
	_tune_layer = _build_menu_overlay("Tune Car", _tune_panel, _close_tune)


# An edit was made in the tune panel. Re-apply ONLY the tuning to the live config
# (retune) — NOT apply_owned, which would reshape and corrupt the staged body.
func _on_tune_changed(owned: Dictionary) -> void:
	if _player != null and _player.has_method("retune"):
		_player.retune(owned)


func _open_upgrades() -> void:
	if _seq != Seq.MENU:
		return
	if _upgrades_layer == null:
		_build_upgrades_overlay()
	var owned: Dictionary = Save.get_car(RallySession.car_instance_id())
	_upgrades_menu.setup(owned, _on_upgrade_changed, Callable(), _pw_limit())
	_upgrades_menu.bind_close_button(_upgrades_back, _close_upgrades)
	_open_menu(_upgrades_layer, _upgrades_menu.first_control(), _upgrades_menu.request_close)


func _close_upgrades() -> void:
	_close_menu(_upgrades_layer, _upgrades_button)


func _build_upgrades_overlay() -> void:
	_upgrades_menu = UpgradesMenu.new()
	_upgrades_layer = _build_menu_overlay("Upgrades", _upgrades_menu, _close_upgrades, false)
	_upgrades_back = _menu_last_back


# An upgrade edit. Re-field the live car's upgrade state WITHOUT reshaping the staged
# body (refit_upgrades, NOT apply_owned).
func _on_upgrade_changed() -> void:
	if _player != null and _player.has_method("refit_upgrades"):
		_player.refit_upgrades(Save.get_car(RallySession.car_instance_id()))


# The engine-detune fraction at which the car passes the rally's power-to-weight ceiling.
func _rally_qualifying_detune(owned: Dictionary) -> float:
	if _rally.is_empty():
		return 1.0
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	var full := owned.duplicate(true)
	var tuning: Dictionary = full.get("tuning", {})
	tuning["engine_detune"] = 1.0
	full["tuning"] = tuning
	return RallyLibrary.qualifying_detune(_rally, UpgradeLibrary.effective_meta(full, entry))


# --- Readouts (for tests) ----------------------------------------------------

func sequence_phase() -> int:
	return _seq


func has_launched() -> bool:
	return _launched


# The number of opponent cars ahead of the player still on the grid (excludes the
# player tail and any car that has already driven off).
func queue_count() -> int:
	var n := 0
	for car in _grid:
		if car != _player:
			n += 1
	return n


# The car ids of the opponent grid cars, front-first as spawned (test readout).
func queue_car_ids() -> Array[String]:
	return _grid_car_ids


func reveal_index() -> int:
	return _reveal_index

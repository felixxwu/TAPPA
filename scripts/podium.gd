extends Node3D
# Podium — the end-of-rally reward sequence (todo/menus.md location 3, the 3D
# reward-reveal rigs). A staged flow the player steps through with a single
# "Next" button, reading the finish summary from RallySession.last_result():
#
#   1. PODIUM        — the top-3 finishers' cars stand physically on a 3D podium,
#                      dropped in so they settle onto their suspension (loaded).
#   2. LEADERBOARD   — the full ranked field, marking where the player finished.
#   3. CAR_REVEAL    — the camera flies over to the showroom for a slot-machine spin
#                      through the car roster, landing on the car won (top-3
#                      only), which turns on the turntable with its name.
#                      (Skipped if no car was won.) Per-event upgrades are revealed
#                      earlier, on the between-event standings screens
#                      (features/reward-system.md), not here.
#
# The Next button stays hidden during a slot-machine spin and only appears once it
# locks onto the result. The final Next flies back to HQ, opening on the GARAGE
# view (RallySession.return_to_garage). Headless runs build everything
# synchronously and resolve the spins instantly so tests can step the stages.

enum Stage { PODIUM, LEADERBOARD, CAR_REVEAL }

# Where the podium steps and the showroom turntable sit in the 3D scene (far apart
# so the camera can frame each cleanly without the other in shot).
const PODIUM_CENTER := Vector3.ZERO
const SHOWROOM_CENTER := Vector3(40.0, 0.0, 0.0)
const CAR_SCENE_PATH := "res://car.tscn"

# Floor + scenery assets. The ground reuses the terrain road-blend shader so the
# tarmac pads feather into grass exactly the way the generated road does; the
# trees + bushes go through the shared Foliage helpers, and the spectators through
# the shared Crowd helper (so all three use the SAME representation + scale as the
# stage + HQ) — placed as plain decorative fields (no collision, no AI).

# Floor is a square PlaneMesh side (m); subdivided finely enough that the pad
# feather bands stay smooth.
const FLOOR_SIZE := 120.0
const FLOOR_SUBDIV := 160

var _result: Dictionary = {}
var _stages: Array[int] = []
var _stage_index := 0
var _stage: int = Stage.PODIUM
var _headless := false
# Gates the Next button during a slot-machine spin (false while spinning).
var _reveal_done := true

# 3D staging.
var _camera: Camera3D
var _podium_cars: Array = []          # the top-3 finisher car props
var _player_car: Node3D               # the player's car among the podium props (null if outside top 3)
var _turntable_pivot: Node3D          # rotates the showroom car
var _showroom_car: Node3D

# Overlay widgets.
var _layer: CanvasLayer
var _middle: VBoxContainer             # the per-stage content stack (re-anchored per stage)
var _title_label: Label
var _body_label: Label                # headline result (PODIUM stage)
var _leaderboard_scroll: ScrollContainer
var _leaderboard_box: VBoxContainer
var _slot_panel: PanelContainer       # the slot-machine reveal card
var _slot_label: Label                # the spinning name
var _slot_caption: Label              # the locked-in caption under it
var _next_button: Button
var _slot_tween: Tween


func _ready() -> void:
	_result = RallySession.last_result()
	_headless = Platform.is_headless()
	_build_environment()
	if not _headless:
		_build_scenery()  # visual dressing only — skipped in tests to stay fast
	_build_podium_steps()
	_spawn_podium_cars()
	_build_overlay()
	_stages = _compute_stages()
	_stage_index = 0
	_enter_stage(_stages[0])


# The stages present for this result: podium + leaderboard always; the upgrade
# reveals only when upgrades were won; the car reveal only when a car was won.
# Upgrades come FIRST — handed out while the player's car still stands on the
# podium — and the sequence then flies over to the showroom for the car reward.
func _compute_stages() -> Array[int]:
	var stages: Array[int] = [Stage.PODIUM, Stage.LEADERBOARD]
	# Upgrades are revealed on the between-event standings screens now, not here — the
	# podium closes on the car reward only (features/reward-system.md).
	if String(_result.get("car_reward", "")) != "":
		stages.append(Stage.CAR_REVEAL)
	return stages


# --- 3D environment ----------------------------------------------------------

func _build_environment() -> void:
	var cfg: GameConfig = Config.data
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = load("res://textures/sky_field.png")
	var sky := Sky.new()
	sky.sky_material = sky_mat
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.68)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(40.0), 0.0)
	sun.light_energy = 1.1
	add_child(sun)

	# A wide collision floor so the dropped cars settle onto their suspension (the
	# visual ground plane has no collision). Top face at y = 0.
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(120.0, 2.0, 120.0)
	floor_shape.shape = floor_box
	floor_shape.position = Vector3(0.0, -1.0, 0.0)
	floor_body.add_child(floor_shape)
	add_child(floor_body)

	# Grass ground with two feathered tarmac pads (podium + showroom). The tarmac
	# is painted by the SAME road-blend shader the generated track uses: per-vertex
	# COLOR.a is the grass→tarmac weight and UV2.x = 1 selects pure tarmac.
	var ground := MeshInstance3D.new()
	ground.name = "Floor"
	var pad_size := Vector2.ONE * cfg.podium_tarmac_pad_half * 2.0
	var pads: Array[Rect2] = [
		Rect2(Vector2(PODIUM_CENTER.x, PODIUM_CENTER.z) - pad_size * 0.5, pad_size),
		Rect2(Vector2(SHOWROOM_CENTER.x, SHOWROOM_CENTER.z) - pad_size * 0.5, pad_size),
	]
	ground.mesh = MeshUtil.feathered_ground_mesh(FLOOR_SIZE, FLOOR_SUBDIV, pads,
		cfg.podium_tarmac_feather_m)
	ground.position.y = -0.01
	ground.material_override = MeshUtil.feathered_ground_material(cfg)
	add_child(ground)

	# The showroom turntable: a low wide cylinder the won car turns on.
	_turntable_pivot = Node3D.new()
	_turntable_pivot.position = SHOWROOM_CENTER
	add_child(_turntable_pivot)
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 3.2
	cyl.bottom_radius = 3.2
	cyl.height = 0.3
	disc.mesh = cyl
	disc.position = Vector3(0.0, 0.15, 0.0)
	var dm := StandardMaterial3D.new()
	dm.albedo_color = Color(0.22, 0.24, 0.30)
	disc.material_override = dm
	_turntable_pivot.add_child(disc)

	_camera = Camera3D.new()
	_camera.current = true
	add_child(_camera)


# --- Decorative scenery (real play only; skipped headless) --------------------

# Dress both focal areas (podium + showroom) with trees, bushes and a standing
# crowd. Pure visual dressing: plain MultiMeshes, no collision, no steering AI.
func _build_scenery() -> void:
	var cfg: GameConfig = Config.data
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xB0DE  # fixed → stable placement run-to-run

	# Trees + bushes go through the shared Foliage helpers, so the podium uses the
	# SAME representation the stage + HQ do — a billboard cutout for trees, the 3D
	# mesh for bushes — and the SAME cfg.tree_size_m / cfg.bush_height_m scale,
	# rather than the raw GLB mesh at its native size. A flat y = 0 terrain seats
	# the instances (the podium ground is a
	# plane); scenery only (no collision), render_distance 1000 = no cull (small scene).
	var flat := TerrainManager.flat()
	Foliage.spawn_trees(self, _scatter_ring(rng, cfg.podium_scenery_tree_count,
			cfg.podium_scenery_ring_inner, cfg.podium_scenery_ring_outer),
			flat, false, 1000.0, 0.0).name = "Trees"
	Foliage.spawn_bushes(self, _scatter_ring(rng, cfg.podium_scenery_bush_count,
			cfg.podium_scenery_ring_inner * 0.7, cfg.podium_scenery_ring_outer),
			flat, 1000.0, 0.0).name = "Bushes"
	flat.free()
	var layout := _spectator_layout(cfg)
	# The podium ground is a flat plane at y = 0 (no terrain), so no ground_at Callable.
	var crowd := Crowd.multimesh_instance("Crowd", layout["pos"], layout["yaw"], Callable())
	if crowd != null:
		add_child(crowd)


# Scatter `count` positions in a ring [inner, outer] around each focal area
# (podium + showroom), off the tarmac pads. Returns world XZ points for the
# Foliage fields (which seat, yaw and scale each instance themselves).
# Deterministic given `rng`'s seed.
func _scatter_ring(rng: RandomNumberGenerator, count: int, inner: float, outer: float) -> PackedVector2Array:
	var cfg: GameConfig = Config.data
	var pad := cfg.podium_tarmac_pad_half + cfg.podium_tarmac_feather_m
	var centers := [PODIUM_CENTER, SHOWROOM_CENTER]
	var out := PackedVector2Array()
	for k in count:
		var c: Vector3 = centers[k % centers.size()]
		var pos := Vector3.ZERO
		for _try in 8:
			var ang := rng.randf() * TAU
			var r := lerpf(inner, outer, rng.randf())
			pos = c + Vector3(cos(ang) * r, 0.0, sin(ang) * r)
			# Reject anything over either pad (Chebyshev, matching the floor pads).
			var on_pad := false
			for cc in centers:
				if maxf(absf(pos.x - cc.x), absf(pos.z - cc.z)) < pad:
					on_pad = true
					break
			if not on_pad:
				break
		out.append(Vector2(pos.x, pos.z))
	return out


# A layerless TerrainManager: the podium ground is a plane at y = 0, so height_at
# returns 0 everywhere — all a Foliage field needs to seat its instances. Used only
# during _build_scenery(); freed straight after (mirrors hq_environment.gd).
# A shallow crowd arc behind the podium (all facing it) plus a small cluster at the
# showroom, as world XZ positions + facing yaws for Crowd.multimesh_instance (which
# seats the figures on the ground). Yaw points each figure at the focal centre.
func _spectator_layout(cfg: GameConfig) -> Dictionary:
	var pos := PackedVector2Array()
	var yaw := PackedFloat32Array()
	var pad := cfg.podium_tarmac_pad_half + cfg.podium_tarmac_feather_m
	# Podium arc: two rows across the rear hemisphere (z < 0), facing the podium.
	var arc := maxi(cfg.podium_spectator_count, 2)
	for i in arc:
		var t := float(i) / float(maxi(arc - 1, 1))
		var ang := lerpf(deg_to_rad(205.0), deg_to_rad(335.0), t)
		var r := pad + 3.0 + (2.4 if i % 2 == 1 else 0.0)
		_append_facing(pos, yaw, PODIUM_CENTER, ang, r)
	# Showroom cluster: a small fan facing the turntable.
	for i in 8:
		var t := float(i) / 7.0
		var ang := lerpf(deg_to_rad(120.0), deg_to_rad(240.0), t)
		_append_facing(pos, yaw, SHOWROOM_CENTER, ang, pad + 3.5)
	return {"pos": pos, "yaw": yaw}


# Append a figure standing at `center + r*(cos,sin)` (XZ), yawed to face `center`
# (the mesh's default facing is +Z).
func _append_facing(pos: PackedVector2Array, yaw: PackedFloat32Array,
		center: Vector3, ang: float, r: float) -> void:
	var x := center.x + cos(ang) * r
	var z := center.z + sin(ang) * r
	pos.append(Vector2(x, z))
	yaw.append(atan2(center.x - x, center.z - z))


# The three podium steps (1st centred + tallest, 2nd left, 3rd right). Each is a
# coloured block with a matching collision box so a car lands on its top face.
func _build_podium_steps() -> void:
	var cfg: GameConfig = Config.data
	var h1: float = cfg.podium_step_height
	var heights := [h1, h1 * 0.66, h1 * 0.45]   # P1, P2, P3
	var xs := [0.0, -cfg.podium_step_spacing, cfg.podium_step_spacing]
	var colors := [Color(0.85, 0.70, 0.30), Color(0.70, 0.72, 0.76), Color(0.66, 0.46, 0.30)]
	for i in 3:
		var h: float = heights[i]
		var pos := PODIUM_CENTER + Vector3(xs[i], 0.0, 0.0)
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(3.0, h, 3.4)
		cs.shape = box
		cs.position = pos + Vector3(0.0, h * 0.5, 0.0)
		body.add_child(cs)
		add_child(body)
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = box.size
		mi.mesh = bm
		mi.position = cs.position
		var m := StandardMaterial3D.new()
		m.albedo_color = colors[i]
		mi.material_override = m
		add_child(mi)


# Spawn the top-3 finishers' cars resting on their steps, frozen. Each car is placed
# with its wheels on its step top via the analytic rest ride height (car.gd:
# settled_ride_height) rather than dropped as a live physics body and frozen a beat
# later — no live settle to mistime, bounce off the narrow step, or damage the model.
# Reads the ranked standings.
func _spawn_podium_cars() -> void:
	var cfg: GameConfig = Config.data
	var h1: float = cfg.podium_step_height
	var heights := [h1, h1 * 0.66, h1 * 0.45]
	var xs := [0.0, -cfg.podium_step_spacing, cfg.podium_step_spacing]
	var top3 := _top_finishers(3)
	for i in top3.size():
		var car_id := String(top3[i].get("car_id", ""))
		if car_id == "":
			continue
		var idx := CarLibrary.index_of(car_id)
		if idx < 0:
			continue
		# Seat on the step top, then lift by the car's resting ride height so its wheels
		# sit on the step; spawn frozen.
		var seat := PODIUM_CENTER + Vector3(xs[i], heights[i], 0.0)
		var car := _spawn_car(idx, seat, false)
		car.global_position += Vector3.UP * car.settled_ride_height()
		car.settle_wheel_visuals()  # frozen prop: droop the wheels to their live rest pose
		# Face the camera: the car's forward is -Z and the podium camera sits on the
		# +Z side, so an unrotated car shows its rear. Yaw it half a turn.
		car.rotate_y(PI)
		_podium_cars.append(car)
		if bool(top3[i].get("is_player", false)):
			_player_car = car


# The classified top-N finishers (placed 1..N), in finishing order, from the
# result standings. Empty when the result carries no standings.
func _top_finishers(n: int) -> Array:
	var out: Array = []
	for entry in _result.get("standings", []):
		var placed := int(entry.get("placed", -1))
		if placed >= 1 and placed <= n:
			out.append(entry)
	out.sort_custom(func(a, b): return int(a["placed"]) < int(b["placed"]))
	return out


# Spawn a car-library car as a silent prop at a world position. `live` leaves it
# running physics (so it settles onto its suspension); otherwise it spawns frozen.
# Gets its own mesh copies (car.tscn shares mesh sub-resources across instances).
func _spawn_car(library_index: int, origin: Vector3, live: bool, parent: Node = null) -> Node3D:
	# Shared display-prop recipe (CarProp.spawn): instantiate + isolated config +
	# apply_car + dup meshes + silence engine audio, then frozen (unless `live`, which
	# leaves it running physics so it settles onto its suspension). Positioning runs in
	# `configure` — parent-local on the turntable pivot, else world-space.
	var xform := Transform3D.IDENTITY
	xform.origin = origin
	var configure := func(c) -> void:
		if parent != null:
			c.transform = xform   # parent-local (the turntable pivot)
		else:
			c.global_transform = xform
	return CarProp.spawn(parent if parent != null else self, load(CAR_SCENE_PATH), {
		"index": library_index,
		"configure": configure,
		"freeze": not live,
		"disable_process": not live,
	})


func _process(delta: float) -> void:
	# Slowly turn the showroom car on its turntable through the car reveal (the
	# closing stage — upgrades are handed out earlier, at the podium).
	if is_instance_valid(_turntable_pivot) and _stage == Stage.CAR_REVEAL:
		_turntable_pivot.rotation.y += deg_to_rad(Config.data.podium_showroom_spin_dps) * delta


# --- Overlay -----------------------------------------------------------------

func _build_overlay() -> void:
	_layer = CanvasLayer.new()
	add_child(_layer)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 24.0
	root.offset_top = 24.0
	root.offset_right = -24.0
	root.offset_bottom = -24.0
	root.add_theme_constant_override("separation", 12)
	_layer.add_child(root)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 30)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_title_label)

	# A stack that holds the per-stage content (only one visible at a time). It's
	# centred for the podium/leaderboard, but drops to the bottom during the car /
	# upgrade reveals so the slot card doesn't cover the revealed car (_enter_stage).
	var middle := VBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.alignment = BoxContainer.ALIGNMENT_CENTER
	middle.add_theme_constant_override("separation", 14)
	root.add_child(middle)
	_middle = middle

	_body_label = Label.new()
	_body_label.add_theme_font_size_override("font_size", 22)
	_body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	middle.add_child(_body_label)

	# Leaderboard: a scrolling ranked field inside a solid panel.
	_leaderboard_scroll = TouchScrollContainer.new()
	_leaderboard_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_leaderboard_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	middle.add_child(_leaderboard_scroll)
	_leaderboard_box = VBoxContainer.new()
	_leaderboard_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_leaderboard_box.add_theme_constant_override("separation", 4)
	_leaderboard_scroll.add_child(_leaderboard_box)

	# Slot-machine reveal card.
	_slot_panel = PanelContainer.new()
	_slot_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_slot_panel.add_theme_stylebox_override("panel", UITheme.reward_card_box())
	middle.add_child(_slot_panel)
	var slot_col := VBoxContainer.new()
	slot_col.add_theme_constant_override("separation", 8)
	_slot_panel.add_child(slot_col)
	_slot_label = Label.new()
	_slot_label.add_theme_font_size_override("font_size", 40)
	_slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_label.custom_minimum_size = Vector2(_card_width(), 0)
	# Wrap at the card width: without this a long part/car name at this font size
	# stretches the reveal card (and its Apply/Keep confirm) wider than the screen.
	_slot_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	slot_col.add_child(_slot_label)
	_slot_caption = Label.new()
	_slot_caption.add_theme_font_size_override("font_size", 16)
	_slot_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	slot_col.add_child(_slot_caption)

	_next_button = Button.new()
	# Focusable so the reward sequence steps with a keyboard/gamepad (ui_accept); it's
	# re-focused whenever it reappears after a reveal (_refresh_next_button).
	_next_button.focus_mode = Control.FOCUS_ALL
	_next_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_next_button.custom_minimum_size = Vector2(240, 48)
	_next_button.pressed.connect(_on_next)
	root.add_child(_next_button)

	UITheme.enforce(_layer)  # house rules: uppercase + one font size + button height
	# Framework: focus + WASD/arrow/gamepad nav on Next. No on_back — the reward flow
	# is linear (Next-only); podium re-grabs Next itself as reveals appear.
	MenuNav.attach(root, {first = _next_button})


# The reveal card's content width (shared with the standings upgrade card).
func _card_width() -> float:
	return UpgradeReveal.card_width(get_viewport().get_visible_rect().size.x)


# --- Stage flow --------------------------------------------------------------

func _enter_stage(stage: int) -> void:
	_stage = stage
	_body_label.visible = false
	_leaderboard_scroll.visible = false
	_slot_panel.visible = false
	_slot_label.visible = true  # the car reveal hides it (one-line card); reset per stage
	_slot_caption.custom_minimum_size = Vector2.ZERO  # car reveal widens it; reset per stage
	_slot_caption.text = ""
	# Drop the content to the bottom for the car reveal (keeps the revealed car in
	# clear view); keep it centred for the podium + leaderboard.
	_middle.alignment = BoxContainer.ALIGNMENT_END if stage == Stage.CAR_REVEAL else BoxContainer.ALIGNMENT_CENTER
	match stage:
		Stage.PODIUM: _show_podium()
		Stage.LEADERBOARD: _show_leaderboard()
		Stage.CAR_REVEAL: _show_car_reveal()


func _show_podium() -> void:
	_title_label.text = "PODIUM"
	_body_label.text = UITheme.caps(_summary_text())
	_body_label.visible = true
	_move_camera(_podium_cam())
	_reveal_done = true
	_refresh_next_button()


func _show_leaderboard() -> void:
	_title_label.text = "RESULTS"
	for c in _leaderboard_box.get_children():
		c.queue_free()
	var standings: Array = _result.get("standings", [])
	if standings.is_empty():
		var none := Label.new()
		none.text = "No standings recorded."
		_leaderboard_box.add_child(none)
	for entry in standings:
		_leaderboard_box.add_child(UITheme.standings_row(entry))
	_leaderboard_scroll.visible = true
	UITheme.enforce(_layer)  # uppercase the freshly-built standings rows
	_move_camera(_podium_cam())
	_reveal_done = true
	_refresh_next_button()


func _show_car_reveal() -> void:
	# A single-line reveal card: the caption alone carries the car name (the big slot
	# label is hidden, so the name isn't shown twice and the card stays one line).
	_title_label.text = "YOUR NEW CAR"
	_slot_panel.visible = true
	# The slot label sets the card width while it spins; give the caption the same
	# width so the landed card stays a single horizontal line instead of wrapping.
	_slot_caption.custom_minimum_size = Vector2(_card_width(), 0)
	_move_camera(_showroom_cam())
	var car_id := String(_result.get("car_reward", ""))
	var entry := CarLibrary.by_id(car_id)
	var target := String(entry.get("name", car_id))
	# Bring the won car onto the turntable (hidden until the spin locks on).
	_reveal_showroom_car(car_id)
	_start_slot(Registry.names(CarLibrary.all()), target, func() -> void:
		# Collapse to the one-line card: the caption alone carries the car name
		# once the reel lands, so the name isn't shown twice.
		_slot_label.visible = false
		if is_instance_valid(_showroom_car):
			_showroom_car.visible = true
		var is_new: bool = bool(_result.get("car_reward_is_new", false))
		_slot_caption.text = UITheme.caps("%s%s — delivered to your garage" % [
			target, "  (NEW)" if is_new else ""]))


# Spawn the won car on the turntable, frozen and silent, hidden until the slot
# reveal lands. Parented to the rotating pivot so it turns with the disc.
func _reveal_showroom_car(car_id: String) -> void:
	if is_instance_valid(_showroom_car):
		_showroom_car.queue_free()
		_showroom_car = null
	var idx := CarLibrary.index_of(car_id)
	if idx < 0:
		return
	_showroom_car = _spawn_car(idx, Vector3(0.0, 0.45, 0.0), false, _turntable_pivot)
	_showroom_car.visible = false


# --- Slot machine ------------------------------------------------------------

# Spin to the won car, then run `on_done`. The Next button is hidden while spinning
# (re-shown when the reel locks on). Wraps the shared UpgradeReveal.start_spin with
# the podium's Next-button gate.
func _start_slot(reel_names: Array, target: String, on_done: Callable) -> void:
	_reveal_done = false
	_slot_caption.text = ""
	_refresh_next_button()
	if _slot_tween != null and _slot_tween.is_valid():
		_slot_tween.kill()
	_slot_tween = UpgradeReveal.start_spin(self, _slot_label, reel_names, target,
		Config.data.podium_slot_spin_time, _headless, func() -> void:
			_reveal_done = true
			on_done.call()
			_refresh_next_button())


# --- Next button -------------------------------------------------------------

func _refresh_next_button() -> void:
	# Hidden during a slot spin — the reveal owns the screen until the reel locks on.
	_next_button.visible = _reveal_done
	_next_button.text = UITheme.caps("Continue to HQ" if _is_last_stage() else "Next >")
	# Whenever the button reappears, re-grab focus so the controller cursor follows it.
	if _next_button.visible:
		UITheme.focus_grab.bind(_next_button).call_deferred()


func _is_last_stage() -> bool:
	return _stage_index >= _stages.size() - 1


func _on_next() -> void:
	if not _reveal_done:
		return  # never advance mid-spin (the button is hidden anyway)
	_stage_index += 1
	if _stage_index >= _stages.size():
		_go_to_hq()
		return
	_enter_stage(_stages[_stage_index])


func _go_to_hq() -> void:
	# Tell HQ to open on the garage (not the exterior title) when it boots.
	RallySession.return_to_garage = true
	get_tree().change_scene_to_file("res://hq.tscn")


# --- Camera ------------------------------------------------------------------

func _podium_cam() -> Transform3D:
	# Frame the PLAYER's car (whichever step they're on — 1st, 2nd or 3rd), not a
	# fixed centre, so the shot always celebrates the player. Falls back to the
	# podium centre if the player finished outside the top 3 (no car on the podium).
	var focus := PODIUM_CENTER + Vector3(0.0, Config.data.podium_step_height, 0.0)
	if is_instance_valid(_player_car):
		focus = _player_car.global_position
	# Sit low (near the ground) and close in, with a slight sideways offset in X so the
	# shot is a hair off head-on. Aim up at the car so the camera looks UP at it from
	# just above ground level.
	var eye := focus + Vector3(1.8, -0.6, 5.2)
	eye.y = maxf(eye.y, 0.8)  # never dip below ~ground level (the P3 step is low)
	return _look_xform(eye, focus + Vector3(0.0, 0.6, 0.0))


func _showroom_cam() -> Transform3D:
	return _look_xform(SHOWROOM_CENTER + Vector3(4.6, 2.4, 6.8), SHOWROOM_CENTER + Vector3(0.0, 0.9, 0.0))


func _look_xform(eye: Vector3, look: Vector3) -> Transform3D:
	var t := Transform3D.IDENTITY
	t.origin = eye
	if eye.distance_to(look) < 0.001:
		return t
	return t.looking_at(look, Vector3.UP)


func _move_camera(xform: Transform3D) -> void:
	if not is_instance_valid(_camera):
		return
	var t: float = Config.data.menu_camera_move_time
	if _headless or t <= 0.0:
		_camera.global_transform = xform
		return
	var tween := create_tween()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tween.tween_property(_camera, "global_transform", xform, t)


# --- Text helpers (ported from the flat podium) ------------------------------

func _summary_text() -> String:
	var rally_name := String(_result.get("rally_name", ""))
	var prefix := (rally_name + "\n") if rally_name != "" else ""
	if _result.get("dnf", false):
		return "%sDNF — car wrecked.\nThe rally stays incomplete." % prefix
	var placed := int(_result.get("placed", -1))
	var combined := int(_result.get("combined_ms", -1))
	var lines: Array[String] = ["%sFinished P%d   (%s)" % [prefix, placed, UITheme.format_time(combined)]]
	if _result.get("showdown_won", false):
		lines.append("THE SHOWDOWN IS WON — you've completed the game!")
	elif _result.get("completed", false):
		lines.append("Top 3 — RALLY WON!")
	else:
		lines.append("Outside the top 3 — no car reward. Re-enter from HQ to try again.")
	return "\n".join(lines)

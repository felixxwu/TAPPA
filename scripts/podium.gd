extends Node3D
# Podium — the end-of-rally reward sequence (todo/menus.md location 3, the 3D
# reward-reveal rigs). A staged flow the player steps through with a single
# "Next" button, reading the finish summary from RallySession.last_result():
#
#   1. PODIUM        — the top-3 finishers' cars stand physically on a 3D podium,
#                      dropped in so they settle onto their suspension (loaded).
#   2. LEADERBOARD   — the full ranked field, marking where the player finished.
#   3. UPGRADE_REVEAL— a slot-machine spin per upgrade won this rally — handed out
#                      at the podium, with the player's car still standing on it —
#                      then an Apply/Keep choice: fit the part straight onto the
#                      car the player just drove, or keep it unlocked for the
#                      garage upgrades menu. (Skipped if none were won — e.g. a DNF.)
#   4. CAR_REVEAL    — the camera flies over to the showroom for the same spin
#                      through the car roster, landing on the car won (top-3
#                      only), which turns on the turntable with its name.
#                      (Skipped if no car was won.)
#
# The Next button stays hidden during a slot-machine spin and only appears once it
# locks onto the result. The final Next flies back to HQ, opening on the GARAGE
# view (RallySession.return_to_garage). Headless runs build everything
# synchronously and resolve the spins instantly so tests can step the stages.

enum Stage { PODIUM, LEADERBOARD, CAR_REVEAL, UPGRADE_REVEAL }

# Where the podium steps and the showroom turntable sit in the 3D scene (far apart
# so the camera can frame each cleanly without the other in shot).
const PODIUM_CENTER := Vector3.ZERO
const SHOWROOM_CENTER := Vector3(40.0, 0.0, 0.0)
const CAR_SCENE_PATH := "res://car.tscn"

# Floor + scenery assets. The ground reuses the terrain road-blend shader so the
# tarmac pads feather into grass exactly the way the generated road does; the
# trees/bushes/spectators are the same low-poly models the world scatters, but
# placed as plain decorative MultiMeshes (no collision, no AI).
const GROUND_SHADER := preload("res://shaders/ps1_models.gdshader")
const GRASS_TEXTURE := preload("res://textures/grass.jpg")
const TREE_MODEL := preload("res://models/low_poly_tree.glb")
const GROUNDCOVER_SCENE := preload("res://models/vegetation/groundcover_opaque.glb")
const SPECTATOR_SCENE := preload("res://blender/spectator/spectator.glb")

# Floor is a square PlaneMesh side (m); subdivided finely enough that the pad
# feather bands stay smooth.
const FLOOR_SIZE := 120.0
const FLOOR_SUBDIV := 160

var _result: Dictionary = {}
var _stages: Array[int] = []
var _stage_index := 0
var _upgrade_index := 0                # which won upgrade the next reveal shows
var _stage: int = Stage.PODIUM
var _headless := false
# Gates the Next button during a slot-machine spin (false while spinning).
var _reveal_done := true

# 3D staging.
var _camera: Camera3D
var _podium_cars: Array = []          # the top-3 settling car props
var _settle_generation := 0
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
var _choice_box: HBoxContainer        # the fit-it-now choice under an upgrade reveal
var _apply_button: Button
var _keep_button: Button
var _choice_pending := false          # gates Next while an apply/keep choice is open
var _choice_item_id := ""             # the revealed upgrade the open choice is about
var _next_button: Button
var _slot_tween: Tween


func _ready() -> void:
	_result = RallySession.last_result()
	_headless = DisplayServer.get_name() == "headless"
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
	# One upgrade-reveal stage per won upgrade (a rally grants several), each a
	# separate slot-machine spin stepped through with Next.
	for _u in (_result.get("upgrades", []) as Array):
		stages.append(Stage.UPGRADE_REVEAL)
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
	ground.mesh = _build_floor_mesh()
	ground.position.y = -0.01
	var gm := ShaderMaterial.new()
	gm.shader = GROUND_SHADER
	gm.set_shader_parameter("albedo_texture", GRASS_TEXTURE)
	gm.set_shader_parameter("tarmac_color", cfg.tarmac_color)
	gm.set_shader_parameter("blend_road", true)
	var tpm: float = cfg.terrain_tile_per_meter
	gm.set_shader_parameter("texture_tile", Vector2(tpm, tpm))
	ground.material_override = gm
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


# The floor mesh: a subdivided grid carrying, per vertex, a grass→tarmac blend
# weight in COLOR.a (1 on a pad, smoothstep-feathered to 0 across the feather
# band) and UV2.x = 1 (pure tarmac). Two square pads: the podium and the showroom.
func _build_floor_mesh() -> ArrayMesh:
	var cfg: GameConfig = Config.data
	var half: float = cfg.podium_tarmac_pad_half
	var feather: float = maxf(cfg.podium_tarmac_feather_m, 0.001)
	var pads := [Vector2(PODIUM_CENTER.x, PODIUM_CENTER.z),
			Vector2(SHOWROOM_CENTER.x, SHOWROOM_CENTER.z)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := FLOOR_SUBDIV
	var step := FLOOR_SIZE / float(n)
	var origin := -FLOOR_SIZE * 0.5
	# Build the (n+1)^2 vertex grid, then index two triangles per cell.
	for j in n + 1:
		for i in n + 1:
			var x := origin + float(i) * step
			var z := origin + float(j) * step
			var w := 0.0
			for c in pads:
				# Chebyshev distance → a square pad; feather beyond its half-extent.
				var d := maxf(absf(x - c.x), absf(z - c.y))
				w = maxf(w, 1.0 - smoothstep(half, half + feather, d))
			st.set_color(Color(1.0, 1.0, 1.0, w))
			st.set_uv(Vector2(x, z))
			st.set_uv2(Vector2(1.0, 0.0))
			st.set_normal(Vector3.UP)  # flat floor; keeps the mesh well-formed
			st.add_vertex(Vector3(x, 0.0, z))
	var row := n + 1
	for j in n:
		for i in n:
			var a := j * row + i
			var b := a + 1
			var cc := a + row
			var d := cc + 1
			# Wound so the front face points UP: the shared ps1_models shader culls back
			# faces, so a downward-facing floor draws nothing when viewed from above.
			st.add_index(a); st.add_index(b); st.add_index(cc)
			st.add_index(b); st.add_index(d); st.add_index(cc)
	return st.commit()


# --- Decorative scenery (real play only; skipped headless) --------------------

# Dress both focal areas (podium + showroom) with trees, bushes and a standing
# crowd. Pure visual dressing: plain MultiMeshes, no collision, no steering AI.
func _build_scenery() -> void:
	var cfg: GameConfig = Config.data
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xB0DE  # fixed → stable placement run-to-run

	var tree_mesh := _mesh_from_scene(TREE_MODEL)
	if tree_mesh != null:
		_add_multimesh(tree_mesh, _scatter_ring(rng, cfg.podium_scenery_tree_count,
				cfg.podium_scenery_ring_inner, cfg.podium_scenery_ring_outer,
				0.85, 1.25), "Trees")
	var bush_mesh := _bush_mesh(cfg)
	if bush_mesh != null:
		_add_multimesh(bush_mesh, _scatter_ring(rng, cfg.podium_scenery_bush_count,
				cfg.podium_scenery_ring_inner * 0.7, cfg.podium_scenery_ring_outer,
				0.8, 1.4), "Bushes")
	var spec_mesh := _mesh_from_scene(SPECTATOR_SCENE)
	if spec_mesh != null:
		_add_multimesh(spec_mesh, _spectator_transforms(cfg, spec_mesh), "Crowd")


# Place `count` items in a ring [inner, outer] around each focal area (podium +
# showroom), off the tarmac pads, with a random yaw and a uniform scale in
# [scale_lo, scale_hi]. Deterministic given `rng`'s seed.
func _scatter_ring(rng: RandomNumberGenerator, count: int, inner: float, outer: float,
		scale_lo: float, scale_hi: float) -> Array[Transform3D]:
	var cfg: GameConfig = Config.data
	var pad := cfg.podium_tarmac_pad_half + cfg.podium_tarmac_feather_m
	var centers := [PODIUM_CENTER, SHOWROOM_CENTER]
	var out: Array[Transform3D] = []
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
		var xb := Basis(Vector3.UP, rng.randf() * TAU).scaled(
				Vector3.ONE * rng.randf_range(scale_lo, scale_hi))
		out.append(Transform3D(xb, pos))
	return out


# A shallow crowd arc behind the podium (all facing it) plus a small cluster at
# the showroom. Yaw points each figure at the focal centre; feet sit on y = 0.
func _spectator_transforms(cfg: GameConfig, mesh: Mesh) -> Array[Transform3D]:
	var foot := -mesh.get_aabb().position.y
	var out: Array[Transform3D] = []
	var pad := cfg.podium_tarmac_pad_half + cfg.podium_tarmac_feather_m
	# Podium arc: two rows across the rear hemisphere (z < 0), facing the podium.
	var arc := maxi(cfg.podium_spectator_count, 2)
	for i in arc:
		var t := float(i) / float(maxi(arc - 1, 1))
		var ang := lerpf(deg_to_rad(205.0), deg_to_rad(335.0), t)
		var r := pad + 3.0 + (2.4 if i % 2 == 1 else 0.0)
		out.append(_facing_xform(PODIUM_CENTER, ang, r, foot))
	# Showroom cluster: a small fan facing the turntable.
	for i in 8:
		var t := float(i) / 7.0
		var ang := lerpf(deg_to_rad(120.0), deg_to_rad(240.0), t)
		out.append(_facing_xform(SHOWROOM_CENTER, ang, pad + 3.5, foot))
	return out


# A transform standing at `center + r*(cos,sin)` on the ground, yawed to face
# `center` (the mesh's default facing is +Z).
func _facing_xform(center: Vector3, ang: float, r: float, foot: float) -> Transform3D:
	var pos := center + Vector3(cos(ang) * r, foot, sin(ang) * r)
	var dir := center - pos
	var yaw := atan2(dir.x, dir.z)
	return Transform3D(Basis(Vector3.UP, yaw), pos)


func _add_multimesh(mesh: Mesh, transforms: Array[Transform3D], node_name: String) -> void:
	if transforms.is_empty():
		return
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	mmi.multimesh = mm
	add_child(mmi)


# Pull the first MeshInstance3D's mesh out of an imported glb PackedScene.
func _mesh_from_scene(scene: PackedScene) -> Mesh:
	var inst := scene.instantiate()
	var hits := inst.find_children("*", "MeshInstance3D", true, false)
	var mesh: Mesh = (hits[0] as MeshInstance3D).mesh if not hits.is_empty() else null
	inst.free()
	return mesh


# The groundcover bush mesh, tinted the same way world.gd renders scattered bushes.
func _bush_mesh(cfg: GameConfig) -> Mesh:
	var src := _mesh_from_scene(GROUNDCOVER_SCENE)
	if src == null:
		return null
	var mesh: Mesh = src.duplicate()
	var base := mesh.surface_get_material(0)
	var mat: StandardMaterial3D = base.duplicate() if base is StandardMaterial3D else StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = cfg.bush_tint
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	mesh.surface_set_material(0, mat)
	return mesh


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


# Spawn the top-3 finishers' cars above their steps so they drop in and settle on
# their suspension, then freeze the settled pose. Reads the ranked standings.
func _spawn_podium_cars() -> void:
	var cfg: GameConfig = Config.data
	var h1: float = cfg.podium_step_height
	var heights := [h1, h1 * 0.66, h1 * 0.45]
	var xs := [0.0, -cfg.podium_step_spacing, cfg.podium_step_spacing]
	var top3 := _top_finishers(3)
	_settle_generation += 1
	var live := false
	for i in top3.size():
		var car_id := String(top3[i].get("car_id", ""))
		if car_id == "":
			continue
		var idx := CarLibrary.index_of(car_id)
		if idx < 0:
			continue
		var drop := Vector3(xs[i], heights[i] + cfg.podium_car_drop_height, 0.0)
		var car := _spawn_car(idx, PODIUM_CENTER + drop, not _headless)
		# Face the camera: the car's forward is -Z and the podium camera sits on the
		# +Z side, so an unrotated car shows its rear. Yaw it half a turn.
		car.rotate_y(PI)
		_podium_cars.append(car)
		live = live or not _headless
	# Let them settle under physics for a beat, then freeze the settled pose. In
	# headless they spawn already frozen (no wait), so the timer is real-play only.
	if live and cfg.podium_car_settle_seconds > 0.0:
		var gen := _settle_generation
		get_tree().create_timer(cfg.podium_car_settle_seconds).timeout.connect(
			func() -> void: _freeze_podium(gen))


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


func _freeze_podium(generation: int) -> void:
	if generation != _settle_generation:
		return
	for car in _podium_cars:
		if is_instance_valid(car):
			car.freeze = true
			car.process_mode = Node.PROCESS_MODE_DISABLED


# Spawn a car-library car as a silent prop at a world position. `live` leaves it
# running physics (so it settles onto its suspension); otherwise it spawns frozen.
# Gets its own mesh copies (car.tscn shares mesh sub-resources across instances).
func _spawn_car(library_index: int, origin: Vector3, live: bool, parent: Node = null) -> Node3D:
	# Variant, not :=, so the dynamic car-script calls below (apply_car, freeze)
	# don't depend on the analyzer resolving car.tscn's root script type at parse
	# time — that inference is environment-fragile (Godot 4.6 can fail it and break
	# the whole script). Runtime behaviour is unchanged (dynamic dispatch).
	var car: Variant = load(CAR_SCENE_PATH).instantiate()
	(parent if parent != null else self).add_child(car)
	# Isolated config so this display car's reshape can't clobber the player car's
	# engine/gearbox in the shared global Config.data (see car.gd `config`).
	car.use_isolated_config()
	car.apply_car(library_index)
	_dup_meshes(car)
	var xform := Transform3D.IDENTITY
	xform.origin = origin
	if parent != null:
		car.transform = xform   # parent-local (the turntable pivot)
	else:
		car.global_transform = xform
	if live:
		car.freeze = false
	else:
		car.freeze = true
		car.process_mode = Node.PROCESS_MODE_DISABLED
	var audio: Variant = car.get_node_or_null("EngineAudio")
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
	# A solid black, sharp-cornered reward card with a green accent border (a reward
	# is a positive event — green is the design system's "positive" colour).
	var style := UITheme.panel_box(0.92, 22)
	style.border_color = UITheme.GREEN
	for side in ["left", "top", "right", "bottom"]:
		style.set("border_width_" + side, 2)
	_slot_panel.add_theme_stylebox_override("panel", style)
	middle.add_child(_slot_panel)
	var slot_col := VBoxContainer.new()
	slot_col.add_theme_constant_override("separation", 8)
	_slot_panel.add_child(slot_col)
	_slot_label = Label.new()
	_slot_label.add_theme_font_size_override("font_size", 40)
	_slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_label.custom_minimum_size = Vector2(520, 0)
	slot_col.add_child(_slot_label)
	_slot_caption = Label.new()
	_slot_caption.add_theme_font_size_override("font_size", 16)
	_slot_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slot_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	slot_col.add_child(_slot_caption)

	# The upgrade reveal's apply/keep choice: fit the won part to the car the player
	# just drove, or keep it unlocked for the garage upgrades menu. Both buttons are
	# focusable so the choice works on keyboard/gamepad (features/menus.md).
	_choice_box = HBoxContainer.new()
	_choice_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_choice_box.add_theme_constant_override("separation", 12)
	_choice_box.visible = false
	slot_col.add_child(_choice_box)
	_apply_button = Button.new()
	_apply_button.focus_mode = Control.FOCUS_ALL
	_apply_button.pressed.connect(_on_apply_upgrade)
	_choice_box.add_child(_apply_button)
	_keep_button = Button.new()
	_keep_button.focus_mode = Control.FOCUS_ALL
	_keep_button.text = "Keep for later"
	_keep_button.pressed.connect(_on_keep_upgrade)
	_choice_box.add_child(_keep_button)

	_next_button = Button.new()
	# Focusable so the reward sequence steps with a keyboard/gamepad (ui_accept); it's
	# re-focused whenever it reappears after a reveal (_refresh_next_button).
	_next_button.focus_mode = Control.FOCUS_ALL
	_next_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_next_button.custom_minimum_size = Vector2(240, 48)
	_next_button.pressed.connect(_on_next)
	root.add_child(_next_button)

	UITheme.enforce(_layer)  # house rules: uppercase + one font size + button height
	# Framework: focus + WASD/arrow/gamepad nav (Next, and the Apply/Keep choice
	# when the upgrade reveal shows it). No on_back — the reward flow is linear
	# (Next-only); podium re-grabs Next/Apply itself as reveals appear.
	MenuNav.attach(root, {first = _next_button})


# --- Stage flow --------------------------------------------------------------

func _enter_stage(stage: int) -> void:
	_stage = stage
	_body_label.visible = false
	_leaderboard_scroll.visible = false
	_slot_panel.visible = false
	_choice_box.visible = false
	_choice_pending = false
	_slot_label.visible = true  # the car reveal hides it (one-line card); reset per stage
	_slot_caption.custom_minimum_size = Vector2.ZERO  # car reveal widens it; reset per stage
	_slot_caption.text = ""
	# Drop the content to the bottom for the reveals (keeps the revealed car in
	# clear view); keep it centred for the podium + leaderboard.
	var reveal := stage == Stage.CAR_REVEAL or stage == Stage.UPGRADE_REVEAL
	_middle.alignment = BoxContainer.ALIGNMENT_END if reveal else BoxContainer.ALIGNMENT_CENTER
	match stage:
		Stage.PODIUM: _show_podium()
		Stage.LEADERBOARD: _show_leaderboard()
		Stage.CAR_REVEAL: _show_car_reveal()
		Stage.UPGRADE_REVEAL: _show_upgrade_reveal()


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
		_leaderboard_box.add_child(_standings_row(entry))
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
	_slot_caption.custom_minimum_size = Vector2(520, 0)
	_move_camera(_showroom_cam())
	var car_id := String(_result.get("car_reward", ""))
	var entry := CarLibrary.by_id(car_id)
	var target := String(entry.get("name", car_id))
	# Bring the won car onto the turntable (hidden until the spin locks on).
	_reveal_showroom_car(car_id)
	_start_slot(_car_names(), target, func() -> void:
		# Collapse to the one-line card: the caption alone carries the car name
		# once the reel lands, so the name isn't shown twice.
		_slot_label.visible = false
		if is_instance_valid(_showroom_car):
			_showroom_car.visible = true
		var is_new: bool = bool(_result.get("car_reward_is_new", false))
		_slot_caption.text = UITheme.caps("%s%s — delivered to your garage" % [
			target, "  (NEW)" if is_new else ""]))


func _show_upgrade_reveal() -> void:
	var upgrades: Array = _result.get("upgrades", [])
	var idx := _upgrade_index
	_upgrade_index += 1
	# Title counts up when a rally grants more than one ("UPGRADE 1 OF 2").
	_title_label.text = "UPGRADE %d OF %d" % [idx + 1, upgrades.size()] if upgrades.size() > 1 else "UPGRADE WON"
	_slot_panel.visible = true
	# Upgrades are handed out at the PODIUM, while the player's car still stands on
	# it — the sequence only flies to the showroom for the car reveal afterwards.
	_move_camera(_podium_cam())
	var won := String(upgrades[idx]) if idx < upgrades.size() else ""
	var target := String(UpgradeLibrary.by_id(won).get("name", won))
	_start_slot(_upgrade_names(), target, func() -> void:
		_offer_upgrade_choice(won, target))


# Once an upgrade reveal lands, offer to fit the part straight onto the car the
# player just drove (Apply) or leave it unlocked for the garage upgrades menu
# (Keep). Consumables (the repair kit) and a missing driven car skip the choice —
# those just land in the unlocked pool as before.
func _offer_upgrade_choice(item_id: String, item_name: String) -> void:
	var driven := Save.get_car(int(_result.get("car_instance_id", -1)))
	if driven.is_empty() or UpgradeLibrary.slot_of(item_id) == "" or UpgradeLibrary.is_consumable(item_id):
		_slot_caption.text = UITheme.caps("%s — added to your unlocked parts" % item_name)
		return
	var car_name := String(CarLibrary.by_id(String(driven.get("model_id", ""))).get("name", "your car"))
	_choice_item_id = item_id
	_choice_pending = true
	_slot_caption.text = UITheme.caps("Fit %s to the %s you just drove?" % [item_name, car_name])
	_apply_button.text = UITheme.caps("Apply to %s" % car_name)
	_choice_box.visible = true
	UITheme.enforce(_layer)  # theme the freshly-shown choice buttons
	_refresh_next_button()
	UITheme.focus_grab.bind(_apply_button).call_deferred()


func _on_apply_upgrade() -> void:
	var item_name := String(UpgradeLibrary.by_id(_choice_item_id).get("name", _choice_item_id))
	if Save.install_upgrade(int(_result.get("car_instance_id", -1)), _choice_item_id):
		_slot_caption.text = UITheme.caps("%s fitted — toggle it any time in the garage" % item_name)
	else:
		# Already fitted to this car (a duplicate win) — the copy stays unlocked.
		_slot_caption.text = UITheme.caps("%s is already fitted — kept in your unlocked parts" % item_name)
	_resolve_upgrade_choice()


func _on_keep_upgrade() -> void:
	var item_name := String(UpgradeLibrary.by_id(_choice_item_id).get("name", _choice_item_id))
	_slot_caption.text = UITheme.caps("%s kept — apply it any time in the garage" % item_name)
	_resolve_upgrade_choice()


func _resolve_upgrade_choice() -> void:
	_choice_item_id = ""
	_choice_pending = false
	_choice_box.visible = false
	_refresh_next_button()


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

# Spin through `reel_names`, decelerating to a stop on `target`, then run `on_done`.
# The Next button is hidden while spinning. Headless / zero spin time resolves
# instantly so tests step straight through.
func _start_slot(reel_names: Array, target: String, on_done: Callable) -> void:
	_reveal_done = false
	_slot_caption.text = ""
	_refresh_next_button()
	if _slot_tween != null and _slot_tween.is_valid():
		_slot_tween.kill()
	var spin: float = Config.data.podium_slot_spin_time
	if _headless or spin <= 0.0 or reel_names.is_empty():
		_slot_label.text = UITheme.caps(target)
		_finish_slot(on_done)
		return
	var reel := _build_reel(reel_names, target)
	_slot_tween = create_tween()
	_slot_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slot_tween.tween_method(
		func(p: float) -> void:
			var i := clampi(int(round(p)), 0, reel.size() - 1)
			_slot_label.text = UITheme.caps(String(reel[i])),
		0.0, float(reel.size() - 1), spin)
	_slot_tween.tween_callback(func() -> void:
		_slot_label.text = UITheme.caps(target)
		_finish_slot(on_done))


# A reel that cycles the candidate names a few times and ends on the target, so the
# tween that walks it slows to a stop on the won item.
func _build_reel(names: Array, target: String) -> Array:
	var reel: Array = []
	var count := maxi(14, names.size() * 3)
	for i in count:
		reel.append(String(names[i % names.size()]))
	reel.append(target)
	return reel


func _finish_slot(on_done: Callable) -> void:
	_reveal_done = true
	if on_done.is_valid():
		on_done.call()
	_refresh_next_button()


func _car_names() -> Array:
	var names: Array = []
	for entry in CarLibrary.CARS:
		names.append(String(entry.get("name", entry.get("id", "?"))))
	return names


func _upgrade_names() -> Array:
	var names: Array = []
	for entry in UpgradeLibrary.UPGRADES:
		names.append(String(entry.get("name", entry.get("id", "?"))))
	return names


# --- Next button -------------------------------------------------------------

func _refresh_next_button() -> void:
	# Hidden during a slot spin AND while an apply/keep choice is open — the choice
	# buttons own the focus until the player picks one.
	_next_button.visible = _reveal_done and not _choice_pending
	_next_button.text = UITheme.caps("Continue to HQ" if _is_last_stage() else "Next >")
	# Whenever the button reappears, re-grab focus so the controller cursor follows it.
	if _next_button.visible:
		UITheme.focus_grab.bind(_next_button).call_deferred()


func _is_last_stage() -> bool:
	return _stage_index >= _stages.size() - 1


func _on_next() -> void:
	if not _reveal_done or _choice_pending:
		return  # never advance mid-spin or mid-choice (the button is hidden anyway)
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
	# Offset in X so the shot sits a little off the podium's axis — a 3/4-ish view
	# of the cars (which face the camera) instead of a flat head-on line-up.
	return _look_xform(PODIUM_CENTER + Vector3(4.2, 4.4, 10.2), PODIUM_CENTER + Vector3(0.0, 1.2, 0.0))


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
	var lines: Array[String] = ["%sFinished P%d   (%s)" % [prefix, placed, _fmt(combined)]]
	if _result.get("showdown_won", false):
		lines.append("THE SHOWDOWN IS WON — you've completed the game!")
	elif _result.get("completed", false):
		lines.append("Top 3 — RALLY WON!")
	else:
		lines.append("Outside the top 3 — no car reward. Re-enter from HQ to try again.")
	return "\n".join(lines)


func _standings_row(entry: Dictionary) -> Label:
	var l := Label.new()
	var placed := int(entry.get("placed", -1))
	var pos_text := "P%d" % placed if placed >= 1 else "DNF"
	var time_text := "WRECKED" if entry.get("dnf", false) else _fmt(int(entry.get("combined_ms", -1)))
	var who := String(entry.get("name", "?"))
	var car := String(entry.get("car_name", ""))
	if car != "":
		who += " (%s)" % car
	var is_player: bool = entry.get("is_player", false)
	l.text = "%s%s — %s — %s" % ["> " if is_player else "", pos_text, who, time_text]
	if is_player:
		l.add_theme_color_override("font_color", UITheme.GOLD)
	return l


# m:ss.cc from milliseconds.
func _fmt(ms: int) -> String:
	if ms < 0:
		return "--:--"
	var seconds := ms / 1000.0
	var minutes := int(seconds / 60.0)
	return "%d:%05.2f" % [minutes, seconds - minutes * 60.0]

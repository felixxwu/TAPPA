extends SceneTree
# Offscreen harness for the corner barriers (features/barriers.md). Renders each
# BarrierSection style on its own, then renders the REAL pipeline — BarrierLayout
# planning a sharp corner and BarrierField building it — so the placement rules
# (outside of the bend, road-facing, surface-driven style) can be checked by eye and
# not just by unit test.
#
#   tools/render_barriers.sh          (xvfb + opengl3 wrapper)
#
# Outputs land in docs/barriers/. Pure tooling — not shipped in the game.

const OUT_DIR := "res://docs/barriers"
const CELL := Vector2i(720, 540)
const CONFIG_PATH := "res://config/game_config.tres"

const SECTION_LEN := 2.0
const CORNER_RADIUS := 12.0     # road CENTERLINE radius of the test corner
const MODULE_X := 9.0           # where the lone-module shot stages its section

var _vp: SubViewport
var _world: Node3D
var _cam: Camera3D
var _run: Node3D
var _params: Dictionary
var _track_width: float


func _init() -> void:
	_render_all()


func _render_all() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_params = _barrier_params()
	_track_width = float(_params["track_width"])
	_build_stage()
	# The stage must be in the tree before the camera can look_at anything.
	await process_frame
	await process_frame

	var module_shots: Array[Image] = []
	var straight_shots: Array[Image] = []
	for style in BarrierSection.Style.values():
		var slug := BarrierSection.style_name(style).to_lower().replace(" ", "_").replace("-", "_")

		# The single 2 m module on its own.
		_lay_module(style)
		_look_from(Vector3(MODULE_X - 2.1, 1.0, 2.3), Vector3(MODULE_X, 0.45, 0.0))
		module_shots.append(await _capture("%s/%s_module.png" % [OUT_DIR, slug]))

		# Modules stitched down a straight, with a car for scale.
		_lay_straight(style)
		_look_from(Vector3(-1.1, 1.6, 6.4), Vector3(3.1, 0.7, -0.6))
		straight_shots.append(await _capture("%s/%s_straight.png" % [OUT_DIR, slug]))

	_save_sheet(module_shots, "%s/sheet_module.png" % OUT_DIR)
	_save_sheet(straight_shots, "%s/sheet_straight.png" % OUT_DIR)

	# The real pipeline on a sharp corner: all-gravel, all-tarmac, and a stage whose
	# gravel→tarmac switch falls mid-corner (the barrier changes with it).
	var corner_shots: Array[Image] = []
	var cases := [
		["corner_gravel", func(_p: Vector2) -> float: return 0.0],
		["corner_tarmac", func(_p: Vector2) -> float: return 1.0],
		["corner_mixed", func(p: Vector2) -> float: return 1.0 if p.y > 2.0 else 0.0],
	]
	for case in cases:
		_lay_planned_corner(case[1])
		_look_from(Vector3(10.4, 2.3, -5.0), Vector3(14.5, 0.9, 7.5))
		corner_shots.append(await _capture("%s/%s.png" % [OUT_DIR, case[0]]))
	_save_sheet(corner_shots, "%s/sheet_corner.png" % OUT_DIR)
	quit()


# The shipped barrier params if the config resource loads standalone, so the renders
# show the real pitch/gap; a hand dict otherwise (the harness is autoload-free, so
# there is no Config singleton to fall back on).
func _barrier_params() -> Dictionary:
	var cfg = load(CONFIG_PATH)
	if cfg != null and cfg.has_method("barrier_render_params"):
		return cfg.barrier_render_params()
	print("NOTE: could not load ", CONFIG_PATH, " — using fallback barrier params")
	return {
		"section_length_m": SECTION_LEN, "road_gap_m": 0.7, "lead_m": 5.0,
		"tarmac_threshold": 0.5, "sink_m": 0.06, "track_width": 7.0,
		"render_distance_m": 0.0, "render_fade_m": 0.0,
	}


# ---------------------------------------------------------------------------
# Stage: viewport, ground, road, a car-sized proxy for scale
# ---------------------------------------------------------------------------
func _build_stage() -> void:
	_vp = SubViewport.new()
	_vp.size = CELL
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.msaa_3d = Viewport.MSAA_2X
	get_root().add_child(_vp)

	_world = Node3D.new()
	_vp.add_child(_world)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.74, 0.86)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.74, 0.78)
	env.ambient_light_energy = 1.0
	we.environment = env
	_world.add_child(we)

	_world.add_child(_flat(Vector2(160, 160), Color(0.44, 0.47, 0.30), 0.0))   # grass verge
	# Straight road down Z at x = 0 for the straight shots; the corner shots lay their
	# own tarmac ring on the same flat ground.
	_world.add_child(_flat(Vector2(_track_width, 160), Color(0.34, 0.33, 0.31), 0.01))

	_run = Node3D.new()
	_world.add_child(_run)

	_cam = Camera3D.new()
	_cam.fov = 62.0
	_world.add_child(_cam)


func _flat(size: Vector2, col: Color, y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = size
	mi.mesh = pm
	mi.material_override = _unshaded(col)
	mi.position = Vector3(0, y, 0)
	return mi


func _unshaded(col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


# A blocky car-sized proxy (4.1 x 1.35 x 1.8 m) so barrier heights can be judged
# against something the size of the player's car.
func _car_proxy(pos: Vector3, yaw: float) -> Node3D:
	var car := Node3D.new()
	car.position = pos
	car.rotation.y = yaw
	car.add_child(_prox_box(Vector3(1.75, 0.55, 4.1), Vector3(0, 0.62, 0), Color(0.72, 0.24, 0.18)))
	car.add_child(_prox_box(Vector3(1.55, 0.42, 2.0), Vector3(0, 1.05, -0.1), Color(0.30, 0.34, 0.40)))
	for sx in [-1.0, 1.0]:
		for sz in [-1.35, 1.35]:
			car.add_child(_prox_box(Vector3(0.26, 0.62, 0.62),
				Vector3(sx * 0.82, 0.32, sz), Color(0.10, 0.10, 0.11)))
	return car


func _prox_box(size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	return MeshUtil.box(size, _unshaded(col), pos)


# ---------------------------------------------------------------------------
# Scenes
# ---------------------------------------------------------------------------
func _clear_run() -> void:
	for c in _run.get_children():
		_run.remove_child(c)
		c.free()


func _section(style: int) -> BarrierSection:
	var s := BarrierSection.new()
	s.style = style
	s.length = SECTION_LEN
	return s


# Place a module at XZ `pos` with its +X (road face) turned toward `road_dir`. The
# same solve BarrierField._module_transform uses.
func _place(s: Node3D, pos: Vector2, road_dir: Vector2) -> void:
	var n := road_dir.normalized()
	s.transform = Transform3D(Basis.looking_at(Vector3(n.y, 0.0, -n.x), Vector3.UP),
		Vector3(pos.x, 0.0, pos.y))


# One module alone on the grass (clear of the road strip), road face toward -X.
func _lay_module(style: int) -> void:
	_clear_run()
	var s := _section(style)
	_run.add_child(s)
	_place(s, Vector2(MODULE_X, 0.0), Vector2(-1.0, 0.0))
	_run.add_child(_nameplate(BarrierSection.style_name(style),
		Vector3(MODULE_X - 0.3, 1.3, 0.0), 0.0028))


# Modules stitched down the straight road, at its right-hand edge.
func _lay_straight(style: int) -> void:
	_clear_run()
	var x := _track_width * 0.5 + float(_params["road_gap_m"])
	for i in range(7):
		var s := _section(style)
		_run.add_child(s)
		_place(s, Vector2(x, -8.0 + i * SECTION_LEN), Vector2(-1.0, 0.0))
	_run.add_child(_car_proxy(Vector3(-0.6, 0.0, -1.6), 0.0))
	_run.add_child(_nameplate(BarrierSection.style_name(style), Vector3(3.0, 2.0, 0.2)))


# The REAL pipeline: a sharp corner planned by BarrierLayout and built by
# BarrierField, with `tarmac_at` standing in for the baked road surface. Nothing here
# picks a side or a style by hand — that is the point of the shot.
func _lay_planned_corner(tarmac_at: Callable) -> void:
	_clear_run()
	var curve := Curve2D.new()
	var steps := 24
	for i in range(steps + 1):
		var a: float = lerpf(-0.55, 1.55, float(i) / float(steps))
		curve.add_point(Vector2(cos(a), sin(a)) * CORNER_RADIUS)
	var start := curve.sample_baked(0.0)
	var pieces := [{
		"corner": "Hairpin", "flip": false, "straight": 0.0,
		"entry_pos": start,
		"entry_heading": (curve.sample_baked(1.0) - start).normalized(),
	}]
	var layout := BarrierLayout.plan(curve, pieces, _params, tarmac_at)
	var field := BarrierField.new()
	_run.add_child(field)
	field.build(layout, null, _params)   # flat ground, so no terrain sampling needed

	_run.add_child(_road_ring(Vector2.ZERO, CORNER_RADIUS - _track_width * 0.5))
	var car_a := 0.15
	var car_pos := Vector2(cos(car_a), sin(car_a)) * CORNER_RADIUS
	_run.add_child(_car_proxy(Vector3(car_pos.x, 0.0, car_pos.y), -car_a))
	var styles := {}
	for entry in layout:
		styles[entry["style"]] = true
	var label := "GRAVEL + TARMAC" if styles.size() > 1 else BarrierSection.style_name(
		layout[0]["style"] if not layout.is_empty() else BarrierSection.Style.ARMCO)
	_run.add_child(_nameplate(label, Vector3(14.0, 4.3, 5.0)))


# A flat tarmac annulus under the corner run, so the barrier reads as roadside.
func _road_ring(centre: Vector2, inner_r: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var steps := 72
	for i in range(steps):
		var a0 := -PI * 0.25 + (i / float(steps)) * PI * 1.1
		var a1 := -PI * 0.25 + ((i + 1) / float(steps)) * PI * 1.1
		var pts := [
			Vector2(cos(a0), sin(a0)) * inner_r, Vector2(cos(a1), sin(a1)) * inner_r,
			Vector2(cos(a1), sin(a1)) * (inner_r + _track_width),
			Vector2(cos(a0), sin(a0)) * (inner_r + _track_width),
		]
		var v := []
		for p in pts:
			v.append(Vector3(centre.x + p.x, 0.02, centre.y + p.y))
		for tri in [[0, 2, 1], [0, 3, 2], [0, 1, 2], [0, 2, 3]]:
			for idx in tri:
				st.set_normal(Vector3.UP)
				st.add_vertex(v[idx])
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _unshaded(Color(0.34, 0.33, 0.31))
	return mi


func _nameplate(text: String, pos: Vector3, pixel_size := 0.006) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = 96
	l.pixel_size = pixel_size
	l.modulate = Color(0.99, 0.98, 0.94)
	l.outline_size = 26
	l.outline_modulate = Color(0.08, 0.08, 0.10)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.position = pos
	return l


# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------
func _look_from(eye: Vector3, target: Vector3) -> void:
	_cam.position = eye
	_cam.look_at(target, Vector3.UP)


func _capture(path: String) -> Image:
	await process_frame
	await process_frame
	await process_frame
	var img := _vp.get_texture().get_image()
	img.save_png(path)
	print("SAVED ", path, " ", img.get_size())
	return img


# Compose shots into one contact sheet, up to 3 per row.
func _save_sheet(shots: Array[Image], path: String) -> void:
	if shots.is_empty():
		return
	var cols: int = mini(3, shots.size())
	var rows := int(ceil(shots.size() / float(cols)))
	var sheet := Image.create_empty(CELL.x * cols, CELL.y * rows, false, shots[0].get_format())
	sheet.fill(Color(0.08, 0.08, 0.09))
	for i in range(shots.size()):
		var dst := Vector2i((i % cols) * CELL.x, (i / cols) * CELL.y)
		sheet.blit_rect(shots[i], Rect2i(Vector2i.ZERO, CELL), dst)
	sheet.save_png(path)
	print("SAVED ", path, " ", sheet.get_size())

extends SceneTree
# Offscreen harness for choosing a corner-barrier look. For every
# BarrierSection.Style it stitches modules end to end — once down a straight and
# once around a sharp corner arc — and renders both, then composes the per-style
# shots into two contact sheets so the candidates can be compared side by side.
#
#   tools/render_barriers.sh          (xvfb + opengl3 wrapper)
#
# Outputs land in docs/barriers/. Pure tooling — not shipped in the game.

const OUT_DIR := "res://docs/barriers"
const CELL := Vector2i(720, 540)

const TRACK_WIDTH := 6.0        # the real in-game road width
const EDGE_INSET := 0.4         # barrier standoff from the road edge
const SECTION_LEN := 2.0
const CORNER_RADIUS := 12.0     # barrier line around a sharp (grade 1 / square) corner
const MODULE_X := 9.0           # where the lone-module shot stages its section (clear of the road)

var _vp: SubViewport
var _world: Node3D
var _cam: Camera3D
var _run: Node3D


func _init() -> void:
	_render_all()


func _render_all() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_build_stage()
	# The stage must be in the tree before the camera can look_at anything.
	await process_frame
	await process_frame

	var module_shots: Array[Image] = []
	var straight_shots: Array[Image] = []
	var corner_shots: Array[Image] = []
	for style in BarrierSection.Style.values():
		var slug := BarrierSection.style_name(style).to_lower().replace(" ", "_").replace("-", "_")

		# 1. the single 2 m module on its own — the unit being chosen.
		_lay_module(style)
		_look_from(Vector3(MODULE_X - 2.1, 1.0, 2.3), Vector3(MODULE_X, 0.45, 0.0))
		module_shots.append(await _capture("%s/%s_module.png" % [OUT_DIR, slug]))

		# 2. modules stitched down a straight, with a car for scale.
		_lay_straight(style)
		_look_from(Vector3(-1.1, 1.6, 6.4), Vector3(3.1, 0.7, -0.6))
		straight_shots.append(await _capture("%s/%s_straight.png" % [OUT_DIR, slug]))

		# 3. the real use case: a run around the outside of a sharp corner.
		_lay_corner(style)
		_look_from(Vector3(7.4, 2.4, -4.6), Vector3(11.0, 0.8, 4.5))
		corner_shots.append(await _capture("%s/%s_corner.png" % [OUT_DIR, slug]))

	_save_sheet(module_shots, "%s/sheet_module.png" % OUT_DIR)
	_save_sheet(straight_shots, "%s/sheet_straight.png" % OUT_DIR)
	_save_sheet(corner_shots, "%s/sheet_corner.png" % OUT_DIR)
	quit()


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

	_world.add_child(_flat(Vector2(120, 120), Color(0.44, 0.47, 0.30), 0.0))   # grass verge
	# Straight road down Z at x = 0, plus a curved apron for the corner shot; the
	# corner run is laid on the same ground, which is flat, so one road strip is
	# enough context for the straight shot and the arc gets its own ring below.
	var road := _flat(Vector2(TRACK_WIDTH, 120), Color(0.34, 0.33, 0.31), 0.01)
	_world.add_child(road)

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
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.position = Vector3(0, y, 0)
	return mi


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
			var w := _prox_box(Vector3(0.26, 0.62, 0.62), Vector3(sx * 0.82, 0.32, sz),
				Color(0.10, 0.10, 0.11))
			car.add_child(w)
	return car


func _prox_box(size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	return MeshUtil.box(size, mat, pos)


# ---------------------------------------------------------------------------
# Runs
# ---------------------------------------------------------------------------
func _clear_run() -> void:
	for c in _run.get_children():
		_run.remove_child(c)
		c.free()


func _section(style: int, index: int) -> BarrierSection:
	var s := BarrierSection.new()
	s.style = style
	s.length = SECTION_LEN
	s.variant_seed = index
	return s


# Place a module at XZ `pos` with its +X (road face) turned toward `road_dir`.
func _place(s: Node3D, pos: Vector2, road_dir: Vector2) -> void:
	var n := road_dir.normalized()
	# Basis.looking_at(d) puts -Z on d and +X on (-d.z, 0, d.x); solving that for
	# +X == n gives the look direction below.
	s.transform = Transform3D(Basis.looking_at(Vector3(n.y, 0.0, -n.x), Vector3.UP),
		Vector3(pos.x, 0.0, pos.y))


# One module alone on the grass (clear of the road strip), road face toward -X.
func _lay_module(style: int) -> void:
	_clear_run()
	var s := _section(style, 0)
	_run.add_child(s)
	_place(s, Vector2(MODULE_X, 0.0), Vector2(-1.0, 0.0))
	_run.add_child(_nameplate(style, Vector3(MODULE_X - 0.3, 1.3, 0.0), 0.0028))


# Seven modules down the straight, at the right-hand road edge, plus the car proxy.
func _lay_straight(style: int) -> void:
	_clear_run()
	var x := TRACK_WIDTH * 0.5 + EDGE_INSET
	for i in range(7):
		var s := _section(style, i)
		_run.add_child(s)
		_place(s, Vector2(x, -8.0 + i * SECTION_LEN), Vector2(-1.0, 0.0))
	_run.add_child(_car_proxy(Vector3(-0.6, 0.0, -1.6), 0.0))
	_run.add_child(_nameplate(style, Vector3(3.0, 2.0, 0.2)))


# A run around the OUTSIDE of a sharp corner: modules stitched at `SECTION_LEN`
# arc pitch around CORNER_RADIUS, with a road ring inside them.
func _lay_corner(style: int) -> void:
	_clear_run()
	var centre := Vector2.ZERO   # the corner's arc centre
	var d_theta := SECTION_LEN / CORNER_RADIUS
	var count := int(ceil((PI * 0.6) / d_theta))
	for i in range(count):
		var th := -PI * 0.15 + (i + 0.5) * d_theta
		var radial := Vector2(cos(th), sin(th))
		var pos := centre + radial * CORNER_RADIUS
		var s := _section(style, i)
		_run.add_child(s)
		_place(s, pos, -radial)   # road side = inward, toward the arc centre
	# Road ring: its OUTER edge sits EDGE_INSET inside the barrier line.
	_run.add_child(_road_ring(centre, CORNER_RADIUS - EDGE_INSET - TRACK_WIDTH))
	# Car proxy mid-road, mid-corner, pointing along the tangent there.
	var car_th := PI * 0.12
	var car_r := CORNER_RADIUS - EDGE_INSET - TRACK_WIDTH * 0.5
	var car_pos := centre + Vector2(cos(car_th), sin(car_th)) * car_r
	_run.add_child(_car_proxy(Vector3(car_pos.x, 0.0, car_pos.y), -car_th))
	_run.add_child(_nameplate(style, Vector3(11.0, 4.3, 4.5)))


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
			Vector2(cos(a1), sin(a1)) * (inner_r + TRACK_WIDTH),
			Vector2(cos(a0), sin(a0)) * (inner_r + TRACK_WIDTH),
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
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.34, 0.33, 0.31)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	return mi


func _nameplate(style: int, pos: Vector3, pixel_size := 0.006) -> Label3D:
	var l := Label3D.new()
	l.text = BarrierSection.style_name(style)
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


# Compose the per-style shots into one 3x2 contact sheet.
func _save_sheet(shots: Array[Image], path: String) -> void:
	if shots.is_empty():
		return
	var cols := 3
	var rows := int(ceil(shots.size() / float(cols)))
	var sheet := Image.create_empty(CELL.x * cols, CELL.y * rows, false, shots[0].get_format())
	sheet.fill(Color(0.08, 0.08, 0.09))
	for i in range(shots.size()):
		var dst := Vector2i((i % cols) * CELL.x, (i / cols) * CELL.y)
		sheet.blit_rect(shots[i], Rect2i(Vector2i.ZERO, CELL), dst)
	sheet.save_png(path)
	print("SAVED ", path, " ", sheet.get_size())

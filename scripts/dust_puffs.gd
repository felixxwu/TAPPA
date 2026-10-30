class_name DustPuffs
extends CpuParticlePool
# Docs: features/dust-puffs.md — update in the same change as this file.
# Tests: tests/headless/test_dust_puffs.gd — extend in the same change.
# Opaque, blocky low-poly dust clouds left behind the rear wheels while the car drives
# on a road (gravel or tarmac). A hand-rolled CPU pool (the ring buffer lives in CpuParticlePool)
# drawn through ONE MultiMesh of ONE flat-shaded blob mesh built at load.
#
# Each puff gets a random tumble and an uneven stretch at birth, so one mesh seen from
# random angles reads as many different clouds. It then grows over its life and, at
# the end, simply disappears (no fade). Size, stretch and tumble all live in the
# instance basis, so growing a puff rewrites 9 basis floats per tick — the mesh never
# changes after load.
#
# Separate from WheelParticles (the small clods thrown on wheelspin): those still fly
# on wheelspin; these are emitted by distance travelled whenever the car is moving on
# a road, grip or no grip.
#
# Tarmac smokes only while a tyre slides (tarmac_smokes). Nothing is raised in the wet.
#
# Colour follows the surface: on gravel it is the gravel's own colour (GameConfig
# dust_puff_color, matched to textures/gravel.jpg, or the region's "dust_color" look key
# matched to its gravel_texture); on tarmac it is a near-white dust_puff_tarmac_color.
# Grass raises nothing.
#
# Created + wired by world.gd._generate_track on a stage and free_roam.gd._ready in
# free roam, next to WheelParticles.

const PUFF_SHADER := preload("res://shaders/dust_puff.gdshader")

# Floats per instance: TRANSFORM_3D (3x4 row-major, origin at 3/7/11) + RGBA.
const STRIDE := 16

# Same surface gate as WheelParticles: on the road footprint and not paved.
const ROAD_WEIGHT_MIN := 0.5
const TARMAC_WEIGHT_MAX := 0.5

# Fixed seed for the blob's vertex jitter, so every run gets the same shape.
const BLOB_SEED := 7

var _car: Node

# Per-slot birth shape: the tumble x stretch basis (unit size), 9 floats row-major.
# The per-tick write is this times the puff's current size.
var _shape: PackedFloat32Array
var _max_life: PackedFloat32Array
# Metres travelled per rear wheel since its last puff (index = rear_wheels index).
var _travel: PackedFloat32Array

# Region override for the GRAVEL dust colour. Alpha 0 = unset (GameConfig.dust_puff_color).
var _color_override := Color(0.0, 0.0, 0.0, 0.0)


func _stride() -> int:
	return STRIDE


func setup(car: Node) -> void:
	_car = car
	_build_pool()


# Seat the region's gravel dust colour (or clear it back to the GameConfig default).
func apply_region_look(look: Dictionary) -> void:
	_color_override = look.get("dust_color", Color(0, 0, 0, 0))


func dust_color() -> Color:
	return _color_override if _color_override.a > 0.0 else Config.data.dust_puff_color


func _build_pool() -> void:
	var cfg: GameConfig = Config.data
	var mat := ShaderMaterial.new()
	mat.shader = PUFF_SHADER
	cfg.apply_car_light(mat)
	mat.set_shader_parameter("camera_hide_m", cfg.dust_puff_camera_hide_m)
	mat.set_shader_parameter("camera_show_m", cfg.dust_puff_camera_show_m)
	material_override = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = build_blob_mesh()
	mm.instance_count = maxi(1, cfg.dust_puff_max)
	multimesh = mm
	_alloc_pool(mm.instance_count)
	_shape = PackedFloat32Array(); _shape.resize(_max * 9)
	_max_life = PackedFloat32Array(); _max_life.resize(_max)
	_travel = PackedFloat32Array()
	_clear()


# A unit-radius icosahedron (20 faces) with its vertices pushed in/out a little so it
# reads as a lumpy cloud rather than a die, flat-shaded: every face gets its own three
# vertices and one shared normal, so the per-vertex lighting comes out as facets.
static func build_blob_mesh() -> ArrayMesh:
	var t := (1.0 + sqrt(5.0)) * 0.5
	var corners: Array[Vector3] = [
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1),
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = BLOB_SEED
	for i in corners.size():
		corners[i] = corners[i].normalized() * rng.randf_range(0.8, 1.1)
	var faces := [
		[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
		[1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
		[3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
		[4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
	]
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	for f in faces:
		var a: Vector3 = corners[f[0]]
		var b: Vector3 = corners[f[1]]
		var c: Vector3 = corners[f[2]]
		var n := (b - a).cross(c - a).normalized()
		# Godot's front faces wind clockwise seen from outside. a, b, c is
		# counter-clockwise from outside exactly when n points outward.
		if n.dot(a + b + c) > 0.0:
			verts.append_array([a, c, b])
		else:
			verts.append_array([a, b, c])
			n = -n
		normals.append_array([n, n, n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# --- Buffer writes -----------------------------------------------------------

# Write slot i's basis as its birth shape scaled to `size` (metres, radius), plus origin.
func _write_transform(i: int, p: Vector3, size: float) -> void:
	var b := i * STRIDE
	var s := i * 9
	_buffer[b + 0] = _shape[s + 0] * size
	_buffer[b + 1] = _shape[s + 1] * size
	_buffer[b + 2] = _shape[s + 2] * size
	_buffer[b + 3] = p.x
	_buffer[b + 4] = _shape[s + 3] * size
	_buffer[b + 5] = _shape[s + 4] * size
	_buffer[b + 6] = _shape[s + 5] * size
	_buffer[b + 7] = p.y
	_buffer[b + 8] = _shape[s + 6] * size
	_buffer[b + 9] = _shape[s + 7] * size
	_buffer[b + 10] = _shape[s + 8] * size
	_buffer[b + 11] = p.z


func _write_color(i: int, c: Color) -> void:
	var b := i * STRIDE
	_buffer[b + 12] = c.r
	_buffer[b + 13] = c.g
	_buffer[b + 14] = c.b
	_buffer[b + 15] = 1.0


# Store slot i's birth shape: a random tumble times an uneven per-axis stretch.
func _set_shape(i: int, basis: Basis) -> void:
	var s := i * 9
	for r in 3:
		for c in 3:
			_shape[s + r * 3 + c] = basis[c][r]  # basis[c] is column c


func _hide_slot(i: int) -> void:
	var b := i * STRIDE
	_buffer[b + 3] = 0.0
	_buffer[b + 7] = HIDE_Y
	_buffer[b + 11] = 0.0


func _build_slot(i: int, p: Vector3) -> void:
	_set_shape(i, Basis.IDENTITY)
	_max_life[i] = 1.0
	_write_transform(i, p, Config.data.dust_puff_size_m)
	_write_color(i, dust_color())


# Puff radius at life fraction t (0 = birth, 1 = death): eases out from the birth size
# to birth x growth, so a puff billows quickly and then hangs.
static func size_at(cfg: GameConfig, t: float) -> float:
	var e := 1.0 - (1.0 - t) * (1.0 - t)
	return cfg.dust_puff_size_m * lerpf(1.0, cfg.dust_puff_growth, clampf(e, 0.0, 1.0))


# --- Tick --------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"dust_puffs", Time.get_ticks_usec() - __t)


func _timed_physics_process(delta: float) -> void:
	if not Config.data.dust_puffs_enabled or multimesh == null:
		return
	var changed := _advance(delta)
	if is_instance_valid(_car) and _car.get("drivetrain") != null:
		if _emit_from_wheels(delta):
			changed = true
	if changed:
		multimesh.buffer = _buffer
		# Weather / time of day can change the light under a live trail (free roam).
		Config.data.apply_car_light(material_override)


# Drift, slow, rise and grow every live puff; a puff past its lifetime just vanishes.
func _advance(delta: float) -> bool:
	if delta <= 0.0 or _alive == 0:
		return false
	var cfg: GameConfig = Config.data
	var drag := maxf(0.0, 1.0 - cfg.dust_puff_drag * delta)
	for i in _max:
		if _life[i] <= 0.0:
			continue
		_life[i] -= delta
		if _life[i] <= 0.0:
			_alive -= 1
			_hide_slot(i)
			continue
		var v := _vel[i] * drag
		_vel[i] = v
		_pos[i] += v * delta
		_write_transform(i, _pos[i], size_at(cfg, 1.0 - _life[i] / _max_life[i]))
	return true


# Drop a puff behind each rear wheel every dust_puff_spacing_m it rolls on road,
# once the car is past dust_puff_min_speed_mps. Distance-based, so the trail density
# along the road is the same at any speed and frame rate.
func _emit_from_wheels(delta: float) -> bool:
	var cfg: GameConfig = Config.data
	var dt = _car.drivetrain
	var terrain = dt.terrain
	if terrain == null or not terrain.has_method("surface_at"):
		return false
	# A wet road raises no dust and no tyre smoke, gravel or tarmac.
	var wet := WeatherLibrary.is_wet(cfg.weather)
	var wheels: Array = dt.rear_wheels
	if _travel.size() != wheels.size():
		_travel.resize(wheels.size())
		_travel.fill(0.0)
	var spacing := maxf(0.05, cfg.dust_puff_spacing_m)
	var r: float = cfg.wheel_radius
	var emitted := false
	for k in wheels.size():
		var wheel = wheels[k]
		if not wheel.is_in_contact():
			continue
		var wpos: Vector3 = wheel.global_position
		var cp := Vector3(wpos.x, wpos.y - r, wpos.z)
		var vel: Vector3 = dt.velocity_at(cp)
		var speed := Vector2(vel.x, vel.z).length()
		var color := Color(0, 0, 0, 0)
		if speed >= cfg.dust_puff_min_speed_mps and not wet:
			var surf: Vector2 = terrain.surface_at(wpos.x, wpos.z)
			color = color_for_surface(cfg, surf)
			# Tarmac only smokes from a tyre that is actually sliding (spinning, locked or
			# skidding sideways: the combined grip usage past dust_puff_tarmac_min_grip).
			# Gravel throws dust from any rolling wheel.
			if surf.y > TARMAC_WEIGHT_MAX and not tarmac_smokes(cfg, dt.wheel_grip_usage(wheel)):
				color = Color(0, 0, 0, 0)
		if color.a <= 0.0:
			_travel[k] = 0.0
			continue
		_travel[k] += speed * delta
		while _travel[k] >= spacing:
			_travel[k] -= spacing
			_emit_puff(cfg, cp, vel, color)
			emitted = true
	return emitted


# The puff colour for a surface_at sample (road_weight, tarmac_weight): the gravel's
# colour on a gravel road, near-white on tarmac, and alpha 0 (no dust) on grass.
func color_for_surface(cfg: GameConfig, surf: Vector2) -> Color:
	if surf.x < ROAD_WEIGHT_MIN:
		return Color(0, 0, 0, 0)
	if surf.y > TARMAC_WEIGHT_MAX:
		return cfg.dust_puff_tarmac_color
	return dust_color()


# Whether a tyre at this combined grip usage smokes on (dry) tarmac.
static func tarmac_smokes(cfg: GameConfig, grip_usage: float) -> bool:
	return grip_usage >= cfg.dust_puff_tarmac_min_grip


func _emit_puff(cfg: GameConfig, cp: Vector3, car_vel: Vector3, c: Color) -> void:
	var scatter := cfg.dust_puff_scatter_mps
	var vel := car_vel * cfg.dust_puff_inherit + Vector3(
		randf_range(-scatter, scatter),
		cfg.dust_puff_rise_mps + randf_range(0.0, scatter),
		randf_range(-scatter, scatter))
	# Spawn sitting on the ground rather than half-buried in it, scattered a little
	# across the tyre's width so the trail isn't a single file of beads.
	var pos := cp + Vector3(
		randf_range(-0.25, 0.25), cfg.dust_puff_size_m, randf_range(-0.25, 0.25))
	var life := cfg.dust_puff_lifetime_s * randf_range(0.8, 1.2)
	_emit_slot(pos, vel, life)
	_max_life[_next] = life
	# Uneven stretch per axis, on top of an overall size spread between puffs.
	var stretch := Vector3(randf_range(0.75, 1.25), randf_range(0.7, 1.0), randf_range(0.75, 1.25)) \
		* randf_range(0.7, 1.3)
	var tumble := Basis(Quaternion(
		randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized())
	_set_shape(_next, tumble * Basis.from_scale(stretch))
	_write_transform(_next, pos, size_at(cfg, 0.0))
	var j := cfg.dust_puff_color_jitter
	var f := 1.0 + randf_range(-j, j)
	_write_color(_next, Color(c.r * f, c.g * f, c.b * f))

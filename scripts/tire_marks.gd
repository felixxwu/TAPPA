class_name TireMarks
extends Node3D
# Lays tyre marks behind the car's wheels while it drives ON the road. The
# gl_compatibility renderer has no Decals, so each wheel gets a persistent ribbon
# mesh (an ArrayMesh rebuilt as segments are appended); each segment carries a
# vertex colour so one ribbon can show both surfaces. See features/tire-marks.md.
#
# Two surfaces, two behaviours:
#   - GRAVEL: a solid gravel-coloured rut laid continuously while moving.
#   - TARMAC: a dark skidmark laid ONLY while a driven wheel is spinning (the same
#     wheelspin slip gate the gravel spray uses in wheel_particles.gd) — a cleanly
#     rolling wheel on tarmac leaves nothing.
# The grass off the road footprint never marks.
#
# Created + wired by world.gd._generate_track once the centerline exists; re-targeted
# on a car swap (world.gd.cycle_car). Marks are capped per wheel (a ring buffer).

# Windowed nearest-offset search of the centerline (around the car's last offset),
# mirroring TrackProgress — local, so it never snaps to a far part of a winding road.
const SEARCH_BACK_M := 30.0
const SEARCH_FWD_M := 60.0
const SEARCH_STEP_M := 1.0
# Tighter window (around the car's offset) for each wheel's own nearest-point gate.
const WHEEL_WINDOW_M := 20.0
# Surface split: a wheel reads as tarmac above this tarmac_weight (the same 0.5 the
# road colour/grip feather across), gravel at or below it. Gravel lays a continuous
# rut; tarmac lays a skidmark only under wheelspin.
const TARMAC_WEIGHT_MAX := 0.5

var _centerline: Curve2D
var _baked_length := 0.0
# Resampled centerline point table, SHARED with TrackProgress (TrackProgress.baked_points
# caches one table per curve, so the two systems resample the track once between them).
# Every per-tick nearest-point probe below reads this array instead of calling
# Curve2D.sample_baked — the car scan plus four wheel scans were ~255 engine calls a
# tick. Lookups interpolate (TrackProgress.point_on), so mark placement is not
# quantised to the table spacing.
var _pts := PackedVector2Array()
var _terrain: Node          # TerrainManager (height_at), or null on flat fixtures
var _car: Node              # the VehicleBody3D (read for linear_velocity)
var _half_width := 3.0      # road half-width (track_width * 0.5)
var _offset := 0.0          # cached windowed nearest-offset for the car centre
var _material: StandardMaterial3D
var _warm_mi: MeshInstance3D  # throwaway quad used by warm_up() to prime the shader

# Parallel per-wheel arrays (index == wheel).
var _wheels: Array = []     # nodes exposing is_in_contact() + global_position
var _ribbons: Array = []    # MeshInstance3D, one ribbon per wheel
var _pairs: Array = []      # per wheel: Array of [left:Vector3, right:Vector3] (ring buffer)
var _last_pos: Array = []   # per wheel: Vector2 last emit XZ, or null = ribbon broken
# Incremental triangle buffers, kept in lock-step with _pairs so a new segment
# appends one quad (and a dropped one trims a quad off the front) instead of
# rebuilding the whole ribbon from _pairs on every emit. _build_ribbon() is the
# reference these must always equal (asserted in tests).
#
# Storage is a FIXED-CAPACITY RING per wheel, so laying marks at speed allocates
# nothing: appending writes 6 verts into the slot at (head + count), and dropping
# the oldest quad just advances head — no array is ever shifted or re-sliced.
# The rings for every wheel live in two flat member PackedArrays (`_ring_verts` /
# `_ring_cols`) rather than nested inside an Array: a member Packed array is
# uniquely referenced, so indexed writes land in place instead of triggering a
# copy-on-write duplication of the whole buffer on every emit.
# `_verts` / `_cols` are the COMPACT, oldest-to-newest snapshot of each ring,
# materialised only at upload time (_sync_snapshot) — that's what the mesh gets,
# and what tests compare against _build_ribbon.
const RING_QUAD_VERTS := 6  # verts per ribbon quad (two triangles)
var _ring_verts := PackedVector3Array()
var _ring_cols := PackedColorArray()
var _ring_head := PackedInt32Array()   # per wheel: oldest quad's slot
var _ring_count := PackedInt32Array()  # per wheel: live quads
var _ring_cap := 0                     # quad slots per wheel (0 = not built yet)
# Scratch reused by _sync_snapshot so building the compact view costs no growth.
var _snap_verts := PackedVector3Array()
var _snap_cols := PackedColorArray()
# Reused surface-array scratch for _upload (Mesh.ARRAY_MAX slots, allocated once).
var _surface_arrays: Array = []
var _verts: Array = []      # per wheel: PackedVector3Array (ribbon triangle verts)
var _cols: Array = []       # per wheel: PackedColorArray (matching per-vertex colours)


# Wire to a freshly generated track + the current car. half_width is the road
# half-width (track_width * 0.5) the marks are gated to.
func setup(centerline: Curve2D, car: Node, terrain: Node, half_width: float) -> void:
	_centerline = centerline
	_baked_length = centerline.get_baked_length()
	_pts = TrackProgress.baked_points(centerline)
	_terrain = terrain
	_half_width = half_width
	_offset = 0.0
	_ensure_material()
	_retarget_internal(car)


# Re-point at a freshly spawned car (a car swap) and clear all marks.
func retarget(car: Node) -> void:
	_offset = 0.0
	_retarget_internal(car)


func _retarget_internal(car: Node) -> void:
	_car = car
	for r in _ribbons:
		if is_instance_valid(r):
			r.queue_free()
	_wheels = _collect_wheels(car)
	_ribbons = []
	_pairs = []
	_last_pos = []
	_verts = []
	_cols = []
	# Force _ensure_ring() to (re)build the rings for the new wheel set.
	_ring_cap = 0
	_ring_head = PackedInt32Array()
	_ring_count = PackedInt32Array()
	for i in _wheels.size():
		var mi := MeshInstance3D.new()
		mi.mesh = ArrayMesh.new()
		add_child(mi)
		_ribbons.append(mi)
		_pairs.append([])
		_last_pos.append(null)
		_verts.append(PackedVector3Array())
		_cols.append(PackedColorArray())


# A car's wheels — duck-typed on is_in_contact() so VehicleWheel3D (real play) and
# test stubs are both found, without depending on the concrete class here.
func _collect_wheels(car: Node) -> Array:
	var out: Array = []
	if car == null:
		return out
	for n in car.find_children("*", "Node3D", true, false):
		if n.has_method("is_in_contact"):
			out.append(n)
	return out


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"tire_marks", Time.get_ticks_usec() - __t)


func _timed_physics_process(_delta: float) -> void:
	if not Config.data.tire_marks_enabled or _centerline == null or not is_instance_valid(_car):
		return
	# Below the speed floor (parked / countdown): break every ribbon so a later
	# segment doesn't draw a line across the stop.
	if _car.linear_velocity.length() < Config.data.tire_mark_min_speed_mps:
		for i in _last_pos.size():
			_last_pos[i] = null
		return
	# Advance the shared offset cache from the car, then gate each wheel by ITS OWN
	# nearest centerline point (not the car's road frame — on a corner a wheel that's
	# on the road but ahead on the curve reads as far off-axis against the car's
	# tangent and would be wrongly rejected).
	_offset = _windowed_offset(Vector2(_car.global_position.x, _car.global_position.z))
	var gate := _half_width + Config.data.tire_mark_gravel_margin_m
	var step := Config.data.tire_mark_segment_step_m
	for i in _wheels.size():
		var wheel: Node = _wheels[i]
		if not wheel.is_in_contact():
			_last_pos[i] = null
			continue
		var wpos: Vector3 = wheel.global_position
		var wxz := Vector2(wpos.x, wpos.z)
		var w_off := _wheel_offset(wxz)
		# True distance to the wheel's nearest road point: off the road (incl. the
		# verge margin) — i.e. on the grass — breaks the ribbon.
		if wxz.distance_to(_point_at(w_off)) > gate:
			_last_pos[i] = null
			continue
		# On the road — pick the mark by surface. Gravel lays a continuous rut; tarmac
		# lays a dark skidmark ONLY while this driven wheel spins (a cleanly rolling
		# wheel on tarmac leaves nothing). Terrain is null on the flat test fixtures,
		# where every surface reads as gravel.
		var color: Color = Config.data.tire_mark_color
		if _terrain != null and _terrain.has_method("surface_at"):
			var surf: Vector2 = _terrain.surface_at(wpos.x, wpos.z)
			if surf.y > TARMAC_WEIGHT_MAX:
				if not _wheel_spinning(wheel, wpos):
					_last_pos[i] = null
					continue
				color = Config.data.tire_mark_tarmac_color
		if _last_pos[i] == null or wxz.distance_to(_last_pos[i]) >= step:
			# A fresh point after a break (airborne / off the gravel / not skidding)
			# starts a NEW strip — it must NOT bridge to the last point across the gap.
			var connected: bool = _last_pos[i] != null
			_emit_segment(i, wpos, _normal_at(w_off), connected, color)
			_last_pos[i] = wxz


# Is this DRIVEN wheel spinning faster than the ground (the tarmac-skid gate)? Reads
# the car's drivetrain exactly as wheel_particles.gd does: wheelspin is the tread
# surface speed (omega x radius) OUTRUNNING the ground along the roll direction by
# more than wheel_particle_min_slip_mps. Undriven wheels free-roll (never skid here),
# and with no drivetrain (flat test fixtures) we can't tell, so report not spinning.
func _wheel_spinning(wheel: Node, wpos: Vector3) -> bool:
	var dt = _car.get("drivetrain")
	if dt == null or not dt.is_wheel_driven(wheel):
		return false
	var r: float = Config.data.wheel_radius
	var cp := Vector3(wpos.x, wpos.y - r, wpos.z)
	var surface_speed: float = dt.wheel_omega(wheel) * r
	var roll: float = dt.wheel_forward(wheel).dot(dt.velocity_at(cp))
	return surface_speed - roll >= Config.data.wheel_particle_min_slip_mps


# Append one ribbon point for a wheel (left/right of its ground contact, across the
# road normal), cap the ring buffer, and rebuild that wheel's surface. The contact
# height comes from the WHEEL (hub Y − wheel radius), not terrain.height_at — near
# the road the terrain mesh is flattened to the baked road height the car sits on,
# so the raw noise height would sink the ribbon under the road in cuts/dips.
func _emit_segment(i: int, wheel_pos: Vector3, road_n: Vector2, connected: bool, color: Color) -> void:
	var y := wheel_pos.y - Config.data.wheel_radius + Config.data.tire_mark_ground_offset_m
	var center := Vector3(wheel_pos.x, y, wheel_pos.z)
	var across := Vector3(road_n.x, 0.0, road_n.y) * (Config.data.tire_mark_width_m * 0.5)
	var pairs: Array = _pairs[i]
	var left := center + across
	var right := center - across
	var cap: int = maxi(2, Config.data.tire_mark_max_segments)
	_ensure_ring(cap)
	# Make room for the point about to be appended BEFORE appending it (the popped
	# 4-tuple is then recycled below, so a steady-state emit allocates nothing).
	# Order is equivalent to appending first and popping down to `cap`: pops only
	# ever remove the FRONT, and the quad append below only touches the BACK.
	var recycled: Variant = null
	while pairs.size() >= cap:
		recycled = pairs.pop_front()
		# The quad the dropped front point fed (its bridge to the next point) is the
		# oldest one in the buffer; it exists iff the point NOW at the front was laid
		# `connected` (a strip start there means no quad crossed the drop).
		if not pairs.is_empty() and bool(pairs[0][2]):
			_drop_front_quad(i)
	# Bridge a quad back to the previous point unless this starts a new strip (a
	# break leaves a real gap). The quad takes the LATER point's colour, matching
	# _build_ribbon. `connected` implies a prior consecutive point still in the ring
	# (pops only drop the oldest), but guard anyway.
	if connected and not pairs.is_empty():
		var prev: Array = pairs[pairs.size() - 1]
		_append_quad(i, prev[0], prev[1], left, right, color)
	# [left, right, connected, color] — `connected` = bridge a quad back to the
	# previous point (a strip start after a break is false, so jumps leave a real
	# gap); `color` is the per-segment vertex colour (gravel rut vs tarmac skid).
	if recycled is Array:
		var slot: Array = recycled
		slot[0] = left
		slot[1] = right
		slot[2] = connected
		slot[3] = color
		pairs.append(slot)
	else:
		pairs.append([left, right, connected, color])
	_upload(i)


# Size the per-wheel quad rings to `cap` slots (one per possible segment point —
# a ribbon of n points holds at most n-1 quads, so that's headroom). Only runs on
# the first emit after a retarget or if the configured cap changes at runtime,
# never on the steady-state hot path; existing geometry is rebuilt from _pairs via
# the reference builder so the invariant "_verts == _build_ribbon(_pairs)" holds.
func _ensure_ring(cap: int) -> void:
	if cap == _ring_cap and _ring_head.size() == _wheels.size():
		return
	_ring_cap = cap
	var wheels := _wheels.size()
	_ring_head.resize(wheels)
	_ring_count.resize(wheels)
	_ring_verts.resize(wheels * cap * RING_QUAD_VERTS)
	_ring_cols.resize(wheels * cap * RING_QUAD_VERTS)
	for w in wheels:
		_ring_head[w] = 0
		_ring_count[w] = 0
		var rebuilt: Dictionary = _build_ribbon(_pairs[w])
		var verts: PackedVector3Array = rebuilt["verts"]
		var cols: PackedColorArray = rebuilt["cols"]
		@warning_ignore("integer_division")  # floor division: verts is always a whole number of quads
		var quads: int = mini(verts.size() / RING_QUAD_VERTS, cap)
		var base: int = w * cap * RING_QUAD_VERTS
		# Keep the NEWEST quads if the cap shrank (the ring drops from the front).
		@warning_ignore("integer_division")
		var skip: int = verts.size() / RING_QUAD_VERTS - quads
		for n in quads * RING_QUAD_VERTS:
			_ring_verts[base + n] = verts[skip * RING_QUAD_VERTS + n]
			_ring_cols[base + n] = cols[skip * RING_QUAD_VERTS + n]
		_ring_count[w] = quads


# Append one ribbon quad (two triangles, 6 verts) bridging the previous segment
# pair (l0/r0) to the new one (l1/r1). Cull disabled, so winding is cosmetic.
func _append_quad(i: int, l0: Vector3, r0: Vector3, l1: Vector3, r1: Vector3, color: Color) -> void:
	if _ring_cap <= 0:
		return
	# Full ring (can't happen while quads <= points-1, but never overwrite the head).
	if _ring_count[i] >= _ring_cap:
		_drop_front_quad(i)
	var slot: int = (_ring_head[i] + _ring_count[i]) % _ring_cap
	var b: int = (i * _ring_cap + slot) * RING_QUAD_VERTS
	_ring_verts[b] = l0; _ring_verts[b + 1] = l1; _ring_verts[b + 2] = r0
	_ring_verts[b + 3] = r0; _ring_verts[b + 4] = l1; _ring_verts[b + 5] = r1
	for n in RING_QUAD_VERTS:
		_ring_cols[b + n] = color
	_ring_count[i] += 1


# Drop the oldest quad off a wheel's ring — O(1), just advance the head.
func _drop_front_quad(i: int) -> void:
	if _ring_cap <= 0 or _ring_count[i] <= 0:
		return
	_ring_head[i] = (_ring_head[i] + 1) % _ring_cap
	_ring_count[i] -= 1


# Materialise a wheel's ring into the compact oldest-to-newest _verts/_cols view
# the mesh (and the tests) consume. Written through reused member scratch buffers,
# so this doesn't grow the heap once the ribbon reaches its steady-state length.
func _sync_snapshot(i: int) -> void:
	var n: int = maxi(_ring_count[i], 0) * RING_QUAD_VERTS if _ring_cap > 0 else 0
	if _snap_verts.size() != n:
		_snap_verts.resize(n)
		_snap_cols.resize(n)
	for q in maxi(_ring_count[i], 0):
		var src: int = (i * _ring_cap + (_ring_head[i] + q) % _ring_cap) * RING_QUAD_VERTS
		var dst: int = q * RING_QUAD_VERTS
		for k in RING_QUAD_VERTS:
			_snap_verts[dst + k] = _ring_verts[src + k]
			_snap_cols[dst + k] = _ring_cols[src + k]
	_verts[i] = _snap_verts
	_cols[i] = _snap_cols


# Push the maintained triangle buffer for a wheel onto its ribbon ArrayMesh.
func _upload(i: int) -> void:
	_sync_snapshot(i)
	var mesh := _ribbons[i].mesh as ArrayMesh
	mesh.clear_surfaces()
	var verts: PackedVector3Array = _verts[i]
	if verts.is_empty():
		return
	if _surface_arrays.size() != Mesh.ARRAY_MAX:
		_surface_arrays.resize(Mesh.ARRAY_MAX)
	_surface_arrays[Mesh.ARRAY_VERTEX] = verts
	_surface_arrays[Mesh.ARRAY_COLOR] = _cols[i]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _surface_arrays)
	mesh.surface_set_material(0, _material)


# Reference full-ribbon build from a segment-pair array: a quad between each
# CONSECUTIVE pair, but only where the later point is `connected` (a break leaves
# a gap instead of a stretched quad). The incremental buffers maintained above
# must always equal this — asserted in test_tire_marks. Kept as the source of
# truth for that geometry, not called on the hot path.
static func _build_ribbon(pairs: Array) -> Dictionary:
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	for k in range(1, pairs.size()):
		if not bool(pairs[k][2]):
			continue
		var l0: Vector3 = pairs[k - 1][0]
		var r0: Vector3 = pairs[k - 1][1]
		var l1: Vector3 = pairs[k][0]
		var r1: Vector3 = pairs[k][1]
		verts.append(l0); verts.append(l1); verts.append(r0)
		verts.append(r0); verts.append(l1); verts.append(r1)
		var col: Color = pairs[k][3]
		for _v in 6:
			cols.append(col)
	return {"verts": verts, "cols": cols}


# The left road normal at an offset (for the ribbon's width direction).
func _normal_at(offset: float) -> Vector2:
	var p := _point_at(offset)
	var tangent := _point_at(minf(offset + 1.0, _baked_length)) - p
	if tangent.length() < 0.001:
		tangent = p - _point_at(maxf(offset - 1.0, 0.0))
	if tangent.length() < 0.001:
		tangent = Vector2(0.0, 1.0)
	tangent = tangent.normalized()
	return Vector2(-tangent.y, tangent.x)


# The car's nearest offset, searched in a wide window around the last value.
func _windowed_offset(here: Vector2) -> float:
	return _search_offset(here, _offset - SEARCH_BACK_M, _offset + SEARCH_FWD_M)


# A wheel's nearest offset — a tighter window around the car's offset (wheels are
# within a couple of metres of the car along the track).
func _wheel_offset(here: Vector2) -> float:
	return _search_offset(here, _offset - WHEEL_WINDOW_M, _offset + WHEEL_WINDOW_M)


func _search_offset(here: Vector2, from_m: float, to_m: float) -> float:
	var lo := maxf(0.0, from_m)
	var hi := minf(_baked_length, to_m)
	var best_o := lo
	var best_d := INF
	var o := lo
	while o <= hi:
		var d := here.distance_squared_to(_point_at(o))
		if d < best_d:
			best_d = d
			best_o = o
		o += SEARCH_STEP_M
	return best_o


# Point on the centerline at a baked offset, off the shared table (see _pts).
func _point_at(offset: float) -> Vector2:
	return TrackProgress.point_on(_pts, _baked_length, offset)


# Force the ribbon material's shader variant to compile NOW (during track
# generation, behind the loading overlay) instead of on the first mark laid. Under
# gl_compatibility a material compiles on its first VISIBLE draw, and the per-wheel
# ribbons are empty until a wheel marks — so we draw one throwaway quad (vertex
# colour, same material) in front of the camera for a rendered frame, then
# clear_warm_up() frees it. See features/tire-marks.md.
func warm_up(pos: Vector3) -> void:
	_ensure_material()
	if _warm_mi == null:
		_warm_mi = MeshInstance3D.new()
		add_child(_warm_mi)
	var s := 0.5
	var verts := PackedVector3Array([
		pos + Vector3(-s, 0.0, -s), pos + Vector3(-s, 0.0, s), pos + Vector3(s, 0.0, -s),
		pos + Vector3(s, 0.0, -s), pos + Vector3(-s, 0.0, s), pos + Vector3(s, 0.0, s),
	])
	var cols := PackedColorArray()
	for _v in 6:
		cols.append(Config.data.tire_mark_color)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, _material)
	_warm_mi.mesh = mesh


# Undo warm_up(): drop the throwaway warm-up quad.
func clear_warm_up() -> void:
	if is_instance_valid(_warm_mi):
		_warm_mi.queue_free()
	_warm_mi = null


func _ensure_material() -> void:
	if _material != null:
		return
	# Each segment carries its own colour (gravel rut vs tarmac skid) as a vertex
	# colour, so one ribbon mesh per wheel can show both surfaces.
	_material = PS1Material.unshaded(null, true)
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED


# --- Readouts (tests) --------------------------------------------------------

func wheel_count() -> int:
	return _wheels.size()


func segment_count(wheel: int) -> int:
	return (_pairs[wheel] as Array).size() if wheel >= 0 and wheel < _pairs.size() else 0

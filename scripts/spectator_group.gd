class_name SpectatorGroup
extends Node3D
# One crowd of roadside spectators that react to the car. While upright they are
# NOT physics bodies at all — just agent data (XZ position/velocity/home) plus a
# single MultiMesh for rendering — so 50+ of them cost almost nothing and never
# touch the vehicle solver (no MAX_CONTACTS_REPORTED pressure, no HP damage; they
# are not in DamageModel.OBSTACLE_GROUP). See todo/roadside-spectators.md.
#
# Each physics tick (only while the car is within `active_radius_m`, an LOD gate)
# the group batch-steers every member with a few preferences, arbitrated by
# priority (see `combine`) and clamped to max_speed_mps:
#   - flee       : move away from the car inside flee_radius_m (a strong near-field
#                  term, so the crowd visibly parts/jostles as the car pushes through
#                  — the "light push")
#   - separation : keep ~separation_m from group neighbours; blended WITH flee at the
#                  top tier so a fleeing crowd fans out sideways instead of piling onto
#                  one point and freezing ("stuck in a crowd")
#   - road       : avoid the carriageway (probes the rasterised road_cells)
#   - obstacle   : avoid trees (probes a grid of tree points)
#   - anchor     : drift back home when nothing is pushing them
#
# When the car actually reaches a member (within knock_radius_m) that member flips
# to a knocked-over RAGDOLL: a real RigidBody3D capsule (single body — the model
# has no armature) launched along the car's velocity. The whole launch impulse scales
# with the car's speed (including the upward kick, which is a fraction of the launch,
# not a constant), so crawling into the crowd topples them gently instead of flinging
# them skyward. Ragdolls collide with the ground but are masked off the car, so a crowd
# can never bog it down. Once the car is well past (despawn_behind_m behind it), the
# ragdoll is freed.

# --- agent state (parallel arrays, index = member) ----------------------------
var _pos: PackedVector2Array      # world XZ
var _vel: PackedVector2Array      # XZ velocity
var _home: PackedVector2Array     # spawn anchor (return target)
var _upright: PackedByteArray     # 1 = standing agent, 0 = knocked (now a ragdoll)
var _yaw: PackedFloat32Array      # facing, radians

var _car: Node                    # VehicleBody3D-ish: global_transform (+ linear_velocity)
var _terrain: Node                # TerrainManager (height_at) or null on flat fixtures
var _terrain_has_height := false  # cached in setup(); _ground() runs per agent per frame
var _road_cells: Dictionary       # Vector2i -> true, the visible carriageway
var _tree_grid: Dictionary        # Vector2i -> PackedVector2Array (built by SpectatorScatter)
var _p: Dictionary                # spectator_params() snapshot

var _mm: MultiMesh
var _foot_offset := 0.0           # lifts the mesh so its feet sit on the ground
var _capsule_height := 1.6
var _capsule_radius := 0.3
var _center := Vector2.ZERO       # group centroid, for the LOD distance test
var _mm_origin := Vector3.ZERO     # MultiMeshInstance3D node origin (= centroid); instance transforms are relative to it
var _ragdolls: Array[RigidBody3D] = []
var _rng := RandomNumberGenerator.new()
var _drag_strength := 0.0         # fraction of horizontal speed a knock sheds (soft drag)
var _sim_accum := 0.0             # delta banked since the last steered tick (decimation)
var _sim_stagger := 0             # per-group tick phase, so groups don't all steer together
var _warm_mi: MeshInstance3D      # throwaway single-instance crowd mesh (ragdoll variant warm-up)


# Wire a freshly placed group. `member_positions` come from SpectatorScatter.members.
func setup(member_positions: PackedVector2Array, car: Node, terrain: Node,
		road_cells: Dictionary, tree_grid: Dictionary, params: Dictionary) -> void:
	_car = car
	_terrain = terrain
	_terrain_has_height = terrain != null and terrain.has_method("height_at")
	_road_cells = road_cells
	_tree_grid = tree_grid
	_p = params
	_drag_strength = float(params.get("drag_strength", 0.0))
	_rng.seed = int(params.get("seed", 0))

	var n := member_positions.size()
	_pos = member_positions.duplicate()
	_home = member_positions.duplicate()
	_vel = PackedVector2Array(); _vel.resize(n)
	_upright = PackedByteArray(); _upright.resize(n)
	_yaw = PackedFloat32Array(); _yaw.resize(n)
	for i in n:
		_upright[i] = 1
		_center += _pos[i]
	if n > 0:
		_center /= float(n)
	# Spread the decimated steer tick across groups by a stable phase from the
	# centroid, so not every active group recomputes on the same physics frame.
	_sim_stagger = absi(int(_center.x) + int(_center.y) * 7)

	# Shared figure mesh + foot offset (Crowd owns them, so the live crowd can't drift
	# from the decorative ones); the capsule dims are this sim's own concern.
	var mesh := Crowd.mesh()
	if mesh != null:
		var aabb := mesh.get_aabb()
		_foot_offset = Crowd.foot_offset(mesh)
		_capsule_height = maxf(aabb.size.y, 0.2)
		_capsule_radius = maxf(maxf(aabb.size.x, aabb.size.z) * 0.5, 0.1)
	_build_multimesh(mesh, n)
	_refresh_all_instances()


func _build_multimesh(mesh: Mesh, n: int) -> void:
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Crowd"
	# Anchor the (single) instance node at the group centroid so its ONE
	# visibility_range test measures camera→crowd distance rather than
	# camera→world-origin; instance transforms below are written RELATIVE to it.
	_mm_origin = Vector3(_center.x, _ground(_center.x, _center.y), _center.y)
	mmi.position = _mm_origin
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = mesh
	_mm.instance_count = n
	mmi.multimesh = _mm
	# Shared world-prop render distance (params carry cfg.tree_render_distance_m /
	# tree_render_fade_m) so the crowd pops in at the same range as the surrounding
	# foliage/signs. 0 = uncapped (flat fixtures leave it disabled).
	var end_m := float(_p.get("render_distance_m", 0.0))
	if end_m > 0.0:
		mmi.visibility_range_end = end_m
		mmi.visibility_range_end_margin = float(_p.get("render_fade_m", 0.0))
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mmi)


# --- steering forces (pure; unit-tested directly) -----------------------------

# Push away from group neighbours closer than `radius` (sum of inverse-weighted
# offsets). Zero when nobody is too close.
#
# Pass a `grid` from `build_separation_grid` (cell size >= radius) to bound the
# work: only the 3x3 cell neighbourhood around member i is scanned instead of all
# N members, turning the per-tick crowd cost from O(N^2) to ~O(N) for a bounded
# density. With no grid (the default) it falls back to the full O(N) scan — used by
# the direct unit tests and safe for tiny groups. Both paths compute the identical
# force (the grid only prunes members that are provably beyond `radius`).
static func separation_force(i: int, positions: PackedVector2Array, upright: PackedByteArray,
		radius: float, grid: Dictionary = {}, cell: float = 0.0) -> Vector2:
	var force := Vector2.ZERO
	if radius <= 0.0:
		return force
	var here := positions[i]
	if grid.is_empty() or cell <= 0.0:
		for j in positions.size():
			if j == i or upright[j] == 0:
				continue
			var d := here.distance_to(positions[j])
			if d > 0.0001 and d < radius:
				force += (here - positions[j]) / d * (1.0 - d / radius)
		return force
	var base := SpatialGrid.cell_key(here, cell)
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			var idxs: PackedInt32Array = grid.get(Vector2i(base.x + ox, base.y + oz), PackedInt32Array())
			for j in idxs:
				if j == i or upright[j] == 0:
					continue
				var d := here.distance_to(positions[j])
				if d > 0.0001 and d < radius:
					force += (here - positions[j]) / d * (1.0 - d / radius)
	return force


# Bin the upright members' start-of-tick positions into a SpatialGrid (index grid)
# for the bounded separation query above. Cell = separation radius so the 3x3
# neighbourhood is guaranteed to cover it. Knocked (ragdoll) members are skipped —
# they exert no separation force. Built once per tick in _timed_physics_process.
static func build_separation_grid(positions: PackedVector2Array, upright: PackedByteArray, cell: float) -> Dictionary:
	var grid := {}
	if cell <= 0.0:
		return grid
	for i in positions.size():
		if upright[i] == 0:
			continue
		var key := SpatialGrid.cell_key(positions[i], cell)
		if not grid.has(key):
			grid[key] = PackedInt32Array()
		grid[key].append(i)
	return grid


# Push directly away from the car, scaled up near-field (squared falloff) so the
# crowd parts hard as the car arrives. Zero beyond `radius`.
static func flee_force(pos: Vector2, car_pos: Vector2, radius: float) -> Vector2:
	if radius <= 0.0:
		return Vector2.ZERO
	var away := pos - car_pos
	var d := away.length()
	if d >= radius or d <= 0.0001:
		return Vector2.ZERO
	var t := 1.0 - d / radius
	return away / d * (t * t)


# Push off the carriageway: probe 8 directions at `probe` metres; each direction
# whose cell is road contributes a push the opposite way. Standing on the road
# yields a strong outward gradient.
static func road_force(pos: Vector2, road_cells: Dictionary, probe: float) -> Vector2:
	if road_cells.is_empty() or probe <= 0.0:
		return Vector2.ZERO
	const DIRS := [
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
		Vector2(0.707, 0.707), Vector2(-0.707, 0.707),
		Vector2(0.707, -0.707), Vector2(-0.707, -0.707)]
	var force := Vector2.ZERO
	for d in DIRS:
		var q: Vector2 = pos + d * probe
		if ScatterMath.on_road(q, road_cells):
			force -= d
	return force


# Push away from nearby tree points (3x3 grid neighbourhood), like flee but for
# static obstacles.
static func obstacle_force(pos: Vector2, grid: Dictionary, cell: float, radius: float) -> Vector2:
	var force := Vector2.ZERO
	if grid.is_empty() or cell <= 0.0 or radius <= 0.0:
		return force
	var base := SpatialGrid.cell_key(pos, cell)
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			var arr: PackedVector2Array = grid.get(Vector2i(base.x + ox, base.y + oz), PackedVector2Array())
			for q in arr:
				var d := pos.distance_to(q)
				if d > 0.0001 and d < radius:
					force += (pos - q) / d * (1.0 - d / radius)
	return force


# Gentle pull back toward the spawn anchor, ignored within `dead_zone` so settled
# agents don't jitter on the spot.
static func anchor_force(pos: Vector2, home: Vector2, dead_zone: float) -> Vector2:
	var to_home := home - pos
	if to_home.length() <= dead_zone:
		return Vector2.ZERO
	return to_home.normalized()


static func clamp_speed(v: Vector2, max_speed: float) -> Vector2:
	if v.length() > max_speed:
		return v.normalized() * max_speed
	return v


# Vertical placement of a knocked ragdoll. The body origin sits at the capsule
# centre (= figure mid-height above `ground`), so the auto centre-of-mass of the
# single centred capsule is at the figure's middle — it tumbles about its waist,
# not its head — and the capsule bottom rests on the ground.
static func ragdoll_body_y(ground: float, capsule_height: float) -> float:
	return ground + capsule_height * 0.5


# Local Y to place the mesh inside that body so its feet meet the capsule bottom.
# The mesh's feet sit `foot_offset` above its own origin, so from the body centre
# (capsule_height/2 above the feet) the mesh drops by that much less the foot offset.
static func ragdoll_mesh_offset_y(foot_offset: float, capsule_height: float) -> float:
	return foot_offset - capsule_height * 0.5


# Prioritised steering arbitration. The two URGENT local forces — fleeing the car
# and keeping personal space from neighbours — are BLENDED at the top tier, then
# static obstacle (road + tree) avoidance gets whatever budget is left under
# max_speed, and the anchor pull comes last.
#
# Blending flee with separation (rather than gating separation behind a saturated
# flee) is what stops a fleeing crowd from freezing: if flee alone claims the whole
# budget, separation gets nothing, so members pile onto the same escape point with
# no spacing force, collapse to near-coincident positions, and can never push apart
# again (coincident/symmetric separation cancels) — the crowd goes "completely
# stuck". Blended, the crowd fans out sideways as it flees. Flee's larger weight
# keeps escaping the car the dominant direction, and the accel-limited integration
# (move_toward) filters any tick-to-tick wobble, so this doesn't jitter a tight clump.
static func combine(flee: Vector2, avoid: Vector2, separation: Vector2, anchor: Vector2, max_speed: float) -> Vector2:
	var v := clamp_speed(flee + separation, max_speed)
	v = _add_priority(v, avoid, max_speed)
	v = _add_priority(v, anchor, max_speed)
	return v


# Add `extra` to `v`, but only up to the speed budget `v` leaves under max_speed — a
# lower-priority force can never override a higher-priority one already at full tilt.
static func _add_priority(v: Vector2, extra: Vector2, max_speed: float) -> Vector2:
	var remaining := max_speed - v.length()
	if remaining <= 0.0:
		return v
	if extra.length() > remaining:
		extra = extra.normalized() * remaining
	return v + extra


# --- simulation ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"spectator_group", Time.get_ticks_usec() - __t)


func _timed_physics_process(delta: float) -> void:
	if _car == null or _pos.is_empty():
		_age_ragdolls()
		return
	var car_xf: Transform3D = _car.global_transform
	var car_xz := Vector2(car_xf.origin.x, car_xf.origin.z)
	# LOD: only steer when the car is near this group. Ragdolls still age out.
	if _center.distance_to(car_xz) > float(_p["active_radius_m"]):
		_age_ragdolls(car_xf)
		return

	# Knock-over detection runs EVERY tick (a discrete event that must stay
	# responsive even at high car speed) — a cheap per-member distance check,
	# independent of the decimated steering below. The car moves every tick, so
	# testing it against the (possibly stale) positions still catches contact.
	var knock_r: float = _p["knock_radius_m"]
	var to_knock: Array[int] = []
	for i in _pos.size():
		if _upright[i] == 1 and car_xz.distance_to(_pos[i]) < knock_r:
			to_knock.append(i)
	for i in to_knock:
		_knock_over(i, car_xf)

	# Sim decimation: steer only every Nth physics tick (staggered per group so the
	# cost spreads across ticks), integrating the accumulated delta so crowd motion
	# is unchanged over time. Ragdolls still age every tick. Pure perf, no behaviour
	# change beyond a coarser (still smooth-at-speed) crowd update rate.
	var interval: int = maxi(1, int(_p.get("sim_interval", 1)))
	_sim_accum += delta
	if interval > 1 and (Engine.get_physics_frames() + _sim_stagger) % interval != 0:
		_age_ragdolls(car_xf)
		return
	var step := _sim_accum
	_sim_accum = 0.0

	var max_speed: float = _p["max_speed_mps"]
	var accel: float = _p["accel_mps2"]
	# Bin members once per tick so separation is a bounded 3x3 neighbour scan (O(N))
	# instead of the every-pair O(N^2) it was. Cell = separation radius.
	var sep_radius: float = _p["separation_m"]
	var sep_grid := build_separation_grid(_pos, _upright, sep_radius)

	for i in _pos.size():
		if _upright[i] == 0:
			continue
		# Prioritised, not a flat weighted sum: fleeing the car is blended with neighbour
		# separation at the top tier (so a fleeing crowd fans out instead of collapsing),
		# then static obstacle (road + tree) avoidance, then the anchor pull.
		var flee: Vector2 = flee_force(_pos[i], car_xz, _p["flee_radius_m"]) * _p["w_flee"]
		var avoid: Vector2 = road_force(_pos[i], _road_cells, _p["road_probe_m"]) * _p["w_road"]
		avoid += obstacle_force(_pos[i], _tree_grid, _p["tree_cell_m"], _p["tree_avoid_m"]) * _p["w_obstacle"]
		var sep: Vector2 = separation_force(i, _pos, _upright, sep_radius, sep_grid, sep_radius) * _p["w_separation"]
		var anchor: Vector2 = anchor_force(_pos[i], _home[i], _p["anchor_dead_zone_m"]) * _p["w_anchor"]
		var desired := combine(flee, avoid, sep, anchor, max_speed)
		# Steer current velocity toward the target, then advance (step = accumulated
		# delta since the last steered tick — see the decimation gate above).
		_vel[i] = clamp_speed(_vel[i].move_toward(desired, accel * step), max_speed)
		_pos[i] += _vel[i] * step
		if _vel[i].length_squared() > 0.0004:
			_yaw[i] = atan2(_vel[i].x, _vel[i].y)
		_write_instance(i)

	_age_ragdolls(car_xf)


# Position one MultiMesh instance from agent i's state (feet on the ground).
func _write_instance(i: int) -> void:
	if _mm == null:
		return
	var x := _pos[i].x
	var z := _pos[i].y
	var y := _ground(x, z) + _foot_offset
	var yaw_basis := Basis(Vector3.UP, _yaw[i])
	# Local to the MMI node (anchored at the centroid) so visibility_range measures
	# camera→crowd, not camera→world-origin.
	_mm.set_instance_transform(i, Transform3D(yaw_basis, Vector3(x, y, z) - _mm_origin))


func _refresh_all_instances() -> void:
	for i in _pos.size():
		if _upright[i] == 1:
			_write_instance(i)


func _ground(x: float, z: float) -> float:
	if _terrain_has_height:
		return _terrain.height_at(x, z)
	return 0.0


# Flip member i from an upright agent to a launched ragdoll body.
# Shader warm-up (auto-invoked by world.gd's warm_up() contract walk while the
# loading cover is up). A knocked spectator draws the crowd mesh as a SINGLE
# MeshInstance3D (_knock_over below), which under gl_compatibility is a different
# shader program than the upright crowd's MultiMesh — so without priming it here the
# first car-into-crowd hit compiles it mid-drive. Draw one throwaway single-instance
# crowd mesh (the ragdoll's exact draw path); clear_warm_up() drops it after the
# rendered frame. See features/rendering.md → "Shader pre-warm".
func warm_up(pos: Vector3) -> void:
	var mesh := Crowd.mesh()
	if mesh == null:
		return
	if _warm_mi == null:
		_warm_mi = MeshInstance3D.new()
		add_child(_warm_mi)
	_warm_mi.mesh = mesh
	_warm_mi.global_position = pos


func clear_warm_up() -> void:
	if _warm_mi != null:
		_warm_mi.queue_free()
		_warm_mi = null


func _knock_over(i: int, car_xf: Transform3D) -> void:
	if _upright[i] == 0:
		return
	_upright[i] = 0
	# Hide the upright instance by collapsing it to zero scale.
	if _mm != null:
		_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))

	var x := _pos[i].x
	var z := _pos[i].y
	var ground := _ground(x, z)

	var body := RigidBody3D.new()
	body.mass = _p["ragdoll_mass_kg"]
	body.collision_layer = int(_p["ragdoll_layer"])
	body.collision_mask = int(_p["ragdoll_mask"])
	add_child(body)
	# Body origin = capsule centre = figure mid-height, so the auto centre-of-mass
	# (single centred capsule) sits at the body's middle and it tumbles about its
	# waist, not its head.
	body.global_position = Vector3(x, ragdoll_body_y(ground, _capsule_height), z)
	# Ragdolls land on the terrain/trees (all on layer 1) but must never collide
	# with the car — the car shares layer 1, so an explicit exception is the only
	# way to let a crowd be driven through without bogging the vehicle down.
	if _car is CollisionObject3D:
		body.add_collision_exception_with(_car)

	var shape := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = _capsule_radius
	cap.height = maxf(_capsule_height, _capsule_radius * 2.0)
	shape.shape = cap
	body.add_child(shape)

	var mi := MeshInstance3D.new()
	mi.mesh = _mm.mesh if _mm != null else null
	# Offset the mesh within the body so its feet meet the capsule bottom on the
	# ground (accounting for the mesh's own foot offset above its origin).
	mi.position = Vector3(0, ragdoll_mesh_offset_y(_foot_offset, _capsule_height), 0)
	body.add_child(mi)

	# Launch along the car's travel direction, with the WHOLE impulse scaled by the car's
	# speed: launch speed is `speed x factor` (clamped), the upward kick is a fraction of
	# that launch (a fixed angle, not a constant m/s), and the spin tapers to zero as the
	# car slows. So a slow nudge topples a spectator gently instead of flinging them up.
	var car_vel := Vector3.ZERO
	if _car != null and "linear_velocity" in _car:
		car_vel = _car.linear_velocity
	var speed := car_vel.length()
	var dir := car_vel.normalized() if speed > 0.1 else -car_xf.basis.z
	var factor := float(_p["knock_speed_factor"])
	var speed_max := float(_p["knock_speed_max"])
	body.linear_velocity = knock_launch_velocity(dir, speed, factor,
		float(_p["knock_speed_min"]), speed_max, float(_p["knock_lift_ratio"]))
	body.angular_velocity = Vector3(
		_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)
	).normalized() * float(_p["knock_spin"]) * knock_spin_scale(speed, factor, speed_max)
	_ragdolls.append(body)

	# Mowing the crowd isn't free: knocking a member sheds a little of the car's speed
	# (soft drag), and the unified deceleration-damage rule (car._integrate_forces) turns
	# that into the HP chip. Grouping is natural — a car slowed toward a stop sheds ~0
	# more per member — so ploughing a dense line doesn't wildly over-count. See
	# features/damage.md.
	if _car != null and _drag_strength > 0.0 and _car.has_method("apply_soft_drag"):
		_car.apply_soft_drag(_drag_strength)


# Launch velocity for a knocked body: along `dir` at magnitude `speed x factor`
# (clamped to [speed_min, speed_max]), tilted upward by `lift_ratio` of that launch.
# Because the lift is a fraction of the (speed-driven) launch — a fixed angle, not a
# constant m/s — the WHOLE impulse scales with car speed: a slow nudge stays low and
# small, a fast hit lofts and flings. Shared launch recipe (also used by SignField).
static func knock_launch_velocity(dir: Vector3, speed: float, factor: float,
		speed_min: float, speed_max: float, lift_ratio: float) -> Vector3:
	var launch := clampf(speed * factor, speed_min, speed_max)
	var launch_dir := (dir + Vector3.UP * lift_ratio).normalized()
	return launch_dir * launch


# Tumble-spin scale in [0, 1], proportional to the raw (unfloored) car speed so a crawl
# barely spins the body while a fast hit spins it fully.
static func knock_spin_scale(speed: float, factor: float, speed_max: float) -> float:
	return clampf(speed * factor / maxf(speed_max, 0.001), 0.0, 1.0)


# Free ragdolls the car has left well behind, so bodies don't accumulate.
func _age_ragdolls(car_xf: Transform3D = Transform3D()) -> void:
	if _ragdolls.is_empty():
		return
	var behind: float = _p.get("despawn_behind_m", 60.0)
	var fwd := -car_xf.basis.z
	var car_pos := car_xf.origin
	var kept: Array[RigidBody3D] = []
	for b in _ragdolls:
		if not is_instance_valid(b):
			continue
		var to_body := b.global_position - car_pos
		# Behind the car (negative along forward) and farther than the threshold.
		if to_body.dot(fwd) < 0.0 and to_body.length() > behind:
			b.queue_free()
		else:
			kept.append(b)
	_ragdolls = kept


# --- readouts (tests / debug) -------------------------------------------------

func upright_count() -> int:
	var c := 0
	for v in _upright:
		c += v
	return c


func ragdoll_count() -> int:
	return _ragdolls.size()


func member_position(i: int) -> Vector2:
	return _pos[i]

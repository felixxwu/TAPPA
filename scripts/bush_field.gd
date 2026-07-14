class_name BushField
extends Node3D
# Interaction (NOT rendering) for the ground-cover bushes. The bushes are drawn by a
# TreeMeshField built with_collision=false (world.gd) — pure visual scatter with no
# physics body, so the car drives THROUGH them. This node makes that drive-through
# cost something: brushing a bush deals a small flat HP loss and applies a side-based
# yaw drag torque, as if the bush snagged and dragged a corner of the car. See
# features/damage.md.
#
# Bushes are not solid colliders (a StaticBody would arrest the car — the opposite of
# the brush-through feel), so contact is a per-tick PROXIMITY query, the same pattern
# the spectator crowd uses. Bush XZ positions are binned into a grid (cell = hit
# radius) so each tick only the ~handful of bushes in the car's 3x3 neighbourhood are
# tested — cheap even though the field spans the whole stage.
#
# One-shot per bush: a bush fires ONCE on the tick the car enters its radius and
# re-arms only after the car leaves (tracked in `_inside`). The DamageModel soft-hit
# cooldown is the backstop so ploughing through a dense clump can't machine-gun HP.

var _car: Node = null                 # VehicleBody3D with a `damage` DamageModel
# Car capabilities resolved once in setup() — probed here instead of every
# physics tick (get()/has_method()/`in` are hashed lookups on the hot path).
var _dmg: DamageModel = null
var _car_has_velocity := false
var _car_can_soft_drag := false
var _car_can_torque_impulse := false
var _points: PackedVector2Array       # bush world XZ, index-stable
var _grid: Dictionary = {}            # Vector2i -> PackedInt32Array of indices into _points
var _cell := 1.0                      # grid cell (== hit radius, so a 3x3 covers the query)
var _hit_radius := 1.0
var _drag_strength := 0.0             # fraction of horizontal speed a graze sheds (soft drag)
var _drag_torque := 0.0               # N·m·s per m/s of speed (scaled by car speed)
var _min_speed_mps := 0.0
# Bush indices the car is currently inside; compared tick-to-tick to detect fresh
# ENTERs (and drop bushes the car has left). Double-buffered with _inside_next so
# each tick fills a reused dict instead of allocating a fresh one.
var _inside: Dictionary = {}
var _inside_next: Dictionary = {}


# Wire the field. `positions` are the same scattered bush XZ points passed to the
# renderer; `hit_radius` is already the leeway-reduced radius (a fraction of the
# bush's visual width — computed by the caller from TreeMeshField.xz_radius).
func setup(positions: PackedVector2Array, car: Node, hit_radius: float,
		drag_strength: float, drag_torque_magnitude: float, min_speed_mps: float) -> void:
	_car = car
	_dmg = car.get("damage") if car != null else null
	_car_has_velocity = car != null and "linear_velocity" in car
	_car_can_soft_drag = car != null and car.has_method("apply_soft_drag")
	_car_can_torque_impulse = car != null and car.has_method("apply_torque_impulse")
	_points = positions
	_hit_radius = maxf(hit_radius, 0.01)
	_drag_strength = drag_strength
	_drag_torque = drag_torque_magnitude
	_min_speed_mps = min_speed_mps
	_cell = _hit_radius
	# Bin bush indices into the hit-radius grid so each tick only tests the car's 3x3
	# neighbourhood (cell == hit radius, so any overlapping bush is in those cells).
	_grid = SpatialGrid.of_indices(_points, _cell)


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"bush_field", Time.get_ticks_usec() - __t)


func _timed_physics_process(_delta: float) -> void:
	if _car == null or _points.is_empty() or _dmg == null:
		return
	var car_xf: Transform3D = _car.global_transform
	var car_xz := Vector2(car_xf.origin.x, car_xf.origin.z)
	var forward := Vector2(-car_xf.basis.z.x, -car_xf.basis.z.z)
	var speed := 0.0
	if _car_has_velocity:
		speed = (_car.linear_velocity as Vector3).length()

	# Bushes the car overlaps THIS tick (from the 3x3 neighbourhood — since the grid
	# cell is the hit radius, any overlapping bush is in these cells). Filled into the
	# reused _inside_next buffer, then swapped into _inside at the end.
	var overlapping := _inside_next
	overlapping.clear()
	var base := SpatialGrid.cell_key(car_xz, _cell)
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			var key := Vector2i(base.x + ox, base.y + oz)
			if not _grid.has(key):
				continue
			var arr: PackedInt32Array = _grid[key]
			for idx in arr:
				var p := _points[idx]
				if car_xz.distance_to(p) >= _hit_radius:
					continue
				overlapping[idx] = true
				# Fresh enter (not already inside this bush) → brush effects. Shed a little
				# speed (soft drag); the unified deceleration-damage rule (car._integrate_forces)
				# turns that into the minor HP chip. Grouping is natural — _inside tracks which
				# bushes the car is already in, so sitting in one doesn't re-apply per tick.
				if not _inside.has(idx) and speed >= _min_speed_mps:
					if _car_can_soft_drag:
						_car.apply_soft_drag(_drag_strength)
					if _car_can_torque_impulse:
						var tq := drag_torque(forward, p - car_xz, _drag_torque) * speed
						_car.apply_torque_impulse(Vector3(0.0, tq, 0.0))
	# Swap buffers: this tick's overlaps become _inside; the old _inside dict is
	# recycled as next tick's fill buffer.
	_inside_next = _inside
	_inside = overlapping


# Signed yaw torque (about +Y) for a bush at `to_bush_xz` relative to a car facing
# `forward_xz` — magnitude scaled by sin(angle) so it's zero head-on and peaks when the
# bush is straight off to one side, and its SIGN swings the car's nose TOWARD the bush
# (the snagged corner drags back and the car pivots into it). Pure/static → unit-tested.
static func drag_torque(forward_xz: Vector2, to_bush_xz: Vector2, magnitude: float) -> float:
	if forward_xz.length() < 1e-6 or to_bush_xz.length() < 1e-6:
		return 0.0
	# sin of the angle from forward to the bush; + when the bush is off to the car's
	# right (+X for a car facing -Z). A +Y torque turns the nose left, so negate to
	# turn the nose toward the bush.
	var s := forward_xz.normalized().cross(to_bush_xz.normalized())
	return -magnitude * s

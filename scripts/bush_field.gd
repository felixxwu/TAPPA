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
var _points: PackedVector2Array       # bush world XZ, index-stable
var _grid: Dictionary = {}            # Vector2i -> PackedInt32Array of indices into _points
var _cell := 1.0                      # grid cell (== hit radius, so a 3x3 covers the query)
var _hit_radius := 1.0
var _hp_loss := 0.0
var _drag_torque := 0.0               # N·m·s per m/s of speed (scaled by car speed)
var _min_speed_mps := 0.0
var _cooldown := 0.0
# Bush indices the car is currently inside; compared tick-to-tick to detect fresh
# ENTERs (and drop bushes the car has left).
var _inside: Dictionary = {}


# Wire the field. `positions` are the same scattered bush XZ points passed to the
# renderer; `hit_radius` is already the leeway-reduced radius (a fraction of the
# bush's visual width — computed by the caller from TreeMeshField.xz_radius).
func setup(positions: PackedVector2Array, car: Node, hit_radius: float,
		hp_loss: float, drag_torque_magnitude: float, min_speed_mps: float, cooldown_s: float) -> void:
	_car = car
	_points = positions
	_hit_radius = maxf(hit_radius, 0.01)
	_hp_loss = hp_loss
	_drag_torque = drag_torque_magnitude
	_min_speed_mps = min_speed_mps
	_cooldown = cooldown_s
	_cell = _hit_radius
	_grid = {}
	for i in _points.size():
		var p := _points[i]
		var key := Vector2i(floori(p.x / _cell), floori(p.y / _cell))
		if not _grid.has(key):
			_grid[key] = PackedInt32Array()
		_grid[key].append(i)


func _physics_process(_delta: float) -> void:
	if _car == null or _points.is_empty():
		return
	var dmg: DamageModel = _car.get("damage")
	if dmg == null:
		return
	var car_xf: Transform3D = _car.global_transform
	var car_xz := Vector2(car_xf.origin.x, car_xf.origin.z)
	var forward := Vector2(-car_xf.basis.z.x, -car_xf.basis.z.z)
	var speed := 0.0
	if "linear_velocity" in _car:
		speed = (_car.linear_velocity as Vector3).length()

	# Bushes the car overlaps THIS tick (from the 3x3 neighbourhood — since the grid
	# cell is the hit radius, any overlapping bush is in these cells).
	var overlapping := {}
	var bx := floori(car_xz.x / _cell)
	var bz := floori(car_xz.y / _cell)
	for ox in range(-1, 2):
		for oz in range(-1, 2):
			var arr: PackedInt32Array = _grid.get(Vector2i(bx + ox, bz + oz), PackedInt32Array())
			for idx in arr:
				var p := _points[idx]
				if car_xz.distance_to(p) >= _hit_radius:
					continue
				overlapping[idx] = true
				# Fresh enter (not already inside this bush) → brush effects.
				if not _inside.has(idx) and speed >= _min_speed_mps:
					var loss := dmg.register_soft_hit(_hp_loss, Vector3(p.x, car_xf.origin.y, p.y), _cooldown)
					# Only tug the car when the graze actually landed (not swallowed by
					# the soft-hit cooldown) — one bush shouldn't tug for a clumpmate's hit.
					if loss > 0.0 and _car.has_method("apply_torque_impulse"):
						var tq := drag_torque(forward, p - car_xz, _drag_torque) * speed
						_car.apply_torque_impulse(Vector3(0.0, tq, 0.0))
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

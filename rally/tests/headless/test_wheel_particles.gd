extends GutTest
# WheelParticles: cheap gravel spray flung from the driven wheels under wheelspin
# (features/wheel-dust.md). Driven against a straight Curve2D with a stub car +
# stub drivetrain + stub wheels, so the gating / emission / ring-buffer logic is
# exercised without a real vehicle or rendering.

const WheelParticles = preload("res://scripts/wheel_particles.gd")


# Stub wheel: the bits WheelParticles reads off a wheel.
class StubWheel:
	extends Node3D
	var _contact := true
	var driven := true
	var omega := 0.0          # rad/s (surface speed = omega * wheel_radius)
	var fwd := Vector3(0, 0, -1)  # rolling direction (road runs +Z, car faces -Z)
	func is_in_contact() -> bool:
		return _contact


# Stub drivetrain: classifies/driven-gates the wheels and reports spin + ground
# velocity, mirroring the real Drivetrain's public surface.
class StubDrivetrain:
	extends RefCounted
	var front_wheels: Array = []
	var rear_wheels: Array = []
	var ground_vel := Vector3.ZERO  # ground velocity at the contact (uniform stub)
	func is_wheel_driven(w) -> bool:
		return w.driven
	func wheel_forward(w) -> Vector3:
		return w.fwd
	func wheel_omega(w) -> float:
		return w.omega
	func velocity_at(_point) -> Vector3:
		return ground_vel


# Stub car: a drivetrain + a world position.
class StubCar:
	extends Node3D
	var drivetrain


var _car: StubCar
var _dt: StubDrivetrain
var _curve: Curve2D
var _wheels: Array = []


func before_each() -> void:
	Config.reset()
	Config.data.wheel_particles_enabled = true
	# A straight road 200 m along +Z (curve points are Vector2(world_x, world_z)).
	_curve = Curve2D.new()
	_curve.add_point(Vector2(0, 0))
	_curve.add_point(Vector2(0, 200))
	_car = StubCar.new()
	_dt = StubDrivetrain.new()
	_car.drivetrain = _dt
	add_child_autofree(_car)
	_car.position = Vector3(0, 0, 10)  # on the road, ~offset 10
	# Four wheels: two front (undriven by default mode in the stub) + two rear.
	_wheels = []
	for i in 4:
		var w := StubWheel.new()
		_car.add_child(w)  # in-tree so global_position resolves
		_wheels.append(w)
		(_dt.rear_wheels if i >= 2 else _dt.front_wheels).append(w)


func after_each() -> void:
	Config.reset()


func _make(half_width := 3.0) -> WheelParticles:
	var wp := WheelParticles.new()
	add_child_autofree(wp)
	wp.setup(_curve, _car, half_width)
	return wp


# Surface speed (m/s) -> omega for the current wheel radius.
func _omega_for(speed: float) -> float:
	return speed / Config.data.wheel_radius


# Tick with delta 0 so the pool emits without ageing (lifetime/gravity untouched).
func _tick(wp: WheelParticles) -> void:
	wp._physics_process(0.0)


func test_pool_starts_empty_and_capped() -> void:
	Config.data.wheel_particle_max = 64
	var wp := _make()
	assert_eq(wp.max_particles(), 64, "pool sized to wheel_particle_max")
	assert_eq(wp.live_count(), 0, "no particles before any wheel spins")


func test_driven_spinning_on_gravel_emits() -> void:
	var wp := _make()
	# Rear (driven) wheel spinning at 10 m/s tread vs a stationary ground -> well
	# over the slip floor, sitting on the centerline.
	_wheels[2].omega = _omega_for(10.0)
	_tick(wp)
	assert_gt(wp.live_count(), 0, "a driven wheel spinning on the gravel throws dirt")


func test_undriven_wheel_does_not_emit() -> void:
	var wp := _make()
	# Front wheel spinning hard, but undriven (free-rolling) -> no dirt.
	_wheels[0].driven = false
	_wheels[0].omega = _omega_for(10.0)
	_tick(wp)
	assert_eq(wp.live_count(), 0, "an undriven wheel flings no dirt however fast it turns")


func test_no_emit_when_not_spinning_faster_than_ground() -> void:
	var wp := _make()
	# Wheel tread speed matches ground speed (pure rolling) -> slip ~0, below floor.
	_dt.ground_vel = Vector3(0, 0, -5)        # v_long = fwd . vel = 5
	_wheels[2].omega = _omega_for(5.0)        # surface speed 5 -> slip 0
	_tick(wp)
	assert_eq(wp.live_count(), 0, "no dirt when the wheel only rolls (no wheelspin)")


func test_no_emit_off_the_gravel() -> void:
	var wp := _make()
	# Driven wheel spinning, but 10 m off to the side (on the grass, past the gate).
	_wheels[2].position = Vector3(10, 0, 0)
	_wheels[2].omega = _omega_for(10.0)
	_tick(wp)
	assert_eq(wp.live_count(), 0, "a wheel spinning off the gravel (grass) throws nothing")


func test_sliding_and_spinning_still_emits_and_sprays_sideways() -> void:
	var wp := _make()
	# The car is sliding sideways at speed (high lateral ground velocity) AND the
	# driven wheel is spinning faster than it rolls forward. It must still count as
	# wheelspin (gauged on the rolling direction, not total speed) and the spray
	# must tilt toward the slide, not just straight back.
	_dt.ground_vel = Vector3(8, 0, 0)         # sideways slide; v_long = 0
	_wheels[2].omega = _omega_for(10.0)
	_tick(wp)
	assert_gt(wp.live_count(), 0, "a spinning wheel during a slide still throws dirt")
	var v: Vector3 = wp._vel[wp._next]
	assert_gt(v.z, 0.0, "dirt is flung backwards (+Z, opposite the -Z heading)")
	assert_gt(v.x, 0.0, "dirt also sprays toward the slide direction (+X)")
	assert_gt(v.y, 0.0, "dirt is angled upwards")


func test_ring_buffer_caps_live_particles() -> void:
	Config.data.wheel_particle_max = 5
	Config.data.wheel_particle_spawn_count = 3
	var wp := _make()
	_wheels[2].omega = _omega_for(10.0)
	for s in 50:
		_tick(wp)  # delta 0 -> nothing ages out, so only the cap can bound the count
	assert_eq(wp.live_count(), 5, "the live pool is capped to wheel_particle_max")

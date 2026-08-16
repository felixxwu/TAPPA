extends GutTest
# WheelParticles: cheap surface debris flung from the driven wheels once they break
# fore/aft traction
# (features/wheel-dust.md). Driven against a stub car + stub drivetrain + stub
# wheels + a stub terrain surface, so the gating / emission / ring-buffer logic and
# the per-particle look (colour / dimensions / roll) are exercised without a real
# vehicle or rendering.


# Stub wheel: the bits WheelParticles reads off a wheel.
class StubWheel:
	extends Node3D
	var _contact := true
	var driven := true
	var omega := 0.0          # rad/s (surface speed = omega * wheel_radius)
	var fwd := Vector3(0, 0, -1)  # rolling direction (road runs +Z, car faces -Z)
	# How far past its fore/aft grip limit this tire is (1.0 = exactly at the limit).
	# This is the emit gate — a tire only throws debris once it has broken traction.
	var long_grip := 0.0
	func is_in_contact() -> bool:
		return _contact


# Stub terrain: reports (road_weight, tarmac_weight) like TerrainManager.surface_at.
# Within |x| <= road_half it's road; beyond that it's grass (road_weight 0).
class StubTerrain:
	extends RefCounted
	var road_half := 3.0
	var tarmac := 0.0
	func surface_at(x: float, _z: float) -> Vector2:
		return Vector2(1.0 if absf(x) <= road_half else 0.0, tarmac)


# Stub drivetrain: classifies/driven-gates the wheels and reports spin, ground
# velocity, and the terrain — mirroring the real Drivetrain's public surface.
class StubDrivetrain:
	extends RefCounted
	var front_wheels: Array = []
	var rear_wheels: Array = []
	var all_wheels: Array = []  # front + rear, cached like the real drivetrain
	var ground_vel := Vector3.ZERO  # ground velocity at the contact (uniform stub)
	var terrain
	func is_wheel_driven(w) -> bool:
		return w.driven
	func wheel_forward(w) -> Vector3:
		return w.fwd
	func wheel_omega(w) -> float:
		return w.omega
	func wheel_long_grip_usage(w) -> float:
		return w.long_grip
	func velocity_at(_point) -> Vector3:
		return ground_vel


# Stub car: a drivetrain + a world position.
class StubCar:
	extends Node3D
	var drivetrain


var _car: StubCar
var _dt: StubDrivetrain
var _terrain: StubTerrain
var _wheels: Array = []


func before_each() -> void:
	Config.reset()
	Config.data.wheel_particles_enabled = true
	_car = StubCar.new()
	_dt = StubDrivetrain.new()
	_terrain = StubTerrain.new()
	_dt.terrain = _terrain
	_car.drivetrain = _dt
	add_child_autofree(_car)
	_car.position = Vector3(0, 0, 10)
	# Four wheels: two front + two rear (all flagged driven in the stub by default;
	# individual tests flip `driven` to model an undriven axle).
	_wheels = []
	for i in 4:
		var w := StubWheel.new()
		_car.add_child(w)  # in-tree so global_position resolves
		_wheels.append(w)
		(_dt.rear_wheels if i >= 2 else _dt.front_wheels).append(w)
		_dt.all_wheels.append(w)


func after_each() -> void:
	Config.reset()


func _make() -> WheelParticles:
	var wp := WheelParticles.new()
	add_child_autofree(wp)
	wp.setup(_car)
	return wp


# Surface speed (m/s) -> omega for the current wheel radius.
func _omega_for(speed: float) -> float:
	return speed / Config.data.wheel_radius


# Put a wheel past its fore/aft grip limit at the given tread speed — the state that
# actually throws debris. `long_grip` defaults comfortably clear of the 1.0 limit;
# tests probing the gate itself pass their own value.
func _break_traction(i: int, tread_speed: float, long_grip := 1.5) -> void:
	_wheels[i].omega = _omega_for(tread_speed)
	_wheels[i].long_grip = long_grip


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
	# Rear (driven) wheel spun up past its fore/aft grip limit at 10 m/s of tread
	# speed, sitting on the gravel road.
	_break_traction(2, 10.0)
	_tick(wp)
	assert_gt(wp.live_count(), 0, "a driven wheel spinning on the gravel throws dirt")


func test_undriven_wheel_does_not_emit() -> void:
	var wp := _make()
	# Front wheel past its grip limit, but undriven (free-rolling) -> no dirt.
	_wheels[0].driven = false
	_break_traction(0, 10.0)
	_tick(wp)
	assert_eq(wp.live_count(), 0, "an undriven wheel flings no dirt however fast it turns")


func test_no_emit_while_the_tire_still_grips() -> void:
	var wp := _make()
	# The tread is turning faster than the ground, but the tire is still WITHIN its
	# fore/aft limit — it is driving through the surface, not tearing it up.
	_dt.ground_vel = Vector3(0, 0, -5)        # v_long = fwd . vel = 5
	_break_traction(2, 8.0, 0.6)              # slipping, but only 60% of the limit
	_tick(wp)
	assert_eq(wp.live_count(), 0, "no dirt while the tire is still gripping")


func test_emit_starts_at_the_grip_limit() -> void:
	# The gate is the limit itself, not an arbitrary slip speed: just under throws
	# nothing, just over throws dirt, at the same tread speed either way.
	Config.data.wheel_particle_min_long_grip = 1.0
	var quiet := _make()
	_break_traction(2, 10.0, 0.99)
	_tick(quiet)
	assert_eq(quiet.live_count(), 0, "a tire just inside its limit throws nothing")
	var spraying := _make()
	_break_traction(2, 10.0, 1.01)
	_tick(spraying)
	assert_gt(spraying.live_count(), 0, "a tire just past its limit throws dirt")


func test_locked_wheel_under_braking_also_emits() -> void:
	# Grip usage is unsigned, so a driven wheel LOCKED under braking (tread slower than
	# the ground) ploughs up debris too — not just one spinning up under power.
	var wp := _make()
	_dt.ground_vel = Vector3(0, 0, -20)  # rolling along at 20 m/s
	_break_traction(2, 0.0, 1.6)         # tread stopped: locked, well past the limit
	_tick(wp)
	assert_gt(wp.live_count(), 0, "a locked wheel ploughs up debris")


func test_grass_emits_blades() -> void:
	# Driven wheel spinning, but 10 m off to the side -> off the road (grass).
	# Grass throws its own particles (slim green blades) rather than nothing.
	var wp := _make()
	_wheels[2].position = Vector3(10, 0, 0)
	_break_traction(2, 10.0)
	_tick(wp)
	assert_gt(wp.live_count(), 0, "a wheel spinning on grass throws grass up")


func test_no_emit_on_tarmac() -> void:
	var wp := _make()
	# Driven wheel spinning on the road, but the surface is tarmac -> no dirt.
	_terrain.tarmac = 1.0
	_break_traction(2, 10.0)
	_tick(wp)
	assert_eq(wp.live_count(), 0, "a wheel spinning on tarmac throws no dirt")


func test_sliding_and_spinning_still_emits_and_sprays_sideways() -> void:
	var wp := _make()
	# The car is sliding sideways at speed (high lateral ground velocity) AND the driven
	# wheel is past its fore/aft grip limit. The emit gate is the LONGITUDINAL usage, so
	# a big lateral slide neither triggers nor suppresses it — and the spray must tilt
	# toward the slide, not just straight back.
	_dt.ground_vel = Vector3(8, 0, 0)         # sideways slide; v_long = 0
	_break_traction(2, 10.0)
	_tick(wp)
	assert_gt(wp.live_count(), 0, "a spinning wheel during a slide still throws dirt")
	var v: Vector3 = wp._vel[wp._next]
	assert_gt(v.z, 0.0, "dirt is flung backwards (+Z, opposite the -Z heading)")
	assert_gt(v.x, 0.0, "dirt also sprays toward the slide direction (+X)")
	assert_gt(v.y, 0.0, "dirt is angled upwards")


func test_warm_up_draws_then_clears() -> void:
	# warm_up() parks one visible instance so the shader compiles behind the loading
	# screen; clear_warm_up() must return the pool to empty (no lingering clod).
	var wp := _make()
	wp.warm_up(Vector3(0, 0, 10))
	assert_eq(wp.live_count(), 1, "warm-up draws a single clod so the shader compiles")
	wp.clear_warm_up()
	assert_eq(wp.live_count(), 0, "clear_warm_up leaves the pool empty")


func test_ring_buffer_caps_live_particles() -> void:
	Config.data.wheel_particle_max = 5
	Config.data.wheel_particle_spawn_count = 3
	var wp := _make()
	_break_traction(2, 10.0)
	for s in 50:
		_tick(wp)  # delta 0 -> nothing ages out, so only the cap can bound the count
	assert_eq(wp.live_count(), 5, "the live pool is capped to wheel_particle_max")


# --- Per-particle appearance (colour / dimensions / roll) --------------------

# The pool is shared by every surface, so one cap and one draw call cover both the
# gravel clods and the grass blades.
func test_one_shared_pool_for_every_surface() -> void:
	Config.data.wheel_particle_max = 32
	var wp := _make()
	assert_true(wp.multimesh.use_colors, "instances carry their own colour")
	assert_eq(wp.multimesh.instance_count, 32, "one MultiMesh sized to the shared cap")
	assert_eq(wp._buffer.size(), 32 * WheelParticles.STRIDE,
		"the buffer holds transform + colour floats for every slot")
	# Spin one wheel on the road and another off it in the same tick: both surfaces
	# feed the SAME ring buffer rather than a pool each.
	_break_traction(2, 10.0)
	_wheels[3].position = Vector3(10, 0, 0)
	_break_traction(3, 10.0)
	_tick(wp)
	assert_gt(wp.live_count(), 1, "gravel and grass particles share one pool")


# _write_slot's basis is the contract billboard_particle.gdshader reads back:
# column lengths are the half-extents, column 0's direction is the roll. Asserted
# against the values handed to _write_slot, not against any authored config.
func test_slot_basis_encodes_size_and_roll() -> void:
	var wp := _make()
	var look := WheelParticles.Look.new(0.5, 2.0, Color(0.1, 0.2, 0.3, 1.0))
	var roll := PI / 3.0
	wp._write_slot(0, Vector3(1, 2, 3), look, roll, look.color)
	var b: PackedFloat32Array = wp._buffer
	# Row-major 3x4: column 0 is floats 0/4/8, column 1 is floats 1/5/9.
	var col0 := Vector3(b[0], b[4], b[8])
	var col1 := Vector3(b[1], b[5], b[9])
	assert_almost_eq(col0.length(), 0.5, 0.001, "column 0 length is the half-width")
	assert_almost_eq(col1.length(), 2.0, 0.001, "column 1 length is the half-height")
	assert_almost_eq(col0.x / 0.5, cos(roll), 0.001, "column 0 direction carries cos(roll)")
	assert_almost_eq(col0.y / 0.5, sin(roll), 0.001, "column 0 direction carries sin(roll)")
	assert_almost_eq(b[3], 1.0, 0.001, "origin x")
	assert_almost_eq(b[7], 2.0, 0.001, "origin y")
	assert_almost_eq(b[11], 3.0, 0.001, "origin z")


# A slim look and a square look of the same area must still be distinguishable in
# the basis — i.e. the two axes are written independently (non-uniform scale).
func test_slot_half_extents_are_independent_axes() -> void:
	var wp := _make()
	wp._write_slot(0, Vector3.ZERO, WheelParticles.Look.new(0.02, 0.5, Color.WHITE), 0.0, Color.WHITE)
	var b: PackedFloat32Array = wp._buffer
	assert_almost_eq(Vector3(b[0], b[4], b[8]).length(), 0.02, 0.0001, "slim axis stays slim")
	assert_almost_eq(Vector3(b[1], b[5], b[9]).length(), 0.5, 0.0001, "long axis stays long")


# Per-instance colour lands in the trailing RGBA floats.
func test_slot_writes_per_instance_colour() -> void:
	var wp := _make()
	var col := Color(0.25, 0.5, 0.75, 1.0)
	wp._write_slot(1, Vector3.ZERO, WheelParticles.Look.new(0.1, 0.1, col), 0.0, col)
	var b := 1 * WheelParticles.STRIDE
	assert_almost_eq(wp._buffer[b + 12], 0.25, 0.001, "red")
	assert_almost_eq(wp._buffer[b + 13], 0.5, 0.001, "green")
	assert_almost_eq(wp._buffer[b + 14], 0.75, 0.001, "blue")


# The spawn angle is FROZEN: integrating the pool moves a particle's origin but
# must leave its basis (size + roll) and colour exactly as emitted. This is what
# keeps the per-tick cost at three float writes per live particle.
func test_advance_moves_origin_but_freezes_look() -> void:
	var wp := _make()
	_break_traction(2, 10.0)
	_tick(wp)
	var i: int = wp._next
	var b: int = i * WheelParticles.STRIDE
	var basis_before := []
	for f in [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 15]:
		basis_before.append(wp._buffer[b + f])
	var y_before: float = wp._buffer[b + 7]
	wp._physics_process(0.1)  # real delta -> gravity + drag actually integrate
	for n in basis_before.size():
		var f: int = [0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13, 14, 15][n]
		assert_almost_eq(wp._buffer[b + f], basis_before[n], 0.0,
			"basis/colour float %d is frozen after emit" % f)
	assert_ne(wp._buffer[b + 7], y_before, "the origin does move as the particle flies")


# With jitter disabled a particle takes its look's colour verbatim — the jitter is
# a variation ON the configured colour, never a replacement for it.
func test_zero_jitter_uses_the_look_colour_verbatim() -> void:
	Config.data.wheel_particle_color_jitter = 0.0
	var base := Color(0.4, 0.3, 0.2, 1.0)
	assert_eq(WheelParticles._jittered(Config.data, base), base,
		"zero jitter leaves the colour untouched")


# Tarmac is unchanged by the multi-surface work: paved road still throws nothing.
func test_look_for_surface_picks_by_surface() -> void:
	var wp := _make()
	var cfg: GameConfig = Config.data
	assert_null(wp._look_for_surface(cfg, Vector2(1.0, 1.0)), "tarmac throws nothing")
	assert_not_null(wp._look_for_surface(cfg, Vector2(1.0, 0.0)), "gravel road throws clods")
	assert_not_null(wp._look_for_surface(cfg, Vector2(0.0, 0.0)), "off-road throws grass")


func test_a_region_can_make_the_off_road_particle_a_square_clod() -> void:
	# The Alps: snow throws clods of powder, not blades of grass. The region override
	# swaps the SHAPE to the gravel clod's square while keeping the region's COLOUR, so
	# the spray stays white rather than turning into dirt. Relations only — no authored
	# width/length/size value is pinned, so a designer can retune any of them.
	var wp := _make()
	var cfg: GameConfig = Config.data
	var blade: WheelParticles.Look = wp._grass_look(cfg)
	assert_ne(blade.half_w, blade.half_h, "by default the off-road particle is a blade")

	wp.set_grass_square_override(true)
	var clod: WheelParticles.Look = wp._grass_look(cfg)
	assert_eq(clod.half_w, clod.half_h, "the override makes it square")
	var gravel: WheelParticles.Look = WheelParticles._gravel_look(cfg)
	assert_eq(clod.half_w, gravel.half_w,
		"...sized off the same field as the gravel clod, so the two cannot drift apart")
	assert_ne(clod.color, gravel.color, "but it keeps its own colour, not the gravel's")


func test_the_square_override_still_honours_the_region_colour() -> void:
	# Shape and colour are independent overrides; setting one must not discard the other.
	var wp := _make()
	var cfg: GameConfig = Config.data
	var tint := Color(0.9, 0.92, 0.95)
	wp.set_grass_color_override(tint)
	wp.set_grass_square_override(true)
	var look: WheelParticles.Look = wp._grass_look(cfg)
	assert_eq(look.color, tint, "the region colour survives the shape override")
	assert_eq(look.half_w, look.half_h, "and the shape is still square")

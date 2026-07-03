extends GutTest
# CpuParticlePool: the shared CPU MultiMesh ring-buffer machinery behind WheelParticles
# and EngineSmoke (features/wheel-dust.md, features/engine-smoke.md). Exercised through a
# tiny concrete subclass so the emit-cursor / alive-count / clear / warm-up behaviour is
# tested directly, without a real effect, car, or terrain.


# Minimal concrete pool: a plain TRANSFORM_3D layout that only writes an origin, so we can
# drive the base class's ring buffer without any effect-specific physics.
class StubPool:
	extends CpuParticlePool
	const S := 12

	func _stride() -> int:
		return S

	func build(count: int) -> void:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = QuadMesh.new()
		mm.instance_count = maxi(1, count)
		multimesh = mm
		_alloc_pool(mm.instance_count)
		for i in _max:
			var b := i * S
			_buffer[b + 0] = 1.0
			_buffer[b + 5] = 1.0
			_buffer[b + 10] = 1.0
		_clear()

	func _set_origin(i: int, p: Vector3) -> void:
		var b := i * S
		_buffer[b + 3] = p.x
		_buffer[b + 7] = p.y
		_buffer[b + 11] = p.z

	func _hide_slot(i: int) -> void:
		var b := i * S
		_buffer[b + 3] = 0.0
		_buffer[b + 7] = HIDE_Y
		_buffer[b + 11] = 0.0

	func _build_slot(i: int, p: Vector3) -> void:
		_set_origin(i, p)

	# Public shim so tests can emit without a physics tick.
	func emit(pos: Vector3, life: float) -> void:
		_emit_slot(pos, Vector3.ZERO, life)
		_set_origin(_next, pos)


func _make(count: int) -> StubPool:
	var p := StubPool.new()
	add_child_autofree(p)
	p.build(count)
	return p


func test_starts_empty_and_sized() -> void:
	var p := _make(8)
	assert_eq(p.max_particles(), 8, "pool sized to the requested count")
	assert_eq(p.live_count(), 0, "no live particles before any emission")


func test_emit_grows_live_count() -> void:
	var p := _make(8)
	p.emit(Vector3.ZERO, 1.0)
	p.emit(Vector3.ZERO, 1.0)
	assert_eq(p.live_count(), 2, "each emission into a fresh slot grows the live count")


func test_ring_buffer_caps_live_at_max() -> void:
	var p := _make(4)
	for i in 20:
		p.emit(Vector3.ZERO, 1.0)  # positive life -> nothing ages out; only the cap bounds it
	assert_eq(p.live_count(), 4, "the ring buffer bounds live particles to the pool cap")


func test_reusing_a_dead_slot_does_not_double_count() -> void:
	# Fill the ring, then emit once more: the cursor wraps onto a still-live slot and
	# overwrites it, so the count must stay at the cap (not exceed it).
	var p := _make(3)
	for i in 3:
		p.emit(Vector3.ZERO, 1.0)
	assert_eq(p.live_count(), 3, "precondition: pool full")
	p.emit(Vector3.ZERO, 1.0)
	assert_eq(p.live_count(), 3, "overwriting a live slot keeps the count, never exceeds the cap")


func test_clear_empties_the_pool() -> void:
	var p := _make(4)
	for i in 3:
		p.emit(Vector3.ZERO, 1.0)
	p._clear()
	assert_eq(p.live_count(), 0, "clear kills every particle")


func test_warm_up_draws_one_then_clears() -> void:
	var p := _make(4)
	p.warm_up(Vector3(0, 0, 5))
	assert_eq(p.live_count(), 1, "warm-up draws a single instance so the shader compiles")
	p.clear_warm_up()
	assert_eq(p.live_count(), 0, "clear_warm_up leaves the pool empty")

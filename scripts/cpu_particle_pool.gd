class_name CpuParticlePool
extends MultiMeshInstance3D
# Shared CPU particle pool for the game's hand-rolled MultiMesh effects (wheel dust,
# engine smoke). The gl_compatibility renderer (desktop + mobile) has no Decals and no
# GPU-particle physics to lean on, so these effects are the cheapest particle that still
# reads: a fixed-size CPU ring buffer drawn through ONE MultiMesh of billboarded quads.
# One draw call, one shared mesh, a fixed instance count, no per-particle scene nodes.
#
# This base owns the machinery every such pool shares:
#   - the parallel _pos / _vel / _life arrays (index == MultiMesh instance == ring slot)
#     and the live transform _buffer (STRIDE floats per slot, pushed with a SINGLE
#     multimesh.buffer assignment per tick instead of N set_instance_transform() calls —
#     the classic MultiMesh perf trap),
#   - the ring-buffer write cursor (_next) and live/max counters,
#   - clear / hide-off-screen, the warm-up shader-compile dance, and the test readouts.
#
# Subclasses supply only what differs: their STRIDE (via _stride()), how a live slot is
# written into the buffer (_build_slot / their own per-slot writer), how a dead slot is
# parked (_hide_slot), how the pool is integrated each tick (_advance), and their own
# emission source (_physics_process). See features/wheel-dust.md + features/engine-smoke.md.

# Dead particles are parked far below the world (origin Y) rather than zero-scaled —
# billboard materials don't reliably honour a zero instance scale under gl_compatibility,
# but a quad this far down is always off-screen, so it draws nothing visible.
const HIDE_Y := -1.0e7

# Particle pool (parallel arrays, index == MultiMesh instance == ring slot).
var _pos: PackedVector3Array
var _vel: PackedVector3Array
var _life: PackedFloat32Array  # remaining lifetime (s); <= 0 means the slot is dead
var _buffer: PackedFloat32Array  # the live MultiMesh buffer (STRIDE floats/slot)
var _next := -1                # ring-buffer write cursor (advances, wraps, recycles oldest)
var _alive := 0
var _max := 0


# --- Virtuals subclasses override -------------------------------------------

# Floats per MultiMesh instance for this pool's transform_format (+ colour). Drives
# the buffer size. Subclasses return their STRIDE.
func _stride() -> int:
	return 12


# Write a freshly-emitted / full-size, fully-visible slot at `p` (used by warm_up).
# Subclasses write their basis / origin / colour.
func _build_slot(_i: int, _p: Vector3) -> void:
	pass


# Park a slot off-screen (dead). Subclasses zero their own layout.
func _hide_slot(_i: int) -> void:
	pass


# --- Shared machinery -------------------------------------------------------

# Allocate the parallel arrays + transform buffer to `count` slots. Subclasses call this
# from their _build_pool after creating the MultiMesh (and may then pre-seed _buffer /
# allocate extra parallel arrays of their own before calling _clear()).
func _alloc_pool(count: int) -> void:
	_max = count
	_pos = PackedVector3Array(); _pos.resize(_max)
	_vel = PackedVector3Array(); _vel.resize(_max)
	_life = PackedFloat32Array(); _life.resize(_max)
	_buffer = PackedFloat32Array()
	_buffer.resize(_max * _stride())


# Kill every particle and park its instance off-screen.
func _clear() -> void:
	_next = -1
	_alive = 0
	if multimesh == null or _buffer.is_empty():
		return
	for i in _max:
		_life[i] = 0.0
		_hide_slot(i)
	multimesh.buffer = _buffer


# Force this pool's shader variant to compile NOW (during track generation, behind the
# loading overlay) instead of on the first live emission. Under gl_compatibility a
# material compiles on its first VISIBLE draw, and every slot sits off-screen at HIDE_Y
# until then — so we park one full-size instance in front of the camera for a rendered
# frame, then clear_warm_up() hides it again.
func warm_up(pos: Vector3) -> void:
	if multimesh == null or _buffer.is_empty():
		return
	_life[0] = 1.0
	_alive = 1
	_build_slot(0, pos)
	multimesh.buffer = _buffer


# Undo warm_up(): park the warm-up instance off-screen and reset the pool to empty.
func clear_warm_up() -> void:
	_clear()


# Reserve the next ring slot for a new particle, recycling the oldest when full, and
# record its lifetime + position/velocity. Advances _next to the written slot and keeps
# _alive correct. The caller writes the slot's buffer layout (via its own slot writer)
# and uploads the whole buffer once per tick.
func _emit_slot(pos: Vector3, vel: Vector3, life: float) -> void:
	_next = (_next + 1) % _max
	if _life[_next] <= 0.0:
		_alive += 1  # reused a dead slot; overwriting a live one keeps the count
	_pos[_next] = pos
	_vel[_next] = vel
	_life[_next] = life


# --- Readouts (tests) --------------------------------------------------------

func live_count() -> int:
	return _alive


func max_particles() -> int:
	return _max

extends GutTest
# EngineSmoke: grey smoke puffed from the bonnet each time a damaged engine misfires
# (features/engine-smoke.md). Driven against a stub car exposing drivetrain.engine
# with a misfire_count, so the emission / ring-buffer / ageing logic is exercised
# without a real vehicle or rendering.


# Stub engine: only the misfire_count EngineSmoke reads.
class StubEngine:
	extends RefCounted
	var misfire_count := 0


# Stub drivetrain: just holds the engine.
class StubDrivetrain:
	extends RefCounted
	var engine


# Stub damage model: only the misfire_level severity EngineSmoke reads in synthetic mode.
class StubDamage:
	extends RefCounted
	var level := 0.0
	func misfire_level(_cfg) -> float:
		return level


# Stub car: a drivetrain + a damage model + a world transform (engine emit point) +
# the per-car engine_smoke_local EngineSmoke reads for the emit point.
class StubCar:
	extends Node3D
	var drivetrain
	var damage
	var engine_smoke_local := Vector3(0.0, 0.4, -1.2)


var _car: StubCar
var _engine: StubEngine
var _dt: StubDrivetrain
var _damage: StubDamage


func before_each() -> void:
	Config.reset()
	Config.data.engine_smoke_enabled = true
	_engine = StubEngine.new()
	_dt = StubDrivetrain.new()
	_dt.engine = _engine
	_damage = StubDamage.new()
	_car = StubCar.new()
	_car.drivetrain = _dt
	_car.damage = _damage
	add_child_autofree(_car)
	_car.position = Vector3(0, 1, 0)


func after_each() -> void:
	Config.reset()


func _make() -> EngineSmoke:
	var es := EngineSmoke.new()
	add_child_autofree(es)
	es.setup(_car)
	return es


func _make_synthetic() -> EngineSmoke:
	var es := EngineSmoke.new()
	add_child_autofree(es)
	es.setup_synthetic(_car)
	return es


# Tick with delta 0 so the pool emits without ageing (lifetime untouched).
func _tick(es: EngineSmoke) -> void:
	es._physics_process(0.0)


func test_no_misfire_no_smoke() -> void:
	var es := _make()
	_tick(es)
	_tick(es)
	assert_eq(es.live_count(), 0, "a healthy engine (no new cuts) puffs no smoke")


func test_warm_up_draws_then_clears() -> void:
	# warm_up() parks one visible puff so the shader compiles behind the loading
	# screen; clear_warm_up() must return the pool to empty.
	var es := _make()
	es.warm_up(Vector3(0, 0, 10))
	assert_eq(es.live_count(), 1, "warm-up draws a single puff so the shader compiles")
	es.clear_warm_up()
	assert_eq(es.live_count(), 0, "clear_warm_up leaves the pool empty")


func test_a_misfire_puffs_a_burst() -> void:
	var es := _make()
	_engine.misfire_count += 1  # one cut happened
	_tick(es)
	assert_eq(es.live_count(), Config.data.engine_smoke_per_cut,
		"one misfire puffs one burst of smoke")


# The single live particle's local Z (car sits at identity basis, so world Z == local
# Z), ignoring the small per-puff jitter. Only valid with exactly one particle alive.
func _live_local_z(es: EngineSmoke) -> float:
	for i in es.max_particles():
		if es._life[i] > 0.0:
			return es._pos[i].z
	return NAN


func test_puff_emits_from_the_cars_engine_point() -> void:
	# Smoke leaves from the car's engine_smoke_local, not a fixed bonnet point: a
	# rear-engine emit point (+Z) puffs behind the car origin, a front one (−Z) ahead.
	Config.data.engine_smoke_per_cut = 1  # one particle so _live_local_z is unambiguous
	_car.engine_smoke_local = Vector3(0.0, 0.4, 1.5)  # rear engine (+Z = rearward)
	var es := _make()
	_engine.misfire_count += 1
	_tick(es)
	assert_almost_eq(_live_local_z(es), 1.5, 0.15, "rear-engine smoke puffs from behind the car origin")

	_car.engine_smoke_local = Vector3(0.0, 0.4, -1.5)  # front engine (−Z = forward)
	var es2 := _make()
	_engine.misfire_count += 1
	_tick(es2)
	assert_almost_eq(_live_local_z(es2), -1.5, 0.15, "front-engine smoke puffs from ahead of the car origin")


func test_no_new_cut_emits_nothing_more() -> void:
	var es := _make()
	_engine.misfire_count += 1
	_tick(es)
	var after_first := es.live_count()
	_tick(es)  # count unchanged
	assert_eq(es.live_count(), after_first, "no smoke added while the misfire count is unchanged")


func test_burst_count_capped_per_tick() -> void:
	# A rapid run of cuts between ticks can't flood the pool: at most
	# max_puffs_per_tick bursts are emitted in one frame.
	var es := _make()
	_engine.misfire_count += 100
	_tick(es)
	var cap: int = Config.data.engine_smoke_max_puffs_per_tick * Config.data.engine_smoke_per_cut
	assert_eq(es.live_count(), cap, "at most max_puffs_per_tick bursts spawn in a single tick")


func test_live_count_never_exceeds_pool_cap() -> void:
	Config.data.engine_smoke_max = 12
	Config.data.engine_smoke_max_puffs_per_tick = 10
	Config.data.engine_smoke_per_cut = 5
	var es := _make()
	for i in 20:
		_engine.misfire_count += 10
		_tick(es)
	assert_lte(es.live_count(), es.max_particles(), "the ring buffer bounds live smoke to the cap")


func test_smoke_rises_and_expires() -> void:
	var es := _make()
	_engine.misfire_count += 1
	_tick(es)  # emit (delta 0, no ageing)
	assert_gt(es.live_count(), 0, "precondition: smoke is alive")
	# Age past the full lifetime: every particle recycles.
	var life: float = Config.data.engine_smoke_lifetime_s
	es._physics_process(life + 0.1)
	assert_eq(es.live_count(), 0, "smoke expires after its lifetime")


func test_disabled_emits_nothing() -> void:
	Config.data.engine_smoke_enabled = false
	var es := _make()
	_engine.misfire_count += 1
	_tick(es)
	assert_eq(es.live_count(), 0, "no smoke when the effect is disabled")


# --- Synthetic mode (HQ / static display cars) -------------------------------

func test_synthetic_healthy_never_puffs() -> void:
	_damage.level = 0.0  # fully healthy
	var es := _make_synthetic()
	for i in 10:
		es._physics_process(1.0)  # plenty of time
	assert_eq(es.live_count(), 0, "a healthy display car puffs no synthetic smoke")


func test_synthetic_damaged_puffs_on_the_timer() -> void:
	_damage.level = 1.0  # worst damage -> shortest interval
	var es := _make_synthetic()
	# One tick shorter than the min interval: not yet.
	es._physics_process(Config.data.engine_smoke_synthetic_interval_min * 0.5)
	assert_eq(es.live_count(), 0, "no puff before the interval elapses")
	# Cross the interval: a burst spawns.
	es._physics_process(Config.data.engine_smoke_synthetic_interval_min)
	assert_eq(es.live_count(), Config.data.engine_smoke_per_cut, "a puff fires once the interval elapses")


func test_synthetic_worse_damage_puffs_sooner() -> void:
	# Same elapsed time: a wreck (severity 1) has puffed, a lightly-damaged car
	# (severity just above the threshold) has a longer interval and has not.
	var dt: float = Config.data.engine_smoke_synthetic_interval_min + 0.01
	_damage.level = 1.0
	var wrecked := _make_synthetic()
	wrecked._physics_process(dt)
	assert_gt(wrecked.live_count(), 0, "a wrecked car puffs within the short interval")

	_damage.level = 0.1
	var light := _make_synthetic()
	light._physics_process(dt)
	assert_eq(light.live_count(), 0, "a lightly-damaged car's interval is longer, so not yet")

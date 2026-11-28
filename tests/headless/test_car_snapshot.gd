extends GutTest
# The car snapshot (features/car-physics.md → Snapshot): one call returns every piece of per-tick car
# state as JSON-safe values. The completeness guards fail when a new state variable is added to the
# engine or damage model without being added to its snapshot().

# Script variables that change but are not per-tick state: config references, caches re-derived
# from the config, and the RNG object itself (its position is recorded as rng_state).
const NOT_STATE := {
	"EngineSim": ["config", "_rng", "shift_up_speeds", "_has_nitrous"],
	"DamageModel": ["_rng"],
}

var _world: Node3D


func after_all() -> void:
	if _world != null:
		_world.free()
		SceneTestHelpers.remove_level_world()
	Config.reset()


static func _script_vars(obj: Object) -> Dictionary:
	var out := {}
	for p in obj.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			var v: Variant = obj.get(p.name)
			out[p.name] = v.duplicate(true) if (v is Array or v is Dictionary) else v
	return out


func _assert_complete(kind: String, before: Dictionary, after: Dictionary, snap: Dictionary) -> void:
	var missing: Array = []
	for name in after:
		if after[name] != before[name] and not snap.has(name) and not NOT_STATE[kind].has(name):
			missing.append(name)
	assert_eq(missing, [], "%s state that changed but is not in snapshot(): %s" % [kind, missing])


func test_engine_snapshot_covers_every_changing_variable() -> void:
	var cfg := GameConfig.new()
	cfg.turbo_enabled = true
	cfg.turbo_boost_gain = 0.5
	cfg.turbo_antilag = true
	cfg.turbo_antilag_drive = 0.5
	cfg.supercharger_boost_gain = 0.3
	cfg.nitrous_boost_gain = 0.5
	cfg.nitrous_tank_seconds = 1.0
	cfg.auto_gearbox = false
	var e := EngineSim.new(cfg)
	var before := _script_vars(e)
	var h := 1.0 / 480.0
	for i in 600:
		var throttle := 1.0 if i % 80 < 40 else 0.0
		e.nitrous_active = i > 100 and i < 400
		e.misfire_level = 0.8 if i > 300 else 0.0
		if i == 350:
			e.rev_limit_scale = 0.6
		if i % 120 == 60:
			e.request_shift(1)
		if i % 120 == 110:
			e.request_shift(-1)
		e.step(h, throttle, float(i) * 0.5, i % 200 > 190)
	e.killed = true
	e.step(h, 0.0, 0.0)
	_assert_complete("EngineSim", before, _script_vars(e), e.snapshot())


func test_damage_snapshot_covers_every_changing_variable() -> void:
	var cfg := GameConfig.new()
	var dm := DamageModel.new()
	dm.thermal = true
	dm.field(1000.0, 1000.0)
	var before := _script_vars(dm)
	dm.register_deceleration(40.0, 1.0 / 60.0, Vector3.ZERO, cfg)
	for i in 300:
		dm.thermal_step(1.0 / 60.0, 1.0, cfg)
		dm.regen(1.0 / 60.0, cfg)
	dm.apply_loss(dm.max_hp * 2.0)
	dm.invulnerable = true
	_assert_complete("DamageModel", before, _script_vars(dm), dm.snapshot())


func _assert_same_keys(a: Variant, b: Variant, path: String) -> void:
	if a is Dictionary:
		assert_true(b is Dictionary, "%s is still a dictionary" % path)
		if not b is Dictionary:
			return
		var ka: Array = a.keys().map(func(k): return String(k))
		var kb: Array = b.keys().map(func(k): return String(k))
		ka.sort()
		kb.sort()
		assert_eq(kb, ka, "%s keeps its keys" % path)
		for k in a:
			if b.has(k):
				_assert_same_keys(a[k], b[k], "%s.%s" % [path, k])


func test_car_snapshot_is_json_safe_and_stable() -> void:
	_world = await SceneTestHelpers.add_level_world(self)
	var car: VehicleBody3D = _world.get_node("Car")
	car.record_contacts = true
	await wait_physics_frames(10)
	var snap: Dictionary = car.snapshot()
	assert_eq(snap, car.snapshot(), "two snapshots with no tick between them are equal")
	assert_true(snap.has("drivetrain") and snap.drivetrain.has("engine") and snap.has("damage"),
		"the car snapshot nests the drivetrain, engine and damage snapshots")
	var parsed: Variant = JSON.parse_string(JSON.stringify(snap, "", true, true))
	_assert_same_keys(snap, parsed, "snapshot")
	car.record_contacts = false

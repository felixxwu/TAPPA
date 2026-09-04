extends GutTest
# Regression: a LIVE drivetrain rebuild must not change how hard the tyres are pressed
# into the ground.
#
# The bug this pins (reported as "swap the tyres on the start line and the car has way more
# grip than stock tyres should on a snow stage"): VehicleBody3D repaints `wheel.position`
# every physics step with the connection point plus the settled suspension travel, so a
# wheel that has settled reads about one travel LOWER than where it is mounted.
# `Drivetrain._init` captured its `hardpoints` from that live position, and
# `Car.refit_upgrades` (the start-line Upgrades menu) rebuilds the drivetrain on a car that
# has been sitting at the line for seconds — so the rebuilt drivetrain measured suspension
# compression from a mount a whole travel too low and over-reported EVERY wheel's normal
# force by ~60%. Tyre force scales with normal force, so the car silently gained grip on any
# upgrade edit, whatever the edit was. The fix keys the hardpoints off Car.wheel_mount().
#
# Deliberately value-agnostic throughout: every assertion compares the car against ITSELF
# before the rebuild, or against an identically-fielded reference car — never against a
# particular force, spring rate or weight ratio, so no retune can break these.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const UpgradeFixtures = preload("res://tests/headless/upgrade_fixtures.gd")
const FIXTURE := "res://tests/fixtures/test_track.tscn"
const SETTLE_FRAMES := 180  # long enough for the suspension to settle and drift wheel.position

var _scene: Node3D
var _car: VehicleBody3D


func before_all() -> void:
	SceneHelpers.minimal_world()
	CarFixtures.install()


func after_all() -> void:
	CarFixtures.restore()
	Config.reset()


func before_each() -> void:
	_scene = load(FIXTURE).instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")


# The fixture car wearing the snow compound, unless `parked` names it.
#
# THE ARGUMENT IS THE PARKED (inactive) LIST, kept that way deliberately: it used to be
# `disabled_upgrades` beside a fixed `installed_upgrades`, and every call site below reads
# `_owned([])` as "the compound is on" / `_owned(["fx_snow_tires"])` as "the compound is
# off". Flipping the argument's sense to an active list would have inverted seventeen call
# sites silently.
#
# What DID change is the seam. `UpgradeLibrary.active_effects` reads a car's `boosts` list
# now; the persistent parts model that filled `installed_upgrades`/`disabled_upgrades` is
# deleted (todo/roguelike-pivot.md). An owned dict still carrying the old keys applies
# NOTHING, so every assertion about a fitted compound compared a value to itself and
# passed — which is exactly how this file went quietly red-then-green across the pivot.
func _owned(parked: Array) -> Dictionary:
	var active: Array = [] if parked.has("fx_snow_tires") else ["fx_snow_tires"]
	return {"model_id": "fx_light_rwd", "instance_id": 1,
		"boosts": UpgradeFixtures.boosts(active), "tuning": {}}


func _wait(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _loads() -> Array:
	var out: Array = []
	for wheel in _car.drivetrain.all_wheels:
		out.append(_car.drivetrain.wheel_normal_force(wheel))
	return out


func _total(loads: Array) -> float:
	var sum := 0.0
	for v in loads:
		sum += float(v)
	return sum


# The core contract: refit the SAME upgrade set onto a settled car and nothing about the
# tyre loads may move. (Same-set refit, so any change can only come from the rebuild
# itself, not from the upgrade layer.)
func test_live_refit_does_not_change_tyre_loads() -> void:
	_car.apply_owned(_owned([]))
	await _wait(SETTLE_FRAMES)
	var before := _loads()
	# Per wheel, not the sum: wheel_normal_force returns 0 for a wheel out of contact, so a
	# summed guard would let an airborne wheel compare 0.0 to 0.0 and pass silently.
	for i in before.size():
		assert_gt(float(before[i]), 0.0, "wheel %d is loaded before the refit (not vacuous)" % i)
	_car.refit_upgrades(_owned([]))
	await _wait(1)
	var after := _loads()
	for i in before.size():
		assert_almost_eq(float(after[i]), float(before[i]), maxf(float(before[i]) * 0.02, 1.0),
			"wheel %d carries the same load after a live drivetrain rebuild" % i)


# The same for the mount geometry the compression is measured from: a rebuild must re-derive
# it from the authored mount, so it cannot drift with the settled wheel transform.
func test_live_refit_keeps_the_authored_wheel_mounts() -> void:
	_car.apply_owned(_owned([]))
	var before := {}
	for wheel in _car.drivetrain.all_wheels:
		before[wheel.name] = _car.drivetrain.hardpoints[wheel]
	await _wait(SETTLE_FRAMES)
	_car.refit_upgrades(_owned([]))
	for wheel in _car.drivetrain.all_wheels:
		# The WHOLE vector: x/z catch a regression in _relocate_wheels' mount re-record
		# (which sets the per-car track/wheelbase), y catches the suspension-travel drift.
		assert_almost_eq(_car.drivetrain.hardpoints[wheel].distance_to(before[wheel.name]), 0.0,
			0.0001, "%s keeps its authored mount across a live rebuild" % wheel.name)


# The same invariant stated RELATIVELY, which is what makes it value-free: a car that has
# settled and then been refitted must carry the same total load as an identical car freshly
# fielded and settled. A compression reference wrong by a suspension travel shows up here as
# a large ratio, and no spring/mass retune can break it (both cars share the config).
#
# Deliberately NOT an absolute band against mass x g: wheel_normal_force is a MIRROR of
# Godot's suspension (a per-unit-mass rate, not force-balanced against the real solver), so
# the settled sum is not ~1.0x weight and any band around it would pin the spring rate.
func test_refitted_load_matches_a_freshly_fielded_car() -> void:
	_car.apply_owned(_owned([]))
	await _wait(SETTLE_FRAMES)
	_car.refit_upgrades(_owned([]))
	await _wait(1)
	var refitted := _total(_loads())
	# A second car, same owned state, never refitted — the reference.
	var fresh_scene: Node3D = load(FIXTURE).instantiate()
	add_child_autofree(fresh_scene)
	var fresh: VehicleBody3D = fresh_scene.get_node("Car")
	fresh.apply_owned(_owned([]))
	await _wait(SETTLE_FRAMES)
	var reference := 0.0
	for wheel in fresh.drivetrain.all_wheels:
		reference += fresh.drivetrain.wheel_normal_force(wheel)
	assert_gt(reference, 0.0, "the reference car is loaded (test isn't vacuous)")
	assert_almost_eq(refitted, reference, reference * 0.05,
		"a refitted car carries the same total tyre load as a freshly fielded one")


# The PREMISE the whole fix rests on: the live wheel transform really does drift away from
# the authored mount once the suspension settles. Without this, the three tests above would
# silently become tautologies if a future Godot stopped repainting wheel.position — the guard
# would be inert and nothing would say so.
func test_the_live_wheel_position_drifts_from_the_authored_mount() -> void:
	_car.apply_owned(_owned([]))
	var mounts := {}
	for wheel in _car.drivetrain.all_wheels:
		mounts[wheel.name] = _car.wheel_mount(wheel)
	await _wait(SETTLE_FRAMES)
	var drifted := 0
	for wheel in _car.drivetrain.all_wheels:
		assert_almost_eq(_car.wheel_mount(wheel).distance_to(mounts[wheel.name]), 0.0, 0.0001,
			"%s's authored mount is stable while the car settles" % wheel.name)
		if absf(wheel.position.y - _car.wheel_mount(wheel).y) > 0.01:
			drifted += 1
	assert_gt(drifted, 0,
		"the live wheel transform DOES drift from the mount once settled — "
		+ "if this fails the regression tests above have gone inert, not green")


# The sibling reader found by the post-fix sweep: _recompute_axles() builds the downforce
# application points from the same wheel geometry, and also runs on every rebuild. A live
# refit must not move them either (it used to drop them by ~one suspension travel, quietly
# changing the car's aero pitch lever).
func test_live_refit_keeps_the_axle_midpoints() -> void:
	_car.apply_owned(_owned([]))
	var front_before: Vector3 = _car._front_axle
	var rear_before: Vector3 = _car._rear_axle
	assert_gt(front_before.distance_to(rear_before), 0.0,
		"the axle midpoints are distinct to begin with (test isn't vacuous)")
	await _wait(SETTLE_FRAMES)
	_car.refit_upgrades(_owned([]))
	assert_almost_eq(_car._front_axle.distance_to(front_before), 0.0, 0.0001,
		"the front axle midpoint survives a live drivetrain rebuild")
	assert_almost_eq(_car._rear_axle.distance_to(rear_before), 0.0, 0.0001,
		"the rear axle midpoint survives a live drivetrain rebuild")


# The live path must RECONFIGURE the drivetrain, not replace it. A rebuild is what re-derived
# geometry from the live scene in the first place, and it also throws away everything the car
# has accumulated — revs, gear, boost, wheel spin, the mirrored gearbox mode. Asserting the
# object identity is deliberate: "same drivetrain, reconfigured" IS the contract now, and it
# is the cheapest way to stop a future edit quietly reintroducing the rebuild.
func test_live_refit_reconfigures_the_drivetrain_instead_of_rebuilding_it() -> void:
	_car.apply_owned(_owned([]))
	await _wait(SETTLE_FRAMES)
	var drivetrain = _car.drivetrain
	var engine = drivetrain.engine
	_car.refit_upgrades(_owned(["fx_snow_tires"]))
	assert_same(_car.drivetrain, drivetrain, "the refit keeps the same Drivetrain instance")
	assert_same(_car.drivetrain.engine, engine, "...and the same EngineSim inside it")


# ...and therefore the running driveline state survives an upgrade edit.
func test_live_refit_preserves_the_running_driveline_state() -> void:
	_car.apply_owned(_owned([]))
	await _wait(SETTLE_FRAMES)
	var engine = _car.drivetrain.engine
	# Markers a rebuild would reset from the config: revs, the selected gear, the mirrored
	# gearbox mode, and the wheel spin the drivetrain integrates.
	engine.omega = engine.idle_omega() * 2.0
	engine.gear = 2
	engine.auto = not _car.config.auto_gearbox
	_car.drivetrain.rear_omega = 12.5
	var revs: float = engine.omega
	var was_auto: bool = engine.auto
	_car.refit_upgrades(_owned(["fx_snow_tires"]))
	assert_almost_eq(_car.drivetrain.engine.omega, revs, 0.001, "the engine keeps its revs")
	assert_eq(_car.drivetrain.engine.gear, 2, "...its selected gear")
	assert_eq(_car.drivetrain.engine.auto, was_auto,
		"...and the player's mirrored gearbox mode (a rebuild used to revert it to the default)")
	assert_almost_eq(_car.drivetrain.rear_omega, 12.5, 0.001, "the driven axle keeps its spin")


# What the reconfigure DOES have to change: the driven axle, and the engine's config-derived
# shift points. Driven directly on the drivetrain — the car-level route to a drive-mode change
# is gated on a purchased conversion, which is the garage's contract, not this one's.
func test_reconfigure_switches_the_driven_axle_and_keeps_the_engine() -> void:
	_car.apply_owned(_owned([]))
	await _wait(SETTLE_FRAMES)
	var engine = _car.drivetrain.engine
	var driven_before := 0
	for wheel in _car.drivetrain.all_wheels:
		if _car.drivetrain.is_wheel_driven(wheel):
			driven_before += 1
	_car.drivetrain.reconfigure(Drivetrain.DriveMode.AWD)
	assert_eq(int(_car.drivetrain.drive_mode), int(Drivetrain.DriveMode.AWD),
		"reconfigure switches the driven axle layout")
	var driven_after := 0
	for wheel in _car.drivetrain.all_wheels:
		if _car.drivetrain.is_wheel_driven(wheel):
			driven_after += 1
	assert_gt(driven_after, driven_before, "AWD drives more wheels than the fixture's stock RWD")
	assert_same(_car.drivetrain.engine, engine, "and it does NOT replace the engine")
	assert_gt(_car.drivetrain.engine.shift_up_speeds.size(), 0,
		"the shift points are (re-)derived, not left empty")


# And the upgrade layer still works through the same call: disabling the fitted compound
# must still reach the live config (the reason refit_upgrades exists at all).
func test_live_refit_still_applies_the_upgrade_change() -> void:
	_car.apply_owned(_owned([]))
	await _wait(SETTLE_FRAMES)
	var fitted: float = _car.config.wheel_friction_slip_front
	_car.refit_upgrades(_owned(["fx_snow_tires"]))
	assert_lt(_car.config.wheel_friction_slip_front, fitted,
		"parking the grip compound still lowers the live axle mu")
	assert_almost_eq(_car.config.tire_snow_grip_mult, 1.0, 1e-6,
		"...and its surface-dependent term returns to the identity")

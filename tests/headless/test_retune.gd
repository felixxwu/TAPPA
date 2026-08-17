extends GutTest
# Car.retune: re-apply a CHANGED per-car tuning to the already-fielded LIVE config
# WITHOUT reshaping the body. Regression for the start-line Tune Car menu, which used
# to call apply_owned — that relocates the wheels (detach/re-attach from the tree) and
# resets the pose on the staged, simulating VehicleBody3D, corrupting its suspension so
# the wheels dropped through the floor. retune must leave the body untouched and only
# re-derive the tuned config fields (all read live each physics step). Uses the
# synthetic CarFixtures roster so no shipped catalogue entry is depended on.

const SceneHelpers = preload("res://tests/headless/scene_helpers.gd")
const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const UpgradeFixtures = preload("res://tests/headless/upgrade_fixtures.gd")

var _scene: Node3D
var _car: VehicleBody3D


func before_all() -> void:
	SceneHelpers.minimal_world()
	CarFixtures.install()
	UpgradeFixtures.install()
	_scene = load("res://main.tscn").instantiate()
	add_child(_scene)
	_car = _scene.get_node("Car")


func after_all() -> void:
	_scene.free()
	UpgradeFixtures.restore()
	CarFixtures.restore()
	Config.reset()


func before_each() -> void:
	# Every test mutates only the live config via retune/refit; re-field the fixture car
	# from a clean owned dict so each test starts from the same pre-tune baseline snapshot
	# (retune/refit_upgrades re-derive from the baseline captured at fielding, so this is
	# the reset point — without it, one test's tuning would leak into the next).
	_car.apply_owned({"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {}, "upgrades": {}})


func test_retune_applies_the_changed_tuning_to_the_live_config() -> void:
	var front_before: float = _car.config.wheel_friction_slip_front
	var rear_before: float = _car.config.wheel_friction_slip_rear
	_car.retune({"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {"grip_balance": 1.0}, "upgrades": {}})
	assert_gt(_car.config.wheel_friction_slip_front, front_before, "oversteer shifts grip onto the front, live")
	assert_lt(_car.config.wheel_friction_slip_rear, rear_before, "oversteer shifts grip off the rear, live")


func test_retune_is_idempotent_and_does_not_compound() -> void:
	var owned := {"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {"grip_balance": 0.7}, "upgrades": {}}
	_car.retune(owned)
	var front_once: float = _car.config.wheel_friction_slip_front
	_car.retune(owned)  # same tuning again
	assert_almost_eq(_car.config.wheel_friction_slip_front, front_once, 0.0001,
		"re-applying the same tuning restores the baseline first, so it never compounds")


# Field the given owned state onto a FRESH car and return its live config — the ground
# truth that any live re-derive (retune/refit_upgrades) of the same final state must
# match. Comparing two independently-built configs keeps these tests value-agnostic (no
# pinned tunable number), per the project testing rules.
# NOTE: returns the LIVE config object, which for a main.tscn car is the shared
# Config.data — i.e. the SAME object as _car.config. Comparing a field of _car.config
# against this reference is a variable compared with itself and passes vacuously (every
# comparison test in this file used to do exactly that). Prefer _fresh_field_values().
func _fresh_field(owned: Dictionary) -> GameConfig:
	var fresh: VehicleBody3D = load("res://main.tscn").instantiate().get_node("Car")
	add_child_autofree(fresh.get_parent())
	fresh.apply_owned(owned)
	return fresh.config


func _owned(upgrades: Array, disabled: Array, tuning: Dictionary) -> Dictionary:
	return {"model_id": "fx_light_rwd", "instance_id": 1,
		"installed_upgrades": upgrades, "disabled_upgrades": disabled, "tuning": tuning}


# Regression (the "really slow after removing the turbo" bug): a live upgrade change
# followed by a tune must land on the SAME config a fresh fielding of that final
# upgrade+tuning state produces — the old tuning must not stay baked into fields the
# upgrade layer doesn't own (peak_torque, grip, brake_bias). The single-baseline
# re-derive (_rederive_live_config) guarantees this for ANY field, so it can't recur.
func test_refit_then_retune_matches_a_fresh_field_no_compounding() -> void:
	# Field WITH a turbo AND a partial detune, then remove the turbo and tune back to
	# full power — the exact start-line flow that surfaced the bug.
	_car.apply_owned(_owned(["fx_turbo_big"], [], {"engine_detune": 0.7}))
	_car.refit_upgrades(_owned(["fx_turbo_big"], ["fx_turbo_big"], {"engine_detune": 0.7}))
	var final_state := _owned(["fx_turbo_big"], ["fx_turbo_big"], {"engine_detune": 1.0})
	_car.retune(final_state)
	assert_almost_eq(_car.config.peak_torque,
		float(_fresh_field_values(final_state)["peak_torque"]), 0.01,
		"refit-then-retune lands on the same power as a fresh field (old tuning not baked in)")


# Sibling of the detune case for a grip axis (a tuning-only field the upgrade layer
# doesn't own): removing an upgrade then re-tuning grip must not compound.
func test_refit_then_retune_grip_matches_a_fresh_field() -> void:
	_car.apply_owned(_owned(["fx_turbo_big"], [], {"grip_balance": 0.6}))
	_car.refit_upgrades(_owned(["fx_turbo_big"], ["fx_turbo_big"], {"grip_balance": 0.6}))
	var final_state := _owned(["fx_turbo_big"], ["fx_turbo_big"], {"grip_balance": -0.3})
	_car.retune(final_state)
	var fresh := _fresh_field_values(final_state)
	assert_almost_eq(_car.config.wheel_friction_slip_front,
		float(fresh["wheel_friction_slip_front"]), 0.0001,
		"grip front matches a fresh field after refit+retune (no compounding)")
	assert_almost_eq(_car.config.wheel_friction_slip_rear,
		float(fresh["wheel_friction_slip_rear"]), 0.0001,
		"grip rear matches a fresh field after refit+retune (no compounding)")


# The downforce pair is the ONLY field both layers write (upgrade aero kit adds, tuning
# aero balance multiplies). Removing the turbo while keeping the aero kit, then re-tuning
# aero, must land on a fresh field — the shared field is the ordering-sensitive one.
func test_refit_then_retune_aero_downforce_matches_a_fresh_field() -> void:
	_car.apply_owned(_owned(["fx_turbo_big", "fx_aero"], [], {"aero_balance": 0.8}))
	_car.refit_upgrades(_owned(["fx_turbo_big", "fx_aero"], ["fx_turbo_big"], {"aero_balance": 0.8}))
	var final_state := _owned(["fx_turbo_big", "fx_aero"], ["fx_turbo_big"], {"aero_balance": -0.4})
	_car.retune(final_state)
	var fresh := _fresh_field_values(final_state)
	assert_almost_eq(_car.config.downforce_front, float(fresh["downforce_front"]), 0.0001,
		"downforce front (the shared field) matches a fresh field after refit+retune")
	assert_almost_eq(_car.config.downforce_rear, float(fresh["downforce_rear"]), 0.0001,
		"downforce rear (the shared field) matches a fresh field after refit+retune")


# The opposite order: tune first, then change an upgrade. Must also match a fresh field.
func test_retune_then_refit_matches_a_fresh_field() -> void:
	_car.apply_owned(_owned(["fx_turbo_big"], [], {"engine_detune": 1.0}))
	_car.retune(_owned(["fx_turbo_big"], [], {"engine_detune": 0.5}))
	var final_state := _owned(["fx_turbo_big"], ["fx_turbo_big"], {"engine_detune": 0.5})
	_car.refit_upgrades(final_state)
	assert_almost_eq(_car.config.peak_torque,
		float(_fresh_field_values(final_state)["peak_torque"]), 0.01,
		"retune-then-refit lands on a fresh field's power (no stale baseline)")


# Repeated refits cycling an upgrade on/off/on must not drift: the baseline is captured
# once at fielding and every re-derive starts from it.
func test_repeated_refit_does_not_drift() -> void:
	_car.apply_owned(_owned(["fx_turbo_big"], [], {}))
	_car.refit_upgrades(_owned(["fx_turbo_big"], ["fx_turbo_big"], {}))  # off
	_car.refit_upgrades(_owned(["fx_turbo_big"], [], {}))               # on
	_car.refit_upgrades(_owned(["fx_turbo_big"], ["fx_turbo_big"], {}))  # off
	var final_state := _owned(["fx_turbo_big"], [], {})                 # on
	_car.refit_upgrades(final_state)
	var fresh := _fresh_field_values(final_state)
	assert_almost_eq(_car.config.peak_torque, float(fresh["peak_torque"]), 0.01,
		"peak_torque matches a fresh field after cycling the turbo (no drift)")
	assert_eq(_car.config.turbo_enabled, bool(fresh["turbo_enabled"]),
		"turbo_enabled matches a fresh field after cycling (flag re-derived from baseline)")
	assert_almost_eq(_car.config.turbo_parasitic_friction,
		float(fresh["turbo_parasitic_friction"]), 0.0001,
		"turbo parasitic friction matches a fresh field after cycling")


func test_retune_does_not_reshape_or_reset_the_body() -> void:
	# The crux of the bug: retune must NOT relocate wheels or reset the pose (apply_owned
	# does both, which broke the live body). Capture the wheel node identities + the
	# body transform, retune, and assert nothing moved.
	var wheels_before := _car.find_children("*", "VehicleWheel3D", false)
	var xform_before: Transform3D = _car.global_transform
	_car.retune({"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {"grip_balance": 1.0, "engine_detune": 0.5}, "upgrades": {}})
	var wheels_after := _car.find_children("*", "VehicleWheel3D", false)
	assert_eq(wheels_after.size(), wheels_before.size(), "no wheels added/removed")
	for w in wheels_before:
		assert_true(wheels_after.has(w), "the SAME wheel nodes remain (not re-instantiated / re-parented)")
	assert_eq(_car.global_transform, xform_before, "the body pose is untouched (no reset_to)")


# Field `owned` on a throwaway car and return a VALUE SNAPSHOT of the resulting config.
#
# Deliberately NOT the config object: the main.tscn car runs on the SHARED Config.data, so
# a returned reference is the same object the car under test then mutates, and any later
# comparison against it is a variable compared with itself — vacuously true.
func _fresh_field_values(owned: Dictionary) -> Dictionary:
	return _fresh_field(owned).snapshot_values()


# --- Start-line tyre swap (regression) ---------------------------------------
#
# Reported as "changing tyres at the start line doesn't take effect on the stage",
# specifically snow tyres -> Stock before a snow stage. It did take effect — but the
# investigation cost a lot precisely because nothing asserted it, so lock it here.
#
# The assertion is a COMPARISON, never a number: a car switched back to stock must land
# on exactly the config a car that never had the tyre produces. That holds for any
# retuning of the compound, and it is the property that actually matters — "no trace of
# the removed tyre is left behind".
func test_refitting_to_stock_tyres_matches_a_car_that_never_had_them() -> void:
	var stock_state := _owned([], [], {})
	var always_stock := _fresh_field_values(stock_state)

	# Field WITH the surface-specialised compound, then take it off again.
	_car.apply_owned(_owned(["fx_snow_tires"], [], {}))
	assert_ne(_car.config.tire_snow_grip_mult, float(always_stock["tire_snow_grip_mult"]),
		"setup: the fitted compound should move the surface term, or this proves nothing")
	_car.refit_upgrades(stock_state)

	for field in ["tire_snow_grip_mult", "tire_tarmac_grip_mult",
			"wheel_friction_slip_front", "wheel_friction_slip_rear"]:
		assert_almost_eq(float(_car.config.get(field)), float(always_stock[field]),
			0.0001, "%s: removing the tyre must leave no trace of it behind" % field)


# The other direction, and the one a player actually reaches for before a snow stage:
# fitting the compound live must land where a fresh fielding of that same state does.
func test_refitting_onto_a_surface_tyre_matches_a_fresh_field() -> void:
	var snow_state := _owned(["fx_snow_tires"], [], {})
	var fresh := _fresh_field_values(snow_state)

	_car.apply_owned(_owned([], [], {}))
	_car.refit_upgrades(snow_state)

	for field in ["tire_snow_grip_mult", "tire_tarmac_grip_mult",
			"wheel_friction_slip_front", "wheel_friction_slip_rear"]:
		assert_almost_eq(float(_car.config.get(field)), float(fresh[field]), 0.0001,
			"%s: a live tyre fit must match a fresh fielding of the same build" % field)


# A PARKED tyre (installed but disabled — what the menu's "Stock" option actually does,
# it disables rather than uninstalls) must be inert. This is the exact save state the
# reported repro produced: installed=[snow], disabled=[snow].
func test_a_parked_tyre_is_inert() -> void:
	var parked := _owned(["fx_snow_tires"], ["fx_snow_tires"], {})
	var always_stock := _fresh_field_values(_owned([], [], {}))
	_car.apply_owned(_owned(["fx_snow_tires"], [], {}))
	_car.refit_upgrades(parked)
	assert_almost_eq(_car.config.tire_snow_grip_mult,
		float(always_stock["tire_snow_grip_mult"]), 0.0001,
		"a disabled tyre must not keep applying its surface bonus")

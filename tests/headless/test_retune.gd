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


func before_each() -> void:
	SceneHelpers.minimal_world()
	CarFixtures.install()
	UpgradeFixtures.install()
	_scene = load("res://main.tscn").instantiate()
	add_child_autofree(_scene)
	_car = _scene.get_node("Car")
	# Field a fixture car from an owned dict so retune has its pre-tune baseline snapshot.
	_car.apply_owned({"model_id": "fx_light_rwd", "instance_id": 1, "tuning": {}, "upgrades": {}})


func after_each() -> void:
	UpgradeFixtures.restore()
	CarFixtures.restore()
	Config.reset()


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
	assert_almost_eq(_car.config.peak_torque, _fresh_field(final_state).peak_torque, 0.01,
		"refit-then-retune lands on the same power as a fresh field (old tuning not baked in)")


# Sibling of the detune case for a grip axis (a tuning-only field the upgrade layer
# doesn't own): removing an upgrade then re-tuning grip must not compound.
func test_refit_then_retune_grip_matches_a_fresh_field() -> void:
	_car.apply_owned(_owned(["fx_turbo_big"], [], {"grip_balance": 0.6}))
	_car.refit_upgrades(_owned(["fx_turbo_big"], ["fx_turbo_big"], {"grip_balance": 0.6}))
	var final_state := _owned(["fx_turbo_big"], ["fx_turbo_big"], {"grip_balance": -0.3})
	_car.retune(final_state)
	var fresh := _fresh_field(final_state)
	assert_almost_eq(_car.config.wheel_friction_slip_front, fresh.wheel_friction_slip_front, 0.0001,
		"grip front matches a fresh field after refit+retune (no compounding)")
	assert_almost_eq(_car.config.wheel_friction_slip_rear, fresh.wheel_friction_slip_rear, 0.0001,
		"grip rear matches a fresh field after refit+retune (no compounding)")


# The downforce pair is the ONLY field both layers write (upgrade aero kit adds, tuning
# aero balance multiplies). Removing the turbo while keeping the aero kit, then re-tuning
# aero, must land on a fresh field — the shared field is the ordering-sensitive one.
func test_refit_then_retune_aero_downforce_matches_a_fresh_field() -> void:
	_car.apply_owned(_owned(["fx_turbo_big", "fx_aero"], [], {"aero_balance": 0.8}))
	_car.refit_upgrades(_owned(["fx_turbo_big", "fx_aero"], ["fx_turbo_big"], {"aero_balance": 0.8}))
	var final_state := _owned(["fx_turbo_big", "fx_aero"], ["fx_turbo_big"], {"aero_balance": -0.4})
	_car.retune(final_state)
	var fresh := _fresh_field(final_state)
	assert_almost_eq(_car.config.downforce_front, fresh.downforce_front, 0.0001,
		"downforce front (the shared field) matches a fresh field after refit+retune")
	assert_almost_eq(_car.config.downforce_rear, fresh.downforce_rear, 0.0001,
		"downforce rear (the shared field) matches a fresh field after refit+retune")


# The opposite order: tune first, then change an upgrade. Must also match a fresh field.
func test_retune_then_refit_matches_a_fresh_field() -> void:
	_car.apply_owned(_owned(["fx_turbo_big"], [], {"engine_detune": 1.0}))
	_car.retune(_owned(["fx_turbo_big"], [], {"engine_detune": 0.5}))
	var final_state := _owned(["fx_turbo_big"], ["fx_turbo_big"], {"engine_detune": 0.5})
	_car.refit_upgrades(final_state)
	assert_almost_eq(_car.config.peak_torque, _fresh_field(final_state).peak_torque, 0.01,
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
	var fresh := _fresh_field(final_state)
	assert_almost_eq(_car.config.peak_torque, fresh.peak_torque, 0.01,
		"peak_torque matches a fresh field after cycling the turbo (no drift)")
	assert_eq(_car.config.turbo_enabled, fresh.turbo_enabled,
		"turbo_enabled matches a fresh field after cycling (flag re-derived from baseline)")
	assert_almost_eq(_car.config.turbo_parasitic_friction, fresh.turbo_parasitic_friction, 0.0001,
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

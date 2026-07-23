class_name UpgradeFixtures
extends RefCounted
# A synthetic upgrade catalogue for tests, mirroring CarFixtures. Install it
# (install()) to run against a stable, test-owned upgrade roster that never tracks
# the shipped UPGRADES, so adding / renaming / retuning a real part can't break a
# logic test. Always restore() in teardown.
#
# The fixture parts cover every EFFECT shape the apply / effective_meta pipeline
# reads: install_turbo, mass_mult (both a reduction < 1 and a `free` ballast > 1),
# unlocks_aero_tuning + downforce, brake_torque_mult + unlocks_brake_bias, and
# unlocks_drivetrain_swap. It also re-exports the two STRUCTURAL consumables by
# their real constant ids (UpgradeLibrary.REPAIR_KIT_ID / ENGINE_SWAP_TOKEN_ID) —
# these are referenced by constant across the save / reward code (like the engine
# FIRING layout keys the car fixtures reuse), so keeping them present means an
# override doesn't strand those lookups.

static func upgrades() -> Array[Dictionary]:
	var list: Array[Dictionary] = [
		# A turbo-slot PAIR (same slot, distinct menu_label) so exclusivity /
		# Big-vs-Small selector UI has two mutually-exclusive parts to toggle.
		{
			"id": "fx_turbo_small", "name": "Fixture Small Turbo", "menu_label": "Small",
			"slot": "turbo", "tier": 1, "consumable": false,
			"effect": {"install_turbo": {
				"turbo_boost_gain": 0.35, "turbo_inertia": 6.0e-3, "turbo_omega_ref": 10000.0,
				"turbo_drive_gain": 0.03, "turbo_drag_coef": 1.0e-6, "turbo_parasitic_friction": 5.0,
				"engine_turbo_whistle_gain": 0.015, "engine_turbo_bov_gain": 0.005,
			}},
		},
		{
			"id": "fx_turbo_big", "name": "Fixture Big Turbo", "menu_label": "Big",
			"slot": "turbo", "tier": 2, "consumable": false,
			"effect": {"install_turbo": {
				"turbo_boost_gain": 0.8, "turbo_inertia": 2.0e-2, "turbo_omega_ref": 14000.0,
				"turbo_drive_gain": 0.028, "turbo_drag_coef": 6.5e-7, "turbo_parasitic_friction": 18.0,
				"engine_turbo_whistle_gain": 0.025, "engine_turbo_bov_gain": 0.008,
			}},
		},
		{
			"id": "fx_aero", "name": "Fixture Aero", "slot": "aero", "tier": 1,
			"consumable": false,
			"effect": {"unlocks_aero_tuning": true, "downforce_front": 3, "downforce_rear": 3},
		},
		{
			"id": "fx_lightweight", "name": "Fixture Lightweight", "slot": "weight",
			"tier": 1, "consumable": false, "effect": {"mass_mult": 0.80},
		},
		{
			"id": "fx_ballast", "name": "Fixture Ballast", "slot": "weight",
			"tier": 1, "consumable": false, "free": true, "effect": {"mass_mult": 1.3},
		},
		{
			"id": "fx_brakes", "name": "Fixture Brakes", "slot": "brakes", "tier": 1,
			"consumable": false,
			"effect": {"brake_torque_mult": 1.20, "unlocks_brake_bias": true},
		},
		{
			"id": "fx_drivetrain", "name": "Fixture Drivetrain", "slot": "drivetrain",
			"tier": 2, "consumable": false, "effect": {"unlocks_drivetrain_swap": true},
		},
		{
			"id": UpgradeLibrary.REPAIR_KIT_ID, "name": "Repair Kit", "slot": "",
			"tier": 1, "consumable": true, "effect": {},
		},
		{
			"id": UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, "name": "Engine Swap Token", "slot": "",
			"tier": 1, "consumable": true, "effect": {},
		},
	]
	return _deep_copy(list)


static func install() -> void:
	UpgradeLibrary.override_for_test(upgrades())


static func restore() -> void:
	UpgradeLibrary.reset()


static func _deep_copy(list: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in list:
		out.append(d.duplicate(true))
	return out

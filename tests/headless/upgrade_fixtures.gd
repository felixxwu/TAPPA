class_name UpgradeFixtures
extends RefCounted
# A synthetic upgrade catalogue for tests, mirroring CarFixtures. Install it
# (install()) to run against a stable, test-owned upgrade roster that never tracks
# the shipped UPGRADES, so adding / renaming / retuning a real part can't break a
# logic test. Always restore() in teardown.
#
# The fixture parts cover every EFFECT shape the apply / effective_meta / grip_meta pipeline
# reads: install_turbo, install_supercharger, mass_mult (both a reduction < 1 and a `free` ballast > 1),
# unlocks_aero_tuning + downforce, shift_time_mult, tire_grip_mult (the one row whose meta
# field and live-config fields differ — see UpgradeLibrary._cfg_fields), and
# unlocks_drivetrain_swap. It also re-exports the two STRUCTURAL consumables by
# their real constant ids (UpgradeLibrary.ENGINE_SWAP_TOKEN_ID / MYSTERY_BOX_ID) —
# these are referenced by constant across the save / reward code (like the engine
# FIRING layout keys the car fixtures reuse), so keeping them present means an
# override doesn't strand those lookups.

static func upgrades() -> Array[Dictionary]:
	var list: Array[Dictionary] = [
		# A turbo-slot PAIR (same slot, distinct menu_label) so exclusivity /
		# Big-vs-Small selector UI has two mutually-exclusive parts to toggle.
		{
			"id": "fx_turbo_small", "name": "Fixture Small Turbo", "menu_label": "Small",
			"slot": "turbo", "consumable": false,
			"effect": {"install_turbo": {
				"turbo_boost_gain": 0.35, "turbo_inertia": 6.0e-3, "turbo_omega_ref": 10000.0,
				"turbo_drive_gain": 0.03, "turbo_drag_coef": 1.0e-6, "turbo_parasitic_friction": 5.0,
				"engine_turbo_whistle_gain": 0.015, "engine_turbo_bov_gain": 0.005,
			}},
		},
		{
			"id": "fx_turbo_big", "name": "Fixture Big Turbo", "menu_label": "Big",
			"slot": "turbo", "consumable": false,
			"effect": {"install_turbo": {
				"turbo_boost_gain": 0.8, "turbo_inertia": 2.0e-2, "turbo_omega_ref": 14000.0,
				"turbo_drive_gain": 0.028, "turbo_drag_coef": 6.5e-7, "turbo_parasitic_friction": 18.0,
				"engine_turbo_whistle_gain": 0.025, "engine_turbo_bov_gain": 0.008,
			}},
		},
		{
			# Third turbo-slot part, prerequisite-gated behind fx_turbo_big, covering the
			# install_supercharger effect shape (belt boost + rpm-scaled drag).
			"id": "fx_supercharger", "name": "Fixture Supercharger", "menu_label": "Supercharger",
			"slot": "turbo", "consumable": false,
			"requires_upgrade_id": "fx_turbo_big",
			"effect": {"install_supercharger": {
				"supercharger_boost_gain": 1.0, "supercharger_rpm_ref": 4200.0,
				"supercharger_parasitic_coef": 9.0,
				"engine_supercharger_whine_gain": 0.06,
			}},
		},
		{
			# Covers the plain single-field "mult" shape on a NON-power-to-weight config
			# field (shift_time), so a test can tell "apply wrote it" from "effective_meta
			# mirrored it" — mass_mult, the other mult row, feeds both.
			"id": "fx_gearbox", "name": "Fixture Sequential", "menu_label": "Sequential",
			"slot": "gearbox", "consumable": false,
			"effect": {"shift_time_mult": 0.3},
		},
		{
			"id": "fx_aero", "name": "Fixture Aero", "slot": "aero",
			"consumable": false,
			"effect": {"unlocks_aero_tuning": true, "downforce_front": 3, "downforce_rear": 3},
		},
		{
			# Covers the `cfg_fields` shape: ONE meta field (tire_compound) standing for TWO
			# live-config fields (the per-axle wheel_friction_slip_*), and the only
			# feeds_grip "mult" row — so grip_meta's multiply arm has something to walk.
			"id": "fx_tires", "name": "Fixture Race Tires", "menu_label": "Race",
			"slot": "tires", "consumable": false,
			"effect": {"tire_grip_mult": 1.15},
		},
		{
			"id": "fx_lightweight", "name": "Fixture Lightweight", "slot": "weight",
			"consumable": false, "effect": {"mass_mult": 0.80},
		},
		{
			"id": "fx_ballast", "name": "Fixture Ballast", "slot": "weight",
			"consumable": false, "free": true, "effect": {"mass_mult": 1.3},
		},
		{
			"id": "fx_drivetrain", "name": "Fixture Drivetrain", "slot": "drivetrain",
			"consumable": false, "effect": {"unlocks_drivetrain_swap": true},
		},
		{
			# STAR-GATED: absent from the reward pool until FX_GATE_RALLY is won. The fixture
			# roster needs one so a test can exercise a CLOSED gate without leaning on the
			# shipped catalogue (and without any prerequisite muddying which gate rejected it).
			# In the WEIGHT slot and strictly lighter than fx_lightweight, so it wins that slot
			# outright once unlocked. That makes it visible to power-to-weight, which is what
			# lets a test tell the aspirational ceiling (gates ignored) from the reachable one.
			"id": "fx_gated", "name": "Fixture Gated Part", "slot": "weight",
			"unlocked_by_rally": FX_GATE_RALLY, "consumable": false,
			"effect": {"mass_mult": 0.6},
		},
		{
			# In a HIDDEN slot (UpgradeLibrary.HIDDEN_SLOTS), so it must install ENABLED
			# whatever the caller asks — it has no garage row to be switched on from. Lets a
			# test exercise that rule without reaching into the shipped nitrous ladder.
			"id": "fx_hidden", "name": "Fixture Hidden Part", "slot": "nitrous",
			"consumable": false,
			"effect": {"install_nitrous": {"nitrous_boost_gain": 0.3, "nitrous_tank_seconds": 2.0}},
		},
		{
			"id": UpgradeLibrary.ENGINE_SWAP_TOKEN_ID, "name": "Engine Swap Token", "slot": "",
			"consumable": true, "effect": {},
		},
	]
	return _deep_copy(list)


# The rally id fx_gated is gated on. Deliberately not a real roster id: a test opens the gate
# by marking THIS id complete in its profile, so the fixture is self-contained.
const FX_GATE_RALLY := "fx_gate_rally"


static func install() -> void:
	UpgradeLibrary.override_for_test(upgrades())


static func restore() -> void:
	UpgradeLibrary.reset()


static func _deep_copy(list: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for d in list:
		out.append(d.duplicate(true))
	return out

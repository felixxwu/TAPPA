class_name TuningLibrary
extends RefCounted
# Per-car TUNING — free, reversible handling nudges the player makes at the
# garage tuning lift (features/tuning.md). This is step 3 of the field-the-car
# pipeline (see car.gd.apply_owned):
#   1. CarLibrary baseline   apply_car(index)          -> Config.data
#   2. Installed upgrades    UpgradeLibrary.apply()      (changes the baseline)
#   3. Per-car tuning        TuningLibrary.apply()       (THIS — re-balances it)
#   4. Damage multipliers    power/steer degraded by HP
#
# Distinguish from UPGRADES (upgrade_library.gd): upgrades are consumable items
# that change the baseline; tuning is free, instant, reversible per-car deltas
# stored on the OwnedCar (Save.set_tuning) and never written back to the .tres.
#
# Each axis is a single normalized slider in [-1, +1], default 0 (the baseline,
# neutral). apply() reads owned_car.tuning and re-balances the LIVE cfg
# (Config.data) in place, scaled by the GameConfig authority knobs so a slider
# can never zero or invert a value. Pure static; mutates only the passed-in cfg.

# The three handling axes the tuning lift exposes. grip is always available;
# brake_bias / aero are gated by the brakes / aero upgrades (UpgradeLibrary),
# matching the lift UI. engine_detune is NOT here — it's a power (p/w) knob, so
# its slider lives in the upgrades menu (UpgradesMenu); apply() still reads the
# stored tuning.engine_detune below, wherever it was set from.
const AXES := ["grip_balance", "brake_bias", "aero_balance"]


# Re-balance `cfg` from `owned_car.tuning`. Runs AFTER UpgradeLibrary.apply, so it
# balances whatever baseline the upgrades produced; the values currently in cfg are
# the per-axis baseline it shifts about.
static func apply(owned_car: Dictionary, cfg: GameConfig) -> void:
	var tuning: Dictionary = owned_car.get("tuning", {})

	# grip_balance: −1 understeer ↔ +1 oversteer. Oversteer means the rear breaks
	# away first, so +1 shifts grip FORWARD (more front, less rear); −1 is the
	# mirror (more rear, less front → the car pushes wide). Shifts the front/rear
	# grip pair about its baseline; always available.
	var g := clampf(float(tuning.get("grip_balance", 0.0)), -1.0, 1.0)
	var gspan := cfg.tuning_grip_authority
	cfg.wheel_friction_slip_front *= (1.0 + g * gspan)
	cfg.wheel_friction_slip_rear *= (1.0 - g * gspan)

	# brake_bias: −1 rearward ↔ +1 forward. Maps to the front/rear foot-brake split
	# (cfg.brake_bias, applied in drivetrain.gd). Like grip/aero above, it shifts the
	# value already in cfg — the car's per-car default brake bias, seeded by
	# CarLibrary.apply_car. The brakes kit lets the slider move it
	# ±tuning_brake_authority about that baseline; without the kit the car simply keeps
	# its default — so a previously-tuned car re-fielded without the kit can't keep an
	# unlocked bias.
	if UpgradeLibrary.brake_bias_unlocked(owned_car):
		var b := clampf(float(tuning.get("brake_bias", 0.0)), -1.0, 1.0)
		cfg.brake_bias += b * cfg.tuning_brake_authority

	# aero_balance: −1 front ↔ +1 rear downforce. Same shape as grip on the
	# downforce pair. Gated by the aero upgrade; a no-op without it.
	if UpgradeLibrary.aero_tuning_unlocked(owned_car):
		var a := clampf(float(tuning.get("aero_balance", 0.0)), -1.0, 1.0)
		var aspan := cfg.tuning_aero_authority
		cfg.downforce_front *= (1.0 - a * aspan)
		cfg.downforce_rear *= (1.0 + a * aspan)

	# engine_detune: a 0..1 direct torque scale (features/engine-swap.md). Applied
	# LAST so it scales whatever torque the swapped engine + upgrade kits produced.
	# Default 1.0 (full power); always available (no upgrade gate).
	cfg.peak_torque *= clampf(float(tuning.get("engine_detune", 1.0)), 0.0, 1.0)


# Whether an axis is tunable for this car: grip always, brake_bias / aero only with
# the matching upgrade installed. Used by the lift UI to enable/disable each slider.
static func axis_unlocked(owned_car: Dictionary, axis: String) -> bool:
	match axis:
		"brake_bias":
			return UpgradeLibrary.brake_bias_unlocked(owned_car)
		"aero_balance":
			return UpgradeLibrary.aero_tuning_unlocked(owned_car)
		_:
			return true

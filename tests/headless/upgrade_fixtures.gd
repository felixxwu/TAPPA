class_name UpgradeFixtures
extends RefCounted
# Synthetic BOOST entries for tests, mirroring CarFixtures' role for cars.
#
# This used to be a synthetic upgrade CATALOGUE, installed over UpgradeLibrary.UPGRADES
# through the Registry seam. There is no catalogue any more: the persistent parts model is
# deleted (todo/roguelike-pivot.md -> "What gets deleted") and what survives is the effects
# FUNNEL — UpgradeLibrary.EFFECTS / _cfg_set / apply / effective_meta / grip_meta, driven by
# `active_effects`, which reads a car's `boosts` list.
#
# So there is nothing to install and nothing to restore: a test that wants an effect in
# force puts one of these entries on the owned-car dict it hands to the code under test.
#   var owned := {"model_id": "...", "boosts": UpgradeFixtures.boosts(["fx_turbo_big"])}
#
# The entries cover every EFFECT SHAPE the funnel reads, which is the whole point of owning
# them here rather than borrowing whatever the game currently ships: install_turbo,
# install_supercharger, install_nitrous (write_fields), mass_mult (both a reduction < 1 and
# an increase > 1), downforce_* (the "add" op, feeds_grip), shift_time_set (the "set" op —
# an absolute value, not a scaling), tire_grip_mult (the one row whose meta field and live-
# config fields differ — see UpgradeLibrary._cfg_fields) and tire_snow_grip_mult /
# tire_tarmac_grip_mult (the surface-dependent compound, whose meta and config names agree).

# id -> the authored `effect` dict, exactly as UpgradeLibrary.EFFECTS keys it.
const EFFECTS := {
	# A turbo PAIR: same shape, two magnitudes, so a test can tell one from the other.
	"fx_turbo_small": {"install_turbo": {
		"turbo_boost_gain": 0.35, "turbo_inertia": 6.0e-3, "turbo_omega_ref": 10000.0,
		"turbo_drive_gain": 0.03, "turbo_drag_coef": 1.0e-6, "turbo_parasitic_friction": 5.0,
		"engine_turbo_whistle_gain": 0.015, "engine_turbo_bov_gain": 0.005,
	}},
	"fx_turbo_big": {"install_turbo": {
		"turbo_boost_gain": 0.8, "turbo_inertia": 2.0e-2, "turbo_omega_ref": 14000.0,
		"turbo_drive_gain": 0.028, "turbo_drag_coef": 6.5e-7, "turbo_parasitic_friction": 18.0,
		"engine_turbo_whistle_gain": 0.025, "engine_turbo_bov_gain": 0.008,
	}},
	# The OTHER induction shape (belt boost + rpm-scaled drag). apply() must clear whichever
	# of the two it is not, which is the behaviour this pair exists to exercise.
	"fx_supercharger": {"install_supercharger": {
		"supercharger_boost_gain": 1.0, "supercharger_rpm_ref": 4200.0,
		"supercharger_parasitic_coef": 9.0,
		"engine_supercharger_whine_gain": 0.06,
	}},
	# The "set" shape — an ABSOLUTE config value replacing the baseline rather than scaling
	# it — on a field that feeds neither power-to-weight nor grip, so a test can tell
	# "apply wrote it" from "effective_meta / grip_meta mirrored it".
	"fx_gearbox": {"shift_time_set": 0.1},
	# The "add" shape, feeds_grip: downforce at both axles.
	"fx_aero": {"downforce_front": 3, "downforce_rear": 3},
	# The `cfg_fields` shape: ONE meta field (tire_compound) standing for TWO live-config
	# fields (the per-axle wheel_friction_slip_*), and the only feeds_grip "mult" row — so
	# grip_meta's multiply arm has something to walk.
	"fx_tires": {"tire_grip_mult": 1.15},
	# The SURFACE-DEPENDENT tyre shape, whose meta and config field names coincide.
	# Deliberately trades in BOTH directions (a bonus above 1 and a penalty below it) — the
	# trade is the point of the shape, and a one-way fixture would let a sign error through.
	"fx_snow_tires": {
		"tire_grip_mult": 1.08,
		"tire_snow_grip_mult": 1.2,
		"tire_tarmac_grip_mult": 0.8,
	},
	# mass_mult in both directions: feeds_pw, so effective_meta must mirror it.
	"fx_lightweight": {"mass_mult": 0.80},
	"fx_ballast": {"mass_mult": 1.3},
	# The "write_fields" shape: a straight splat with no enable flag.
	"fx_nitrous": {"install_nitrous": {"nitrous_boost_gain": 0.3, "nitrous_tank_seconds": 2.0}},
}


# One boost entry, in the shape UpgradeLibrary.active_effects yields:
# {"id": String, "effect": Dictionary}. Deep-copied, so a test that mutates what it gets
# back cannot poison the next one. {} for an unknown id — deliberately not an error, so a
# test can exercise the funnel's own unknown-input handling.
static func boost(id: String) -> Dictionary:
	if not EFFECTS.has(id):
		return {}
	return {"id": id, "effect": (EFFECTS[id] as Dictionary).duplicate(true)}


# The boost entries for `ids`, ready to drop on an owned-car dict as its `boosts` key.
static func boosts(ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		var b := boost(String(id))
		if not b.is_empty():
			out.append(b)
	return out

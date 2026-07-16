extends GutTest
# Behaviour of UpgradeLibrary.snapshot/restore — the linchpin of car.refit_upgrades.
# Pure (no scene): snapshot before apply, restore after, must undo apply exactly;
# and restore-then-reapply must equal a single apply (apply multiplies, so a naive
# re-apply on a live cfg would compound). Synthetic upgrade + config only — no
# catalogue entries, no tunable values pinned.

const T_MASS := {
	"id": "t_mass", "name": "Synthetic Weight Kit", "slot": "chassis",
	"tier": 1, "consumable": false, "effect": {"mass_mult": 0.5},
}


func after_each() -> void:
	UpgradeLibrary.reset()


func _cfg(mass: float) -> GameConfig:
	var cfg := GameConfig.new()
	cfg.mass = mass
	return cfg


func test_restore_undoes_apply() -> void:
	UpgradeLibrary.override_for_test([T_MASS] as Array[Dictionary])
	var owned := {"installed_upgrades": ["t_mass"], "disabled_upgrades": []}
	var cfg := _cfg(1000.0)
	var snap := UpgradeLibrary.snapshot(cfg)
	UpgradeLibrary.apply(owned, cfg)
	assert_ne(cfg.mass, 1000.0, "apply changed mass (sanity)")
	UpgradeLibrary.restore(cfg, snap)
	assert_almost_eq(cfg.mass, 1000.0, 0.001, "restore returns mass to baseline")


func test_restore_then_reapply_does_not_compound() -> void:
	UpgradeLibrary.override_for_test([T_MASS] as Array[Dictionary])
	var owned := {"installed_upgrades": ["t_mass"], "disabled_upgrades": []}

	# Single apply from a clean baseline.
	var once := _cfg(1000.0)
	UpgradeLibrary.apply(owned, once)

	# Snapshot before the first apply, then restore-then-reapply (the refit path).
	var live := _cfg(1000.0)
	var snap := UpgradeLibrary.snapshot(live)
	UpgradeLibrary.apply(owned, live)
	UpgradeLibrary.restore(live, snap)
	UpgradeLibrary.apply(owned, live)

	assert_almost_eq(live.mass, once.mass, 0.001,
		"restore+reapply equals a single apply — no compounding")

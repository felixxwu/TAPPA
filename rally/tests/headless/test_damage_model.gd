extends GutTest
# DamageModel: the per-car HP / attrition logic (todo/damage-model.md). These
# exercise the maths and wreck semantics directly against a DamageModel (no
# physics body needed). The bound-wreck and persistence tests use a throwaway
# Save profile so a real profile is never touched, mirroring test_save_manager.gd.

const TEST_PATH := "user://test_damage_profile.json"

var _save: Node


func before_each() -> void:
	Config.reset()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()


func after_each() -> void:
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# --- Impulse -> HP -----------------------------------------------------------

func test_impulse_below_threshold_costs_nothing() -> void:
	var cfg: GameConfig = Config.data
	assert_eq(DamageModel.hp_loss_for_impulse(0.0, cfg), 0.0, "no contact, no loss")
	assert_eq(DamageModel.hp_loss_for_impulse(cfg.impact_min_impulse, cfg), 0.0,
		"a hit exactly at the threshold still costs nothing")
	assert_eq(DamageModel.hp_loss_for_impulse(cfg.impact_min_impulse - 1.0, cfg), 0.0,
		"a gentle scrape below the threshold costs nothing")


func test_impulse_above_threshold_is_linear() -> void:
	var cfg: GameConfig = Config.data
	var impulse := cfg.impact_min_impulse + 100.0
	var expected := 100.0 * cfg.hp_per_impulse
	assert_almost_eq(DamageModel.hp_loss_for_impulse(impulse, cfg), expected, 1e-5,
		"HP loss is (impulse - threshold) * hp_per_impulse")


func test_register_impact_reduces_hp_and_emits_damaged() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, false)
	var got := {"loss": -1.0, "point": Vector3.ZERO, "count": 0}
	dm.damaged.connect(func(loss: float, point: Vector3) -> void:
		got["loss"] = loss
		got["point"] = point
		got["count"] += 1)
	var impulse := cfg.impact_min_impulse + 200.0
	var expected := 200.0 * cfg.hp_per_impulse
	var hit_loss := dm.register_impact(impulse, Vector3(1, 2, 3), cfg)
	assert_almost_eq(hit_loss, expected, 1e-5, "register_impact returns the HP lost")
	assert_almost_eq(dm.hp, 1000.0 - expected, 1e-5, "HP drained by the loss")
	assert_almost_eq(got["loss"], expected, 1e-5, "damaged carries the loss")
	assert_eq(got["point"], Vector3(1, 2, 3), "damaged carries the contact point")
	# A sub-threshold hit costs nothing and does NOT emit.
	got["count"] = 0
	assert_eq(dm.register_impact(1.0, Vector3.ZERO, cfg), 0.0, "scrape costs nothing")
	assert_eq(got["count"], 0, "no damaged signal for a no-cost hit")


# --- Effects scale with damage fraction --------------------------------------

func test_effects_zero_at_full_hp() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, false)
	dm.align_bias_sign = 1.0
	assert_almost_eq(dm.damage_fraction(), 0.0, 1e-6, "d = 0 at full HP")
	assert_almost_eq(dm.power_multiplier(cfg), 1.0, 1e-6, "full power at full HP")
	assert_almost_eq(dm.steer_bias(cfg), 0.0, 1e-6, "no steer pull at full HP")


func test_effects_max_at_zero_hp() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, false)
	dm.align_bias_sign = 1.0
	dm.hp = 0.0
	assert_almost_eq(dm.damage_fraction(), 1.0, 1e-6, "d = 1 at 0 HP")
	assert_almost_eq(dm.power_multiplier(cfg), 1.0 - cfg.damage_power_loss_max, 1e-6,
		"power loss caps at damage_power_loss_max")
	assert_almost_eq(dm.steer_bias(cfg), cfg.damage_steer_bias_max, 1e-6,
		"steer pull caps at damage_steer_bias_max in the rolled direction")


func test_effects_monotonic_between() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, false)
	dm.align_bias_sign = 1.0
	dm.hp = 500.0
	assert_almost_eq(dm.damage_fraction(), 0.5, 1e-6, "half HP -> d = 0.5")
	assert_almost_eq(dm.power_multiplier(cfg), 1.0 - 0.5 * cfg.damage_power_loss_max, 1e-6,
		"power loss is half of max at half damage")
	assert_almost_eq(dm.steer_bias(cfg), 0.5 * cfg.damage_steer_bias_max, 1e-6,
		"steer pull is half of max at half damage")


func test_steer_bias_follows_rolled_sign() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 0.0, false)
	dm.align_bias_sign = -1.0
	assert_almost_eq(dm.steer_bias(cfg), -cfg.damage_steer_bias_max, 1e-6,
		"a -1 roll pulls the other way")


# --- Wreck at 0 HP -----------------------------------------------------------

func test_unbound_wreck_emits_without_touching_save() -> void:
	var dm := DamageModel.new()
	dm.field(800.0, 30.0, false, -1)  # unbound: free-roam / dev
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	dm.apply_loss(100.0)
	assert_eq(wrecks["n"], 1, "wrecked emitted once at 0 HP")
	assert_eq(dm.hp, 0.0, "HP floored at 0")
	assert_eq(_save.profile["cars"].size(), 0, "an unbound model never touches the save")


func test_bound_wreck_removes_instance_and_returns_upgrades() -> void:
	var car: Dictionary = _save.grant_car("mx5", false)
	var id := int(car["instance_id"])
	_save.add_item("engine_stage1", 1)
	assert_true(_save.install_upgrade(id, "engine_stage1"), "upgrade fitted")
	assert_eq(_save.get_car(id)["installed_upgrades"].size(), 1, "one upgrade installed")
	assert_eq(int(_save.profile["inventory"].get("engine_stage1", 0)), 0, "item left inventory on install")

	var dm := DamageModel.new()
	dm.field(800.0, 40.0, false, id)
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	dm.apply_loss(40.0)  # -> 0 HP

	assert_eq(wrecks["n"], 1, "wrecked emitted")
	assert_true(_save.get_car(id).is_empty(), "the instance is removed from the save")
	assert_eq(int(_save.profile["inventory"].get("engine_stage1", 0)), 1,
		"the fitted upgrade is returned to inventory before removal")


func test_immortal_takes_no_damage_and_never_wrecks() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(800.0, 800.0, true)
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	assert_eq(dm.register_impact(100000.0, Vector3.ZERO, cfg), 0.0, "immortal ignores impacts")
	assert_eq(dm.hp, 800.0, "immortal HP unchanged by impacts")
	dm.apply_loss(100000.0)
	assert_gt(dm.hp, 0.0, "immortal HP floors above 0")
	assert_eq(wrecks["n"], 0, "immortal is never wrecked")
	assert_almost_eq(dm.damage_fraction(), 0.0, 1e-6, "immortal shows no damage effects")


# --- Persistence handoff -----------------------------------------------------

func test_event_boundary_writeback_round_trips() -> void:
	var car: Dictionary = _save.grant_car("rs3", false)
	var id := int(car["instance_id"])
	var max_hp := float(_save.get_car(id)["hp"])  # granted at full HP
	# Working HP depleted over a run is written back at the event boundary.
	_save.apply_damage(id, 250.0)
	_save.save_now()
	_save.load_or_new()
	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp - 250.0, 1e-6,
		"depleted HP persists and reloads unchanged")

extends GutTest
# DamageModel: the per-car HP / attrition logic (features/damage.md). These
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


# --- Speed -> HP -------------------------------------------------------------

# Helper: an impact speed (m/s) for a given km/h, matching the config's units.
func _mps(kmh: float) -> float:
	return kmh / DamageModel.MPS_TO_KMH


func test_low_speed_below_threshold_costs_nothing() -> void:
	var cfg: GameConfig = Config.data
	assert_eq(DamageModel.hp_loss_for_speed(0.0, cfg), 0.0, "stationary, no loss")
	assert_eq(DamageModel.hp_loss_for_speed(_mps(cfg.impact_min_speed_kmh), cfg), 0.0,
		"a hit exactly at the threshold speed still costs nothing")
	assert_eq(DamageModel.hp_loss_for_speed(_mps(cfg.impact_min_speed_kmh - 1.0), cfg), 0.0,
		"a crawl below the threshold speed costs nothing")


func test_hp_loss_grows_with_square_of_speed() -> void:
	var cfg: GameConfig = Config.data
	# At the reference speed a hit costs exactly the reference HP loss.
	assert_almost_eq(DamageModel.hp_loss_for_speed(_mps(cfg.impact_ref_speed_kmh), cfg),
		cfg.impact_ref_hp_loss, 1e-3, "a reference-speed hit costs impact_ref_hp_loss")
	# Square law: halving the speed cuts the loss to well under half (so a slow hit
	# is disproportionately gentle), and the loss rises monotonically with speed.
	var slow := DamageModel.hp_loss_for_speed(_mps(cfg.impact_ref_speed_kmh * 0.5), cfg)
	var fast := DamageModel.hp_loss_for_speed(_mps(cfg.impact_ref_speed_kmh), cfg)
	assert_lt(slow, fast * 0.4, "half the speed costs much less than half the HP (energy law)")
	assert_gt(fast, slow, "faster hits always cost more")


# The behaviour the design calls for: a ~60 km/h hit lets most cars (max HP
# 800-1100) survive 4-5 hits, while a ~20 km/h hit barely scratches them.
func test_speed_damage_calibration() -> void:
	var cfg: GameConfig = Config.data
	var loss_60 := DamageModel.hp_loss_for_speed(_mps(60.0), cfg)
	assert_between(int(ceil(800.0 / loss_60)), 4, 5,
		"a ~800 HP car survives 4-5 hits at 60 km/h")
	assert_between(int(ceil(1000.0 / loss_60)), 4, 5,
		"a ~1000 HP car survives 4-5 hits at 60 km/h")
	var loss_20 := DamageModel.hp_loss_for_speed(_mps(20.0), cfg)
	assert_lt(loss_20 / 800.0, 0.05,
		"a 20 km/h hit costs under 5% of the smallest car's HP (barely any damage)")


func test_register_impact_reduces_hp_and_emits_damaged() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, false)
	var got := {"loss": -1.0, "point": Vector3.ZERO, "count": 0}
	dm.damaged.connect(func(loss: float, point: Vector3) -> void:
		got["loss"] = loss
		got["point"] = point
		got["count"] += 1)
	var speed := _mps(cfg.impact_ref_speed_kmh)
	var expected := cfg.impact_ref_hp_loss  # below the per-hit cap for a 1000 HP car
	var hit_loss := dm.register_impact(speed, Vector3(1, 2, 3), cfg)
	assert_almost_eq(hit_loss, expected, 1e-3, "register_impact returns the HP lost")
	assert_almost_eq(dm.hp, 1000.0 - expected, 1e-3, "HP drained by the loss")
	assert_almost_eq(got["loss"], expected, 1e-3, "damaged carries the loss")
	assert_eq(got["point"], Vector3(1, 2, 3), "damaged carries the contact point")
	# A below-threshold hit costs nothing and does NOT emit. (The earlier hit started
	# a cooldown, but a crawl would cost nothing regardless.)
	got["count"] = 0
	assert_eq(dm.register_impact(_mps(1.0), Vector3.ZERO, cfg), 0.0, "low-speed nudge costs nothing")
	assert_eq(got["count"], 0, "no damaged signal for a no-cost hit")


func test_single_impact_is_capped_and_cannot_wreck() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, false)
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	# A colossal single impact (huge speed) is capped to a fraction of max HP, so it can't wreck.
	var loss := dm.register_impact(_mps(1.0e6), Vector3.ZERO, cfg)
	assert_almost_eq(loss, 1000.0 * cfg.impact_max_loss_frac, 1e-3,
		"a single impact is capped to impact_max_loss_frac of max HP")
	assert_gt(dm.hp, 0.0, "one crash cannot wreck the car")
	assert_eq(wrecks["n"], 0, "no wreck from a single hit")


func test_cooldown_groups_a_crash_and_it_takes_several_hits_to_wreck() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, false)
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	var big := _mps(1.0e6)  # huge speed -> capped per-hit loss
	dm.register_impact(big, Vector3.ZERO, cfg)
	var after_one := dm.hp
	# A second impact during the cooldown (same crash, next tick) is ignored.
	dm.register_impact(big, Vector3.ZERO, cfg)
	assert_almost_eq(dm.hp, after_one, 1e-5, "impacts during the cooldown count as one hit")
	# Separated big hits eventually wreck it — but it takes several.
	var hits := 1
	while dm.hp > 0.0 and hits < 10:
		dm.tick_cooldown(cfg.impact_cooldown_s)  # let the cooldown expire
		dm.register_impact(big, Vector3.ZERO, cfg)
		hits += 1
	assert_between(hits, 2, 4, "a car survives ~2-3 big hits before wrecking")
	assert_eq(wrecks["n"], 1, "wrecked exactly once, on the final hit")


func test_sustained_contact_stays_one_hit() -> void:
	# Staying jammed against an obstacle reports a contact EVERY physics tick. The
	# cooldown re-arms on each continuing contact, so a multi-second grind/pin counts
	# as ONE hit, not a fresh hit every impact_cooldown_s. Mirrors car.gd's per-tick
	# tick_cooldown(delta) + register_impact() loop while in contact.
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, false)
	var big := _mps(1.0e6)
	dm.register_impact(big, Vector3.ZERO, cfg)
	var after_one := dm.hp
	var dt := 1.0 / 60.0
	# ~3 s of continuous contact — well past the 0.7 s window, so the old fixed
	# cooldown would have expired and re-chipped several times.
	for _i in int(3.0 / dt):
		dm.tick_cooldown(dt)
		dm.register_impact(big, Vector3.ZERO, cfg)
	assert_almost_eq(dm.hp, after_one, 1e-5,
		"a multi-second sustained crash still costs only one hit")


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


func test_bound_wreck_zeroes_hp_keeping_car_and_upgrades() -> void:
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
	# The bound car is left at 0 HP in the save (repairable), not destroyed.
	assert_false(_save.get_car(id).is_empty(), "the wrecked instance is kept in the save")
	assert_eq(float(_save.get_car(id)["hp"]), 0.0, "the saved car sits at 0 HP")
	assert_true(_save.get_car(id)["installed_upgrades"].has("engine_stage1"),
		"the fitted upgrade stays on the wrecked car")
	assert_eq(int(_save.profile["inventory"].get("engine_stage1", 0)), 0,
		"the upgrade is not returned to inventory (it rides along with the car)")


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

extends GutTest
# DamageModel: the per-car HP / attrition logic (features/damage.md). These
# exercise the maths and 0-HP semantics directly against a DamageModel (no
# physics body needed). Damage NEVER takes the car out: 0 HP is a state, not an
# event — nothing is signalled and the car keeps driving under a maxed misfire and
# the lowest rev cap. The persistence tests use a throwaway Save profile so a real
# profile is never touched, mirroring test_save_manager.gd.

const TEST_PATH := "user://test_damage_profile.json"

var _save: Node


func before_each() -> void:
	Config.reset()
	CarFixtures.install()
	UpgradeFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()


func after_each() -> void:
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	UpgradeFixtures.restore()
	CarFixtures.restore()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# --- Speed -> HP -------------------------------------------------------------

# Helper: an impact speed (m/s) for a given km/h, matching the config's units.
func _mps(kmh: float) -> float:
	return kmh / DamageModel.MPS_TO_KMH


func test_hp_loss_is_zero_at_rest_and_positive_above() -> void:
	# hp_loss_for_speed is a pure v² curve from zero (no low-speed floor — the
	# braking-proof gate lives in register_deceleration, tested separately).
	var cfg: GameConfig = Config.data
	assert_eq(DamageModel.hp_loss_for_speed(0.0, cfg), 0.0, "no shed velocity, no loss")
	assert_gt(DamageModel.hp_loss_for_speed(_mps(5.0), cfg), 0.0, "any real shed velocity costs some HP")


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


# --- Unified deceleration damage ---------------------------------------------

const DT := 1.0 / 60.0


# The shed-velocity (m/s) whose per-tick deceleration is `g` gravities.
func _dv_at_g(g: float) -> float:
	return g * DamageModel.GRAVITY_MPS2 * DT


func test_below_threshold_g_costs_nothing() -> void:
	# Hard braking (~1 g) is a real deceleration but stays under the ~2 g threshold, so
	# it never chips HP — the whole point of keying damage to sudden deceleration.
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	assert_eq(dm.register_deceleration(_dv_at_g(1.0), DT, Vector3.ZERO, cfg), 0.0,
		"a braking-magnitude deceleration costs nothing")
	assert_almost_eq(dm.hp, 1000.0, 1e-6, "HP unchanged below threshold")


func test_above_threshold_costs_hp_and_emits() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	var got := {"loss": -1.0, "point": Vector3.ZERO, "count": 0}
	dm.damaged.connect(func(loss: float, point: Vector3) -> void:
		got["loss"] = loss
		got["point"] = point
		got["count"] += 1)
	# A full arrest at the reference speed sheds ref_speed of velocity in one tick.
	var dv := _mps(cfg.impact_ref_speed_kmh)
	var expected := cfg.impact_ref_hp_loss  # below the per-hit cap for a 1000 HP car
	var loss := dm.register_deceleration(dv, DT, Vector3(1, 2, 3), cfg)
	assert_almost_eq(loss, expected, 1e-3, "register_deceleration returns the HP lost")
	assert_almost_eq(dm.hp, 1000.0 - expected, 1e-3, "HP drained by the loss")
	assert_almost_eq(got["loss"], expected, 1e-3, "damaged carries the loss")
	assert_eq(got["point"], Vector3(1, 2, 3), "damaged carries the contact point")
	assert_eq(got["count"], 1, "damaged emitted once")


func test_full_arrest_matches_capped_square_law() -> void:
	# Continuity with the old speed-keyed model: a full solid arrest deals the same HP
	# as the (capped) square law for that shed velocity — so the existing tuning carries.
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	var dv := _mps(cfg.impact_ref_speed_kmh)
	var expected := minf(DamageModel.hp_loss_for_speed(dv, cfg), cfg.impact_max_loss)
	assert_almost_eq(dm.register_deceleration(dv, DT, Vector3.ZERO, cfg), expected, 1e-3,
		"deceleration damage == capped square law for the shed velocity")


func test_single_spike_is_capped_and_cannot_empty_the_hp_pool() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	# A colossal single spike is capped to a flat HP amount, so it can't strip the pool.
	var loss := dm.register_deceleration(1.0e6, DT, Vector3.ZERO, cfg)
	assert_almost_eq(loss, cfg.impact_max_loss, 1e-3,
		"a single spike is capped to the flat impact_max_loss amount")
	assert_gt(dm.hp, 0.0, "one crash cannot take the car to 0 HP")


func test_stopped_car_self_limits_without_a_cooldown() -> void:
	# No cooldown: once the car is stopped it sheds ~0 velocity/tick, so grinding against
	# a wall costs nothing more on its own — the physics self-limits without a timer.
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	dm.register_deceleration(1.0e6, DT, Vector3.ZERO, cfg)
	var after_one := dm.hp
	for _i in 200:
		dm.register_deceleration(0.0, DT, Vector3.ZERO, cfg)  # pinned/stopped: no Δv
	assert_almost_eq(dm.hp, after_one, 1e-6, "a stopped car takes no further damage")


func test_repeated_spikes_accumulate_down_to_zero() -> void:
	# A real multi-bounce tumble is several genuine Δv spikes; with no cooldown each
	# capped hit lands, so enough of them empty the pool (tall drops are dangerous).
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	var hits := 0
	while dm.hp > 0.0 and hits < 20:
		dm.register_deceleration(1.0e6, DT, Vector3.ZERO, cfg)
		hits += 1
	assert_lt(hits, 20, "repeated capped spikes eventually run the car out of HP")
	assert_eq(dm.hp, 0.0, "HP bottoms out at 0")
	# ...and further hits keep working on a 0 HP car without doing anything odd.
	dm.register_deceleration(1.0e6, DT, Vector3.ZERO, cfg)
	assert_eq(dm.hp, 0.0, "HP stays clamped at 0, never negative")


func test_soft_drag_deceleration_deals_small_damage() -> void:
	# A soft contact (bush/crowd) sheds a small slice of speed; that deceleration must
	# clear the threshold for a SMALL chip — not zero, not a full crash.
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	# ~0.9 m/s shed in a tick (a graze at speed) is well over the ~2 g floor.
	var loss := dm.register_deceleration(0.9, DT, Vector3.ZERO, cfg)
	assert_gt(loss, 0.0, "a soft graze's deceleration costs a little HP")
	assert_lt(loss, cfg.impact_ref_hp_loss * 0.25, "but far less than a real crash")


# --- Damage fraction (drives the engine misfire) -----------------------------

func test_damage_fraction_tracks_hp() -> void:
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	assert_almost_eq(dm.damage_fraction(), 0.0, 1e-6, "d = 0 at full HP")
	dm.hp = 500.0
	assert_almost_eq(dm.damage_fraction(), 0.5, 1e-6, "half HP -> d = 0.5")
	dm.hp = 0.0
	assert_almost_eq(dm.damage_fraction(), 1.0, 1e-6, "d = 1 at 0 HP")


# A config with an explicit, known damage ramp/cap, so no assertion below depends on
# the authored (tunable) values in game_config.tres — only on the relationships.
func _damage_cfg(threshold := 0.5, misfire_max := 0.8, rev_floor := 0.6) -> GameConfig:
	var cfg := GameConfig.new()
	cfg.damage_misfire_health_threshold = threshold
	cfg.damage_misfire_level_max = misfire_max
	cfg.damage_rev_limit_min_fraction = rev_floor
	return cfg


func test_damage_ramp_is_zero_above_the_threshold_and_one_at_zero_hp() -> void:
	# The single shared ramp behind both engine effects. Driven with an explicit
	# threshold so it pins the SHAPE, not the authored number.
	var cfg := _damage_cfg(0.5)
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	assert_eq(dm.damage_ramp(cfg), 0.0, "full health -> no ramp")
	dm.hp = 600.0  # health 0.6, above the threshold
	assert_eq(dm.damage_ramp(cfg), 0.0, "above the threshold nothing is weakened yet")
	dm.hp = 500.0  # exactly at the threshold: the edge of healthy
	assert_almost_eq(dm.damage_ramp(cfg), 0.0, 1e-6, "at the threshold the ramp just begins")
	dm.hp = 250.0  # halfway from threshold to empty
	assert_almost_eq(dm.damage_ramp(cfg), 0.5, 1e-6, "linear through the damaged band")
	dm.hp = 0.0
	assert_almost_eq(dm.damage_ramp(cfg), 1.0, 1e-6, "fully ramped at 0 HP")


func test_misfire_level_follows_the_ramp_but_never_reaches_one() -> void:
	# The "certain point" damage stops at: the misfire is the ramp SCALED by the cap, so
	# even a 0 HP engine still fires sometimes and the car still drives. The cap value is
	# tunable, so this asserts the RELATIONSHIP (worst misfire == the configured cap, and
	# that cap is below a total cut) rather than any particular number.
	var cfg := _damage_cfg(0.5, 0.8)
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	assert_eq(dm.misfire_level(cfg), 0.0, "full health -> no misfire")
	dm.hp = 0.0
	assert_almost_eq(dm.misfire_level(cfg), cfg.damage_misfire_level_max, 1e-6,
		"the worst misfire is exactly the configured cap")
	assert_lt(dm.misfire_level(cfg), 1.0, "and the cap is below a permanent cut, so the car still drives")
	# Mid-ramp it is the ramp times the cap — same shape, scaled.
	dm.hp = 250.0
	assert_almost_eq(dm.misfire_level(cfg), dm.damage_ramp(cfg) * cfg.damage_misfire_level_max, 1e-6,
		"misfire == ramp * cap all the way down")


func test_misfire_level_respects_any_configured_cap() -> void:
	# Retuning the cap must move the worst-case misfire with it (and never above it) —
	# the property that has to hold for ANY reasonable authored value.
	var dm := DamageModel.new()
	dm.field(1000.0, 0.0)
	for cap in [0.25, 0.5, 0.9]:
		var cfg := _damage_cfg(0.5, cap)
		assert_almost_eq(dm.misfire_level(cfg), cap, 1e-6,
			"a 0 HP car misfires at exactly the configured cap (%s)" % cap)
		assert_lt(dm.misfire_level(cfg), 1.0, "never a total cut")


func test_rev_limit_fraction_falls_monotonically_to_a_positive_floor() -> void:
	# Full revs while healthy, falling with the same ramp to the configured floor at 0 HP.
	# Never 0: a rev-capped car must still be able to rev, pull away and change gear.
	var cfg := _damage_cfg(0.5, 0.8, 0.6)
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	assert_almost_eq(dm.rev_limit_fraction(cfg), 1.0, 1e-6, "full health -> full revs")
	dm.hp = 600.0
	assert_almost_eq(dm.rev_limit_fraction(cfg), 1.0, 1e-6, "above the threshold, still full revs")
	var prev := dm.rev_limit_fraction(cfg)
	for hp in [500.0, 400.0, 300.0, 200.0, 100.0, 0.0]:
		dm.hp = hp
		var f := dm.rev_limit_fraction(cfg)
		assert_lte(f, prev + 1e-9, "the rev cap never rises as HP falls (at %s HP)" % hp)
		prev = f
	assert_almost_eq(dm.rev_limit_fraction(cfg), cfg.damage_rev_limit_min_fraction, 1e-6,
		"at 0 HP the cap is exactly the configured floor")
	assert_gt(dm.rev_limit_fraction(cfg), 0.0, "and the floor is strictly positive")


func test_rev_limit_fraction_respects_any_configured_floor() -> void:
	var dm := DamageModel.new()
	dm.field(1000.0, 0.0)
	for floor_frac in [0.2, 0.5, 0.9]:
		var cfg := _damage_cfg(0.5, 0.8, floor_frac)
		assert_almost_eq(dm.rev_limit_fraction(cfg), floor_frac, 1e-6,
			"a 0 HP car keeps exactly the configured fraction of its redline (%s)" % floor_frac)
		assert_gt(dm.rev_limit_fraction(cfg), 0.0, "always some usable rev range")


# --- Wheel-toe misalignment --------------------------------------------------

func test_field_loads_persisted_wheel_toe() -> void:
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, -1, [0.01, -0.02, 0.03, -0.04])
	# Loaded in WHEEL_NAMES order; round-trips back out unchanged.
	assert_eq(dm.toe_array(), [0.01, -0.02, 0.03, -0.04], "toe loaded and returned in order")


func test_field_missing_toe_fields_straight() -> void:
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, -1, [])  # older save with no wheel_toe
	assert_eq(dm.toe_array(), [0.0, 0.0, 0.0, 0.0], "an empty toe array fields straight wheels")


func test_nudge_bends_every_wheel_within_clamp() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	dm.nudge_wheels(cfg.impact_max_loss, cfg)  # a big hit
	var any_bent := false
	for a in dm.toe_array():
		assert_true(abs(a) <= cfg.damage_wheel_toe_max + 1e-6, "each wheel clamped to ±toe_max")
		if absf(a) > 1e-9:
			any_bent = true
	assert_true(any_bent, "a solid hit bends at least one wheel")


func test_nudge_zero_strength_is_noop() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	dm.nudge_wheels(0.0, cfg)
	assert_eq(dm.toe_array(), [0.0, 0.0, 0.0, 0.0], "a zero-loss hit bends nothing")


func test_nudge_always_clamped_over_many_hits() -> void:
	# Repeated hits can push a wheel back toward straight (random per-wheel sign) but
	# can never exceed the clamp — the invariant that keeps a crashed car drivable.
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	for i in 50:
		dm.nudge_wheels(cfg.impact_max_loss, cfg)
	for a in dm.toe_array():
		assert_true(abs(a) <= cfg.damage_wheel_toe_max + 1e-6, "toe never exceeds the clamp")


func test_reset_wheel_toe_straightens() -> void:
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0, -1, [0.05, -0.05, 0.05, -0.05])
	dm.reset_wheel_toe()
	assert_eq(dm.toe_array(), [0.0, 0.0, 0.0, 0.0], "a repair straightens every wheel")


func test_deceleration_bends_wheels() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	# A fast deceleration both costs HP and bends the wheels.
	var loss := dm.register_deceleration(30.0, DT, Vector3.ZERO, cfg)
	assert_gt(loss, 0.0, "the hit cost HP")
	var any_bent := false
	for a in dm.toe_array():
		if absf(a) > 1e-9:
			any_bent = true
	assert_true(any_bent, "the impact bent the wheels")


# --- 0 HP is a state, not an event ------------------------------------------

func test_apply_loss_past_zero_clamps_and_signals_nothing() -> void:
	# apply_loss just drains: HP floors at 0, nothing is emitted, the save is untouched.
	# (There is no wrecked signal any more — 0 HP is a state the car keeps driving in.)
	var dm := DamageModel.new()
	dm.field(800.0, 30.0, -1)  # unbound: free-roam / dev
	assert_false(dm.has_signal("wrecked"), "no wreck event exists on the damage model")
	var emitted := {"damaged": 0}
	dm.damaged.connect(func(_loss: float, _pt: Vector3) -> void: emitted["damaged"] += 1)
	dm.apply_loss(100.0)
	assert_eq(dm.hp, 0.0, "HP floored at 0, not negative")
	dm.apply_loss(500.0)
	assert_eq(dm.hp, 0.0, "further losses on an empty pool stay clamped at 0")
	assert_eq(emitted["damaged"], 0, "a bare apply_loss emits nothing")
	assert_eq(_save.profile["cars"].size(), 0, "an unbound model never touches the save")


func test_bound_model_at_zero_hp_keeps_the_car_and_its_upgrades() -> void:
	# Running a BOUND car's HP to 0 costs the run's pace, never the car: the instance,
	# and everything fitted to it, is still in the save afterwards, needing a repair.
	var car: Dictionary = _save.grant_car("fx_light_rwd")
	var id := int(car["instance_id"])
	assert_true(_save.install_upgrade(id, "fx_turbo_small"), "upgrade fitted")

	var dm := DamageModel.new()
	dm.field(800.0, 40.0, id)
	dm.apply_loss(40.0)  # -> 0 HP

	assert_eq(dm.hp, 0.0, "the model reads empty")
	assert_false(_save.get_car(id).is_empty(), "the instance is kept in the save")
	assert_true(_save.get_car(id)["installed_upgrades"].has("fx_turbo_small"),
		"the fitted upgrade stays on the car")


func test_a_zero_hp_car_is_maximally_weakened_but_still_drivable() -> void:
	# The contract that replaced the wreck: impacts cost HP, HP bottoms out at 0, and at
	# 0 HP the engine is at its worst — yet the misfire is still short of a total cut and
	# the rev cap is still above zero, so the car can be driven to the finish.
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(800.0, 800.0)
	assert_gt(dm.register_deceleration(100000.0, DT, Vector3.ZERO, cfg), 0.0, "a hard impact costs HP")
	assert_lt(dm.hp, 800.0, "HP falls after an impact")
	dm.apply_loss(100000.0)
	assert_eq(dm.hp, 0.0, "enough damage floors HP at 0")
	assert_almost_eq(dm.damage_fraction(), 1.0, 1e-6, "a 0 HP car reads full damage")
	assert_almost_eq(dm.damage_ramp(cfg), 1.0, 1e-6, "and is fully ramped")
	assert_almost_eq(dm.misfire_level(cfg), clampf(cfg.damage_misfire_level_max, 0.0, 1.0), 1e-6,
		"the worst misfire is the configured cap, whatever it is tuned to")
	assert_gt(dm.rev_limit_fraction(cfg), 0.0, "and some rev range always remains")


# --- Persistence handoff -----------------------------------------------------

func test_event_boundary_writeback_round_trips() -> void:
	var car: Dictionary = _save.grant_car("fx_rwd_coupe")
	var id := int(car["instance_id"])
	var max_hp := float(_save.get_car(id)["hp"])  # granted at full HP
	# Working HP depleted over a run is written back at the event boundary.
	_save.apply_damage(id, 250.0)
	_save.save_now()
	_save.load_or_new()
	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp - 250.0, 1e-6,
		"depleted HP persists and reloads unchanged")

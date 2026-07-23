extends GutTest
# DamageModel: the per-car HP / attrition logic (features/damage.md). These
# exercise the maths and wreck semantics directly against a DamageModel (no
# physics body needed). The bound-wreck and persistence tests use a throwaway
# Save profile so a real profile is never touched, mirroring test_save_manager.gd.

const TEST_PATH := "user://test_damage_profile.json"

var _save: Node


func before_each() -> void:
	Config.reset()
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


func test_single_spike_is_capped_and_cannot_wreck() -> void:
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	# A colossal single spike is capped to a flat HP amount, so it can't wreck.
	var loss := dm.register_deceleration(1.0e6, DT, Vector3.ZERO, cfg)
	assert_almost_eq(loss, cfg.impact_max_loss, 1e-3,
		"a single spike is capped to the flat impact_max_loss amount")
	assert_gt(dm.hp, 0.0, "one crash cannot wreck the car")
	assert_eq(wrecks["n"], 0, "no wreck from a single hit")


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


func test_repeated_spikes_accumulate_and_wreck() -> void:
	# A real multi-bounce tumble is several genuine Δv spikes; with no cooldown each
	# capped hit lands, so enough of them wreck the car (tall drops are dangerous).
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	var hits := 0
	while dm.hp > 0.0 and hits < 20:
		dm.register_deceleration(1.0e6, DT, Vector3.ZERO, cfg)
		hits += 1
	assert_lt(hits, 20, "repeated capped spikes eventually wreck the car")
	assert_eq(wrecks["n"], 1, "wrecked exactly once, on the final hit")


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


func test_misfire_level_zero_above_threshold_then_ramps() -> void:
	# Fully healthy above the health threshold; ramps 0 -> 1 from the threshold down
	# to 0 HP. Uses an explicit threshold so it doesn't pin the authored config value.
	var cfg := GameConfig.new()
	cfg.damage_misfire_health_threshold = 0.5
	var dm := DamageModel.new()
	dm.field(1000.0, 1000.0)
	assert_eq(dm.misfire_level(cfg), 0.0, "full health -> no misfire")
	dm.hp = 600.0  # health 0.6, above the 0.5 threshold
	assert_eq(dm.misfire_level(cfg), 0.0, "above the threshold the engine stays healthy")
	dm.hp = 500.0  # exactly at the threshold: still the edge of healthy
	assert_almost_eq(dm.misfire_level(cfg), 0.0, 1e-6, "at the threshold, misfire just begins")
	dm.hp = 250.0  # health 0.25, halfway from threshold to 0
	assert_almost_eq(dm.misfire_level(cfg), 0.5, 1e-6, "misfire ramps in below the threshold")
	dm.hp = 0.0
	assert_almost_eq(dm.misfire_level(cfg), 1.0, 1e-6, "full misfire intensity at 0 HP")


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


# --- Wreck at 0 HP -----------------------------------------------------------

func test_unbound_wreck_emits_without_touching_save() -> void:
	var dm := DamageModel.new()
	dm.field(800.0, 30.0, -1)  # unbound: free-roam / dev
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	dm.apply_loss(100.0)
	assert_eq(wrecks["n"], 1, "wrecked emitted once at 0 HP")
	assert_eq(dm.hp, 0.0, "HP floored at 0")
	assert_eq(_save.profile["cars"].size(), 0, "an unbound model never touches the save")


func test_bound_wreck_zeroes_hp_keeping_car_and_upgrades() -> void:
	var car: Dictionary = _save.grant_car("mx5")
	var id := int(car["instance_id"])
	# Upgrades are car-bound — install_upgrade fits the part straight to the car.
	assert_true(_save.install_upgrade(id, "fx_turbo_small"), "upgrade fitted")
	assert_eq(_save.get_car(id)["installed_upgrades"].size(), 1, "one upgrade installed")

	var dm := DamageModel.new()
	dm.field(800.0, 40.0, id)
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	dm.apply_loss(40.0)  # -> 0 HP

	assert_eq(wrecks["n"], 1, "wrecked emitted")
	# The bound car is left at 0 HP in the save (repairable), not destroyed.
	assert_false(_save.get_car(id).is_empty(), "the wrecked instance is kept in the save")
	assert_eq(float(_save.get_car(id)["hp"]), 0.0, "the saved car sits at 0 HP")
	assert_true(_save.get_car(id)["installed_upgrades"].has("fx_turbo_small"),
		"the fitted upgrade stays on the wrecked car")


func test_every_car_takes_damage_and_can_wreck() -> void:
	# No car is invulnerable any more: impacts cost HP and enough damage wrecks it.
	var cfg: GameConfig = Config.data
	var dm := DamageModel.new()
	dm.field(800.0, 800.0)
	var wrecks := {"n": 0}
	dm.wrecked.connect(func() -> void: wrecks["n"] += 1)
	assert_gt(dm.register_deceleration(100000.0, DT, Vector3.ZERO, cfg), 0.0, "a hard impact costs HP")
	assert_lt(dm.hp, 800.0, "HP falls after an impact")
	dm.apply_loss(100000.0)
	assert_eq(dm.hp, 0.0, "lethal damage floors HP at 0")
	assert_eq(wrecks["n"], 1, "the car wrecks at 0 HP")
	assert_almost_eq(dm.damage_fraction(), 1.0, 1e-6, "a wrecked car reads full damage")


# --- Persistence handoff -----------------------------------------------------

func test_event_boundary_writeback_round_trips() -> void:
	var car: Dictionary = _save.grant_car("xjs")
	var id := int(car["instance_id"])
	var max_hp := float(_save.get_car(id)["hp"])  # granted at full HP
	# Working HP depleted over a run is written back at the event boundary.
	_save.apply_damage(id, 250.0)
	_save.save_now()
	_save.load_or_new()
	assert_almost_eq(float(_save.get_car(id)["hp"]), max_hp - 250.0, 1e-6,
		"depleted HP persists and reloads unchanged")

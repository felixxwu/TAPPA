class_name DamageModel
extends RefCounted
# Docs: features/damage.md — update in the same change as this file.
# Tests: tests/headless/test_damage_model.gd, tests/headless/test_spectator_damage.gd — extend in the same change.
# Per-car HP / attrition state and the maths that degrade a damaged car, owned by
# car.gd the way Drivetrain is (a plain RefCounted helper, no scene coupling). It
# holds the run's WORKING HP, converts contact impulses into HP loss, exposes the
# damage fraction (which drives the engine misfire and the rev cap) and the per-wheel
# toe the car reads each tick. See features/damage.md.
#
# Hitting 0 HP never wrecks a stage car: it keeps driving, misfiring and rev-capped. In free
# roam `thermal` is on: an overheating engine drains HP, and at 0 HP the car gives up (`gave_up`).
# HP climbs back only via regen() (a tunable rate) or repair().

# Lost HP per impact and the contact point, for the HUD impact cue / impact SFX
# (todo/audio.md). Emitted only for hits that actually cost HP.
signal damaged(hp_loss: float, contact_point: Vector3)
# The car has given up: HP reached 0 with the thermal chain on (free roam,
# todo/2026-10-19-free-roam-pivot.md decision 8). Emitted ONCE per fall to 0; repair() re-arms
# it. Never emitted with `thermal` off, so the stage keeps "damage never wrecks".
signal gave_up
# Scene group every damage-dealing obstacle (tree/bush/sign collision body) joins,
# so the car can tell a real obstacle contact from the ground/road in
# _integrate_forces. BillboardField tags its collision body with this.
const OBSTACLE_GROUP := "obstacle"

# m/s -> km/h, so the speed-keyed damage maths can work in the km/h the GameConfig
# knobs are authored in (car.gd reads the body's velocity in m/s).
const MPS_TO_KMH := 3.6

# Gravity magnitude used to turn the config's braking-proof threshold (in g) into a
# per-tick velocity floor (impact_threshold_g · g · dt). See register_deceleration.
# Sourced from Platform.gravity() (physics/3d/default_gravity) so this tracks the
# actual simulated gravity; a static var, not a const, because const can't call a func.
static var GRAVITY_MPS2: float = Platform.gravity()

# The four wheel nodes, in a STABLE order — the index used to persist wheel_toe on
# the OwnedCar (features/damage.md). Matches the VehicleWheel3D node names in
# car.tscn; car.gd maps each entry to its node when it applies the bend.
const WHEEL_NAMES: Array[String] = ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]

var max_hp := 1000.0
var hp := 1000.0
# Permanent per-wheel toe misalignment (radians), keyed by WHEEL_NAMES. Each solid
# impact bends every wheel by a random amount/direction (nudge_wheels); car.gd feeds
# these into the per-wheel VehicleWheel3D.steering so the car's pull/crab comes from
# the physics alone. Saved with the world's car_state; a full repair straightens it.
var wheel_toe: Dictionary = _zero_toe()


## The free-roam damage chain: below cooling_failure_hp_fraction the cooling breaks and stays
## broken until repair(); while broken, engine_temp only rises (faster at higher revs);
## above overheat_temp_threshold_c it drains HP; at 0 HP the car gives up (`gave_up`). Off by
## default, so the stage is untouched.
var thermal := false
# Takes no damage at all (the benchmark, so a crash can't wreck the run or bend the steering).
var invulnerable := false
var cooling_broken := false
var engine_temp := 0.0
var _gave_up := false


# Set the HP pool and load the car's persisted wheel misalignment; called by car.gd when a car is configured.
func field(p_max_hp: float, p_hp: float, p_toe: Array = []) -> void:
	max_hp = maxf(1.0, p_max_hp)
	hp = clampf(p_hp, 0.0, max_hp)
	set_toe_from_array(p_toe)


# A fresh all-zero toe map (no wheel bent). Used as the default and by a repair.
static func _zero_toe() -> Dictionary:
	var d := {}
	for name in WHEEL_NAMES:
		d[name] = 0.0
	return d


# Load persisted per-wheel toe from an array ordered like WHEEL_NAMES (as stored on
# the OwnedCar). A short/empty array leaves the remaining wheels straight, so an
# older save with no wheel_toe key fields a straight car.
func set_toe_from_array(arr: Array) -> void:
	wheel_toe = _zero_toe()
	for i in mini(arr.size(), WHEEL_NAMES.size()):
		wheel_toe[WHEEL_NAMES[i]] = float(arr[i])


# The current toe as an array ordered like WHEEL_NAMES, for persisting on the OwnedCar.
func toe_array() -> Array:
	var out: Array = []
	for name in WHEEL_NAMES:
		out.append(wheel_toe[name])
	return out


# Straighten every wheel (the field repair eases the alignment back along with the HP).
func reset_wheel_toe() -> void:
	wheel_toe = _zero_toe()


# Bend each wheel by a random amount and direction on a solid impact. The magnitude
# scales with the hit's strength (hp_loss as a fraction of max HP) so a big crash
# knocks the wheels harder; the direction is rolled PER WHEEL so they don't all bend
# the same way and repeated hits can partly cancel (a wheel can end up near-straight
# again). Each wheel is clamped to ±damage_wheel_toe_max. Called by register_deceleration.
func nudge_wheels(hp_loss: float, cfg: GameConfig) -> void:
	if hp_loss <= 0.0 or max_hp <= 0.0:
		return
	var strength := clampf(hp_loss / max_hp, 0.0, 1.0)
	var base := strength * cfg.damage_wheel_toe_gain
	for name in WHEEL_NAMES:
		var dir := 1.0 if randf() < 0.5 else -1.0
		var delta := dir * base * randf_range(0.5, 1.0)
		wheel_toe[name] = clampf(wheel_toe[name] + delta, -cfg.damage_wheel_toe_max, cfg.damage_wheel_toe_max)


# Damage fraction d ∈ [0,1]: 0 at full HP, 1 at 0 HP.
func damage_fraction() -> float:
	if max_hp <= 0.0:
		return 0.0
	return clampf(1.0 - hp / max_hp, 0.0, 1.0)


# How far past the "damage starts costing power" threshold the car is, ∈ [0,1]:
# 0 while health (hp/max_hp) is at/above damage_misfire_health_threshold, ramping
# linearly to 1 at 0 HP. The SINGLE ramp behind every engine-weakening effect
# (misfire and rev cap), so they all begin at the same moment and reach their worst
# together. Pure — no config side effects.
func damage_ramp(cfg: GameConfig) -> float:
	return maxf(_health_ramp(cfg), overheat_ramp(cfg))


# How far an overheating engine is past its threshold toward its maximum, ∈ [0,1]; 0 with the
# thermal chain off. Feeds the same misfire / rev-cap ramp as damage, so overheating sounds sick.
func overheat_ramp(cfg: GameConfig) -> float:
	if not thermal:
		return 0.0
	var span := maxf(cfg.engine_temp_max_c - cfg.overheat_temp_threshold_c, 0.001)
	return clampf((engine_temp - cfg.overheat_temp_threshold_c) / span, 0.0, 1.0)


func _health_ramp(cfg: GameConfig) -> float:
	if max_hp <= 0.0:
		return 0.0
	var threshold := cfg.damage_misfire_health_threshold
	if threshold <= 0.0:
		# Degenerate threshold: only a dead-flat 0 HP car is weakened (avoid div-by-zero).
		return 1.0 if hp <= 0.0 else 0.0
	var health := hp / max_hp
	return clampf((threshold - health) / threshold, 0.0, 1.0)


# Engine misfire intensity, fed to EngineSim.misfire_level each tick by car.gd. Follows
# damage_ramp but tops out at damage_misfire_level_max rather than 1.0: damage weakens
# the engine TO A POINT and no further, so even a 0 HP car still makes progress under
# power instead of becoming an undrivable brick. That cap is the whole reason a car can
# sit at 0 HP indefinitely without the run ending.
func misfire_level(cfg: GameConfig) -> float:
	return damage_ramp(cfg) * clampf(cfg.damage_misfire_level_max, 0.0, 1.0)


# Fraction of the engine's redline still usable, ∈ (0,1]. 1.0 (full revs) until health
# drops past damage_misfire_health_threshold, then falls linearly with the same ramp to
# damage_rev_limit_min_fraction at 0 HP — a damaged engine won't pull to the top end, so
# each gear runs out early and the car is slower everywhere, in a way the player HEARS
# (it bounces off a lower limiter) as well as feels. Never returns 0: the floor is a
# tunable minimum, so the car always revs enough to drive.
func rev_limit_fraction(cfg: GameConfig) -> float:
	var floor_frac := clampf(cfg.damage_rev_limit_min_fraction, 0.05, 1.0)
	return lerpf(1.0, floor_frac, damage_ramp(cfg))


# HP a shed velocity (m/s) costs: a pure square-law (kinetic-energy) climb reaching
# impact_ref_hp_loss at impact_ref_speed_kmh (working in km/h to match the config knobs;
# above the reference it keeps climbing, capped by the caller). There is no low-speed
# floor here — the braking-proof gate lives in register_deceleration (impact_threshold_g),
# so this stays a clean v² curve, well-defined from zero. Pure/static, unit-testable.
static func hp_loss_for_speed(speed_mps: float, cfg: GameConfig) -> float:
	var v := speed_mps * MPS_TO_KMH
	var ref := cfg.impact_ref_speed_kmh
	return cfg.impact_ref_hp_loss * v * v / maxf(ref * ref, 1e-6)


# The UNIFIED damage entry point (features/damage.md): HP loss keyed to how much
# velocity the car shed in ONE physics tick (`dv_mps`), whatever caused it — a tree,
# a cliff wall, a nose-first drop, or the small drag impulse of a brushed bush/crowd.
# `dt` is the physics step. Nothing below the braking-proof threshold
# (impact_threshold_g · g · dt) costs HP, so ordinary braking (~1-1.5 g) is free;
# above it the same square law as before scales the loss (for a full solid arrest
# dv ≈ approach speed, so the existing tuning carries over). Capped per hit so no one
# crash can gut it in one go. NO cooldown: a pinned car sheds ~0 velocity/tick so grinding
# self-limits, while a real multi-bounce tumble racks up several capped hits. Returns
# the HP lost.
func register_deceleration(dv_mps: float, dt: float, contact_point: Vector3, cfg: GameConfig) -> float:
	if dt <= 0.0 or invulnerable:
		return 0.0
	var floor_mps := cfg.impact_threshold_g * GRAVITY_MPS2 * dt
	if dv_mps <= floor_mps:
		return 0.0
	var loss := hp_loss_for_speed(dv_mps, cfg)
	if loss <= 0.0:
		return 0.0
	# Cap a single hit (flat HP amount) so no one crash can strip the car's whole HP pool;
	# because it's absolute, a car's max_hp determines how many capped hits it takes.
	loss = minf(loss, cfg.impact_max_loss)
	nudge_wheels(loss, cfg)
	apply_loss(loss)
	damaged.emit(loss, contact_point)
	return loss


# Drain HP by `amount`, bottoming out at 0. With `thermal` on, reaching 0 emits `gave_up` once.
func apply_loss(amount: float) -> void:
	if invulnerable:
		return
	hp = maxf(0.0, hp - amount)
	if thermal and hp <= 0.0 and not _gave_up:
		_gave_up = true
		gave_up.emit()


# One physics tick of the thermal chain. `rpm_frac` is rpm / redline. The engine heats linearly with
# rpm; working cooling multiplies the temperature by a factor just under 1, so a hotter engine sheds
# more. Broken cooling simply skips that multiply. Returns the HP the overheat drained this tick.
func thermal_step(dt: float, rpm_frac: float, cfg: GameConfig) -> float:
	if not thermal or dt <= 0.0:
		return 0.0
	if not cooling_broken and max_hp > 0.0 and hp <= max_hp * cfg.cooling_failure_hp_fraction:
		cooling_broken = true
	engine_temp += cfg.engine_heat_c_per_s * maxf(rpm_frac, 0.0) * dt
	if not cooling_broken:
		engine_temp *= pow(cfg.engine_cooling_retain_per_s, dt)
	engine_temp = minf(engine_temp, cfg.engine_temp_max_c)
	if engine_temp <= cfg.overheat_temp_threshold_c:
		return 0.0
	var before := hp
	apply_loss(cfg.overheat_hp_drain_per_s * dt)
	return before - hp


# How hot the engine is on the gauge, ∈ [0,1]: the temperature in °C over the overheat threshold
# (where HP starts draining), so 0 °C is empty; past the threshold the gauge stays full.
func temp_fraction(cfg: GameConfig) -> float:
	return clampf(engine_temp / maxf(cfg.overheat_temp_threshold_c, 0.001), 0.0, 1.0)


func is_overheating(cfg: GameConfig) -> bool:
	return thermal and engine_temp > cfg.overheat_temp_threshold_c


# The rest-stop repair: full HP, cooling fixed (it brings the temperature down by itself), wheels
# straight, and `gave_up` re-armed.
func repair(_cfg: GameConfig) -> void:
	hp = max_hp
	cooling_broken = false
	_gave_up = false
	reset_wheel_toe()


# The self-heal tick: trickle `cfg.damage_regen_hp_per_s` back into the pool, capped at
# max_hp, on the same physics step the impact damage above is measured on.
# Healing does not straighten wheels — only a full repair resets `wheel_toe`.
# Returns the HP actually regained (0.0 when already full, or the rate is 0).
func regen(dt: float, cfg: GameConfig) -> float:
	if dt <= 0.0 or cfg.damage_regen_hp_per_s <= 0.0:
		return 0.0
	var before := hp
	hp = minf(max_hp, hp + cfg.damage_regen_hp_per_s * dt)
	return hp - before

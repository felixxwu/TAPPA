class_name DamageModel
extends RefCounted
# Per-car HP / attrition state and the maths that degrade a damaged car, owned by
# car.gd the way Drivetrain is (a plain RefCounted helper, no scene coupling). It
# holds the run's WORKING HP, converts contact impulses into HP loss, exposes the
# damage fraction (which drives the engine misfire) and the per-wheel toe the car
# reads each tick, and wrecks the car at 0 HP. See features/damage.md.
#
# HP only ever goes DOWN in-run (no passive regen); a repair kit (Save) is the
# only way it climbs back, and that lives between runs, not here.
#
# Binding: when a car is FIELDED from the meta-game (a future rally/Start-line
# layer, features/rally-session.md) it carries an OwnedCar instance_id, and a
# wreck removes that instance via Save.wreck_car (returning its upgrades to
# inventory). In free-roam / dev play the model is UNBOUND (instance_id < 0): it
# still depletes and degrades and emits `wrecked`, but never touches the save —
# the car self-heals and respawns so play continues (car.gd handles that).
#
# There is no in-run anti-soft-lock floor: every car can be wrecked. A wrecked-out
# player is recovered between runs by Save.ensure_repair_safety_net (a free repair
# kit when all owned cars are wrecked and none is held).

# Lost HP per impact and the contact point, for the HUD impact cue / impact SFX
# (todo/audio.md). Emitted only for hits that actually cost HP.
signal damaged(hp_loss: float, contact_point: Vector3)
# HP reached 0: the run is a DNF. A fielded car has already
# had Save.wreck_car called; listeners (the rally flow) react to the signal.
signal wrecked()

# Scene group every damage-dealing obstacle (tree/bush/sign collision body) joins,
# so the car can tell a real obstacle contact from the ground/road in
# _integrate_forces. BillboardField tags its collision body with this.
const OBSTACLE_GROUP := "obstacle"

# m/s -> km/h, so the speed-keyed damage maths can work in the km/h the GameConfig
# knobs are authored in (car.gd reads the body's velocity in m/s).
const MPS_TO_KMH := 3.6

# Gravity magnitude used to turn the config's braking-proof threshold (in g) into a
# per-tick velocity floor (impact_threshold_g · g · dt). See register_deceleration.
const GRAVITY_MPS2 := 9.81

# The four wheel nodes, in a STABLE order — the index used to persist wheel_toe on
# the OwnedCar (features/damage.md). Matches the VehicleWheel3D node names in
# car.tscn; car.gd maps each entry to its node when it applies the bend.
const WHEEL_NAMES: Array[String] = ["WheelFL", "WheelFR", "WheelRL", "WheelRR"]

var max_hp := 1000.0
var hp := 1000.0
# OwnedCar binding; -1 = unbound (free-roam / dev play — never touches Save).
var instance_id := -1
# Permanent per-wheel toe misalignment (radians), keyed by WHEEL_NAMES. Each solid
# impact bends every wheel by a random amount/direction (nudge_wheels); car.gd feeds
# these into the per-wheel VehicleWheel3D.steering so the car's pull/crab comes from
# the physics alone. Persisted per car (Save), cleared only by a Repair Kit. See
# features/damage.md.
var wheel_toe: Dictionary = _zero_toe()


# Field the model for a run: bind it to an OwnedCar (or -1 for free-roam), set the
# HP pool, and load the car's persisted wheel misalignment. Called by car.gd when a
# car is configured (apply_car / apply_owned) and by the fielding layer.
func field(p_max_hp: float, p_hp: float, p_instance_id := -1, p_toe: Array = []) -> void:
	max_hp = maxf(1.0, p_max_hp)
	hp = clampf(p_hp, 0.0, max_hp)
	instance_id = p_instance_id
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


# Straighten every wheel (a Repair Kit fixes the alignment along with the HP).
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


# Engine misfire intensity ∈ [0,1], fed to EngineSim.misfire_level each tick by
# car.gd. 0 (fully healthy) while health (hp/max_hp) is at/above
# damage_misfire_health_threshold, then ramps linearly to 1 at 0 HP — so the engine
# only starts stumbling once the car is damaged past the threshold.
func misfire_level(cfg: GameConfig) -> float:
	if max_hp <= 0.0:
		return 0.0
	var threshold := cfg.damage_misfire_health_threshold
	if threshold <= 0.0:
		# Degenerate threshold: only a dead-flat 0 HP car misfires (avoid div-by-zero).
		return 1.0 if hp <= 0.0 else 0.0
	var health := hp / max_hp
	return clampf((threshold - health) / threshold, 0.0, 1.0)


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
# crash wrecks the car. NO cooldown: a pinned car sheds ~0 velocity/tick so grinding
# self-limits, while a real multi-bounce tumble racks up several capped hits. Returns
# the HP lost.
func register_deceleration(dv_mps: float, dt: float, contact_point: Vector3, cfg: GameConfig) -> float:
	if dt <= 0.0:
		return 0.0
	var floor_mps := cfg.impact_threshold_g * GRAVITY_MPS2 * dt
	if dv_mps <= floor_mps:
		return 0.0
	var loss := hp_loss_for_speed(dv_mps, cfg)
	if loss <= 0.0:
		return 0.0
	# Cap a single hit (flat HP amount) so no one crash can wreck the car; because
	# it's absolute, a car's max_hp determines how many capped hits it survives.
	loss = minf(loss, cfg.impact_max_loss)
	nudge_wheels(loss, cfg)
	apply_loss(loss)
	damaged.emit(loss, contact_point)
	return loss


# Drain HP by `amount`, wrecking the car if it hits 0.
func apply_loss(amount: float) -> void:
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0:
		_wreck()


# 0 HP: a fielded car is destroyed via Save (upgrades returned, then removed);
# either way `wrecked` fires for the run/menu layer.
# `Save` is the autoload, reached by global name like Config is in Drivetrain; an
# unbound model (instance_id < 0, free-roam/dev) never touches it.
func _wreck() -> void:
	if instance_id >= 0:
		Save.wreck_car(instance_id)
	wrecked.emit()

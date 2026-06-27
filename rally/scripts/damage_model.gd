class_name DamageModel
extends RefCounted
# Per-car HP / attrition state and the maths that degrade a damaged car, owned by
# car.gd the way Drivetrain is (a plain RefCounted helper, no scene coupling). It
# holds the run's WORKING HP, converts contact impulses into HP loss, exposes the
# damage-fraction-scaled handling/power effects the car reads each tick, and
# wrecks the car at 0 HP. See todo/damage-model.md.
#
# HP only ever goes DOWN in-run (no passive regen); a repair kit (Save) is the
# only way it climbs back, and that lives between runs, not here.
#
# Binding: when a car is FIELDED from the meta-game (a future rally/Start-line
# layer, todo/rally-event-flow.md) it carries an OwnedCar instance_id, and a
# wreck removes that instance via Save.wreck_car (returning its upgrades to
# inventory). In free-roam / dev play the model is UNBOUND (instance_id < 0): it
# still depletes and degrades and emits `wrecked`, but never touches the save —
# the car self-heals and respawns so play continues (car.gd handles that).
#
# The immortal starter (OwnedCar.immortal) is the anti-soft-lock floor: it never
# loses HP, shows no effects and is never wrecked.

# Lost HP per impact and the contact point, for the HUD impact cue / impact SFX
# (todo/audio.md). Emitted only for hits that actually cost HP.
signal damaged(hp_loss: float, contact_point: Vector3)
# HP reached 0 on a non-immortal car: the run is a DNF. A fielded car has already
# had Save.wreck_car called; listeners (the rally flow) react to the signal.
signal wrecked()

# Scene group every damage-dealing obstacle (tree/bush/sign collision body) joins,
# so the car can tell a real obstacle contact from the ground/road in
# _integrate_forces. BillboardField tags its collision body with this.
const OBSTACLE_GROUP := "obstacle"

var max_hp := 1000.0
var hp := 1000.0
var immortal := false
# OwnedCar binding; -1 = unbound (free-roam / dev play — never touches Save).
var instance_id := -1
# +1 / -1 alignment-pull direction, re-rolled each run so it can't be pre-learnt
# (todo/damage-model.md §3). Set via reroll_bias(); defaults to a pull, not 0.
var align_bias_sign := 1.0
# Seconds of impact immunity remaining after a damaging hit (impact_cooldown_s).
# Ticked down by car.gd each physics frame (tick_cooldown). Groups one crash —
# which contacts the chassis every tick while pinned — into a single hit.
var _impact_cooldown := 0.0


# Field the model for a run: bind it to an OwnedCar (or -1 for free-roam), set the
# HP pool, and re-roll the alignment-pull direction. Called by car.gd when a car
# is configured (apply_car) and by the future fielding layer.
func field(p_max_hp: float, p_hp: float, p_immortal: bool, p_instance_id := -1) -> void:
	max_hp = maxf(1.0, p_max_hp)
	hp = clampf(p_hp, 0.0, max_hp)
	immortal = p_immortal
	instance_id = p_instance_id
	_impact_cooldown = 0.0
	reroll_bias()


# Decay the post-hit impact cooldown. Called by car.gd each physics frame.
func tick_cooldown(delta: float) -> void:
	_impact_cooldown = maxf(0.0, _impact_cooldown - delta)


# Re-roll the alignment-pull direction (±1). Random per run so a re-entry can pull
# the other way; not tied to any seed. Tests set align_bias_sign directly instead.
func reroll_bias() -> void:
	align_bias_sign = 1.0 if randf() < 0.5 else -1.0


# Damage fraction d ∈ [0,1]: 0 at full HP, 1 at 0 HP. Always 0 for the immortal
# starter (it shows no effects). The handling/power effects scale off this.
func damage_fraction() -> float:
	if immortal or max_hp <= 0.0:
		return 0.0
	return clampf(1.0 - hp / max_hp, 0.0, 1.0)


# Added steer-target bias (radians) from wheel misalignment — the car drifts to
# one side as it takes damage. 0 at full HP, ±damage_steer_bias_max at 0 HP.
func steer_bias(cfg: GameConfig) -> float:
	return align_bias_sign * damage_fraction() * cfg.damage_steer_bias_max


# Multiplier on the driven torque: 1 at full HP, falling to
# 1 - damage_power_loss_max at 0 HP.
func power_multiplier(cfg: GameConfig) -> float:
	return 1.0 - damage_fraction() * cfg.damage_power_loss_max


# HP a contact of the given impulse magnitude costs: nothing up to the threshold,
# then linear above it. Pure/static so the conversion is unit-testable.
static func hp_loss_for_impulse(impulse: float, cfg: GameConfig) -> float:
	return maxf(0.0, impulse - cfg.impact_min_impulse) * cfg.hp_per_impulse


# Register an obstacle contact: convert its impulse to HP loss, apply it, and
# (when it actually costs HP) emit `damaged` for the HUD/audio cue. Returns the
# HP lost. The immortal starter ignores impacts entirely.
func register_impact(impulse: float, contact_point: Vector3, cfg: GameConfig) -> float:
	if immortal:
		return 0.0
	# Within the post-hit cooldown the crash is still "in progress" — ignore it so a
	# car pinned against a tree (which contacts every tick) loses HP once, not per frame.
	if _impact_cooldown > 0.0:
		return 0.0
	var loss := hp_loss_for_impulse(impulse, cfg)
	if loss <= 0.0:
		return 0.0
	# Cap a single hit so no one crash can wreck the car (survive 2-3 big hits).
	loss = minf(loss, max_hp * cfg.impact_max_loss_frac)
	_impact_cooldown = cfg.impact_cooldown_s
	apply_loss(loss)
	damaged.emit(loss, contact_point)
	return loss


# Drain HP by `amount`, wrecking the car if it hits 0. The immortal starter floors
# at 1 HP and is never wrecked.
func apply_loss(amount: float) -> void:
	if immortal:
		hp = maxf(1.0, hp - amount)
		return
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0:
		_wreck()


# 0 HP: a fielded car is destroyed via Save (upgrades returned, then removed);
# either way `wrecked` fires for the run/menu layer. Never wrecks the immortal.
# `Save` is the autoload, reached by global name like Config is in Drivetrain; an
# unbound model (instance_id < 0, free-roam/dev) never touches it.
func _wreck() -> void:
	if immortal:
		return
	if instance_id >= 0:
		Save.wreck_car(instance_id)
	wrecked.emit()

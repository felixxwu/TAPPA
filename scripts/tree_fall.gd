class_name TreeFall
# Pure, scene-free maths for felling a tree when the car crashes into it above a
# speed threshold (see todo/trees-falling-on-impact.md). Kept static + stateless so
# it's unit-testable headless, in the same spirit as ScatterMath. The stateful part
# (mutating the struck MultiMesh instance, disabling its hitbox) lives in
# TreeMeshField; this module only answers "should it fall?", "how far has it fallen
# by now?", and "about which axis?".


# Target tilt angle (radians) a felled tree reaches when it's flat on the ground.
# Just past PI/2 so it reads as lying down / settled rather than balanced on edge.
const FLAT_ANGLE := PI * 0.55


# True when a crash at `speed_mps` is fast enough to topple a tree, per the
# configured km/h threshold. A non-positive threshold means "never fell" (the
# feature is effectively off), so trees stay solid obstacles at any speed.
static func should_fell(speed_mps: float, cfg: GameConfig) -> bool:
	if cfg.tree_fell_speed_kmh <= 0.0:
		return false
	return speed_mps * DamageModel.MPS_TO_KMH >= cfg.tree_fell_speed_kmh


# Speed (km/h) at which a tree of visual `size` (0..1) fells. Scales LINEARLY with
# size off the full-size threshold cfg.tree_fell_speed_kmh, so a small tree topples
# sooner. size == 1.0 preserves the configured threshold exactly.
static func fell_speed_kmh(size: float, cfg: GameConfig) -> float:
	return cfg.tree_fell_speed_kmh * clampf(size, 0.0, 1.0)


# True when a crash at `speed_mps` fells a tree of visual `size`. The size-aware
# twin of should_fell. A non-positive full-size threshold means "never fell".
static func should_fell_sized(speed_mps: float, size: float, cfg: GameConfig) -> bool:
	var thresh := fell_speed_kmh(size, cfg)
	if thresh <= 0.0:
		return false
	return speed_mps * DamageModel.MPS_TO_KMH >= thresh


# Fraction of the shed forward momentum a FELLED tree of visual `size` returns to
# the car (as a central impulse — see car.gd). 0 at full size (hard stop as today),
# rising toward cfg.tree_plough_keep_max as size shrinks, so small trees are
# pushovers. Result is clamped to [0, 1].
static func plough_keep(size: float, cfg: GameConfig) -> float:
	return clampf(cfg.tree_plough_keep_max * (1.0 - clampf(size, 0.0, 1.0)), 0.0, 1.0)


# New linear velocity for a car that ploughs through felled trees this tick. `keep`
# in [0,1] is the fraction of the shed FORWARD momentum returned (0 = hard stop: the
# solver's post-solve velocity stands). Restores only the HORIZONTAL component along
# the shed direction, leaving the vertical to gravity/suspension, and never lets the
# horizontal speed exceed `approach_speed` (no free energy). Returns a LINEAR velocity
# ONLY — the caller applies it centrally, so the solver's off-center contact response
# (the spin a rear-quarter clip imparts) is left completely untouched.
static func plough_restore_velocity(approach_vel: Vector3, post_vel: Vector3,
		keep: float, approach_speed: float) -> Vector3:
	keep = clampf(keep, 0.0, 1.0)
	if keep <= 0.0:
		return post_vel
	var shed := approach_vel - post_vel
	var restore := Vector3(shed.x, 0.0, shed.z) * keep
	var v := post_vel + restore
	var v_h := Vector3(v.x, 0.0, v.z)
	if v_h.length() > approach_speed:
		v_h = v_h.normalized() * approach_speed
		return Vector3(v_h.x, v.y, v_h.z)
	return v


# Eased tilt angle at `elapsed` seconds into a fall of length `duration`. Starts at
# 0 (upright), rises monotonically, and clamps to FLAT_ANGLE at/after `duration`
# with no overshoot past the clamp. Ease-out (fast then settling) so the tree snaps
# over then eases flat.
static func fall_angle(elapsed: float, duration: float) -> float:
	if duration <= 0.0:
		return FLAT_ANGLE
	var t := clampf(elapsed / duration, 0.0, 1.0)
	# Ease-out cubic: quick topple, gentle settle.
	var eased := 1.0 - pow(1.0 - t, 3.0)
	return eased * FLAT_ANGLE


# Horizontal unit axis to topple about so the tree falls ALONG `dir` (the car's
# travel direction). Perpendicular to `dir` and level with the ground. Falls back
# to a fixed axis when `dir` is ~zero or ~vertical, so the result is always a valid
# unit vector.
static func topple_axis(dir: Vector3) -> Vector3:
	var axis := Vector3.UP.cross(dir)
	if axis.length() < 0.0001:
		return Vector3.RIGHT
	return axis.normalized()

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

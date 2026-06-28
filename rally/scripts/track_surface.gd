class_name TrackSurface
extends RefCounted
# Pure functions describing how a generated track is split between gravel and
# tarmac along its length. A track switches surface exactly ONCE (so each surface
# appears as one contiguous run): it either starts on gravel and switches to
# tarmac, or starts on tarmac and switches to gravel — picked deterministically
# from the track seed. The switch sits so the tarmac run covers `tarmac_fraction`
# of the length and the gravel run the rest.
#
# `tarmac_weight` returns the tarmac-ness in [0, 1] at a distance along the track
# (0 = pure gravel, 1 = pure tarmac), feathered with a smoothstep over a band so
# the gravel↔tarmac seam blends like the perpendicular grass↔road edge does. It
# drives BOTH the road colour (TerrainManager bakes it per cell / vertex) and the
# per-wheel grip (TerrainManager.surface_grip_at), so look and feel stay in sync.

# Deterministic surface orientation for a seed: true = the track STARTS on
# tarmac (then switches to gravel), false = starts on gravel (then tarmac).
static func orientation_tarmac_first(track_seed: int) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = track_seed
	return rng.randf() < 0.5


# Tarmac-ness in [0, 1] at `dist_m` metres along a track of length `total_m`.
# `tarmac_fraction` is the share of the length that is tarmac; `tarmac_first`
# picks which surface the track opens with; `feather_m` is the lengthwise
# smoothstep band centred on the single switch point. Fully-one-surface tracks
# (fraction 0 or 1) return a flat constant with no seam.
static func tarmac_weight(dist_m: float, total_m: float, tarmac_fraction: float, tarmac_first: bool, feather_m: float) -> float:
	if tarmac_fraction <= 0.0:
		return 0.0
	if tarmac_fraction >= 1.0:
		return 1.0
	# The single switch point: distance where the opening surface gives way.
	var switch_m := (tarmac_fraction if tarmac_first else 1.0 - tarmac_fraction) * total_m
	# Smoothstep 0→1 rising across the feather band centred on the switch.
	var rising := _smooth_switch(dist_m, switch_m, feather_m)
	# Tarmac-first opens at 1 and falls to 0; gravel-first opens at 0 and rises.
	return 1.0 - rising if tarmac_first else rising


# Smoothstep from 0 (well before `center`) to 1 (well after), over a band of
# `feather_m` centred on `center`. A zero/negative band is a hard step.
static func _smooth_switch(d: float, center: float, feather_m: float) -> float:
	if feather_m <= 0.0:
		return 0.0 if d < center else 1.0
	var half := feather_m * 0.5
	var t := clampf((d - (center - half)) / feather_m, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)

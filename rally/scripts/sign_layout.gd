class_name SignLayout
extends RefCounted
# Pure, scene-free planner for roadside signs (todo/roadside-signs.md §2). Given a
# generated track (centerline Curve2D + pieces, from TrackGenerator.generate) and
# the sign config, it returns one placement dict per physical sign. Mirrors
# TrackGenerator / TreeScatter: all static, no nodes, unit-testable. SignField
# (the Node3D) turns these placements into meshes + collision.
#
# Each placement:
#   { "kind": "turn",          # the only kind planted now (see plan())
#     "texture_key": String,   # which atlas image (GameConfig.sign_textures key)
#     "pos": Vector2,          # centerline point (XZ) at this sign's arc offset
#     "tangent": Vector2,      # unit road direction there
#     "side": int }            # +1 / -1 : which road edge (perpendicular sign)

# Corners that get a turn arrow: "4 or sharper" by exact name, plus Square/Hairpin.
# Gentle 5s and 6s are nearly straight, so they go unsigned; the compound
# "Right 4 tightens 2" is also excluded (see todo/roadside-signs.md §2).
const TURN_CORNERS := ["1", "2", "3", "4", "Square", "Hairpin"]

# Small arc-distance step used to estimate the road tangent by finite difference.
const TANGENT_EPS_M := 0.5


# Plan every sign for a stage. Turn arrows are the only roadside signs planted:
# the start and finish are marked by the inflatable arches (features/finish-arch.md),
# and the stage is no longer split into signed sectors (it is too short to carve
# into meaningful sector boards).
static func plan(centerline: Curve2D, pieces: Array) -> Array:
	var out: Array = []
	var length := centerline.get_baked_length()
	if length <= 0.0:
		return out

	# Turn arrows: a pair at the corner entry of every sharp turn.
	for piece in pieces:
		var corner := String(piece.get("corner", ""))
		if not TURN_CORNERS.has(corner):
			continue
		var entry_pos: Vector2 = piece["entry_pos"]
		var entry_heading: Vector2 = piece["entry_heading"]
		# The corner starts after the connecting straight (§1).
		var corner_entry := entry_pos + entry_heading.normalized() * float(piece["straight"])
		var offset := centerline.get_closest_offset(corner_entry)
		_emit_pair(out, centerline, length, offset, "turn", _arrow_key(corner, bool(piece["flip"])))

	return out


# The interior sector-boundary arc offsets (k*L/count for k in 1..count-1). No
# longer used for signs (sector boards were dropped), but kept as the stage timer's
# hook for per-sector splits (todo/stage-start-and-end.md §5) instead of recomputing.
static func sector_offsets(centerline: Curve2D, count: int) -> Array:
	var offsets: Array = []
	var length := centerline.get_baked_length()
	if length <= 0.0 or count <= 1:
		return offsets
	for k in range(1, count):
		offsets.append(k * length / float(count))
	return offsets


# Append two placements (one per road edge) at a single arc offset.
static func _emit_pair(out: Array, centerline: Curve2D, length: float, offset: float,
		kind: String, texture_key: String) -> void:
	var clamped := clampf(offset, 0.0, length)
	var pos := centerline.sample_baked(clamped)
	var tangent := _tangent_at(centerline, clamped, length)
	for side in [1, -1]:
		out.append({
			"kind": kind,
			"texture_key": texture_key,
			"pos": pos,
			"tangent": tangent,
			"side": side,
		})


# Unit road direction at an arc offset, by forward finite difference (backward
# near the end of the curve so the finish gate still gets a sensible tangent).
static func _tangent_at(centerline: Curve2D, offset: float, length: float) -> Vector2:
	var pos := centerline.sample_baked(offset)
	var tangent: Vector2
	if offset + TANGENT_EPS_M <= length:
		tangent = centerline.sample_baked(offset + TANGENT_EPS_M) - pos
	else:
		tangent = pos - centerline.sample_baked(maxf(0.0, offset - TANGENT_EPS_M))
	if tangent.length() < 1e-5:
		return Vector2(0.0, 1.0)
	return tangent.normalized()


# Atlas key for a turn arrow: shape from the corner name, direction from the flip
# (flip = left-hand corner). Numbered gradients carry their grade so each shows its
# own number on the board (textures/signs/arrow_<grade>_<dir>.png); Square and
# Hairpin use their named glyph. See the table in todo/roadside-signs.md §2.
static func _arrow_key(corner: String, flip: bool) -> String:
	var dir := "left" if flip else "right"
	match corner:
		"Square":
			return "arrow_square_%s" % dir
		"Hairpin":
			return "arrow_uturn_%s" % dir
		_:  # numbered gradient "1".."6": grade-specific curved arrow
			return "arrow_%s_%s" % [corner, dir]

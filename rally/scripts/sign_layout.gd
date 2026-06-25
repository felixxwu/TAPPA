class_name SignLayout
extends RefCounted
# Pure, scene-free planner for roadside signs (todo/roadside-signs.md §2). Given a
# generated track (centerline Curve2D + pieces, from TrackGenerator.generate) and
# the sign config, it returns one placement dict per physical sign. Mirrors
# TrackGenerator / TreeScatter: all static, no nodes, unit-testable. SignField
# (the Node3D) turns these placements into meshes + collision.
#
# Each placement:
#   { "kind": "sector"|"turn"|"start"|"finish",
#     "texture_key": String,   # which atlas image (GameConfig.sign_textures key)
#     "pos": Vector2,          # centerline point (XZ) at this sign's arc offset
#     "tangent": Vector2,      # unit road direction there
#     "side": int }            # +1 / -1 : which road edge (perpendicular sign)

# Corners that get a turn arrow: "2 or sharper" by exact name. The compound
# "Right 4 tightens 2" is intentionally excluded (see todo/roadside-signs.md §2).
const TURN_CORNERS := ["1", "2", "Square", "Hairpin"]

# Small arc-distance step used to estimate the road tangent by finite difference.
const TANGENT_EPS_M := 0.5


# Plan every sign for a stage. `params` is GameConfig.sign_params()
# ({ "sector_count": int }).
static func plan(centerline: Curve2D, pieces: Array, params: Dictionary) -> Array:
	var out: Array = []
	var length := centerline.get_baked_length()
	if length <= 0.0:
		return out
	var sector_count := int(params.get("sector_count", 4))

	# Start / finish gates (offset 0 and L), a pair each.
	_emit_pair(out, centerline, length, 0.0, "start", "start")
	_emit_pair(out, centerline, length, length, "finish", "finish")

	# Sector boards: a pair at each interior boundary, marking entry into 2..N.
	# Sector 1 is implied by the start gate, so we don't sign offset 0 again.
	for k in range(1, sector_count):
		var offset := k * length / float(sector_count)
		_emit_pair(out, centerline, length, offset, "sector", "sector_%d" % (k + 1))

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


# The interior sector-boundary arc offsets (k*L/count for k in 1..count-1). Exposed
# so the stage timer can reuse the exact same boundaries for per-sector splits if
# todo/stage-start-and-end.md grows them (§5) instead of recomputing the math.
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
	var tan: Vector2
	if offset + TANGENT_EPS_M <= length:
		tan = centerline.sample_baked(offset + TANGENT_EPS_M) - pos
	else:
		tan = pos - centerline.sample_baked(maxf(0.0, offset - TANGENT_EPS_M))
	if tan.length() < 1e-5:
		return Vector2(0.0, 1.0)
	return tan.normalized()


# Atlas key for a turn arrow: shape from the corner name, direction from the flip
# (flip = left-hand corner). See the table in todo/roadside-signs.md §2.
static func _arrow_key(corner: String, flip: bool) -> String:
	var dir := "left" if flip else "right"
	match corner:
		"Square":
			return "arrow_square_%s" % dir
		"Hairpin":
			return "arrow_uturn_%s" % dir
		_:  # "1", "2": curved arrow
			return "arrow_curve_%s" % dir

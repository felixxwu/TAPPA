class_name Pacenotes
extends RefCounted
# Pure, scene-free helpers for the in-run HUD pacenote strip (features/hud.md).
# Turns a generated track (centerline Curve2D + pieces, from TrackGenerator.generate)
# into an ordered list of turn calls the HUD reads left-to-right — the current turn,
# then the upcoming turns queued to its right. All static, no nodes, unit-testable,
# mirroring SignLayout / TrackGenerator.
#
# Each note:
#   { "corner": String,   # the CornerLibrary turn name ("1".."6", "Square", ...)
#     "flip": bool,       # true = left-hand corner (TrackGenerator mirrors right art)
#     "offset_m": float } # arc offset of the corner ENTRY on the centerline
#
# world.gd stamps an "at_frac" (0..1 progress fraction of the corner entry) onto each
# note so the StageManager can advance the strip off TrackProgress.progress_percent();
# see notes_to_fracs().

# Pieces that carry no turn call. A plain Straight isn't a corner, so it's skipped;
# every actual bend (gentle 5s/6s included, unlike the roadside signs) gets a note.
const SKIP_CORNERS := ["Straight"]


# Build the ordered note list from a generated track. One note per non-straight
# piece, at the corner entry (after the connecting straight) — the same arc offset
# SignLayout plants its board at. Empty for a null/degenerate centerline.
static func build(centerline: Curve2D, pieces: Array) -> Array:
	var out: Array = []
	if centerline == null or centerline.get_baked_length() <= 0.0:
		return out
	for piece in pieces:
		var corner := String(piece.get("corner", ""))
		if corner == "" or SKIP_CORNERS.has(corner):
			continue
		var entry_pos: Vector2 = piece.get("entry_pos", Vector2.ZERO)
		var entry_heading: Vector2 = piece.get("entry_heading", Vector2(0.0, 1.0))
		# The corner starts after the connecting straight (mirrors SignLayout.plan).
		var corner_entry := entry_pos + entry_heading.normalized() * float(piece.get("straight", 0.0))
		out.append({
			"corner": corner,
			"flip": bool(piece.get("flip", false)),
			"offset_m": centerline.get_closest_offset(corner_entry),
		})
	return out


# Convert each note's centerline arc offset into a progress FRACTION (0..1), matching
# how world.gd derives the pace-split thresholds: progress runs from the start line,
# so a staged run's lead-in ahead of the generated track (start_lead_in_ahead_m) is
# added to both the offset and the span. Returns a plain float array, note-aligned.
static func notes_to_fracs(notes: Array, ahead: float, span: float) -> Array:
	var out: Array = []
	if span <= 0.0:
		return out
	for n in notes:
		out.append(clampf((ahead + float(n.get("offset_m", 0.0))) / span, 0.0, 1.0))
	return out


# HUD arrow-atlas key for a note (a key into GameConfig.sign_textures). Shape from the
# corner name, direction from the flip.
#
# NOTE the direction is the TRUE turn direction — a left-hand corner (flip) shows a
# LEFT arrow. This is the OPPOSITE of SignLayout._arrow_key, which deliberately picks
# the mirrored art because a roadside A-frame FACES the oncoming driver; the HUD is
# not a facing panel, so no inversion here.
#
# The compound "Right 4 tightens 2" has no single grade, so it reuses its entry-grade
# (4) art. Square / Hairpin use their named glyph; numbered gradients "1".."6" carry
# their own grade board.
static func arrow_key(corner: String, flip: bool) -> String:
	var dir := "left" if flip else "right"
	match corner:
		"Square":
			return "arrow_square_%s" % dir
		"Hairpin":
			return "arrow_uturn_%s" % dir
		"Right 4 tightens 2":
			return "arrow_4_%s" % dir
		_:  # numbered gradient "1".."6"
			return "arrow_%s_%s" % [corner, dir]

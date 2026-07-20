extends GutTest
# Pacenotes: the pure, scene-free helpers behind the in-run HUD pacenote strip
# (features/hud.md). Build a note per corner from a generated track, map each to its
# arrow art (TRUE turn direction, unlike the oncoming-facing roadside signs), and
# convert corner offsets to progress fractions. All static, no scene.

const START_POS := Vector2(0.0, 0.0)
const START_HEADING := Vector2(0.0, 1.0)
const _TGP = preload("res://scripts/track_gen_params.gd")


# A dead-straight centerline along +Y, so a corner entry at (0, y) sits at offset ~y.
func _straight_curve(length: float) -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(0.0, length))
	return c


func _piece(corner: String, flip: bool, entry_y: float, straight: float) -> Dictionary:
	return {
		"corner": corner,
		"flip": flip,
		"entry_pos": Vector2(0.0, entry_y),
		"entry_heading": Vector2(0.0, 1.0),
		"straight": straight,
	}


func _generate(seed_value: int, turns: int = 12, width: float = 6.0) -> Dictionary:
	return await TrackGenerator.generate(
		_TGP.of(START_POS, START_HEADING, seed_value, turns, width, 0.0, 0.0, 0.0, 0.0))


# --- build() -----------------------------------------------------------------

func test_build_notes_every_corner_and_skips_straights() -> void:
	var curve := _straight_curve(100.0)
	var pieces := [
		_piece("Straight", false, 0.0, 0.0),   # not a turn -> no note
		_piece("3", false, 0.0, 10.0),          # corner entry at y=10
		_piece("6", true, 20.0, 5.0),           # gentle 6 STILL gets a note (unlike signs)
		_piece("Hairpin", true, 40.0, 5.0),
	]
	var notes := Pacenotes.build(curve, pieces)
	assert_eq(notes.size(), 3, "one note per non-straight piece")
	assert_eq(String(notes[0]["corner"]), "3", "first note is the 3")
	assert_eq(String(notes[1]["corner"]), "6", "gentle 6 is called too")
	assert_true(bool(notes[1]["flip"]), "flip carried through")
	assert_almost_eq(float(notes[0]["offset_m"]), 10.0, 0.5, "corner entry = after the straight")
	assert_almost_eq(float(notes[2]["offset_m"]), 45.0, 0.5, "hairpin entry at 40+5")


func test_build_offsets_ascend_along_track() -> void:
	var curve := _straight_curve(100.0)
	var pieces := [
		_piece("1", false, 0.0, 5.0),
		_piece("2", false, 20.0, 5.0),
		_piece("4", false, 60.0, 5.0),
	]
	var notes := Pacenotes.build(curve, pieces)
	for i in range(1, notes.size()):
		assert_gt(float(notes[i]["offset_m"]), float(notes[i - 1]["offset_m"]),
			"note %d is further along than the previous" % i)


func test_build_empty_for_null_or_degenerate_centerline() -> void:
	assert_eq(Pacenotes.build(null, [_piece("1", false, 0.0, 0.0)]).size(), 0,
		"null centerline -> no notes")
	assert_eq(Pacenotes.build(Curve2D.new(), [_piece("1", false, 0.0, 0.0)]).size(), 0,
		"zero-length centerline -> no notes")


# --- arrow_key(): TRUE direction, no oncoming-facing inversion ---------------

func test_arrow_key_matches_the_sign_direction_convention() -> void:
	# The chase camera flips the 2D track's left/right on screen — the same inversion
	# the roadside boards bake in — so the HUD uses the SAME dir mapping as the signs
	# (a left-hand corner, flip=true, takes the "right"-keyed art), not the opposite.
	assert_eq(Pacenotes.arrow_key("1", true), "arrow_1_right", "flip=true -> right-keyed art")
	assert_eq(Pacenotes.arrow_key("1", false), "arrow_1_left", "flip=false -> left-keyed art")
	assert_eq(Pacenotes.arrow_key("5", false), "arrow_5_left", "gentle 5 has its own board")
	assert_eq(Pacenotes.arrow_key("6", true), "arrow_6_right", "gentle 6 has its own board")
	assert_eq(Pacenotes.arrow_key("Square", true), "arrow_square_right", "square glyph")
	assert_eq(Pacenotes.arrow_key("Hairpin", false), "arrow_uturn_left", "hairpin glyph")


func test_arrow_key_agrees_with_the_signs_for_shared_shapes() -> void:
	# Lock the intent: HUD and roadside signs read the same way, so their direction
	# mapping is identical for every shape the signs also plant.
	for corner in ["1", "2", "3", "4", "Square", "Hairpin"]:
		for flip in [false, true]:
			assert_eq(Pacenotes.arrow_key(corner, flip), SignLayout._arrow_key(corner, flip),
				"HUD arrow for %s (flip=%s) matches the sign" % [corner, flip])


func test_arrow_key_compound_reuses_entry_grade_art() -> void:
	assert_eq(Pacenotes.arrow_key("Right 4 tightens 2", false), "arrow_4_left",
		"compound corner reuses its entry-grade (4) board")
	assert_eq(Pacenotes.arrow_key("Right 4 tightens 2", true), "arrow_4_right",
		"compound corner, left-hand")


# --- notes_to_fracs() --------------------------------------------------------

func test_notes_to_fracs_maps_offset_over_span_from_start_line() -> void:
	var notes := [{"offset_m": 0.0}, {"offset_m": 50.0}, {"offset_m": 100.0}]
	# A lead-in of 10 m ahead of the track shifts both offset and span.
	var fracs := Pacenotes.notes_to_fracs(notes, 10.0, 110.0)
	assert_eq(fracs.size(), 3, "one fraction per note")
	assert_almost_eq(float(fracs[0]), 10.0 / 110.0, 1e-4, "entry at start + lead-in")
	assert_almost_eq(float(fracs[1]), 60.0 / 110.0, 1e-4, "mid entry")
	assert_almost_eq(float(fracs[2]), 1.0, 1e-4, "last entry clamps to the finish")


func test_notes_to_fracs_empty_when_span_non_positive() -> void:
	assert_eq(Pacenotes.notes_to_fracs([{"offset_m": 5.0}], 0.0, 0.0).size(), 0,
		"no span -> no fractions")


# --- against a real generated track ------------------------------------------

func test_build_against_generated_track_covers_every_corner() -> void:
	var r := await _generate(7, 12)
	var notes := Pacenotes.build(r["centerline"], r["pieces"])
	var corners := 0
	for piece in r["pieces"]:
		if not Pacenotes.SKIP_CORNERS.has(String(piece["corner"])):
			corners += 1
	assert_gt(corners, 0, "the generated track has corners to call")
	assert_eq(notes.size(), corners, "a note per non-straight piece")


func test_every_note_arrow_key_resolves_in_the_texture_atlas() -> void:
	# Guards the 5/6 boards are baked + registered: every corner the generator can
	# place must map to a key that exists in the sign texture atlas.
	var r := await _generate(3, 14)
	for n in Pacenotes.build(r["centerline"], r["pieces"]):
		var key := Pacenotes.arrow_key(String(n["corner"]), bool(n["flip"]))
		assert_true(Config.data.sign_textures.has(key),
			"arrow key %s (corner %s) is registered in sign_textures" % [key, n["corner"]])

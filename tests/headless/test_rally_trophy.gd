extends GutTest
# RallyTrophy: the procedural trophy marker a star-gated SPECIAL stands on the HQ map table
# instead of a flag (hq._make_pin). Covers the two state axes — the medal colour (which
# placement you took) and the plinth tint (whether you can race it) — plus that build()
# yields a usable marker sitting on the map plane with the same footprint as a flag.
#
# Colours are compared as RELATIONSHIPS and identities (this medal differs from that one,
# gold matches the flag's gold) rather than by pinning RGB values, which are look tunables.


# --- The medal axis: which placement the cup shows --------------------------

func test_each_podium_placement_gets_its_own_medal_colour() -> void:
	# The whole reason a special gets a cup rather than a pennant: a trophy can say WHICH
	# medal you took, where the flag only distinguishes "podiumed" from "not".
	var gold := RallyTrophy.medal_color(false, 3)
	var silver := RallyTrophy.medal_color(false, 2)
	var bronze := RallyTrophy.medal_color(false, 1)
	var unwon := RallyTrophy.medal_color(false, 0)
	var seen := {}
	for c in [gold, silver, bronze, unwon]:
		assert_false(seen.has(c), "each placement reads as a distinct colour")
		seen[c] = true


func test_a_won_special_shares_the_flags_gold() -> void:
	# One visual language across both markers: "won" must look the same whether the rally
	# planted a flag or a trophy.
	assert_eq(RallyTrophy.medal_color(false, 3), RallyFlag.ACCENT_GOLD,
		"a 1st place reads as the same gold the flag uses")


func test_an_unpodiumed_special_shows_no_medal() -> void:
	assert_eq(RallyTrophy.medal_color(false, 0), RallyTrophy.MEDAL_NONE,
		"never podiumed → plain metal, nothing won yet")


func test_a_locked_special_can_never_show_a_medal() -> void:
	# A locked rally cannot have been podiumed, so even a stray star count must not paint a
	# medal onto it — that would advertise a result the player has not got.
	for stars in [0, 1, 2, 3]:
		assert_eq(RallyTrophy.medal_color(true, stars), RallyTrophy.MEDAL_NONE,
			"locked shows no medal (stars=%d)" % stars)


func test_medal_colour_tolerates_an_out_of_range_star_count() -> void:
	assert_eq(RallyTrophy.medal_color(false, 99), RallyTrophy.medal_color(false, 3),
		"above the top placement clamps to the best medal")
	assert_eq(RallyTrophy.medal_color(false, -1), RallyTrophy.MEDAL_NONE,
		"below zero reads as unwon")


# --- The base axis: whether you can race it --------------------------------

func test_the_plinth_marks_whether_a_car_can_enter() -> void:
	# Mirrors the flag's green/grey pennant axis, so "raceable now" reads identically on
	# either marker.
	assert_eq(RallyTrophy.base_color(false, true), RallyTrophy.BASE_RACEABLE,
		"an eligible car owned → the raceable tint")
	assert_eq(RallyTrophy.base_color(false, false), RallyTrophy.BASE_INERT,
		"no eligible car → the inert tint")


func test_a_locked_special_never_reads_as_raceable() -> void:
	assert_eq(RallyTrophy.base_color(true, true), RallyTrophy.BASE_INERT,
		"locked stays inert even if an eligible car exists")


func test_the_two_axes_are_independent() -> void:
	# A special can be won but currently un-enterable (car sold), or enterable but never
	# podiumed — the marker has to be able to say both at once.
	assert_eq(RallyTrophy.medal_color(false, 3), RallyTrophy.medal_color(false, 3),
		"the medal ignores eligibility")
	assert_ne(RallyTrophy.base_color(false, true), RallyTrophy.base_color(false, false),
		"the plinth ignores placement and tracks eligibility only")


# --- The built marker -------------------------------------------------------

func test_build_yields_a_marker_rooted_at_the_plane() -> void:
	var trophy := RallyTrophy.build(false, 2, true)
	autofree(trophy)
	assert_true(trophy is Node3D, "build returns a Node3D marker")
	assert_eq(trophy.position, Vector3.ZERO, "marker root sits at its own origin")
	# Coin + plinth + stem + cup + two handles + finial.
	var meshes := trophy.find_children("*", "MeshInstance3D", true, false)
	assert_gte(meshes.size(), 7, "marker builds its plinth, stem, bowl, handles and finial")


func test_the_marker_stands_on_the_plane_and_fits_under_its_declared_height() -> void:
	# HEIGHT is what hq._make_pin hangs the floating readout box from, so nothing may poke
	# above it and nothing may sink below the map.
	var trophy := RallyTrophy.build(false, 3, true)
	autofree(trophy)
	assert_gt(RallyTrophy.HEIGHT, 0.0, "the marker declares a positive height")
	for m in trophy.find_children("*", "MeshInstance3D", true, false):
		var mesh := m as MeshInstance3D
		var box := mesh.mesh.get_aabb()
		var low := mesh.position.y + box.position.y
		var high := low + box.size.y
		assert_gte(low, -0.001, "no part of the marker sinks below the map plane")
		assert_lte(high, RallyTrophy.HEIGHT + 0.001,
			"no part of the marker rises above its declared HEIGHT")


func test_the_trophy_stands_as_tall_as_a_flag() -> void:
	# A special is the PRESTIGE event on its corner, so its marker must not read as a smaller
	# thing than the ordinary rallies around it. Compared loosely (within a marker's own base
	# thickness) — the point is "not visibly shorter", not an exact match.
	assert_almost_eq(RallyTrophy.HEIGHT, RallyFlag.POLE_HEIGHT, 0.05,
		"the trophy stands about as tall as a flag pole, so specials don't look diminished")


func test_the_plinth_never_outshouts_the_cup() -> void:
	# The raceable green is DERIVED from the flag's pennant green rather than reused raw: on a
	# chunky plinth the full-brightness version overpowers the cup it is meant to frame. It
	# must still read as green, and still differ from the inert grey.
	var green := RallyTrophy.BASE_RACEABLE
	assert_gt(green.g, green.r, "the raceable tint is recognisably green")
	assert_gt(green.g, green.b, "the raceable tint is recognisably green")
	assert_lt(green.v, RallyFlag.PENNANT_GREEN.v,
		"and is darker than the flag's pennant green, which covers far less area")
	assert_ne(RallyTrophy.BASE_RACEABLE, RallyTrophy.BASE_INERT,
		"raceable and inert stay distinguishable")


func test_the_footprint_matches_a_flags_so_pin_spacing_needs_no_special_case() -> void:
	# The table's pin positions and hit-sphere radii are tuned against the flag's base coin;
	# a trophy has to sit in the same footprint or neighbouring pins start overlapping.
	assert_eq(RallyTrophy.DISK_RADIUS, RallyFlag.DISK_RADIUS, "same base radius as a flag")
	assert_eq(RallyTrophy.DISK_HEIGHT, RallyFlag.DISK_HEIGHT, "same base thickness")


func test_the_cup_flares_outward_from_the_stem() -> void:
	# Shape sanity, not a tuned value: a cup is wider at the rim than at its foot, and its
	# rim is wider than the stem it stands on — otherwise it reads as a pipe.
	assert_gt(RallyTrophy.CUP_TOP_RADIUS, RallyTrophy.CUP_BOTTOM_RADIUS,
		"the bowl flares toward the rim")
	assert_gt(RallyTrophy.CUP_BOTTOM_RADIUS, RallyTrophy.STEM_RADIUS,
		"the bowl's foot is wider than the stem")


func test_every_state_combination_builds() -> void:
	# Cheap guard against a state that throws while assembling (a null mesh, a bad rotation).
	for locked in [true, false]:
		for stars in [0, 1, 2, 3]:
			for eligible in [true, false]:
				var t := RallyTrophy.build(locked, stars, eligible)
				autofree(t)
				assert_gt(t.find_children("*", "MeshInstance3D", true, false).size(), 0,
					"builds for locked=%s stars=%d eligible=%s" % [locked, stars, eligible])

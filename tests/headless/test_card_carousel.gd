extends GutTest
# CardCarousel (scripts/card_carousel.gd) — the shared horizontal card-list widget
# used by the hub's MAIN/REGION/CAR/SHOP/PERKS pages. Covers selection/confirm signals,
# tap-to-select vs tap-to-confirm, and the nearest-card snap the drag path uses — NOT
# any page's wording/content, which belongs to test_hub_shell.gd instead.

var _carousel: CardCarousel


func before_each() -> void:
	_carousel = CardCarousel.new()
	add_child_autofree(_carousel)
	_carousel.size = Vector2(800, 300)
	for i in 4:
		var card := _carousel.add_card(i == 2)  # card 2 is disabled, like a locked row
		card.info.add_child(UITheme.label("Card %d" % i))
	await get_tree().process_frame


func test_starts_selected_on_the_first_card() -> void:
	assert_eq(_carousel.selected_index(), 0)


# Regression: the carousel used to declare a minimum HEIGHT only, so a MenuPage body box
# (which hugs its content's minimum WIDTH — menu_page.gd) squeezed it down to whatever its
# narrowest sibling needed, clipping every card down to a sliver that read as "a list
# scrolling inside one card" instead of cards sitting side by side. The carousel must
# claim real width on its own, regardless of what it's placed inside.
func test_declares_a_minimum_width_wide_enough_to_peek_neighbours() -> void:
	var fresh := CardCarousel.new()
	add_child_autofree(fresh)
	var expected := Config.data.card_carousel_card_width * Config.data.card_carousel_visible_width_factor
	assert_almost_eq(fresh.get_combined_minimum_size().x, expected, 0.01)
	assert_gt(fresh.get_combined_minimum_size().x, Config.data.card_carousel_card_width,
		"must be wider than a single card, or neighbours never peek into view")


# fit_to_available_width is what a host calls to make the carousel run edge to edge
# instead of the default couple-of-peeks width — it must round DOWN to a whole, ODD
# number of cards, never leave a fractional remainder that would clip a card in half at
# the visible edge (the strip always centres the selected card, so only an odd visible
# count keeps an equal number of whole cards on both sides).
func test_fit_to_available_width_uses_a_whole_odd_number_of_cards() -> void:
	var unit: float = Config.data.card_carousel_card_width + Config.data.card_carousel_gap
	# Exactly 4 units of room: only 3 cards (the next odd number down) may fit, not 4.
	_carousel.fit_to_available_width(unit * 4.0)
	var width := _carousel.custom_minimum_size.x
	var shown := int(round((width + Config.data.card_carousel_gap) / unit))
	assert_eq(shown % 2, 1, "an even visible count clips a card in half at one edge")
	assert_true(width < unit * 4.0, "must not claim more than what was actually offered")


func test_fit_to_available_width_never_returns_less_than_one_card() -> void:
	_carousel.fit_to_available_width(1.0)
	assert_almost_eq(_carousel.custom_minimum_size.x, Config.data.card_carousel_card_width, 0.01)


# Regression: every UITheme panel (cards included) is solid black, sitting on the ALSO
# solid black MenuPage body box — a card with no border is optically indistinguishable
# from both the gap beside it and the body panel behind it, and modulate.a dimming does
# nothing visible on black-on-black. Without an outline the whole strip reads as one fused
# black slab ("all cards joined into one"), not a row of separate cards, regardless of how
# wide the gap between them is. Every card must carry a real border, and the selected one
# a distinctly different one, so cardhood and selection are both visible independent of
# whatever else sits behind the carousel.
func test_every_card_has_a_visible_border_and_selection_changes_it() -> void:
	for card in _carousel._cards:
		var box: StyleBox = card.root.get_theme_stylebox("panel")
		assert_true(box is StyleBoxFlat, "a card needs a real stylebox to carry a border")
		var flat := box as StyleBoxFlat
		assert_gt(flat.border_width_left, 0, "an unbordered card is invisible against the black body box")

	_carousel.select(1, false)
	var selected_box: StyleBoxFlat = _carousel._cards[1].root.get_theme_stylebox("panel")
	var other_box: StyleBoxFlat = _carousel._cards[0].root.get_theme_stylebox("panel")
	assert_ne(selected_box.border_color, other_box.border_color,
		"the centred card's border must read as distinct from an unselected one")


func test_menu_nav_handles_side_moves_selection_and_emits_changed() -> void:
	var seen: Array = []
	_carousel.selection_changed.connect(func(i): seen.append(i))
	_carousel.select(0, false)
	seen.clear()
	assert_true(_carousel.menu_nav_handles_side(SIDE_RIGHT))
	assert_eq(_carousel.selected_index(), 1)
	assert_eq(seen, [1])
	assert_true(_carousel.menu_nav_handles_side(SIDE_LEFT))
	assert_eq(_carousel.selected_index(), 0)


func test_menu_nav_handles_side_only_owns_left_and_right() -> void:
	assert_false(_carousel.menu_nav_handles_side(SIDE_TOP),
		"up/down must fall through to normal focus-neighbour movement")
	assert_false(_carousel.menu_nav_handles_side(SIDE_BOTTOM))


func test_select_clamps_to_the_card_range() -> void:
	_carousel.select(-5, false)
	assert_eq(_carousel.selected_index(), 0)
	_carousel.select(999, false)
	assert_eq(_carousel.selected_index(), 3)


func test_confirm_fires_for_an_enabled_card() -> void:
	var confirmed: Array = []
	_carousel.confirmed.connect(func(i): confirmed.append(i))
	_carousel.select(0, false)
	_carousel._confirm_selected()
	assert_eq(confirmed, [0])


func test_confirm_does_not_fire_for_a_disabled_card() -> void:
	var confirmed: Array = []
	_carousel.confirmed.connect(func(i): confirmed.append(i))
	_carousel.select(2, false)  # the disabled card
	_carousel._confirm_selected()
	assert_true(confirmed.is_empty(), "a locked/disabled card must not confirm")


# Tapping a NON-CENTRED card moves the selection toward it rather than confirming —
# only the already-centred card confirms on tap.
func test_tapping_a_non_centred_card_selects_it_instead_of_confirming() -> void:
	var confirmed: Array = []
	_carousel.confirmed.connect(func(i): confirmed.append(i))
	_carousel.select(0, false)
	_carousel._tap_card(1)
	assert_eq(_carousel.selected_index(), 1, "tapping card 1 moves selection to it")
	assert_true(confirmed.is_empty(), "and does not confirm")


func test_tapping_the_already_centred_card_confirms() -> void:
	var confirmed: Array = []
	_carousel.confirmed.connect(func(i): confirmed.append(i))
	_carousel.select(0, false)
	_carousel._tap_card(0)
	assert_eq(confirmed, [0], "tapping the centred card confirms it")


# Drag-and-release snaps to the NEAREST card rather than leaving the strip parked
# between two of them.
# Regression: a touch press was recorded LOCAL TO THE PRESSED CARD (_on_card_gui_input is
# bound to that card's own gui_input signal) while the drag handler reads
# InputEventScreenDrag.position LOCAL TO THE CAROUSEL (_gui_input is the carousel's own
# override) — comparing those two different local frames produced a bogus delta on the
# very first drag sample, as large as the distance between the pressed card and the
# carousel's own local origin. Reported symptom: starting a touch swipe on the peeking
# card next to the first (selected) card made the whole strip jump immediately.
func test_touch_drag_tracks_the_real_finger_delta_not_a_coordinate_mismatch() -> void:
	_carousel.select(0, false)
	await get_tree().process_frame
	var card1: Control = _carousel._cards[1].root
	var local_press := Vector2(10.0, 10.0)
	var press := InputEventScreenTouch.new()
	press.pressed = true
	press.position = local_press
	_carousel._on_card_gui_input(press, 1)

	# The SAME physical point, moved 5px left in real (global) screen space — expressed,
	# as Godot would actually deliver it, local to the CAROUSEL rather than to card1.
	var real_delta := 5.0
	var global_press: Vector2 = card1.get_global_transform() * local_press
	var global_now := global_press - Vector2(real_delta, 0.0)
	var carousel_local_now: Vector2 = _carousel.get_global_transform().affine_inverse() * global_now
	var drag := InputEventScreenDrag.new()
	drag.position = carousel_local_now
	_carousel._gui_input(drag)

	assert_almost_eq(_carousel._offset, real_delta, 0.5,
		"a 5px finger movement must move the strip by about 5px, not jump")


func test_drag_release_snaps_to_the_nearest_card() -> void:
	var target := _carousel._target_offset_for(0)
	var step := _carousel._target_offset_for(1) - target
	_carousel._offset = target + step * 0.6  # past the halfway point toward card 1
	_carousel.end_drag_and_snap()
	assert_eq(_carousel.selected_index(), 1, "closer to card 1 than card 0")


func test_drag_release_snaps_back_when_short_of_the_next_card() -> void:
	var target := _carousel._target_offset_for(0)
	var step := _carousel._target_offset_for(1) - target
	_carousel._offset = target + step * 0.3  # short of the halfway point
	_carousel.end_drag_and_snap()
	assert_eq(_carousel.selected_index(), 0, "still closer to card 0")


func test_unselected_cards_are_dimmed_and_selected_is_opaque() -> void:
	_carousel.select(1, false)
	for i in _carousel.card_count():
		var expected := 1.0 if i == 1 else Config.data.card_carousel_unselected_alpha
		assert_almost_eq(_carousel._cards[i].root.modulate.a, expected, 0.001)

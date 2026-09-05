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

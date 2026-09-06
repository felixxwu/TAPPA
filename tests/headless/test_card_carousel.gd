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


# visible_card_count is what a host with an expensive per-card visual (a live 3D preview,
# say — see hub_shell.gd's _refresh_car_previews) uses to decide how many it can afford to
# keep built at once. It must reflect whatever fit_to_available_width actually decided,
# not some independent guess.
func test_visible_card_count_matches_what_fit_to_available_width_decided() -> void:
	var unit: float = Config.data.card_carousel_card_width + Config.data.card_carousel_gap
	_carousel.fit_to_available_width(unit * 4.0)
	var width := _carousel.custom_minimum_size.x
	var expected := int(round((width + Config.data.card_carousel_gap) / unit))
	assert_eq(_carousel.visible_card_count(), expected)


func test_get_card_returns_the_same_handle_add_card_returned() -> void:
	var card := _carousel.add_card()
	assert_eq(_carousel.get_card(_carousel.card_count() - 1), card)


# Cards used to carry an accent border (selected vs. unselected) so a card would read as
# a distinct shape against the ALSO-solid-black MenuPage body box behind it. That's no
# longer needed now that the five carousel pages sit on a TRANSPARENT body box (the gaps
# show the live 3D showcase) — a card's own opaque fill already reads as distinct against
# that busier background — and the border was removed on request, for both states.
func test_no_card_has_a_border_selected_or_not() -> void:
	for card in _carousel._cards:
		var box: StyleBox = card.root.get_theme_stylebox("panel")
		assert_true(box is StyleBoxFlat, "a card needs a real stylebox for its fill")
		var flat := box as StyleBoxFlat
		assert_eq(flat.border_width_left, 0, "no card should carry a border")

	_carousel.select(1, false)
	var selected_box: StyleBoxFlat = _carousel._cards[1].root.get_theme_stylebox("panel")
	assert_eq(selected_box.border_width_left, 0, "the selected card must not grow a border either")


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


# Regression: _drag_active was only ever armed inside _on_card_gui_input, bound to each
# CARD's own gui_input signal — a press/drag starting on the carousel's own background
# (the space between/around cards, genuinely reachable now that the page behind it is
# transparent) never reached that handler, so a drag started off any card silently did
# nothing at all. _gui_input (the carousel's own override, which DOES receive a press
# landing on empty space) must arm the same drag state.
func test_dragging_from_the_background_between_cards_still_pans_the_strip() -> void:
	_carousel.select(0, false)
	await get_tree().process_frame
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.global_position = Vector2(50.0, 50.0)
	_carousel._gui_input(press)
	assert_true(_carousel._drag_active, "a background press must arm the drag")

	var motion := InputEventMouseMotion.new()
	motion.global_position = Vector2(45.0, 50.0)
	_carousel._gui_input(motion)
	assert_almost_eq(_carousel._offset, 5.0, 0.01,
		"a background-started drag must pan the strip like a card-started one")

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.global_position = motion.global_position
	_carousel._gui_input(release)
	assert_false(_carousel._drag_active, "release must clear the drag even off any card")


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


# The snap must VISIBLY travel. Regression: _snap_to animated _offset with
# tween_property but only re-ran _layout from a step_finished connection — and
# step_finished fires when a step COMPLETES (once, after the full duration), never
# per frame — so the cards sat frozen for the whole snap and teleported at the end
# (reported as "the snap is immediate, no animation between where the list is and the
# end of the snap"). tween_method now drives offset AND layout every frame, so
# mid-snap a card's real position must already sit between where the strip started and
# where it lands. (--fixed-fps 60 in run_tests.sh makes frame counts deterministic:
# 0.22s is ~13 frames, so two frames in is safely mid-flight.)
func test_snap_travels_through_intermediate_positions_before_landing() -> void:
	_carousel.select(0, false)
	await get_tree().process_frame
	var card1: Control = _carousel._cards[1].root
	var start_x := card1.position.x

	_carousel.select(1, true)
	await get_tree().process_frame
	await get_tree().process_frame
	var mid_x := card1.position.x
	assert_lt(mid_x, start_x, "mid-snap the card must already be travelling toward the centre")
	assert_true(_carousel._tween != null and _carousel._tween.is_running(),
			"the snap tween must still be in flight two frames into a 0.22s snap")

	while _carousel._tween != null and _carousel._tween.is_running():
		await get_tree().process_frame
	assert_almost_eq(_carousel._offset, _carousel._target_offset_for(1), 0.5,
			"the strip must land exactly on the selected card's offset")
	assert_lt(card1.position.x, mid_x, "and it must still be travelling past the sampled frame")


# A re-grab mid-snap must take the strip over from the tween: the snap now writes
# _offset every frame, so a tween left running under an active drag would fight the
# finger for the same value — the strip pulling itself toward the old target while the
# drag pulls it elsewhere. _begin_drag kills the tween first, so the drag owns the
# offset from exactly where the snap had reached (and the next snap animates from there).
func test_starting_a_drag_mid_snap_kills_the_running_snap() -> void:
	_carousel.select(0, false)
	await get_tree().process_frame
	_carousel.select(3, true)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.global_position = Vector2(50.0, 50.0)
	_carousel._gui_input(press)
	assert_true(_carousel._tween == null or not _carousel._tween.is_valid(),
			"a press must kill the running snap tween rather than fight the finger")
	var motion := InputEventMouseMotion.new()
	motion.global_position = Vector2(40.0, 50.0)
	_carousel._gui_input(motion)
	assert_almost_eq(_carousel._offset, 10.0, 0.01,
			"the drag must own the offset from wherever the snap had reached")


func test_unselected_cards_are_dimmed_and_selected_is_opaque() -> void:
	_carousel.select(1, false)
	for i in _carousel.card_count():
		var expected := 1.0 if i == 1 else Config.data.card_carousel_unselected_alpha
		assert_almost_eq(_carousel._cards[i].root.modulate.a, expected, 0.001)


# Regression: card.root is an absolute-positioned child of a plain (non-layout) Control,
# so nothing caps its size — an unwrapped long label (a region's "Locked — clear <gate>"
# subtitle was the real case) reports its full text width as its minimum size and grows
# the card past card_carousel_card_width, overlapping the neighbour sitting at the next
# fixed index*unit offset. A label added to visual/info must come out autowrapping so it
# never forces the card wider, regardless of how long the caller's text is.
func test_a_long_unwrapped_label_does_not_grow_the_card_past_card_width() -> void:
	var card := _carousel.add_card()
	var long_label := Label.new()
	long_label.text = "Locked — clear a very long region name that would never fit on one line"
	card.info.add_child(long_label)
	await get_tree().process_frame
	assert_eq(long_label.autowrap_mode, TextServer.AUTOWRAP_WORD_SMART,
		"an incoming label must be forced to wrap")
	assert_lte(card.root.get_combined_minimum_size().x, Config.data.card_carousel_card_width + 0.5,
		"a long label must not push the card wider than card_width")


# Regression: wrapping a long label (the fix above) trades width for height — several
# SHORT lines instead of one LONG one. card.info used to be a plain VBoxContainer with no
# height cap of its own, so that taller wrapped content could push col's, and so
# card.root's, combined minimum height past card_carousel_aspect * card_width, growing
# the whole card downward past its own border — reported as "the visual part pushes
# everything else down past the bottom of the card".
func test_many_wrapped_info_lines_do_not_grow_the_card_past_card_height() -> void:
	var card := _carousel.add_card()
	for i in 6:
		var lbl := Label.new()
		lbl.text = "A fairly long line of card info text number %d that wants to wrap" % i
		card.info.add_child(lbl)
	await get_tree().process_frame
	var expected_h := Config.data.card_carousel_card_width * Config.data.card_carousel_aspect
	assert_lte(card.root.get_combined_minimum_size().y, expected_h + 0.5,
		"a long info section must not push the card taller than its own height")


# Regression: every Control defaults to MOUSE_FILTER_STOP, so a caller's decorative
# content in card.visual (an icon, a CarCardPreview) swallowed a tap before Godot's own
# PASS-filter bubbling could ever carry it up to card.root's gui_input — reported as
# "touch targets don't work for the visual upper half" (the bottom half worked, since
# Label already defaults to MOUSE_FILTER_IGNORE). Godot's own input propagation isn't
# something a headless unit test can drive directly, so this pins the actual mechanism the
# fix relies on: nothing added to visual/info may capture input in its own right — and,
# separately, that the real destination (card.root's gui_input, already exercised by the
# tap/confirm tests above) is unaffected by that.
func test_content_added_to_visual_or_info_never_captures_its_own_input() -> void:
	var card := _carousel.add_card()
	var icon := ColorRect.new()
	card.visual.add_child(icon)
	var readout := Label.new()
	card.info.add_child(readout)
	await get_tree().process_frame
	assert_eq(icon.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"a card's own visual content must not capture the tap meant for the whole card")
	assert_eq(readout.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"info content must stay transparent to input too, for the same reason")
	assert_eq(card.visual.mouse_filter, Control.MOUSE_FILTER_PASS,
		"the SLOT itself must still let the tap through to card.root")

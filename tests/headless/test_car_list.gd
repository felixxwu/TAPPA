extends GutTest
# CarList (scripts/car_list.gd): the car park's paginated list. Pure paging LOGIC —
# wrap on a single page, auto page-flip at page boundaries, and a global wrap at the
# ring's ends. Uses synthetic item lists (plain dicts), never the real catalogue, so
# it tests the behaviour that must hold for ANY list, not any authored roster.

# A list of `n` trivially-distinguishable items ({"i": 0}, {"i": 1}, …).
func _items(n: int) -> Array:
	var a: Array = []
	for i in n:
		a.append({"i": i})
	return a


func test_empty_list_is_inert() -> void:
	var cl := CarList.new()
	cl.setup([], 10)
	assert_true(cl.is_empty(), "no items")
	assert_eq(cl.total(), 0, "total is zero")
	assert_eq(cl.page_count(), 1, "an empty list still reports one page")
	assert_eq(cl.page_items(), [], "no page items")
	assert_eq(cl.focused(), {}, "no focused car")
	assert_false(cl.advance(1), "advancing an empty list never flips a page")


func test_single_page_wraps_within_itself() -> void:
	var cl := CarList.new()
	cl.setup(_items(3), 10)  # 3 items, 10 bays -> one page
	assert_eq(cl.page_count(), 1, "3 items in 10 bays is a single page")
	assert_false(cl.has_multiple_pages(), "single page")
	assert_eq(cl.page_items().size(), 3, "all three items show on the page")
	assert_eq(cl.global_index(), 0, "starts on the first car")
	# Forward through the page, then wrap back to the start (no page flip on a single page).
	assert_false(cl.advance(1), "moving within the page doesn't flip a page")
	assert_eq(cl.global_index(), 1, "moved to the second car")
	cl.advance(1)
	assert_eq(cl.global_index(), 2, "moved to the third (last) car")
	assert_false(cl.advance(1), "past the end on a single page stays on the page")
	assert_eq(cl.global_index(), 0, "past the end wraps to the first car")
	# And backward from the first wraps to the last.
	assert_false(cl.advance(-1), "before the start on a single page stays on the page")
	assert_eq(cl.global_index(), 2, "before the start wraps to the last car")


func test_multi_page_flips_pages_at_boundaries() -> void:
	var cl := CarList.new()
	cl.setup(_items(25), 10)  # 25 items, 10 per page -> 3 pages (10 / 10 / 5)
	assert_eq(cl.page_count(), 3, "25 items in pages of 10 is three pages")
	assert_true(cl.has_multiple_pages(), "multiple pages")
	assert_eq(cl.page, 0, "starts on page 0")
	assert_eq(cl.page_items().size(), 10, "page 0 is full")

	# Step to the last car of page 0, then one more flips to page 1's first car.
	cl.seat_global(9)
	assert_eq(cl.page, 0, "index 9 is still on page 0")
	assert_true(cl.advance(1), "stepping past the page boundary flips the page")
	assert_eq(cl.page, 1, "now on page 1")
	assert_eq(cl.global_index(), 10, "focus is the first car of page 1")
	assert_eq(cl.focus, 0, "focus is local index 0 on the new page")

	# Backward across the boundary returns to page 0's last car.
	assert_true(cl.advance(-1), "stepping back past the boundary flips the page")
	assert_eq(cl.page, 0, "back on page 0")
	assert_eq(cl.global_index(), 9, "focus is page 0's last car")

	# The short final page holds the remainder.
	cl.seat_global(24)
	assert_eq(cl.page, 2, "the last item is on the final page")
	assert_eq(cl.page_items().size(), 5, "the final page holds the 5 remaining cars")


func test_global_wrap_across_all_pages() -> void:
	var cl := CarList.new()
	cl.setup(_items(25), 10)
	# From the very last car, forward wraps to the very first (page 2 -> page 0).
	cl.seat_global(24)
	assert_true(cl.advance(1), "wrapping off the last car flips back to the first page")
	assert_eq(cl.page, 0, "wrapped to page 0")
	assert_eq(cl.global_index(), 0, "wrapped to the first car")
	# From the first car, backward wraps to the very last (page 0 -> page 2).
	assert_true(cl.advance(-1), "wrapping before the first car flips to the last page")
	assert_eq(cl.page, 2, "wrapped to the final page")
	assert_eq(cl.global_index(), 24, "wrapped to the last car")


func test_setup_seats_on_a_given_start_index() -> void:
	var cl := CarList.new()
	cl.setup(_items(25), 10, 13)  # seat on global 13 -> page 1, local focus 3
	assert_eq(cl.page, 1, "start index lands on the right page")
	assert_eq(cl.focus, 3, "start index lands on the right local focus")
	assert_eq(cl.global_index(), 13, "global index matches the requested start")
	assert_eq(int(cl.focused()["i"]), 13, "the focused car is the requested one")


func test_page_size_one_makes_every_item_its_own_page() -> void:
	var cl := CarList.new()
	cl.setup(_items(3), 1)  # one bay: each car is its own page
	assert_eq(cl.page_count(), 3, "3 items at 1 per page is three pages")
	assert_eq(cl.page_items().size(), 1, "one car parked at a time")
	assert_true(cl.advance(1), "every advance flips a page when the page holds one car")
	assert_eq(cl.global_index(), 1, "advanced to the second car")
	assert_true(cl.advance(1), "still flipping pages")
	assert_eq(cl.global_index(), 2, "advanced to the third car")
	assert_true(cl.advance(1), "past the end flips (and wraps) to the first page")
	assert_eq(cl.global_index(), 0, "wrapped to the first car")


func test_multi_step_advance_crosses_pages() -> void:
	var cl := CarList.new()
	cl.setup(_items(25), 10)
	assert_false(cl.advance(7), "a 7-step jump within page 0 doesn't cross a boundary")
	assert_eq(cl.page, 0, "still on page 0 after +7")
	assert_eq(cl.global_index(), 7, "landed on global 7")
	assert_true(cl.advance(7), "another +7 crosses into page 1")
	assert_eq(cl.page, 1, "now on page 1")
	assert_eq(cl.global_index(), 14, "landed on global 14")


func test_setup_start_out_of_range_wraps() -> void:
	var cl := CarList.new()
	cl.setup(_items(25), 10, 25)  # 25 is one past the end -> wraps to 0
	assert_eq(cl.global_index(), 0, "an out-of-range start wraps into range (documented as wrapped)")
	cl.setup(_items(25), 10, -1)  # before the start -> wraps to the last
	assert_eq(cl.global_index(), 24, "a negative start wraps to the last car")


func test_focus_local_moves_within_page_only() -> void:
	var cl := CarList.new()
	cl.setup(_items(25), 10)
	cl.seat_global(10)  # page 1, focus 0
	cl.focus_local(4)
	assert_eq(cl.page, 1, "a local focus tap never changes the page")
	assert_eq(cl.global_index(), 14, "local focus 4 on page 1 is global 14")
	# Out-of-range taps clamp to the page.
	cl.focus_local(99)
	assert_eq(cl.focus, cl.page_len() - 1, "an over-range local focus clamps to the last visible car")

class_name CarList
extends RefCounted
# The car park's paginated list of cars — the single owner of "which cars, on which
# page, with the cursor where" for EVERY car-park screen (rally car-select, the garage
# picker, engine-swap, the starter picker, free roam). hq.gd owns the 3D props + camera
# framing; this helper owns the paging maths so all those screens page identically.
#
# The whole item list is treated as ONE wrapped ring. Only `page_size` items (the lot's
# painted bays, GameConfig.carpark_page_size) are shown at a time. Cycling the cursor
# left/right moves through the ring car-by-car; crossing a page boundary flips to the
# next / previous page, and cycling past the very first / last car wraps around to the
# other end. A list that fits on one page simply wraps within itself. This is generic:
# a 3-car list and a 300-car list behave the same, so there's no per-screen car cap.
#
# It holds only DATA (the car dicts + indices). Rendering, prop spawning and framing stay
# in hq.gd, which reads page_items() / focus / global_index() after each nav call. See
# features/menus.md → "Car park".

var items: Array = []      # the full car list (owned cars, previews, whatever the caller parks)
var page_size := 1         # bays per page (>= 1)
var page := 0              # current page index (0 .. page_count() - 1)
var focus := 0             # cursor position WITHIN the current page (0 .. page_len() - 1)


# Point the list at `list`, using `size` bays per page, and seat the cursor on the item
# at global index `start` (wrapped into range, via seat_global). Resets to page 0 /
# focus 0 for an empty list.
func setup(list: Array, size: int, start := 0) -> void:
	items = list
	page_size = max(1, size)
	page = 0
	focus = 0
	if not items.is_empty():
		seat_global(start)


func is_empty() -> bool:
	return items.is_empty()


func total() -> int:
	return items.size()


# How many pages the list spans (>= 1, so an empty list still reports one empty page).
func page_count() -> int:
	if items.is_empty():
		return 1
	return ceili(items.size() / float(page_size))


func has_multiple_pages() -> bool:
	return page_count() > 1


# Global index of the first item on the current page.
func page_start() -> int:
	return page * page_size


# The slice of items shown on the current page (what hq.gd spawns into the bays).
func page_items() -> Array:
	if items.is_empty():
		return []
	return items.slice(page_start(), page_start() + page_size)


# How many items sit on the current page (page_size, except a short final page). Pure
# arithmetic — no slice allocation.
func page_len() -> int:
	if items.is_empty():
		return 0
	return mini(page_size, items.size() - page_start())


# Global index of the focused item across the whole ring (0 .. total() - 1).
func global_index() -> int:
	return page_start() + focus


# The focused car dict, or {} when the list is empty.
func focused() -> Dictionary:
	if items.is_empty():
		return {}
	return items[clampi(global_index(), 0, items.size() - 1)]


# Move the cursor `step` items along the wrapped ring (± any amount; usually ±1). Returns
# true when the PAGE changed, so the caller knows to re-spawn the lineup props; false when
# the move stayed on the current page (a cheap focus repaint). No-op on an empty list.
func advance(step: int) -> bool:
	if items.is_empty():
		return false
	return seat_global(wrapi(global_index() + step, 0, items.size()))


# Seat the cursor on global index `gi` (wrapped into range), recomputing page + focus.
# Returns true when that moved to a different page. No-op on an empty list.
func seat_global(gi: int) -> bool:
	if items.is_empty():
		return false
	gi = wrapi(gi, 0, items.size())
	@warning_ignore("integer_division")  # floor division is intentional: which page holds gi
	var new_page: int = gi / page_size
	var page_changed := new_page != page
	page = new_page
	focus = gi - page_start()
	return page_changed


# Seat the cursor on a page-LOCAL index (0 .. page_len() - 1) without changing page —
# used for a pointer tap on an already-visible car. Clamped to the current page.
func focus_local(local: int) -> void:
	if page_len() == 0:
		return
	focus = clampi(local, 0, page_len() - 1)

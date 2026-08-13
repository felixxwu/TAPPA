extends GutTest
# MenuPage: the shared house page shape — a body box that HUGS its contents with a gap to
# the screen edges, plus the page's action buttons in ONE horizontal row gapped below the
# box. See scripts/menu_page.gd for why both are rules rather than per-screen choices.
#
# These tests pin the STRUCTURE those rules depend on (the box does not stretch, the
# actions are a sibling of the box and not inside it, the page insets from its parent), not
# the specific paddings/alphas — those are look tunables.


func _page(opts: Dictionary = {}) -> MenuPage:
	var page := MenuPage.new(opts)
	add_child_autofree(page)
	return page


# A MenuPage anchored full-rect inside a host of a known size. Its own size must NOT be
# assigned directly (Godot overrides the size of a node with non-equal opposite anchors after
# _ready), so a laid-out page is produced by sizing its PARENT.
func _sized_page(w: float, h: float, opts: Dictionary = {}) -> MenuPage:
	var host := Control.new()
	host.custom_minimum_size = Vector2(w, h)
	host.size = Vector2(w, h)
	add_child_autofree(host)
	var page := MenuPage.new(opts)
	host.add_child(page)
	return page


# --- Rule 1: the body box hugs its contents ---------------------------------

func test_the_body_box_does_not_stretch_to_fill_the_page() -> void:
	# The whole point: a box stretched to the viewport reads as "the app is this screen now",
	# and paints a black field over the 3D station behind it. SHRINK is what keeps it a panel
	# resting over the world.
	var page := _page()
	assert_eq(page.panel().size_flags_vertical, Control.SIZE_SHRINK_CENTER,
		"the body box hugs its content's height rather than filling the page")


func test_the_body_scroll_does_not_claim_the_spare_height() -> void:
	# Regression guard on the subtle way rule 1 gets broken: an EXPAND_FILL scroll inside the
	# box grows to all available height, which stretches the box even though the box itself
	# is SHRINK.
	var page := _page()
	var scroll: Node = page.body().get_parent()
	assert_true(scroll is ScrollContainer, "the body sits in a scroll safety net")
	assert_eq((scroll as Control).size_flags_vertical, Control.SIZE_SHRINK_CENTER,
		"the scroll must not expand, or it stretches the box it lives in")


func test_the_box_actually_takes_the_height_of_its_content() -> void:
	# THE regression that matters, and the one the size-flag assertions above cannot see: a
	# ScrollContainer reports a near-zero minimum size, so a SHRINK scroll hugs NOTHING and
	# the box renders as an empty bar with the content invisible inside it. Shipped exactly
	# that once. So measure the laid-out height against the content, not the flags.
	var page := _sized_page(400.0, 400.0)
	var rows := 0
	var wanted := 0.0
	for i in 4:
		var row := Label.new()
		row.text = "ROW %d" % i
		row.custom_minimum_size.y = 20.0
		page.body().add_child(row)
		rows += 1
		wanted += 20.0
	await get_tree().process_frame
	await get_tree().process_frame
	assert_gte(page.panel().size.y, wanted,
		"the box is at least as tall as the %d rows inside it" % rows)
	assert_gt(page.body().get_parent().size.y, 0.0,
		"the scroll holding the content has a real height, not a collapsed one")


func test_a_tall_body_is_capped_so_the_action_row_stays_on_screen() -> void:
	# The other half: past the available height the box must STOP growing and scroll its
	# content, because menu_back is Escape / gamepad B only — a touch player whose exit got
	# pushed off the bottom of a short canvas has no way out at all.
	var page := _sized_page(400.0, 200.0)
	page.add_action(UITheme.row_button("< Back", Callable()))
	for i in 40:
		var row := Label.new()
		row.text = "ROW %d" % i
		row.custom_minimum_size.y = 20.0
		page.body().add_child(row)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_lte(page.panel().size.y, page.size.y,
		"the box never grows past the page it sits in")
	var row_bottom: float = page.actions().position.y + page.actions().size.y
	assert_lte(row_bottom, page.size.y + 1.0,
		"the action row is still within the page, so the exit is reachable")


func test_the_page_insets_from_its_parent_on_every_side() -> void:
	# The inset IS the gap to the screen edges that makes the box read as floating. Measured
	# as real geometry rather than by reading the margin theme constants: those live on an
	# inner MarginContainer (the page itself is a plain Control so a `dim` backdrop can cover
	# the whole frame), so asserting the constants would pin the mechanism, not the result.
	var page := _sized_page(400.0, 300.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var box := page.panel()
	assert_gt(box.global_position.x - page.global_position.x, 0.0, "inset on the left")
	assert_gt(box.global_position.y - page.global_position.y, 0.0, "inset on the top")
	assert_gt((page.global_position.x + page.size.x) - (box.global_position.x + box.size.x),
		0.0, "inset on the right")
	# The bottom gap is the action row plus its own gap, so the box must end well above it.
	assert_gt((page.global_position.y + page.size.y) - (box.global_position.y + box.size.y),
		0.0, "inset on the bottom")


func test_over_wide_content_does_not_paint_outside_the_box() -> void:
	# The margin does NOT cap the box's width — see the "margin does not bind horizontally"
	# note in menu_page.gd. What protects the screen is clipping, so that is what to assert:
	# content wider than the frame must not paint outside its own background.
	var page := _sized_page(400.0, 300.0, {"margin": 24.0})
	var wide := Label.new()
	wide.custom_minimum_size.x = 2000.0   # far wider than the 400-wide frame
	page.body().add_child(wide)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_true(page.panel().clip_contents,
		"the box clips, so an over-wide row can't bleed into the 3D scene behind it")


# --- The optional dim backdrop (true modals) ---------------------------------

func test_no_dim_backdrop_by_default() -> void:
	# Most pages sit over a 3D station that should stay visible; only a true modal dims.
	var page := _page()
	assert_eq(page.find_children("*", "ColorRect", false, false).size(), 0,
		"a plain page paints no backdrop")


func test_a_dim_page_covers_the_WHOLE_frame() -> void:
	# The reason MenuPage is a plain Control and not a MarginContainer: a container lays its
	# children out inside its own margins, so a full-rect backdrop child would be inset by
	# them and leave an undimmed border around the screen.
	var page := _sized_page(400.0, 300.0, {"dim": true, "margin": 24.0})
	await get_tree().process_frame
	await get_tree().process_frame
	var rects := page.find_children("*", "ColorRect", false, false)
	assert_eq(rects.size(), 1, "a dim page paints exactly one backdrop")
	var dim := rects[0] as ColorRect
	assert_almost_eq(dim.size.x, page.size.x, 1.0, "the backdrop spans the full width")
	assert_almost_eq(dim.size.y, page.size.y, 1.0, "the backdrop spans the full height")
	assert_eq(dim.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"the backdrop is a visual cue and must not swallow input")


func test_the_dim_backdrop_sits_behind_the_body_box() -> void:
	var page := _sized_page(400.0, 300.0, {"dim": true})
	await get_tree().process_frame
	var rects := page.find_children("*", "ColorRect", false, false)
	assert_gt(rects.size(), 0, "precondition: the backdrop exists")
	# Draw order is child order, so the backdrop must come before the margined column.
	assert_eq(page.get_child(0), rects[0], "the backdrop is drawn first, behind the content")


# --- Rule 2: actions are a gapped row BELOW the box, not inside it ----------

func test_the_action_row_is_a_sibling_of_the_body_box_not_a_child() -> void:
	# Being OUTSIDE the box is what makes the gap read as a gap: inside it, the buttons are
	# just one more row of content no matter how much spacing precedes them.
	var page := _page()
	var box := page.panel()
	var row := page.actions()
	assert_eq(row.get_parent(), box.get_parent(), "the action row is a sibling of the body box")
	assert_ne(row.get_parent(), box, "...and NOT inside it")
	# And it comes after, so it reads as the page's footer.
	assert_gt(row.get_index(), box.get_index(), "the action row sits below the body box")


func test_the_column_gaps_the_box_from_the_action_row() -> void:
	var page := _page()
	var col: Node = page.panel().get_parent()
	assert_gt((col as BoxContainer).get_theme_constant("separation"), 0,
		"there is a real gap between the body box and the action row")


func test_actions_are_added_left_to_right() -> void:
	# Callers rely on this to put "leaving" leftmost (features/menus.md -> Button order).
	var page := _page()
	var first := page.add_action(UITheme.row_button("< Back", Callable()))
	var second := page.add_action(UITheme.row_button("Wheels", Callable()))
	assert_eq(page.actions().get_child(0), first, "the first action added leads the row")
	assert_eq(page.actions().get_child(1), second, "later actions follow it")
	assert_eq(page.add_action(UITheme.row_button("X", Callable())).get_parent(), page.actions(),
		"add_action returns the button it parented")


# --- The body / title handles ------------------------------------------------

func test_body_content_lands_inside_the_box() -> void:
	var page := _page()
	var row := Label.new()
	page.body().add_child(row)
	# Walk up from the content: it must be enclosed by the box, so the box's background
	# actually sits behind it.
	var found := false
	var n: Node = row
	while n != null:
		if n == page.panel():
			found = true
			break
		n = n.get_parent()
	assert_true(found, "content added to body() is drawn inside the body box")


func test_a_title_is_optional() -> void:
	assert_null(_page().title_label(), "no title requested -> no label is built at all")
	var titled := _page({"title": "Upgrades"})
	assert_not_null(titled.title_label(), "a requested title builds a heading")
	assert_eq(titled.title_label().text, UITheme.caps("Upgrades"),
		"the heading shows the requested title (house rule: uppercased)")


func test_the_title_is_inside_the_box_above_the_body() -> void:
	var page := _page({"title": "Upgrades"})
	var title := page.title_label()
	assert_eq(title.get_parent(), page.body().get_parent().get_parent(),
		"the title sits in the box, outside the scroll, so it never scrolls away")


func test_a_caller_can_fix_the_body_column_width() -> void:
	# Default is to hug; a caller wanting a stable column (so the box doesn't resize as its
	# content changes) asks for one.
	assert_eq(_page().body().custom_minimum_size.x, 0.0, "by default the box hugs its content")
	assert_eq(_page({"width": 380.0}).body().custom_minimum_size.x, 380.0,
		"a requested width becomes the body column's floor")


func test_the_box_clips_content_that_overflows_it() -> void:
	# A row wider than the box must not spill past the background into the 3D scene.
	assert_true(_page().panel().clip_contents, "the body box clips overflowing content")


func test_a_pinned_height_stops_the_box_tracking_its_content() -> void:
	# For a page that swaps its content while it stays open (the challenge screen's kind
	# tabs). A MINIMUM cannot do this — content taller than the number still grows the box —
	# so the pin is exact, and taller content scrolls instead.
	var page := _sized_page(400.0, 600.0, {"fixed_height": 120.0})
	await get_tree().process_frame
	await get_tree().process_frame
	var before: float = page.panel().size.y
	for i in 30:
		var row := Label.new()
		row.text = "ROW %d" % i
		row.custom_minimum_size.y = 20.0
		page.body().add_child(row)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_almost_eq(page.panel().size.y, before, 1.0,
		"the box keeps its pinned height after 600px of content is added")


# --- open_modal: the hosting contract ----------------------------------------
# A modal page must be independent of any station's CanvasLayer (WorldPanelHost hides those
# when it migrates a station's tree into a 3D panel), must draw BELOW ConfirmPopup (it hosts
# confirms rather than being one), and must claim the screen so WorldPanel._input stops
# projecting its clicks into the 3D station behind it.

func test_open_modal_hosts_the_page_on_its_own_canvas_layer() -> void:
	var host := Node.new()
	add_child_autofree(host)
	var page := MenuPage.open_modal(host)
	assert_not_null(page, "a page comes back")
	var layer := page.get_parent() as CanvasLayer
	assert_not_null(layer, "the page's parent is a CanvasLayer of its own")
	assert_eq(layer.get_parent(), host, "which hangs off the host that was asked")


func test_open_modal_draws_below_a_confirm_popup() -> void:
	# Compared against ConfirmPopup's own level, never a pinned number: a tie lets the confirm
	# hide behind this page's opaque panel while its click-swallowing dim stays live.
	var host := Node.new()
	add_child_autofree(host)
	var page := MenuPage.open_modal(host)
	var confirm := ConfirmPopup.open(host, "T", "B", [{"label": "OK", "callback": Callable()}])
	assert_not_null(confirm, "a confirm opens over the page rather than being refused")
	if confirm == null:
		return
	assert_lt((page.get_parent() as CanvasLayer).layer, (confirm as CanvasLayer).layer,
		"the modal page draws below any confirm popup opened over it")
	confirm.trigger_back()


func test_open_modal_claims_the_screen_while_visible() -> void:
	var host := Node.new()
	add_child_autofree(host)
	var outsider := Control.new()
	add_child_autofree(outsider)
	var page := MenuPage.open_modal(host)
	await get_tree().process_frame
	assert_true(MenuNav.input_blocked(outsider),
		"while the modal is up, everything outside it goes deaf (pointer included)")
	page.visible = false
	assert_false(MenuNav.input_blocked(outsider),
		"and hiding the page releases the claim — hosts keep these pages and toggle visible")

class_name MenuPage
extends Control
# THE HOUSE PAGE SHAPE, as a reusable widget: a BODY BOX that hugs its own contents with a
# gap to the screen edges, and the page's ACTION BUTTONS along the bottom in one horizontal
# row, gapped off the body.
#
#            ┌───────────────────────────────┐   <- body box: black, sized to its
#            │  UPGRADES                     │      CONTENTS, never to the screen
#            │  TURBO         [STOCK] SMALL  │
#            │  AERO        [STOCK] AERO KIT │
#            └───────────────────────────────┘
#                 [ < BACK ]  [ WHEELS ]         <- one horizontal action row, gapped
#
# Two rules it exists to enforce, because both were being re-derived (differently) per
# screen:
#
# 1. THE BODY BOX HUGS ITS CONTENTS. A page whose background is stretched to the full
#    viewport reads as "the app is now this screen"; one that hugs its content reads as a
#    panel resting over the world behind it, which is what the 3D stations want — you can
#    still see the bay / the map / the staged car around it. It also means a two-row page
#    doesn't paint a huge empty black field under those two rows.
# 2. ACTIONS GO IN A HORIZONTAL ROW BELOW THE BODY, NOT INSIDE IT. Inside the box, the
#    buttons read as one more row of content; outside and gapped, they read as what you do
#    with the page. Leaving is leftmost (see features/menus.md → "Button order").
#
# The gap to the screen edges is what makes the box read as floating rather than as the
# screen itself — do not anchor a MenuPage to a full rect with zero margin.
#
# CAVEAT: the margin does NOT bind horizontally. The box hugs and centres, so with content
# narrower than the frame the centring gap dominates and the margin is invisible; with content
# WIDER than the frame the box still grows past it, because the body's scroll has
# horizontal_scroll_mode DISABLED and therefore propagates its content's minimum width. What
# actually stops an over-wide row reaching the 3D scene is `clip_contents` on the box. So the
# margin's real effect is vertical (via _sync_body_height's available-height budget) plus the
# resting look. If a hard horizontal cap is ever needed, it needs a real mechanism — capping
# the body's width at the call site (set_body_width + hq._modal_body_width is the existing
# pattern) rather than relying on this opt.
#
# Usage — for a page that lives on a station's own overlay tree:
#     var page := MenuPage.new({"title": "Upgrades", "width": 380.0})
#     page.body().add_child(my_rows)
#     page.add_action(UITheme.row_button("< Back", on_back))
#     station_tree.add_child(page)
#
# For a MODAL page — one that covers the screen — use `open_modal` instead and let it own
# the hosting. DO NOT hand-roll it by adding the page to a station's CanvasLayer: see
# open_modal for the two bugs that costs.
#
# Hand `page` (or its owning layer) to MenuNav.attach / UITheme.enforce as usual: the
# action row is a sibling of the body box, and MenuNav drives focus across container
# boundaries by geometry, so down-nav off the last body row lands in the row.

# The body's scroll is a SAFETY NET for very short logical canvases (DESIGN_HEIGHT is small
# on every target — see display_stretch.gd), not the normal way content
# is read: the box is meant to fit. It matters because the box hugs its contents, so tall
# content would otherwise push the action row off the bottom of the screen entirely.
var _panel: PanelContainer
var _inner: VBoxContainer
var _title_label: Label
var _scroll: TouchScrollContainer
var _body: VBoxContainer
var _actions: HBoxContainer
# An EXACT height for the body (0 = hug the content instead). Set by a page whose content
# changes while it stays open — see set_body_fixed_height.
var _fixed_body_height := 0.0


# opts:
#   "title"  (String)  a heading inside the body box; omitted/"" builds no label at all
#   "width"  (float)   a fixed column width for the body box; omitted hugs the content
#   "fixed_height" (float) an exact body height; omitted lets it hug the content
#   "alpha"  (float)   body-box background alpha (default opaque — see UITheme.panel_box)
#   "margin" (float)   the gap to the screen edges (default UITheme.MARGIN)
#   "padding" (float)  the body box's inner padding (default UITheme.panel_box's own)
#   "dim"    (bool)    paint UITheme.MODAL_DIM over the WHOLE frame behind the page, for a
#                      true modal that must read as blocking what's underneath
# THE MODAL CANVAS LEVEL. Above the station overlays (which take CanvasLayer's default 1)
# and STRICTLY BELOW ConfirmPopup's 101, because a modal page HOSTS confirms rather than
# being one: the car park's Change-Upgrades page opens a ConfirmPopup from its Auto-Upgrade
# row, and the reward / detune prompts open over these pages. On a tie the confirm can be
# drawn UNDER the page's opaque panel while its own full-screen MOUSE_FILTER_STOP dim goes
# on swallowing every click — an invisible confirm behind a menu that has gone dead.
const MODAL_LAYER := 100


# A MODAL MenuPage, hosted correctly. The one way to put a full-screen page on screen.
#
# It exists because hosting a modal was being re-derived per call site, and two of the three
# derivations were wrong in ways nothing reported:
#
# 1. NEVER A STATION'S CanvasLayer. `WorldPanelHost.sync` migrates a station's UI tree into a
#    3D WorldPanel and hides its flat layer outright (`flat_layer.visible = false`) whenever
#    `world_space_menus` is on — the SHIPPED value. A page added to `_car_layer` was built,
#    gated and nav-wired but rendered NOWHERE: pressing "Change Upgrades" on the car park's
#    "Too powerful" prompt looked like it dropped the player back to car-select. Its own
#    layer makes the page independent of where the station's tree currently lives.
# 2. IT MUST CLAIM THE SCREEN, POINTER INCLUDED. `WorldPanel._input` projects clicks that
#    land inside its 3D quad into the panel's SubViewport and marks them handled, standing
#    down only for `MenuNav.input_blocked`. A page outside that predicate rendered on top
#    while the station underneath quietly ate its clicks. Joining SCREEN_CLAIMER_GROUP —
#    and NOT ConfirmPopup's MODAL_GROUP, which would make the page refuse the very confirms
#    it hosts — is what makes the page's own buttons reachable.
#
# `opts` is passed through to _init verbatim, plus "layer" to override MODAL_LAYER. Returns
# the page; its CanvasLayer is `page.get_parent()` (freeing that frees the page with it).
static func open_modal(host: Node, opts: Dictionary = {}) -> MenuPage:
	var page := MenuPage.new(opts)
	var layer := CanvasLayer.new()
	layer.layer = int(opts.get("layer", MODAL_LAYER))
	host.add_child(layer)
	layer.add_child(page)
	# On the PAGE, not the layer, so that hiding the page releases the claim: hosts keep
	# these pages alive and toggle `visible` (hq_carpark.gd _close_upgrades_popup), and a
	# hidden page must not go on blocking the world behind it.
	page.add_to_group(MenuNav.SCREEN_CLAIMER_GROUP)
	return page


func _init(opts: Dictionary = {}) -> void:
	var margin: float = float(opts.get("margin", UITheme.MARGIN))
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# Let anything not a control fall through to the 3D station behind the page.
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# This extends a plain Control rather than a MarginContainer SO THAT a dim backdrop can
	# cover the whole frame: a Container lays its children out inside its own margins, so a
	# full-rect ColorRect child would be inset by them and leave an undimmed border. The
	# margins therefore live on an inner MarginContainer, which the dim sits behind.
	if bool(opts.get("dim", false)):
		var dim := ColorRect.new()
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		dim.color = UITheme.MODAL_DIM
		# IGNORE, not STOP: the dim is a visual cue. Screens that must actually block input
		# underneath do it by routing navigation to the modal (see hq_carpark.gd _carpark_modal_open),
		# not by relying on a rect to swallow events.
		dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(dim)

	var margins := MarginContainer.new()
	margins.set_anchors_preset(Control.PRESET_FULL_RECT)
	margins.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "top", "right", "bottom"]:
		margins.add_theme_constant_override("margin_" + side, int(margin))
	add_child(margins)

	# The column centres its two parts vertically, which is what lets the body box hug its
	# contents instead of being stretched to the available height.
	var col := VBoxContainer.new()
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", UITheme.GAP)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margins.add_child(col)

	_panel = PanelContainer.new()
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # hug the content's height
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", UITheme.panel_box(
		float(opts.get("alpha", 1.0)), int(opts.get("padding", UITheme.PANEL_PAD))))
	# A row that wants more width than the box must never spill past the background into
	# the 3D scene behind it. Content is also wrapped where it can be (the HFlowContainer
	# option rows in upgrades_menu.gd), so this is a safety net, not the mechanism.
	_panel.clip_contents = true
	col.add_child(_panel)

	_inner = VBoxContainer.new()
	_inner.add_theme_constant_override("separation", UITheme.GAP)
	_inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_inner)

	var title := String(opts.get("title", ""))
	if title != "":
		_title_label = UITheme.title(title)
		_inner.add_child(_title_label)

	_scroll = TouchScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# NOT EXPAND_FILL: an expanding scroll claims all the height going and the box stretches
	# to the screen again, defeating rule 1. But SHRINK alone is NOT enough either, and this
	# is the trap worth remembering: a ScrollContainer deliberately reports a near-zero
	# minimum size (that is what makes it scrollable), so it does NOT pass its content's
	# height up to the box. Left to shrink, the box hugs *nothing* and collapses to an empty
	# bar. _sync_body_height is what actually gives the box its height — see there.
	_scroll.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_inner.add_child(_scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", UITheme.GAP)
	_scroll.add_child(_body)

	if opts.has("width"):
		set_body_width(float(opts["width"]))
	if opts.has("fixed_height"):
		set_body_fixed_height(float(opts["fixed_height"]))

	_actions = HBoxContainer.new()
	_actions.alignment = BoxContainer.ALIGNMENT_CENTER
	_actions.add_theme_constant_override("separation", UITheme.GAP)
	col.add_child(_actions)


func _ready() -> void:
	# Re-derive the box's height whenever its content changes size (rows added/removed, a
	# label rewrapping) or the frame resizes.
	_body.minimum_size_changed.connect(_sync_body_height)
	resized.connect(_sync_body_height)
	_sync_body_height()


# Give the scroll — and therefore the body box — exactly the height its CONTENT wants, up to
# what the page can show. This is what makes rule 1 work: a ScrollContainer reports a
# near-zero minimum size, so without this the box would collapse to an empty bar around a
# zero-height scroll.
#
# The cap is the other half of it. Past the available height the box stops growing and the
# content scrolls inside it, which keeps the action row on screen — the thing that must never
# break, because `menu_back` is Escape / gamepad B only (project.godot) and a touch player
# whose exit has been pushed off the bottom of the frame is simply trapped. The logical canvas
# is short (DESIGN_HEIGHT — see display_stretch.gd), so this is a real case, not a
# theoretical one.
func _sync_body_height() -> void:
	# Every part is optional here because this can be called DURING construction: the
	# "fixed_height" opt runs set_body_fixed_height before _actions exists, and _ready()
	# re-runs the whole thing once everything is built anyway.
	if _scroll == null or _body == null or _actions == null:
		return
	# A page that pinned its height gets exactly that, whatever its content currently is;
	# everything else hugs. See set_body_fixed_height.
	var wanted: float = _fixed_body_height if _fixed_body_height > 0.0 \
		else _body.get_combined_minimum_size().y
	# Everything in the page that is NOT the scroll, and so cannot be given to it.
	var chrome: float = _actions.get_combined_minimum_size().y + UITheme.GAP
	if _title_label != null:
		chrome += _title_label.get_combined_minimum_size().y + UITheme.GAP
	# The body box's own padding, top and bottom (see UITheme.panel_box).
	chrome += _panel.get_theme_stylebox("panel").get_minimum_size().y
	var available: float = size.y - chrome
	_scroll.custom_minimum_size.y = minf(wanted, available) if available > 0.0 else wanted


# Put the page's content here.
func body() -> VBoxContainer:
	return _body


# The bottom action row. Prefer add_action(); reach for this to inspect or reorder it.
func actions() -> HBoxContainer:
	return _actions


# The body box itself — for a caller that needs to restyle or hide just the box.
func panel() -> PanelContainer:
	return _panel


# The heading label, or null when the page was built without a title.
func title_label() -> Label:
	return _title_label


# Append an action button to the bottom row. Buttons are added left to right, and LEAVING
# the page (Back / Done / Close) belongs leftmost, so add it first.
func add_action(button: Button) -> Button:
	_actions.add_child(button)
	return button


# Fix the body box's column width. Callers that want a stable column (so the box doesn't
# resize as its content changes) set this; the default is to hug the content. Pass a width
# already clamped to what the CURRENT logical canvas can show, since the frame's width is
# not a constant — see display_stretch.gd and hq.gd's _modal_body_width.
func set_body_width(preferred: float) -> void:
	_body.custom_minimum_size.x = preferred


# Pin the body to an EXACT height, so the box stops tracking its content.
#
# Hugging the content is right for a page built once and then read, but WRONG for a page that
# swaps its own content while it stays open — the challenge screen's Daily / Weekly / Monthly
# tabs are the case that matters. Each kind has a different amount to say (a longer ceiling
# subtitle, an extra "Needs tune:" line, a different number of leaderboard rows), so a box
# that hugs re-fits on every tab press and the panel jumps around under the player, moving
# the very tabs being clicked.
#
# Deliberately EXACT rather than a minimum. A floor cannot do this job: it only stops the box
# getting SMALLER than the number, and content taller than it still grows the box, so the
# jumping remains. (A floor appears to work on the short logical canvas — DESIGN_HEIGHT —
# because the available-height cap pins it anyway; on a taller frame the jitter comes
# straight back. That is a trap, not a fix.)
#
# Content taller than the pin scrolls inside the box, which is what the body's scroll is for.
# Pair with set_body_width to pin the other axis — and note that a non-wrapping label can
# still push the WIDTH past its floor, so wrap the page's headings too.
func set_body_fixed_height(exact_height: float) -> void:
	_fixed_body_height = exact_height
	_sync_body_height()

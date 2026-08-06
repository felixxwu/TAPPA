class_name HqOverlays
extends RefCounted
# Overlay/menu-layer builders for the HQ, extracted from hq.gd to shrink it. Each
# method builds one 2D CanvasLayer overlay and wires its buttons back to the HQ
# controller. Holds a back-reference to the HqController and reaches into it for
# state, node parenting, widget helpers, and button callbacks.

var _hq: HqController

func _init(hq: HqController) -> void:
	_hq = hq


func build_title_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._title_layer = made[0]
	var root: VBoxContainer = made[1]
	# Sit the buttons at the BOTTOM of the screen so the HQ (garage + parked
	# collection) stays visible above them rather than being covered by a centred menu.
	root.alignment = BoxContainer.ALIGNMENT_END

	root.add_child(UITheme.vspacer())

	# Title screen is a horizontal row of buttons (Start / Settings / Free Roam, plus
	# Exit Game on non-web builds) over the parked-collection backdrop — no title/
	# subtitle text. Same diegetic idiom as the garage row and lift hub: FOCUS_NONE
	# buttons over a single left/right ButtonCursor (_title_cursor), not native focus —
	# EXTERIOR is one more spatially-navigated 3D station now, not a flat focus graph.
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	# BUTTON ORDER: leaving is leftmost, proceeding is rightmost (features/menus.md →
	# "Button order"). So Exit Game leads and Start closes the row — this used to be
	# exactly inverted, the one screen every player sees first.
	var buttons: Array = []
	var acts: Array = []
	# Exit Game: quit the application. Skipped on the web build, where there's no OS
	# process to quit (the tab owns the lifecycle) — which is why Start's index is
	# COMPUTED below rather than hardcoded: on web this button isn't there at all.
	if not Platform.is_web():
		var exit_btn := _hq._station_button("Exit Game", _hq._on_exterior_exit)
		actions.add_child(exit_btn)
		_hq._title_exit_button = exit_btn
		buttons.append(exit_btn)
		acts.append(_hq._on_exterior_exit)
	# Free Roam: a session-less drive in any catalogue car. It lives HERE, not in the
	# garage, because it isn't a career action — it needs no owned car, no session and no
	# lift, so making the player walk into the garage to reach it was a detour through
	# state it doesn't use. Back out of its picker returns to this screen
	# (CarparkMode.FREEROAM in _carpark_back). This slot used to hold Account, which is
	# reachable as a Settings page instead — one route, not two.
	var free_roam := _hq._station_button("Free Roam", _hq._enter_free_roam)
	actions.add_child(free_roam)
	_hq._title_free_roam_button = free_roam
	buttons.append(free_roam)
	acts.append(_hq._enter_free_roam)
	# Settings: the shared camera/controls page. Moved here from the garage action row —
	# Back from it now always returns to the title (see _on_settings_action / the
	# SETTINGS branch in _unhandled_input).
	var to_settings_cb := _hq._open_settings.bind(false)
	var settings := _hq._station_button("Settings", to_settings_cb)
	actions.add_child(settings)
	_hq._title_settings_button = settings
	buttons.append(settings)
	acts.append(to_settings_cb)
	var start := _hq._station_button("Start", _hq._on_exterior_start)
	actions.add_child(start)
	_hq._title_start_button = start
	buttons.append(start)
	acts.append(_hq._on_exterior_start)
	_hq._title_cursor.setup(buttons, acts)

	# Build version, shown only on the title screen (bottom-right corner). It is
	# stamped into application/config/version by build_web.sh (0.<git commit count>
	# + short SHA) and falls back to the project default on editor/dev runs.
	var ver := str(ProjectSettings.get_setting("application/config/version", ""))
	var version_label := Label.new()
	version_label.text = ("v" + ver) if ver != "" else "dev"
	version_label.add_theme_font_size_override("font_size", 12)
	version_label.anchor_left = 1.0
	version_label.anchor_right = 1.0
	version_label.anchor_top = 1.0
	version_label.anchor_bottom = 1.0
	version_label.offset_left = -120.0
	version_label.offset_top = -28.0
	version_label.offset_right = -12.0
	version_label.offset_bottom = -8.0
	version_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	version_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	version_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	version_label.modulate = Color(1, 1, 1, 0.6)
	_hq._title_layer.add_child(version_label)
	_hq._title_version_label = version_label

	# EXTERIOR is now driven by menu_left/menu_right/menu_select over _title_cursor (see
	# _unhandled_input), the same diegetic idiom as the garage row and lift hub — no
	# MenuNav here. hq re-seats the cursor on Start itself on view entry (_go_to).


func build_garage_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._garage_layer = made[0]
	var root: VBoxContainer = made[1]

	# NO header text. This used to carry "GARAGE — tap the map table to choose a rally, or the
	# lift to tune your car": a caption naming the room you can see, plus instructions for two
	# objects that are already lit, labelled and pickable in the 3D scene. The garage is a
	# diegetic station — the room IS the menu — so a line of prose over it only competes with
	# the thing it describes. The action row at the bottom is the only chrome here now.
	root.add_child(UITheme.vspacer())

	# The bottom action row is rebuilt IN PLACE by hq._refresh_garage_row():
	# Back / Career / Garage / Mystery Box (N) / Online, ONE level (Mystery Box appears
	# only when one is held). FOCUS_NONE + hand-painted like the tuning hub, since the
	# garage is a spatially-navigated 3D station, not a native focus graph. (Repair
	# lives on the tuning-lift HUB row — see build_lift_overlay. Settings and Free Roam
	# live on the title screen — see build_title_overlay.)
	_hq._garage_actions_row = HBoxContainer.new()
	_hq._garage_actions_row.add_theme_constant_override("separation", 8)
	root.add_child(_hq._garage_actions_row)
	_hq._refresh_garage_row()

	_hq._passthrough_overlay(root)  # let taps reach the 3D table / lift behind the HUD


func build_table_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._table_layer = made[0]
	var root: VBoxContainer = made[1]

	# The new-rally reveal's one-line banner ("NEW RALLY - …" / "SPECIAL EVENT UNLOCKED - …"),
	# hidden except while the reveal sequence is running. See hq_table.gd _set_reveal_banner.
	_hq._reveal_banner = _hq._label("", 20)
	_hq._reveal_banner.visible = false
	root.add_child(_hq._reveal_banner)

	root.add_child(UITheme.vspacer())

	# The star balance, BOTTOM CENTRE rather than in the top-left corner where it started.
	# It's the map's one number and the currency the special pins are gated on, so it belongs
	# on the centre line the player's eye already travels rather than tucked over the pins.
	# It is a spendable balance with no denominator (_refresh_meter), hence one star and a
	# count — not a StarRow of N lit-of-M, which is the rally MEDAL readout and would imply
	# a maximum that doesn't exist. The glyph is a StarRow of one because Syne Mono has no ★
	# (see star_row.gd); the label carries only the digits.
	var meter_row := HBoxContainer.new()
	meter_row.alignment = BoxContainer.ALIGNMENT_CENTER
	meter_row.add_theme_constant_override("separation", 6)
	root.add_child(meter_row)
	var star := StarRow.new()
	star.star_radius = 8.0
	star.setup(1, 1)
	meter_row.add_child(star)
	_hq._map_meter = _hq._label("", 20)
	_hq._map_meter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	meter_row.add_child(_hq._map_meter)

	var back := Button.new()
	back.text = "< Back to garage"
	back.focus_mode = Control.FOCUS_NONE
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(func() -> void: _hq._go_to(HqController.View.GARAGE))
	root.add_child(back)

	_hq._passthrough_overlay(root)  # let taps / drags reach the 3D map pins behind the HUD


func build_detail_overlay() -> void:
	# Scrolled body + pinned actions row (_hq._make_modal_overlay — read its header for
	# why): the eligibility column is three autowrapped labels whose height depends on the
	# rally's restriction text and the player's garage, and on a narrow phone frame they
	# wrap to several lines each. Before this they could push "< Map" off the bottom of the
	# canvas, and menu_back is Esc / gamepad B only — no way back by touch.
	var made := _hq._make_modal_overlay()
	_hq._detail_layer = made[0]
	var root: VBoxContainer = made[1]
	var footer: HBoxContainer = made[2]
	# NO full-rect backing here: MenuPage's body box IS the panel, and it hugs its contents
	# so the map stays visible around it. A full-screen ColorRect behind it would paint over
	# the whole map table and undo that.

	# A WIDTH FLOOR, for the same reason the challenge screen has one: this page is re-filled
	# per rally (build_detail_overlay runs once, _show_rally_detail rewrites it), and rally
	# names, restriction strings and star counts all differ in length — so a box that only
	# hugs its contents is a different width for every pin you open. Floored so it reads as
	# one panel you keep opening rather than a new one each time. Kept the SAME number as the
	# challenge screen below: the two open from the same map and read as one panel shape, so a
	# few px of difference between them looks like a bug rather than a choice.
	var page := made[3] as MenuPage
	page.set_body_width(_hq._modal_body_width(480.0))  # clamped to the current logical canvas

	# Everything below is uppercased + locked to one font size by UITheme.enforce
	# (via _normalize_menus on each view change), so hierarchy comes from layout,
	# colour and separators — not font size. Stars are a polygon StarRow, since
	# Syne Mono has no ★ glyph.

	# --- Header: title + region on the left, a gold SPECIAL EVENT chip on the right.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	# AUTOWRAP both: set_body_width is only a FLOOR, so a non-wrapping label that wants more
	# still widens the box past it. A long rally name ("Archipelago Trial - 3 stages") is
	# exactly that, which would leave the width floored but still varying per pin. Everything
	# else in this page already wraps (_detail_wrap_label).
	_hq._detail_title = _hq._label("", 30)
	_hq._detail_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hq._detail_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(_hq._detail_title)
	_hq._detail_region = _hq._label("", 16)
	_hq._detail_region.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hq._detail_region.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hq._detail_region.add_theme_color_override("font_color", UITheme.MUTED)
	titles.add_child(_hq._detail_region)
	_hq._detail_special = _hq._label("SPECIAL EVENT", 16)
	_hq._detail_special.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hq._detail_special.add_theme_color_override("font_color", UITheme.GOLD)
	header.add_child(_hq._detail_special)

	root.add_child(HSeparator.new())

	# --- One full-width status column. The old per-stage breakdown (surface mix per
	# event) was more detail than the player needs here and cost half the panel; the
	# stage COUNT now rides on the header title instead ("Coastal Sprint - 3 stages"),
	# which frees the whole width for the eligibility read-out on small screens.
	var right := VBoxContainer.new()
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 4)
	root.add_child(right)
	right.add_child(_hq._detail_heading("Eligibility"))
	# All sidebar text wraps within the column so a long restriction / caution can't
	# draw past the panel edge (Labels don't clip by default).
	_hq._detail_restriction = _hq._detail_wrap_label()
	right.add_child(_hq._detail_restriction)
	_hq._detail_qualify = _hq._detail_wrap_label()
	right.add_child(_hq._detail_qualify)
	_hq._detail_adjust = _hq._detail_wrap_label()
	_hq._detail_adjust.add_theme_color_override("font_color", UITheme.GOLD)
	right.add_child(_hq._detail_adjust)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	right.add_child(gap)
	right.add_child(_hq._detail_heading("Your record"))
	var record_row := HBoxContainer.new()
	record_row.add_theme_constant_override("separation", 10)
	right.add_child(record_row)
	_hq._detail_record = _hq._label("", 16)
	record_row.add_child(_hq._detail_record)
	_hq._detail_stars = StarRow.new()
	_hq._detail_stars.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	record_row.add_child(_hq._detail_stars)

	# The actions row is the pinned footer, so both controls are always on screen.
	# "< Map" stays FOCUS_NONE deliberately: this panel has no MenuNav and no button
	# cursor — hq._unhandled_input drives it directly from the TABLE view (menu_select
	# enters, menu_back hides it), so making one of the two buttons focusable would
	# create a half-built focus graph with nothing to seed or move the cursor. Pinning is
	# what makes it reachable by touch; keyboard/gamepad already have menu_back.
	var actions := footer
	var back := Button.new()
	back.text = "< Map"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_hq._table_ui._hide_detail)
	actions.add_child(back)
	var enter := Button.new()
	enter.text = "Enter Rally — choose car >"
	enter.focus_mode = Control.FOCUS_NONE
	enter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enter.pressed.connect(_hq._enter_car_screen)
	actions.add_child(enter)
	_hq._detail_enter_button = enter


func build_lift_overlay() -> void:
	_hq._lift_layer = CanvasLayer.new()
	_hq.add_child(_hq._lift_layer)

	# --- The sub-menu page (shown on the TUNE / UPGRADES pages) ---
	# The house page shape, from the shared MenuPage widget: a body box that HUGS its
	# contents with a gap to the screen edges, and the page's actions in one horizontal row
	# gapped below it. See menu_page.gd for why those two are rules rather than per-screen
	# choices. This screen used to hand-roll a full-height ColorRect, which both painted a
	# black field over the whole bay and enclosed the action row so the buttons read as body
	# content.
	#
	var page := MenuPage.new({"margin": 12.0})
	_hq._lift_layer.add_child(page)
	_hq._lift_menu_bg = page.panel()
	var root: VBoxContainer = page.body()

	_hq._lift_menu_title = _hq._label("", 22)
	root.add_child(_hq._lift_menu_title)

	# MenuPage already wraps the body in a scroll safety net for very short logical
	# canvases, so the page's rows go straight into its body.
	var content := root

	_hq._tune_panel = TuningPanel.new()
	content.add_child(_hq._tune_panel)
	# The UPGRADES page is the reusable UpgradesMenu component (shared with the car-park
	# detune popup). It attaches + preserves its own MenuNav across rebuilds and shows a
	# p/w + G stats line; the lift wires on_change + the engine-swap action in
	# _refresh_lift_ui. See features/upgrade-catalogue.md.
	_hq._lift_upgrades_box = UpgradesMenu.new()
	content.add_child(_hq._lift_upgrades_box)

	# Framework: WASD + arrow + gamepad focus nav for the native-focus TUNE (sliders)
	# sub-page. Attached to the tune box ONLY — not the lift root — so the diegetic HUB
	# buttons (FOCUS_NONE, manual left/right cursor) are left untouched. The box goes
	# inert while hidden (_menu_visible). The UpgradesMenu self-attaches its own nav.
	MenuNav.attach(_hq._tune_panel)

	# A sub-page's ACTIONS go along the bottom in ONE horizontal row, OUTSIDE the body box
	# and gapped off it — MenuPage owns that row. Its visibility is gated with the page
	# (_refresh_lift_ui), since it is a sibling of the box rather than a child of it.
	_hq._lift_page_actions = page.actions()

	# "< Back" leads the row (leaving is always leftmost — features/menus.md -> Button
	# order). Focusable so keyboard/gamepad can reach it, and it is the focus fallback for a
	# page whose body has no focusable control (a fresh car's Upgrades page — see
	# _open_lift_page).
	_hq._lift_back_button = UITheme.row_button("< Back", _hq._lift_hub)
	_hq._lift_back_button.focus_mode = Control.FOCUS_ALL  # these pages navigate by native focus
	_hq._lift_page_actions.add_child(_hq._lift_back_button)

	# The TUNE page's own actions (Reset to neutral / Wheels) sit beside Back in the same
	# row. TuningPanel builds them but never parents them, precisely so they can land here;
	# _refresh_lift_ui shows them only while the TUNE page is up, since they act on the
	# sliders. Kept in one array so that gating is a loop, not a list of named buttons.
	_hq._tune_action_buttons = _hq._tune_panel.action_buttons()
	for b in _hq._tune_action_buttons:
		_hq._lift_page_actions.add_child(b)

	# --- The bottom column: car-description info panel + (on the HUB) the Tuning /
	# Upgrades buttons and Test Drive. Spans the full page width (the sub-menu
	# no longer needs room on the right) and grows upward so the info panel sits at the
	# bottom with the hub controls above it; mouse-transparent except buttons.
	var left_col := VBoxContainer.new()
	left_col.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	left_col.offset_left = 20
	left_col.offset_right = -20
	left_col.offset_bottom = -20
	left_col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	left_col.add_theme_constant_override("separation", 10)
	left_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hq._lift_layer.add_child(left_col)

	# The car readout: TWO stacked rows of equal-height boxes, above the hub button row.
	#
	#   [ < ] [ MAZDA MX-5 (TURBO) ] [ > ]      <- the car SELECTOR
	#   [ RWD · 1,010 KG · 180 HP        ]      <- that car's stats
	#
	# The chevrons are how you change the car on the lift without leaving the bay
	# (_cycle_lift_car, also driven by menu_up/menu_down — see hq._unhandled_input). They
	# replace the old "back out to the garage and reopen the Garage picker" round-trip,
	# which is why the Garage button now drops straight onto the lift.
	#
	# Each box is a separate panel rather than one panel with two lines of text, so the
	# selector row reads as a control (matching the hub buttons' height and spacing
	# exactly) while the stats stay a passive readout under it.
	_hq._lift_info_panel = VBoxContainer.new()
	var info_panel := _hq._lift_info_panel
	info_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	info_panel.add_theme_constant_override("separation", UITheme.GAP)
	info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left_col.add_child(info_panel)

	# Row 1: < | name | >. Hugs its content on the left so the raised car stays in view.
	var selector := HBoxContainer.new()
	selector.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	selector.add_theme_constant_override("separation", UITheme.GAP)
	selector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_child(selector)

	# Clickable chevrons. FOCUS_NONE like every other diegetic-station button — the bay
	# navigates by manual cursor, not native focus, so these are pointer affordances for
	# an action the keyboard/gamepad reaches with up/down. Both are hidden outright when
	# there is only one car to cycle (_refresh_lift_car_label).
	_hq._lift_prev_button = _hq._station_button("<", _hq._cycle_lift_car.bind(-1))
	selector.add_child(_hq._lift_prev_button)

	# The name sits in a box of its own, matched to the chevrons' height so the three
	# read as one control. Not clickable: there is nothing for a press on the name to do
	# that the chevrons either side don't already say more clearly.
	var name_box := PanelContainer.new()
	name_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_box.custom_minimum_size.y = UITheme.MENU_ROW_H
	name_box.add_theme_stylebox_override("panel", UITheme.readout_box())
	selector.add_child(name_box)
	_hq._lift_car_label = _hq._label("", 14)
	_hq._lift_car_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_box.add_child(_hq._lift_car_label)

	_hq._lift_next_button = _hq._station_button(">", _hq._cycle_lift_car.bind(1))
	selector.add_child(_hq._lift_next_button)

	# The selector is the HUB's second cursor row. Same contract as the actions row below
	# it: each button's `pressed` callable is also the cursor's action for that index, so a
	# click and a keyboard/gamepad select can't drift apart.
	_hq._lift_selector_cursor.setup(
		[_hq._lift_prev_button, _hq._lift_next_button],
		[_hq._cycle_lift_car.bind(-1), _hq._cycle_lift_car.bind(1)])

	# Row 2: the stats line for whichever car the selector landed on.
	var stats_box := PanelContainer.new()
	stats_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats_box.custom_minimum_size.y = UITheme.MENU_ROW_H
	stats_box.add_theme_stylebox_override("panel", UITheme.readout_box())
	info_panel.add_child(stats_box)
	_hq._lift_car_stats_label = _hq._label("", 14)
	_hq._lift_car_stats_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	stats_box.add_child(_hq._lift_car_stats_label)

	# The hub controls UNDER the car description: a SINGLE bottom row holding Back, the
	# Tuning / Upgrades buttons, and a Test Drive button. Shown only on the HUB page
	# (_refresh_lift_ui). Hugs content on the left so the raised car stays in clear view.
	_hq._lift_hub_controls = HBoxContainer.new()
	_hq._lift_hub_controls.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_hq._lift_hub_controls.add_theme_constant_override("separation", 8)
	_hq._lift_hub_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left_col.add_child(_hq._lift_hub_controls)

	# Back / Upgrades / Tuning / Test Drive form the HUB's ACTIONS row — a left/right
	# ButtonCursor (_hub_focus), the lower of the page's two cursor rows (see LiftRow). As
	# with the garage row, each button's pressed callable is also the cursor's action for
	# that index, so a click and a keyboard/gamepad select agree.
	# (No Change Car button here: changing the car is the SELECTOR row above, whose
	# chevrons swap it in place — see _cycle_lift_car.)
	var on_back := func() -> void: _hq._go_to(HqController.View.GARAGE)
	var to_tune_cb := _hq._open_lift_page.bind(HqController.LiftPage.TUNE)
	var to_upgrades_cb := _hq._open_lift_page.bind(HqController.LiftPage.UPGRADES)
	var back := _hq._station_button("< Back", on_back)
	_hq._lift_hub_controls.add_child(back)
	# The two menu buttons — Upgrades first, then Tuning.
	var to_upgrades := _hq._station_button("Upgrades", to_upgrades_cb)
	_hq._lift_hub_controls.add_child(to_upgrades)
	var to_tune := _hq._station_button("Tuning", to_tune_cb)
	_hq._lift_hub_controls.add_child(to_tune)
	# Test Drive: drive the car currently on the lift in free roam — no car picker, we're
	# already focused on one (see _test_drive). (Wheels moved into the Tuning panel
	# itself — see tuning_panel.gd — so the hub row no longer carries it.)
	var test_drive := _hq._station_button("Test Drive", _hq._test_drive)
	_hq._lift_hub_controls.add_child(test_drive)
	# (No Repair button: repair kits are gone and damage is one-way — see features/damage.md.)
	_hq._hub_cursor.setup(
		[back, to_upgrades, to_tune, test_drive],
		[on_back, to_upgrades_cb, to_tune_cb, _hq._test_drive])


func build_car_overlay() -> void:
	var made := _hq._make_overlay(16.0)
	_hq._car_layer = made[0]
	var root: VBoxContainer = made[1]

	_hq._rally_banner = _hq._label("", 22)
	root.add_child(_hq._rally_banner)

	# EMPTY and HIDDEN by default. This used to read "Choose your car" under the banner, which
	# said nothing the ◄ / ► row and the lot full of cars didn't already say — two lines of
	# header over a 3D scene the player is meant to be looking at. It survives as a node
	# because CarparkMode.PRESENT still has something real to say ("Open it to see what is
	# inside" — a one-off prompt for an object with no other affordance), and hq.gd hides it
	# again when the present flow ends.
	_hq._car_hint_label = _hq._label("", 14)
	_hq._car_hint_label.visible = false
	root.add_child(_hq._car_hint_label)

	# Push the car nav + actions to the bottom so the 3D car park is visible above.
	root.add_child(UITheme.vspacer())

	_hq._no_eligible_label = _hq._label("", 16)
	_hq._no_eligible_label.visible = false
	root.add_child(_hq._no_eligible_label)

	# Car selector: ◄ / ► pan the camera to the prev/next eligible car.
	var nav_made := _hq._build_carpark_nav_row()
	root.add_child(nav_made[0])
	# Stored so CarparkMode.PRESENT can hide the prev/next arrows: there is nothing to
	# cycle through when the lot holds one present box, but the centre LABEL is still the
	# place the revealed car's name goes.
	_hq._car_nav_row = nav_made[0]
	_hq._car_name_label = nav_made[1]

	_hq._car_stats_label = _hq._label("", 12)
	_hq._car_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(_hq._car_stats_label)

	# Engine-swap only: the post-swap power-to-weight for BOTH cars (a swap exchanges
	# engines, so both change). Coloured ↑/↓ deltas; hidden in every other car-park mode.
	_hq._swap_preview_label = RichTextLabel.new()
	_hq._swap_preview_label.bbcode_enabled = true
	_hq._swap_preview_label.fit_content = true
	_hq._swap_preview_label.scroll_active = false
	_hq._swap_preview_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hq._swap_preview_label.add_theme_font_size_override("normal_font_size", 13)
	_hq._swap_preview_label.set_meta("menu_nav_skip", true)
	_hq._swap_preview_label.visible = false
	root.add_child(_hq._swap_preview_label)

	# Shown when the focused car can't be entered as-is: wrecked (why + how to fix it).
	# An over-powered car does NOT warn here — the over-limit prompt pops as a confirm
	# dialog on Start instead (_show_over_limit_prompt), keeping the overlay compact.
	_hq._car_warning_label = _hq._label("", 14)
	_hq._car_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hq._car_warning_label.add_theme_color_override("font_color", UITheme.RED)
	_hq._car_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hq._car_warning_label.visible = false
	root.add_child(_hq._car_warning_label)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_hq._car_back)
	actions.add_child(back)
	# (No Repair button here either — a wrecked car can never be brought back.)
	_hq._start_button = Button.new()
	_hq._start_button.text = "Start Rally"
	_hq._start_button.focus_mode = Control.FOCUS_NONE
	_hq._start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hq._start_button.pressed.connect(_hq._on_start_pressed)
	actions.add_child(_hq._start_button)
	_hq._passthrough_overlay(root)  # let taps / swipes reach the 3D lineup behind the HUD


# The Settings overlay (opened from the title screen's action row): the shared SettingsMenu
# (camera angle + mobile control scheme). Choices are highlighted and persisted via
# Save.set_setting; the same component backs the in-run pause menu, so the two pages
# stay identical.
func build_settings_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._settings_layer = made[0]
	var root: VBoxContainer = made[1]

	var title := _hq._label("SETTINGS", 32)
	root.add_child(title)

	# Subtitle for the PRE-RALLY GATE only ("choose your touch controls to start"), where it
	# is the one thing explaining why the player is being made to pick. The ordinary
	# title-screen / pause entry shows nothing here — the SETTINGS heading plus the category
	# buttons already say everything a "Camera & controls:" line did, so it was pure chrome.
	# _open_settings owns both the text and the visibility.
	_hq._settings_sub = _hq._label("", 16)
	_hq._settings_sub.visible = false
	root.add_child(_hq._settings_sub)

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_hq._settings_menu = SettingsMenu.new()
	_hq._settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hq._settings_menu.page_changed.connect(_hq._on_settings_page_changed)
	_hq._settings_menu.dev_car_upgraded.connect(_hq._on_dev_car_upgraded)
	scroll.add_child(_hq._settings_menu)

	_hq._settings_action_button = Button.new()
	_hq._settings_action_button.text = "< Back"
	# Focusable so down-nav from the last category row reaches the bottom button.
	_hq._settings_action_button.focus_mode = Control.FOCUS_ALL
	_hq._settings_action_button.pressed.connect(_hq._on_settings_action)
	root.add_child(_hq._settings_action_button)

	# Framework: WASD + arrow + gamepad focus nav across the SettingsMenu rows and
	# the bottom button. No on_back — hq owns menu_back here (SettingsMenu.go_back /
	# gate handling). Inert while the settings layer is hidden.
	MenuNav.attach(root)


# --- Rally Challenge entry point (Daily/Weekly/Monthly) ------------------------
# A modal overlay over the GARAGE (built on the shared _make_modal_overlay contract —
# scrolled body, pinned footer), opened by the garage row's Online button and built lazily on
# first open (_hq._challenge_ui._open_challenge_overlay). See spec §7 and features/rally-challenge.md.
# A flat widget list -> native focus + MenuNav, not the diegetic ButtonCursor idiom
# the 3D stations use, since this whole screen is a plain menu page.
# A dark detail-card SIBLING to the rally-detail panel (build_detail_overlay, above):
# same MODAL_DIM backing, two-line header (kind + ceiling) with a non-mouse-interactive
# tab row for the kind, HSeparator, then a status column of one-row-per-section
# (_hq._challenge_info_row) so the two panels read as the same design system.
# A pointer press on a kind tab selects that kind and nothing else. Grabbing focus is
# what selects (focus_entered -> _select_challenge_kind), and accept_event() swallows the
# press so the Button never emits `pressed` — which is wired to START the challenge. That
# keeps the rule the tabs were originally written around ("`pressed` only ever comes from
# ui_accept") true for touch as well, instead of buying touch support at the price of a
# tap launching a run the player only meant to look at.
func _tab_pointer_select(event: InputEvent, btn: Button) -> void:
	var is_click := event is InputEventMouseButton and (event as InputEventMouseButton).pressed
	var is_touch := event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed
	if not (is_click or is_touch):
		return
	if not btn.has_focus():
		btn.grab_focus()  # focus_entered is the selection
	btn.accept_event()


func build_challenge_overlay() -> void:
	# Scrolled body + pinned Back/Start (_hq._make_modal_overlay): the four info rows each
	# wrap, and the eligible-cars row appends a second "Needs tune: …" line, so on the
	# short web-touch canvas the actions row was liable to be pushed off the bottom.
	var made := _hq._make_modal_overlay()
	_hq._challenge_layer = made[0]
	var root: VBoxContainer = made[1]
	var footer: HBoxContainer = made[2]
	var nav_root: Control = made[3]  # the MenuPage itself — for MenuNav.attach / UITheme.enforce
	# NO full-rect backing: MenuPage's body box IS the panel and it hugs its contents, so the
	# garage stays visible around it — a full-screen ColorRect behind it would undo that.

	# FIXED SIZE on both axes, unlike the other pages built on this shape. This screen swaps
	# its own content in place: the Daily / Weekly / Monthly tabs each have a different amount
	# to say (a longer ceiling subtitle, an extra "Needs tune:" line, a different number of
	# leaderboard rows), so a box that hugs its contents re-fits on every tab press and the
	# panel jumps around under the player — moving the very tabs being clicked. Sized for the
	# largest of the three views and pinned there. See MenuPage.set_body_fixed_height.
	var page := nav_root as MenuPage
	page.set_body_width(_hq._modal_body_width(480.0))  # clamped to the current logical canvas
	# EXACT, not a floor — a floor only stops the box getting smaller, so content taller than
	# it still grew the box and the panel kept jumping. Content taller than the pin scrolls.
	page.set_body_fixed_height(210.0)

	# --- Header: title ("Daily Challenge") + ceiling subtitle underneath, mirroring
	# _detail_title/_detail_region's two-line shape.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	# Both AUTOWRAP, which is what actually holds the panel's width steady. set_body_width is
	# only a FLOOR — a child that demands more still widens the box — and these two are the
	# only labels here that don't wrap: "Daily/Weekly/Monthly Challenge" are three different
	# lengths, and each kind's ceiling subtitle differs too, so their min width was setting
	# the panel's width and the box grew and shrank by a few px per tab. The info rows below
	# already wrap (_challenge_info_row -> _detail_wrap_label), which is why they never did
	# this.
	_hq._challenge_title_label = _hq._label("", 30)
	_hq._challenge_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hq._challenge_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(_hq._challenge_title_label)
	_hq._challenge_subtitle_label = _hq._label("", 16)
	_hq._challenge_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hq._challenge_subtitle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hq._challenge_subtitle_label.add_theme_color_override("font_color", UITheme.MUTED)
	titles.add_child(_hq._challenge_subtitle_label)

	# --- Kind tabs: Daily / Weekly / Monthly, a visible tab row (the current one
	# highlighted — see _refresh_challenge_overlay). FOCUS_ALL so keyboard/gamepad focus
	# can rest on and move across them via native left/right focus-neighbour nav
	# (menu_nav.gd); arriving via focus_entered IS the selection, with no separate
	# "confirm" press needed.
	#
	# TOUCH. These used to be MOUSE_FILTER_IGNORE — deliberately not pointer-interactive
	# at all — which left a phone with NO WAY WHATSOEVER to change kind: the tabs were
	# the only control that picks one, and menu_left/menu_right are keyboard/gamepad-only
	# actions. They are hit-testable now, but a tap must SELECT ONLY, never start: the
	# `pressed` wiring below launches the challenge, and a pointer press would otherwise
	# both move focus here (selecting) and fire `pressed` in the same gesture, so tapping
	# "Weekly" would start the Weekly run instantly. _tab_pointer_select consumes the
	# pointer press and grabs focus itself, preserving the original invariant that
	# `pressed` can only ever arrive from ui_accept.
	var kind_row := HBoxContainer.new()
	kind_row.add_theme_constant_override("separation", 6)
	header.add_child(kind_row)
	_hq._challenge_kind_buttons = []
	for kind_str in [ChallengeLibrary.DAILY, ChallengeLibrary.WEEKLY, ChallengeLibrary.MONTHLY]:
		var btn := Button.new()
		btn.text = kind_str.capitalize()
		btn.focus_mode = Control.FOCUS_ALL
		btn.mouse_filter = Control.MOUSE_FILTER_STOP  # hit-testable; see _tab_pointer_select
		btn.set_meta("challenge_kind", kind_str)
		btn.focus_entered.connect(_hq._challenge_ui._select_challenge_kind.bind(kind_str))
		btn.gui_input.connect(_tab_pointer_select.bind(btn))
		# mouse_filter IGNORE means `pressed` can only ever fire via keyboard/gamepad
		# ui_accept while this tab has focus (never a stray click) — wiring it to Start
		# means Enter starts the challenge straight from a focused tab, no need to tab
		# down to the Start button first (see _on_challenge_tab_activated).
		btn.pressed.connect(_hq._challenge_ui._on_challenge_tab_activated)
		kind_row.add_child(btn)
		_hq._challenge_kind_buttons.append(btn)

	root.add_child(HSeparator.new())

	# --- Four concise sections: win condition, win reward, eligible cars, current
	# progress. Each is ONE row — a fixed-width dim heading + the value alongside it,
	# not heading-above-value-below — so four sections cost four lines, not eight. The
	# entry requirement (the ceiling) already rides on the header subtitle, so it
	# doesn't get its own section at all.
	var body := VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 4)
	root.add_child(body)

	_hq._challenge_win_label = _hq._challenge_info_row(body, "Win condition")
	_hq._challenge_reward_label = _hq._challenge_info_row(body, "Win reward")
	_hq._challenge_eligible_label = _hq._challenge_info_row(body, "Eligible cars")
	_hq._challenge_progress_label = _hq._challenge_info_row(body, "Progress")

	# Back / Start live in the pinned footer. Both stay FOCUS_ALL: MenuNav moves focus
	# across container boundaries by geometry, so down-nav off the last info row still
	# reaches them (the arrangement build_settings_overlay already proves), and
	# MenuNav._enable_scroll_follow makes the body scroll back into view on the way up.
	var actions := footer
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_ALL
	back.pressed.connect(_hq._challenge_ui._close_challenge_overlay)
	actions.add_child(back)
	_hq._challenge_start_button = Button.new()
	_hq._challenge_start_button.text = "Start"
	_hq._challenge_start_button.focus_mode = Control.FOCUS_ALL
	_hq._challenge_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hq._challenge_start_button.pressed.connect(_hq._challenge_ui._on_challenge_start_pressed)
	actions.add_child(_hq._challenge_start_button)

	# Framework: WASD + arrow + gamepad focus nav for this flat page — the kind tabs,
	# then Back/Start below. Native left/right focus-neighbour movement (menu_nav.gd)
	# carries the player across the tab row; up/down reaches Back/Start. on_back closes
	# the overlay back to the garage, the same way every other modal overlay's Back
	# restores its host. (_open_challenge_overlay re-grabs the CURRENT kind's tab explicitly
	# on every open, so `first` here only matters as MenuNav's own fallback.)
	MenuNav.attach(nav_root, {first = _hq._challenge_kind_buttons[0], on_back = _hq._challenge_ui._close_challenge_overlay})

	# Hidden until _open_challenge_overlay shows it — this overlay is built eagerly in
	# _ready (like the per-view stations) but is a MODAL over the garage, not one of the
	# _view-switched layers _update_overlays drives, so it must start hidden by hand.
	_hq._challenge_layer.visible = false

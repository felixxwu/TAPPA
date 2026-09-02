class_name HqOverlays
extends RefCounted
# Docs: features/menus.md, features/world-panel.md — update in the same change as this file.
# Tests: tests/headless/test_menu_flow.gd, tests/headless/test_menu_nav.gd, tests/headless/test_menu_page.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'HqOverlays' tests/headless/` and read the assertions that pin what you are about to change (6 test files touch this script).
# Overlay/menu-layer builders for the HQ, extracted from hq.gd to shrink it. Each
# method builds one 2D CanvasLayer overlay and wires its buttons back to the HQ
# controller. Holds a back-reference to the HqController and reaches into it for
# state, node parenting, widget helpers, and button callbacks.

var _hq: HqController

# Widget handles this class is the only user of — built here, read by the nav tests. The rest
# of the overlay widgets stay on HqController because hq.gd or another collaborator also reads
# them; a handle with two readers is not this class's private state.
var _title_free_roam_button: Button  # EXTERIOR title Free Roam (session-less drive)
var _title_settings_button: Button  # EXTERIOR title Settings
var _title_exit_button: Button  # EXTERIOR title Exit Game (last in the row)
var _title_version_label: Label  # EXTERIOR title build-version readout (bottom-right)

func _init(hq: HqController) -> void:
	_hq = hq


func build_title_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._title_layer = made[0]
	var root: VBoxContainer = made[1]
	_hq._title_root = root
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
		var exit_btn := UITheme.row_button("Exit Game", _hq._on_exterior_exit)
		actions.add_child(exit_btn)
		_title_exit_button = exit_btn
		buttons.append(exit_btn)
		acts.append(_hq._on_exterior_exit)
	# Free Roam: a session-less drive in any catalogue car. It lives HERE, not in the
	# garage, because it isn't a career action — it needs no owned car, no session and no
	# lift, so making the player walk into the garage to reach it was a detour through
	# state it doesn't use. Back out of its picker returns to this screen
	# (CarparkMode.FREEROAM in _carpark_back). This slot used to hold Account, which is
	# reachable as a Settings page instead — one route, not two.
	var free_roam := UITheme.row_button("Free Roam", _hq._enter_free_roam)
	actions.add_child(free_roam)
	_title_free_roam_button = free_roam
	buttons.append(free_roam)
	acts.append(_hq._enter_free_roam)
	# Settings: the shared camera/controls page. Moved here from the garage action row —
	# Back from it now always returns to the title (see _on_settings_action / the
	# SETTINGS branch in _unhandled_input).
	var to_settings_cb := _hq._open_settings.bind(false)
	var settings := UITheme.row_button("Settings", to_settings_cb)
	actions.add_child(settings)
	_title_settings_button = settings
	buttons.append(settings)
	acts.append(to_settings_cb)
	var start := UITheme.row_button("Start", _hq._on_exterior_start)
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
	version_label.add_theme_font_size_override("font_size", UITheme.px(12))
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
	# On its own CanvasLayer (see _hq._version_layer) so it survives the title screen
	# migrating to a 3D panel; update_overlays shows it with the title.
	_hq._version_layer = CanvasLayer.new()
	_hq.add_child(_hq._version_layer)
	_hq._version_layer.add_child(version_label)
	_title_version_label = version_label

	# EXTERIOR is now driven by menu_left/menu_right/menu_select over _title_cursor (see
	# _unhandled_input), the same diegetic idiom as the garage row and lift hub — no
	# MenuNav here. hq re-seats the cursor on Start itself on view entry (go_to).


func build_garage_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._garage_layer = made[0]
	var root: VBoxContainer = made[1]
	_hq._garage_root = root

	# NOTHING over the room but the action row. This used to carry "GARAGE — tap the map table
	# to choose a rally, or the lift to tune your car": a caption naming the room you can see,
	# plus instructions for two objects that are already lit, labelled and pickable in the 3D
	# scene. The garage is a diegetic station — the room IS the menu — so a line of prose over
	# it only competes with the thing it describes.
	#
	# The last line standing up here was the NEXT CARROT readout, naming the nearest locked
	# special. It went the same way: once the progression stopped being a tally of rallies it
	# had no number to quote, and the specials it names are mostly titled after their own
	# reward ("Upgrade: Supercharger"), so it ended up a bare rally name hanging over the
	# garage with nothing to say why. The map table still teases that special where it stands
	# on the map (hq._build_special_teaser_label), which is the readout that reads.

	root.add_child(UITheme.vspacer())

	# The bottom action row is rebuilt IN PLACE by hq._refresh_garage_row():
	# Back / Career / Garage / Mystery Box (N) / Online, ONE level (Mystery Box appears
	# only when one is held). FOCUS_NONE + hand-painted like the tuning hub, since the
	# garage is a spatially-navigated 3D station, not a native focus graph. (Repair is
	# per-CAR so it lives on the tuning-lift HUB row — see build_lift_overlay. Settings and
	# Free Roam live on the title screen — see build_title_overlay.)
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
	_hq._reveal_banner = _hq.label("", 20)
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
	_hq._map_meter = _hq.label("", 20)
	_hq._map_meter.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	meter_row.add_child(_hq._map_meter)

	var back := Button.new()
	back.text = "< Back to garage"
	back.focus_mode = Control.FOCUS_NONE
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(func() -> void: _hq.go_to(HqController.View.GARAGE))
	root.add_child(back)

	_hq._passthrough_overlay(root)  # let taps / drags reach the 3D map pins behind the HUD


# The RALLY-DETAIL PANEL is no longer built here. It moved to RallyDetail
# (scripts/rally_detail.gd) whole — build half, fill half and state — so the overworld hub can
# open the same card; hq.gd::_build_hq constructs it and wires its three callbacks. See
# todo/hq-split.md for the extraction discipline and docs/superpowers/specs/
# 2026-08-17-overworld-hq-design.md → "The detail-panel extraction" for why.


func build_lift_overlay() -> void:
	_hq._lift_layer = CanvasLayer.new()
	_hq.add_child(_hq._lift_layer)

	# ONE full-rect root under the layer, holding BOTH of this screen's anchored children
	# (the sub-page and the hub column below). A WorldPanel hosts a single Control, so the
	# screen needs one handle to move between hosts — and both children keep their own
	# anchors, resolved against this root instead of the layer, so the flat layout is
	# unchanged. PASS so it doesn't swallow presses meant for the buttons inside it.
	_hq._lift_root = Control.new()
	_hq._lift_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hq._lift_root.mouse_filter = Control.MOUSE_FILTER_PASS
	_hq._lift_layer.add_child(_hq._lift_root)

	# --- The sub-menu page (shown on the TUNE / UPGRADES pages) ---
	# The house page shape, from the shared MenuPage widget: a body box that HUGS its
	# contents with a gap to the screen edges, and the page's actions in one horizontal row
	# gapped below it. See menu_page.gd for why those two are rules rather than per-screen
	# choices. This screen used to hand-roll a full-height ColorRect, which both painted a
	# black field over the whole bay and enclosed the action row so the buttons read as body
	# content.
	#
	var page := MenuPage.new({"margin": 12.0})
	_hq._lift_root.add_child(page)
	_hq._lift_menu_bg = page.panel()
	# LEFT-ALIGN THE SUB-PAGE ON A WORLD PANEL. MenuPage centres its panel and its action row, which is
	# right for a modal over a screen — but on the lift it meant the Upgrades/Tuning page sat at a
	# different left edge from the hub rows below it (and moved as its content width changed). Opting in
	# lets WorldPanel.apply_host_style share one left edge per host and restore centring when flat.
	_hq._lift_menu_bg.set_meta(WorldPanel.ALIGN_BEGIN_META, true)
	page.actions().set_meta(WorldPanel.ALIGN_BEGIN_META, true)
	var root: VBoxContainer = page.body()

	# NO PAGE HEADING HERE. The lift's own heading only ever read "UPGRADES" and was only
	# ever visible on the UPGRADES page — which is exactly the page whose component draws
	# its own heading (UpgradesGrid.build_title_row, carrying the star balance so all four
	# hosts show it). Two identical titles stacked on one page; the component keeps its one
	# because the other three hosts have no heading of their own to lend it.

	# MenuPage already wraps the body in a scroll safety net for very short logical
	# canvases, so the page's rows go straight into its body.
	var content := root

	_hq._tune_panel = TuningPanel.new()
	content.add_child(_hq._tune_panel)
	# The UPGRADES page is the reusable UpgradesGrid component (shared with the car-park
	# Change-Upgrades popup, the start line and the upgrade reveal). It attaches + preserves
	# its own MenuNav across rebuilds; the lift wires on_change + the engine-swap action in
	# _refresh_lift_ui. See features/upgrade-catalogue.md.
	_hq._lift_upgrades_box = UpgradesGrid.new()
	content.add_child(_hq._lift_upgrades_box)

	# Framework: WASD + arrow + gamepad focus nav for the native-focus TUNE (sliders)
	# sub-page. Attached to the tune box ONLY — not the lift root — so the diegetic HUB
	# buttons (FOCUS_NONE, manual left/right cursor) are left untouched. The box goes
	# inert while hidden (_menu_visible). The UpgradesGrid self-attaches its own nav.
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
	# Bottom-anchored is right FLAT (a row over the 3D bay) but wrong on a world panel, where the panel
	# is the menu and there is nothing behind it to leave room for — the hub sat low while MenuPage
	# centred the Upgrades/Tuning body, so the content jumped bands when switching pages. Opting in
	# lets WorldPanel.apply_host_style centre it per host and put it back when flat.
	left_col.set_meta(WorldPanel.CENTER_META, true)
	_hq._lift_root.add_child(left_col)

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
	_hq._lift_prev_button = UITheme.row_button("<", _hq._cycle_lift_car.bind(-1))
	selector.add_child(_hq._lift_prev_button)

	# The name sits in a box of its own, matched to the chevrons' height so the three
	# read as one control. Not clickable: there is nothing for a press on the name to do
	# that the chevrons either side don't already say more clearly.
	var name_box := PanelContainer.new()
	name_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_box.custom_minimum_size.y = UITheme.MENU_ROW_H
	name_box.add_theme_stylebox_override("panel", UITheme.readout_box())
	selector.add_child(name_box)
	_hq._lift_car_label = _hq.label("", 14)
	_hq._lift_car_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_box.add_child(_hq._lift_car_label)

	_hq._lift_next_button = UITheme.row_button(">", _hq._cycle_lift_car.bind(1))
	selector.add_child(_hq._lift_next_button)

	# REPAIR sits here, beside the car it acts on, rather than in the actions row below.
	# That row had outgrown the screen — Back / Upgrades / Tuning / Repair / Test Drive ran
	# off the right edge — and Repair is the one of the five that is about THIS car's
	# condition, which the stats line right underneath is already reporting. The other four
	# are navigation.
	#
	# Always built, never conditionally hidden: unlike a locked part option, "your car is
	# fine" and "you cannot afford it" are both things the player can read off the label and
	# act on, so the button states them instead of vanishing. hq._refresh_repair_button()
	# writes its text and disabled state on every repaint.
	_hq._lift_repair_button = UITheme.row_button("Repair", _hq._repair_selected_car)
	selector.add_child(_hq._lift_repair_button)

	# The selector is the HUB's second cursor row. Same contract as the actions row below
	# it: each button's `pressed` callable is also the cursor's action for that index, so a
	# click and a keyboard/gamepad select can't drift apart. Repair joins it so moving the
	# button did not cost it keyboard/gamepad reachability (features/menus.md).
	_hq._lift_selector_cursor.setup(
		[_hq._lift_prev_button, _hq._lift_next_button, _hq._lift_repair_button],
		[_hq._cycle_lift_car.bind(-1), _hq._cycle_lift_car.bind(1),
			_hq._repair_selected_car])

	# Row 2: the stats line for whichever car the selector landed on.
	var stats_box := PanelContainer.new()
	stats_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stats_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stats_box.custom_minimum_size.y = UITheme.MENU_ROW_H
	stats_box.add_theme_stylebox_override("panel", UITheme.readout_box())
	info_panel.add_child(stats_box)
	_hq._lift_car_stats_label = _hq.label("", 14)
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
	var on_back := func() -> void: _hq.go_to(HqController.View.GARAGE)
	var to_tune_cb := _hq._open_lift_page.bind(HqController.LiftPage.TUNE)
	var to_upgrades_cb := _hq._open_lift_page.bind(HqController.LiftPage.UPGRADES)
	var back := UITheme.row_button("< Back", on_back)
	_hq._lift_hub_controls.add_child(back)
	# The two menu buttons — Upgrades first, then Tuning.
	var to_upgrades := UITheme.row_button("Upgrades", to_upgrades_cb)
	_hq._lift_hub_controls.add_child(to_upgrades)
	var to_tune := UITheme.row_button("Tuning", to_tune_cb)
	_hq._lift_hub_controls.add_child(to_tune)
	# Test Drive: drive the car currently on the lift in free roam — no car picker, we're
	# already focused on one (see _test_drive). (Wheels moved into the Tuning panel
	# itself — see tuning_panel.gd — so the hub row no longer carries it.)
	# Repair: spend stars to put the car on the lift back to full health with straight
	# wheels (features/star-economy.md). It lives HERE rather than on the garage row because
	# it acts on ONE car — the lift is the station where you work on the car in front of you,
	# and the garage row is for garage-wide actions. It is built UP IN THE SELECTOR ROW,
	# beside the car name, because this row ran out of width — see there.
	#
	# Test Drive stays RIGHTMOST: the house rule is that leaving is leftmost and proceeding
	# is rightmost (features/menus.md → "Button order"), and driving the car is the one
	# action here that leaves the station.
	var test_drive := UITheme.row_button("Test Drive", _hq._test_drive)
	_hq._lift_hub_controls.add_child(test_drive)
	_hq._hub_cursor.setup(
		[back, to_upgrades, to_tune, test_drive],
		[on_back, to_upgrades_cb, to_tune_cb, _hq._test_drive])


func build_car_overlay() -> void:
	var made := _hq._make_overlay(16.0)
	_hq._car_layer = made[0]
	var root: VBoxContainer = made[1]
	# Held so the tree can be moved between its CanvasLayer and a world-space
	# WorldPanel at runtime (hq.gd::_sync_panel). The tree itself is built exactly
	# the same either way — only its container changes.
	_hq._car_root = root

	_hq._rally_banner = _hq.label("", 22)
	_hq._rally_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Autowrap so a long rally name + restriction WRAPS instead of running off the edge. It
	# never wraps on the flat full-width canvas; it is the narrow world-panel canvas that
	# needs it (see WorldPanel.text_backing).
	_hq._rally_banner.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(WorldPanel.text_backing(_hq._rally_banner))

	# EMPTY and HIDDEN by default. This used to read "Choose your car" under the banner, which
	# said nothing the ◄ / ► row and the lot full of cars didn't already say — two lines of
	# header over a 3D scene the player is meant to be looking at. It survives as a node
	# because CarparkMode.PRESENT still has something real to say ("Open it to see what is
	# inside" — a one-off prompt for an object with no other affordance), and hq.gd hides it
	# again when the present flow ends.
	_hq._car_hint_label = _hq.label("", 14)
	_hq._car_hint_label.visible = false
	root.add_child(WorldPanel.text_backing(_hq._car_hint_label))

	# Push the car nav + actions to the bottom so the 3D car park is visible above.
	root.add_child(UITheme.vspacer())

	_hq._no_eligible_label = _hq.label("", 16)
	_hq._no_eligible_label.visible = false
	root.add_child(WorldPanel.text_backing(_hq._no_eligible_label))

	# Car selector: ◄ / ► pan the camera to the prev/next eligible car.
	var nav_made := _hq._build_carpark_nav_row()
	root.add_child(nav_made[0])
	# Stored so CarparkMode.PRESENT can hide the prev/next arrows: there is nothing to
	# cycle through when the lot holds one present box, but the centre LABEL is still the
	# place the revealed car's name goes.
	_hq._car_nav_row = nav_made[0]
	_hq._car_name_label = nav_made[1]

	_hq._car_stats_label = _hq.label("", 12)
	_hq._car_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Same reason as the banner: the stats line is long ("AWD | 307 HP | 1336 KG | HEALTH …")
	# and was being cut off at the panel's edge rather than wrapping.
	_hq._car_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(WorldPanel.text_backing(_hq._car_stats_label))

	# Engine-swap only: the post-swap power-to-weight for BOTH cars (a swap exchanges
	# engines, so both change). Coloured ↑/↓ deltas; hidden in every other car-park mode.
	_hq._swap_preview_label = RichTextLabel.new()
	_hq._swap_preview_label.bbcode_enabled = true
	_hq._swap_preview_label.fit_content = true
	_hq._swap_preview_label.scroll_active = false
	_hq._swap_preview_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hq._swap_preview_label.add_theme_font_size_override("normal_font_size", UITheme.px(13))
	_hq._swap_preview_label.set_meta("menu_nav_skip", true)
	_hq._swap_preview_label.visible = false
	root.add_child(WorldPanel.text_backing(_hq._swap_preview_label))

	# Shown when the focused car handles badly (why + how to fix it). Advisory only — damage
	# never blocks entry (features/damage.md).
	# An over-powered car does NOT warn here — the over-limit prompt pops as a confirm
	# dialog on Start instead (_show_over_limit_prompt), keeping the overlay compact.
	_hq._car_warning_label = _hq.label("", 14)
	_hq._car_warning_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hq._car_warning_label.add_theme_color_override("font_color", UITheme.RED)
	_hq._car_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hq._car_warning_label.visible = false
	root.add_child(WorldPanel.text_backing(_hq._car_warning_label))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	var back := Button.new()
	back.text = "< Back"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_hq._car_back)
	actions.add_child(back)
	# Kept on the controller so the present-box reveal can hide it — that beat is forced.
	_hq._car_back_button = back
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

	var title := _hq.label("SETTINGS", 32)
	root.add_child(title)

	# Subtitle for the PRE-RALLY GATE only ("choose your touch controls to start"), where it
	# is the one thing explaining why the player is being made to pick. The ordinary
	# title-screen / pause entry shows nothing here — the SETTINGS heading plus the category
	# buttons already say everything a "Camera & controls:" line did, so it was pure chrome.
	# _open_settings owns both the text and the visibility.
	_hq._settings_sub = _hq.label("", 16)
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
# A dark detail-card SIBLING to the rally-detail panel (RallyDetail.build):
# same MODAL_DIM backing, two-line header (kind + ceiling) with a non-mouse-interactive
# tab row for the kind, HSeparator, then a status column of one-row-per-section
# (_hq.challenge_info_row) so the two panels read as the same design system.
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
	#
	# BOTH numbers are AUTHORED sizes and so BOTH must be inflated by UITheme.UI_SCALE, exactly
	# like the fonts inside them (features/ui-design-system.md → "UI scale"). They were literals
	# in raw logical pixels, which is why this screen went cramped when the UI was rescaled: the
	# text got its genuinely larger point size and the box that has to hold it did not, so the
	# fixed height clipped the info rows into the body scroll and the column was ~a quarter too
	# narrow, wrapping values that used to fit on one line. A box pinned in logical pixels
	# around text measured in scaled pixels is always a bug — pin both in the same units.
	var page := nav_root as MenuPage
	page.set_body_width(_hq._modal_body_width(480.0 * UITheme.UI_SCALE))  # clamped to the canvas
	# EXACT, not a floor — a floor only stops the box getting smaller, so content taller than
	# it still grew the box and the panel kept jumping. Content taller than the pin scrolls.
	page.set_body_fixed_height(250.0 * UITheme.UI_SCALE)

	# --- Header: title ("Daily Challenge") + ceiling subtitle underneath, mirroring
	# RallyDetail's title/region two-line shape.
	# Titles get the FULL column width — the kind tabs used to sit beside them in this row, so
	# the header demanded title-width PLUS tab-row-width and the two headline strings were
	# squeezed into whatever was left. That squeeze is what wrapped them.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UITheme.px(12))
	root.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	# NEITHER WRAPS. "Daily Challenge" and the "Rating NNN max" ceiling line are the screen's
	# two headline strings and each must read as ONE line — a title broken across two lines
	# reads as a layout fault, not as a heading.
	#
	# They used to autowrap, to stop their differing lengths (three kind names, three ceiling
	# figures) from setting the panel's width and jittering the box a few px per tab, because
	# set_body_width is only a FLOOR — a child that demands more still widens the box. That
	# defence is no longer load-bearing: the floor is now the authored width times UI_SCALE
	# (see above), which is several times what either of these short strings measures, so
	# neither can reach past it however the kind changes. The jitter guard is
	# test_menu_flow.gd::test_hq_challenge_screen_keeps_one_size_across_the_kind_tabs — if a
	# future retune drops the floor below these strings, that test is what catches it.
	#
	# The info rows below still wrap (challenge_info_row -> detail_wrap_label): those carry
	# sentences, not headings, and are the right place to spend vertical space.
	#
	# NOT clipped either — every character of both lines must be readable. That is affordable
	# only because the kind tabs no longer sit beside the title (see the tab row below): the
	# header's width demand is now the LONGER of title-or-tabs instead of their sum, which
	# leaves both comfortably inside the pinned column, so neither has to wrap, clip, or push
	# the box wider.
	_hq._challenge_title_label = _hq.label("", 30)
	_hq._challenge_title_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_hq._challenge_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	titles.add_child(_hq._challenge_title_label)
	_hq._challenge_subtitle_label = _hq.label("", 16)
	_hq._challenge_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_OFF
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
	# THEIR OWN ROW, under the title — not beside it. Side by side, the header's minimum width
	# was title + three tabs, which is what made this screen too narrow for its own text at the
	# scaled-up font: the titles were left a fraction of the column and broke across lines.
	# Stacked, the row costs one line of height (the box is pinned taller to match) and the
	# header's width demand drops to the LONGER of the two instead of their sum, so the title,
	# the ceiling subtitle and all three tabs each show in full.
	var kind_row := HBoxContainer.new()
	kind_row.add_theme_constant_override("separation", UITheme.px(6))
	root.add_child(kind_row)
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
	body.add_theme_constant_override("separation", UITheme.px(4))
	root.add_child(body)

	_hq._challenge_win_label = _hq.challenge_info_row(body, "Win condition")
	_hq._challenge_reward_label = _hq.challenge_info_row(body, "Win reward")
	_hq._challenge_eligible_label = _hq.challenge_info_row(body, "Eligible cars")
	_hq._challenge_progress_label = _hq.challenge_info_row(body, "Progress")

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
	# _view-switched layers update_overlays drives, so it must start hidden by hand.
	_hq._challenge_shown = false
	_hq._challenge_layer.visible = false


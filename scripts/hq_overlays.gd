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

	# Title screen is a flat list of buttons (Start, plus Exit Game on non-web
	# builds) over the parked-collection backdrop — no title/subtitle text. It uses native
	# focus: Start is focused on entry, ui_up/ui_down move between the buttons, ui_accept
	# fires the focused one. (The 3D stations behind it keep menu_* nav.) Settings lives on
	# the garage action row now, not here (see build_garage_overlay).
	_hq._title_start_button = _hq._title_button(root, "Start", 52.0, _hq._on_exterior_start)
	# Exit Game: quit the application. Sits at the bottom of the title list. Skipped on
	# the web build, where there's no OS process to quit (the tab owns the lifecycle).
	if not Platform.is_web():
		_hq._title_exit_button = _hq._title_button(root, "Exit Game", 44.0, _hq._on_exterior_exit)

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

	# Framework: WASD + arrow + gamepad focus nav for the flat Start (+ Exit Game) menu
	# (no on_back — EXTERIOR has no back; the diegetic stations behind keep menu_*).
	# MenuNav goes inert while _title_layer is hidden, so it never steals input from
	# the 3D stations. hq re-grabs focus itself on view entry.
	MenuNav.attach(root, {first = _hq._title_start_button})


func build_garage_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._garage_layer = made[0]
	var root: VBoxContainer = made[1]

	var hint := _hq._label("GARAGE — tap the map table to choose a rally, or the lift to tune your car", 22)
	root.add_child(hint)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	# Back / Career / Garage / Free Roam / Settings form a single left/right ButtonCursor
	# (_garage_focus). FOCUS_NONE + hand-painted like the tuning hub, since the garage is
	# a spatially-navigated 3D station, not a native focus graph. Each button's pressed
	# callable is ALSO the cursor's action for that index, so click and select agree.
	# (Repair lives on the tuning-lift HUB row now — see build_lift_overlay.)
	var on_back := func() -> void: _hq._go_to(HqController.View.EXTERIOR)
	var back := _hq._station_button("< Back", on_back)
	actions.add_child(back)
	# Convenience button mirroring the clickable 3D table.
	var to_table := _hq._station_button("Career", _hq._enter_table)
	actions.add_child(to_table)
	# Garage: open the car park to pick which owned car to work on, then drop straight
	# into the tuning lift bay for that car (see _open_garage_picker / _select_garage_car).
	var to_garage := _hq._station_button("Garage", _hq._open_garage_picker)
	actions.add_child(to_garage)
	# Free Roam: open the car park across the WHOLE catalogue (owned or not) and drop into
	# a session-less drive in the picked car (see _enter_free_roam / _start_free_roam).
	var to_free := _hq._station_button("Free Roam", _hq._enter_free_roam)
	actions.add_child(to_free)
	# Settings: the shared camera/controls page. Back from it returns to the garage
	# (see _on_settings_action / the SETTINGS branch in _unhandled_input).
	var to_settings_cb := _hq._open_settings.bind(false)
	var to_settings := _hq._station_button("Settings", to_settings_cb)
	actions.add_child(to_settings)
	_hq._garage_cursor.setup(
		[back, to_table, to_garage, to_free, to_settings],
		[on_back, _hq._enter_table, _hq._open_garage_picker, _hq._enter_free_roam, to_settings_cb])

	_hq._passthrough_overlay(root)  # let taps reach the 3D table / lift behind the HUD


func build_table_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._table_layer = made[0]
	var root: VBoxContainer = made[1]

	_hq._map_meter = _hq._label("", 14)
	root.add_child(_hq._map_meter)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	var back := Button.new()
	back.text = "< Back to garage"
	back.focus_mode = Control.FOCUS_NONE
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(func() -> void: _hq._go_to(HqController.View.GARAGE))
	root.add_child(back)

	_hq._passthrough_overlay(root)  # let taps / drags reach the 3D map pins behind the HUD


func build_detail_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._detail_layer = made[0]
	var root: VBoxContainer = made[1]
	# A solid backing so the detail reads as a panel over the map.
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.0, 0.0, 0.0, 0.96)
	_hq._detail_layer.add_child(bg)
	_hq._detail_layer.move_child(bg, 0)

	# Everything below is uppercased + locked to one font size by UITheme.enforce
	# (via _normalize_menus on each view change), so hierarchy comes from layout,
	# colour and separators — not font size. Stars are a polygon StarRow, since
	# Syne Mono has no ★ glyph.

	# --- Header: title + region on the left, a gold SHOWDOWN chip on the right.
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	root.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	_hq._detail_title = _hq._label("", 30)
	titles.add_child(_hq._detail_title)
	_hq._detail_region = _hq._label("", 16)
	_hq._detail_region.add_theme_color_override("font_color", UITheme.MUTED)
	titles.add_child(_hq._detail_region)
	_hq._detail_showdown = _hq._label("SHOWDOWN", 16)
	_hq._detail_showdown.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hq._detail_showdown.add_theme_color_override("font_color", UITheme.GOLD)
	header.add_child(_hq._detail_showdown)

	root.add_child(HSeparator.new())

	# --- Two columns: STAGES (left) | status sidebar (right). Laid out as two halves
	# ANCHORED to 50% each (not an HBox), so the split is always exactly equal — an HBox
	# only shares LEFTOVER space by ratio and keeps each column's content-driven minimum
	# first, which left the wider STAGES side bigger. `cols` is a plain Control that fills
	# the remaining height; the two halves anchor to its left/right with a centre gutter.
	const HALF_GUTTER := 16.0
	var cols := Control.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(cols)

	var left := VBoxContainer.new()
	left.anchor_left = 0.0
	left.anchor_right = 0.5
	left.anchor_top = 0.0
	left.anchor_bottom = 1.0
	left.offset_right = -HALF_GUTTER
	cols.add_child(left)
	left.add_child(_hq._detail_heading("Stages"))
	_hq._detail_stages = VBoxContainer.new()
	_hq._detail_stages.add_theme_constant_override("separation", 8)
	left.add_child(_hq._detail_stages)
	_hq._detail_combined = _hq._label("", 16)
	_hq._detail_combined.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hq._detail_combined.add_theme_color_override("font_color", UITheme.INK_DIM)
	left.add_child(_hq._detail_combined)

	# A thin centre divider between the two halves.
	var divider := ColorRect.new()
	divider.color = UITheme.INK_DIM
	divider.anchor_left = 0.5
	divider.anchor_right = 0.5
	divider.anchor_top = 0.0
	divider.anchor_bottom = 1.0
	divider.offset_left = -1.0
	divider.offset_right = 1.0
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(divider)

	var right := VBoxContainer.new()
	right.anchor_left = 0.5
	right.anchor_right = 1.0
	right.anchor_top = 0.0
	right.anchor_bottom = 1.0
	right.offset_left = HALF_GUTTER
	right.add_theme_constant_override("separation", 4)
	cols.add_child(right)
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

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	var back := Button.new()
	back.text = "< Map"
	back.focus_mode = Control.FOCUS_NONE
	back.pressed.connect(_hq._hide_detail)
	actions.add_child(back)
	var enter := Button.new()
	enter.text = "Enter Rally — choose car >"
	enter.focus_mode = Control.FOCUS_NONE
	enter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enter.pressed.connect(_hq._enter_car_screen)
	actions.add_child(enter)


func build_lift_overlay() -> void:
	var frac: float = Config.data.hq_lift_menu_centered_width_frac
	_hq._lift_layer = CanvasLayer.new()
	_hq.add_child(_hq._lift_layer)

	# --- The sub-menu panel (shown on the TUNE / UPGRADES pages) ---
	# Centred horizontally and wide (hq_lift_menu_centered_width_frac) so an open page
	# uses most of the screen; the car description hides while it's up (_refresh_lift_ui).
	_hq._lift_menu_bg = ColorRect.new()
	_hq._lift_menu_bg.anchor_left = (1.0 - frac) * 0.5
	_hq._lift_menu_bg.anchor_right = 1.0 - (1.0 - frac) * 0.5
	_hq._lift_menu_bg.anchor_top = 0.0
	_hq._lift_menu_bg.anchor_bottom = 1.0
	_hq._lift_menu_bg.color = Color(0.0, 0.0, 0.0, 0.96)
	_hq._lift_layer.add_child(_hq._lift_menu_bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	_hq._lift_menu_bg.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	_hq._lift_menu_title = _hq._label("", 22)
	root.add_child(_hq._lift_menu_title)

	# A scroll container is kept as a safety net for very short screens, but with each
	# menu on its own page (no hub controls or tab strip above it) the content is
	# meant to fit without scrolling.
	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

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

	# The shared "< Back" for both sub-pages. Focusable so keyboard/gamepad can reach it:
	# it lives in `root` (a sibling of the scroll, below the page content), and the box
	# MenuNavs drive focus across container boundaries by geometry, so down-nav off the
	# last slider / upgrade row lands here. It's also the focus fallback for a page whose
	# body has no focusable control (a fresh car's Upgrades page — see _open_lift_page).
	_hq._lift_back_button = Button.new()
	_hq._lift_back_button.text = "< Back"
	_hq._lift_back_button.focus_mode = Control.FOCUS_ALL
	_hq._lift_back_button.pressed.connect(_hq._lift_hub)
	root.add_child(_hq._lift_back_button)

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

	_hq._lift_info_panel = PanelContainer.new()
	var info_panel := _hq._lift_info_panel
	info_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Solid black, sharp-cornered house panel (design system).
	info_panel.add_theme_stylebox_override("panel", UITheme.panel_box(0.82, 14))
	left_col.add_child(info_panel)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 4)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_panel.add_child(info)
	_hq._lift_car_label = _hq._label("", 14)
	_hq._lift_car_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hq._lift_car_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_child(_hq._lift_car_label)

	# The hub controls UNDER the car description: a SINGLE bottom row holding Back, the
	# Tuning / Upgrades buttons, and a Test Drive button. Shown only on the HUB page
	# (_refresh_lift_ui). Hugs content on the left so the raised car stays in clear view.
	_hq._lift_hub_controls = HBoxContainer.new()
	_hq._lift_hub_controls.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_hq._lift_hub_controls.add_theme_constant_override("separation", 8)
	_hq._lift_hub_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left_col.add_child(_hq._lift_hub_controls)

	# Back / Tuning / Upgrades / Test Drive form a single left/right ButtonCursor
	# (_hub_focus). As with the garage row, each button's pressed callable is also the
	# cursor's action for that index, so a click and a keyboard/gamepad select agree.
	# (No Change Car here: pick a different car via the garage's Garage button, which
	# reopens the car park.)
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
	# already focused on one (see _test_drive).
	var test_drive := _hq._station_button("Test Drive", _hq._test_drive)
	_hq._lift_hub_controls.add_child(test_drive)
	# Repair: spend one Repair Kit on the selected car (full restore). HIDDEN for now —
	# earning Repair Kits is disabled, so there's nothing to spend. The button is still
	# built (and _refresh_lift_repair_button still labels it) but kept invisible and OUT
	# of the hub cursor so it's neither shown nor navigable; re-add it to both when kits
	# come back.
	var repair := _hq._station_button("Repair", _hq._repair_selected_car)
	repair.visible = false
	_hq._lift_hub_controls.add_child(repair)
	_hq._lift_repair_button = repair
	_hq._hub_cursor.setup(
		[back, to_upgrades, to_tune, test_drive],
		[on_back, to_upgrades_cb, to_tune_cb, _hq._test_drive])


func build_car_overlay() -> void:
	var made := _hq._make_overlay(16.0)
	_hq._car_layer = made[0]
	var root: VBoxContainer = made[1]

	_hq._rally_banner = _hq._label("", 22)
	root.add_child(_hq._rally_banner)

	var hint := _hq._label("Choose your car", 14)
	root.add_child(hint)

	# Push the car nav + actions to the bottom so the 3D car park is visible above.
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(spacer)

	_hq._no_eligible_label = _hq._label("", 16)
	_hq._no_eligible_label.visible = false
	root.add_child(_hq._no_eligible_label)

	# Car selector: ◄ / ► pan the camera to the prev/next eligible car.
	var nav_made := _hq._build_carpark_nav_row()
	root.add_child(nav_made[0])
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
	# Repair the focused wrecked car (uses one kit, restores full health, enables Start).
	# Hidden unless the focused car is wrecked AND a Repair Kit is owned.
	_hq._car_repair_button = Button.new()
	_hq._car_repair_button.text = "Repair (1 kit)"
	_hq._car_repair_button.focus_mode = Control.FOCUS_NONE
	_hq._car_repair_button.visible = false
	_hq._car_repair_button.pressed.connect(_hq._repair_focused_car)
	actions.add_child(_hq._car_repair_button)
	_hq._start_button = Button.new()
	_hq._start_button.text = "Start Rally"
	_hq._start_button.focus_mode = Control.FOCUS_NONE
	_hq._start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hq._start_button.pressed.connect(_hq._on_start_pressed)
	actions.add_child(_hq._start_button)
	_hq._passthrough_overlay(root)  # let taps / swipes reach the 3D lineup behind the HUD


# The Settings overlay (opened from the garage action row): the shared SettingsMenu
# (camera angle + mobile control scheme). Choices are highlighted and persisted via
# Save.set_setting; the same component backs the in-run pause menu, so the two pages
# stay identical.
func build_settings_overlay() -> void:
	var made := _hq._make_overlay()
	_hq._settings_layer = made[0]
	var root: VBoxContainer = made[1]

	var title := _hq._label("SETTINGS", 32)
	root.add_child(title)

	_hq._settings_sub = _hq._label("Camera & controls:", 16)
	root.add_child(_hq._settings_sub)

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_hq._settings_menu = SettingsMenu.new()
	_hq._settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hq._settings_menu.page_changed.connect(_hq._on_settings_page_changed)
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

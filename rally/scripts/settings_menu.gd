class_name SettingsMenu
extends VBoxContainer
# A reusable settings panel shared by the HQ title screen and the in-run pause
# menu, so both present the SAME options. It opens on a LIST of categories; each
# row drills into its own sub-page:
#   • Camera — pick the camera angle (chase / bonnet), persisted under
#     CameraManager.SETTING_KEY. Emits `camera_changed` so a live scene (the run's
#     CameraManager) can switch immediately; the HQ has no camera so it just saves
#     and the choice is applied on the next run.
#   • Mobile controls — pick the touch control scheme (MobileControls.SCHEMES),
#     persisted under MobileControls.SETTING_KEY. Each row carries a vector layout
#     diagram (ControlSchemeDiagram), as on the original title-screen page.
# Navigation is internal: show_list()/show_camera()/show_schemes() swap which page
# is visible. `page_changed(is_root)` lets the host adapt its single bottom button
# — on a sub-page it means "< Back" (to the list); on the list it means the host's
# own action (exit Settings, or Start in the pre-rally gate). Choices are stored
# via Save.set_setting. The host wraps this whole VBox in a (touch) ScrollContainer;
# only the visible page contributes height, so the long schemes page scrolls while
# the short list/camera pages don't.

signal camera_changed(mode: int)
# Emitted on every page switch; is_root == the category list is showing.
signal page_changed(is_root: bool)

# Selectable rows, exposed for tests / hosts: [{key: Variant, button: Button}].
var camera_rows: Array = []
var scheme_rows: Array = []

# The swappable pages (only one visible at a time).
var _list_page: VBoxContainer
var _camera_page: VBoxContainer
var _scheme_page: VBoxContainer
var _dev_page: VBoxContainer
var _dev_status: Label  # feedback line on the dev page ("Granted …", "Wiped …")


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build()
	UITheme.enforce(self)  # house rules: uppercase + one font size
	show_list()


func _build() -> void:
	# Category list — one nav row per sub-page.
	_list_page = _make_page()
	add_child(_list_page)
	_list_page.add_child(_make_sub("Choose a category:"))
	_list_page.add_child(_make_nav_button("Camera", show_camera))
	_list_page.add_child(_make_nav_button("Mobile controls", show_schemes))
	_list_page.add_child(_make_nav_button("Dev", show_dev))

	# Camera sub-page.
	_camera_page = _make_page()
	add_child(_camera_page)
	_camera_page.add_child(_make_heading("Camera"))
	_camera_page.add_child(_make_sub("Pick your camera angle:"))
	camera_rows.clear()
	for entry in CameraManager.MODES:
		_camera_page.add_child(_make_camera_row(int(entry["mode"]), entry))

	# Mobile-controls sub-page.
	_scheme_page = _make_page()
	add_child(_scheme_page)
	_scheme_page.add_child(_make_heading("Mobile controls"))
	_scheme_page.add_child(_make_sub("Pick a touch layout:"))
	scheme_rows.clear()
	for entry in MobileControls.SCHEMES:
		_scheme_page.add_child(_make_scheme_row(int(entry["id"]), entry))

	# Dev sub-page — wipe the whole save, or unlock any car / upgrade in the game.
	_dev_page = _make_page()
	add_child(_dev_page)
	_dev_page.add_child(_make_heading("Dev"))
	_dev_status = _make_sub("Wipe progress or unlock anything.")
	_dev_page.add_child(_dev_status)
	_dev_page.add_child(_make_action_button("Wipe all progress", _wipe_progress))
	_dev_page.add_child(_make_sub("Unlock a car:"))
	for car in CarLibrary.CARS:
		var car_id := String(car["id"])
		var car_name := String(car["name"])
		_dev_page.add_child(_make_action_button("Unlock %s" % car_name, _grant_car.bind(car_id, car_name)))
	_dev_page.add_child(_make_sub("Add an upgrade to inventory:"))
	for up in UpgradeLibrary.UPGRADES:
		var up_id := String(up["id"])
		var up_name := String(up["name"])
		_dev_page.add_child(_make_action_button("Add %s" % up_name, _add_upgrade.bind(up_id, up_name)))

	_refresh_camera_selection()
	_refresh_scheme_selection()


# --- Navigation --------------------------------------------------------------

# True while the category list is showing (vs a sub-page).
func at_root() -> bool:
	return _list_page != null and _list_page.visible


func show_list() -> void:
	_show_page(_list_page)


func show_camera() -> void:
	_show_page(_camera_page)


func show_schemes() -> void:
	_show_page(_scheme_page)


func show_dev() -> void:
	_show_page(_dev_page)


func _show_page(page: Control) -> void:
	_list_page.visible = page == _list_page
	_camera_page.visible = page == _camera_page
	_scheme_page.visible = page == _scheme_page
	_dev_page.visible = page == _dev_page
	page_changed.emit(at_root())


# Persist the chosen camera mode, refresh the highlight, and tell any live scene to
# switch (the run's CameraManager wires `camera_changed`).
func select_camera(mode: int) -> void:
	Save.set_setting(CameraManager.SETTING_KEY, mode)
	_refresh_camera_selection()
	camera_changed.emit(mode)


# Persist the chosen scheme and refresh the highlight. The live MobileControls reads
# this on the next run (loaded fresh with main.tscn), so no scene is poked here.
func select_scheme(id: int) -> void:
	Save.set_setting(MobileControls.SETTING_KEY, id)
	_refresh_scheme_selection()


func _refresh_camera_selection() -> void:
	var current := int(Save.get_setting(CameraManager.SETTING_KEY, CameraManager.ORDER[0]))
	for entry in camera_rows:
		_highlight(entry["button"], int(entry["key"]) == current)


func _refresh_scheme_selection() -> void:
	var current := int(Save.get_setting(MobileControls.SETTING_KEY, MobileControls.DEFAULT_SCHEME))
	for entry in scheme_rows:
		_highlight(entry["button"], int(entry["key"]) == current)


# --- Dev actions -------------------------------------------------------------

# Wipe the entire save profile back to a fresh new-game state. Camera / control
# settings are part of the profile, so refresh their highlights afterwards.
func _wipe_progress() -> void:
	Save.reset_new_game()
	_refresh_camera_selection()
	_refresh_scheme_selection()
	_dev_status.text = "Wiped all progress."


# Grant a fresh owned instance of any car in the library (no rally required).
func _grant_car(model_id: String, display_name: String) -> void:
	Save.grant_car(model_id)
	_dev_status.text = "Granted %s." % display_name


# Drop one of any upgrade (or the repair kit) into the inventory to fit later.
func _add_upgrade(item_id: String, display_name: String) -> void:
	Save.add_item(item_id)
	_dev_status.text = "Added %s." % display_name


# --- Row builders ------------------------------------------------------------

# A category row on the list page: a plain menu button that opens a sub-page. The
# trailing ASCII ">" reads as "drills in" (the font lacks arrow glyphs — same
# reason the rest of the UI uses ASCII < / >).
func _make_nav_button(text: String, on_press: Callable) -> Button:
	var button := _make_row_button(48)
	button.text = "%s  >" % text
	button.pressed.connect(on_press)
	return button


# A plain labelled action button (used by the dev page).
func _make_action_button(text: String, on_press: Callable) -> Button:
	var button := _make_row_button(40)
	button.text = text
	button.pressed.connect(on_press)
	return button


# A camera row: a full-width flat Button carrying name + how-to (no diagram).
func _make_camera_row(mode: int, entry: Dictionary) -> Button:
	var button := _make_row_button(64)
	button.pressed.connect(select_camera.bind(mode))
	var text := _make_row_text(button)
	_add_row_labels(text, String(entry["name"]), String(entry["desc"]))
	camera_rows.append({"key": mode, "button": button})
	return button


# A scheme row: the same flat Button, with a layout diagram beside the text so the
# option visually shows its touch layout (the inner controls are mouse-transparent).
func _make_scheme_row(id: int, entry: Dictionary) -> Button:
	var button := _make_row_button(92)
	button.pressed.connect(select_scheme.bind(id))

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 10
	row.offset_top = 8
	row.offset_right = -10
	row.offset_bottom = -8
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)

	var diagram := ControlSchemeDiagram.new()
	diagram.scheme = id
	diagram.custom_minimum_size = Vector2(132, 76)
	row.add_child(diagram)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text)
	_add_row_labels(text, String(entry["name"]), String(entry["desc"]))

	scheme_rows.append({"key": id, "button": button})
	return button


# --- Shared widgets ----------------------------------------------------------

# A page container — a VBox that fills the width and stacks its rows.
func _make_page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 10)
	return page


func _make_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	return label


func _make_sub(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 14)
	return label


func _make_row_button(min_height: float) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.custom_minimum_size = Vector2(0, min_height)
	return button


# A text column anchored inside a row Button (used when there is no diagram).
func _make_row_text(button: Button) -> VBoxContainer:
	var text := VBoxContainer.new()
	text.set_anchors_preset(Control.PRESET_FULL_RECT)
	text.offset_left = 12
	text.offset_top = 8
	text.offset_right = -12
	text.offset_bottom = -8
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(text)
	return text


func _add_row_labels(text: VBoxContainer, name_text: String, desc_text: String) -> void:
	var name_label := Label.new()
	name_label.text = name_text
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(name_label)
	var desc_label := Label.new()
	desc_label.text = desc_text
	desc_label.add_theme_font_size_override("font_size", 13)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(desc_label)


# Highlight a selected row in the house style (green underline + green text),
# flattening the rest. Delegates to the shared design system (UITheme).
func _highlight(button: Button, selected: bool) -> void:
	UITheme.mark_selected(button, selected)

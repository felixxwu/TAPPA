class_name SettingsMenu
extends VBoxContainer
# A reusable settings panel shared by the HQ title screen and the in-run pause
# menu, so both present the SAME options. Two sections:
#   • Camera — pick the camera angle (chase / bonnet), persisted under
#     CameraManager.SETTING_KEY. Emits `camera_changed` so a live scene (the run's
#     CameraManager) can switch immediately; the HQ has no camera so it just saves
#     and the choice is applied on the next run.
#   • Mobile controls — pick the touch control scheme (MobileControls.SCHEMES),
#     persisted under MobileControls.SETTING_KEY. Each row carries a vector layout
#     diagram (ControlSchemeDiagram), as on the original title-screen page.
# Choices are stored via Save.set_setting. The panel lays its rows out in itself
# (a VBox); the host wraps it in a ScrollContainer so it fits small screens.

signal camera_changed(mode: int)

# Selectable rows, exposed for tests / hosts: [{key: Variant, button: Button}].
var camera_rows: Array = []
var scheme_rows: Array = []


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build()


func _build() -> void:
	add_child(_make_heading("Camera"))
	add_child(_make_sub("Pick your camera angle:"))
	camera_rows.clear()
	for entry in CameraManager.MODES:
		add_child(_make_camera_row(int(entry["mode"]), entry))

	add_child(_make_heading("Mobile controls"))
	add_child(_make_sub("Pick a touch layout:"))
	scheme_rows.clear()
	for entry in MobileControls.SCHEMES:
		add_child(_make_scheme_row(int(entry["id"]), entry))

	_refresh_camera_selection()
	_refresh_scheme_selection()


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


# --- Row builders ------------------------------------------------------------

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


# Highlight a selected row (a tinted, bordered box) and flatten the rest.
func _highlight(button: Button, selected: bool) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.20, 0.34, 0.52, 0.85) if selected else Color(0.12, 0.14, 0.18, 0.6)
	for corner in ["top_left", "top_right", "bottom_left", "bottom_right"]:
		box.set("corner_radius_" + corner, 6)
	if selected:
		for side in ["left", "top", "right", "bottom"]:
			box.set("border_width_" + side, 2)
		box.border_color = Color(0.55, 0.78, 1.0, 0.95)
	for state in ["normal", "hover", "pressed", "focus"]:
		button.add_theme_stylebox_override(state, box)

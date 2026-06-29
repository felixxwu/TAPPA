class_name PauseMenu
extends CanvasLayer
# In-run pause menu. A top-right Pause button freezes the game
# (`get_tree().paused`) and opens an overlay offering Resume and Settings; Settings
# shows the SAME shared SettingsMenu as the title screen (camera angle + mobile
# controls). The whole layer runs with PROCESS_MODE_ALWAYS (set in main.tscn) so its
# button and the menu still respond while the tree is paused. A camera pick in
# Settings applies immediately via the scene's CameraManager (wired below); ui_cancel
# (Esc / gamepad B) toggles the menu too. See features/menus.md.

# The scene's CameraManager, so a camera pick in Settings switches the live camera.
@export var camera_manager: CameraManager

var _pause_button: Button
var _overlay: Control          # dim backdrop + panels, hidden until paused
var _menu_panel: Control       # PAUSED + Resume + Settings
var _settings_panel: Control   # the shared SettingsMenu + Back

var settings_menu: SettingsMenu


func _ready() -> void:
	_build()
	_set_open(false)


func is_open() -> bool:
	return _overlay.visible


# Freeze the game and show the menu (the Resume/Settings page).
func open() -> void:
	get_tree().paused = true
	_set_open(true)
	_show_settings(false)


# Unfreeze and hide the whole overlay.
func resume() -> void:
	get_tree().paused = false
	_set_open(false)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if not is_open():
		open()
	elif _settings_panel.visible:
		_show_settings(false)  # Esc backs out of Settings to the menu first
	else:
		resume()
	get_viewport().set_input_as_handled()


# --- Build -------------------------------------------------------------------

func _build() -> void:
	layer = 5  # above HUD (2) and mobile controls (3)

	# Top-right Pause button, always available during gameplay.
	_pause_button = Button.new()
	_pause_button.text = "| |"
	_pause_button.focus_mode = Control.FOCUS_NONE
	_pause_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_pause_button.offset_left = -52
	_pause_button.offset_top = 8
	_pause_button.offset_right = -8
	_pause_button.offset_bottom = 36
	_pause_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_pause_button.add_theme_font_size_override("font_size", 14)
	_pause_button.pressed.connect(open)
	add_child(_pause_button)

	# Full-screen overlay: a dim backdrop (swallows taps to the game) + the panels.
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_overlay)

	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = Color(0, 0, 0, 0.6)
	_overlay.add_child(backdrop)

	_menu_panel = _build_menu_panel()
	_overlay.add_child(_menu_panel)
	_settings_panel = _build_settings_panel()
	_overlay.add_child(_settings_panel)


# PAUSED + Resume + Settings, centred.
func _build_menu_panel() -> Control:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(col)

	# PAUSED on a solid black title plate (the house style), centred over the menu.
	var title_plate := UITheme.panel(0.9, 14)
	var title := UITheme.title("Paused")
	title.custom_minimum_size = Vector2(UITheme.BUTTON_MIN.x, 0)
	title_plate.add_child(title)
	col.add_child(title_plate)

	var resume_btn := _make_menu_button("Resume")
	resume_btn.pressed.connect(resume)
	col.add_child(resume_btn)

	var settings_btn := _make_menu_button("Settings")
	settings_btn.pressed.connect(_show_settings.bind(true))
	col.add_child(settings_btn)
	return center


# The shared SettingsMenu in a scroll, with a Back button. Hidden until Settings.
func _build_settings_panel() -> Control:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	margin.add_child(col)

	var title := Label.new()
	title.text = "SETTINGS"
	title.add_theme_font_size_override("font_size", 28)
	col.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	settings_menu = SettingsMenu.new()
	settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_menu.camera_changed.connect(_on_camera_changed)
	scroll.add_child(settings_menu)

	var back := _make_menu_button("< Back")
	back.pressed.connect(_show_settings.bind(false))
	col.add_child(back)
	return margin


func _make_menu_button(text: String) -> Button:
	var button := Button.new()
	button.text = UITheme.caps(text)
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(220, 44)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return button


# --- State -------------------------------------------------------------------

func _set_open(opened: bool) -> void:
	_overlay.visible = opened
	_pause_button.visible = not opened


func _show_settings(on: bool) -> void:
	_settings_panel.visible = on
	_menu_panel.visible = not on


func _on_camera_changed(mode: int) -> void:
	if camera_manager != null:
		camera_manager.set_mode(mode)

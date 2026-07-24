class_name PauseMenu
extends CanvasLayer
# In-run pause menu. A top-right Pause button freezes the game
# (`get_tree().paused`) and opens an overlay offering Resume, Settings and Quit to HQ;
# Settings shows the SAME shared SettingsMenu as the title screen (camera angle + mobile
# controls). Quit to HQ abandons the current rally (no retry penalty, damage persisted,
# no reward — RallySession.abandon) after a confirm and returns to HQ. The whole layer
# runs with PROCESS_MODE_ALWAYS (set in main.tscn) so its button and the menu still
# respond while the tree is paused. A camera pick in Settings applies immediately via the
# scene's CameraManager (wired below); ui_cancel (Esc / gamepad B) toggles the menu too.
# See features/menus.md.

# The scene's CameraManager, so a camera pick in Settings switches the live camera.
# Emitted when the player picks "Reset to track" — world.gd snaps the live car onto
# the centerline beside its current position (TrackProgress.manual_reset_pose) and the
# menu resumes. The menu itself has no car reference, so it delegates the reset upward.
signal reset_to_track_requested

@export var camera_manager: CameraManager
# The scene's MobileControls, so a touch-scheme pick in Settings rebuilds the live
# on-screen controls immediately (rather than only taking effect on the next run).
@export var mobile_controls: MobileControls

var _pause_button: Button
var _overlay: Control          # dim backdrop + panels, hidden until paused
var _menu_panel: Control       # PAUSED + Resume + Settings + Quit to HQ
var _settings_panel: Control   # the shared SettingsMenu + Back
var _resume_button: Button     # default keyboard/gamepad focus when the menu opens
var _reset_button: Button      # "Reset to track" — snaps the car back onto the road
var _settings_button: Button   # focus returns here when backing out of Settings
var _quit_button: Button       # "Quit to HQ" — abandons the rally

var settings_menu: SettingsMenu

# Default-CLOSED: the menu is inert until the world finishes loading and world.gd
# calls set_input_enabled(true). Without this the Pause button / Esc are live from
# frame 0 — including during world.gd's awaited generation window (loading overlay
# up), where opening the menu would set get_tree().paused = true MID-generation and
# let the player quit/resume into a half-built world. Mirrors the default-inert
# `_armed` gate on StageManager. See features/menus.md.
var _input_enabled := false


func _ready() -> void:
	_build()
	UITheme.enforce(self)  # house rules: uppercase + one size + fixed button height
	_set_open(false)


# Arm (or disarm) the menu. world.gd enables it once the world is generated, so
# pause can't fire while the loading overlay is still up. Closing an open menu on
# disable would strand get_tree().paused, so callers only disable at boot (closed).
func set_input_enabled(on: bool) -> void:
	_input_enabled = on


func is_open() -> bool:
	return _overlay.visible


# Freeze the game and show the menu (the Resume/Settings page).
func open() -> void:
	if not _input_enabled:
		return  # inert while the world is still loading (see set_input_enabled)
	get_tree().paused = true
	_set_open(true)
	_show_settings(false)
	UITheme.focus_grab.bind(_resume_button).call_deferred()  # land the cursor on Resume


# Unfreeze and hide the whole overlay.
func resume() -> void:
	get_tree().paused = false
	_set_open(false)


# Reset to track: hand the reset to the host (which owns the car + TrackProgress),
# then unfreeze and close the menu so the player drops straight back into the run.
# (Car.reset_to queues the teleport for the physics step, so it survives being fired
# from here — outside the physics frame, and even while the tree is still paused.)
func _on_reset_to_track_pressed() -> void:
	reset_to_track_requested.emit()
	resume()


# Pop the "Abandon rally?" confirm; quit_to_hq() runs only if the player accepts.
func _on_quit_pressed() -> void:
	ConfirmPopup.open(self, "Quit to HQ?",
		"Abandon this rally and return to HQ?\nYour progress in this run is lost.",
		[ {"label": "Quit to HQ", "callback": quit_to_hq},
		  {"label": "Cancel", "callback": Callable()} ])


# Leave the run for HQ: unfreeze, then abandon the active rally. RallySession.abandon
# emits rally_finished, which world.gd routes back to HQ (the garage view). A benchmark
# run exits through Benchmark.exit_to_hq so its config overrides are restored. With no
# session (a plain dev boot of main.tscn) there's nothing to abandon, so load HQ direct.
func quit_to_hq() -> void:
	get_tree().paused = false
	if Benchmark.active:
		Benchmark.exit_to_hq()
	elif RallySession.is_active():
		RallySession.abandon()
	else:
		get_tree().change_scene_to_file("res://hq.tscn")


func _unhandled_input(event: InputEvent) -> void:
	if not _input_enabled:
		return  # Esc / gamepad B do nothing while the world is loading
	# The `pause` action (Esc / gamepad Start) TOGGLES the menu. ui_cancel (gamepad B)
	# is NOT an opener — in gameplay B is the handbrake — it only acts as "back" once the
	# menu is already open (step out of a sub-page, else resume). This keeps the pause
	# menu off the B button while still letting B/Esc back out of it.
	if event.is_action_pressed("pause"):
		if is_open():
			resume()
		else:
			open()
		get_viewport().set_input_as_handled()
		return
	if not is_open() or not event.is_action_pressed("ui_cancel"):
		return
	if _settings_panel.visible:
		_on_settings_back()  # Esc / B steps out a level: sub-page → list → menu
	else:
		resume()
	get_viewport().set_input_as_handled()


# --- Build -------------------------------------------------------------------

func _build() -> void:
	layer = 5  # above HUD (2) and mobile controls (3)

	# Top-right Pause button, always available during gameplay. Square, with a proper
	# drawn pause glyph (PauseIcon) instead of a cramped "| |" string.
	_pause_button = Button.new()
	_pause_button.focus_mode = Control.FOCUS_NONE
	_pause_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_pause_button.offset_left = -48
	_pause_button.offset_top = 8
	_pause_button.offset_right = -8
	_pause_button.offset_bottom = 48
	_pause_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_pause_button.pressed.connect(open)
	var pause_icon := PauseIcon.new()
	pause_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	pause_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "top"]:
		pause_icon.set("offset_" + side, 11)
	for side in ["right", "bottom"]:
		pause_icon.set("offset_" + side, -11)
	_pause_button.add_child(pause_icon)
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

	# Framework: focus + WASD/arrow/gamepad nav across whichever page is showing
	# (Resume/Settings/Quit, or the SettingsMenu rows). No on_back — this menu's
	# own _unhandled_input owns ui_cancel because it also OPENS the menu when
	# closed and steps sub-page → list → menu, which a plain back callback can't.
	MenuNav.attach(_overlay, {first = _resume_button})


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
	var title := UITheme.title("PAUSED")
	title.custom_minimum_size = Vector2(UITheme.BUTTON_MIN_W, 0)
	title_plate.add_child(title)
	col.add_child(title_plate)

	_resume_button = _make_menu_button("Resume")
	_resume_button.pressed.connect(resume)
	col.add_child(_resume_button)

	# Reset to track — snap the car back onto the road at its current progress
	# (recovery pose), then unpause. world.gd owns the car and performs the reset.
	_reset_button = _make_menu_button("Reset to track")
	_reset_button.pressed.connect(_on_reset_to_track_pressed)
	col.add_child(_reset_button)

	_settings_button = _make_menu_button("Settings")
	_settings_button.pressed.connect(_show_settings.bind(true))
	col.add_child(_settings_button)

	# Quit to HQ — abandons the rally (after a confirm). No retry penalty: a non-top-3
	# rally is simply re-entered later from the map.
	_quit_button = _make_menu_button("Quit to HQ")
	_quit_button.pressed.connect(_on_quit_pressed)
	col.add_child(_quit_button)
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

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	settings_menu = SettingsMenu.new()
	settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_menu.camera_changed.connect(_on_camera_changed)
	settings_menu.scheme_changed.connect(_on_scheme_changed)
	scroll.add_child(settings_menu)

	# Single bottom button: on a sub-page it backs out to the category list; on the
	# list it backs out to the Resume/Settings menu.
	var back := _make_menu_button("< Back")
	back.pressed.connect(_on_settings_back)
	col.add_child(back)
	return margin


# Back from the Settings panel: step out of a sub-page to the category list first
# (handled inside the shared menu), then (from the list) out to the Resume/Settings
# menu. Same path for the bottom button and for menu_back / ui_cancel.
func _on_settings_back() -> void:
	if not settings_menu.go_back():
		_show_settings(false)


func _make_menu_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	# Focusable so the pause menu is fully keyboard / gamepad navigable (ui_up/ui_down
	# walk Resume/Settings/Quit, ui_accept fires the focused one).
	button.focus_mode = Control.FOCUS_ALL
	button.custom_minimum_size = Vector2(220, 44)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return button


# --- State -------------------------------------------------------------------

func _set_open(opened: bool) -> void:
	_overlay.visible = opened
	_pause_button.visible = not opened


func _show_settings(on: bool) -> void:
	if on:
		settings_menu.show_list()  # always open Settings on the category list (focuses it)
	_settings_panel.visible = on
	_menu_panel.visible = not on
	if not on:
		# Returning to the Resume/Settings menu — put the cursor back on Settings.
		UITheme.focus_grab.bind(_settings_button).call_deferred()


func _on_camera_changed(mode: int) -> void:
	if camera_manager != null:
		camera_manager.set_mode(mode)


func _on_scheme_changed(id: int) -> void:
	if mobile_controls != null:
		mobile_controls.set_scheme(id)

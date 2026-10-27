class_name PauseMenu
extends CanvasLayer
# Docs: features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_pause_menu.gd, tests/headless/test_photo_mode.gd, tests/headless/test_menu_nav.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# In-run pause menu. A top-right Pause button freezes the game
# (`get_tree().paused`) and opens an overlay offering Resume, Settings and Quit to title;
# Settings shows the SAME shared SettingsMenu as the title screen (camera angle + mobile
# controls). Quit to title saves and goes back to the title screen. The whole layer
# runs with PROCESS_MODE_ALWAYS (set in main.tscn) so its button and the menu still
# respond while the tree is paused. A camera pick in Settings applies immediately via the
# scene's CameraManager (wired below); ui_cancel (Esc / gamepad B) toggles the menu
# too. See features/menus.md.

# The scene's CameraManager, so a camera pick in Settings switches the live camera.
# Emitted when the player picks "Reset to track" — world.gd snaps the live car onto
# the centerline beside its current position (TrackProgress.manual_reset_pose) and the
# menu resumes. The menu itself has no car reference, so it delegates the reset upward.
signal reset_to_track_requested
# Emitted when the player picks "Photo Mode". world.gd owns the free-fly camera (it
# owns the scene's cameras and overlays); this menu only hides itself and disarms so
# the frozen shot is unobstructed. The tree stays PAUSED throughout — leaving photo
# mode comes back to this menu, still frozen, via return_from_photo_mode().
signal photo_mode_requested

@export var camera_manager: CameraManager
# The scene's MobileControls, so a touch-scheme pick in Settings rebuilds the live
# on-screen controls immediately (rather than only taking effect on the next run).
@export var mobile_controls: MobileControls
# Photo Mode needs a host that owns a free-fly camera (world.gd). A scene without one turns
# the row off rather than offering a button that would leave the game frozen.
@export var offer_photo_mode := true
# Extra rows the host handles itself (free roam: "Map", "Stats"), placed above Settings. Pressing
# one emits extra_requested with its label; the menu stays open, still paused, for the host's page
# to cover. The host calls return_from_extra() when its page closes.
@export var extra_rows := PackedStringArray()

signal extra_requested(label: String)
signal quitting

var _pause_button: Button
var _overlay: Control          # dim backdrop + panels, hidden until paused
var _menu_panel: MenuPage      # PAUSED over a card list: Resume, Reset, Photo Mode, extras, Settings, Quit
var _settings_panel: Control   # the shared SettingsMenu + Back
var _cards: CardCarousel       # the menu's cards; MenuNav's opening focus (Resume is card 0)

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


# Arm (or disarm) the menu. world.gd enables it once the world is generated, so pause
# can't fire while the loading overlay is still up; photo mode disarms it while it runs.
#
# DISARMING NEVER CLOSES AN OPEN MENU — that would strand get_tree().paused. A caller
# that ever needs to disarm a menu that might be OPEN must resume() first.
func set_input_enabled(on: bool) -> void:
	_input_enabled = on
	_refresh_pause_button()


func is_open() -> bool:
	return _overlay.visible


func is_armed() -> bool:
	return _input_enabled


# Freeze the game and show the menu (the Resume/Settings page).
func open() -> void:
	if not _input_enabled:
		return  # inert while the world is still loading (see set_input_enabled)
	get_tree().paused = true
	_set_open(true)
	_show_settings(false)
	# NO focus grab here. Showing the overlay fires its visibility_changed, and the
	# MenuNav attached in _build owns where the cursor lands (see _build's attach
	# call). One owner: a second grab here would silently beat the framework, and
	# any change to opening focus made through MenuNav would look like it did
	# nothing.


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


# Photo Mode: hide this overlay and DISARM the menu (so Esc / the Pause button belong
# to the photo camera, and can't stack an overlay over the shot), but do NOT unpause —
# the frozen world is the whole feature. The host answers on photo_mode_requested.
# An extra row: hide the overlay but stay paused and armed-off while the host's page is up.
func _on_extra_pressed(label: String) -> void:
	_extra_return_card = label
	set_input_enabled(false)
	_set_open(false)
	extra_requested.emit(label)


var _extra_return_card := ""


# The host's extra page closed: show this menu again, cursor back on the card that opened it.
func return_from_extra() -> void:
	set_input_enabled(true)
	get_tree().paused = true
	_set_open(true)
	_show_settings(false)
	_focus_card(_extra_return_card)


func _on_photo_mode_pressed() -> void:
	set_input_enabled(false)
	_set_open(false)
	photo_mode_requested.emit()


# Photo mode is over: re-arm and show this menu again, with the cursor back on the
# Photo Mode row. The tree was never unpaused, so the world is still exactly as frozen
# as when the player left it.
func return_from_photo_mode() -> void:
	set_input_enabled(true)
	open()
	_focus_card("Photo Mode")


const QUIT_LABEL := "Quit to title"


# Pop the quit confirm; quit_to_title() runs only if the player accepts.
func confirm_quit_to_title() -> void:
	ConfirmPopup.open(self, QUIT_LABEL + "?",
		"Leave the island and return to the title screen? Your world is saved.",
		[ {"label": "Cancel", "callback": Callable()},
		  {"label": QUIT_LABEL, "callback": quit_to_title} ],
		1, 0)  # focus stays on Quit as before; Back/Esc = Cancel (index 0)


# Unfreeze, then go to the title. A benchmark run exits through Benchmark.exit_to_title so its
# config overrides and the real profile are restored.
func quit_to_title() -> void:
	get_tree().paused = false
	quitting.emit()
	if Benchmark.active:
		Benchmark.exit_to_title()
	else:
		Scenes.change_to(get_tree(), Scenes.TITLE)


func _unhandled_input(event: InputEvent) -> void:
	if not _input_enabled:
		return  # Esc / gamepad B do nothing while the world is loading
	# A ConfirmPopup (the "Quit to title?" confirm) is MODAL and hosted on THIS node, as
	# its own CanvasLayer (layer 101) above the pause overlay (layer 5). Its own
	# MenuNav consumes ui_cancel/menu_back and directional input, but NOT `pause` —
	# so without this guard, pressing gamepad Start while the confirm is up fell
	# through to the case below and called resume(): get_tree().paused = false and
	# _set_open(false) hide the pause overlay, but the popup is a SEPARATE CanvasLayer
	# and stays on screen — now floating over LIVE, unpaused gameplay with its "Quit to
	# title" button still armed. Bailing here leaves the confirm exactly as it was
	# (Start does nothing) rather than silently resuming under an orphaned modal; the
	# player still has ui_cancel/B (routed to the popup's own Cancel action) or a tap
	# on one of the popup's own buttons to get out.
	if ConfirmPopup.any_open(get_tree()) != null:
		return
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
	# pixel-art pause glyph.
	_pause_button = Button.new()
	_pause_button.focus_mode = Control.FOCUS_NONE
	_pause_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_pause_button.offset_left = -48
	_pause_button.offset_top = 8
	_pause_button.offset_right = -8
	_pause_button.offset_bottom = 48
	_pause_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_pause_button.pressed.connect(open)
	var pause_icon := PixelIcon.new()
	pause_icon.texture = preload("res://icons/hud/pause.png")
	pause_icon.tint = UITheme.INK
	pause_icon.set_anchors_preset(Control.PRESET_FULL_RECT)
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
	backdrop.color = UITheme.PANEL_DIM
	_overlay.add_child(backdrop)

	_build_menu_panel()
	_settings_panel = _build_settings_panel()
	_overlay.add_child(_settings_panel)
	# Start on the menu page. Left visible, the first open() read as "returning from
	# Settings" and put the cursor on the Settings row instead of Resume.
	_settings_panel.visible = false

	# Framework: focus + WASD/arrow/gamepad nav across whichever page is showing
	# (the card list, or the SettingsMenu rows). No on_back — this menu's
	# own _unhandled_input owns ui_cancel because it also OPENS the menu when
	# closed and steps sub-page → list → menu, which a plain back callback can't.
	MenuNav.attach(_overlay, {first = _cards})


# PAUSED over the card list (CardUI.card_page / card_list). Built once: the rows it offers are
# exports the host sets in its scene.
func _build_menu_panel() -> MenuPage:
	_menu_panel = CardUI.card_page(_overlay, {"title": "Paused"})
	var entries: Array = [
		{"title": "Resume", "icon": "resume_run", "action": resume},
		# Snap the car back onto the road at its current progress, then unpause. The host owns
		# the car and performs the reset.
		{"title": "Reset to road", "icon": "reset_road", "action": _on_reset_to_track_pressed},
	]
	# Hand the screen to the host's free-fly camera with the tree still frozen. Esc there comes
	# back to this menu (return_from_photo_mode).
	if offer_photo_mode:
		entries.append({"title": "Photo Mode", "icon": "photo", "action": _on_photo_mode_pressed})
	for label in extra_rows:
		entries.append({"title": label, "icon": EXTRA_ICONS.get(label, "generic"), "action": _on_extra_pressed.bind(label)})
	entries.append({"title": "Settings", "icon": "settings", "action": _show_settings.bind(true)})
	entries.append({"title": QUIT_LABEL, "icon": "quit", "action": confirm_quit_to_title})
	_cards = CardUI.card_list(_menu_panel, entries)
	return _menu_panel


const EXTRA_ICONS := {"Map": "map", "Stats": "stats"}


# Put the cursor on the card titled `title` (the one the player left the menu from).
func _focus_card(title: String) -> void:
	var i := CardUI.index_of(_cards, title)
	if i >= 0:
		_cards.select(i, false)
	UITheme.focus_grab.bind(_cards).call_deferred()


# Readout for tests and hosts: the menu's card list.
func cards() -> CardCarousel:
	return _cards


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
	title.add_theme_font_size_override("font_size", UITheme.TITLE_FONT_SIZE)
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
	var back := UITheme.row_button("< Back", Callable())
	back.pressed.connect(_on_settings_back)
	col.add_child(back)
	return margin


# Back from the Settings panel: step out of a sub-page to the category list first
# (handled inside the shared menu), then (from the list) out to the Resume/Settings
# menu. Same path for the bottom button and for menu_back / ui_cancel.
func _on_settings_back() -> void:
	if not settings_menu.go_back():
		_show_settings(false)


# --- State -------------------------------------------------------------------

func _set_open(opened: bool) -> void:
	_overlay.visible = opened
	_refresh_pause_button()


# The Pause button is offered only when the menu is BOTH armed and closed. One writer, so
# the open-state and armed-state halves of that rule can't drift apart — a live-looking
# button over a disarmed menu would let a pause overlay open while the menu is inert.
func _refresh_pause_button() -> void:
	if is_instance_valid(_pause_button):
		_pause_button.visible = _input_enabled and not is_open()


func _show_settings(on: bool) -> void:
	# Only a genuine RETURN from the settings sub-panel puts the cursor back on
	# Settings. open() also calls _show_settings(false), on a menu that was never
	# showing settings, and grabbing there stole the opening focus from MenuNav —
	# masked until now only because open() re-grabbed afterwards.
	var was_showing_settings := _settings_panel.visible
	if on:
		settings_menu.show_list()  # always open Settings on the category list (focuses it)
	_settings_panel.visible = on
	_menu_panel.visible = not on
	if was_showing_settings and not on:
		# Returning to the card list — put the cursor back on Settings.
		_focus_card("Settings")


func _on_camera_changed(mode: int) -> void:
	if camera_manager != null:
		camera_manager.set_mode(mode)


func _on_scheme_changed(id: int) -> void:
	if mobile_controls != null:
		mobile_controls.set_scheme(id)

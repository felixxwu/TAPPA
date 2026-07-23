class_name SettingsMenu
extends VBoxContainer
# A reusable settings panel shared by the HQ title screen and the in-run pause
# menu, so both present the SAME options. It opens on a LIST of categories; each
# row drills into its own sub-page:
#   • Camera — pick the camera angle (chase / bonnet), persisted under
#     CameraManager.SETTING_KEY. Emits `camera_changed` so a live scene (the run's
#     CameraManager) can switch immediately; the HQ has no camera so it just saves
#     and the choice is applied on the next run.
#   • Key bindings — rebind the keyboard and controller controls. Each driving
#     action (InputRemap.ACTIONS) gets a row with a keyboard button and a controller
#     button showing its current binding; tapping one listens for the next key /
#     gamepad input and stores it via InputRemap. A "Reset to defaults" row clears
#     all overrides. Esc cancels a pending listen.
#   • Mobile controls — pick the touch control scheme (MobileControls.SCHEMES),
#     persisted under MobileControls.SETTING_KEY. Each row carries a vector layout
#     diagram (ControlSchemeDiagram), as on the original title-screen page.
#   • Benchmark — configure and launch the in-game performance benchmark
#     (features/benchmark.md): one ON/OFF row per Benchmark.TOGGLES entry
#     (vegetation, spectators, render distance, …) and a Start row that hands off
#     to the Benchmark autoload (which owns the config overrides + scene change).
# Navigation is internal: show_list()/show_camera()/show_schemes() swap which page
# is visible. `page_changed(is_root)` lets the host adapt its single bottom button
# — on a sub-page it means "< Back" (to the list); on the list it means the host's
# own action (exit Settings, or Start in the pre-rally gate). Choices are stored
# via Save.set_setting. The host wraps this whole VBox in a (touch) ScrollContainer;
# only the visible page contributes height, so the long schemes page scrolls while
# the short list/camera pages don't.

signal camera_changed(mode: int)
# Emitted when the touch-control scheme is picked, so a live MobileControls (the
# run's, via the pause menu) can switch the on-screen controls immediately.
signal scheme_changed(id: int)
# Emitted on every page switch; is_root == the category list is showing.
signal page_changed(is_root: bool)

# Fixed width for the key-binding buttons (and their column captions), wide enough
# for the longest label ("RIGHT STICK RIGHT", "RIGHT BUMPER").
const _BIND_BUTTON_W := 168.0

# Selectable rows, exposed for tests / hosts: [{key: Variant, button: Button}].
var camera_rows: Array = []
var scheme_rows: Array = []
# Key-binding rows, exposed for tests / hosts:
# [{action: String, keyboard_button: Button, controller_button: Button}].
var controls_rows: Array = []
# Benchmark toggle rows, exposed for tests: [{key: String, button: Button}].
var benchmark_rows: Array = []

# The swappable pages (only one visible at a time).
var _list_page: VBoxContainer
var _audio_page: VBoxContainer
# The music-volume slider + its live "%"" label on the Audio page (exposed for tests).
var music_slider: HSlider
var music_value_label: Label
var _camera_page: VBoxContainer
var _controls_page: VBoxContainer
var _scheme_page: VBoxContainer
var _benchmark_page: VBoxContainer
var _dev_page: VBoxContainer
var _dev_status: Label  # feedback line on the dev page ("Granted …", "Wiped …")
var _pages: Array[Control] = []  # all swappable pages, list first; see _build()

# Seed-lab page: trial (seed, water level, …) combinations against a live
# TrackPreview that animates the generation just like the loading screen
# (features/lakes.md). Typeable SpinBox inputs.
var _seedlab_page: Control          # full-screen overlay (top_level), not a VBox page
var _seedlab_preview: TrackPreview
var _seed_spin: SpinBox
var _level_spin: SpinBox
var _turns_spin: SpinBox
var _straight_spin: SpinBox
var _sl_gen := 0  # generation token — stale async runs stop updating the preview
# Event picker: a popup over the seed lab that lists every rally + its events.
# Selecting one COPIES the event's values into the four spinboxes and regenerates —
# so the inputs are always the single source of truth and never drift from what the
# 2D preview shows. `_syncing_spins` batches the four field sets into one regen
# (each set would otherwise fire its own value_changed -> _regen_seedlab).
var _seedlab_popup: Control
var _event_focus: Control  # last-focused event row, restored when the picker reopens
var _syncing_spins := false
# Terrain editor: a second popup exposing the 6 terrain-noise params (3 layers ×
# wavelength+amplitude). These shape the track too — the generator routes the road
# around below-water cells and relocates the dry start — so without them the lab's
# lakes disagree with the real career event. _seedlab_cfg folds them into the config
# the preview generates against, matching RallySession.apply_event_config.
var _seedlab_terrain_popup: Control
var _t1w: SpinBox  # layer 1 wavelength
var _t1a: SpinBox  # layer 1 amplitude
var _t2w: SpinBox
var _t2a: SpinBox
var _t3w: SpinBox
var _t3a: SpinBox

# While the player is reassigning a control, the pending capture:
# {action: String, slot: String, button: Button}; empty when not listening.
var _listening: Dictionary = {}


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build()
	UITheme.enforce(self)  # house rules: uppercase + one font size
	show_list()
	# Cancel any in-flight seed-lab generation when the menu is hidden (e.g. the
	# pause menu closes without navigating back), so no search keeps running.
	visibility_changed.connect(func() -> void:
		if not visible:
			_sl_gen += 1)


func _build() -> void:
	_build_list_page()
	_build_audio_page()
	_build_camera_page()
	_build_controls_page()
	_build_schemes_page()
	_build_benchmark_page()
	_build_dev_page()
	_build_seedlab_page()

	# Single source of truth for the swappable pages (list first — it's the
	# default page). _show_page / focus_current_page fan out over this so adding
	# a page only means appending it here.
	_pages = [_list_page, _audio_page, _camera_page, _controls_page, _scheme_page,
			_benchmark_page, _dev_page, _seedlab_page]

	_refresh_camera_selection()
	_refresh_scheme_selection()
	_refresh_controls_selection()
	_refresh_benchmark_rows()


func _build_list_page() -> void:
	# Category list — one nav button per sub-page, laid out in a 2-column grid so the
	# list stays short (about half the height) instead of a long single column that
	# overflows and scrolls.
	_list_page = _make_page()
	add_child(_list_page)
	_list_page.add_child(_make_sub("Choose a category:"))
	var list_grid := GridContainer.new()
	list_grid.columns = 2
	list_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_grid.add_theme_constant_override("h_separation", 10)
	list_grid.add_theme_constant_override("v_separation", 10)
	_list_page.add_child(list_grid)
	list_grid.add_child(_make_nav_button("Audio", show_audio))
	list_grid.add_child(_make_nav_button("Camera", show_camera))
	list_grid.add_child(_make_nav_button("Key bindings", show_controls))
	list_grid.add_child(_make_nav_button("Mobile controls", show_schemes))
	list_grid.add_child(_make_nav_button("Benchmark", show_benchmark))
	list_grid.add_child(_make_nav_button("Dev", show_dev))
	list_grid.add_child(_make_nav_button("Seed lab", show_seedlab))


func _build_audio_page() -> void:
	# Audio sub-page — the music volume slider (room for SFX/engine later).
	_audio_page = _make_page()
	add_child(_audio_page)
	_audio_page.add_child(_make_heading("Audio"))
	_audio_page.add_child(_make_sub("Set the music volume:"))
	_audio_page.add_child(_make_volume_row())


func _build_camera_page() -> void:
	# Camera sub-page.
	_camera_page = _make_page()
	add_child(_camera_page)
	_camera_page.add_child(_make_heading("Camera"))
	_camera_page.add_child(_make_sub("Pick your camera angle:"))
	camera_rows.clear()
	for entry in CameraManager.MODES:
		_camera_page.add_child(_make_camera_row(int(entry["mode"]), entry))


func _build_controls_page() -> void:
	# Key-bindings sub-page — one row per action, a keyboard + a controller button.
	_controls_page = _make_page()
	add_child(_controls_page)
	_controls_page.add_child(_make_heading("Key bindings"))
	_controls_page.add_child(_make_sub("Tap a binding, then press a key or button. Esc cancels."))
	_controls_page.add_child(_make_controls_header())
	controls_rows.clear()
	for entry in InputRemap.ACTIONS:
		_controls_page.add_child(_make_control_row(entry))
	_controls_page.add_child(_make_action_button("Reset to defaults", _reset_bindings))


func _build_schemes_page() -> void:
	# Mobile-controls sub-page.
	_scheme_page = _make_page()
	add_child(_scheme_page)
	_scheme_page.add_child(_make_heading("Mobile controls"))
	_scheme_page.add_child(_make_sub("Pick a touch layout:"))
	scheme_rows.clear()
	for entry in MobileControls.SCHEMES:
		_scheme_page.add_child(_make_scheme_row(int(entry["id"]), entry))


func _build_benchmark_page() -> void:
	# Benchmark sub-page — the pre-run feature toggles + Start (features/benchmark.md).
	_benchmark_page = _make_page()
	add_child(_benchmark_page)
	_benchmark_page.add_child(_make_heading("Benchmark"))
	_benchmark_page.add_child(_make_sub(
		"Auto-drive a long stage at %d km/h and measure performance. Toggle features to isolate their cost:"
		% int(BenchmarkRunner.TARGET_SPEED_KMH)))
	benchmark_rows.clear()
	for entry in Benchmark.TOGGLES:
		var key := String(entry["key"])
		var button := _make_action_button("", _toggle_benchmark.bind(key))
		benchmark_rows.append({"key": key, "name": String(entry["name"]), "button": button})
		_benchmark_page.add_child(button)
	_benchmark_page.add_child(_make_action_button("Start benchmark  >", _start_benchmark))


func _build_dev_page() -> void:
	# Dev sub-page — wipe the whole save, or unlock any car / upgrade in the game.
	_dev_page = _make_page()
	add_child(_dev_page)
	_dev_page.add_child(_make_heading("Dev"))
	_dev_status = _make_sub("Wipe progress or unlock anything.")
	_dev_page.add_child(_dev_status)
	_dev_page.add_child(_make_action_button("Wipe all progress", _wipe_progress))
	_dev_page.add_child(_make_action_button("3-star all rallies (unlock all regions)", _three_star_all_rallies))
	# Only meaningful mid-rally: instantly finish the whole rally with a perfect time
	# and jump to the podium (where the top-3 finish grants the car). Hidden in the HQ
	# settings, where there is no rally to complete.
	if RallySession.is_active():
		_dev_page.add_child(_make_action_button("Complete rally (win now)", _complete_rally))
	_dev_page.add_child(_make_sub("Unlock a car:"))
	for car in CarLibrary.all():
		var car_id := String(car["id"])
		var car_name := String(car["name"])
		_dev_page.add_child(_make_action_button("Unlock %s" % car_name, _grant_car.bind(car_id, car_name)))
	_dev_page.add_child(_make_sub("Fit an upgrade to the selected car (repair kit -> inventory):"))
	for up in UpgradeLibrary.UPGRADES:
		var up_id := String(up["id"])
		var up_name := String(up["name"])
		# Slottable parts are car-bound now, so fit them straight onto the selected
		# car; the repair kit is the one true consumable, so it still goes to inventory.
		if UpgradeLibrary.is_consumable(up_id):
			_dev_page.add_child(_make_action_button("Add %s" % up_name, _add_upgrade.bind(up_id, up_name)))
		else:
			_dev_page.add_child(_make_action_button("Fit %s" % up_name, _fit_upgrade.bind(up_id, up_name)))


func _build_seedlab_page() -> void:
	# Seed lab — a FULL-SCREEN overlay (like the loading screen), NOT a scrolling
	# settings page: a black background over the whole screen, the animated track
	# preview pinned to the top (always visible), and the typeable controls docked at
	# the bottom. top_level escapes the settings VBox/ScrollContainer layout.
	_seedlab_page = Control.new()
	_seedlab_page.top_level = true
	_seedlab_page.z_index = 100
	_seedlab_page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seedlab_page.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_seedlab_page)
	var sl_bg := ColorRect.new()
	sl_bg.color = UITheme.BLACK
	sl_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sl_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seedlab_page.add_child(sl_bg)
	# Track preview fills the top ~62%, always on screen.
	_seedlab_preview = TrackPreview.new()
	_seedlab_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seedlab_preview.anchor_bottom = 0.62
	_seedlab_preview.offset_bottom = 0.0
	_seedlab_page.add_child(_seedlab_preview)
	# Controls docked along the bottom. A ScrollContainer guards against very short
	# screens (nothing gets cut off) while a compact 2-column grid means everything
	# fits without scrolling in the common case. Focus nav is contained by
	# _wire_seedlab_nav so left/right never leaks between the grid and the button row.
	var cfg0: GameConfig = Config.data
	_seed_spin = _make_spin(0.0, 4_294_967_295.0, 1.0, float(cfg0.track_seed))
	_level_spin = _make_spin(-40.0, 10.0, 0.5, cfg0.track_water_level_m)
	_turns_spin = _make_spin(3.0, 40.0, 1.0, float(cfg0.track_turn_count))
	_straight_spin = _make_spin(0.0, 1.0, 0.05, cfg0.track_straightness)
	# Terrain-noise fields (edited in a separate popup). All authored terrain values
	# are whole numbers, so an integer step is safe — SpinBox snaps value to step, and
	# a coarser step would corrupt a fractional value (none exist here by design).
	_t1w = _make_spin(1.0, 1000.0, 1.0, cfg0.terrain_layer1_wavelength)
	_t1a = _make_spin(0.0, 100.0, 1.0, cfg0.terrain_layer1_amplitude)
	_t2w = _make_spin(1.0, 200.0, 1.0, cfg0.terrain_layer2_wavelength)
	_t2a = _make_spin(0.0, 10.0, 1.0, cfg0.terrain_layer2_amplitude)
	_t3w = _make_spin(1.0, 200.0, 1.0, cfg0.terrain_layer3_wavelength)
	_t3a = _make_spin(0.0, 10.0, 1.0, cfg0.terrain_layer3_amplitude)
	var sl_scroll := ScrollContainer.new()
	sl_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sl_scroll.anchor_top = 0.63
	sl_scroll.offset_left = 40.0
	sl_scroll.offset_right = -40.0
	sl_scroll.offset_top = 8.0
	sl_scroll.offset_bottom = -16.0
	sl_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_seedlab_page.add_child(sl_scroll)
	var sl_panel := VBoxContainer.new()
	sl_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl_panel.add_theme_constant_override("separation", 8)
	sl_scroll.add_child(sl_panel)
	var sl_grid := GridContainer.new()
	sl_grid.columns = 2
	sl_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl_grid.add_theme_constant_override("h_separation", 24)
	sl_grid.add_theme_constant_override("v_separation", 8)
	sl_panel.add_child(sl_grid)
	sl_grid.add_child(_spin_row("Seed", _seed_spin))
	sl_grid.add_child(_spin_row("Water level", _level_spin))
	sl_grid.add_child(_spin_row("Turns", _turns_spin))
	sl_grid.add_child(_spin_row("Straightness", _straight_spin))
	var sl_actions := HBoxContainer.new()
	sl_actions.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl_actions.add_theme_constant_override("separation", 24)
	sl_panel.add_child(sl_actions)
	var sl_load := _make_action_button("Load event…", _open_event_picker)
	sl_load.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl_actions.add_child(sl_load)
	var sl_terrain := _make_action_button("Terrain…", _open_terrain_editor)
	sl_terrain.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl_actions.add_child(sl_terrain)
	var sl_random := _make_action_button("Randomize seed", _randomize_seed)
	sl_random.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl_actions.add_child(sl_random)
	var sl_back := _make_action_button("Back", go_back)
	sl_back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl_actions.add_child(sl_back)
	_wire_seedlab_nav([[_seed_spin, _level_spin], [_turns_spin, _straight_spin]],
		[sl_load, sl_terrain, sl_random, sl_back])
	_build_event_picker()
	_build_terrain_editor()
	_seedlab_page.visible = false  # shown only via show_seedlab()


# --- Navigation --------------------------------------------------------------

# True while the category list is showing (vs a sub-page).
func at_root() -> bool:
	return _list_page != null and _list_page.visible


# Step back one level for the host's Back / cancel: a sub-page returns to the
# category list (and reports it consumed the press); the list reports false so the
# host can close Settings (or run its own bottom action). Keyboard/gamepad Back
# (menu_back / ui_cancel) and the bottom button both route through here.
func go_back() -> bool:
	if at_root():
		return false
	show_list()
	return true


# Put keyboard/gamepad focus on the first selectable row of whichever page is
# showing — called (deferred) by the host once it has revealed the Settings overlay,
# and on every page switch, so a controller always has a live cursor.
func focus_current_page() -> void:
	var page: Control = _list_page
	for p in _pages:
		if p.visible:
			page = p
			break
	_focus_first_in(page)


func _focus_first_in(page: Control) -> void:
	# Prefer the first Button (most pages are button rows; recurses so a button nested
	# in an HBox — the key-binding rows do this — isn't skipped). Fall back to any
	# focusable control so a page whose only control is a slider (Audio) still seats
	# the cursor for keyboard/gamepad.
	var target := UITheme.first_focusable(page, "Button")
	if target == null:
		target = UITheme.first_focusable(page)
	if target != null:
		UITheme.focus_grab(target)


func show_list() -> void:
	_show_page(_list_page)


func show_audio() -> void:
	_show_page(_audio_page)


func show_camera() -> void:
	_show_page(_camera_page)


func show_controls() -> void:
	_show_page(_controls_page)


func show_schemes() -> void:
	_show_page(_scheme_page)


func show_benchmark() -> void:
	_show_page(_benchmark_page)


func show_dev() -> void:
	_show_page(_dev_page)


func show_seedlab() -> void:
	_show_page(_seedlab_page)
	_regen_seedlab()


func _show_page(page: Control) -> void:
	cancel_listen()  # leaving a page abandons any pending key capture
	# Cancel any in-flight seed-lab generation whenever the page changes (including
	# leaving the seed lab) so its animated search stops doing per-frame work.
	_sl_gen += 1
	for p in _pages:
		p.visible = page == p
	page_changed.emit(at_root())
	# Move the focus cursor onto the newly-shown page (deferred so it runs after the
	# visibility change settles; no-op while the whole menu is still hidden on _ready).
	focus_current_page.call_deferred()


# Persist the chosen camera mode, refresh the highlight, and tell any live scene to
# switch (the run's CameraManager wires `camera_changed`).
func select_camera(mode: int) -> void:
	Save.set_setting(CameraManager.SETTING_KEY, mode)
	_refresh_camera_selection()
	camera_changed.emit(mode)


# Persist the chosen scheme, refresh the highlight, and tell any live scene to switch
# (the run's MobileControls wires `scheme_changed`, so the on-screen controls update
# the instant you pick a scheme rather than only on the next run). The HQ has no live
# controls, so it just saves and the choice is applied when the next run boots.
func select_scheme(id: int) -> void:
	Save.set_setting(MobileControls.SETTING_KEY, id)
	_refresh_scheme_selection()
	scheme_changed.emit(id)


# Highlight the row in `rows` whose "key" matches the saved setting under `key`
# (falling back to `default`), un-highlighting the rest.
func _refresh_selection(rows: Array, key: String, default: int) -> void:
	var current := int(Save.get_setting(key, default))
	for entry in rows:
		_highlight(entry["button"], int(entry["key"]) == current)


func _refresh_camera_selection() -> void:
	_refresh_selection(camera_rows, CameraManager.SETTING_KEY, int(CameraManager.ORDER[0]))


func _refresh_scheme_selection() -> void:
	_refresh_selection(scheme_rows, MobileControls.SETTING_KEY, MobileControls.DEFAULT_SCHEME)


# --- Key bindings ------------------------------------------------------------

# Repaint every binding button with its action's current key / controller label.
func _refresh_controls_selection() -> void:
	for row in controls_rows:
		var action: String = row["action"]
		row["keyboard_button"].text = UITheme.caps(
			InputRemap.describe(InputRemap.current_event(action, InputRemap.SLOT_KEYBOARD)))
		row["controller_button"].text = UITheme.caps(
			InputRemap.describe(InputRemap.current_event(action, InputRemap.SLOT_CONTROLLER)))


# Enter "listening" mode for one binding: the next matching input is captured and
# assigned (see _input). The button shows a prompt while we wait.
func _begin_listen(action: String, slot: String, button: Button) -> void:
	cancel_listen()
	_listening = {"action": action, "slot": slot, "button": button}
	button.text = UITheme.caps("Press %s…" % ("a key" if slot == InputRemap.SLOT_KEYBOARD else "a button"))


# Abandon a pending capture (navigated away, Esc, or a fresh listen) and restore the
# button labels. No-op when not listening.
func cancel_listen() -> void:
	if _listening.is_empty():
		return
	_listening = {}
	_refresh_controls_selection()


# Reset every binding to its project.godot default and repaint.
func _reset_bindings() -> void:
	cancel_listen()
	InputRemap.reset_defaults()
	_refresh_controls_selection()


# While listening, grab the first input that fits the slot and assign it. Esc aborts.
# Runs before the GUI pass so the captured key never also triggers a button / Esc
# never also closes the host menu.
func _input(event: InputEvent) -> void:
	if _listening.is_empty():
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		cancel_listen()
		return
	var captured := _capture_for_slot(event, String(_listening["slot"]))
	if captured == null:
		return
	get_viewport().set_input_as_handled()
	var action := String(_listening["action"])
	var slot := String(_listening["slot"])
	_listening = {}
	InputRemap.rebind(action, slot, captured)
	_refresh_controls_selection()


# Build a clean event from a raw input if it matches the slot, else null. Keyboard
# stores the physical keycode (layout-independent, as project.godot does); controller
# accepts a button press or a stick/trigger deflection past the deadzone (stored as a
# sign so a half-press still maps to the full axis direction).
func _capture_for_slot(event: InputEvent, slot: String) -> InputEvent:
	if slot == InputRemap.SLOT_KEYBOARD:
		if event is InputEventKey and event.pressed and not event.echo:
			var k := InputEventKey.new()
			k.physical_keycode = event.physical_keycode
			return k
		return null
	if event is InputEventJoypadButton and event.pressed:
		var b := InputEventJoypadButton.new()
		b.button_index = event.button_index
		return b
	if event is InputEventJoypadMotion and absf(event.axis_value) >= InputRemap.AXIS_THRESHOLD:
		var m := InputEventJoypadMotion.new()
		m.axis = event.axis
		m.axis_value = signf(event.axis_value)
		return m
	return null


# --- Benchmark ---------------------------------------------------------------

# Repaint every benchmark toggle row with its option's current ON/OFF state
# (green-selected while ON, like the camera/scheme selections).
func _refresh_benchmark_rows() -> void:
	for row in benchmark_rows:
		var on: bool = Benchmark.get_option(String(row["key"]))
		row["button"].text = UITheme.caps("%s: %s" % [String(row["name"]), "On" if on else "Off"])
		_highlight(row["button"], on)


# Flip one benchmark toggle and repaint.
func _toggle_benchmark(key: String) -> void:
	Benchmark.set_option(key, not Benchmark.get_option(key))
	_refresh_benchmark_rows()


# Launch the benchmark. The Benchmark autoload owns the rest (unpause, abandon
# any active rally, config overrides, the run-scene load), so this works the
# same from the HQ title screen and the in-run pause menu.
func _start_benchmark() -> void:
	Benchmark.start()


# --- Dev actions -------------------------------------------------------------

# Wipe the entire save profile back to a fresh new-game state. Camera / control
# settings are part of the profile, so refresh their highlights afterwards.
func _wipe_progress() -> void:
	Save.reset_new_game()
	_refresh_camera_selection()
	_refresh_scheme_selection()
	_dev_status.text = "Wiped all progress."


# Dev: instantly win the active rally. Unfreeze first (this page is reached from the
# in-run pause overlay, which paused the tree — mirrors PauseMenu.quit_to_hq) so the
# podium the resolve routes to isn't left paused, then complete the rally: RallySession
# fills every event with a 0 ms time, resolves to a P1 finish, and emits rally_finished,
# which world.gd routes to the podium (where the car reward is granted).
func _complete_rally() -> void:
	if not RallySession.is_active():
		return
	get_tree().paused = false
	RallySession.dev_complete_rally()


# Dev: 3-star every rally so all regions unlock (regions gate on each region's
# showdown being completed — see RegionLibrary.unlocked / features/regions.md).
func _three_star_all_rallies() -> void:
	Save.dev_three_star_all_rallies()
	_dev_status.text = "3-starred all rallies — all regions unlocked."


# Grant a fresh owned instance of any car in the library (no rally required).
func _grant_car(model_id: String, display_name: String) -> void:
	Save.grant_car(model_id)
	_dev_status.text = "Granted %s." % display_name


# Drop a consumable (the repair kit) into the shared inventory.
func _add_upgrade(item_id: String, display_name: String) -> void:
	Save.add_item(item_id)
	_dev_status.text = "Added %s." % display_name


# Fit a slottable part straight onto the selected car — upgrades are car-bound, so
# there's no inventory to stash them in; they live on the car that unlocks them.
func _fit_upgrade(item_id: String, display_name: String) -> void:
	var iid := Save.selected_instance_id()
	if iid < 0:
		_dev_status.text = "Own a car first — nothing to fit %s to." % display_name
		return
	if Save.install_upgrade(iid, item_id):
		_dev_status.text = "Fitted %s to the selected car." % display_name
	else:
		_dev_status.text = "Couldn't fit %s (already fitted?)." % display_name


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


# The column captions above the key-binding rows, aligned over the two button
# columns (a leading spacer matches the action-name column's expand).
func _make_controls_header() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var spacer := Label.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	for caption in ["Keyboard", "Controller"]:
		var label := Label.new()
		label.text = caption
		label.custom_minimum_size = Vector2(_BIND_BUTTON_W, 0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 13)
		row.add_child(label)
	return row


# A key-binding row: the action name (expanding) plus a keyboard button and a
# controller button, each showing the current binding and listening on press.
func _make_control_row(entry: Dictionary) -> HBoxContainer:
	var action := String(entry["action"])
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)

	var name_label := Label.new()
	name_label.text = String(entry["name"])
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_label.add_theme_font_size_override("font_size", 16)
	row.add_child(name_label)

	var keyboard_button := _make_binding_button(action, InputRemap.SLOT_KEYBOARD)
	var controller_button := _make_binding_button(action, InputRemap.SLOT_CONTROLLER)
	row.add_child(keyboard_button)
	row.add_child(controller_button)

	controls_rows.append({
		"action": action,
		"keyboard_button": keyboard_button,
		"controller_button": controller_button,
	})
	return row


# One fixed-width binding button. Pressing it starts listening for that slot.
# Focusable so the bindings page is keyboard/gamepad navigable like the rest
# (ui_left/ui_right hop keyboard↔controller, ui_up/ui_down change action, ui_accept
# starts listening); the theme's focus stylebox paints the cursor.
func _make_binding_button(action: String, slot: String) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_ALL
	button.custom_minimum_size = Vector2(_BIND_BUTTON_W, 36)
	button.pressed.connect(func() -> void: _begin_listen(action, slot, button))
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


# --- Audio -------------------------------------------------------------------

# The music-volume row: [Music   <===slider===>   60%]. The slider is focusable so
# it's keyboard/gamepad navigable (native ui_left/ui_right adjust it); dragging it
# live-applies + persists via MusicDirector (Music autoload). Initial value comes
# from the saved setting, and value_changed is wired AFTER seeding it so building
# the page never re-persists.
func _make_volume_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)

	var name_label := Label.new()
	name_label.text = "Music"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_label.add_theme_font_size_override("font_size", 18)
	row.add_child(name_label)

	music_slider = HSlider.new()
	music_slider.focus_mode = Control.FOCUS_ALL
	music_slider.min_value = 0.0
	music_slider.max_value = 1.0
	music_slider.step = 0.05
	music_slider.custom_minimum_size = Vector2(220, 24)
	music_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	music_slider.value = clampf(
		float(Save.get_setting(MusicDirector.SETTING_KEY, MusicDirector.DEFAULT_VOLUME)), 0.0, 1.0)
	row.add_child(music_slider)

	music_value_label = Label.new()
	music_value_label.custom_minimum_size = Vector2(56, 0)
	music_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	music_value_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(music_value_label)

	_update_music_value_label()
	music_slider.value_changed.connect(_on_music_volume_changed)
	return row


func _on_music_volume_changed(v: float) -> void:
	Music.set_volume(v)  # live-apply to the Music bus + persist to the profile
	_update_music_value_label()


func _update_music_value_label() -> void:
	if music_value_label != null and music_slider != null:
		music_value_label.text = "%d%%" % roundi(music_slider.value * 100.0)


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
	# Wrap long blurbs (e.g. the benchmark page's description) to the width the
	# page's rows set, instead of forcing the whole settings panel wider.
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


# --- Seed lab ----------------------------------------------------------------

# A typeable numeric field, re-rendering the preview on every change.
func _make_spin(mn: float, mx: float, stp: float, val: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = mn
	spin.max_value = mx
	spin.step = stp
	spin.value = val
	spin.update_on_text_changed = true  # type a value, not just click arrows
	spin.custom_minimum_size = Vector2(130, 0)
	spin.value_changed.connect(func(_v: float): _on_spin_changed())
	return spin


# Regenerate on a field change — unless we're mid-sync copying an event's values in
# (then a single regen fires once the whole set lands).
func _on_spin_changed() -> void:
	if _syncing_spins:
		return
	_regen_seedlab()


# A [title    <spin>] row.
func _spin_row(title: String, spin: SpinBox) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 8)
	var name_lbl := Label.new()
	name_lbl.text = title
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_lbl)
	row.add_child(spin)
	return row


func _randomize_seed() -> void:
	_seed_spin.value = float(randi() % 1_000_000)  # fires value_changed -> _regen_seedlab


# Contain left/right so it never leaks between the 2-column field grid and the
# bottom button row. Within the grid, left/right just swaps columns on that row and
# stops at the outer edges (edge cell's outward neighbour points at itself); up/down
# still walks the rows (and off the last row down into the buttons) via Godot's
# geometric default. On the button row, left/right chains between the buttons and
# stops at the ends. `field_rows` is one [left, right] pair per grid row.
func _wire_seedlab_nav(field_rows: Array, buttons: Array) -> void:
	for row in field_rows:
		var l := row[0] as Control
		var r := row[1] as Control
		l.focus_neighbor_left = l.get_path()   # leftmost column: no leftward move
		l.focus_neighbor_right = r.get_path()
		r.focus_neighbor_left = l.get_path()
		r.focus_neighbor_right = r.get_path()  # rightmost column: no rightward move
	for i in buttons.size():
		var b := buttons[i] as Control
		var left: Control = buttons[i - 1] if i > 0 else b
		var right: Control = buttons[i + 1] if i < buttons.size() - 1 else b
		b.focus_neighbor_left = left.get_path()
		b.focus_neighbor_right = right.get_path()


# --- Event picker ------------------------------------------------------------

# A full-screen popup over the seed lab listing every rally and its events. Built
# once (hidden); shown by _open_event_picker. Same top_level / high-z pattern as the
# seed-lab page itself so it escapes the settings VBox layout.
func _build_event_picker() -> void:
	_seedlab_popup = Control.new()
	_seedlab_popup.top_level = true
	_seedlab_popup.z_index = 110  # above the seed-lab page (z 100)
	_seedlab_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seedlab_popup.mouse_filter = Control.MOUSE_FILTER_STOP
	_seedlab_page.add_child(_seedlab_popup)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.85)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seedlab_popup.add_child(dim)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 40.0
	scroll.offset_right = -40.0
	scroll.offset_top = 40.0
	scroll.offset_bottom = -40.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_seedlab_popup.add_child(scroll)  # MenuNav enables follow_focus on open
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)
	list.add_child(_make_heading("Preview event"))
	for rally in RallyLibrary.all():
		var name_text := "%s  (%s)" % [String(rally.get("name", "?")),
			String(rally.get("region", ""))]
		list.add_child(_make_sub(name_text))
		var events: Array = rally.get("events", [])
		for i in events.size():
			var event: Dictionary = events[i]
			var label := "Event %d — seed %d, %d turns" % [i + 1,
				int(event.get("seed", 0)), int(event.get("turn_count", 0))]
			var btn := _make_action_button(label, _load_event.bind(event))
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			btn.focus_entered.connect(_remember_event_focus.bind(btn))
			list.add_child(btn)
	list.add_child(_make_action_button("Close", _close_event_picker))
	_seedlab_popup.visible = false


func _remember_event_focus(btn: Control) -> void:
	_event_focus = btn


func _open_event_picker() -> void:
	_seedlab_popup.visible = true
	# Keyboard/gamepad: walk the rows, B / Esc closes (per the menu-nav rule). Reopen
	# lands on the row the cursor last sat on (follow_focus scrolls it into view).
	var first: Control = _event_focus if is_instance_valid(_event_focus) else null
	MenuNav.attach(_seedlab_popup, {"first": first, "on_back": _close_event_picker})


func _close_event_picker() -> void:
	_seedlab_popup.visible = false
	focus_current_page()  # cursor back onto the seed-lab controls


# Load a real rally event: copy every field the lab can drive into its spinboxes
# (the four core inputs + the six terrain-noise fields) so the inputs stay the single
# source of truth AND the preview matches the real career stage. Terrain matters
# because the generator routes the road around below-water cells and relocates the
# dry start — omitting it made the lab's lakes disagree with the event. Omitted keys
# fall back to the authored base config (exactly as RallySession.apply_event_config).
func _load_event(event: Dictionary) -> void:
	var base: GameConfig = load(Config.CONFIG_PATH)
	_syncing_spins = true
	_seed_spin.value = float(int(event.get("seed", base.track_seed)))
	_level_spin.value = float(event.get("water_level", base.track_water_level_m))
	_turns_spin.value = float(int(event.get("turn_count", base.track_turn_count)))
	_straight_spin.value = RallyLibrary.event_straightness(event)
	_t1w.value = float(event.get("terrain_layer1_wavelength", base.terrain_layer1_wavelength))
	_t1a.value = float(event.get("terrain_layer1_amplitude", base.terrain_layer1_amplitude))
	_t2w.value = float(event.get("terrain_layer2_wavelength", base.terrain_layer2_wavelength))
	_t2a.value = float(event.get("terrain_layer2_amplitude", base.terrain_layer2_amplitude))
	_t3w.value = float(event.get("terrain_layer3_wavelength", base.terrain_layer3_wavelength))
	_t3a.value = float(event.get("terrain_layer3_amplitude", base.terrain_layer3_amplitude))
	_syncing_spins = false
	_close_event_picker()
	_regen_seedlab()


# The lab's inputs as an EventDef — the same dict shape RallyLibrary events use.
# The preview generates from THIS through the exact career path (see _regen_seedlab),
# so what the lab shows matches what the stage actually generates.
func _seedlab_event() -> Dictionary:
	return {
		"seed": int(_seed_spin.value),
		"turn_count": int(_turns_spin.value),
		"straightness": _straight_spin.value,
		"water_level": _level_spin.value,
		"terrain_layer1_wavelength": _t1w.value,
		"terrain_layer1_amplitude": _t1a.value,
		"terrain_layer2_wavelength": _t2w.value,
		"terrain_layer2_amplitude": _t2a.value,
		"terrain_layer3_wavelength": _t3w.value,
		"terrain_layer3_amplitude": _t3a.value,
	}


# --- Terrain editor ----------------------------------------------------------

# A popup exposing the six terrain-noise fields. Docked over the lower controls so
# the track preview stays visible above it and updates live as values change.
func _build_terrain_editor() -> void:
	_seedlab_terrain_popup = Control.new()
	_seedlab_terrain_popup.top_level = true
	_seedlab_terrain_popup.z_index = 110
	_seedlab_terrain_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_seedlab_terrain_popup.mouse_filter = Control.MOUSE_FILTER_STOP
	_seedlab_page.add_child(_seedlab_terrain_popup)
	var panel := ColorRect.new()
	panel.color = Color(0, 0, 0, 0.92)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.anchor_top = 0.63  # leave the preview (top ~62%) visible for live feedback
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_seedlab_terrain_popup.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.anchor_top = 0.63
	scroll.offset_left = 40.0
	scroll.offset_right = -40.0
	scroll.offset_top = 8.0
	scroll.offset_bottom = -16.0
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_seedlab_terrain_popup.add_child(scroll)
	var panel_box := VBoxContainer.new()
	panel_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_box.add_theme_constant_override("separation", 8)
	scroll.add_child(panel_box)
	panel_box.add_child(_make_heading("Terrain noise"))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 24)
	grid.add_theme_constant_override("v_separation", 8)
	panel_box.add_child(grid)
	grid.add_child(_spin_row("Hills wavelength", _t1w))
	grid.add_child(_spin_row("Hills amplitude", _t1a))
	grid.add_child(_spin_row("Mid wavelength", _t2w))
	grid.add_child(_spin_row("Mid amplitude", _t2a))
	grid.add_child(_spin_row("Fine wavelength", _t3w))
	grid.add_child(_spin_row("Fine amplitude", _t3a))
	panel_box.add_child(_make_action_button("Close", _close_terrain_editor))
	_seedlab_terrain_popup.visible = false


func _open_terrain_editor() -> void:
	_seedlab_terrain_popup.visible = true
	MenuNav.attach(_seedlab_terrain_popup, {"on_back": _close_terrain_editor})


func _close_terrain_editor() -> void:
	_seedlab_terrain_popup.visible = false
	focus_current_page()


# Generate the trial track and paint the preview, ANIMATING the DFS like the
# loading screen (on_progress yields a frame per step). A generation token drops
# stale runs so rapid edits don't fight over the preview.
func _regen_seedlab() -> void:
	if _seedlab_preview == null:
		return
	_sl_gen += 1
	var gen := _sl_gen
	# Generate through the SAME path the career uses — for_event on the event resolved
	# to its canonical config — so the preview matches the real stage exactly (start-
	# line staging, lead-in reserve, width, water, terrain). for_trial skipped staging,
	# which is why the lab's shapes disagreed with the cached career tracks.
	var ev := _seedlab_event()
	var cfg := RallySession.canonical_event_config(ev)
	var params := TrackGenParams.for_event(ev, cfg)
	# Paint the waterline first (known up-front) over a rough box, then animate.
	var reach := clampf(float(params.turn_count) * 12.0, 200.0, 600.0)
	var box := Rect2(params.origin - Vector2(reach, reach), Vector2(reach, reach) * 2.0)
	box = LoadingScreen.expand_to_aspect(box, LoadingScreen.aspect_of(_seedlab_preview.size))
	var wp: Array = LakeField.preview_cells(params, box)
	_seedlab_preview.set_water(wp[0], wp[1], box)
	var on_prog := func(pts: PackedVector2Array) -> void:
		if gen == _sl_gen:
			_seedlab_preview.set_points(pts)
	# should_abort stops the search the instant a newer request (or leaving the page)
	# bumps the token — so stale generations don't keep running every frame.
	var abort := func() -> bool: return gen != _sl_gen
	var res: Dictionary = await TrackGenerator.generate(params, on_prog, abort)
	if gen != _sl_gen:
		return  # a newer request superseded this one
	var poly := (res["centerline"] as Curve2D).tessellate()
	_seedlab_preview.set_points(poly)
	# Refine water to the actual track bounds.
	var tb := LoadingScreen.bounds_of(poly).grow(60.0)
	tb = LoadingScreen.expand_to_aspect(tb, LoadingScreen.aspect_of(_seedlab_preview.size))
	var wp2: Array = LakeField.preview_cells(params, tb)
	_seedlab_preview.set_water(wp2[0], wp2[1], tb)


func _make_row_button(min_height: float) -> Button:
	var button := Button.new()
	# Focusable so keyboard / gamepad can walk the rows (ui_up/ui_down) and fire one
	# with ui_accept; the theme's focus stylebox paints the cursor (same look as hover).
	button.focus_mode = Control.FOCUS_ALL
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

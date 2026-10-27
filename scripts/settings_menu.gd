class_name SettingsMenu
extends VBoxContainer
# Docs: features/settings.md (adding/changing a setting), features/menu-navigation.md (every row must be keyboard+gamepad navigable) — update in the same change as this file.
# Tests: tests/headless/test_settings_menu.gd, tests/headless/test_menu_nav.gd, tests/headless/test_benchmark_ui.gd — extend in the same change. Others: grep -rl SettingsMenu tests/.
# A reusable settings panel shared by the title screen's Settings page and
# the pause menu, so both present the SAME options. It opens on a LIST of
# categories; each
# row drills into its own sub-page:
#   • Audio — a Master volume slider (AudioServer bus 0, so it scales everything:
#     music, engine, UI) and a Music volume slider (the Music bus, on top of
#     master). Both live-apply and persist via the Music autoload
#     (MusicDirector.set_master_volume / set_volume).
#   • Display — pick the frame-rate cap (30 / 60 / uncapped), persisted under
#     FpsSetting.SETTING_KEY. Applied live via Engine.max_fps (a global engine
#     property, so both hosts take effect immediately); world._ready() re-derives
#     it next run. Defaults to the platform's cap (web-touch 30, else 60).
#   • Camera — pick the camera angle (chase / bonnet), persisted under
#     CameraManager.SETTING_KEY. Emits `camera_changed` so a live scene (the run's
#     CameraManager) can switch immediately.
#   • Gearbox — the transmission is always automatic now; there is no manual option
#     and no settings row for it. `SettingsMenu.gearbox_auto()` always returns true;
#     car.gd mirrors it onto the live engine every tick.
#   • Key bindings — rebind the keyboard and controller controls. Each driving
#     action (InputRemap.ACTIONS) gets a row with a keyboard button and a controller
#     button showing its current binding; tapping one listens for the next key /
#     gamepad input and stores it via InputRemap. A "Reset to defaults" row clears
#     all overrides. Esc cancels a pending listen.
#   • Mobile controls — pick the touch control scheme (MobileControls.SCHEMES),
#     persisted under MobileControls.SETTING_KEY. Each row carries a vector layout
#     diagram (ControlSchemeDiagram), as on the original title-screen page.
#   • Reset progress — wipe the save back to a fresh new game (local AND, when
#     signed in, the cloud copy). Player-facing, NOT dev tooling: it is the only
#     way to start over, so it sits in the ordinary list behind a confirm modal.
#   • Benchmark — configure and launch the in-game performance benchmark
#     (features/benchmark.md): one ON/OFF row per Benchmark.TOGGLES entry
#     (vegetation, spectators, render distance, …) and a Start row that hands off
#     to the Benchmark autoload (which owns the config overrides + scene change).
# Navigation is internal: show_list()/show_camera()/show_schemes() swap which page
# is visible. `page_changed(is_root)` lets the host adapt its single bottom button
# — on a sub-page it means "< Back" (to the list); on the list it means the host's
# own action (exit Settings). Choices are stored
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
const _BIND_BUTTON_W := 168.0 * UITheme.UI_SCALE

# Standing copy on the Reset progress page: the warning shown above the button, and
# the body of the confirm modal (which appends the cloud line when signed in). One
# string so the page and the prompt cannot describe the same destruction differently.
const RESET_WARNING := "Start a brand new game. Your world, cars, parts, money and " \
	+ "checkpoints are erased — on this device and, while you are signed in, in " \
	+ "the cloud. This cannot be undone."


# Test override for dev_tools_enabled(): -1 = use the real default, 0 = force
# off, 1 = force on. Lets a test assert the off case even though the shipped
# default is now always-on.
static var dev_tools_override := -1


# Are the developer-only settings pages (Benchmark / Dev) reachable,
# and — via this same switch, checked at every OTHER dev-affordance site in the
# project (car.gd, hud.gd, world.gd, terrain_manager.gd, perf_log.gd) — every other dev key/overlay/log too. One
# switch, defaulting to true: dev features are exposed to every player, not just
# debug builds, so the whole in-game toolkit (grip grid, force arrows,
# config hot-reload, perf overlay/log) is
# reachable in the shipped release/web export as well as the editor.
static func dev_tools_enabled() -> bool:
	if dev_tools_override >= 0:
		return dev_tools_override == 1
	return true

# Selectable rows, exposed for tests / hosts: [{key: Variant, button: Button}].
var camera_rows: Array = []
var scheme_rows: Array = []
var fps_rows: Array = []
var outline_button: Button = null
# Key-binding rows, exposed for tests / hosts:
# [{action: String, keyboard_button: Button, controller_button: Button}].
var controls_rows: Array = []
var _dev_weather_button: Button
# Benchmark toggle rows, exposed for tests: [{key: String, button: Button}].
var benchmark_rows: Array = []

# The swappable pages (only one visible at a time).
var _list_page: VBoxContainer
var _audio_page: VBoxContainer
var _display_page: VBoxContainer
# The Audio page's volume sliders + their live "%" labels (exposed for tests).
# Master scales everything (bus 0); music is the Music bus on top of it.
var master_slider: HSlider
var master_value_label: Label
var music_slider: HSlider
var music_value_label: Label
var _camera_page: VBoxContainer
var _controls_page: VBoxContainer
var _scheme_page: VBoxContainer
var _benchmark_page: VBoxContainer
var _dev_page: VBoxContainer
var _dev_status: Label  # feedback line on the dev page ("Added …", "Granted …")
var _reset_page: VBoxContainer
var _reset_status: Label  # warning line, replaced with the outcome after a wipe
var _account_page: VBoxContainer
var _account: AccountMenu  # optional cloud save; see features/cloud-save.md
# The single source of truth for the swappable pages, id -> page. show_page(id)
# swaps visibility over this.
var _pages: Dictionary = {}

# While the player is reassigning a control, the pending capture:
# {action: String, slot: String, button: Button}; empty when not listening.
var _listening: Dictionary = {}


func _ready() -> void:
	add_theme_constant_override("separation", 10)
	_build()
	UITheme.enforce(self)  # house rules: uppercase + one font size
	show_list()


func _build() -> void:
	_build_list_page()
	_build_audio_page()
	_build_display_page()
	_build_camera_page()
	_build_controls_page()
	_build_schemes_page()
	_build_benchmark_page()
	_build_dev_page()
	_build_account_page()
	_build_reset_page()

	# Single source of truth for the swappable pages (list first — it's the
	# default page). show_page / _show_page / focus_current_page fan out over
	# this so adding a page only means adding an entry here.
	_pages = {
		"list": _list_page, "audio": _audio_page, "display": _display_page,
		"camera": _camera_page, "controls": _controls_page,
		"schemes": _scheme_page, "benchmark": _benchmark_page, "dev": _dev_page,
		"account": _account_page, "reset": _reset_page,
	}

	_refresh_camera_selection()
	_refresh_scheme_selection()
	_refresh_fps_selection()
	_refresh_outline_row()
	_refresh_controls_selection()
	_refresh_benchmark_rows()


func _build_list_page() -> void:
	# Category list — one nav button per sub-page, laid out in a 2-column grid so the
	# list stays short (about half the height) instead of a long single column that
	# overflows and scrolls.
	_list_page = _make_page()
	add_child(_list_page)
	# No subtitle: the page is a grid of named category buttons under a SETTINGS heading, so
	# "Choose a category:" only restated what the buttons already show.
	var list_grid := GridContainer.new()
	list_grid.columns = 2
	list_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_grid.add_theme_constant_override("h_separation", 10)
	list_grid.add_theme_constant_override("v_separation", 10)
	_list_page.add_child(list_grid)
	list_grid.add_child(_make_nav_button("Audio", show_audio))
	list_grid.add_child(_make_nav_button("Display", show_page.bind("display")))
	list_grid.add_child(_make_nav_button("Camera", show_camera))
	list_grid.add_child(_make_nav_button("Key bindings", show_controls))
	list_grid.add_child(_make_nav_button("Mobile controls", show_schemes))
	# Reset progress is a PLAYER setting, not dev tooling: starting over is something
	# anyone is allowed to do, so it is offered unconditionally (the destructive part
	# is guarded by a confirm modal, not by hiding the button). It goes after the
	# everyday categories — it is the one row nobody should reach for by accident.
	list_grid.add_child(_make_nav_button("Reset progress", show_page.bind("reset")))
	# Developer tooling is hidden from players. The pages are still BUILT (and the
	# show_* methods still work, which is how the tests reach them) — only the way
	# in is removed, so nothing else has to learn about the distinction.
	if dev_tools_enabled():
		list_grid.add_child(_make_nav_button("Benchmark", show_benchmark))
		list_grid.add_child(_make_nav_button("Dev", show_dev))


func _build_audio_page() -> void:
	# Audio sub-page — master volume (everything) then music volume (music only,
	# scaled by master since the Music bus sends to Master).
	_audio_page = _make_page()
	add_child(_audio_page)
	_audio_page.add_child(_make_heading("Audio"))
	_audio_page.add_child(_make_sub("Set the volume levels:"))

	var master := _make_volume_row("Master", float(Save.get_setting(
		MusicDirector.MASTER_SETTING_KEY, MusicDirector.DEFAULT_MASTER_VOLUME)))
	master_slider = master["slider"]
	master_value_label = master["value_label"]
	master_slider.value_changed.connect(_on_master_volume_changed)
	_audio_page.add_child(master["row"])

	var music := _make_volume_row("Music", float(Save.get_setting(
		MusicDirector.SETTING_KEY, MusicDirector.DEFAULT_VOLUME)))
	music_slider = music["slider"]
	music_value_label = music["value_label"]
	music_slider.value_changed.connect(_on_music_volume_changed)
	_audio_page.add_child(music["row"])


func _build_display_page() -> void:
	# Display sub-page — the frame-rate cap (FpsSetting): 30 / 60 / uncapped, then the
	# Outlines toggle (OutlineSetting).
	_display_page = _make_page()
	add_child(_display_page)
	_display_page.add_child(_make_heading("Display"))
	_display_page.add_child(_make_sub("Limit the frame rate:"))
	_build_option_page(_display_page, FpsSetting.OPTIONS, "value", fps_rows, select_fps)
	outline_button = _make_action_button("", toggle_outlines)
	_display_page.add_child(outline_button)


func _build_camera_page() -> void:
	# Camera sub-page.
	_camera_page = _make_page()
	add_child(_camera_page)
	_camera_page.add_child(_make_heading("Camera"))
	_camera_page.add_child(_make_sub("Pick your camera angle:"))
	_build_option_page(_camera_page, CameraManager.MODES, "mode", camera_rows, select_camera)


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
	_build_option_page(_scheme_page, MobileControls.SCHEMES, "id", scheme_rows, select_scheme,
		_make_scheme_row)


func _build_benchmark_page() -> void:
	# Benchmark sub-page — the pre-run feature toggles + Start (features/benchmark.md).
	_benchmark_page = _make_page()
	add_child(_benchmark_page)
	_benchmark_page.add_child(_make_heading("Benchmark"))
	_benchmark_page.add_child(_make_sub(
		"Auto-drive a route across a fixed island and measure performance. Toggle features to isolate their cost:"))
	benchmark_rows.clear()
	for entry in Benchmark.TOGGLES:
		var key := String(entry["key"])
		var button := _make_action_button("", _toggle_benchmark.bind(key))
		benchmark_rows.append({"key": key, "name": String(entry["name"]), "button": button})
		_benchmark_page.add_child(button)
	_benchmark_page.add_child(_make_action_button("Start benchmark  >", _start_benchmark))


func _build_dev_page() -> void:
	# Dev sub-page: money for the free-roam shop, and the whole map unlocked for travel. Wiping the save
	# is NOT here: it is a player setting, on its own Reset progress page (which dev
	# builds see too), so there is exactly one route to it.
	_dev_page = _make_page()
	add_child(_dev_page)
	_dev_page.add_child(_make_heading("Dev"))
	_dev_status = _make_sub("Developer actions.")
	_dev_page.add_child(_dev_status)
	_dev_page.add_child(_make_action_button("Add $%d" % DEV_MONEY_GRANT, _add_dev_money))
	_dev_page.add_child(_make_action_button("Unlock entire map", _unlock_map))
	_dev_weather_button = _make_action_button("", _cycle_dev_weather)
	_dev_page.add_child(_dev_weather_button)
	_refresh_dev_weather()


# Reset progress sub-page — the player-facing "start over". One button, a standing
# warning line above it (which doubles as the outcome report afterwards), and a
# confirm modal before anything is destroyed.
func _build_reset_page() -> void:
	_reset_page = _make_page()
	add_child(_reset_page)
	_reset_page.add_child(_make_heading("Reset progress"))
	_reset_status = _make_sub(RESET_WARNING)
	_reset_page.add_child(_reset_status)
	_reset_page.add_child(_make_action_button("Wipe all progress", _prompt_wipe_progress))


# Account sub-page — optional cloud save. The AccountMenu widget owns the whole
# page (it is also hosted standalone from the title screen), so this is just a
# mount point.
func _build_account_page() -> void:
	_account_page = _make_page()
	add_child(_account_page)
	_account = AccountMenu.new()
	_account_page.add_child(_account)


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
	# The account page has its own sub-forms (sign in / register / reset), so give
	# it first refusal before backing out of the page entirely.
	if _account_page != null and _account_page.visible and _account != null \
			and _account.go_back():
		return true
	show_list()
	return true


# Put keyboard/gamepad focus on the first selectable row of whichever page is
# showing — called (deferred) by the host once it has revealed the Settings overlay,
# and on every page switch, so a controller always has a live cursor.
func focus_current_page() -> void:
	var page: Control = _list_page
	for p in _pages.values():
		if (p as Control).visible:
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


# Show the page registered under `id` in `_pages`. The handful of show_* wrappers below exist only
# because other files (and tests) call them by name; anything reached only from
# inside this file goes through show_page directly.
func show_page(id: String) -> void:
	_show_page(_pages[id])


func show_list() -> void:
	show_page("list")


func show_audio() -> void:
	show_page("audio")


func show_camera() -> void:
	show_page("camera")


func show_controls() -> void:
	show_page("controls")


func show_schemes() -> void:
	show_page("schemes")


func show_benchmark() -> void:
	show_page("benchmark")


func show_dev() -> void:
	show_page("dev")


func _show_page(page: Control) -> void:
	cancel_listen()  # leaving a page abandons any pending key capture
	for p in _pages.values():
		(p as Control).visible = page == p
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
# the instant you pick a scheme rather than only on the next run).
func select_scheme(id: int) -> void:
	Save.set_setting(MobileControls.SETTING_KEY, id)
	_refresh_scheme_selection()
	scheme_changed.emit(id)


# Persist the chosen frame cap and apply it live. Unlike camera/scheme, the frame
# cap is a global engine property, so it's applied by writing Engine.max_fps
# directly (takes effect immediately) rather than via a
# live-scene signal. world._ready() re-derives it from the same setting next run.
# Skipped under --headless (no rendering to pace / test runner must stay uncapped).
func select_fps(value: int) -> void:
	Save.set_setting(FpsSetting.SETTING_KEY, value)
	_refresh_fps_selection()
	if not Platform.is_headless():
		Engine.max_fps = value


# Highlight the row in `rows` whose "key" matches the saved setting under `key`
# (falling back to `default`), un-highlighting the rest.
func _refresh_selection(rows: Array, key: String, default: int) -> void:
	var current := int(Save.get_setting(key, default))
	for entry in rows:
		_highlight(entry["button"], int(entry["key"]) == current)


func _refresh_camera_selection() -> void:
	_refresh_selection(camera_rows, CameraManager.SETTING_KEY, int(CameraManager.ORDER[0]))


# Is the transmission automatic? Always true now — there is no manual option.
# Static so car.gd can ask without holding a menu instance.
static func gearbox_auto() -> bool:
	return true


func _refresh_scheme_selection() -> void:
	_refresh_selection(scheme_rows, MobileControls.SETTING_KEY, MobileControls.DEFAULT_SCHEME)


# Flip the Outlines setting (OutlineSetting) and repaint its row.
func toggle_outlines() -> void:
	OutlineSetting.apply(get_tree(), not OutlineSetting.resolve())
	_refresh_outline_row()


func _refresh_outline_row() -> void:
	var on := OutlineSetting.resolve()
	outline_button.text = UITheme.caps("Outlines: %s" % ("On" if on else "Off"))
	_highlight(outline_button, on)


func _refresh_fps_selection() -> void:
	# Default highlight = the platform's natural cap (web-touch 30, else 60), so the
	# option that's actually in force reads as selected before the player picks.
	_refresh_selection(fps_rows, FpsSetting.SETTING_KEY, FpsSetting.default_cap())


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


# Launch the benchmark. The Benchmark autoload owns the rest (unpause, config
# overrides, the run-scene load), so this works the same from the title screen
# and the pause menu.
func _start_benchmark() -> void:
	Benchmark.start()


# --- Reset progress ----------------------------------------------------------

# Ask before starting over. THE BUTTON NEVER WIPES DIRECTLY: this is offered to every
# player (not just dev builds), it is irreversible, and it reaches the cloud copy too —
# so the press opens the house confirm modal and the wipe only runs from its second
# action. House button order puts the cancelling action leftmost and it is also the
# default focus + the Back target, so a stray Enter / gamepad-B can only back out.
func _prompt_wipe_progress() -> void:
	var body := RESET_WARNING
	if Cloud != null and Cloud.is_signed_in():
		body += "\n\nYour cloud save is cleared as well, so this will not come back " \
			+ "on your other devices."
	ConfirmPopup.open(self, "Wipe all progress?", body,
		[ {"label": "Cancel", "callback": Callable()},
		  {"label": "Wipe everything", "callback": _wipe_progress} ],
		0, 0)


# Wipe the entire save profile back to a fresh new-game state. Camera / control
# settings are part of the profile, so refresh their highlights afterwards.
# The cloud copy is wiped too when signed in — otherwise the next pull sees a
# clean local against an ahead cloud and restores everything, so the wipe would
# silently undo itself (see Cloud.publish_local_wipe). Behind the shared busy
# cover, since it is a real network round-trip.
#
# Called by the confirm modal, and directly by tests — the confirmation is
# _prompt_wipe_progress's job, so this stays the plain "do it" entry point.
#
# Ends by rebooting through the title scene (see _reload_after_wipe), because the live
# world still holds the old car and state the wipe just erased.
func _wipe_progress() -> void:
	Save.reset_new_game()
	_refresh_camera_selection()
	_refresh_scheme_selection()
	_reset_status.text = "Wiped all progress."
	if Cloud == null or not Cloud.is_signed_in():
		_reload_after_wipe()
		return
	var result: Dictionary = await CloudBusy.run_covered(
		self, "Wiping your progress…", "Clearing your cloud save…",
		func() -> Dictionary: return await Cloud.publish_local_wipe())
	if not is_instance_valid(_reset_status):
		return
	_reset_status.text = "Wiped all progress (local and cloud)." \
		if bool(result.get("ok", false)) \
		else "Wiped locally — the cloud copy could not be cleared, so it may come back."
	_reload_after_wipe()


# Boot again as a brand-new player would. Routed through
# Scenes.change_to so tests (which arm Scenes.block_real_changes) stay inert.
func _reload_after_wipe() -> void:
	Scenes.change_to(get_tree(), Scenes.TITLE)


# --- Dev actions -------------------------------------------------------------
#
# The dev page's action. Not a setting, so nothing here persists a player choice; it edits the
# world session and reports through _dev_status.

const DEV_MONEY_GRANT := 10000


func _add_dev_money() -> void:
	if not WorldSession.has_world():
		_dev_status.text = "No world yet."
		return
	WorldSession.set_money(WorldSession.money() + DEV_MONEY_GRANT)
	_dev_status.text = "$%d." % WorldSession.money()


# Put every biome ring's stock on sale and open the whole island for travel (the live free-roam scene does the rest).
func _unlock_map() -> void:
	var scene := get_tree().current_scene
	if not WorldSession.has_world() or scene == null or not scene.has_method("unlock_map"):
		_dev_status.text = "No world yet."
		return
	var rings: Array = []
	for r in Config.data.free_roam.ring_count:
		rings.append(r)
	WorldSession.set_list("revealed", rings)
	scene.unlock_map()
	_dev_status.text = "Map unlocked."


# The live world's biome director, or null outside free roam.
func _biome_director() -> BiomeDirector:
	var scene := get_tree().current_scene
	return scene.get_node_or_null("BiomeDirector") as BiomeDirector if scene != null else null


# Step the forced weather through Auto (the rings' own draw) and every condition, applied at once.
func _cycle_dev_weather() -> void:
	var director := _biome_director()
	if director == null:
		_dev_status.text = "No world yet."
		return
	var ids: Array = [""]
	for entry in WeatherLibrary.all():
		ids.append(String(entry["id"]))
	director.forced_weather = ids[(ids.find(director.forced_weather) + 1) % ids.size()]
	director.update_now()
	_refresh_dev_weather()


func _refresh_dev_weather() -> void:
	var director := _biome_director() if is_inside_tree() else null
	var id := director.forced_weather if director != null else ""
	_dev_weather_button.text = "Weather: %s" % (id.capitalize() if id != "" else "Auto")


# --- Row builders ------------------------------------------------------------

# A category row on the list page: a plain menu button that opens a sub-page. The
# trailing ASCII ">" reads as "drills in" (the font lacks arrow glyphs — same
# reason the rest of the UI uses ASCII < / >).
func _make_nav_button(text: String, on_press: Callable) -> Button:
	var button := _make_row_button(UITheme.px(48))
	button.text = "%s  >" % text
	button.pressed.connect(on_press)
	return button


# A plain labelled action button (used by the dev page).
func _make_action_button(text: String, on_press: Callable) -> Button:
	var button := _make_row_button(UITheme.px(40))
	button.text = text
	button.pressed.connect(on_press)
	return button


# Fill an options page (camera / fps / mobile-scheme) from a table of
# entries: clear `rows`, then build + append one row per entry, keyed by
# `key_field` (e.g. "mode", "value", "id"). `row_builder` lets a page swap in a
# richer row (the scheme page's diagram-carrying _make_scheme_row) while sharing
# everything else — the default is the flat name+blurb button every other page uses.
func _build_option_page(page: VBoxContainer, options: Array, key_field: String,
		rows: Array, on_select: Callable, row_builder := Callable(self, "_make_option_row")) -> void:
	rows.clear()
	for entry in options:
		var key := int(entry[key_field])
		page.add_child(row_builder.call(key, entry, rows, on_select))


# The flat name+blurb row shared by the camera / fps pages: a full-width
# Button carrying the option's name and how-to text, no diagram.
func _make_option_row(key: int, entry: Dictionary, rows: Array, on_select: Callable) -> Button:
	var button := _make_row_button(UITheme.px(64))
	button.pressed.connect(on_select.bind(key))
	var text := _make_row_text(button)
	_add_row_labels(text, String(entry["name"]), String(entry["desc"]))
	rows.append({"key": key, "button": button})
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
		label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
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
	name_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
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
	button.custom_minimum_size = Vector2(_BIND_BUTTON_W, UITheme.px(36))
	button.pressed.connect(func() -> void: _begin_listen(action, slot, button))
	return button


# A scheme row: the same flat Button, with a layout diagram beside the text so the
# option visually shows its touch layout (the inner controls are mouse-transparent).
# Same (key, entry, rows, on_select) shape as _make_option_row so _build_option_page
# can drive this page too — it's the one row that carries an extra diagram.
func _make_scheme_row(id: int, entry: Dictionary, rows: Array, on_select: Callable) -> Button:
	var button := _make_row_button(UITheme.px(92))
	button.pressed.connect(on_select.bind(id))

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
	diagram.custom_minimum_size = Vector2(UITheme.px(176), UITheme.px(100))
	row.add_child(diagram)

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text)
	_add_row_labels(text, String(entry["name"]), String(entry["desc"]))

	rows.append({"key": id, "button": button})
	return button


# --- Audio -------------------------------------------------------------------

# One volume row, built through the shared SliderRow widget (the same builder the
# tuning panel and upgrades-menu detune row use — see slider_row.gd) rather than a
# third hand-copied slider row: that copy had already drifted from the other two
# (18px name label vs. SliderRow's 16, no SLIDER_MIN_W floor, no focus highlight).
# The slider is focusable so it's keyboard/gamepad navigable (native ui_left/
# ui_right adjust it); dragging it live-applies + persists via MusicDirector (Music
# autoload), which owns both the Master and Music bus levels. Initial value comes
# from the saved setting, seeded with set_value_no_signal so building the page never
# re-persists. Returns {row, slider, value_label}.
func _make_volume_row(label_text: String, initial: float) -> Dictionary:
	var built := SliderRow.build({"name": label_text, "min": 0.0, "max": 1.0, "step": 0.05})
	var slider: HSlider = built["slider"]
	slider.set_value_no_signal(clampf(initial, 0.0, 1.0))
	var value_label: Label = built["value_label"]
	value_label.text = _volume_percent(slider.value)
	return {"row": built["panel"], "slider": slider, "value_label": value_label}


func _on_master_volume_changed(v: float) -> void:
	Music.set_master_volume(v)  # live-apply to bus 0 + persist to the profile
	_update_volume_label(master_value_label, master_slider)


func _on_music_volume_changed(v: float) -> void:
	Music.set_volume(v)  # live-apply to the Music bus + persist to the profile
	_update_volume_label(music_value_label, music_slider)


func _update_volume_label(value_label: Label, slider: HSlider) -> void:
	if value_label != null and slider != null:
		value_label.text = _volume_percent(slider.value)


func _volume_percent(v: float) -> String:
	return "%d%%" % roundi(v * 100.0)


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
	label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	return label


func _make_sub(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	# Wrap long blurbs (e.g. the benchmark page's description) to the width the
	# page's rows set, instead of forcing the whole settings panel wider.
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


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
	name_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(name_label)
	var desc_label := Label.new()
	desc_label.text = desc_text
	desc_label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(desc_label)


# Highlight a selected row in the house style (green underline + green text),
# flattening the rest. Delegates to the shared design system (UITheme).
func _highlight(button: Button, selected: bool) -> void:
	UITheme.mark_selected(button, selected)

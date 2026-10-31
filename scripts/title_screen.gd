class_name TitleScreen
extends Control
# Docs: features/world-session.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_title_screen.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# The title screen (todo/2026-10-19-free-roam-pivot.md decision 20): the game's front door, shown
# over the live, paused world (free_roam.gd → _show_title). Card pages (CardUI.card_page / card_list)
# driven by MenuNav:
#   MAIN     — Continue (closes the menu; only with a world the player has driven), New World, Settings.
#   STARTER  — a new world starts by choosing one of a few starter cars (decision 19); picking one
#              creates the world and drives into it.
#   SETTINGS — the shared SettingsMenu.
#   FIRST_RUN — shown once to a brand-new player before MAIN: the SettingsMenu's camera page, then
#              (on touch devices) its touch-layout page. Picking a row, Next or Back moves on. After
#              the cold open (ColdOpen) it's shown on its own (`options_only`) and closes into the game.
# New World over an existing world asks first: the old world, its cars and its loot are lost.
# A first-time player's world was already built at boot (WorldSession.fresh), so New World just
# picks the car for it.

enum View { MAIN, STARTER, SETTINGS, FIRST_RUN }

const FIRST_RUN_DONE_KEY := "first_run_setup_done"

var view := View.MAIN
# Only the first-run options, closing back into the game when done (the end of the cold open).
var options_only := false
var _page: MenuPage
var _cards: CardCarousel
var _settings_menu: SettingsMenu
# Continue: the host hides the menu over the world it's already showing.
var close := func() -> void: pass
# A new world (or a new car on the fresh one) loads the scene afresh. A test swaps it for a capture.
var enter_world := func() -> void: Scenes.change_to(get_tree(), Scenes.FREE_ROAM)


func _ready() -> void:
	add_to_group(MusicLibrary.MENU_GROUP)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.4)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_show(View.FIRST_RUN if options_only or needs_first_run() else View.MAIN)
	if not options_only:
		_check_for_update()


static func needs_first_run() -> bool:
	return WorldSession.fresh and not Save.get_setting(FIRST_RUN_DONE_KEY, false)


static func starter_choices() -> PackedStringArray:
	return LootRules.starter_cars()


func _show(v: View) -> void:
	if _page != null:
		CardUI.park_previews(_page)
		_page.queue_free()
	_cards = null
	view = v
	match v:
		View.MAIN:
			_page = CardUI.card_page(self, {"title": "TAPPA"})
			var entries: Array = []
			if WorldSession.has_world() and not WorldSession.fresh:
				entries.append({"title": "Continue", "icon": "resume_run", "action": close})
			entries.append({"title": "New world", "icon": "new_run", "action": _on_new_world})
			entries.append({"title": "Settings", "icon": "settings", "action": _show.bind(View.SETTINGS)})
			_cards = CardUI.card_list(_page, entries)
			MenuNav.attach(_page, {first = _cards})
			_build_version_label()
		View.STARTER:
			_page = CardUI.card_page(self, {"title": "Choose your car"})
			var entries: Array = []
			for id in starter_choices():
				var car := CarLibrary.by_id(id)
				entries.append({"title": String(car.get("name", id)), "subtitle": CardUI.car_subtitle(car),
					"car": CarLibrary.index_of(id), "action": _start.bind(id)})
			_cards = CardUI.card_list(_page, entries)
			_page.add_action(UITheme.row_button("< Back", _show.bind(View.MAIN)))
			MenuNav.attach(_page, {first = _cards, on_back = _show.bind(View.MAIN)})
		View.SETTINGS:
			_page = MenuPage.new({"title": "Settings", "alpha": 0.0, "width": UITheme.px(560)})
			add_child(_page)
			_settings_menu = SettingsMenu.new()
			_settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_page.body().add_child(_settings_menu)
			var back := _page.add_action(UITheme.row_button("< Back", _settings_back))
			MenuNav.attach(_page, {first = back, on_back = _settings_back})
			_settings_menu.show_list.call_deferred()
		View.FIRST_RUN:
			_page = MenuPage.new({"title": "Welcome", "alpha": 0.0, "width": UITheme.px(560)})
			add_child(_page)
			_settings_menu = SettingsMenu.new()
			_settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_page.body().add_child(_settings_menu)
			_settings_menu.camera_changed.connect(_first_run_next.unbind(1))
			_settings_menu.scheme_changed.connect(_first_run_next.unbind(1))
			var next := _page.add_action(UITheme.row_button("Next >", _first_run_next))
			MenuNav.attach(_page, {first = next, on_back = _first_run_next})
			_settings_menu.show_camera.call_deferred()
	UITheme.enforce(_page)


# Passive build-version readout in the MAIN page's bottom-right corner (features/update-check.md),
# so a tester can read off which build they're on. Added to the page itself, outside the body and
# never focusable; hidden for an unstamped build (editor, local run).
func _build_version_label() -> void:
	var text := UpdateCheck.display_version(str(ProjectSettings.get_setting("application/config/version", "")))
	if text.is_empty():
		return
	var l := UITheme.label(text, "dim")
	l.name = "VersionLabel"
	l.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	l.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	l.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var m := Config.data.hub_version_label_margin_px
	l.position -= Vector2(m, m)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_page.add_child(l)


# The native builds' update check (features/update-check.md): one GET off the boot path, and a
# dismissible prompt on the title's MAIN page if a newer build has shipped. A silent no-op on web,
# headless and unstamped builds (UpdateCheck.applicable).
func _check_for_update() -> void:
	if not UpdateCheck.applicable():
		return
	var latest: int = await UpdateCheck.fetch_latest_build(Cloud.rest)
	if not is_inside_tree() or view != View.MAIN:
		return
	var current := UpdateCheck.current_build()
	var dismissed := int(Save.get_setting(UpdateCheck.DISMISSED_SETTING, 0))
	if UpdateCheck.should_prompt(current, latest, dismissed):
		show_update_prompt(current, latest)


func show_update_prompt(current: int, latest: int) -> void:
	var remember := func() -> void:
		Save.set_setting(UpdateCheck.DISMISSED_SETTING, latest)
	ConfirmPopup.open(self, "Update available", UpdateCheck.prompt_body(current, latest),
		[{"label": "Not now", "callback": remember},
		 {"label": UpdateCheck.store_label(), "callback": func() -> void:
			remember.call()
			OS.shell_open(UpdateCheck.store_url())}], 1)


func _settings_back() -> void:
	if _settings_menu != null and _settings_menu.go_back():
		return
	_show(View.MAIN)


func _first_run_next() -> void:
	if Platform.is_touch() and not _settings_menu.showing("schemes"):
		_settings_menu.show_schemes()
		return
	Save.set_setting(FIRST_RUN_DONE_KEY, true)
	if options_only:
		close.call()
		return
	_show(View.MAIN)


func _on_new_world() -> void:
	if not WorldSession.has_world() or WorldSession.fresh:
		_show(View.STARTER)
		return
	ConfirmPopup.open(self, "New world?", "Your current world, its cars and everything you've found are lost.",
		[{"label": "Cancel", "callback": Callable()}, {"label": "New world", "callback": _show.bind(View.STARTER)}],
		0, 0)


func _start(model_id: String) -> void:
	var was_fresh := WorldSession.fresh
	WorldSession.fresh = false
	if was_fresh and String(WorldSession.active_car()["model_id"]) == model_id:
		close.call()
		return
	WorldSession.new_world(WorldSession.world_seed() if was_fresh else Config.data.free_roam.pick_world_seed(), model_id)
	enter_world.call()


# Readout for tests and hosts: the current page's card list (null on SETTINGS).
func cards() -> CardCarousel:
	return _cards

class_name TitleScreen
extends Control
# Docs: features/world-session.md, features/menus.md — update in the same change as this file.
# Tests: tests/headless/test_title_screen.gd — extend in the same change (every menu change needs a keyboard+gamepad nav test).
# The title screen: the game's front door, shown over the live, paused world by its host scene.
# Card pages (CardUI.card_page / card_list) driven by MenuNav:
#   MAIN     — Continue (closes the menu; only with a world), New World (a fresh world, from the start car), Settings.
#   SETTINGS — the shared SettingsMenu.
# New World over an existing world asks first: the old world and its cars are lost.

enum View { MAIN, SETTINGS }

var view := View.MAIN
var _page: MenuPage
var _cards: CardCarousel
var _settings_menu: SettingsMenu
# Continue: the host hides the menu over the world it's already showing.
var close := func() -> void: pass
# A new world loads the scene afresh. A test swaps it for a capture.
var enter_world := func() -> void: Scenes.change_to(get_tree(), Scenes.WORLD)


func _ready() -> void:
	add_to_group(MusicLibrary.MENU_GROUP)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.4)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_show(View.MAIN)
	_check_for_update()


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
			if WorldSession.has_world():
				entries.append({"title": "Continue", "icon": "resume_run", "action": close})
			entries.append({"title": "New world", "icon": "new_run", "action": _on_new_world})
			entries.append({"title": "Settings", "icon": "settings", "action": _show.bind(View.SETTINGS)})
			_cards = CardUI.card_list(_page, entries)
			MenuNav.attach(_page, {first = _cards})
			_build_version_label()
		View.SETTINGS:
			_page = MenuPage.new({"title": "Settings", "alpha": 0.0, "width": UITheme.px(560)})
			add_child(_page)
			_settings_menu = SettingsMenu.new()
			_settings_menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_page.body().add_child(_settings_menu)
			var back := _page.add_action(UITheme.row_button("< Back", _settings_back))
			MenuNav.attach(_page, {first = back, on_back = _settings_back})
			_settings_menu.show_list.call_deferred()
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


func _on_new_world() -> void:
	if not WorldSession.has_world():
		_start()
		return
	ConfirmPopup.open(self, "New world?", "Your current world, its cars and everything you've found are lost.",
		[{"label": "Cancel", "callback": Callable()}, {"label": "New world", "callback": _start}],
		0, 0)


func _start() -> void:
	new_world()
	enter_world.call()


# Replaces the saved world with a fresh one in the level's start car (title_boot.gd for a first-time player too).
static func new_world() -> void:
	WorldSession.new_world(randi(), Config.authored_value("level_car_id", Config.data.level_car_id))


# Readout for tests and hosts: the current page's card list (null on SETTINGS).
func cards() -> CardCarousel:
	return _cards

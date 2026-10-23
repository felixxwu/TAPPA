class_name CheckpointBanner
extends CanvasLayer
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd — extend in the same change.
# Lighting a checkpoint for the first time: a Dark Souls style "Checkpoint reached" band across the
# screen while the car drives on, then a card page of what is still to be found in its biome.

signal closed

const FADE_S := 0.6
const HOLD_S := 3.0

@export var rest_stops: RestStops
@export var loot: LootDirector
@export var pause_menu: PauseMenu

var _band: Control
var _page: MenuPage
var _cards: CardCarousel
var _pending_site := -1


func _init() -> void:
	layer = 7
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	if rest_stops != null:
		rest_stops.lit.connect(show_reached)


func is_showing_banner() -> bool:
	return _band != null


func is_open() -> bool:
	return _page != null


func show_reached(site: int) -> void:
	if _band != null:
		_band.queue_free()
	_band = build_band("Checkpoint reached")
	add_child(_band)
	_band.modulate.a = 0.0
	var tween := _band.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_band, "modulate:a", 1.0, FADE_S)
	tween.tween_interval(HOLD_S)
	tween.tween_property(_band, "modulate:a", 0.0, FADE_S)
	tween.tween_callback(_banner_done.bind(site))


# The band across the middle of the screen, `text` in big gold capitals. RegionBanner wears it too.
static func build_band(text: String) -> Control:
	var band := ColorRect.new()
	band.name = "Band"
	band.color = UITheme.PANEL_DIM
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.set_anchors_preset(Control.PRESET_HCENTER_WIDE)
	var h := UITheme.px(110)
	band.offset_top = -h / 2.0
	band.offset_bottom = h / 2.0
	var label := UITheme.title(UITheme.caps(text))
	label.add_theme_font_size_override("font_size", UITheme.FONT_SIZE * 4)
	label.add_theme_color_override("font_color", UITheme.GOLD)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_preset(Control.PRESET_FULL_RECT)
	band.add_child(label)
	return band


func _banner_done(site: int) -> void:
	if _band != null:
		_band.queue_free()
		_band = null
	_pending_site = site


# The item page waits for whatever else has frozen the game (the checkpoint page, a wreck) to close.
func _process(_delta: float) -> void:
	if _pending_site >= 0 and not get_tree().paused:
		var site := _pending_site
		_pending_site = -1
		open_items(site)


# What is still to be found in the biome of checkpoint `site`, best first.
func items_for(site: int) -> Array:
	if rest_stops == null or loot == null:
		return []
	var settings := rest_stops.streamer.settings
	var ring := clampi(rest_stops.streamer.sites.ring[site], 0, settings.ring_count - 1)
	var items: Array = []
	for item: Dictionary in LootRules.remaining(LootRules.ring_tables(settings.ring_count)[ring], loot.taken_keys()):
		if String(item["kind"]) != "rumour":
			items.append(item)
	return items


func open_items(site: int) -> void:
	var items := items_for(site)
	if items.is_empty():
		return
	get_tree().paused = true
	if pause_menu != null:
		pause_menu.set_input_enabled(false)
	var entries: Array = [{"title": "Continue", "icon": "resume_run", "action": close}]
	for item: Dictionary in items:
		var text := LootRules.card_text(item)
		entries.append({"title": text[0], "subtitle": text[1], "icon": LootRules.icon(item), "action": close})
	_page = CardUI.card_page(self, {"title": "Now in reach", "dim": true})
	_cards = CardUI.card_list(_page, entries, [rest_stops.name_of(site), "Out here to be found:"])
	MenuNav.attach(_page, {first = _cards, on_back = close})
	UITheme.enforce(_page)


func close() -> void:
	if _page == null:
		return
	CardUI.park_previews(_page)
	_page.queue_free()
	_page = null
	_cards = null
	get_tree().paused = false
	if pause_menu != null:
		pause_menu.set_input_enabled(true)
	closed.emit()


func cards() -> CardCarousel:
	return _cards

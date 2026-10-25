class_name CheckpointBanner
extends CanvasLayer
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd — extend in the same change.
# Lighting a checkpoint for the first time: a Dark Souls style "Checkpoint reached" band across the
# screen while the car drives on. Its biome's cars and parts go on sale at every checkpoint.

const FADE_S := 0.6
const HOLD_S := 3.0

@export var rest_stops: RestStops
@export var loot: LootDirector

var _band: Control


func _init() -> void:
	layer = 7
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	if rest_stops != null:
		rest_stops.lit.connect(show_reached)


func is_showing_banner() -> bool:
	return _band != null


func show_reached(site: int) -> void:
	_reveal_ring(site)
	if _band != null:
		_band.queue_free()
	_band = build_band("Checkpoint reached")
	add_child(_band)
	_band.modulate.a = 0.0
	var tween := _band.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_band, "modulate:a", 1.0, FADE_S)
	tween.tween_interval(HOLD_S)
	tween.tween_property(_band, "modulate:a", 0.0, FADE_S)
	tween.tween_callback(_banner_done)


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


func _banner_done() -> void:
	if _band != null:
		_band.queue_free()
		_band = null


# Lighting a checkpoint puts its biome ring's stock on sale.
func _reveal_ring(site: int) -> void:
	if rest_stops == null or loot == null:
		return
	var ring := clampi(rest_stops.streamer.sites.ring[site], 0, rest_stops.streamer.settings.ring_count - 1)
	loot.unlock(ring)

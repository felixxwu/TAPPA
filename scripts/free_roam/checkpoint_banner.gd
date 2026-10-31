class_name CheckpointBanner
extends CanvasLayer
# Docs: features/free-roam.md — update in the same change as this file.
# Tests: tests/headless/test_free_roam_rest_stops.gd — extend in the same change.
# Lighting a checkpoint for the first time: a Dark Souls style "Checkpoint reached" band across the
# screen, with a small line under it saying the car heals while it stays (RestStops._heal), while
# the car drives on.

const SUBTITLE := "Your car is being repaired"

@export var rest_stops: RestStops

var _band: Control


func _init() -> void:
	layer = 7
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	if rest_stops != null:
		rest_stops.lit.connect(show_reached)


func is_showing_banner() -> bool:
	return _band != null


func show_reached(_site: int) -> void:
	if _band != null:
		_band.queue_free()
	_band = build_band("Checkpoint reached", SUBTITLE)
	add_child(_band)
	_band.modulate.a = 0.0
	var fade := Config.data.free_roam.banner_fade_s
	var tween := _band.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_band, "modulate:a", 1.0, fade)
	tween.tween_interval(Config.data.free_roam.banner_hold_s)
	tween.tween_property(_band, "modulate:a", 0.0, fade)
	tween.tween_callback(_banner_done)


# The band across the middle of the screen, `text` in big gold capitals, and `subtitle` (if any)
# under it at the house font size. RegionBanner wears it too.
static func build_band(text: String, subtitle: String = "") -> Control:
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
	if subtitle.is_empty():
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		band.add_child(label)
		return band
	var stack := VBoxContainer.new()
	stack.name = "Stack"
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 0)
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.add_child(label)
	var sub := UITheme.label(subtitle)
	sub.name = "Subtitle"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(sub)
	band.add_child(stack)
	return band


func _banner_done() -> void:
	if _band != null:
		_band.queue_free()
		_band = null

class_name LevelBanner
extends CanvasLayer
# Docs: features/level-editor.md — update in the same change as this file.
# Tests: tests/headless/test_level_view.gd — extend in the same change.
# A Dark Souls style band across the screen ("Delivery complete"), held for a few seconds while the car drives on.

const FADE_S := 0.6
const HOLD_S := 3.0

var _band: Control


func _init() -> void:
	layer = 7
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_showing_banner() -> bool:
	return _band != null


func show_band(text: String, subtitle: String) -> void:
	if _band != null:
		_band.queue_free()
	_band = _build_band(text, subtitle)
	add_child(_band)
	_band.modulate.a = 0.0
	var tween := _band.create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_band, "modulate:a", 1.0, FADE_S)
	tween.tween_interval(HOLD_S)
	tween.tween_property(_band, "modulate:a", 0.0, FADE_S)
	tween.tween_callback(_banner_done)


# `text` in big gold capitals, and `subtitle` (if any) under it at the house font size.
static func _build_band(text: String, subtitle: String = "") -> Control:
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

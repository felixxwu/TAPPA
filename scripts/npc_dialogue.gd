class_name NpcDialogue
extends CanvasLayer
# Docs: features/npc-dialogue.md — update in the same change as this file.
# Tests: tests/headless/test_npc_dialogue.gd — extend in the same change.
# A character talking: their portrait leans out over a black box at the bottom of the screen and each page of
# their lines types out letter by letter. Confirm (or a click/tap) shows the rest of the page, then the next page;
# after the last page it closes and emits `finished`. It swallows all input while open, so the menu under it waits.

signal finished()

const PORTRAIT_PX := 288
const PORTRAIT_TUCK := 0.2  # the share of the portrait hidden behind the box, cutting the figure at the chest

var pages: Array = []
var _portrait := ""
var page := 0
var shown := 0.0
var text: Label
var more: Label


static func open(parent: Node, portrait: String, lines: Array) -> NpcDialogue:
	var d := NpcDialogue.new()
	d.pages = lines
	d._portrait = portrait
	parent.add_child(d)
	return d


func _ready() -> void:
	layer = 100  # over menus and the money read-out, under modals (101)
	process_mode = Node.PROCESS_MODE_ALWAYS  # menus pause the tree
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.theme = UITheme.theme()
	add_child(root)
	var box_h := UITheme.TITLE_FONT_SIZE * 3 + UITheme.PANEL_PAD * 2
	var pic := TextureRect.new()
	pic.texture = load(_portrait)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	pic.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	pic.offset_left = UITheme.MARGIN + UITheme.PANEL_PAD
	pic.offset_right = pic.offset_left + PORTRAIT_PX
	pic.offset_bottom = -UITheme.MARGIN - box_h + int(PORTRAIT_PX * PORTRAIT_TUCK)
	pic.offset_top = pic.offset_bottom - PORTRAIT_PX
	root.add_child(pic)
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UITheme.panel_box(1.0))
	box.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	box.offset_left = UITheme.MARGIN
	box.offset_right = -UITheme.MARGIN
	box.offset_top = -UITheme.MARGIN - box_h
	box.offset_bottom = -UITheme.MARGIN
	root.add_child(box)
	text = UITheme.label("")
	text.add_theme_font_size_override("font_size", UITheme.TITLE_FONT_SIZE)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	box.add_child(text)
	more = UITheme.label(">", "dim")
	more.add_theme_font_size_override("font_size", UITheme.TITLE_FONT_SIZE)
	more.size_flags_horizontal = Control.SIZE_SHRINK_END
	more.size_flags_vertical = Control.SIZE_SHRINK_END
	box.add_child(more)
	_show_page()


func _show_page() -> void:
	text.text = String(pages[page])
	shown = 0.0
	text.visible_characters = 0
	more.visible = false


func typing() -> bool:
	return text.visible_characters >= 0 and text.visible_characters < text.get_total_character_count()


func _process(dt: float) -> void:
	if not typing():
		return
	shown += dt * Config.data.npc_text_chars_per_s
	text.visible_characters = int(shown)
	if not typing():
		text.visible_characters = -1
		more.visible = true


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventScreenDrag or event is InputEventJoypadMotion:
		return
	get_viewport().set_input_as_handled()
	var go: bool = event.is_action_pressed("menu_select") or event.is_action_pressed("ui_accept") or event.is_action_pressed("menu_back") \
		or (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT) \
		or (event is InputEventScreenTouch and event.pressed)
	if not go or event.is_echo():
		return
	advance()


# Finish typing the page, else turn to the next one, else close.
func advance() -> void:
	if typing():
		text.visible_characters = -1
		more.visible = true
	elif page + 1 < pages.size():
		page += 1
		_show_page()
	else:
		finished.emit()
		queue_free()

class_name TextField
extends VBoxContainer
# A labelled text input, built in code like the rest of the menu widgets.
#
# This is the project's FIRST text input, so it carries the wiring that makes
# typing coexist with a menu system driven by bare letter keys:
#
#   * WASD is safe by construction — a focused LineEdit consumes printable keys
#     in the GUI phase, before MenuNav's _unhandled_input ever sees them.
#   * Up/down must LEAVE the field (focus_neighbor_top/bottom, set by
#     wire_column below) while left/right stay caret movement, which is what a
#     player expects from both a keyboard and a stick.
#   * Esc/B while typing is handled centrally by MenuNav.is_text_editing().
#   * Enter submits rather than inserting a newline (LineEdit is single-line, so
#     this is just the `text_submitted` signal).
#
# Note SPACE: ui_accept binds Space, and Space is a legal password character.
# The focused LineEdit consumes it first, so typing wins over "press the focused
# button" — the behaviour is correct, but it is the thing to re-check by hand if
# the input map ever changes.

signal submitted()

var line: LineEdit
var _label: Label


func _init(label_text: String, placeholder := "", secret := false) -> void:
	add_theme_constant_override("separation", UITheme.GAP_TIGHT)

	_label = UITheme.label(label_text, "dim")
	_label.add_theme_font_size_override("font_size", UITheme.px(14))
	add_child(_label)

	line = LineEdit.new()
	line.placeholder_text = placeholder
	line.secret = secret
	line.focus_mode = Control.FOCUS_ALL
	line.custom_minimum_size = Vector2(UITheme.px(320), UITheme.MENU_ROW_H)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Bring up the on-screen keyboard on phones and in mobile browsers, where
	# there is no hardware keyboard to fall back on.
	line.virtual_keyboard_enabled = true
	line.caret_blink = true
	line.text_submitted.connect(func(_t: String) -> void: submitted.emit())
	add_child(line)


func text() -> String:
	return line.text.strip_edges()


func set_text(value: String) -> void:
	line.text = value


func clear() -> void:
	line.text = ""


func set_editable(value: bool) -> void:
	line.editable = value


# Toggle a password field between hidden and visible.
func set_secret(value: bool) -> void:
	line.secret = value


# Chain a column of focusable controls top-to-bottom so up/down walk them.
#
# Buttons get this for free from Godot's automatic neighbour search, but a
# LineEdit swallows left/right for the caret, and the automatic search can pick
# a surprising target once a row is mixed. Wiring the column explicitly makes
# the order the same one the player sees.
#
# Being passed here IS the declaration that a control belongs in the focus
# column, so FOCUS_NONE controls (e.g. fresh UITheme.row_button results, which
# defer focusability to MenuNav) are promoted to FOCUS_ALL rather than dropped —
# only the `menu_nav_skip` meta opts a control out, same as MenuNav._enable.
static func wire_column(controls: Array) -> void:
	var focusables: Array[Control] = []
	for c in controls:
		if c is TextField:
			focusables.append((c as TextField).line)
		elif c is Control and not (c as Control).has_meta("menu_nav_skip"):
			var ctrl := c as Control
			if ctrl.focus_mode == Control.FOCUS_NONE:
				ctrl.focus_mode = Control.FOCUS_ALL
			focusables.append(ctrl)
	for i in focusables.size():
		var above := focusables[maxi(i - 1, 0)]
		var below := focusables[mini(i + 1, focusables.size() - 1)]
		focusables[i].focus_neighbor_top = above.get_path()
		focusables[i].focus_previous = above.get_path()
		focusables[i].focus_neighbor_bottom = below.get_path()
		focusables[i].focus_next = below.get_path()

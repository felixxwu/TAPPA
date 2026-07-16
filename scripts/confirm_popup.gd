# scripts/confirm_popup.gd
class_name ConfirmPopup
extends CanvasLayer
# Reusable on-brand confirm modal: dim mouse-consuming backdrop + centred house
# panel with a title, an autowrap body, and one button per action. Each action is
# { "label": String, "callback": Callable, "disabled": bool (optional) }. Pressing
# an action closes the popup then runs its callback; Back routes to back_index
# (default last = the dismiss convention). MenuNav-wired (keyboard + gamepad).
# Named ConfirmPopup, NOT Popup — Godot has a native Popup class.

signal finished()

var _actions: Array = []
var _back_index: int = -1
var _buttons: Array[Button] = []

# host: parent to attach under (its process mode is inherited — a paused host's
# popup still processes). Returns the live popup (owns its own CanvasLayer).
static func open(host: Node, title: String, body: String, actions: Array,
		default_index := 0, back_index := -1) -> ConfirmPopup:
	var popup := ConfirmPopup.new()
	popup._actions = actions
	popup._back_index = back_index if back_index >= 0 else actions.size() - 1
	host.add_child(popup)
	popup._build(title, body, default_index)
	return popup

func _build(title: String, body: String, default_index: int) -> void:
	layer = 101  # above overlays

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.0, 0.0, 0.0, 0.96)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow taps so nothing falls through
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := UITheme.panel(1.0, 20)
	center.add_child(panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", UITheme.GAP)
	vbox.custom_minimum_size = Vector2(420, 0)
	panel.add_child(vbox)

	vbox.add_child(UITheme.title(title))
	var body_label := Label.new()
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_label.text = body
	vbox.add_child(body_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	vbox.add_child(row)
	_buttons = []
	for i in _actions.size():
		var a: Dictionary = _actions[i]
		var b := Button.new()
		b.text = String(a.get("label", ""))
		b.focus_mode = Control.FOCUS_ALL
		b.disabled = bool(a.get("disabled", false))
		b.pressed.connect(_on_action.bind(i))
		row.add_child(b)
		_buttons.append(b)

	UITheme.enforce(self)
	# first may be null when every action is disabled — MenuNav simply seats no
	# cursor, which is the intended behaviour (nothing to focus).
	var first := _pick_first(default_index)
	MenuNav.attach(center, {"first": first, "on_back": trigger_back})

func _pick_first(default_index: int) -> Control:
	if default_index >= 0 and default_index < _buttons.size() \
			and not _buttons[default_index].disabled:
		return _buttons[default_index]
	for b in _buttons:
		if not b.disabled:
			return b
	return null

func _on_action(index: int) -> void:
	var cb: Callable = _actions[index].get("callback", Callable())
	_dismiss()
	if cb.is_valid():
		cb.call()

# Route Back / cancel to the configured action (default: the last one).
func trigger_back() -> void:
	if _back_index >= 0 and _back_index < _actions.size():
		_on_action(_back_index)
	else:
		_dismiss()

func _dismiss() -> void:
	finished.emit()
	queue_free()

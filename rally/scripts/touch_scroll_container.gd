class_name TouchScrollContainer
extends ScrollContainer
# A ScrollContainer that drag-scrolls under touch/mouse even when the gesture
# STARTS on an interactive child (a list-item Button). Godot's built-in touch
# scroll only fires from the container's own `_gui_input`, which a pressed child
# Button swallows — so on a phone a finger that lands on a row can't scroll the
# list at all. This watches raw input in `_input` (which runs BEFORE the GUI pass,
# so it sees the press the button would otherwise eat): a press arms a gesture,
# vertical motion past a small deadzone becomes a scroll, and a press that never
# moves passes straight through as a normal tap/click on the child. Only the
# release that ENDED a real drag is swallowed, so the row under the finger doesn't
# also fire its action.
#
# Scrolling is driven from MOUSE events — on this project a finger arrives as a
# mouse event via `pointing/emulate_mouse_from_touch` (the same path the HQ
# map-table pan uses). The raw touch events are swallowed inside our rect so the
# built-in touch-scroll doesn't ALSO run and double the movement.

# Pixels of vertical travel before a press is treated as a scroll (not a tap).
const DRAG_DEADZONE := 10.0

var _pressing := false
var _dragging := false
var _press_pos := Vector2.ZERO
var _press_scroll := 0
var _press_button: BaseButton = null


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		# We scroll from the emulated mouse events below; swallow the raw touch
		# inside our rect so the built-in ScrollContainer touch-scroll doesn't ALSO
		# run and double the movement.
		if _has_overflow() and get_global_rect().has_point(event.position):
			get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_begin(event.position)
		else:
			_end()
	elif event is InputEventMouseMotion and _pressing:
		_update(event.position)


# Arm a gesture only when the press lands inside us AND there is something to
# scroll; otherwise stay out of the way so taps/hover behave exactly as before.
func _try_begin(pos: Vector2) -> void:
	if not _has_overflow() or not get_global_rect().has_point(pos):
		_pressing = false
		return
	_pressing = true
	_dragging = false
	_press_pos = pos
	_press_scroll = scroll_vertical
	_press_button = _button_at(self, pos)


func _update(pos: Vector2) -> void:
	var dy := pos.y - _press_pos.y
	if not _dragging and absf(dy) > DRAG_DEADZONE:
		_dragging = true
	if _dragging:
		scroll_vertical = int(_press_scroll - dy)


func _end() -> void:
	if _dragging:
		# The press became a scroll — eat the release so the row under the finger
		# doesn't fire its click, and clear the child's lingering pressed look.
		get_viewport().set_input_as_handled()
		if _press_button != null and not _press_button.disabled:
			_press_button.disabled = true
			_press_button.disabled = false
	_pressing = false
	_dragging = false
	_press_button = null


func _has_overflow() -> bool:
	var bar := get_v_scroll_bar()
	return bar != null and (bar.max_value - bar.page) > 1.0


# The deepest visible BaseButton whose global rect contains `pos` (the row the
# press landed on), so a drag that ended on it can clear its stuck pressed look.
static func _button_at(node: Node, pos: Vector2) -> BaseButton:
	for i in range(node.get_child_count() - 1, -1, -1):
		var child := node.get_child(i)
		if child is CanvasItem and not (child as CanvasItem).visible:
			continue
		var found := _button_at(child, pos)
		if found != null:
			return found
	if node is BaseButton and (node as Control).get_global_rect().has_point(pos):
		return node as BaseButton
	return null

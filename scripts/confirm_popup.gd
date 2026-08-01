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

# ONE MODAL AT A TIME, TREE-WIDE. Every modal in the game is either a ConfirmPopup
# or a UsernamePopup (which joins this same group), and they all sit on layer 101 —
# so two of them on screen at once is never a design, always a bug: the top one
# hides the other, dismissing it "does nothing" except reveal a twin with the focus
# cursor reset.
#
# WHY A GROUP RATHER THAN A FLAG ON THE RAISER. The bug this exists to kill was a
# single Cloud.conflict_detected broadcast reaching two subscribers, each of which
# checked its OWN private "is my prompt up?" bool. Neither latch could see the
# other, so both opened. The question "is a modal already on screen?" has exactly
# one true answer and it belongs to the scene tree, not to any one host — a helper
# that centralises WHAT a modal does while leaving each caller to track WHETHER one
# is up has only half-consolidated the rule. See features/menus.md → "One modal at
# a time" and todo/challenge-career-reuse-drift.md item 10.
const MODAL_GROUP := "modal"

var _actions: Array = []
var _back_index: int = -1
var _buttons: Array[Button] = []


# The modal currently on screen anywhere in `tree`, or null when there is none.
#
# SKIPS NODES BEING FREED. ConfirmPopup._dismiss emits `finished` and THEN
# queue_free()s, and a freed node stays in its groups until the end of the frame —
# so a host that re-checks from its own `finished` handler (account_menu.rebuild
# does exactly this) would otherwise be told a modal is still up by the very popup
# that just closed, and be silently refused.
static func any_open(tree: SceneTree) -> Node:
	if tree == null:
		return null
	for n in tree.get_nodes_in_group(MODAL_GROUP):
		var node := n as Node
		if is_instance_valid(node) and not node.is_queued_for_deletion():
			return node
	return null


# host: parent to attach under (its process mode is inherited — a paused host's
# popup still processes). Returns the live popup, or NULL when one is refused —
# callers must not assume a popup came back.
#
# `allow_stack` opts out of the exclusivity rule for the rare modal that must be
# seen even over another one (CloudBusy's failure notice: dropping it silently is
# how a failed sync becomes invisible). Refusals are pushed as warnings rather than
# swallowed — a modal that never appeared is a bug worth hearing about, and there
# is deliberately NO queue: re-showing a modal the player has moved past invents an
# ordering nobody asked for.
static func open(host: Node, title: String, body: String, actions: Array,
		default_index := 0, back_index := -1, allow_stack := false) -> ConfirmPopup:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return null
	if not allow_stack:
		var live := any_open(host.get_tree())
		if live != null:
			push_warning("ConfirmPopup '%s' refused: '%s' is already on screen." % [
				title, live.get_meta("modal_title", "another modal")])
			return null
	var popup := ConfirmPopup.new()
	popup._actions = actions
	popup._back_index = back_index if back_index >= 0 else actions.size() - 1
	host.add_child(popup)
	popup._build(title, body, default_index)
	return popup

func _build(title: String, body: String, default_index: int) -> void:
	layer = 101  # above overlays
	add_to_group(MODAL_GROUP)  # see MODAL_GROUP — one modal at a time, tree-wide
	set_meta("modal_title", title)  # named in the refusal warning above

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = UITheme.MODAL_DIM
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

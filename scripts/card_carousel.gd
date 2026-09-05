class_name CardCarousel
extends Control
# Docs: features/card-carousel.md — update in the same change as this file.
# Tests: tests/headless/test_card_carousel.gd — extend in the same change.
#
# A HORIZONTAL, SIDE-SCROLLING CARD CAROUSEL — the shared replacement for a vertical
# MenuPage row list. Cards sit side by side, the selected one centred and opaque, the
# rest dimmed (Config.data.card_carousel_unselected_alpha). Each card has a VISUAL slot
# (top half — a SubViewport, icon, or plain ColorRect; the caller populates it) and an
# INFO slot (bottom half — a VBoxContainer the caller fills with labels/price/state).
#
# Input:
#   - Keyboard/gamepad: this Control is ONE focusable unit. Left/right (menu_left/
#     menu_right, and native ui_left/ui_right since MenuNav.attach makes it FOCUS_ALL)
#     move the selection by one card; ui_accept/menu_select confirms. See
#     `menu_nav_handles_side` below — that is the seam MenuNav calls into, the same
#     shape it already special-cases Range/sliders through.
#   - Mouse/touch: tapping a non-centred card selects it (moves toward centre by
#     whatever number of steps separate it from centre); tapping the ALREADY-centred
#     card confirms. Dragging pans the strip; releasing snaps to the nearest card.
#
# Signals: selection_changed(index), confirmed(index).
#
# Usage:
#   var carousel := CardCarousel.new()
#   page.body().add_child(carousel)
#   for item in items:
#       var card := carousel.add_card(item.disabled)
#       card.visual.add_child(my_icon_or_viewport)
#       card.info.add_child(UITheme.label(item.name))
#   carousel.confirmed.connect(func(i): ...)
#   MenuNav.attach(page, {"first": carousel})   # carousel is itself the focusable widget

signal selection_changed(index: int)
signal confirmed(index: int)

class Card:
	var root: PanelContainer
	var visual: Control
	var info: VBoxContainer
	var disabled := false

var _cards: Array[Card] = []
var _selected := 0
var _strip: Control
# Scroll offset in pixels, 0 == card 0 centred. Positive moves the strip so later
# cards come into view from the right.
var _offset := 0.0
var _tween: Tween
var _drag_active := false
var _drag_start_x := 0.0
var _drag_start_offset := 0.0

const _GAP := 24.0


func _init() -> void:
	# A REAL minimum width, not just height. Cards are absolute-positioned children of a
	# plain (non-Container) `_strip`, so they never contribute to anyone's minimum size —
	# and MenuPage's body box hugs its content's minimum width (menu_page.gd), so without
	# this the box shrinks to whatever its narrowest sibling label needs and clips the
	# carousel down to a sliver, which reads as "scrolling a list inside one card" rather
	# than cards sitting side by side. Claiming enough width for the selected card plus a
	# peek of its neighbours is what makes it read as a card LIST.
	custom_minimum_size = Vector2(
		Config.data.card_carousel_card_width * Config.data.card_carousel_visible_width_factor,
		_card_height() + 8.0)
	clip_contents = true
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	_strip = Control.new()
	_strip.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_strip)


func _card_width() -> float:
	return Config.data.card_carousel_card_width


func _card_height() -> float:
	return _card_width() * Config.data.card_carousel_aspect


# Add a new card and return its Card handle so the caller can populate visual/info.
# `disabled` cards are shown (dimmed, per the project's "locked rows stay visible"
# convention) but skip both selection landing and confirm.
func add_card(disabled: bool = false) -> Card:
	var card := Card.new()
	card.disabled = disabled
	card.root = PanelContainer.new()
	card.root.custom_minimum_size = Vector2(_card_width(), _card_height())
	card.root.add_theme_stylebox_override("panel", UITheme.panel_box(1.0))
	card.root.mouse_filter = Control.MOUSE_FILTER_PASS

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	card.root.add_child(col)

	card.visual = Control.new()
	card.visual.custom_minimum_size = Vector2(0, _card_height() * 0.5)
	card.visual.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.visual.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_child(card.visual)

	card.info = VBoxContainer.new()
	card.info.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.info.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_child(card.info)

	_strip.add_child(card.root)
	var index := _cards.size()
	card.root.gui_input.connect(_on_card_gui_input.bind(index))
	_cards.append(card)
	_layout()
	return card


func card_count() -> int:
	return _cards.size()


func selected_index() -> int:
	return _selected


# Move the selection to `index` (clamped), skipping over nothing — a caller that wants
# to skip disabled cards on entry should pick a valid `first` itself; the carousel does
# not auto-skip on directional nav, matching how a disabled MenuPage row is merely
# unfocusable rather than invisible to the cursor.
func select(index: int, animate: bool = true) -> void:
	if _cards.is_empty():
		return
	index = clampi(index, 0, _cards.size() - 1)
	var changed := index != _selected
	_selected = index
	_snap_to(_selected, animate)
	if changed:
		selection_changed.emit(_selected)


func _target_offset_for(index: int) -> float:
	return index * (_card_width() + _GAP)


func _snap_to(index: int, animate: bool) -> void:
	var target := _target_offset_for(index)
	if _tween != null and _tween.is_valid():
		_tween.kill()
	if animate:
		_tween = create_tween()
		_tween.tween_property(self, "_offset", target, Config.data.card_carousel_snap_duration_s) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_tween.tween_callback(_layout)
		_tween.step_finished.connect(func(_i): _layout())
	else:
		_offset = target
		_layout()


func _layout() -> void:
	if not is_inside_tree():
		return
	var centre_x := size.x * 0.5
	for i in _cards.size():
		var card := _cards[i]
		var x := centre_x - _card_width() * 0.5 + i * (_card_width() + _GAP) - _offset
		card.root.position = Vector2(x, (size.y - _card_height()) * 0.5)
		card.root.modulate.a = 1.0 if i == _selected \
			else Config.data.card_carousel_unselected_alpha


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_layout()


# --- Keyboard / gamepad: the MenuNav seam ------------------------------------
#
# MenuNav._unhandled_input, on a focused control, checks `has_method("menu_nav_handles_side")`
# BEFORE its own slider special-case and its default focus-neighbour search (see
# menu_nav.gd) — the same "this widget owns its own left/right" seam a Range already
# uses, generalised so a second widget type didn't need bespoke handling wired into the
# framework itself. Returning false for up/down lets focus leave the carousel normally.
func menu_nav_handles_side(side: int) -> bool:
	if side == SIDE_LEFT:
		select(_selected - 1)
		return true
	if side == SIDE_RIGHT:
		select(_selected + 1)
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	# ui_accept is caught in _gui_input (it reaches the focused control there first);
	# this only covers menu_select, which — like menu_left/right — is a custom action
	# with no native GUI-phase consumer.
	if not has_focus() or not is_visible_in_tree():
		return
	if MenuNav.input_blocked(self):
		return
	if event.is_action_pressed("menu_select"):
		_confirm_selected()
		get_viewport().set_input_as_handled()


func _confirm_selected() -> void:
	if _selected < 0 or _selected >= _cards.size():
		return
	if _cards[_selected].disabled:
		return
	confirmed.emit(_selected)


# --- Mouse / touch ------------------------------------------------------------

func _on_card_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag_active = true
				_drag_start_x = mb.global_position.x
				_drag_start_offset = _offset
			else:
				var dragged := absf(mb.global_position.x - _drag_start_x) > 4.0
				_drag_active = false
				if not dragged:
					_tap_card(index)
	elif event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_drag_active = true
			_drag_start_x = t.position.x
			_drag_start_offset = _offset
		else:
			var dragged2 := absf(t.position.x - _drag_start_x) > 4.0
			_drag_active = false
			if not dragged2:
				_tap_card(index)


func _tap_card(index: int) -> void:
	grab_focus()
	if index == _selected:
		_confirm_selected()
	else:
		select(index)


func _gui_input(event: InputEvent) -> void:
	# Native ui_left/ui_right would otherwise move focus to the next sibling widget
	# (Godot's built-in focus-neighbour search runs AFTER gui_input if unhandled) —
	# intercept here so arrow keys / D-pad / left stick move the SELECTED CARD instead,
	# matching menu_left/menu_right (caught by MenuNav via menu_nav_handles_side).
	if event.is_action_pressed("ui_left"):
		select(_selected - 1)
		accept_event()
		return
	if event.is_action_pressed("ui_right"):
		select(_selected + 1)
		accept_event()
		return
	if event.is_action_pressed("ui_accept"):
		_confirm_selected()
		accept_event()
		return
	if event is InputEventMouseMotion and _drag_active:
		var mm := event as InputEventMouseMotion
		_offset = _drag_start_offset - (mm.global_position.x - _drag_start_x)
		_layout()
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		_offset = _drag_start_offset - (d.position.x - _drag_start_x)
		_layout()


func end_drag_and_snap() -> void:
	if _cards.is_empty():
		return
	# A drag has to cross card_carousel_drag_step_fraction of a card's width, from the
	# CURRENTLY selected card, before it counts as a step — a short drag (a flick that
	# barely moved) snaps back to where it started instead of jumping to whatever card
	# is nearest by raw distance, which would make a small accidental drag re-pick.
	var step := _card_width() + _GAP
	var from_selected := (_offset - _target_offset_for(_selected)) / step
	var threshold: float = Config.data.card_carousel_drag_step_fraction
	var moved := 0
	if from_selected > threshold:
		moved = ceili(from_selected)
	elif from_selected < -threshold:
		moved = floori(from_selected)
	select(clampi(_selected + moved, 0, _cards.size() - 1), true)


func _input(event: InputEvent) -> void:
	if not _drag_active:
		return
	var released := (event is InputEventMouseButton and not (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and not (event as InputEventScreenTouch).pressed)
	if released:
		end_drag_and_snap()

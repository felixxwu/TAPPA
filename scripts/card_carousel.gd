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
var _visible_count := 1


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


# Widen the carousel's minimum width to use `avail_width` — called by a host that wants
# the carousel to run edge to edge instead of the default peek-a-couple-neighbours width
# from _init(). Rounds DOWN to a whole, ODD number of visible cards (so the selected card
# sits exactly centred with an equal number of whole cards either side) rather than
# whatever fraction happens to fit avail_width — a fractional card at the strip's clipped
# edge is a card sliced in half, which is exactly the "don't clip" case this exists to
# avoid. Falls back to one bare card's width if avail_width can't fit even that.
func fit_to_available_width(avail_width: float) -> void:
	var unit := _card_width() + Config.data.card_carousel_gap
	var count := int(floor((avail_width + Config.data.card_carousel_gap) / unit))
	count = maxi(count, 1)
	if count % 2 == 0:
		count -= 1
	count = maxi(count, 1)
	_visible_count = count
	custom_minimum_size.x = count * _card_width() + (count - 1) * Config.data.card_carousel_gap
	_layout()


# How many cards fit_to_available_width decided can be on screen at once (always odd —
# see fit_to_available_width). A host with an expensive per-card visual (a live 3D
# preview, say) can use this to only keep that many live around the current selection
# instead of building one for every card up front — see CarCardPreview's caller in
# hub_shell.gd for why that matters. 1 before fit_to_available_width has ever run.
func visible_card_count() -> int:
	return _visible_count


func _card_width() -> float:
	return Config.data.card_carousel_card_width


func _card_height() -> float:
	return _card_width() * Config.data.card_carousel_aspect


# A card's own panel is solid black (like every other panel in the theme — UITheme's
# "pure black, no border" rule), sitting on the ALSO-solid-black MenuPage body box behind
# it. Without a border a card's edges are optically identical to both the gap beside it
# AND the body box behind it, so modulate.a dimming (which just makes black-on-black more
# transparent, i.e. no visible change at all) was the ONLY selection cue and the whole
# strip read as one fused black slab with a few floating coloured icons — not a row of
# cards. A border is the fix: reward_card_box() already sets this precedent (a black card
# that must visibly pop against another black panel gets an accent border), generalised
# here to every unselected card too so the CARD SHAPE itself is always visible, not just
# the selected one.
func _card_stylebox(selected: bool) -> StyleBoxFlat:
	var box := UITheme.panel_box(1.0)
	for side in ["left", "top", "right", "bottom"]:
		box.set("border_width_" + side, 3 if selected else 1)
	box.border_color = UITheme.GREEN if selected else UITheme.INK_DIM
	return box


# Add a new card and return its Card handle so the caller can populate visual/info.
# `disabled` cards are shown (dimmed, per the project's "locked rows stay visible"
# convention) but skip both selection landing and confirm.
func add_card(disabled: bool = false) -> Card:
	var card := Card.new()
	card.disabled = disabled
	card.root = PanelContainer.new()
	card.root.custom_minimum_size = Vector2(_card_width(), _card_height())
	card.root.add_theme_stylebox_override("panel", _card_stylebox(false))
	card.root.mouse_filter = Control.MOUSE_FILTER_PASS
	# `card.root` is an absolute-positioned child of `_strip` (a plain Control, not a
	# layout Container) — nothing ever assigns it a rect, so its actual size just grows to
	# fit whatever its children's combined minimum size demands. A caller's long label (a
	# region's "Locked — clear <gate>" subtitle, say) that doesn't wrap pushes the card
	# wider than card_carousel_card_width, and since cards sit at FIXED index*unit offsets,
	# a too-wide card visibly overlaps its neighbour. clip_contents is the safety net (a
	# card can never bleed into a neighbour's space even if something still overflows);
	# the actual fix is _prepare_incoming_child below, which stops the overflow at the
	# source so text is legible (wrapped) rather than merely clipped.
	card.root.clip_contents = true

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", UITheme.GAP_TIGHT)
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	card.root.add_child(col)

	# visual + info must sum to EXACTLY the space card.root's stylebox padding and col's
	# separation leave inside _card_height() — not "half the card each" independently of
	# that budget, which is what let a caller's info content (now often several WRAPPED
	# lines — see _prepare_incoming_child below) push col's combined minimum height past
	# _card_height() and grow the whole card downward past its own border. Both slots are
	# plain Controls (not layout Containers), so — same trick as card.root's own
	# clip_contents — their REPORTED minimum size to col is fixed at whatever we set here,
	# never inflated by what a caller adds inside; clip_contents on each is what then
	# happens to content that still doesn't fit, instead of growing the card.
	var content_h := _card_height() - UITheme.GAP_TIGHT - 2.0 * UITheme.PANEL_PAD
	var visual_h := content_h * 0.5
	var info_h := content_h - visual_h

	card.visual = Control.new()
	card.visual.custom_minimum_size = Vector2(0, visual_h)
	card.visual.clip_contents = true
	card.visual.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card.visual.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_child(card.visual)

	var info_slot := Control.new()
	info_slot.custom_minimum_size = Vector2(0, info_h)
	info_slot.clip_contents = true
	info_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	info_slot.mouse_filter = Control.MOUSE_FILTER_PASS
	col.add_child(info_slot)

	card.info = VBoxContainer.new()
	card.info.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.info.mouse_filter = Control.MOUSE_FILTER_PASS
	info_slot.add_child(card.info)
	# Any child a caller adds to visual/info must (a) never capture input itself — every
	# Control defaults to MOUSE_FILTER_STOP, which swallowed a tap on a card's own icon/3D
	# preview before it could ever reach card.root's gui_input, reported as "touch targets
	# don't work for the visual upper half" — and (b), if it's a Label, wrap rather than
	# report a wide minimum size that would grow the card past card_width (see the comment
	# on card.root above). Hooked here, once, so every current AND future caller is
	# covered automatically — no caller has to remember either rule for its own children.
	card.visual.child_entered_tree.connect(_prepare_incoming_child)
	card.info.child_entered_tree.connect(_prepare_incoming_child)

	_strip.add_child(card.root)
	var index := _cards.size()
	card.root.gui_input.connect(_on_card_gui_input.bind(index))
	_cards.append(card)
	_layout()
	return card


func _prepare_incoming_child(node: Node) -> void:
	var ctrl := node as Control
	if ctrl != null:
		# Purely decorative from the input system's POV — card.root (via _on_card_gui_input)
		# is what owns tap-to-select/tap-to-confirm for the WHOLE card. Control defaults to
		# MOUSE_FILTER_STOP, which swallows a touch/click before it can ever bubble up to
		# card.root, so a caller's icon/CarCardPreview silently ate every tap that landed on
		# it instead of letting the card itself see it.
		ctrl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lbl := node as Label
	if lbl == null:
		return
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# A Label with autowrap OFF reports the full unwrapped text width as its minimum size,
	# which is exactly what pushed a card wider than card_width. Autowrap alone doesn't
	# clear an explicit custom_minimum_size some caller might have set, so zero it too.
	lbl.custom_minimum_size.x = 0


func card_count() -> int:
	return _cards.size()


# The Card handle add_card returned for `index` — for a host that needs to reach back into
# a card's visual/info slots after the fact (e.g. to rebuild an expensive visual lazily
# around the current selection rather than for every card up front; see hub_shell.gd's
# _refresh_car_previews).
func get_card(index: int) -> Card:
	return _cards[index]


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
	return index * (_card_width() + Config.data.card_carousel_gap)


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
		var x := centre_x - _card_width() * 0.5 + i * (_card_width() + Config.data.card_carousel_gap) - _offset
		card.root.position = Vector2(x, (size.y - _card_height()) * 0.5)
		card.root.modulate.a = 1.0 if i == _selected \
			else Config.data.card_carousel_unselected_alpha
		card.root.add_theme_stylebox_override("panel", _card_stylebox(i == _selected))


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

# Shared by both the per-card press handler below AND _gui_input's own press handling
# (for a press that lands on the carousel's own background, between/around cards, rather
# than on any specific card — see _gui_input for why that needs its own arming path too).
func _begin_drag(global_x: float) -> void:
	_drag_active = true
	_drag_start_x = global_x
	_drag_start_offset = _offset


func _on_card_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_drag(mb.global_position.x)
			else:
				var dragged := absf(mb.global_position.x - _drag_start_x) > 4.0
				_drag_active = false
				if not dragged:
					_tap_card(index)
	elif event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		# InputEventScreenTouch has no global_position field (unlike mouse events), and
		# this handler is bound to the PRESSED CARD's own gui_input signal, so t.position
		# arrives local to THAT card — not to the carousel. _gui_input's drag handler below
		# reads InputEventScreenDrag.position local to the CAROUSEL instead (it's the
		# carousel's own override). Mixing those two local frames was the bug: the very
		# first drag sample computed position-in-carousel minus position-in-card, a bogus
		# delta as large as the distance between that card and the carousel's own origin —
		# read by the player as the whole strip jumping the moment a touch started on any
		# card that wasn't sitting exactly at the carousel's local (0,0). Converting through
		# get_global_transform() puts both ends in the same frame.
		var touch_x := (_cards[index].root.get_global_transform() * t.position).x
		if t.pressed:
			_begin_drag(touch_x)
		else:
			var dragged2 := absf(touch_x - _drag_start_x) > 4.0
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
	# A press that lands on the carousel's OWN background — the empty space between or
	# around cards, now genuinely reachable since the page behind it is transparent
	# (features/card-carousel.md → "the gaps show the live 3D showcase") — never reaches
	# _on_card_gui_input at all, since that's bound to each CARD's gui_input signal. Without
	# arming _drag_active here too, a drag started off any card silently did nothing:
	# reported as "impossible to scroll starting from the background". A press that
	# DID land on a card also reaches here (cards use MOUSE_FILTER_PASS, so the event
	# bubbles up after the card's own handler runs) — re-arming with the same true global
	# x is harmless, not a conflicting second gesture.
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_begin_drag(mb.global_position.x)
			else:
				# Reset even though a card-originated release already does this too (that
				# handler runs first — children process before ancestors — so this is a
				# harmless no-op then): a release that never touched a card would otherwise
				# leave _drag_active stuck true, and bare mouse motion with no button held
				# would go on panning the strip.
				_drag_active = false
		return
	if event is InputEventScreenTouch:
		var ts := event as InputEventScreenTouch
		if ts.pressed:
			_begin_drag((get_global_transform() * ts.position).x)
		else:
			_drag_active = false
		return
	if event is InputEventMouseMotion and _drag_active:
		var mm := event as InputEventMouseMotion
		_offset = _drag_start_offset - (mm.global_position.x - _drag_start_x)
		_layout()
	elif event is InputEventScreenDrag and _drag_active:
		var d := event as InputEventScreenDrag
		# d.position arrives local to THIS control (the carousel), while _drag_start_x was
		# recorded local to whichever CARD the touch started on — see the matching comment
		# in _on_card_gui_input for why that mismatch has to be resolved through a common
		# (global) frame rather than compared directly.
		var drag_x := (get_global_transform() * d.position).x
		_offset = _drag_start_offset - (drag_x - _drag_start_x)
		_layout()


func end_drag_and_snap() -> void:
	if _cards.is_empty():
		return
	# A drag has to cross card_carousel_drag_step_fraction of a card's width, from the
	# CURRENTLY selected card, before it counts as a step — a short drag (a flick that
	# barely moved) snaps back to where it started instead of jumping to whatever card
	# is nearest by raw distance, which would make a small accidental drag re-pick.
	var step := _card_width() + Config.data.card_carousel_gap
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

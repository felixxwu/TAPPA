class_name UpgradeSlotPopup
extends CanvasLayer
# The picker that opens over the upgrades grid when a tile is pressed: pick what this ONE
# slot runs. Same modal shape as ConfirmPopup (dim mouse-consuming backdrop + centred house
# panel on layer 101, MODAL_GROUP so only one is ever up and everything behind it goes
# deaf), but deliberately stripped of ConfirmPopup's chrome — no title, no body, no button
# row. The tile the player just pressed already says which slot this is, and a title
# repeating "TURBO" over a list of turbos is a line of nothing.
#
# Two entry points, because the slots split two ways:
#   open()        — a vertical list of text options, one per UpgradeOptions entry.
#   open_slider() — the engine DETUNE, which is continuous: a list of 21 percentages would
#                   be a slider drawn badly, so it gets an actual slider.
#
# Everything about WHICH options exist, what they cost and why one is locked comes from
# UpgradeOptions — this file only draws it. See features/upgrade-catalogue.md.

signal finished()

var _on_pick: Callable = Callable()
var _center: CenterContainer = null   # MenuNav's root; the panel's centring parent


# The option list for `slot`. `options` are UpgradeOptions.options_for entries; picking a
# selectable one closes the popup and calls `on_pick` with its `id`. Back closes without
# applying. Returns null when a modal is already up (ConfirmPopup's one-at-a-time rule).
static func open(host: Node, options: Array, on_pick: Callable) -> UpgradeSlotPopup:
	var popup := _spawn(host)
	if popup == null:
		return null
	popup._on_pick = on_pick
	popup._build_list(options)
	return popup


# The engine-detune slider, 0–100% in steps of 5. `initial` is the current percentage;
# `on_value` fires on every change (the write-through is live, so the player sees the car's
# figures move while dragging) and back/confirm simply closes.
static func open_slider(host: Node, initial: float, on_value: Callable,
		label_for := Callable()) -> UpgradeSlotPopup:
	var popup := _spawn(host)
	if popup == null:
		return null
	popup._build_slider(initial, on_value, label_for)
	return popup


# The shared modal shell: refuse if something already owns the screen, then layer + dim +
# centre exactly as ConfirmPopup does, so a picker and a confirm can't read as two
# different kinds of window.
# `host` identifies the TREE, not the parent.
#
# The popup is parented at the SCENE ROOT, never at the calling control, because the
# upgrades page can be hosted inside a WorldPanel — a SubViewport rendered onto a 3D quad
# in the garage. A CanvasLayer added under that page would render into the SubViewport:
# its full-rect dim would fill the quad with black and its panel would be scaled down with
# the rest of the viewport, leaving the list far too small to read. Every ConfirmPopup
# caller sidesteps this by passing a scene-level node; doing it here means callers cannot
# get it wrong.
static func _spawn(host: Node) -> UpgradeSlotPopup:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return null
	var tree := host.get_tree()
	if ConfirmPopup.any_open(tree) != null:
		return null
	# Prefer the current scene so the popup dies with it; fall back to the window root
	# (a bare test harness has no current_scene). NEVER fall back to `host` — that is the
	# SubViewport case this whole function exists to avoid.
	var parent: Node = tree.current_scene
	if parent == null or not is_instance_valid(parent):
		parent = tree.root
	var popup := UpgradeSlotPopup.new()
	parent.add_child(popup)
	return popup


# The panel every variant fills: returns the VBox its rows go into.
func _shell() -> VBoxContainer:
	layer = 101  # above overlays, same as ConfirmPopup
	add_to_group(ConfirmPopup.MODAL_GROUP)
	set_meta("modal_title", "Upgrade slot")  # named if a second modal is ever refused

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = UITheme.MODAL_DIM
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow taps so nothing falls through
	add_child(dim)

	_center = CenterContainer.new()
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_center)
	var panel := UITheme.panel(1.0, 20)
	_center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 2)
	vbox.custom_minimum_size = Vector2(_panel_width(), 0)
	panel.add_child(vbox)
	return vbox


# Clamp the panel to the logical viewport, for the same reason ConfirmPopup does: the
# design width is comfortable on desktop and wider than the whole screen in portrait.
func _panel_width() -> float:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size \
		if get_viewport() != null else (Config.data.virtual_resolution if Config.data != null else Vector2(480, 360))
	return clampf(300.0, 180.0, maxf(viewport_size.x - 32.0, 180.0))


func _build_list(options: Array) -> void:
	var vbox := _shell()
	var first: Control = null
	for entry in options:
		var opt: Dictionary = entry
		if bool(opt.get("selectable", false)):
			var b := _option_button(opt)
			vbox.add_child(b)
			# Open ON what the car is already running, so the list reads as "here is where
			# you are" rather than dumping the cursor on whatever happens to be top.
			if bool(opt.get("current", false)):
				first = b
		else:
			vbox.add_child(_locked_row(opt))
	if first == null:
		first = UITheme.first_focusable(vbox)
	UITheme.enforce(self)
	MenuNav.attach(_center, {"first": first, "on_back": _dismiss})


# A pickable option. `price >= 0` means taking it SPENDS stars, so the row quotes them with
# the drawn gold star every price in the game uses (StarRow.price_icon — Syne Mono has no
# star glyph, so a text one is tofu on the web export).
func _option_button(opt: Dictionary) -> Button:
	var b := Button.new()
	var price := int(opt.get("price", -1))
	b.text = String(opt.get("label", ""))
	if price >= 0:
		b.text = "%s %d" % [b.text, price]
		b.icon = StarRow.price_icon()
		b.icon_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		b.add_theme_constant_override("h_separation", 3)
	b.focus_mode = Control.FOCUS_ALL
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	# The house "this one is selected" treatment, so the current pick stays legible even
	# while the focus cursor sits somewhere else in the list.
	UITheme.mark_selected(b, bool(opt.get("current", false)))
	b.pressed.connect(_pick.bind(String(opt.get("id", ""))))
	return b


# An option the player cannot take yet: SHOWN, greyed, and captioned with the reason —
# a slot's whole ladder is visible so "what else could go in here" is answered on the spot.
#
# A LABEL rather than a disabled button, deliberately. MenuNav.attach promotes every
# FOCUS_NONE BaseButton it finds to FOCUS_ALL, so a button here would be walked onto by the
# keyboard/gamepad cursor no matter how it was configured; a Label cannot take focus at all,
# so the skip is structural rather than a setting someone can undo.
func _locked_row(opt: Dictionary) -> Control:
	var l := Label.new()
	var reason := String(opt.get("locked_reason", ""))
	l.text = String(opt.get("label", "")) if reason == "" \
		else "%s — %s" % [opt.get("label", ""), reason]
	l.modulate = UITheme.MUTED
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _build_slider(initial: float, on_value: Callable, label_for: Callable) -> void:
	var vbox := _shell()
	# The same shared house slider row the tuning panel's handling axes use, so the detune
	# knob looks and behaves like every other continuous control in the game.
	var handles := SliderRow.build({
		"name": "Engine detune", "lo": "0%", "hi": "100%",
		"min": 0.0, "max": 100.0, "step": 5.0,
	})
	var slider: HSlider = handles["slider"]
	var value_label: Label = handles["value_label"]
	slider.set_value_no_signal(clampf(initial, 0.0, 100.0))
	var repaint := func(v: float) -> void:
		if on_value.is_valid():
			on_value.call(v)
		if label_for.is_valid():
			value_label.text = String(label_for.call(v))
	slider.value_changed.connect(repaint)
	if label_for.is_valid():
		value_label.text = String(label_for.call(slider.value))
	vbox.add_child(handles["panel"])
	# A DONE BUTTON, unlike the list variant. The list closes itself the moment an option is
	# picked, so its only exit is the one the player already wanted; a slider has no
	# equivalent "I am finished" gesture, and Esc / gamepad-B are not discoverable and do
	# not exist at all for a pointer or a touchscreen. Without this the popup could only be
	# left by a key the player had to guess.
	#
	# The write-through is live on every drag, so this confirms nothing — it just leaves.
	var done := Button.new()
	done.text = "Done"
	done.focus_mode = Control.FOCUS_ALL
	done.pressed.connect(_dismiss)
	vbox.add_child(done)
	UITheme.enforce(self)
	MenuNav.attach(_center, {"first": slider, "on_back": _dismiss})


func _pick(id: String) -> void:
	var cb := _on_pick
	_dismiss()
	if cb.is_valid():
		cb.call(id)


# Public so a host (or a test) can close the picker the same way Back does.
func dismiss() -> void:
	_dismiss()


func _dismiss() -> void:
	finished.emit()
	queue_free()

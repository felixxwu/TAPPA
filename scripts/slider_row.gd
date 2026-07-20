class_name SliderRow
extends RefCounted
# Shared builder for the house "labeled slider row" used by the tuning panel
# (TuningPanel, the handling axes) and the upgrades menu (UpgradesMenu, the engine
# detune). One place owns the layout, the fixed 180px label column, the font sizes,
# the extremity end-labels, and the focus-highlight wiring — so the rows can't drift
# apart (they used to be two hand-copied builders). Pure construction, no per-frame
# state, so it's a static builder rather than a scene/node.
#
# build(spec) returns the handles the caller binds axis-specific behaviour onto:
#   {panel, slider, name_label, value_label}
# The caller adds `panel` to its tree, connects `slider.value_changed`, seeds the
# value via set_value_no_signal, and writes `value_label` / grey state itself. The
# host owns MenuNav (the two hosts drive nav differently), so it stays out of here.

# spec keys: name, lo, hi (label texts); min, max, step (slider range, defaults
# −1..1 step 0.05 — the handling-axis shape).
static func build(spec: Dictionary) -> Dictionary:
	# Use horizontal space: a left column (name above value) sits beside a right
	# column (the slider above its extremity labels).
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	# Left column: name on top of the current value. FIXED width (clip, don't grow) so
	# a longer value — e.g. the detune row's "80% - 200 hp/tonne" readout — can't widen
	# this column and shrink only that row's slider. Every row's slider column then
	# gets the same leftover width, so all sliders line up to the same length.
	var label_col := VBoxContainer.new()
	label_col.add_theme_constant_override("separation", 2)
	label_col.custom_minimum_size = Vector2(180, 0)
	label_col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	row.add_child(label_col)
	var name_label := Label.new()
	name_label.text = String(spec.get("name", ""))
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.clip_text = true
	label_col.add_child(name_label)
	var value := Label.new()
	value.add_theme_font_size_override("font_size", 14)
	value.modulate = Color(1, 1, 1, 0.8)
	value.clip_text = true
	label_col.add_child(value)

	# Right column: the slider with its extremity labels beneath.
	var slider_col := VBoxContainer.new()
	slider_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider_col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider_col.add_theme_constant_override("separation", 2)
	row.add_child(slider_col)

	var slider := HSlider.new()
	slider.min_value = float(spec.get("min", -1.0))
	slider.max_value = float(spec.get("max", 1.0))
	slider.step = float(spec.get("step", 0.05))
	# Focusable: ui_up/ui_down walk between sliders, ui_left/ui_right nudge the focused
	# one (the natural Range behaviour) — keyboard/gamepad tuning with no pointer.
	slider.focus_mode = Control.FOCUS_ALL
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider_col.add_child(slider)

	var ends := HBoxContainer.new()
	slider_col.add_child(ends)
	var lo := Label.new()
	lo.text = String(spec.get("lo", ""))
	lo.add_theme_font_size_override("font_size", 11)
	lo.modulate = Color(1, 1, 1, 0.6)
	lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ends.add_child(lo)
	var hi := Label.new()
	hi.text = String(spec.get("hi", ""))
	hi.add_theme_font_size_override("font_size", 11)
	hi.modulate = Color(1, 1, 1, 0.6)
	hi.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ends.add_child(hi)

	# Wrap the row in a panel that lights up (SURFACE_HOVER face + green underline, the
	# house focus look) while its slider holds the keyboard/gamepad cursor, so it's
	# obvious which slider is selected. Focus signals paint it; callers grey the panel
	# out when a row is locked. `pad` is the panel's content inset (default 6, breathing
	# room for the highlight box); pass 0 when the row must line up flush with sibling
	# rows that AREN'T panel-wrapped (e.g. the detune row among the upgrades slot rows).
	var pad := int(spec.get("pad", 6))
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(row)
	slider.focus_entered.connect(SliderRow._highlight.bind(panel, name_label, true, pad))
	slider.focus_exited.connect(SliderRow._highlight.bind(panel, name_label, false, pad))
	_highlight(panel, name_label, false, pad)

	return {"panel": panel, "slider": slider, "name_label": name_label, "value_label": value}


# Paint / clear the selected-row highlight on a row's wrapping panel as its slider
# gains / loses the keyboard/gamepad focus: the name goes bright white and the panel
# lifts to the house focus look so the current slider stands out.
static func _highlight(panel: PanelContainer, name_label: Label, focused: bool, pad := 6) -> void:
	UITheme.mark_panel_focused(panel, focused, pad)
	if focused:
		name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	else:
		name_label.remove_theme_color_override("font_color")

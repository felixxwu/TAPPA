class_name TuningPanel
extends VBoxContainer
# Reusable per-car TUNING slider panel — the four handling axes (grip balance,
# brake bias, aero balance, engine detune). Owns its sliders and Save persistence;
# reports edits via on_change so the host can re-field the car. Used by the HQ lift
# (hq.gd) and the start-line pre-event grid (start_line.gd). See features/tuning.md.

var _owned: Dictionary = {}
var _on_change: Callable = Callable()
var _pw_limit := -1.0  # rally power-to-weight ceiling (hp/tonne) to show; <0 = none
var _sliders: Dictionary = {}        # axis -> HSlider
var _slider_rows: Dictionary = {}    # axis -> row PanelContainer (greyed when locked)
var _slider_values: Dictionary = {}  # axis -> value Label
var _built := false


# Build the rows once, then bind the owned car. on_change() is called (no args) after
# each edit / reset so the host can re-apply tuning to the live car. pw_limit (hp/tonne,
# <0 = none) is the rally's power-to-weight ceiling; when set, the engine-detune label
# shows the limit and flags OVER LIMIT. The start line passes the rally's pw_max; the HQ
# garage lift omits it (the player tunes freely — eligibility is checked at Start).
func setup(owned_car: Dictionary, on_change := Callable(), pw_limit := -1.0) -> void:
	_owned = owned_car
	_on_change = on_change
	_pw_limit = pw_limit
	if not _built:
		_build()
		_built = true


func first_slider() -> Control:
	for axis in TuningLibrary.AXES:
		if _sliders.has(axis):
			return _sliders[axis]
	return null


func _build() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	# One row per axis: a heading + value, then the slider. The labels at each end
	# name the slider's directions so the player knows which way is which.
	for spec in [
		{"axis": "grip_balance", "name": "Grip balance", "lo": "understeer", "hi": "oversteer"},
		{"axis": "brake_bias", "name": "Brake bias", "lo": "rearward", "hi": "forward"},
		{"axis": "aero_balance", "name": "Aero balance", "lo": "front", "hi": "rear"},
		{"axis": "engine_detune", "name": "Engine detune", "lo": "0%", "hi": "100%",
			"min": 0.0, "max": 100.0, "step": 5.0, "fmt": "%d%%"},
	]:
		add_child(_make_slider_row(spec))

	var reset := Button.new()
	reset.text = "Reset to neutral"
	reset.focus_mode = Control.FOCUS_ALL
	reset.pressed.connect(_reset)
	add_child(reset)


# Paint / clear the selected-row highlight on a tuning slider's wrapping panel when
# its slider gains / loses the keyboard/gamepad focus. The name goes bright white and
# the panel lifts to the house focus look so the current slider stands out clearly.
func _highlight_slider_row(panel: PanelContainer, name_label: Label, focused: bool) -> void:
	UITheme.mark_panel_focused(panel, focused, 6)
	if focused:
		name_label.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	else:
		name_label.remove_theme_color_override("font_color")


func _make_slider_row(spec: Dictionary) -> Control:
	var axis := String(spec["axis"])
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
	name_label.text = String(spec["name"])
	name_label.add_theme_font_size_override("font_size", 16)
	name_label.clip_text = true
	label_col.add_child(name_label)
	var value := Label.new()
	value.add_theme_font_size_override("font_size", 14)
	value.modulate = Color(1, 1, 1, 0.8)
	value.clip_text = true
	label_col.add_child(value)
	_slider_values[axis] = value

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
	slider.value_changed.connect(_on_slider_changed.bind(axis))
	slider_col.add_child(slider)
	_sliders[axis] = slider

	var ends := HBoxContainer.new()
	slider_col.add_child(ends)
	var lo := Label.new()
	lo.text = String(spec["lo"])
	lo.add_theme_font_size_override("font_size", 11)
	lo.modulate = Color(1, 1, 1, 0.6)
	lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ends.add_child(lo)
	var hi := Label.new()
	hi.text = String(spec["hi"])
	hi.add_theme_font_size_override("font_size", 11)
	hi.modulate = Color(1, 1, 1, 0.6)
	hi.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ends.add_child(hi)

	# Wrap the row in a panel that lights up (SURFACE_HOVER face + green underline, the
	# house focus look) while its slider holds the keyboard/gamepad cursor, so it's
	# obvious which slider is selected. Focus signals paint it; the panel is the row
	# Control refresh() greys out when the axis is locked.
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(row)
	slider.focus_entered.connect(_highlight_slider_row.bind(panel, name_label, true))
	slider.focus_exited.connect(_highlight_slider_row.bind(panel, name_label, false))
	_highlight_slider_row(panel, name_label, false)
	_slider_rows[axis] = panel
	return panel


# The engine-detune slider's value label: the detune percent plus the car's LIVE
# power-to-weight at that setting (e.g. "80% - 200 hp/tonne"), so the player sees the
# ratio each event is gated on move as they detune. effective_meta already folds in
# the (mirrored) detune, so this recomputes off the current setting.
func _detune_label_text(pct: int) -> String:
	var entry := CarLibrary.by_id(String(_owned.get("model_id", "")))
	var pw := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(_owned, entry)) * CarLibrary.KW_KG_TO_HP_TONNE
	if _pw_limit >= 0.0:
		var over := " OVER LIMIT" if pw > _pw_limit else ""
		return "%d%% - %.0f hp/tonne (max %.0f)%s" % [pct, pw, _pw_limit, over]
	return "%d%% - %.0f hp/tonne" % [pct, pw]


# Reflect the stored tuning + each axis's unlock state onto the sliders.
func refresh() -> void:
	var tuning: Dictionary = _owned.get("tuning", {})
	for axis in TuningLibrary.AXES:
		var slider: HSlider = _sliders[axis]
		var value: Label = _slider_values[axis]
		var row: Control = _slider_rows[axis]
		var unlocked := TuningLibrary.axis_unlocked(_owned, axis)
		slider.editable = unlocked
		row.modulate = Color(1, 1, 1, 1.0 if unlocked else 0.4)
		# set_value_no_signal so syncing the UI doesn't re-save the value.
		if axis == "engine_detune":
			# Full 0-100% range: the car can be detuned or run at full power freely.
			# Rally eligibility is enforced at Start (start_line.gd), not by capping here.
			slider.max_value = 100.0
			slider.set_value_no_signal(clampf(float(tuning.get("engine_detune", 1.0)), 0.0, 1.0) * 100.0)
			value.text = _detune_label_text(int(round(slider.value)))
		else:
			slider.set_value_no_signal(clampf(float(tuning.get(axis, 0.0)), -1.0, 1.0))
			if unlocked:
				value.text = "%+.2f" % slider.value
			else:
				value.text = "needs %s" % ("Big Brake Kit" if axis == "brake_bias" else "Aero Kit")


func _on_slider_changed(value: float, axis: String) -> void:
	if _owned.is_empty():
		return
	if axis == "engine_detune":
		var frac := clampf(value / 100.0, 0.0, 1.0)
		Save.set_engine_detune(int(_owned.get("instance_id", -1)), frac)
		var tuning_d: Dictionary = _owned.get("tuning", {})
		tuning_d["engine_detune"] = frac
		_owned["tuning"] = tuning_d
		(_slider_values[axis] as Label).text = _detune_label_text(int(round(value)))
		if _on_change.is_valid():
			_on_change.call()
		return
	var tuning: Dictionary = _owned.get("tuning", {})
	tuning[axis] = value
	_owned["tuning"] = tuning
	Save.set_tuning(int(_owned.get("instance_id", -1)), tuning)
	(_slider_values[axis] as Label).text = "%+.2f" % value
	if _on_change.is_valid():
		_on_change.call()


# Zero every axis (free + instant) — the lift's Reset action (features/tuning.md).
func _reset() -> void:
	if _owned.is_empty():
		return
	_owned["tuning"] = {}
	Save.set_tuning(int(_owned.get("instance_id", -1)), {})
	refresh()
	if _on_change.is_valid():
		_on_change.call()

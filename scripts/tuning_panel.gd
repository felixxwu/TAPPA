class_name TuningPanel
extends VBoxContainer
# Docs: features/tuning.md — update in the same change as this file.
# Tests: tests/headless/test_drivetrain.gd, tests/headless/test_tuning_panel.gd, tests/headless/test_start_line.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'TuningPanel' tests/headless/` and read the assertions that pin what you are about to change (4 test files touch this script).
# Reusable per-car TUNING slider panel — the three handling axes (grip balance,
# brake bias, aero balance). Owns its sliders and Save persistence; reports edits
# via on_change so the host can re-field the car. Used by the start-line pre-event menu
# (start_line.gd). Engine detune is a power (p/w) knob, so its slider lives wherever the
# host draws one, not here. See features/tuning.md.

var _owned: Dictionary = {}
var _on_change: Callable = Callable()
var _on_wheels: Callable = Callable()
var _sliders: Dictionary = {}        # axis -> HSlider
var _slider_values: Dictionary = {}  # axis -> value Label
var _built := false
# The two action buttons. Built here, PLACED BY THE HOST in its bottom action row —
# see action_buttons().
var _reset_button: Button   # reset every axis to neutral — see _reset
var _wheels_button: Button  # cosmetic wheel styles — see _on_wheels_pressed


# Build the rows once, then bind the owned car. on_change() is called (no args) after
# each edit / reset so the host can re-apply tuning to the live car. on_wheels() (no
# args) fires when the Wheels button is pressed — the host owns the wheel-swap flow. NO
# HOST WIRES IT TODAY (the HQ lift did, and is deleted), so the button is hidden
# everywhere; see features/wheel-customization.md.
func setup(owned_car: Dictionary, on_change := Callable(), on_wheels := Callable()) -> void:
	_owned = owned_car
	_on_change = on_change
	_on_wheels = on_wheels
	if not _built:
		_build()
		_built = true
	# Wheels only makes sense where the host actually wired somewhere to send it; the
	# start line passes no on_wheels, so hide it rather than show a button that does
	# nothing.
	_wheels_button.visible = _on_wheels.is_valid()


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
	]:
		add_child(_make_slider_row(spec))

	# The ACTIONS are built here but deliberately NOT added as children: the host lays
	# them out along the bottom of its page, in one horizontal row gapped off this body,
	# beside its own Back button (see action_buttons). Every menu in the game ends in that
	# same row, so a page that stacked its actions full-width inside the body read as a
	# different kind of screen.
	_reset_button = Button.new()
	_reset_button.text = "Reset to neutral"
	_reset_button.focus_mode = Control.FOCUS_ALL
	_reset_button.pressed.connect(_reset)

	# Wheels: cosmetic wheel styles. The host it was built for opened a solo car-park view
	# where the car sat SETTLED on its suspension under a side-on camera (wheels are judged
	# by stance). That view is deleted; the button stays built and hidden until something
	# wires on_wheels again. See features/wheel-customization.md.
	_wheels_button = Button.new()
	_wheels_button.text = "Wheels"
	_wheels_button.focus_mode = Control.FOCUS_ALL
	_wheels_button.pressed.connect(_on_wheels_pressed)


# This panel's action buttons, for the HOST to place in its bottom action row (in order,
# left to right). They are not children of the panel — see _build. Hosts must add them to
# a container, or they are never freed and never shown.
func action_buttons() -> Array[Button]:
	if not _built:
		_build()
		_built = true
	return [_reset_button, _wheels_button]


func _on_wheels_pressed() -> void:
	if _on_wheels.is_valid():
		_on_wheels.call()


# Build one handling-axis row via the shared SliderRow builder, then bind the axis-
# specific bits (value persistence + the axis's slider/value/panel handles refresh()
# and _reset() reach for). The layout + focus-highlight live in SliderRow so this row
# can't drift from the detune slider in UpgradeSlotPopup (the shared modal picker).
func _make_slider_row(spec: Dictionary) -> Control:
	var axis := String(spec["axis"])
	var handles := SliderRow.build(spec)
	var slider: HSlider = handles["slider"]
	slider.value_changed.connect(_on_slider_changed.bind(axis))
	_sliders[axis] = slider
	_slider_values[axis] = handles["value_label"]
	return handles["panel"]


# Reflect the stored tuning onto the sliders. EVERY AXIS IS EDITABLE: the aero-part gate
# that used to grey out aero_balance went with the parts model
# (todo/roguelike-pivot.md decision 24 — "tuning survives, ungated").
func refresh() -> void:
	var tuning: Dictionary = _owned.get("tuning", {})
	for axis in TuningLibrary.AXES:
		var slider: HSlider = _sliders[axis]
		var value: Label = _slider_values[axis]
		slider.editable = true
		# set_value_no_signal so syncing the UI doesn't re-save the value.
		slider.set_value_no_signal(clampf(float(tuning.get(axis, 0.0)), -1.0, 1.0))
		value.text = "%+.2f" % slider.value


func _on_slider_changed(value: float, axis: String) -> void:
	if _owned.is_empty():
		return
	var tuning: Dictionary = _owned.get("tuning", {})
	tuning[axis] = value
	_owned["tuning"] = tuning
	Save.set_tuning(int(_owned.get("instance_id", -1)), tuning)
	(_slider_values[axis] as Label).text = "%+.2f" % value
	if _on_change.is_valid():
		_on_change.call()


# Zero the handling axes (free + instant) — the Reset action (features/tuning.md).
# Clears ONLY the TuningLibrary.AXES keys and leaves the rest of the tuning bag intact,
# so non-axis knobs stored alongside (engine_detune) survive — this panel resets what it
# owns, not the whole bag.
func _reset() -> void:
	if _owned.is_empty():
		return
	var tuning: Dictionary = (_owned.get("tuning", {}) as Dictionary).duplicate()
	for axis in TuningLibrary.AXES:
		tuning.erase(axis)
	_owned["tuning"] = tuning
	Save.set_tuning(int(_owned.get("instance_id", -1)), tuning)
	refresh()
	if _on_change.is_valid():
		_on_change.call()

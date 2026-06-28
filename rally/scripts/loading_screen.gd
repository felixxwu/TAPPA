class_name LoadingScreen
extends CanvasLayer
# Full-screen "loading stage" overlay shown while world.gd builds the world.
#
# Godot's own boot bar only covers engine + .pck load + script compile. The
# world generation that runs in world.gd._ready() (track, terrain ring, tree
# and bush scatter) is heavy and synchronous, so without this the screen sits
# frozen with no feedback between the boot bar finishing and the first playable
# frame. world.gd shows this overlay first, then advances `set_step()` between
# generation stages (yielding a frame each time so the new label paints), and
# calls `finish()` when the world is ready.

# Drawn above the HUD (layer 2) and mobile controls (layer 3).
const _LAYER := 100

var _title: Label
var _step: Label


func _init() -> void:
	layer = _LAYER

	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.05, 0.08, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(box)

	_title = Label.new()
	_title.text = "Loading stage…"
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_size_override("font_size", 22)
	box.add_child(_title)

	_step = Label.new()
	_step.text = ""
	_step.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_step.add_theme_font_size_override("font_size", 14)
	_step.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_step)


# Set the headline (defaults to "Loading stage…"; the HQ uses its own wording).
func set_title(text: String) -> void:
	if _title != null:
		_title.text = text


# Update the current-stage line (e.g. "Building terrain…").
func set_step(text: String) -> void:
	if _step != null:
		_step.text = text


# Tear the overlay down once the world is ready.
func finish() -> void:
	queue_free()

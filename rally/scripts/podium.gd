extends Control
# Podium — end-of-rally result (todo/menus.md location 3), minimal vertical-slice
# version: a flat placeholder for the 3D podium + reward-reveal rigs. Reads the
# finished rally's summary from RallySession.last_result() and offers Continue,
# which flies back to HQ (placeholder: a plain scene change).

func _ready() -> void:
	var result := RallySession.last_result()
	_build_ui(result)


func _build_ui(result: Dictionary) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.1, 0.12, 0.14)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.add_theme_constant_override("separation", 12)
	add_child(box)

	var title := Label.new()
	title.text = "PODIUM"
	title.add_theme_font_size_override("font_size", 28)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var summary := Label.new()
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	summary.text = _summary_text(result)
	box.add_child(summary)

	var cont := Button.new()
	cont.text = "Continue to HQ"
	cont.focus_mode = Control.FOCUS_NONE
	cont.pressed.connect(_on_continue)
	box.add_child(cont)


func _summary_text(result: Dictionary) -> String:
	if result.get("dnf", false):
		return "DNF — car wrecked.\nThe rally stays incomplete."
	var placed := int(result.get("placed", -1))
	var combined := int(result.get("combined_ms", -1))
	var lines: Array[String] = ["Finished P%d   (%s)" % [placed, _fmt(combined)]]
	if result.get("completed", false):
		lines.append("Top 3 — RALLY WON! Reward delivered to HQ.")
	else:
		lines.append("Outside the top 3 — no reward. Re-enter from HQ to try again.")
	return "\n".join(lines)


# m:ss.cc from milliseconds.
func _fmt(ms: int) -> String:
	if ms < 0:
		return "--:--"
	var seconds := ms / 1000.0
	var minutes := int(seconds / 60.0)
	return "%d:%05.2f" % [minutes, seconds - minutes * 60.0]


func _on_continue() -> void:
	get_tree().change_scene_to_file("res://hq.tscn")

extends Control
# Podium — end-of-rally result (todo/menus.md location 3 + overlay 7), still the
# flat placeholder for the eventual 3D podium / reward-reveal rigs, but now reads
# the full finish summary from RallySession.last_result(): the placement + combined
# time, the REWARD REVEAL (the won car + the per-event upgrades), and the full
# ranked STANDINGS (player vs the fixed opponent field). Continue flies back to HQ
# (placeholder: a plain scene change).

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

	# Title fixed at top, Continue pinned at the bottom, the result/reward/standings
	# in a scroll view between them — the full field can be 10–15 rows, so on a phone
	# the list scrolls and Continue is never clipped (mirrors hq.gd's layout).
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16.0
	root.offset_top = 16.0
	root.offset_right = -16.0
	root.offset_bottom = -16.0
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var title := Label.new()
	title.text = "PODIUM"
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

	# --- Headline result ---
	var summary := Label.new()
	summary.text = _summary_text(result)
	content.add_child(summary)

	# --- Reward reveal (won car + per-event upgrades) ---
	_build_rewards(content, result)

	# --- Standings (full ranked field) ---
	var standings: Array = result.get("standings", [])
	if not standings.is_empty():
		content.add_child(_heading("Standings"))
		for entry in standings:
			content.add_child(_standings_row(entry))

	var cont := Button.new()
	cont.text = "Continue to HQ"
	cont.focus_mode = Control.FOCUS_NONE
	cont.pressed.connect(_on_continue)
	root.add_child(cont)


func _summary_text(result: Dictionary) -> String:
	var rally_name := String(result.get("rally_name", ""))
	var prefix := (rally_name + "\n") if rally_name != "" else ""
	if result.get("dnf", false):
		return "%sDNF — car wrecked.\nThe rally stays incomplete." % prefix
	var placed := int(result.get("placed", -1))
	var combined := int(result.get("combined_ms", -1))
	var lines: Array[String] = ["%sFinished P%d   (%s)" % [prefix, placed, _fmt(combined)]]
	if result.get("showdown_won", false):
		lines.append("THE SHOWDOWN IS WON — you've completed the game!")
	elif result.get("completed", false):
		lines.append("Top 3 — RALLY WON!")
	else:
		lines.append("Outside the top 3 — no car reward. Re-enter from HQ to try again.")
	return "\n".join(lines)


# The reward block: the new car (with a NEW badge when first owned) and the
# per-event upgrade drops — both granted already by RallySession; this only
# reveals them. Upgrades drop every completed event regardless of placement.
func _build_rewards(content: VBoxContainer, result: Dictionary) -> void:
	var car_reward := String(result.get("car_reward", ""))
	var upgrades: Array = result.get("upgrades", [])
	if car_reward == "" and upgrades.is_empty():
		return
	content.add_child(_heading("Rewards"))
	if car_reward != "":
		var entry := CarLibrary.by_id(car_reward)
		var car_name := String(entry.get("name", car_reward))
		var badge := "  (NEW)" if result.get("car_reward_is_new", false) else ""
		var car_label := Label.new()
		car_label.text = "Car won: %s%s — delivered to HQ" % [car_name, badge]
		content.add_child(car_label)
	for line in _upgrade_lines(upgrades):
		var l := Label.new()
		l.text = "+ %s" % line
		content.add_child(l)


# Aggregate the per-event upgrade ids into "Name ×N" lines (resolving display
# names via UpgradeLibrary), preserving first-seen order.
func _upgrade_lines(upgrades: Array) -> Array[String]:
	var counts: Dictionary = {}
	var order: Array[String] = []
	for item_id in upgrades:
		var key := String(item_id)
		if not counts.has(key):
			counts[key] = 0
			order.append(key)
		counts[key] += 1
	var lines: Array[String] = []
	for key in order:
		var display_name := String(UpgradeLibrary.by_id(key).get("name", key))
		var n: int = counts[key]
		lines.append("%s x%d" % [display_name, n] if n > 1 else display_name)
	return lines


# One standings row: position, name, time / DNF. The player's row is tinted and
# marked with a ▶ so it stands out in the field.
func _standings_row(entry: Dictionary) -> Label:
	var l := Label.new()
	var placed := int(entry.get("placed", -1))
	var pos_text := "P%d" % placed if placed >= 1 else "DNF"
	var time_text := "WRECKED" if entry.get("dnf", false) else _fmt(int(entry.get("combined_ms", -1)))
	var who := String(entry.get("name", "?"))
	var is_player: bool = entry.get("is_player", false)
	l.text = "%s%s — %s — %s" % ["> " if is_player else "", pos_text, who, time_text]
	if is_player:
		l.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	return l


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	return l


# m:ss.cc from milliseconds.
func _fmt(ms: int) -> String:
	if ms < 0:
		return "--:--"
	var seconds := ms / 1000.0
	var minutes := int(seconds / 60.0)
	return "%d:%05.2f" % [minutes, seconds - minutes * 60.0]


func _on_continue() -> void:
	get_tree().change_scene_to_file("res://hq.tscn")

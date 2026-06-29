extends Control
# Between-event standings interstitial (todo/menus.md overlay 7). Shown after each
# non-final event: the leaderboard SO FAR — the player's cumulative time vs the
# fixed opponent field over the events run to this point — so the player always
# knows how they're doing. Continue resumes into the next event
# (RallySession.continue_to_next_event). A flat placeholder, like the podium.

func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UITheme.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Title + standings in a scroll view, Continue pinned at the bottom (the field
	# can be 10-15 rows, so on a phone it scrolls and Continue is never clipped).
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16.0
	root.offset_top = 16.0
	root.offset_right = -16.0
	root.offset_bottom = -16.0
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var rally := RallyLibrary.by_id(RallySession.rally_id())
	var done := RallySession.events_completed()
	var title := Label.new()
	title.text = "STANDINGS — after event %d of %d" % [done, RallySession.EVENTS_PER_RALLY]
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "%s — combined time so far" % String(rally.get("name", ""))
	subtitle.add_theme_font_size_override("font_size", 14)
	root.add_child(subtitle)

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	for entry in RallySession.current_standings():
		content.add_child(_standings_row(entry))

	var cont := Button.new()
	cont.text = "Continue to next event >"
	cont.focus_mode = Control.FOCUS_NONE
	cont.pressed.connect(_on_continue)
	root.add_child(cont)

	UITheme.enforce(self)  # house rules: uppercase + one font size


# One standings row: position, name (and the car they drove), cumulative time /
# DNF; the player's row is tinted and marked. Mirrors the podium's row format.
func _standings_row(entry: Dictionary) -> Label:
	var l := Label.new()
	var placed := int(entry.get("placed", -1))
	var pos_text := "P%d" % placed if placed >= 1 else "DNF"
	var time_text := "WRECKED" if entry.get("dnf", false) else _fmt(int(entry.get("combined_ms", -1)))
	var who := String(entry.get("name", "?"))
	var car := String(entry.get("car_name", ""))
	if car != "":
		who += " (%s)" % car
	var is_player: bool = entry.get("is_player", false)
	l.text = "%s%s — %s — %s" % ["> " if is_player else "", pos_text, who, time_text]
	if is_player:
		l.add_theme_color_override("font_color", UITheme.GOLD)
	return l


# m:ss.cc from milliseconds.
func _fmt(ms: int) -> String:
	if ms < 0:
		return "--:--"
	var seconds := ms / 1000.0
	var minutes := int(seconds / 60.0)
	return "%d:%05.2f" % [minutes, seconds - minutes * 60.0]


func _on_continue() -> void:
	RallySession.continue_to_next_event()

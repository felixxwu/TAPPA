extends Control
# Between-event standings interstitial (features/menus.md, features/rally-session.md).
# Shown after each event. For every event after the first it shows TWO pages:
#   1. EVENT n RESULT — that one event's finishing times, ranked (current_event_standings)
#   2. STANDINGS — the cumulative leaderboard so far (current_standings)
# The FIRST event skips page 1 (its event time == its combined time). The FINAL event
# shows only page 1 and then hands off to the podium (which carries the combined view).
# Continue resumes into the next event / results (RallySession.continue_to_next_event).

var _showing_event_page := false
var _action_button: Button = null


func _ready() -> void:
	# The final event resolves to the podium; load it when the rally finishes so the
	# transition happens from here (the run scene is gone by now).
	if not RallySession.rally_finished.is_connected(_on_rally_finished):
		RallySession.rally_finished.connect(_on_rally_finished)
	# Events after the first open on the event-only page; the first event has only the
	# combined page (its single event time is its combined time).
	_showing_event_page = RallySession.events_completed() >= 2
	_build_ui()


func showing_event_page() -> bool:
	return _showing_event_page


func is_final_event() -> bool:
	return RallySession.events_completed() >= RallySession.EVENTS_PER_RALLY


func _build_ui() -> void:
	for c in get_children():
		c.queue_free()

	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = UITheme.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

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
	var subtitle := Label.new()
	var rows: Array
	var button_text := ""
	if _showing_event_page:
		title.text = "EVENT %d RESULT" % done
		subtitle.text = "%s — this event's time" % String(rally.get("name", ""))
		rows = RallySession.current_event_standings()
		button_text = "Continue >" if is_final_event() else "See overall standings >"
	else:
		title.text = "STANDINGS — after event %d of %d" % [done, RallySession.EVENTS_PER_RALLY]
		subtitle.text = "%s — combined time so far" % String(rally.get("name", ""))
		rows = RallySession.current_standings()
		button_text = "Continue to next event >"
	title.add_theme_font_size_override("font_size", 28)
	root.add_child(title)
	subtitle.add_theme_font_size_override("font_size", 14)
	root.add_child(subtitle)

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	for entry in rows:
		content.add_child(_standings_row(entry))

	var cont := Button.new()
	cont.text = button_text
	cont.focus_mode = Control.FOCUS_ALL
	cont.pressed.connect(_on_action)
	root.add_child(cont)
	_action_button = cont

	UITheme.enforce(self)  # house rules: uppercase + one font size
	UITheme.focus_grab.bind(cont).call_deferred()


# The button advances: event page -> combined page (mid-rally), or event/combined
# page -> next event / podium via RallySession.
func _on_action() -> void:
	if _showing_event_page and not is_final_event():
		_showing_event_page = false
		_build_ui()
	else:
		RallySession.continue_to_next_event()


# Back (keyboard/gamepad): from the combined page (reached from the event page) step
# back to the event page. Otherwise leave it to the default (nothing to go back to).
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("menu_back"):
		if not _showing_event_page and RallySession.events_completed() >= 2:
			_showing_event_page = true
			_build_ui()
			get_viewport().set_input_as_handled()


func _on_rally_finished(result: Dictionary) -> void:
	# The final event resolved (from continue_to_next_event on the event page) — show
	# the podium, which carries the combined leaderboard. A rally ABANDONED from the
	# pause menu has no result to celebrate: world.gd sends it to HQ, so the standings
	# scene must NOT load the podium for it (also prevents abandon() during test
	# teardown from firing a stray scene change into the next test).
	if result.get("abandoned", false):
		return
	get_tree().change_scene_to_file("res://podium.tscn")


# One standings row: position, name (and the car), time / DNF; the player's row is
# tinted and marked. Shared by both pages (the row's `combined_ms` is the event time
# on page 1, the cumulative time on page 2).
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

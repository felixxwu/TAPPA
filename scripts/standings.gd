extends Control
# Between-event standings interstitial (features/menus.md, features/rally-session.md).
# Shown after each event. For every event after the first it shows TWO pages:
#   1. EVENT n RESULT — that one event's finishing times, ranked (current_event_standings)
#   2. STANDINGS — the cumulative leaderboard so far (current_standings)
# The FIRST event skips page 1 (its event time == its combined time). Every event,
# INCLUDING the final one, shows both pages before Continue — the final event's page 2
# then hands off to the podium (which carries the combined view).
# Continue resumes into the next event / results (RallySession.continue_to_next_event).

signal leaderboard_hidden_changed(hidden: bool)

# Overlay mode (features/menus.md, event-replay feature): when hosted as an in-world
# overlay over the replay (Task 7 wires this), the host sets overlay_mode = true
# BEFORE _ready — transparent background so the 3D replay shows through, and the
# overlay does NOT own the rally_finished -> podium transition (the live host does).
var overlay_mode := false
var leaderboard_hidden := false

var _showing_event_page := false
var _action_button: Button = null


func _ready() -> void:
	# The final event resolves to the podium; load it when the rally finishes so the
	# transition happens from here (the run scene is gone by now). In overlay mode the
	# live host owns this transition instead.
	if not overlay_mode and not RallySession.rally_finished.is_connected(_on_rally_finished):
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
	bg.name = "Background"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(UITheme.BLACK, 0.0) if overlay_mode else UITheme.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	if overlay_mode and leaderboard_hidden:
		# Hidden: only a Show button, so the replay is visible full-screen behind it.
		var show_btn := Button.new()
		show_btn.text = "Show leaderboard >"
		show_btn.focus_mode = Control.FOCUS_ALL
		# Anchor to the bottom-right but GROW inward (up + left) so the button stays
		# fully on-screen and clickable; a bare BOTTOM_RIGHT preset pins its top-left to
		# the corner and pushes the button off-screen (invisible → no way to un-hide).
		show_btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		show_btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		show_btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
		show_btn.offset_right = -16.0
		show_btn.offset_bottom = -16.0
		show_btn.pressed.connect(toggle_leaderboard)
		add_child(show_btn)
		UITheme.enforce(self)
		MenuNav.attach(self, {first = show_btn, on_back = toggle_leaderboard})
		return

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
		button_text = "See overall standings >"
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
		content.add_child(UITheme.standings_row(entry))

	var cont := Button.new()
	cont.text = button_text
	cont.focus_mode = Control.FOCUS_ALL
	cont.pressed.connect(_on_action)
	root.add_child(cont)
	_action_button = cont

	if overlay_mode:
		var hide_btn := Button.new()
		hide_btn.text = "Hide leaderboard"
		hide_btn.focus_mode = Control.FOCUS_ALL
		hide_btn.pressed.connect(toggle_leaderboard)
		root.add_child(hide_btn)

	UITheme.enforce(self)  # house rules: uppercase + one font size
	# Framework wires focus + WASD/arrow/gamepad nav and routes back (see
	# features/menus.md → MenuNav). Re-run each _build_ui so the fresh button is
	# picked up; attach() reuses the existing node rather than stacking handlers.
	MenuNav.attach(self, {first = cont, on_back = _on_back_pressed})


# The button advances: event page -> combined page (mid-rally), or event/combined
# page -> next event / podium via RallySession.
func _on_action() -> void:
	if _showing_event_page:
		_showing_event_page = false
		_build_ui()
	else:
		RallySession.continue_to_next_event()


# Back (keyboard/gamepad, via MenuNav on_back): from the combined page (reached from
# the event page) step back to the event page. On the event page there's nothing to
# go back to, so we simply do nothing (MenuNav still consumes the press).
func _on_back_pressed() -> void:
	if not _showing_event_page and RallySession.events_completed() >= 2:
		_showing_event_page = true
		_build_ui()


func toggle_leaderboard() -> void:
	leaderboard_hidden = not leaderboard_hidden
	leaderboard_hidden_changed.emit(leaderboard_hidden)
	_build_ui()


func _on_rally_finished(result: Dictionary) -> void:
	# The final event resolved (from continue_to_next_event on the event page) — show
	# the podium, which carries the combined leaderboard. A rally ABANDONED from the
	# pause menu has no result to celebrate: world.gd sends it to HQ, so the standings
	# scene must NOT load the podium for it (also prevents abandon() during test
	# teardown from firing a stray scene change into the next test).
	if result.get("abandoned", false):
		return
	get_tree().change_scene_to_file("res://podium.tscn")

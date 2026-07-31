class_name Standings
extends Control
# Between-event standings interstitial (features/menus.md, features/rally-session.md).
# Shown after each event, as ONE page carrying both leaderboards stacked:
#   1. STAGE n RESULT — that one stage's finishing times, ranked (current_event_standings)
#   2. OVERALL — the cumulative leaderboard so far (current_standings)
# Each section lists the top PODIUM_ROWS finishers; if the player placed outside
# them their own row is appended at the bottom (with a gap marker when it isn't
# adjacent) so they can always see where they came. Both sections show on EVERY stage,
# including the first — where they are identical — so the screen keeps one shape.
# Continue resumes into the next event / results (RallySession.continue_to_next_event);
# after the final event that resolves to the podium (which carries the combined view).

signal leaderboard_hidden_changed(hidden: bool)

var _reward_collected := false
var _reveal: UpgradeReveal = null

# Overlay mode (features/menus.md, event-replay feature): when hosted as an in-world
# overlay over the replay (Task 7 wires this), the host sets overlay_mode = true
# BEFORE _ready — transparent background so the 3D replay shows through, and the
# overlay does NOT own the rally_finished -> podium transition (the live host does).
var overlay_mode := false
var leaderboard_hidden := false

var _action_button: Button = null
var _reveal_gen := 0  # bumped per reveal so a stale coroutine can't touch freed rows

# Page 2 — the global stage leaderboard (features/menus.md, features/global-leaderboards.md).
# A page concept on the local-vs-global axis, living in the child control rather
# than as a mode flag here. Shown once, on the way out of this screen.
var _global_page: GlobalStandings = null
var _global_shown := false
var _root_box: VBoxContainer = null  # page 1's content, hidden while page 2 is up

# Seconds between each leaderboard line appearing. Shorter than it was when this
# screen showed one list at a time: two stacked sections mean roughly twice as many
# lines, and the whole fill-in should still be over in a couple of seconds.
const REVEAL_STEP := 0.3
# How many finishers each section lists before it cuts to the player's own row.
const PODIUM_ROWS := 3


func _ready() -> void:
	# The final event resolves to the podium; load it when the rally finishes so the
	# transition happens from here (the run scene is gone by now). In overlay mode the
	# live host owns this transition instead.
	if not overlay_mode and not RallySession.rally_finished.is_connected(_on_rally_finished):
		RallySession.rally_finished.connect(_on_rally_finished)
	_build_ui()


func is_final_event() -> bool:
	return RallySession.events_completed() >= RallySession.EVENTS_PER_RALLY


# True when this event awarded an upgrade still to be collected — PAGE 2's button
# then collects it (the reveal) instead of resuming the rally. Always false on the
# final event, which draws no upgrade.
func _reward_pending() -> bool:
	return not _reward_collected \
		and RallySession.events_completed() < RallySession.EVENTS_PER_RALLY \
		and RallySession.current_event_upgrade() != ""


# Which entries of a ranked leaderboard a section actually shows: the top `top`,
# plus the player's own row when they finished outside it. A {"gap": true} marker
# is inserted between the two when they are not already adjacent, so the jump in
# position reads as a cut rather than a mistake. Pure + static so it can be tested
# without building the scene.
# Heading for the cumulative section, spelling out exactly which stages are summed:
# "OVERALL — stage 1 only", then "OVERALL — stages 1 + 2", "OVERALL — stages 1 + 2 + 3".
# On stage 1 the two lists are identical, so saying "stage 1 only" is what stops that
# duplication reading as a bug.
static func overall_heading(done: int) -> String:
	if done <= 1:
		return "OVERALL — stage 1 only"
	var parts: PackedStringArray = []
	for i in done:
		parts.append(str(i + 1))
	return "OVERALL — stages %s" % " + ".join(parts)


static func visible_rows(rows: Array, top: int = PODIUM_ROWS) -> Array:
	var player_index := -1
	for i in rows.size():
		if bool(rows[i].get("is_player", false)):
			player_index = i
	var out: Array = []
	for i in mini(top, rows.size()):
		out.append(rows[i])
	if player_index >= top:
		if player_index > top:
			out.append({"gap": true})
		out.append(rows[player_index])
	return out


func _build_ui() -> void:
	for c in get_children():
		c.queue_free()
	# Every child just went; drop the page-1 / page-2 handles with them so nothing
	# below reasons about a node that is on its way out.
	_root_box = null
	_global_page = null

	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.name = "Background"
	# ...AND_OFFSETS_: plain set_anchors_preset defaults to keep_offsets = true,
	# which preserves the rect the node already has — and a fresh ColorRect's rect
	# is 0x0, so the backdrop would never cover anything.
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
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
	_root_box = root

	var done := RallySession.events_completed()

	# No screen title / rally-name subtitle: the two section headings ("STAGE n
	# RESULT" and "OVERALL") already say what each list is, and the player knows
	# which rally they're in. Those two lines cost enough vertical space to push the
	# second leaderboard below the fold on a phone, which is worse than any context
	# they added.

	# This page ALWAYS leads to the global leaderboard now — the reward (when there
	# is one) is collected from page 2, after the player has seen where they placed
	# in the world. So the label is unconditional: it names page 2 and nothing else,
	# because page 2 is the only thing this button ever does.
	var button_text := "Online leaderboard >"

	var scroll := TouchScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	# Build every row up front but hidden, then reveal them P1-down one at a
	# time so the leaderboard fills in dramatically (see _reveal_standings).
	# BOTH sections show on every stage, including the first — where the two lists are
	# necessarily identical (one stage's time IS the combined time). That duplication
	# is deliberate: the screen keeps the same shape from stage 1 to stage 3, so the
	# player learns where to look once instead of having the layout change under them.
	var row_nodes: Array[Control] = []
	row_nodes.append_array(_add_section(content, "STAGE %d RESULT" % done,
		RallySession.current_event_standings()))
	row_nodes.append_array(_add_section(content, overall_heading(done),
		RallySession.current_standings()))

	# The action row sits side by side rather than stacked: two full-width buttons
	# eat a leaderboard row's worth of height each, and this screen is tight enough
	# that the second list was scrolling off. Geometry gives MenuNav left/right
	# between them for free (find_valid_focus_neighbor).
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)

	# Watch Replay sits on the LEFT and the forward action on the RIGHT, so the
	# button that advances the rally is where the eye ends up.
	if overlay_mode:
		var hide_btn := Button.new()
		hide_btn.text = "Watch Replay"
		hide_btn.focus_mode = Control.FOCUS_ALL
		hide_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hide_btn.pressed.connect(toggle_leaderboard)
		actions.add_child(hide_btn)

	var cont := Button.new()
	cont.text = button_text
	cont.focus_mode = Control.FOCUS_ALL
	cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cont.pressed.connect(_on_action)
	actions.add_child(cont)
	_action_button = cont

	UITheme.enforce(self)  # house rules: uppercase + one font size
	# Framework wires focus + WASD/arrow/gamepad nav and routes back (see
	# features/menus.md → MenuNav). Re-run each _build_ui so the fresh button is
	# picked up; attach() reuses the existing node rather than stacking handlers.
	#
	# ATTACHED TO `root`, NOT `self`. MenuNav goes inert while its ROOT is hidden
	# (MenuNav._menu_visible), and page 2 replaces this page by hiding `root` — so
	# the nav must hang off the thing that gets hidden. Attached to `self` it
	# stayed live behind page 2 and both navs consumed the same Back press.
	MenuNav.attach(root, {first = cont, on_back = _on_back_pressed})

	if not Platform.is_headless():
		_reveal_standings(row_nodes)


# One leaderboard block: a heading plus its trimmed rows. Returns the nodes in
# reveal order (the heading first), which the caller concatenates so the two
# sections fill in top-to-bottom as one continuous sequence.
func _add_section(parent: VBoxContainer, heading: String, rows: Array) -> Array[Control]:
	var built: Array[Control] = []
	if parent.get_child_count() > 0:
		# Breathing room between the two stacked leaderboards. Always visible (it is
		# blank) so the reveal doesn't shuffle the layout as rows appear.
		var spacer := Control.new()
		spacer.custom_minimum_size.y = 12.0
		parent.add_child(spacer)
	var head := UITheme.label(heading, "dim")
	parent.add_child(head)
	built.append(head)
	for entry in visible_rows(rows):
		var row: Control
		if bool(entry.get("gap", false)):
			# The cut between the podium and the player's own position.
			row = UITheme.label("...", "dim")
		else:
			row = UITheme.standings_row(entry)
		parent.add_child(row)
		built.append(row)
	if not Platform.is_headless():
		for node in built:
			node.visible = false
	return built


# Reveal leaderboard rows from P1 downward, one every REVEAL_STEP seconds,
# starting from an empty list. Guarded by _reveal_gen so a rebuild (page
# toggle / rebuild) mid-reveal abandons the coroutine without touching freed nodes.
func _reveal_standings(rows: Array) -> void:
	_reveal_gen += 1
	var gen := _reveal_gen
	for row in rows:
		await get_tree().create_timer(REVEAL_STEP).timeout
		if gen != _reveal_gen:
			return
		if is_instance_valid(row):
			row.visible = true


# The button advances. There is no branch here any more: page 1 always leads to
# the global leaderboard, and the reward is collected one page later.
func _on_action() -> void:
	_advance()


# THE SOLE EXIT from this screen, and a strict three-step ladder. Every route off
# the interstitial funnels through here — page 1's button, page 2's button, and
# the upgrade reveal's `finished` — so `continue_to_next_event()` has exactly one
# call site and is reached exactly once per stage, whatever the stage awarded.
#
#   1st call (page 1's button)     -> show page 2, the global stage leaderboard.
#   2nd call (page 2's button)     -> collect the reward, if this stage drew one.
#   final call (the reveal, or the
#   2nd call on a stage with no
#   reward)                        -> resume: next stage, or the podium.
#
# ORDER: local standings -> world standings -> reward. The reward is the payoff
# and it goes last; a reveal card in the middle used to bury the world board
# behind it. The final stage draws no upgrade (RallySession only awards on
# non-final events), so _reward_pending() is false there and it goes straight
# from page 2 to the podium with no empty reveal step.
func _advance() -> void:
	if not _global_shown:
		_global_shown = true
		_show_global_page()
		return
	if _reward_pending():
		_collect_reward()
		return
	RallySession.continue_to_next_event()


# Page 2 REPLACES page 1's content: hiding the root VBox takes the parent's
# MenuNav inert along with it (MenuNav._unhandled_input is gated on its root being
# visible), so the child's is the only live nav and the two cannot race on Back.
func _show_global_page() -> void:
	var opts := GlobalStandings.for_current_stage()
	# Back is now offered on EVERY stage. Page 2 comes BEFORE the reward, so page 1
	# is always still intact behind it — the old "no Back after a reward, because
	# page 1 was torn down for the reveal card" special case is gone with the
	# reordering, and the screen behaves the same whatever the stage awarded.
	var have_page_one := is_instance_valid(_root_box)
	opts["show_back"] = have_page_one
	opts["overlay_mode"] = overlay_mode
	# Page 2's button names what happens NEXT, which is now the reward when this
	# stage drew one — the reveal sits between page 2 and resuming.
	if _reward_pending():
		opts["continue_text"] = "Collect reward >"
	elif RallySession.events_completed() >= RallySession.EVENTS_PER_RALLY:
		opts["continue_text"] = "Continue to podium >"
	else:
		opts["continue_text"] = "Continue to next stage >"

	if have_page_one:
		_root_box.visible = false

	_global_page = GlobalStandings.new()
	_global_page.name = "GlobalStandings"
	_global_page.configure(opts)
	_global_page.continued.connect(_advance)
	_global_page.back_pressed.connect(_on_global_back)
	add_child(_global_page)


func _on_global_back() -> void:
	if is_instance_valid(_global_page):
		_global_page.queue_free()
	_global_page = null
	# Allow page 2 to be reached again from the restored Continue — Back means
	# "let me re-read the local standings", not "skip the global board".
	_global_shown = false
	if is_instance_valid(_root_box):
		_root_box.visible = true
	# Re-grab focus on Continue. attach() reuses the existing MenuNav rather than
	# stacking handlers, and the row reveal deliberately does NOT re-run: the rows
	# are already built and visible, and re-playing a board the player has read is
	# noise.
	if is_instance_valid(_root_box) and is_instance_valid(_action_button):
		MenuNav.attach(_root_box, {first = _action_button, on_back = _on_back_pressed})


# Take over the screen with the reward reveal (same card as the podium). This is
# now the LAST step of the interstitial, reached from page 2 rather than page 1:
# the player has read both leaderboards and the reward is the payoff. The reveal's
# own Upgrades/Next row (UpgradeReveal._show_actions) is the only "I'm done"
# affordance — pressing Next resolves `finished`, which resumes the rally.
func _collect_reward() -> void:
	_reward_collected = true  # so _reward_pending() is false once we continue
	for c in get_children():
		c.queue_free()
	# Page 1 AND page 2 are gone; the reveal card owns the screen. _global_shown
	# stays true, so when the reveal finishes _advance() falls through to resuming
	# rather than building the world board a second time.
	_root_box = null
	_global_page = null
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.name = "Background"
	# ...AND_OFFSETS_: plain set_anchors_preset defaults to keep_offsets = true,
	# which preserves the rect the node already has — and a fresh ColorRect's rect
	# is 0x0, so the backdrop would never cover anything.
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(UITheme.BLACK, 0.0) if overlay_mode else UITheme.BLACK
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

	_reveal = UpgradeReveal.new()
	_reveal.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_reveal)
	_action_button = null

	# NOT connected straight to RallySession.continue_to_next_event. Every route off
	# this screen funnels through _advance() so there is exactly ONE call site for
	# resuming the rally; by the time this fires, page 2 has been seen and the
	# reward collected, so _advance() falls through to that single call.
	_reveal.finished.connect(_advance, CONNECT_ONE_SHOT)
	_reveal.reveal(RallySession.current_event_upgrade(), RallySession.car_instance_id())


# Back (keyboard/gamepad, via MenuNav on_back): the interstitial is a single page
# mid-rally, so there is nowhere to go back TO — the press is consumed and ignored
# rather than falling through to whatever is behind (pause / the replay host).
func _on_back_pressed() -> void:
	pass


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

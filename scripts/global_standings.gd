class_name GlobalStandings
extends Control
# PAGE 2 of the between-event interstitial: how the player's time for THIS ONE
# STAGE ranks against every other player in the world.
# (docs/superpowers/specs/2026-07-31-global-leaderboards-design.md §5 + §6,
# features/menus.md.)
#
# Shown by Standings._advance() after the combined local standings, as a sibling
# that REPLACES page 1's content — page 1's root VBox is hidden, so only this
# page's MenuNav is live and the two cannot race on a Back press.
#
# NOTHING HERE MAY BLOCK A RALLY. The page always renders and its Continue is
# live from the very first frame, in every state including "the network is gone".
# A fetch failure of any kind (offline, timeout, 5xx, 429, unparseable) lands in
# one dim UNAVAILABLE line — the same degradation contract as the rest of cloud
# save.
#
# The page never talks to RallySession: the host owns advancing (see `continued`).
# That keeps the dependency direction cloud save was built around — the rally
# flow behaves identically whether or not this page exists.

# The player pressed Continue: the HOST advances the rally, not this page.
signal continued()
# The player pressed Back: the host re-shows page 1 and frees this page.
signal back_pressed()

enum State { LOADING, SIGNED_OUT, NO_USERNAME, POSTED, UNAVAILABLE }


# --- Host-set configuration (all set by configure() before the page is added) ---
var stage_key := ""
var stage_number := 1
var time_ms := 0
var car_name := ""
var car_id := ""
var show_back := true
var continue_text := "Continue to next stage >"
var overlay_mode := false

# Test / host seam. When set, this Callable is used in place of
# Cloud.leaderboard.submit_and_fetch — it takes (stage_key, time_ms, row) and
# returns the same result dict. Headless runs with no fetcher go straight to
# UNAVAILABLE rather than reaching for the network.
var fetcher: Callable = Callable()

var _state: int = State.LOADING
var _rows: Array = []      # the assembled display list (standings_row dicts + gap markers)
var _total := 0            # how many times are posted on this board at all
var _rank := 0             # the player's world rank, 0 when they have not posted
var _signed_in := false    # as of the last fetch (or Cloud, when there wasn't one)
var _continue_button: Button = null
var _action_button: Button = null   # the state's extra affordance (sign in / choose a name)
var _account_overlay: CanvasLayer = null


# Build the opts for the stage that just finished. Kept here (rather than in
# standings.gd) so everything the page needs to know about the rally is gathered
# in one place, and the host stays a two-line hand-off.
static func for_current_stage() -> Dictionary:
	var done: int = RallySession.events_completed()
	var event_index := done - 1
	var rally: Dictionary = RallyLibrary.by_id(RallySession.rally_id())
	var key := ""
	if event_index >= 0 and not rally.is_empty():
		key = RallyLibrary.stage_key(rally, event_index)
	# The player's own row from the local stage leaderboard already carries the
	# corrected garage car name (RallySession._player_car_name) and the bare model
	# id, so the two boards can never disagree about what the player was driving.
	var mine: Dictionary = {}
	for entry in RallySession.current_event_standings():
		if bool(entry.get("is_player", false)):
			mine = entry
	return {
		"stage_key": key,
		"stage_number": maxi(done, 1),
		"time_ms": int(mine.get("combined_ms", -1)),
		"car_name": String(mine.get("car_name", "")),
		"car_id": String(mine.get("car_id", "")),
		"dnf": bool(mine.get("dnf", false)),
	}


func configure(opts: Dictionary) -> void:
	stage_key = String(opts.get("stage_key", stage_key))
	stage_number = int(opts.get("stage_number", stage_number))
	time_ms = int(opts.get("time_ms", time_ms))
	car_name = String(opts.get("car_name", car_name))
	car_id = String(opts.get("car_id", car_id))
	show_back = bool(opts.get("show_back", show_back))
	continue_text = String(opts.get("continue_text", continue_text))
	overlay_mode = bool(opts.get("overlay_mode", overlay_mode))
	# A DNF has no time to rank, so there is nothing to post and no board row of
	# the player's own — the page still shows the world's top times.
	if bool(opts.get("dnf", false)):
		time_ms = -1


func _ready() -> void:
	# Sets anchors AND offsets explicitly rather than relying on a fresh Control's
	# offsets already being zero. Equivalent here (set_anchors_preset defaults to
	# keep_offsets = false, so the plain call was NOT the blank-page bug), but it
	# states the intent instead of depending on a default, and it matches the idiom
	# the rest of the codebase uses for a code-built full-rect Control
	# (settings_menu.gd, upgrade_reveal.gd, start_line.gd).
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	_refresh()


# --- Fetch --------------------------------------------------------------------

# Submit-if-faster then fetch, and repaint with whatever came back. Re-runnable:
# a successful sign-in from this page calls it again so the player posts the time
# they just set without re-driving the stage.
func _refresh() -> void:
	_state = State.LOADING
	_build_ui()

	var use_injected := fetcher.is_valid()
	if not use_injected \
			and (Platform.is_headless() or Cloud == null or Cloud.leaderboard == null):
		_land(State.UNAVAILABLE, {})
		return
	if stage_key == "":
		_land(State.UNAVAILABLE, {})
		return

	# Leaderboard.submit_and_fetch degrades to a plain read on its own when the
	# player is signed out, has no name, or has no time — so the identity is
	# always passed and the decision lives in one place, not two.
	var username := UsernamePopup.current()
	var identity := {"name": username, "car_name": car_name, "car_id": car_id}

	# THE LIVE CALL IS DIRECT, not through a Callable.
	#
	# `submit_and_fetch` is a coroutine. Awaiting it through `some_callable.call()`
	# is not the same construct as awaiting the method: the compiler can only emit a
	# proper suspend-and-resume when it can see it is calling a coroutine, and a
	# Callable invocation is resolved at runtime. Routing the real path through the
	# same Callable seam the tests inject was the one piece of this page that NO
	# test exercised — the injected test fetchers are plain synchronous lambdas, for
	# which `await callable.call()` behaves perfectly. So the tests could not have
	# caught a difference in that machinery, and the live path is the only place it
	# mattered. It is spelled out as two branches for exactly that reason.
	var raw: Variant
	if use_injected:
		raw = await fetcher.call(stage_key, time_ms, identity)
	else:
		raw = await Cloud.leaderboard.submit_and_fetch(stage_key, time_ms, identity)
	if not is_instance_valid(self) or not is_inside_tree():
		return  # the page went away mid-flight (scene torn down / Back pressed)

	# Deliberately NOT `var result: Dictionary = await ...`. A typed assignment of
	# anything non-Dictionary raises and ABORTS this function mid-flight, which
	# leaves the page parked in whatever state it was already showing with no error
	# path and no repaint — the exact "stuck forever" shape being fixed here. Take
	# it as a Variant and degrade to UNAVAILABLE instead, so every outcome, however
	# malformed, still lands somewhere that repaints.
	var result: Dictionary = raw if raw is Dictionary else {}
	# ok == false IS the unavailable state: offline, timeout, 5xx, 429 and a parse
	# failure all arrive the same way, and every other field is meaningless then.
	if not bool(result.get("ok", false)):
		_land(State.UNAVAILABLE, {})
		return
	if not bool(result.get("signed_in", false)):
		_land(State.SIGNED_OUT, result)
	elif username == "":
		_land(State.NO_USERNAME, result)
	else:
		_land(State.POSTED, result)


func _land(state: int, result: Dictionary) -> void:
	_state = state
	# On UNAVAILABLE there is no result to read this from, and the answer still
	# matters: it decides which of the two prompts to offer (see _prompt_kind).
	_signed_in = bool(result.get("signed_in", Cloud != null and Cloud.is_signed_in()))
	_total = int(result.get("total", 0))
	_rank = int(result.get("player_rank", 0))
	# Assembly (top rows, the {"gap": true} marker, the player's own row) is
	# Leaderboard.display_rows — a pure static, tested next to the fetch that
	# produces its input. Deliberately NOT Standings.visible_rows, which needs the
	# COMPLETE ranked field the top-3-plus-aggregate fetch never has.
	_rows = Leaderboard.display_rows(result.get("rows", []), result.get("player_row", {}))
	_build_ui()


# --- Building -----------------------------------------------------------------

# Which prompt (if any) stands between this player and a posted time:
#   "signin" — not signed in, so there is no document to write.
#   "name"   — signed in but profile["username"] is still blank. The cloud layer
#              treats a blank name as "read only, write nothing", SILENTLY — so
#              this button is the ONLY thing that ever gets a time onto the board
#              for such a player. It must never be conditional on anything else.
#   ""       — nothing in the way (or nothing to post: a DNF has no time).
func _prompt_kind() -> String:
	if _state == State.LOADING or time_ms <= 0:
		return ""
	if not _signed_in:
		return "signin"
	if UsernamePopup.current() == "":
		return "name"
	return ""


func _build_ui() -> void:
	for c in get_children():
		if c == _account_overlay:
			continue
		remove_child(c)
		c.queue_free()
	_continue_button = null
	_action_button = null

	var bg := ColorRect.new()
	bg.name = "Background"
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(UITheme.BLACK, 0.0) if overlay_mode else UITheme.BLACK
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var root := VBoxContainer.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 16.0
	root.offset_top = 16.0
	root.offset_right = -16.0
	root.offset_bottom = -16.0
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	root.add_child(UITheme.label("Online leaderboard — stage %d" % stage_number, "dim"))

	# Only the RANKED ROWS go inside the scroll. The status line below goes straight
	# onto `root`, outside it, on purpose: a ScrollContainer clips, so anything put
	# inside one can be swallowed whole by a layout fault without a single node
	# reporting itself hidden. Keeping one always-present line outside the clipping
	# node is what makes "this page can never show an empty body" structural rather
	# than a thing the tests have to keep catching.
	var scroll := TouchScrollContainer.new()
	scroll.name = "Rows"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content)
	_build_rows(content)

	# Unconditional, and built here at construction time before any async work: in
	# EVERY state, including the very first frame before the fetch has been sent,
	# this page says something about the board.
	var status := UITheme.label(_status_line(), "dim")
	status.name = "Status"
	root.add_child(status)

	# The prompt sits on its OWN full-width row above the actions: page 1 already
	# established that three buttons don't fit one row.
	#
	# It is driven by _prompt_kind, NOT by the board state, so that a player who
	# still needs to sign in or pick a name is offered the way to do it EVEN WHEN
	# THE BOARD FAILED TO LOAD. Gating it on a successful fetch created a
	# chicken-and-egg trap: the very first player on a brand-new board can be the
	# one whose read fails, and they would then never be prompted, so they would
	# never post, so the board would stay empty.
	match _prompt_kind():
		"signin":
			_action_button = _wide_button("Sign in to post time", _on_sign_in_pressed)
			root.add_child(_action_button)
		"name":
			_action_button = _wide_button("Choose a name to post", _on_choose_name_pressed)
			root.add_child(_action_button)

	# Back on the LEFT, the forward action on the RIGHT, so the button that
	# advances the rally is where the eye ends up (page 1's convention).
	# In overlay mode Watch Replay stays on page 1 only.
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	root.add_child(actions)
	if show_back:
		var back := Button.new()
		back.text = "< Back"
		back.focus_mode = Control.FOCUS_ALL
		back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		back.pressed.connect(_on_back)
		actions.add_child(back)
	var cont := Button.new()
	cont.text = continue_text
	cont.focus_mode = Control.FOCUS_ALL
	cont.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cont.pressed.connect(_on_continue)
	actions.add_child(cont)
	_continue_button = cont

	UITheme.enforce(self)  # house rules: uppercase + one font size
	# Keyboard + gamepad, the same framework page 1 uses. attach() reuses the
	# existing node rather than stacking handlers across rebuilds.
	#
	# The cursor lands on the PROMPT when there is one, and on Continue otherwise.
	# A prompt the player has to spot and aim at is a prompt most players skip
	# past — and skipping it here means their time is never posted at all, with no
	# error and nothing to notice. Seating the cursor on it makes it the default
	# action for a keyboard and a gamepad; Continue is still a single press away.
	var seat: Control = _action_button if _action_button != null else cont
	MenuNav.attach(self, {first = seat, on_back = _on_back})


# The RANKED ROWS, and nothing else — every node added visible. Empty is a legal
# outcome here (a brand-new board, a failed fetch); _status_line is what guarantees
# the page still says something, and it lives outside the clipping scroll.
func _build_rows(content: VBoxContainer) -> void:
	if _state == State.LOADING or _state == State.UNAVAILABLE:
		return
	for entry in _rows:
		if bool(entry.get("gap", false)):
			content.add_child(UITheme.label("...", "dim"))
		else:
			content.add_child(UITheme.standings_row(entry))


# The one line this page ALWAYS shows, in every state, outside the ScrollContainer.
# Never returns "": a blank return here would put the page back in the state that
# has now been reported twice.
func _status_line() -> String:
	match _state:
		State.LOADING:
			return "Loading…"
		State.UNAVAILABLE:
			# No popup, no retry loop, nothing blocked — a lost board must never cost
			# a player their rally.
			return "Online leaderboard unavailable"
		_:
			pass
	if _rows.is_empty():
		# Say the total anyway: "no times posted yet" and "you are 300th of 312 but
		# the rows failed to map" are very different things to a player.
		return "No times posted yet — %d times posted" % _total if _total > 0 \
			else "No times posted yet"
	# The total shows in every successful state, signed out included: it is the one
	# number that says whether an empty-looking board is empty or just above you.
	if _state == State.POSTED and _rank >= 1:
		return "P%d of %d times posted" % [_rank, _total]
	return "%d times posted" % _total


func _wide_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, UITheme.MENU_ROW_H)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(on_press)
	return b


# --- Actions ------------------------------------------------------------------

func _on_continue() -> void:
	continued.emit()


func _on_back() -> void:
	if not show_back:
		return  # nowhere to go back TO; swallow rather than falling through
	back_pressed.emit()


func _on_choose_name_pressed() -> void:
	var popup := UsernamePopup.open(self)
	popup.finished.connect(func(name: String) -> void:
		if name != "":
			_refresh()
		else:
			UITheme.focus_grab(_continue_button))


# Sign in without leaving the page: the AccountMenu opens as an overlay (a third
# host beside Settings and the title screen), and on success the page re-runs
# submit-and-fetch in place — the player does not lose the time they just set.
func _on_sign_in_pressed() -> void:
	if _account_overlay != null:
		return
	var layer := CanvasLayer.new()
	layer.layer = 100
	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = UITheme.BLACK
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	layer.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UITheme.GAP)
	margin.add_child(column)
	var account := AccountMenu.new()
	account.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(account)
	var close := _wide_button("< Back to online leaderboard", _close_account_overlay)
	column.add_child(close)
	add_child(layer)
	_account_overlay = layer
	UITheme.enforce(layer)
	# The overlay's own nav is the only live one while it is up: this page's
	# MenuNav goes inert because a CanvasLayer over it doesn't hide it — so route
	# Back here explicitly, and let the account page own the rest.
	MenuNav.attach(margin, {"on_back": func() -> void:
		if not account.go_back():
			_close_account_overlay()})


func _close_account_overlay() -> void:
	if _account_overlay == null:
		return
	_account_overlay.queue_free()
	_account_overlay = null
	# Signed in? Re-run submit-and-fetch so the just-set time posts. Signed out
	# still, or cancelled? _refresh simply repaints the same signed-out board.
	_refresh()


# --- Introspection (hosts + tests) ---------------------------------------------

func state() -> int:
	return _state


func rows() -> Array:
	return _rows

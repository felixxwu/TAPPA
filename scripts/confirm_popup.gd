# scripts/confirm_popup.gd
class_name ConfirmPopup
extends CanvasLayer
# Reusable on-brand confirm modal: dim mouse-consuming backdrop + centred house
# panel with a title, an autowrap body, and one button per action. Each action is
# { "label": String, "callback": Callable, "disabled": bool (optional) }. Pressing
# an action closes the popup then runs its callback; Back routes to back_index
# (default last = the dismiss convention). MenuNav-wired (keyboard + gamepad).
# Named ConfirmPopup, NOT Popup — Godot has a native Popup class.

signal finished()

# ONE MODAL AT A TIME, TREE-WIDE. Every modal in the game is either a ConfirmPopup
# or a UsernamePopup (which joins this same group), and they all sit on layer 101 —
# so two of them on screen at once is never a design, always a bug: the top one
# hides the other, dismissing it "does nothing" except reveal a twin with the focus
# cursor reset.
#
# WHY A GROUP RATHER THAN A FLAG ON THE RAISER. The bug this exists to kill was a
# single Cloud.conflict_detected broadcast reaching two subscribers, each of which
# checked its OWN private "is my prompt up?" bool. Neither latch could see the
# other, so both opened. The question "is a modal already on screen?" has exactly
# one true answer and it belongs to the scene tree, not to any one host — a helper
# that centralises WHAT a modal does while leaving each caller to track WHETHER one
# is up has only half-consolidated the rule. See features/menus.md → "One modal at
# a time" and todo/challenge-career-reuse-drift.md item 10.
const MODAL_GROUP := "modal"

var _actions: Array = []
var _back_index: int = -1
var _buttons: Array[Button] = []
var _body_label: Label = null


# The modal currently on screen anywhere in `tree`, or null when there is none.
#
# SKIPS NODES BEING FREED. ConfirmPopup._dismiss emits `finished` and THEN
# queue_free()s, and a freed node stays in its groups until the end of the frame —
# so a host that re-checks from its own `finished` handler (account_menu.rebuild
# does exactly this) would otherwise be told a modal is still up by the very popup
# that just closed, and be silently refused.
static func any_open(tree: SceneTree) -> Node:
	if tree == null:
		return null
	for n in tree.get_nodes_in_group(MODAL_GROUP):
		var node := n as Node
		if is_instance_valid(node) and not node.is_queued_for_deletion():
			return node
	return null


# host: parent to attach under (its process mode is inherited — a paused host's
# popup still processes). Returns the live popup, or NULL when one is refused —
# callers must not assume a popup came back.
#
# `allow_stack` opts out of the exclusivity rule for the rare modal that must be
# seen even over another one (CloudBusy's failure notice: dropping it silently is
# how a failed sync becomes invisible). Refusals are pushed as warnings rather than
# swallowed — a modal that never appeared is a bug worth hearing about, and there
# is deliberately NO queue: re-showing a modal the player has moved past invents an
# ordering nobody asked for.
static func open(host: Node, title: String, body: String, actions: Array,
		default_index := 0, back_index := -1, allow_stack := false) -> ConfirmPopup:
	if not is_instance_valid(host) or not host.is_inside_tree():
		return null
	if not allow_stack:
		var live := any_open(host.get_tree())
		if live != null:
			push_warning("ConfirmPopup '%s' refused: '%s' is already on screen." % [
				title, live.get_meta("modal_title", "another modal")])
			return null
	var popup := ConfirmPopup.new()
	popup._actions = actions
	# Back defaults to the FIRST action, because the house button order puts the
	# exit/cancel action leftmost and the proceeding action rightmost (see
	# features/menus.md "Button order"). This default USED to be the last action, which
	# was correct only while dismiss sat on the right — leaving it there after the
	# reorder would route Esc / gamepad-B to the CONFIRMING button, i.e. Escape would
	# abandon a rally or overwrite a career. Single-action popups are unaffected (first
	# and last are the same button).
	popup._back_index = back_index if back_index >= 0 else 0
	host.add_child(popup)
	popup._build(title, body, default_index)
	return popup

# RESERVE THE SCREEN, THEN COMMIT. For the "do an irreversible thing and tell the
# player what happened" shape — open a mystery box, grant a challenge reward — where
# doing it first and presenting second is a silent data loss: `open` REFUSES while
# another modal is up (see MODAL_GROUP), so the transaction lands and its one and only
# reveal is dropped. This inverts the order so that state is unrepresentable: the modal
# slot is acquired FIRST, and `commit` runs only once the popup that will report it is
# already on screen. If the slot cannot be had, `commit` IS NEVER CALLED and null comes
# back — the caller has mutated nothing and can simply return.
#
# WHY A DEFERRED BODY RATHER THAN "commit returns the text". Because one real caller
# (world.gd's challenge reward) must `await` its mutation, a synchronous
# "Callable -> String" contract can't express it. So the popup is built with
# `placeholder` and the body is filled in afterwards: `commit` may be a plain function
# OR a coroutine, its return value is awaited either way, and if it hands back a
# non-empty String that becomes the body. A commit that needs to compose the body from
# several steps (or emit no string at all) can instead call `popup.set_body(...)` on
# the popup it is passed. `open_committing` is therefore itself a coroutine — call it
# as `await ConfirmPopup.open_committing(...)`.
#
# `commit` is called with the live popup as its single argument, so it can set the body,
# read the popup, or ignore it (a zero-arg Callable is accepted too).
#
# Deliberately NO `allow_stack`: the whole point is the refusal, and a commit that is
# allowed to stack over another modal has no reason to use this entry point.
static func open_committing(host: Node, title: String, placeholder: String,
		actions: Array, commit: Callable, default_index := 0,
		back_index := -1) -> ConfirmPopup:
	if not commit.is_valid():
		push_warning("ConfirmPopup.open_committing('%s') needs a valid commit callable." % title)
		return null
	var popup := open(host, title, placeholder, actions, default_index, back_index)
	if popup == null:
		return null  # slot refused -> the mutation deliberately does not run
	var produced: Variant = null
	if commit.get_argument_count() > 0:
		produced = await commit.call(popup)
	else:
		produced = await commit.call()
	# An awaited commit gives the player time to dismiss the popup first, so it may be
	# gone by now — the mutation still happened and was still reported, which is the
	# guarantee; there is simply nothing left to write to.
	if not is_instance_valid(popup) or popup.is_queued_for_deletion():
		return null
	if produced is String and not String(produced).is_empty():
		popup.set_body(String(produced))
	return popup


# Replace the body text of a live popup. Used by open_committing to fill in the
# placeholder once the mutation it reserved the screen for has completed; safe to call
# on a popup the player has already dismissed (it simply does nothing).
func set_body(text: String) -> void:
	if is_instance_valid(_body_label):
		_body_label.text = text


func _build(title: String, body: String, default_index: int) -> void:
	layer = 101  # above overlays
	add_to_group(MODAL_GROUP)  # see MODAL_GROUP — one modal at a time, tree-wide
	set_meta("modal_title", title)  # named in the refusal warning above

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = UITheme.MODAL_DIM
	dim.mouse_filter = Control.MOUSE_FILTER_STOP  # swallow taps so nothing falls through
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel := UITheme.panel(1.0, 20)
	center.add_child(panel)

	# ADAPTIVE WIDTH. 420 is the house default, but on a narrow/portrait aspect
	# (see DisplayStretch — width follows device aspect and can get much narrower
	# than 420) a fixed 420 forces the panel wider than the screen. Clamp against the current
	# logical viewport width, with a little breathing room on each side.
	# Fallback mirrors GameConfig.virtual_resolution (scripts/game_config.gd), the real
	# source of truth for the design resolution. Config.data is populated by the Config
	# autoload before any runtime scene (this popup included) can be built, so it's safe
	# to read here; the literal only remains as a last-resort guard in case Config.data
	# is ever null (e.g. a stripped-down test harness with no autoloads).
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size \
		if get_viewport() != null else (Config.data.virtual_resolution if Config.data != null else Vector2(480, 360))
	const SIDE_MARGIN := 32.0
	const MIN_PANEL_WIDTH := 200.0
	var panel_width: float = clampf(420.0, MIN_PANEL_WIDTH,
		maxf(viewport_size.x - SIDE_MARGIN, MIN_PANEL_WIDTH))

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", UITheme.GAP)
	vbox.custom_minimum_size = Vector2(panel_width, 0)
	panel.add_child(vbox)

	vbox.add_child(UITheme.title(title))

	var body_label := Label.new()
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body_label.text = body
	body_label.custom_minimum_size = Vector2(panel_width, 0)
	body_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# PIN THE WRAP WIDTH. An autowrapped Label's minimum width is a single character, and
	# a ScrollContainer hands its child that minimum rather than stretching it — so
	# without this the body collapsed to one column and wrapped after EVERY LETTER
	# ("A" / "B" / "A" …) with a scrollbar beside it. It must be the same width the
	# height measurement below wraps at, or the measured height describes a different
	# layout than the one on screen.
	_body_label = body_label

	# SCROLLING BODY, BUTTONS PINNED. The buttons are the only way to dismiss a
	# ConfirmPopup by touch (no touch back — trigger_back is reachable only from
	# ui_cancel/menu_back), and its dim backdrop swallows taps, so a long body
	# (server error text, a computed multi-line reward) must never be able to
	# push them off the bottom of the screen. TouchScrollContainer is the house
	# scroll widget (see hq_overlays.gd / pause_menu.gd / standings.gd); the
	# buttons stay OUTSIDE it in `row` below so focus never has to enter the
	# scroll at all.
	var scroll := TouchScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(body_label)
	vbox.add_child(scroll)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.GAP)
	vbox.add_child(row)
	_buttons = []
	for i in _actions.size():
		var a: Dictionary = _actions[i]
		var b := Button.new()
		b.text = String(a.get("label", ""))
		b.focus_mode = Control.FOCUS_ALL
		b.disabled = bool(a.get("disabled", false))
		b.pressed.connect(_on_action.bind(i))
		row.add_child(b)
		_buttons.append(b)

	# UITheme.enforce must run BEFORE the height measurement below: it sets the
	# real rendered font size on title/body/buttons, and the measurement needs
	# that final size to be accurate.
	UITheme.enforce(self)

	# SHOW ALL THE TEXT. The scroll must be given the body's true wrapped height
	# or it collapses to ~0 (a ScrollContainer reports no minimum on the axis it
	# scrolls) and the message is hidden behind a scrollbar. UITheme.fit_body_scroll
	# owns that measurement — including the re-fit once the Label has a real width,
	# which is also what keeps set_body() (open_committing's deferred body) honest.
	# It caps against the viewport as a last resort only; a normal body never scrolls.
	UITheme.fit_body_scroll(scroll, body_label, panel_width)

	# first may be null when every action is disabled — MenuNav simply seats no
	# cursor, which is the intended behaviour (nothing to focus).
	var first := _pick_first(default_index)
	MenuNav.attach(center, {"first": first, "on_back": trigger_back})

func _pick_first(default_index: int) -> Control:
	if default_index >= 0 and default_index < _buttons.size() \
			and not _buttons[default_index].disabled:
		return _buttons[default_index]
	for b in _buttons:
		if not b.disabled:
			return b
	return null

func _on_action(index: int) -> void:
	var cb: Callable = _actions[index].get("callback", Callable())
	_dismiss()
	if cb.is_valid():
		cb.call()

# Route Back / cancel to the configured action (default: the last one).
func trigger_back() -> void:
	if _back_index >= 0 and _back_index < _actions.size():
		_on_action(_back_index)
	else:
		_dismiss()

func _dismiss() -> void:
	finished.emit()
	queue_free()

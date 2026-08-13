class_name MenuNav
extends Node
# THE FLAT-MENU NAVIGATION FRAMEWORK. Attach one of these to a flat overlay / panel
# menu and it handles ALL of the keyboard + gamepad interoperability so the menu
# author doesn't have to remember (and can't forget) the per-widget wiring. See
# features/menus.md → "Menu navigation".
#
# What `attach(root, opts)` does, once:
#   1. FOCUS — walks `root`'s descendants and makes every interactive Control
#      (BaseButton / Slider / anything already FOCUS_ALL) keyboard/gamepad
#      focusable, so Godot's native focus cursor can land on it. A node can opt
#      OUT by setting the `menu_nav_skip` meta (used by the diegetic HQ station
#      buttons, which keep FOCUS_NONE so left/right can drive the 3D car instead).
#   2. GRAB — defers a guarded focus grab onto `opts.first` (or the first
#      focusable descendant), and re-grabs whenever `root` becomes visible again,
#      so the cursor is never "dead until you click" and survives a menu re-show.
#   3. WASD — fills the one gap in Godot's defaults: the native ui_up/down/left/
#      right actions bind arrows + D-pad + left-stick but NOT WASD. This node
#      translates the game's menu_up/down/left/right actions (which bind W/A/S/D)
#      into focus-neighbour moves. Native ui_* still consumes arrows/stick/D-pad
#      in the GUI phase BEFORE _unhandled_input, so only the WASD presses actually
#      reach here — no double-movement, and no fragile project.godot surgery.
#   4. BACK — routes ui_cancel AND menu_back (Esc / gamepad B) to `opts.on_back`
#      if given. Omit it and the host keeps full control of back (e.g. a menu with
#      a bespoke toggle handler); nothing is forced.
#
# opts keys (all optional):
#   first   : Control  — where the cursor lands on open / re-show. Defaults to the
#                        first focusable descendant in tree order.
#   on_back : Callable — invoked on ui_cancel / menu_back. If null, back is left
#                        to the host.
#
# Idempotent: attaching twice to the same root reuses the existing node (updates
# its first/on_back) rather than stacking handlers.

const _NODE_NAME := "__MenuNav"

var _root: Control
var _first: Control
var _on_back: Callable


# Attach (or reconfigure) the framework on a flat menu. `root` is the container
# whose descendants form the menu (an overlay Control, a panel, the menu scene
# root). Returns the MenuNav node so callers can hold a reference.
static func attach(root: Control, opts: Dictionary = {}) -> MenuNav:
	if not is_instance_valid(root):
		return null
	var nav: MenuNav = null
	# Reuse an existing, live MenuNav on this root so a second attach() (e.g. a
	# menu that rebuilds its UI) doesn't stack duplicate input handlers.
	for child in root.get_children():
		if child is MenuNav and not child.is_queued_for_deletion():
			nav = child
			break
	if nav == null:
		nav = MenuNav.new()
		nav.name = _NODE_NAME
		root.add_child(nav)
	nav._root = root
	nav._on_back = opts.get("on_back", Callable())
	nav._make_focusable(root)
	nav._enable_scroll_follow(root)
	nav._first = opts.get("first", null)
	if nav._first == null:
		nav._first = UITheme.first_focusable(root)
	# Grab focus after the host finishes showing/laying out the menu.
	#
	# `grab: false` opts out, for a menu that REBUILDS ITSELF while parked out of
	# sight. UITheme.focus_grab only checks the Control chain, and a Control
	# inside a hidden CanvasLayer still reports is_visible_in_tree() == true, so
	# an unguarded re-attach yanks the cursor off whatever is actually on screen
	# (the account page did this to the HQ title screen). Default stays true:
	# most hosts attach once, while hidden, and show immediately after.
	if bool(opts.get("grab", true)):
		UITheme.focus_grab.bind(nav._first).call_deferred()
	# Re-grab whenever the menu is shown again (guarded inside focus_grab).
	if not root.visibility_changed.is_connected(nav._on_root_visibility):
		root.visibility_changed.connect(nav._on_root_visibility)
	return nav


func _on_root_visibility() -> void:
	if is_instance_valid(_root) and _root.is_visible_in_tree():
		UITheme.focus_grab.bind(_first).call_deferred()


# Make every interactive descendant focusable, unless it opted out via the
# `menu_nav_skip` meta. Sliders and buttons are the widgets a flat menu drives.
func _make_focusable(root: Node) -> void:
	for node in root.find_children("*", "BaseButton", true, false):
		_enable(node as Control)
	for node in root.find_children("*", "Slider", true, false):
		_enable(node as Control)
	# Text fields are focusable too, so a form (the account sign-in page) can be
	# filled in with a gamepad / keyboard alone. Handled here rather than at the
	# call site so every future form gets it without remembering to ask.
	for node in root.find_children("*", "LineEdit", true, false):
		_enable(node as Control)


func _enable(c: Control) -> void:
	if c == null or c.has_meta("menu_nav_skip"):
		return
	if c.focus_mode == Control.FOCUS_NONE:
		c.focus_mode = Control.FOCUS_ALL


# Make every ScrollContainer under the menu follow keyboard/gamepad focus: when the
# cursor moves (native ui_* OR our WASD grab_focus) onto a row that's scrolled out of
# view, the list auto-scrolls to reveal it. Without this, directional nav can walk the
# cursor onto rows the user can't see. follow_focus is a no-op when nothing overflows,
# so it's safe to switch on everywhere.
func _enable_scroll_follow(root: Node) -> void:
	for node in root.find_children("*", "ScrollContainer", true, false):
		(node as ScrollContainer).follow_focus = true


# Is `node` actually on screen? Control.is_visible_in_tree() only walks Control
# ancestors, so it MISSES a CanvasLayer ancestor being hidden (how HQ toggles its
# station overlays) — a panel inside a hidden overlay reports itself visible.
# Check all three chains: the Control chain, any CanvasLayer ancestor, AND any
# Node3D ancestor.
#
# THE Node3D CASE IS FOR WorldPanel (world_panel.gd): a menu hosted in a world-space
# panel lives inside a SubViewport whose owning Sprite3D/Node3D chain is what gets
# hidden. Nothing on the Control chain changes when a panel is hidden, and a
# SubViewport is not a CanvasLayer, so without this a hidden world panel would keep
# eating menu_* / ui_cancel — exactly the bug the CanvasLayer clause above exists to
# prevent, one host later.
#
# Static because this is not only MenuNav's problem: anything that grabs focus
# from a panel that might be parked inside a hidden overlay needs the same
# question answered (AccountMenu does, and stole focus from the HQ title screen
# before it asked it).
static func is_on_screen(node: Node) -> bool:
	if not is_instance_valid(node):
		return false
	if node is Control and not (node as Control).is_visible_in_tree():
		return false
	var n: Node = node
	while n != null:
		if n is CanvasLayer and not (n as CanvasLayer).visible:
			return false
		if n is Node3D and not (n as Node3D).is_visible_in_tree():
			return false
		n = n.get_parent()
	return true


func _menu_visible() -> bool:
	return is_on_screen(_root)


# Is the player typing into a text field right now?
#
# Menus are driven by bare letter keys (WASD) and by Esc/B for back, both of
# which a player also has to be able to TYPE. A focused LineEdit consumes
# printable keys in the GUI phase before _unhandled_input, so WASD is safe by
# construction — but Esc is NOT consumed, and any host with its own
# _unhandled_input (hq.gd's station nav, settings_menu.gd's key-rebind capture)
# sees everything regardless. One shared predicate so those hosts all ask the
# same question rather than each inventing a guard.
static func is_text_editing() -> bool:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var vp := (loop as SceneTree).root.get_viewport()
		if vp != null:
			var focused := vp.gui_get_focus_owner()
			return focused is LineEdit or focused is TextEdit
	return false


# SHOULD `node` IGNORE MENU INPUT RIGHT NOW? The one predicate every menu host asks,
# extending the same convention as is_text_editing() above: two different reasons to go
# deaf (the player is typing; a modal owns the screen) that every host would otherwise
# re-invent, half of them forgetting the second one. hq.gd's station nav did exactly
# that — it allowlisted its own two overlays but not ConfirmPopup, so HQ rows still
# fired behind an open popup, which is how a second modal became reachable at all.
#
# THE CARVE-OUT: a node INSIDE the open modal is not blocked by it. The modal builds a
# MenuNav of its own on its centring container (ConfirmPopup._build), and that nav has
# to keep answering Back / directional nav — blocking it would trap the player in a
# popup that no longer responds to anything. So the modal blocks everyone except its
# own subtree.
#
# Order matters: the carve-out is tested BEFORE text editing, so a text field inside a
# modal (UsernamePopup) is left to the caller's own typing rules rather than being
# blanket-blocked here.
static func input_blocked(node: Node) -> bool:
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree != null:
		var modal := ConfirmPopup.any_open(tree)
		if modal == null:
			modal = screen_claimer(tree)
		if modal != null:
			if is_instance_valid(node) and (node == modal or modal.is_ancestor_of(node)):
				return false  # the modal's own widgets keep their input
			return true
	return is_text_editing()


# A FULL-SCREEN OVERLAY THAT IS NOT A ConfirmPopup, but owns the screen just the same.
#
# ConfirmPopup's MODAL_GROUP does double duty: it answers "does something own the screen?"
# AND it enforces one-modal-at-a-time by REFUSING a second open (confirm_popup.gd
# MODAL_GROUP). A modal that legitimately HOSTS confirms — the car park's Change-Upgrades
# page, whose Auto-Upgrade row opens its own ConfirmPopup — cannot join that group without
# refusing its own children, so it needs the first half of the answer without the second.
# Hence a separate group, read here and nowhere else.
#
# WHY IT MATTERS BEYOND NAV: WorldPanel._input claims POINTER events for the panel quad
# unless this predicate says otherwise (world_panel.gd _input). An overlay outside both
# groups therefore rendered on top while the 3D panel underneath quietly ate every click
# that landed inside the quad and marked it handled — the modal was on screen and visibly
# focused, and clicking it did nothing.
#
# Membership is on the overlay's own Control (not its CanvasLayer) so that hiding the page
# releases the claim: hosts keep these pages alive and toggle `visible` (see
# hq_carpark.gd _close_upgrades_popup), and a hidden page must not go on blocking the world.
const SCREEN_CLAIMER_GROUP := "screen_claimer"


static func screen_claimer(tree: SceneTree) -> Node:
	if tree == null:
		return null
	for n in tree.get_nodes_in_group(SCREEN_CLAIMER_GROUP):
		var node := n as Node
		if not is_instance_valid(node) or node.is_queued_for_deletion():
			continue
		var ci := node as CanvasItem
		if ci != null and not ci.is_visible_in_tree():
			continue
		return node
	return null


func _unhandled_input(event: InputEvent) -> void:
	# Inert while the menu is hidden — otherwise a hidden overlay (e.g. an HQ panel
	# layered over a diegetic station) would keep eating menu_* / ui_cancel and
	# steal them from whatever is actually on screen.
	if not _menu_visible():
		return

	# While typing, Back means "stop typing", not "leave the page" — otherwise Esc
	# discards a half-entered email instead of just releasing the field.
	if is_text_editing() \
			and (event.is_action_pressed("ui_cancel") or event.is_action_pressed("menu_back")):
		var editing := get_viewport().gui_get_focus_owner()
		if editing != null:
			editing.release_focus()
		get_viewport().set_input_as_handled()
		return

	# A modal owns the screen while it is up: every page behind it goes deaf, so a
	# stacked press can't move a cursor or fire a Back on a page the player can't see.
	# Until now that was masked only by tree ordering (the modal sits on layer 101), and
	# tree ordering is not a rule. The modal's OWN nav is carved out by input_blocked,
	# so it keeps its Back and its cursor. (Text editing is already handled above, which
	# is why this only bites for the modal case here.)
	if input_blocked(self):
		return

	# Back first: Esc / gamepad B. Only if the host handed us an on_back.
	if _on_back.is_valid() \
			and (event.is_action_pressed("ui_cancel") or event.is_action_pressed("menu_back")):
		_on_back.call()
		get_viewport().set_input_as_handled()
		return

	# WASD directional nav. Native ui_* already moved focus for arrows / stick /
	# D-pad in the GUI phase (so those never reach here); this catches the WASD
	# keys that the native ui_* actions don't bind.
	var side := -1
	if event.is_action_pressed("menu_up"):
		side = SIDE_TOP
	elif event.is_action_pressed("menu_down"):
		side = SIDE_BOTTOM
	elif event.is_action_pressed("menu_left"):
		side = SIDE_LEFT
	elif event.is_action_pressed("menu_right"):
		side = SIDE_RIGHT
	if side == -1:
		return

	var vp := get_viewport()
	var focused := vp.gui_get_focus_owner()
	if focused == null:
		# Nothing focused (e.g. cursor was released) — land on `first` so the very
		# first WASD press revives the cursor instead of being swallowed.
		if is_instance_valid(_first) and _first.is_visible_in_tree():
			_first.grab_focus()
			vp.set_input_as_handled()
		return

	# On a slider, left/right ADJUST the value rather than moving focus, so the cursor
	# resting on a slider is enough to change it — no "select it first" step, and WASD
	# (A/D) nudges it the same as the arrow keys do natively. Arrows / D-pad / stick
	# are already consumed by the Range in the GUI phase (they bind ui_left/ui_right),
	# so only the WASD presses reach here; up/down still fall through to focus nav so
	# the cursor can leave the slider for the next row.
	if focused is Range and (side == SIDE_LEFT or side == SIDE_RIGHT):
		var rng := focused as Range
		if rng.editable:
			var stepv: float = rng.step if rng.step > 0.0 else (rng.max_value - rng.min_value) / 20.0
			rng.value += stepv if side == SIDE_RIGHT else -stepv
			vp.set_input_as_handled()
		return

	var neighbour := focused.find_valid_focus_neighbor(side)
	if neighbour != null and neighbour != focused:
		neighbour.grab_focus()
		vp.set_input_as_handled()

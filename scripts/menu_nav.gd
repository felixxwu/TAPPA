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
	nav._first = opts.get("first", null)
	if nav._first == null:
		nav._first = UITheme.first_focusable(root)
	# Grab focus after the host finishes showing/laying out the menu.
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


func _enable(c: Control) -> void:
	if c == null or c.has_meta("menu_nav_skip"):
		return
	if c.focus_mode == Control.FOCUS_NONE:
		c.focus_mode = Control.FOCUS_ALL


# Is the menu actually on screen? Control.is_visible_in_tree() only walks Control
# ancestors, so it MISSES a CanvasLayer ancestor being hidden (how HQ toggles its
# station overlays). Check both: the Control chain AND any CanvasLayer ancestor.
func _menu_visible() -> bool:
	if not is_instance_valid(_root) or not _root.is_visible_in_tree():
		return false
	var n: Node = _root
	while n != null:
		if n is CanvasLayer and not (n as CanvasLayer).visible:
			return false
		n = n.get_parent()
	return true


func _unhandled_input(event: InputEvent) -> void:
	# Inert while the menu is hidden — otherwise a hidden overlay (e.g. an HQ panel
	# layered over a diegetic station) would keep eating menu_* / ui_cancel and
	# steal them from whatever is actually on screen.
	if not _menu_visible():
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

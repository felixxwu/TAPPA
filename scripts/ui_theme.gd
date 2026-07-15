class_name UITheme
extends RefCounted
# THE DESIGN SYSTEM — one place that defines how every menu, panel and button in
# the game looks, so the UI reads as one polished, consistent whole instead of a
# pile of one-off `Color(...)` literals and ad-hoc font sizes.
#
# The look is a retro arcade / terminal aesthetic adapted from the previous web
# build of this game: pure-black, sharp-cornered panels; a hand-drawn monospace
# font (Syne Mono); crisp white text with a hard drop shadow; and a tight accent
# palette (green = active/positive, gold = money/reward, red = danger/timer). No
# rounded corners, no gradients, no blur. This is a STYLING layer only — it never
# changes what a screen says or where its buttons are; text is rendered verbatim.
#
# How it's applied:
#   * GLOBAL THEME — `theme/ui_theme.tres` (built by tools/build_ui_theme.gd from
#     the constants here) is wired as the project-wide default theme
#     (project.godot `gui/theme/custom`). Every Control inherits the font, the
#     button/panel styleboxes, the text colour and the drop shadow automatically —
#     this is what makes the whole game consistent without touching each widget.
#   * THIS MODULE — the palette + size constants are the single source of truth
#     (the theme generator reads them), and the `static` helpers below build the
#     bits a flat theme can't express: solid black panel boxes, role-coloured
#     labels (money/danger/positive), and the ▶◀ selection markers / underline.
#
# HOUSE RULES (enforced, not just suggested — see `enforce`):
#   1. ALL menu text is UPPERCASE.
#   2. ONE fixed font size everywhere (FONT_SIZE) — no per-screen size hierarchy.
#   3. Single-line menu buttons are a FIXED, compact height (MENU_ROW_H).
#   4. Menu backgrounds are PURE BLACK.
# `enforce(root)` applies 1–3 to every Label/Button under a menu root; the global
# theme bakes in 2–4 as the defaults. Menu builders call `enforce` once after
# building (HQ re-runs it on every view change so dynamic text obeys too).
#
# Tune the look HERE (then re-run tools/build_ui_theme.gd to regenerate the .tres);
# don't scatter new colour/size literals through the UI scripts. See
# features/ui-design-system.md.

# Syne Mono is the UI face: a hand-drawn monospace, so stat read-outs and money
# columns line up while the lettering keeps a characterful, slightly informal feel.
const FONT_PATH := "res://fonts/SyneMono.ttf"

# --- Palette -----------------------------------------------------------------
# Surfaces are pure black; over the 3D world panels stay nearly opaque so the
# terminal text reads cleanly against grass/sky.
const BLACK := Color(0.0, 0.0, 0.0, 1.0)            # solid panel / fully opaque surface
const PANEL := Color(0.0, 0.0, 0.0, 0.9)            # panel over the 3D world
const PANEL_DIM := Color(0.0, 0.0, 0.0, 0.6)        # dim backdrop behind a menu
const SURFACE := Color(0.05, 0.06, 0.05, 1.0)       # raised surface (button face)
const SURFACE_HOVER := Color(0.11, 0.14, 0.11, 1.0) # button hover/pressed lift

# Text + accents.
const INK := Color(0.92, 0.95, 0.90, 1.0)           # primary text — crisp warm white
const INK_DIM := Color(0.92, 0.95, 0.90, 0.55)      # secondary / hint text
const GREEN := Color(0.33, 0.86, 0.36, 1.0)         # active / selected / positive
const GOLD := Color(0.97, 0.80, 0.13, 1.0)          # money / winnings / reward
const RED := Color(0.89, 0.27, 0.22, 1.0)           # danger / run timer / warning
const MUTED := Color(0.58, 0.66, 0.54, 0.55)        # locked / disabled (olive-grey)
const SHADOW := Color(0.0, 0.0, 0.0, 0.95)          # hard text drop shadow

# --- Size (rule 2: one fixed font size everywhere) ---------------------------
# Deliberately small. There is NO type hierarchy — titles, headings, body and
# buttons all use this single size, the way a terminal readout is uniform.
const FONT_SIZE := 16

# --- Rule 3: fixed, compact height for single-line menu buttons --------------
const MENU_ROW_H := 30
# A modest min width so short buttons (BACK, QUIT) still read as a bar.
const BUTTON_MIN_W := 180

# --- Spacing -----------------------------------------------------------------
const GAP_TIGHT := 6
const GAP := 10
const GAP_WIDE := 16
const MARGIN := 24
const SHADOW_OFFSET := 2    # hard drop shadow, x == y


# --- Resource loaders --------------------------------------------------------

static func font() -> FontFile:
	return load(FONT_PATH)


static func theme() -> Theme:
	return load("res://theme/ui_theme.tres")


# --- Text helpers ------------------------------------------------------------

# Uppercase a string (rule 1). Used by the helpers and `enforce`.
static func caps(text: String) -> String:
	return text.to_upper()


# A label in a given role colour at the one house font size, uppercased.
# role: "ink" | "dim" | "green" | "gold" | "red". Inherits the theme font + shadow.
static func label(text: String, role: String = "ink") -> Label:
	var l := Label.new()
	l.text = caps(text)
	l.add_theme_font_size_override("font_size", FONT_SIZE)
	l.add_theme_color_override("font_color", _role_color(role))
	return l


# A screen title — same size as everything else (rule 2), just centred.
static func title(text: String) -> Label:
	var l := label(text)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


# A money read-out (gold), e.g. "$88,052".
static func money(text: String) -> Label:
	return label(text, "gold")


# Format a lap/run time in milliseconds as "m:ss.cc" (e.g. 83210 -> "1:23.21").
# The single source of truth for the time read-out the leaderboard/standings,
# podium, start line and finish arch all show. Negative ms is the "no time"
# sentinel — it renders `negative_text` ("--:--" for standings/podium, "—" for
# the start-line rival grid). Callers with seconds (the HUD) multiply by 1000.
static func format_time(ms: int, negative_text: String = "--:--") -> String:
	if ms < 0:
		return negative_text
	var seconds := ms / 1000.0
	var minutes := int(seconds / 60.0)
	return "%d:%05.2f" % [minutes, seconds - minutes * 60.0]


# One leaderboard/standings row, identical between the standings overlay and the
# podium's leaderboard: "> P3 — NAME (CAR) — 1:23.21", where the leading "> " and
# a gold tint mark the player, place < 1 reads "DNF", and a wrecked entry shows
# "WRECKED" instead of a time. Reads `placed`, `dnf`, `combined_ms`, `name`,
# `car_name`, `is_player` from the entry dict.
static func standings_row(entry: Dictionary) -> Label:
	var l := Label.new()
	var placed := int(entry.get("placed", -1))
	var pos_text := "P%d" % placed if placed >= 1 else "DNF"
	var time_text := "WRECKED" if entry.get("dnf", false) else format_time(int(entry.get("combined_ms", -1)))
	var who := String(entry.get("name", "?"))
	var car := String(entry.get("car_name", ""))
	if car != "":
		who += " (%s)" % car
	var is_player: bool = entry.get("is_player", false)
	l.text = "%s%s — %s — %s" % ["> " if is_player else "", pos_text, who, time_text]
	if is_player:
		l.add_theme_color_override("font_color", GOLD)
	return l


static func _role_color(role: String) -> Color:
	match role:
		"dim": return INK_DIM
		"green": return GREEN
		"gold": return GOLD
		"red": return RED
		"muted": return MUTED
		_: return INK


# --- Panels ------------------------------------------------------------------

# A pure-black, sharp-cornered panel box (rule 4). Defaults to fully opaque;
# `alpha` can soften a panel that floats over the 3D world.
static func panel_box(alpha: float = 1.0, pad: int = 14) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.0, 0.0, 0.0, alpha)
	for side in ["left", "top", "right", "bottom"]:
		box.set("content_margin_" + side, float(pad))
	# Sharp corners, no border — the defining trait of the look.
	return box


# A PanelContainer wearing `panel_box`. Drop children straight in.
static func panel(alpha: float = 1.0, pad: int = 14) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_box(alpha, pad))
	return p


# A solid black, sharp-cornered reward-card stylebox with a green accent border (a
# reward is a positive event — GREEN is the design system's "positive" colour).
# Shared by the upgrade reveal and the podium car-reveal cards.
static func reward_card_box() -> StyleBoxFlat:
	var style := panel_box(0.92, 22)
	style.border_color = GREEN
	for side in ["left", "top", "right", "bottom"]:
		style.set("border_width_" + side, 2)
	return style


# --- Buttons & selection -----------------------------------------------------

# A standard menu button: uppercase, fixed compact height (rule 3), no keyboard
# focus ring (menus here are tap / explicit-nav driven). Styling (pure-black face,
# font, size) comes from the global theme.
static func button(text: String) -> Button:
	var b := Button.new()
	b.text = caps(text)
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(BUTTON_MIN_W, MENU_ROW_H)
	return b


# Show/clear the "this option is selected" treatment used by the web build:
# the label is underlined and tinted green while selected. Pair with `flank()`
# for the ▶◀ triangles around the active row.
#
# The `focus` state is deliberately LEFT to the global theme (a SURFACE_HOVER box
# with a green underline, white text — see tools/build_ui_theme.gd) so that a
# keyboard/gamepad focus cursor stays visible ON a selected row: a focused row
# reads as white text, a merely-selected row as green text. (Menus drive nav by
# native focus — focus_mode = FOCUS_ALL — and the theme's focus look is the same
# lift a mouse hover shows, so the two read identically.)
static func mark_selected(btn: Button, selected: bool) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = SURFACE_HOVER if selected else BLACK  # pure black when idle (rule 4)
	if selected:
		box.border_width_bottom = 3
		box.border_color = GREEN
	for side in ["left", "top", "right", "bottom"]:
		box.set("content_margin_" + side, 10.0)
	for state in ["normal", "hover", "pressed"]:
		btn.add_theme_stylebox_override(state, box)
	btn.add_theme_color_override("font_color", GREEN if selected else INK)


# Show/clear a keyboard/gamepad CURSOR highlight on a button whose focus is driven
# MANUALLY rather than by Godot's focus system. The diegetic HQ stations keep
# focus_mode = FOCUS_NONE so left/right can mean "cycle the 3D car / map pin"
# instead of "move focus to the neighbour widget", so they track a cursor index by
# hand and paint it here. Mirrors the theme's focus look — the same SURFACE_HOVER
# lift + green underline a mouse hover (or a native-focus menu) shows — so a manual
# cursor and a real focus ring read identically. Flat menus don't need this; their
# highlight comes from the theme `focus` stylebox via grab_focus().
static func mark_focused(btn: Button, focused: bool) -> void:
	if focused:
		var box := StyleBoxFlat.new()
		box.bg_color = SURFACE_HOVER
		box.border_width_bottom = 3
		box.border_color = GREEN
		box.content_margin_left = 14
		box.content_margin_right = 14
		box.content_margin_top = 4
		box.content_margin_bottom = 4
		btn.add_theme_stylebox_override("normal", box)
		btn.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	else:
		btn.remove_theme_stylebox_override("normal")
		btn.remove_theme_color_override("font_color")


# Show/clear the selection treatment on a billboarded MAP-PIN readout panel. The map
# pins keep a manual cursor (left/right cycles spatial pins, not widget focus), so the
# selected pin can't lean on Godot's focus ring; instead of scaling the pin up (which
# made some rally boxes read as larger than others) we paint its panel like a hovered
# menu row — the same SURFACE_HOVER face + green bottom underline `mark_focused` gives a
# button — so a selected pin and a hovered menu option read identically. `pad` matches
# the panel's content padding so the box doesn't resize between the two states.
static func mark_panel_focused(container: PanelContainer, focused: bool, pad: int = 14) -> void:
	var box := StyleBoxFlat.new()
	if focused:
		box.bg_color = SURFACE_HOVER
		box.border_width_bottom = 3
		box.border_color = GREEN
	else:
		box.bg_color = BLACK  # pure black when idle (rule 4)
	for side in ["left", "top", "right", "bottom"]:
		box.set("content_margin_" + side, float(pad))
	container.add_theme_stylebox_override("panel", box)


# Grab keyboard/gamepad focus on `ctrl`, but only when it can actually take it —
# valid, in the tree, visible, and focusable. Call deferred so it runs after the
# host has finished showing/laying out the menu, e.g.
#   UITheme.focus_grab.bind(my_button).call_deferred()
# Guards against the errors grab_focus() pushes when a control isn't visible yet
# (a menu built while its layer is still hidden, a podium button mid-spin, ...).
# `ctrl` is left untyped on purpose: a typed `Control` param breaks the bound-and-
# deferred Callable path (`UITheme.focus_grab.bind(btn).call_deferred()`) — the
# deferred queue stores the arg as a generic Object and the typed conversion fails.
# The first focusable, enabled, visible Control under `root` (tree order), or null.
# Shared by the menu framework (MenuNav) and HQ's native-focus pages to seat the
# cursor when a menu opens. Skips FOCUS_NONE widgets and disabled buttons.
static func first_focusable(root: Node) -> Control:
	if root == null:
		return null
	for node in root.find_children("*", "Control", true, false):
		var c := node as Control
		# Skip nodes in a dying subtree: a rebuilt menu (e.g. the HQ upgrades page)
		# queue_frees its old ROW containers and adds fresh ones in the SAME frame. A
		# button under a queued row isn't itself is_queued_for_deletion() (only the
		# explicitly-freed ancestor is), so we must walk up — otherwise a deferred grab
		# lands on a doomed button and loses focus when its parent is freed next frame.
		if c != null and not in_dying_subtree(c) \
				and c.focus_mode != Control.FOCUS_NONE and c.is_visible_in_tree() \
				and not (c is BaseButton and (c as BaseButton).disabled):
			return c
	return null


# True if `node` or any of its ancestors is queued for deletion — i.e. it's part of a
# subtree that will be freed at the end of the frame, so it must not be a focus target.
static func in_dying_subtree(node: Node) -> bool:
	var n: Node = node
	while n != null:
		if n.is_queued_for_deletion():
			return true
		n = n.get_parent()
	return false


# Grab focus on the first focusable control under `root` (see first_focusable).
# Deferred-friendly: UITheme.focus_grab_first.bind(root).call_deferred().
static func focus_grab_first(root: Node) -> void:
	focus_grab(first_focusable(root))


static func focus_grab(ctrl) -> void:
	# Check validity BEFORE casting: a deferred grab can fire after its menu was freed
	# (e.g. a scene torn down in a test), and `as Control` on a freed object errors.
	if not is_instance_valid(ctrl):
		return
	var c := ctrl as Control
	if c != null and c.is_inside_tree() \
			and c.is_visible_in_tree() and c.focus_mode != Control.FOCUS_NONE:
		c.grab_focus()


# Wrap a control with white ▶ ◀ selection triangles (shown only when `active`),
# mirroring the focused-row markers in the web build. Returns the HBox to add.
static func flank(inner: Control, active: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var left := label("▶")   # ▶
	var right := label("◀")  # ◀
	left.visible = active
	right.visible = active
	row.add_child(left)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(inner)
	row.add_child(right)
	return row


# --- Rule enforcement --------------------------------------------------------

# Apply the house rules to every Label/Button under a menu root:
#   1. uppercase the text,
#   2. lock the font size to FONT_SIZE,
#   3. give plain single-line buttons the fixed compact height.
# Idempotent and cheap — menu builders call it once after building, and screens
# with dynamic text (e.g. HQ) re-run it whenever that text changes so the rules
# keep holding. Leaves layout/colour alone; only normalises text, size, height.
static func enforce(root: Node) -> void:
	for node in root.find_children("*", "Label", true, false):
		var l := node as Label
		l.text = caps(l.text)
		l.add_theme_font_size_override("font_size", FONT_SIZE)
	for node in root.find_children("*", "Button", true, false):
		var b := node as Button
		b.text = caps(b.text)
		b.add_theme_font_size_override("font_size", FONT_SIZE)
		# A "single-line menu" button: no embedded layout, no manual line break.
		if b.get_child_count() == 0 and not b.text.contains("\n"):
			b.custom_minimum_size.y = MENU_ROW_H

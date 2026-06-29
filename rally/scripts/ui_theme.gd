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
static func mark_selected(btn: Button, selected: bool) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = SURFACE_HOVER if selected else BLACK  # pure black when idle (rule 4)
	if selected:
		box.border_width_bottom = 3
		box.border_color = GREEN
	for side in ["left", "top", "right", "bottom"]:
		box.set("content_margin_" + side, 10.0)
	for state in ["normal", "hover", "pressed", "focus"]:
		btn.add_theme_stylebox_override(state, box)
	btn.add_theme_color_override("font_color", GREEN if selected else INK)


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

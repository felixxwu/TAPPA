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
#   * THIS MODULE — the palette + type-scale constants are the single source of
#     truth (the theme generator reads them), and the `static` helpers below build
#     the bits a flat theme can't express on its own: solid black panel boxes,
#     role-coloured labels (money/danger/positive), and the ▶◀ selection markers /
#     underline used to show the focused menu option, exactly like the web build.
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

# --- Type scale (px) ---------------------------------------------------------
# VT323 is a touch shorter than Open Sans at the same px, so these run a little
# larger than the old ad-hoc sizes. UPPERCASE is the house style (see `caps`).
const SIZE_DISPLAY := 80    # the big 3·2·1·GO countdown
const SIZE_TITLE := 44      # screen titles: PAUSED, STAGE COMPLETE
const SIZE_HEADING := 32    # section headings
const SIZE_SUBHEADING := 24 # sub-headings / banners
const SIZE_BODY := 20       # default body / button text
const SIZE_LABEL := 18      # compact labels, stat rows
const SIZE_SMALL := 15      # hints, captions, end-labels

# --- Spacing -----------------------------------------------------------------
const GAP_TIGHT := 6
const GAP := 12
const GAP_WIDE := 18
const MARGIN := 24
const SHADOW_OFFSET := 3    # hard pixel shadow, x == y

# Standard min size for a tappable menu button (mobile-friendly hit target).
const BUTTON_MIN := Vector2(240, 52)


# --- Resource loaders --------------------------------------------------------

static func font() -> FontFile:
	return load(FONT_PATH)


static func theme() -> Theme:
	return load("res://theme/ui_theme.tres")


# --- Text helpers ------------------------------------------------------------

# Optional uppercase helper for when a caller WANTS the all-caps arcade look on a
# specific string. Not applied automatically — labels/buttons keep their text
# verbatim so a screen's wording stays exactly as authored.
static func caps(text: String) -> String:
	return text.to_upper()


# A label in a given role colour + size. role: "ink" | "dim" | "green" | "gold"
# | "red". Inherits the global theme's font + drop shadow.
static func label(text: String, size: int = SIZE_BODY, role: String = "ink") -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", _role_color(role))
	return l


# A screen title (big, white, centred). Text is used verbatim — pass the wording
# you want (e.g. "PAUSED").
static func title(text: String) -> Label:
	var l := label(text, SIZE_TITLE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


# A money read-out (gold), e.g. "$88,052".
static func money(text: String) -> Label:
	return label(text, SIZE_HEADING, "gold")


static func _role_color(role: String) -> Color:
	match role:
		"dim": return INK_DIM
		"green": return GREEN
		"gold": return GOLD
		"red": return RED
		"muted": return MUTED
		_: return INK


# --- Panels ------------------------------------------------------------------

# A solid black, sharp-cornered panel box (the house surface). `alpha` lets a
# panel over the 3D world stay slightly see-through; pass 1.0 for a solid screen.
static func panel_box(alpha: float = 0.9, pad: int = 18) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.0, 0.0, 0.0, alpha)
	for side in ["left", "top", "right", "bottom"]:
		box.set("content_margin_" + side, float(pad))
	# Sharp corners, no border — the defining trait of the look.
	return box


# A PanelContainer wearing `panel_box`. Drop children straight in.
static func panel(alpha: float = 0.9, pad: int = 18) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_box(alpha, pad))
	return p


# --- Buttons & selection -----------------------------------------------------

# A standard menu button: house min-size, no keyboard focus ring (menus here are
# tap / explicit-nav driven). Text is used verbatim; styling comes from the global
# theme.
static func button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = BUTTON_MIN
	return b


# Show/clear the "this option is selected" treatment used by the web build:
# the label is underlined and tinted green while selected. Pair with `flank()`
# for the ▶◀ triangles around the active row.
static func mark_selected(button: Button, selected: bool) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = SURFACE_HOVER if selected else SURFACE
	if selected:
		box.border_width_bottom = 3
		box.border_color = GREEN
	for side in ["left", "top", "right", "bottom"]:
		box.set("content_margin_" + side, 12.0)
	for state in ["normal", "hover", "pressed", "focus"]:
		button.add_theme_stylebox_override(state, box)
	button.add_theme_color_override("font_color", GREEN if selected else INK)


# Wrap a control with white ▶ ◀ selection triangles (shown only when `active`),
# mirroring the focused-row markers in the web build. Returns the HBox to add.
static func flank(inner: Control, active: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", GAP)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var left := label("▶", SIZE_SUBHEADING)   # ▶
	var right := label("◀", SIZE_SUBHEADING)  # ◀
	left.visible = active
	right.visible = active
	row.add_child(left)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(inner)
	row.add_child(right)
	return row

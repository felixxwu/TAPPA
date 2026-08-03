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
# don't scatter new colour/size literals through the UI scripts. NOTE the palette
# values are GRADE-BAKED — read the Palette section below before editing a colour.
# See features/ui-design-system.md.

# Syne Mono is the UI face: a hand-drawn monospace, so stat read-outs and money
# columns line up while the lettering keeps a characterful, slightly informal feel.
const FONT_PATH := "res://fonts/SyneMono.ttf"

# --- Palette -----------------------------------------------------------------
# Surfaces are pure black; over the 3D world panels stay nearly opaque so the
# terminal text reads cleanly against grass/sky.
#
# GRADE-BAKED. Every value below has been run through the world's colour grade
# (the GRID look — desaturate + contrast + warm split tone; see
# features/rendering.md → "Colour grade") so the UI sits in the same palette as
# the 3D it overlays. The authored design intent is kept in each trailing comment
# and is the real source of truth: the UI is NOT shader-graded, because it lives
# on CanvasLayers above the post-process container and reaching it would cost a
# hint_screen_texture backbuffer copy every frame.
#
# These are therefore DERIVED values. Retuning the grade in
# config/game_config.tres does NOT update them — re-run
# `godot --headless --script tools/bake_ui_palette.gd`, paste its output here, then
# re-run tools/build_ui_theme.gd to regenerate theme/ui_theme.tres. The bake tool
# holds the authored palette itself, so it stays idempotent.
#
# Note the pure blacks survive the grade unchanged (a black pixel has no hue to
# shift and the contrast curve clamps at zero), so HOUSE RULE 4 — menu
# backgrounds are PURE BLACK — still holds exactly.
const BLACK := Color(0.0, 0.0, 0.0, 1.0)            # solid panel / fully opaque surface
const PANEL := Color(0.0, 0.0, 0.0, 0.9)            # panel over the 3D world
const PANEL_DIM := Color(0.0, 0.0, 0.0, 0.6)        # dim backdrop behind a menu
const MODAL_DIM := Color(0.0, 0.0, 0.0, 0.96)       # backdrop behind a blocking modal
                                                    # (confirm popup / car-park prompts):
                                                    # heavier than PANEL_DIM so the world
                                                    # behind reads as fully interrupted
const SURFACE := Color(0.0028, 0.0132, 0.0071, 1.0)      # raised surface (button face) — authored Color(0.05, 0.06, 0.05)
const SURFACE_HOVER := Color(0.0807, 0.0989, 0.0642, 1.0) # button hover/pressed lift — authored Color(0.11, 0.14, 0.11)

# Text + accents.
const INK := Color(1.0, 0.9938, 0.8346, 1.0)        # primary text — warm off-white — authored Color(0.92, 0.95, 0.90)
const INK_DIM := Color(1.0, 0.9938, 0.8346, 0.55)   # secondary / hint text — authored Color(0.92, 0.95, 0.90, 0.55)
const GREEN := Color(0.4272, 0.8594, 0.3718, 1.0)   # active / selected / positive — authored Color(0.33, 0.86, 0.36)
const GOLD := Color(1.0, 0.8269, 0.2127, 1.0)       # money / winnings / reward — authored Color(0.97, 0.80, 0.13)
const RED := Color(0.8747, 0.2743, 0.1982, 1.0)     # danger / run timer / warning — authored Color(0.89, 0.27, 0.22)
const MUTED := Color(0.6368, 0.6679, 0.4914, 0.55)  # locked / disabled (olive-grey) — authored Color(0.58, 0.66, 0.54, 0.55)
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


# "1 token" / "3 tokens" — a count with its noun, pluralised. Trivial, but it was being
# hand-rolled at three call sites (the garage swap row's label and its locked hint, and the
# car-park swap confirm popup), which is three chances to disagree about the wording.
static func count_noun(n: int, noun: String, plural := "") -> String:
	if n == 1:
		return "1 %s" % noun
	return "%d %s" % [n, plural if plural != "" else noun + "s"]


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


# --- Scrolling body text -----------------------------------------------------

# Breathing room kept between a modal panel and the edges of the screen when the
# body has to be capped. Only ever bites on a pathologically long string.
const BODY_SCROLL_MARGIN := 32.0

# SIZE A SCROLLED BODY LABEL TO ITS CONTENT. Shared by every modal that puts an
# autowrapped body Label inside a (Touch)ScrollContainer — ConfirmPopup and
# UsernamePopup today.
#
# WHY THIS EXISTS. A ScrollContainer does not report its child's minimum size on
# an axis it may scroll, so an untouched scroll collapses to ~0 tall inside a
# CenterContainer/PanelContainer (both of which size to their natural minimum).
# The scroll's height therefore has to be set explicitly, and it must be the
# body's TRUE wrapped height or the last line(s) get hidden behind a scrollbar —
# exactly the bug this helper fixes. These popups are fullscreen and their bodies
# are short, so in practice NOTHING should ever scroll; the cap below is only a
# fallback so a pathological string is reachable rather than clipped.
#
# TWO MEASUREMENTS, BECAUSE THE FIRST ONE IS ONLY AN ESTIMATE. Before the first
# layout pass the Label has no width, so its own minimum height cannot be
# trusted and we estimate from the font at the known wrap width. That estimate
# used to be the ONLY measurement, and it is systematically SHORT:
# `Font.get_multiline_string_size` returns lines x font-height and knows nothing
# about the Label's `line_spacing` theme constant, so an N-line body came out
# (N-1) x line_spacing too short and scrolled. We add the spacing back, and then
# re-fit from the Label itself (via its `resized` signal) once it has a real
# width and reports its exact content height — which also covers the body TEXT
# being replaced later (ConfirmPopup.set_body / open_committing).
static func fit_body_scroll(scroll: ScrollContainer, body: Label, wrap_width: float) -> void:
	if not is_instance_valid(scroll) or not is_instance_valid(body):
		return
	if not scroll.has_meta("body_fit_wired"):
		scroll.set_meta("body_fit_wired", true)
		body.resized.connect(_refit_body_scroll.bind(scroll, body, wrap_width))
	_refit_body_scroll(scroll, body, wrap_width)


static func _refit_body_scroll(scroll: ScrollContainer, body: Label, wrap_width: float) -> void:
	if not is_instance_valid(scroll) or not is_instance_valid(body) or not scroll.is_inside_tree():
		return
	var content_h := _body_content_height(body, wrap_width)
	var previous: float = scroll.custom_minimum_size.y
	scroll.custom_minimum_size = Vector2(0, content_h)
	# Cap against what the screen actually leaves once everything OUTSIDE the
	# scroll (title, field, buttons, gaps, panel padding) has taken its share.
	var viewport_h: float = scroll.get_viewport().get_visible_rect().size.y \
		if scroll.get_viewport() != null else 360.0
	var box := _panel_ancestor(scroll)
	var reserved_h: float = 0.0
	if box != null:
		reserved_h = maxf(box.get_combined_minimum_size().y - content_h, 0.0)
	var max_h: float = maxf(viewport_h - reserved_h - BODY_SCROLL_MARGIN, 40.0)
	var fitted: float = minf(content_h, max_h)
	# Only write when it actually moved: `resized` fires as a RESULT of this
	# write, and re-writing an identical value would spin the layout forever.
	if absf(fitted - previous) > 0.5:
		scroll.custom_minimum_size = Vector2(0, fitted)
	else:
		scroll.custom_minimum_size = Vector2(0, previous)


# The body's true wrapped height. Prefers the Label's own report once it has been
# laid out at (about) the wrap width; falls back to a font measurement corrected
# for `line_spacing` before the first layout pass.
static func _body_content_height(body: Label, wrap_width: float) -> float:
	if body.size.x >= wrap_width - 1.0 and body.size.x > 0.0:
		return body.get_combined_minimum_size().y
	var body_font: Font = body.get_theme_font("font")
	var font_size: int = body.get_theme_font_size("font_size")
	if body_font == null:
		return 0.0
	var lines_h: float = body_font.get_multiline_string_size(
		body.text, HORIZONTAL_ALIGNMENT_LEFT, wrap_width, font_size).y
	var line_h: float = maxf(body_font.get_height(font_size), 1.0)
	var line_count: int = maxi(int(round(lines_h / line_h)), 1)
	var spacing: float = float(body.get_theme_constant("line_spacing"))
	return lines_h + spacing * float(line_count - 1)


static func _panel_ancestor(node: Node) -> PanelContainer:
	var p := node.get_parent()
	while p != null:
		if p is PanelContainer:
			return p as PanelContainer
		p = p.get_parent()
	return null


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


# A button for a HORIZONTAL action row: no width floor, so it hugs its own label.
# `button()` above pins BUTTON_MIN_W, which is right for a stacked column but wrong
# side by side — four of them need ~750 logical units against a canvas ~556 wide at
# the design height (~445 on the 288 web-touch tier), so the row runs off both edges.
# Height and uppercasing are left to `enforce()`, which every menu runs after building.
static func row_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE  # MenuNav/ButtonCursor decide focusability
	if on_press.is_valid():
		b.pressed.connect(on_press)
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
# `cls` optionally restricts the scan to a single class (e.g. "Button" to seat the
# cursor on the first real button, skipping focusable non-button widgets like
# sliders); the default "" scans all Controls.
static func first_focusable(root: Node, cls := "") -> Control:
	if root == null:
		return null
	var type := cls if cls != "" else "Control"
	for node in root.find_children("*", type, true, false):
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

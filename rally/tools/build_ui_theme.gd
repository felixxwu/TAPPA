extends SceneTree
# Generator for the project-wide UI Theme (theme/ui_theme.tres). Run headless:
#
#     godot --headless --script tools/build_ui_theme.gd
#
# It builds the Theme entirely from the constants in scripts/ui_theme.gd
# (UITheme) so the design system has ONE source of truth: tune the palette / type
# scale there, re-run this, and the whole game restyles. The .tres is wired as the
# project default theme via project.godot `gui/theme/custom`, so every Control
# inherits the font, button/panel styleboxes, text colour and drop shadow.
#
# See features/ui-design-system.md.

const OUT_PATH := "res://theme/ui_theme.tres"


func _init() -> void:
	var theme := Theme.new()
	var font := UITheme.font()
	theme.default_font = font
	theme.default_font_size = UITheme.SIZE_BODY

	_build_label(theme)
	_build_button(theme)
	_build_panels(theme)
	_build_slider(theme)
	_build_progress(theme)

	DirAccess.make_dir_recursive_absolute("res://theme")
	var err := ResourceSaver.save(theme, OUT_PATH)
	if err == OK:
		print("Wrote ", OUT_PATH)
	else:
		push_error("Failed to save theme: %d" % err)
	quit(0 if err == OK else 1)


# Crisp white text with a hard pixel drop shadow — the chunky terminal look.
func _build_label(theme: Theme) -> void:
	theme.set_color("font_color", "Label", UITheme.INK)
	theme.set_color("font_shadow_color", "Label", UITheme.SHADOW)
	theme.set_constant("shadow_offset_x", "Label", UITheme.SHADOW_OFFSET)
	theme.set_constant("shadow_offset_y", "Label", UITheme.SHADOW_OFFSET)
	theme.set_constant("shadow_outline_size", "Label", 0)


# Solid, sharp-cornered black buttons. Hover/pressed lift the face and underline
# it green; no focus ring (menus are tap / explicit-nav driven).
func _build_button(theme: Theme) -> void:
	theme.set_stylebox("normal", "Button", _btn_box(UITheme.SURFACE))
	theme.set_stylebox("hover", "Button", _btn_box(UITheme.SURFACE_HOVER, true))
	theme.set_stylebox("pressed", "Button", _btn_box(UITheme.SURFACE_HOVER, true))
	theme.set_stylebox("focus", "Button", _btn_box(UITheme.SURFACE_HOVER, true))
	theme.set_stylebox("disabled", "Button", _btn_box(Color(0.04, 0.05, 0.04, 0.85)))

	theme.set_color("font_color", "Button", UITheme.INK)
	theme.set_color("font_hover_color", "Button", Color(1, 1, 1, 1))
	theme.set_color("font_pressed_color", "Button", UITheme.GREEN)
	theme.set_color("font_focus_color", "Button", Color(1, 1, 1, 1))
	theme.set_color("font_disabled_color", "Button", UITheme.MUTED)


func _btn_box(bg: Color, selected: bool = false) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.content_margin_left = 16
	box.content_margin_right = 16
	box.content_margin_top = 10
	box.content_margin_bottom = 10
	if selected:
		box.border_width_bottom = 3
		box.border_color = UITheme.GREEN
	# Sharp corners, no outer border — the defining trait of the look.
	return box


func _build_panels(theme: Theme) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = UITheme.PANEL
	box.content_margin_left = 18
	box.content_margin_right = 18
	box.content_margin_top = 18
	box.content_margin_bottom = 18
	theme.set_stylebox("panel", "PanelContainer", box)
	theme.set_stylebox("panel", "Panel", box.duplicate())
	# Popups / dialogs share the surface.
	var popup := StyleBoxFlat.new()
	popup.bg_color = UITheme.BLACK
	popup.content_margin_left = 16
	popup.content_margin_right = 16
	popup.content_margin_top = 16
	popup.content_margin_bottom = 16
	theme.set_stylebox("panel", "PopupPanel", popup)


# Minimal green slider on a thin dark track (tuning sliders).
func _build_slider(theme: Theme) -> void:
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.10, 0.12, 0.10, 1.0)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	theme.set_stylebox("slider", "HSlider", track)
	var area := StyleBoxFlat.new()
	area.bg_color = UITheme.GREEN
	area.content_margin_top = 3
	area.content_margin_bottom = 3
	theme.set_stylebox("grabber_area", "HSlider", area)
	theme.set_stylebox("grabber_area_highlight", "HSlider", area.duplicate())


# HP / progress bar: dark track, no rounding (HUD recolours the fill per-HP).
func _build_progress(theme: Theme) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.08, 0.09, 0.08, 0.9)
	theme.set_stylebox("background", "ProgressBar", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = UITheme.GREEN
	theme.set_stylebox("fill", "ProgressBar", fill)

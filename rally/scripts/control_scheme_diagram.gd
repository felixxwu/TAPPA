class_name ControlSchemeDiagram
extends Control
# A small vector diagram of one mobile control scheme (MobileControls.SCHEME_*),
# drawn for the title-screen Settings page so each option visually shows its
# layout: a landscape "phone" with the slider / steer buttons / pedals / tilt
# motif of that scheme. Set `scheme` then add it to the tree; it redraws on resize.

# Pedal/steer/accent colours — green gas, red brake, blue steering.
const _SCREEN_BG := Color(0.09, 0.11, 0.15, 1.0)
const _BORDER := Color(1, 1, 1, 0.45)
const _GAS := Color(0.38, 0.78, 0.42, 0.9)
const _BRAKE := Color(0.86, 0.40, 0.34, 0.9)
const _STEER := Color(0.62, 0.74, 1.0, 0.9)
const _SHADE := Color(0.62, 0.74, 1.0, 0.18)
const _TEXT := Color(1, 1, 1, 0.92)

var scheme := 0:
	set(value):
		scheme = value
		queue_redraw()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # the row Button behind it takes the tap


func _draw() -> void:
	var s := size
	# The phone screen (landscape) fills the control with a thin inset.
	var screen := Rect2(Vector2(1, 1), s - Vector2(2, 2))
	draw_rect(screen, _SCREEN_BG, true)
	draw_rect(screen, _BORDER, false, 1.5)

	var w := s.x
	var h := s.y
	var m := w * 0.05
	# Right-hand pedal stack geometry (shared by the schemes that use pedals).
	var pw := w * 0.18
	var ph := h * 0.22
	var px := w - m - pw
	var brake_y := h - m - ph
	var gas_y := brake_y - h * 0.06 - ph

	match scheme:
		MobileControls.SCHEME_SLIDER_GAS_BRAKE:
			_slider(m, h)
			_box(Rect2(px, gas_y, pw, ph), _GAS, "GAS")
			_box(Rect2(px, brake_y, pw, ph), _BRAKE, "BRK")
		MobileControls.SCHEME_BUTTONS_GAS_BRAKE:
			_steer_buttons(m, h)
			_box(Rect2(px, gas_y, pw, ph), _GAS, "GAS")
			_box(Rect2(px, brake_y, pw, ph), _BRAKE, "BRK")
		MobileControls.SCHEME_SLIDER_BRAKE_AUTO:
			_slider(m, h)
			_box(Rect2(px, brake_y, pw, ph), _BRAKE, "BRK")
			_auto_tag(w, h)
		MobileControls.SCHEME_BUTTONS_BRAKE_AUTO:
			_steer_buttons(m, h)
			_box(Rect2(px, brake_y, pw, ph), _BRAKE, "BRK")
			_auto_tag(w, h)
		MobileControls.SCHEME_SIMPLE_LR_AUTO:
			_simple_halves(w, h)
			_auto_tag(w, h)
		MobileControls.SCHEME_TILT_GAS_BRAKE:
			_tilt_motif(w, h)
			_box(Rect2(px, gas_y, pw, ph), _GAS, "GAS")
			_box(Rect2(px, brake_y, pw, ph), _BRAKE, "BRK")


# A filled, outlined, centred-label box.
func _box(rect: Rect2, fill: Color, label: String) -> void:
	draw_rect(rect, fill, true)
	draw_rect(rect, _BORDER, false, 1.0)
	_glyph(rect.position + rect.size * 0.5, label, int(rect.size.y * 0.42), _TEXT)


# The bottom-left steering slider: a track with a centred thumb.
func _slider(m: float, h: float) -> void:
	var sw := size.x * 0.42
	var sh := h * 0.14
	var track := Rect2(m, h - m - sh, sw, sh)
	draw_rect(track, _SHADE, true)
	draw_rect(track, _BORDER, false, 1.0)
	var thumb_w := sh
	var thumb := Rect2(track.position.x + sw * 0.5 - thumb_w * 0.5, track.position.y, thumb_w, sh)
	draw_rect(thumb, _STEER, true)
	draw_rect(thumb, _BORDER, false, 1.0)


# Two bottom-left steer buttons (< and >).
func _steer_buttons(m: float, h: float) -> void:
	var bw := size.x * 0.15
	var bh := h * 0.22
	var gap := size.x * 0.025
	var y := h - m - bh
	_box(Rect2(m, y, bw, bh), _STEER, "<")
	_box(Rect2(m + bw + gap, y, bw, bh), _STEER, ">")


# Left / right tap halves with a "both = brake" hint in the middle.
func _simple_halves(w: float, h: float) -> void:
	var top := h * 0.18
	var left := Rect2(2, top, w * 0.5 - 2, h - top - 2)
	var right := Rect2(w * 0.5, top, w * 0.5 - 2, h - top - 2)
	draw_rect(left, _SHADE, true)
	draw_rect(right, _SHADE, true)
	draw_line(Vector2(w * 0.5, top), Vector2(w * 0.5, h - 2), _BORDER, 1.0)
	_glyph(Vector2(w * 0.25, top + (h - top) * 0.5), "<", int(h * 0.3), _STEER)
	_glyph(Vector2(w * 0.75, top + (h - top) * 0.5), ">", int(h * 0.3), _STEER)
	_glyph(Vector2(w * 0.5, h * 0.12), "BOTH = BRAKE", int(h * 0.11), _BRAKE)


# A tilted mini-phone with a rotation hint, on the left.
func _tilt_motif(w: float, h: float) -> void:
	var c := Vector2(w * 0.27, h * 0.55)
	var hw := w * 0.13
	var hh := h * 0.22
	# Rectangle corners rotated about the centre to suggest a tilted device.
	var ang := deg_to_rad(18.0)
	var pts := PackedVector2Array()
	for corner in [Vector2(-hw, -hh), Vector2(hw, -hh), Vector2(hw, hh), Vector2(-hw, hh)]:
		pts.append(c + corner.rotated(ang))
	draw_colored_polygon(pts, _SHADE)
	for i in pts.size():
		draw_line(pts[i], pts[(i + 1) % pts.size()], _STEER, 1.5)
	# A double-headed arrow above it = "rock left/right".
	_glyph(Vector2(c.x, h * 0.2), "< >", int(h * 0.16), _STEER)
	_glyph(Vector2(c.x, h * 0.9), "TILT", int(h * 0.13), _TEXT)


# "AUTO GAS" caption (top-left) for the throttle-automatic schemes.
func _auto_tag(_w: float, h: float) -> void:
	_glyph(Vector2(h * 0.95, h * 0.12), "AUTO GAS", int(h * 0.11), _GAS)


# Draw `text` centred on `center` at the given font size.
func _glyph(center: Vector2, text: String, fs: int, color: Color) -> void:
	var font := ThemeDB.fallback_font
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, Vector2(center.x - tw * 0.5, center.y + fs * 0.35),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)

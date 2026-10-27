class_name HudGauge
extends Control
# One in-run HUD gauge (features/hud.md): a vertical strip on a black column that fills
# from the bottom, with the gauge's name running up the bar in faint ink, an ink needle
# riding over it at the current level, quarter ticks beside it and the icon underneath.
# hud.gd sets `value` and `fill_color`, hides the strip when the part isn't fitted, and
# lays the visible strips side by side so their black columns read as one panel.

# Layout in whole pixels so nothing lands between pixels: the bar runs from BAR_TOP down
# to ICON_AREA above the bottom, and the icon is centred in that bottom band.
const BAR_W := 16
const BAR_TOP := 8
const ICON_AREA := 24
const ICON_SCALE := 2
const NEEDLE_OVERHANG := 4
const NEEDLE_H := 2
# Jersey 10 only renders cleanly at UITheme.FONT_SIZE or a multiple of it, so the bar is
# sized to fit the longest name at that size rather than shrinking the text.
const NAME_FONT_SIZE := UITheme.FONT_SIZE
const NAME_ALPHA := 0.35
# The unfilled part of the bar and the tick marks. An empty gauge still shows where it is,
# so a spent NOS tank doesn't look the same as a car with no NOS fitted.
const TRACK_ALPHA := 0.13
const TICK_ALPHA := 0.5

const NAMES := {
	GaugeIcons.Kind.HEALTH: "HEALTH",
	GaugeIcons.Kind.BOOST: "BOOST",
	GaugeIcons.Kind.NOS: "NITROUS",
	GaugeIcons.Kind.TEMP: "TEMP",
}

@export var icon: GaugeIcons.Kind = GaugeIcons.Kind.HEALTH:
	set(v):
		icon = v
		queue_redraw()

# Fill fraction, 0..1. Clamped on draw, stored raw so the property round-trips.
var value := 0.0:
	set(v):
		if is_equal_approx(value, v):
			return
		value = v
		queue_redraw()

# The bar's tint. hud.gd pulses warnings through its alpha, so the needle, name and icon
# stay plain ink and readable while the bar flashes.
var fill_color := Color.WHITE:
	set(v):
		if fill_color == v:
			return
		fill_color = v
		queue_redraw()


func _init() -> void:
	# Purely a readout: never take focus or swallow a tap meant for the mobile controls.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE


# Where the needle sits for value `v` on a bar spanning `top`..`top + height`: the bottom
# when empty, the top when full.
static func level_y(v: float, top: float, height: float) -> float:
	return top + height * (1.0 - clampf(v, 0.0, 1.0))


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	draw_rect(Rect2(Vector2.ZERO, size), UITheme.BLACK)
	var bar_x := floorf((size.x - BAR_W) * 0.5)
	var bar_h := maxf(0.0, size.y - BAR_TOP - ICON_AREA)
	var level := roundf(level_y(value, BAR_TOP, bar_h))
	var track := UITheme.INK
	track.a = TRACK_ALPHA
	draw_rect(Rect2(bar_x, BAR_TOP, BAR_W, bar_h), track)
	draw_rect(Rect2(bar_x, level, BAR_W, BAR_TOP + bar_h - level), fill_color)
	var tick := UITheme.INK
	tick.a = TICK_ALPHA
	for i in 5:
		var tick_w := 2.0 if i % 2 == 1 else 3.0
		draw_rect(Rect2(bar_x + BAR_W + 1, roundf(BAR_TOP + bar_h * i / 4.0), tick_w, 1.0), tick)
	_draw_name(bar_x, bar_h)
	draw_rect(Rect2(bar_x - NEEDLE_OVERHANG, level - NEEDLE_H * 0.5, BAR_W + NEEDLE_OVERHANG * 2, NEEDLE_H), UITheme.INK)
	var icon_centre := Vector2(size.x * 0.5, size.y - ICON_AREA * 0.5)
	PixelIcon.draw_snapped(self, GaugeIcons.texture(icon), icon_centre, ICON_SCALE, UITheme.INK)


# The name reads bottom-to-top along the bar, centred on it. Rotated -90°, the text's
# baseline runs up the screen and its letters stand out to the left of the baseline.
func _draw_name(bar_x: float, bar_h: float) -> void:
	var font := UITheme.font()
	var text: String = NAMES.get(icon, "")
	var ink := UITheme.INK
	ink.a = NAME_ALPHA
	var text_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE).x
	var glyph_h := font.get_ascent(NAME_FONT_SIZE) - font.get_descent(NAME_FONT_SIZE)
	var baseline_x := bar_x + floorf((BAR_W + glyph_h) * 0.5)
	var start_y := BAR_TOP + bar_h - floorf((bar_h - text_w) * 0.5)
	draw_set_transform(Vector2(baseline_x, start_y), -PI * 0.5)
	draw_string(font, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, -1, NAME_FONT_SIZE, ink)
	draw_set_transform(Vector2.ZERO)

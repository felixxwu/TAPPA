class_name HudDial
extends Control
# Docs: features/hud.md — update in the same change as this file.
# Tests: tests/headless/test_hud.gd — extend in the same change.
# The in-run gauge cluster (features/hud.md): one rev-counter dial in the bottom-right
# corner that also carries every other gauge. The rim is health, the face glows red as
# the engine heats up, the gap at the bottom is boost and the ring of dots round the gear
# is the nitrous tank. hud.gd writes the readings below each frame and calls queue_redraw.

const RADIUS := 96
const BEZEL_W := 9
const SIZE := (RADIUS + BEZEL_W + 8) * 2
const BEZEL_SEGMENTS := 28
const NITROUS_PIPS := 10
const PIP_RING := 33
const FONT := UITheme.FONT_SIZE
const GEAR_FONT := UITheme.FONT_SIZE * 3
# The scale sweeps 270° clockwise from bottom-left, leaving the bottom quarter free for boost.
const SWEEP_START := 0.75 * PI
const SWEEP := 1.5 * PI
const BLINK_HZ := 3.0

const OFF := Color(0.11, 0.13, 0.09)
const DEAD_BEZEL := Color(0.16, 0.1, 0.08)
const NEEDLE := Color(1.0, 0.35, 0.24)

var rpm := 0.0
var scale_rpm := 8000.0
# Where the red zone starts. It follows the engine's damage-capped redline, so a hurt
# engine's red zone creeps down the dial.
var redline_rpm := 6500.0
var gear_text := "N"
# A negative reading means that gauge isn't shown: health off in settings, no thermal
# model, no turbo/supercharger, no nitrous fitted.
var hp := -1.0
var hp_color := Color.GREEN
var temp := -1.0
var overheating := false
var boost := -1.0
var boost_color := Color.BLUE
var nitrous := -1.0
var nitrous_color := Color.PURPLE
var nitrous_on := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2.ONE * SIZE


# Bottom-right, the same gap in from the edges as the minimap is at bottom-left.
static func home_rect(screen: Vector2) -> Rect2:
	var gap := float(UITheme.FONT_SIZE)
	return Rect2(screen - Vector2.ONE * (SIZE + gap), Vector2.ONE * SIZE)


# Top of the dial's scale for an engine with this redline: the next whole thousand at
# least 1000 rpm past it, so the red zone always has room to read.
static func scale_for(redline: float) -> float:
	return ceilf((redline + 1000.0) / 1000.0) * 1000.0


static func angle_at(frac: float) -> float:
	return SWEEP_START + SWEEP * clampf(frac, 0.0, 1.0)


func _draw() -> void:
	var c := (size * 0.5).round()
	var r := float(RADIUS)
	_draw_face(c, r)
	if hp >= 0.0:
		_draw_bezel(c, r)
	_draw_scale(c, r)
	if boost >= 0.0:
		_draw_boost(c, r)
	if overheating:
		_text("HOT", c + Vector2(0, -50), FONT, UITheme.RED if _blink() else UITheme.GOLD)
	else:
		_text("x1000", c + Vector2(0, -50), FONT, UITheme.INK_DIM)
	var a := angle_at(rpm / scale_rpm)
	var dir := Vector2.from_angle(a)
	draw_line(c + dir * 44.0, c + dir * (r - 10.0), NEEDLE, 4.0, true)
	if nitrous >= 0.0:
		_draw_nitrous(c)
	_text(gear_text, c + Vector2(0, 2), GEAR_FONT, UITheme.INK)


# Black at the centre, warming to red at the rim as the engine heats past half temperature.
func _draw_face(c: Vector2, r: float) -> void:
	var hot := clampf((temp - 0.5) / 0.5, 0.0, 1.0) if temp >= 0.0 else 0.0
	var rim := Color(0.08, 0.09, 0.07).lerp(Color(0.75, 0.04, 0.03), hot * hot)
	const STEPS := 6
	for i in STEPS:
		var t := float(i) / (STEPS - 1)
		draw_circle(c, (r + 3.0) * lerpf(1.0, 0.6, t), rim.lerp(UITheme.BLACK, t), true, -1.0, true)


func _draw_bezel(c: Vector2, r: float) -> void:
	var lit := roundi(clampf(hp, 0.0, 1.0) * BEZEL_SEGMENTS)
	var step := TAU / BEZEL_SEGMENTS
	var col := hp_color
	for i in BEZEL_SEGMENTS:
		var a := PI * 0.5 + i * step + 0.02
		draw_arc(c, r + BEZEL_W, a, a + step - 0.04, 8, col if i < lit else DEAD_BEZEL, BEZEL_W, true)


func _draw_scale(c: Vector2, r: float) -> void:
	var red_from := clampf(redline_rpm / scale_rpm, 0.0, 1.0)
	draw_arc(c, r - 5.0, angle_at(red_from), angle_at(1.0), 24, UITheme.RED, 8.0, true)
	var thousands := roundi(scale_rpm / 1000.0)
	var label_every := 1 if thousands <= 10 else 2
	for i in thousands * 2 + 1:
		var a := angle_at(i / (thousands * 2.0))
		var dir := Vector2.from_angle(a)
		var major := i % 2 == 0
		draw_line(c + dir * (r - (15.0 if major else 9.0)), c + dir * (r - 2.0),
			UITheme.INK if major else UITheme.INK_DIM, 3.0 if major else 2.0, true)
		var k := int(i / 2.0)
		if major and k % label_every == 0:
			var in_red := k * 1000.0 >= redline_rpm
			_text(str(k), c + dir * (r - 31.0), FONT, UITheme.RED if in_red else UITheme.INK)


# Boost fills the empty bottom quarter of the dial from left to right.
func _draw_boost(c: Vector2, r: float) -> void:
	var from := 0.75 * PI - 0.1
	var to := 0.25 * PI + 0.1
	var rr := r - 6.0
	draw_arc(c, rr, to, from, 16, OFF, 7.0, true)
	var v := clampf(boost, 0.0, 1.0)
	if v > 0.001:
		draw_arc(c, rr, from, from - (from - to) * v, 16, boost_color, 7.0, true)
	_text("BOOST", c + Vector2(0, r - 24.0), FONT, UITheme.INK_DIM)


func _draw_nitrous(c: Vector2) -> void:
	var lit := ceili(clampf(nitrous, 0.0, 1.0) * NITROUS_PIPS - 0.001)
	var dim := nitrous_color.darkened(0.75)
	for i in NITROUS_PIPS:
		var p := c + Vector2.from_angle(-PI * 0.5 + i * TAU / NITROUS_PIPS) * PIP_RING
		var on := i < lit
		draw_circle(p, 5.0 if on and nitrous_on else 4.0, nitrous_color if on else dim, true, -1.0, true)


func _blink() -> bool:
	return fmod(Time.get_ticks_msec() / 1000.0 * BLINK_HZ, 1.0) < 0.5


# Centred text on whole pixels with the house hard drop shadow.
func _text(s: String, centre: Vector2, font_size: int, col: Color) -> void:
	var font := UITheme.font()
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var base := Vector2(centre.x - w * 0.5,
		centre.y + (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5).round()
	draw_string(font, base + Vector2(2, 2), s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, UITheme.SHADOW)
	draw_string(font, base, s, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)

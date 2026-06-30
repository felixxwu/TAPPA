class_name PauseIcon
extends Control
# A crisp two-bar pause glyph drawn in `_draw` — the project font (Syne Mono) has no
# ⏸ glyph, so the in-run Pause button used a stand-in "| |" string that read as cramped
# punctuation. This draws two even, sharp-cornered bars in the house ink colour (rule:
# no rounded corners), sized to the control, so the button shows a real pause symbol.
# Drop it (mouse-ignoring) into the Pause button and let it fill.

const BAR_W_FRAC := 0.26   # each bar's width as a fraction of the control width
const GAP_FRAC := 0.18     # gap between the bars, as a fraction of the width
const BAR_H_FRAC := 0.62   # bar height as a fraction of the control height

var bar_color := UITheme.INK


func _draw() -> void:
	var bar_w := size.x * BAR_W_FRAC
	var bar_h := size.y * BAR_H_FRAC
	var top := (size.y - bar_h) * 0.5
	var half_gap := size.x * GAP_FRAC * 0.5
	var mid := size.x * 0.5
	draw_rect(Rect2(mid - half_gap - bar_w, top, bar_w, bar_h), bar_color)
	draw_rect(Rect2(mid + half_gap, top, bar_w, bar_h), bar_color)

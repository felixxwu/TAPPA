class_name UIHardShadowBox
extends StyleBox
# Docs: features/ui-design-system.md — update in the same change as this file.
# Tests: tests/headless/test_ui_theme.gd — extend in the same change.
#
# A StyleBox WRAPPER that draws UITheme's sharp, zero-blur drop shadow behind
# `inner`, then draws `inner` on top — the theme-wide form of the same hard
# shadow CardCarousel casts behind its cards (see features/card-carousel.md →
# "Cards cast a sharp drop shadow" for why it can't be StyleBoxFlat's own
# shadow_* properties: that shadow rect is `inner` expanded on ALL sides before
# the offset, so a purely-diagonal, zero-blur offset is unreachable through it).
#
# CardCarousel needs a separate sibling Panel for its shadow because its cards
# are absolute-positioned children of a plain Control (`_strip`), outside the
# normal layout system, and `card.root` clips its own contents — a shadow drawn
# INSIDE that draw call would be clipped away. An ordinary themed Button or
# PanelContainer has no such constraint: it draws through exactly one StyleBox,
# so the shadow can be baked straight into that single draw call instead. Build
# one via UITheme.shadowed(box) rather than constructing this directly.
var inner: StyleBox


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	if inner == null:
		return
	var off := UITheme.card_shadow_offset()
	RenderingServer.canvas_item_add_rect(
		to_canvas_item, Rect2(rect.position + Vector2(off, off), rect.size),
		UITheme.CARD_SHADOW_COLOR)
	inner.draw(to_canvas_item, rect)


# Forward inner's content margin so a Container laying out children inside a
# wrapped panel/button pads them exactly as it would around `inner` alone —
# the shadow must never nudge a widget's own content.
func _get_style_margin(side: Side) -> float:
	return inner.get_margin(side) if inner else 0.0


func _get_minimum_size() -> Vector2:
	return inner.get_minimum_size() if inner else Vector2.ZERO

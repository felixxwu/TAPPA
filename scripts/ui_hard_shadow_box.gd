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
	# AN INVISIBLE SURFACE CASTS NO SHADOW. A wrapped box whose fill is fully transparent
	# draws nothing itself, so there is no opaque face to hide the shadow quad — the whole
	# offset rect shows through at its full 20% black, reading as a large dark translucent
	# panel the size of the widget rather than as a thin sliver under its edge. That is
	# exactly what MenuPage's carousel-page body box is: `UITheme.panel_box(0.0)` wrapped in
	# `shadowed()` so the live 3D showcase shows through the gaps between cards
	# (features/card-carousel.md), which instead painted a dark box around the whole
	# carousel. The cards, buttons and opaque panels on top of it are unaffected — they have
	# a real fill, so they still cast.
	if not casts_shadow():
		inner.draw(to_canvas_item, rect)
		return
	var off := UITheme.card_shadow_offset()
	RenderingServer.canvas_item_add_rect(
		to_canvas_item, Rect2(rect.position + Vector2(off, off), rect.size),
		UITheme.CARD_SHADOW_COLOR)
	inner.draw(to_canvas_item, rect)


# Whether `inner` paints anything solid enough to cast. A StyleBoxEmpty paints nothing at
# all; a StyleBoxFlat with a zero-alpha background paints (at most) its border, and a hollow
# outline casting a filled rect of shadow is just as wrong as a transparent panel doing it,
# so alpha 0 is the whole test.
func casts_shadow() -> bool:
	if inner is StyleBoxEmpty:
		return false
	var flat := inner as StyleBoxFlat
	if flat != null and flat.bg_color.a <= 0.0:
		return false
	return true


# NOTE: there is deliberately no `_get_style_margin` override here. It reads like the
# obvious way to forward `inner`'s padding, but it isn't a real scriptable virtual on
# `StyleBox` in this Godot version (only `_draw`, `_get_draw_rect`, `_get_minimum_size`
# and `_test_mask` are) — a method by that name is silently never called, and
# `get_margin()` falls back to 0 for every side, flushing a wrapped Container's children
# against its edges. `UITheme.shadowed()` instead copies `inner`'s margins onto this
# wrapper's own real `content_margin_*` properties ONCE, at construction time, which
# `get_margin()` does honour — see it for the full story. Don't re-add this method
# thinking you're fixing a gap; it does nothing.


func _get_minimum_size() -> Vector2:
	return inner.get_minimum_size() if inner else Vector2.ZERO

class_name PixelIcon
extends Control
# Docs: features/ui-design-system.md — update in the same change as this file.
# Tests: tests/headless/test_pixel_icon.gd — extend in the same change.
# Draws a 1-bit pixel-art icon at the largest whole-number scale that fits, snapped to whole pixels so it never smears.

var texture: Texture2D:
	set(v):
		texture = v
		queue_redraw()
var tint := Color.WHITE


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Cards slide by fractional amounts while scrolling, so re-snap whenever we move.
	set_notify_transform(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		queue_redraw()


func _draw() -> void:
	if texture == null:
		return
	var tex_size := texture.get_size()
	var k := maxi(1, int(minf(size.x / tex_size.x, size.y / tex_size.y)))
	draw_snapped(self, texture, size * 0.5, k, tint)


# Draw `tex` at whole-number scale `k`, centred on local point `centre`, snapped to the pixel grid.
static func draw_snapped(ci: CanvasItem, tex: Texture2D, centre: Vector2, k: int, color := Color.WHITE) -> void:
	ci.draw_texture_rect(tex, snapped_rect(ci.get_global_transform(), tex.get_size(), centre, k), false, color)


# The local rect to draw a `tex_size` texture at scale `k` around `centre`, whose on-screen
# corner (through `xform`) lands on a whole pixel.
static func snapped_rect(xform: Transform2D, tex_size: Vector2, centre: Vector2, k: int) -> Rect2:
	var drawn := tex_size * k
	return Rect2(xform.affine_inverse() * (xform * (centre - drawn * 0.5)).round(), drawn)

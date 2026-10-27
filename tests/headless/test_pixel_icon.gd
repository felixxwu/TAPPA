extends GutTest
# Pixel-art icons (PixelIcon, icons/cards/, icons/hud/) — see features/ui-design-system.md.

const DIRS := ["res://icons/cards/", "res://icons/hud/"]


# Every icon is strictly 1-bit: each texel fully white or fully clear, as imported (a lossy
# import would sneak in-between values back in).
func test_every_icon_is_pure_white_or_transparent() -> void:
	var checked := 0
	for dir: String in DIRS:
		for file: String in ResourceLoader.list_directory(dir):
			if not file.ends_with(".png"):
				continue
			var img: Image = (load(dir + file) as Texture2D).get_image()
			img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			var bad := 0
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					if not (c.a == 0.0 or c == Color.WHITE):
						bad += 1
			assert_eq(bad, 0, "%s%s has only white or clear texels" % [dir, file])
			checked += 1
	assert_gt(checked, 0, "found icons to check")


func test_the_drawn_rect_is_a_whole_multiple_on_whole_pixels() -> void:
	var xform := Transform2D(0.0, Vector2(103.37, 41.6))
	var rect := PixelIcon.snapped_rect(xform, Vector2(20, 20), Vector2(45.25, 33.5), 4)
	assert_eq(rect.size, Vector2(80, 80), "drawn at exactly k times the texture size")
	var screen := xform * rect.position
	assert_almost_eq((screen - screen.round()).length(), 0.0, 0.001, "the top-left lands on a whole screen pixel")
	assert_almost_eq((rect.get_center() - Vector2(45.25, 33.5)).length(), 0.0, 0.71,
		"it stays centred to within half a pixel")


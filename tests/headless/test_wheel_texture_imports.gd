extends GutTest
# Import-settings integrity for the COSMETIC WHEEL textures (features/wheel-customization.md).
#
# Wheels are the one texture family every car can now wear (WheelStyle/CarLibrary.wheel_catalogue),
# so a bad import setting on ANY of them is reachable from ANY car. Two rules, both about
# the ANDROID/mobile export path (project.godot sets textures/vram_compression/import_etc2_astc,
# and the mobile renderer is gl_compatibility):
#
#   1. detect_3d/compress_to MUST be 0. With Godot's default of 1, the first time a texture
#      is sampled in 3D the editor SILENTLY re-imports it as VRAM-compressed — which is how
#      the car body atlases drifted once already (see todo/mobile-web-performance.md,
#      "lessons" item 7). The wheel swap makes every wheel texture 3D-sampled, so every one
#      of them is now exposed to that drift.
#   2. A texture that IS VRAM-compressed (compress/mode 2) must have block-aligned
#      dimensions — ETC2/ASTC compress in 4x4 blocks, so a non-multiple-of-4 image is not
#      safely representable and misbehaves on device while looking fine on a desktop
#      D3D12/Vulkan build. (blender/xjs/wheel.png is 127x127, which is exactly this trap.)
#
# Deliberately NOT pinning WHICH textures exist, what their sizes are, or which compress
# mode any of them chose — those are authoring decisions. Only the safety rule is asserted.

const VRAM_COMPRESSED := 2
const BLOCK := 4


func _wheel_texture_paths() -> Array[String]:
	var out: Array[String] = []
	for entry in CarLibrary.all():
		var tex := String(entry.get("wheel_texture", ""))
		if not tex.is_empty() and not out.has(tex):
			out.append(tex)
	return out


func test_every_wheel_texture_opts_out_of_the_silent_3d_reimport() -> void:
	var paths := _wheel_texture_paths()
	assert_gt(paths.size(), 0, "the roster should reference at least one wheel texture")
	for path in paths:
		var import_path := path + ".import"
		assert_true(FileAccess.file_exists(import_path),
			"%s should have an .import file" % path)
		if not FileAccess.file_exists(import_path):
			continue
		var cfg := ConfigFile.new()
		assert_eq(cfg.load(import_path), OK, "%s should parse" % import_path)
		assert_eq(int(cfg.get_value("params", "detect_3d/compress_to", 1)), 0,
			"%s must set detect_3d/compress_to=0 — otherwise Godot silently re-imports it "
			% import_path + "as VRAM-compressed the first time it is sampled in 3D")


func test_vram_compressed_wheel_textures_are_block_aligned() -> void:
	for path in _wheel_texture_paths():
		var import_path := path + ".import"
		if not FileAccess.file_exists(import_path):
			continue
		var cfg := ConfigFile.new()
		if cfg.load(import_path) != OK:
			continue
		if int(cfg.get_value("params", "compress/mode", 0)) != VRAM_COMPRESSED:
			continue  # not block-compressed on export — alignment is irrelevant
		# The IMPORTED texture, not the source file: process/size_limit can rescale on the
		# way in, and it's the imported dimensions the block compressor actually sees.
		var tex := load(path) as Texture2D
		assert_not_null(tex, "%s should load as a Texture2D" % path)
		if tex == null:
			continue
		assert_eq(tex.get_width() % BLOCK, 0,
			"%s is VRAM-compressed, so its width must be a multiple of %d (ETC2/ASTC block)"
			% [path, BLOCK])
		assert_eq(tex.get_height() % BLOCK, 0,
			"%s is VRAM-compressed, so its height must be a multiple of %d (ETC2/ASTC block)"
			% [path, BLOCK])

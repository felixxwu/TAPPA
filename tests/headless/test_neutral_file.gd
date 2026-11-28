extends GutTest
# NeutralFile (scripts/neutral_file.gd) and LevelBake.save_neutral / manifest: a written container parses back, and the manifest tracks the bake's data.
# Every bake here is synthetic; nothing reads the shipped Hafren save.

const PATH := "user://test_neutral_file.bake.bin"


func after_each() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func _bake() -> LevelBake:
	var hm: Array = []
	for r in 9:
		for c in 9:
			hm.append(2.0 * sin(c / 2.0) + cos(r / 3.0))
	var data := LevelData.new()
	data.load_save({"size": 60, "heightmap": hm, "roads": [[{"x": -20.0, "z": 0.0, "w": 3.0, "m": null, "tension": 1.0},
		{"x": 20.0, "z": 5.0, "w": 3.0, "m": null, "tension": 1.0}]], "trees": [
		{"x": 10.0, "z": 10.0, "rot": 0.0, "sx": 1.0, "sy": 1.0, "kind": "tree.png"},
		{"x": -10.0, "z": -10.0, "rot": 30.0, "sx": 1.0, "sy": 1.5, "kind": "tree.png"}]})
	var b := LevelBake.bake(data, "k")
	var rows := []
	for r in LevelBake.VIS_KEY + 3:
		rows.append([r % 2])
	b.set_visibility(4, rows)
	return b


# Header JSON and each section's raw bytes, read the way a reader without Godot would.
func _read(path: String) -> Array:
	var bytes := FileAccess.get_file_as_bytes(path)
	var h_len := bytes.decode_u32(0)
	assert_between(h_len, 2, bytes.size() - 4, "header length in range")
	var header: Variant = JSON.parse_string(bytes.slice(4, 4 + h_len).get_string_from_utf8())
	assert_true(header is Dictionary, "the header is JSON")
	var at := 4 + h_len
	var raws := {}
	for s: Dictionary in header["sections"]:
		var zipped := bytes.slice(at, at + int(s["bytes"]))
		var raw_size := zipped.decode_u32(0)
		var raw := zipped.slice(4).decompress(raw_size, FileAccess.COMPRESSION_ZSTD) if raw_size > 0 else PackedByteArray()
		assert_eq(raw.size(), raw_size, "%s unzips to its declared size" % s["name"])
		raws[s["name"]] = zipped
		at += int(s["bytes"])
	assert_eq(at, bytes.size(), "the sections' bytes sum to the rest of the file")
	return [header, raws]


func test_a_written_file_parses_back() -> void:
	var raw := PackedByteArray([1, 2, 3, 4, 5])
	assert_eq(NeutralFile.write(PATH, {"kind": "t"}, [["a", NeutralFile.zip(raw)], ["empty", NeutralFile.zip(PackedByteArray())]]), OK)
	var got := _read(PATH)
	assert_eq(int(got[0]["format"]), NeutralFile.FORMAT)
	assert_eq(got[0]["kind"], "t")


func test_each_bake_section_is_the_blob_the_bake_res_stores() -> void:
	var b := _bake()
	assert_eq(b.save_neutral(PATH, "nk"), OK)
	var got := _read(PATH)
	assert_eq(got[0]["kind"], "level_bake")
	assert_eq(got[0]["neutral_key"], "nk")
	assert_eq(got[0]["source_key"], "k")
	assert_eq(got[1].keys(), LevelBake.BLOBS)
	for name: String in LevelBake.BLOBS:
		assert_eq(got[1][name], b._get(name), name)
	for s: Dictionary in got[0]["sections"]:
		assert_true(s["encoding"] in ["raw", "delta_u16_planes", "delta_i32_planes"], s["name"])


func test_the_manifest_is_stable_and_follows_the_heights() -> void:
	var a := _bake()
	var b := _bake()
	assert_eq(a.manifest("f"), b.manifest("f"))
	var lines := a.manifest("f")
	var sorted := lines.duplicate()
	sorted.sort()
	assert_eq(lines, sorted, "sorted")
	assert_true(lines.has(NeutralFile.line("f", "row.%d" % LevelBake.VIS_KEY, a.decoded_row(LevelBake.VIS_KEY).to_byte_array())), "a keyframe row is listed")
	b.heights.encode_u16(0, b.heights.decode_u16(0) + 1)
	assert_ne(a.manifest("f"), b.manifest("f"), "one height changed")


func test_a_manifest_line_writes_floats_as_their_bytes() -> void:
	assert_eq(NeutralFile.line("f", "x", 1.0), "f\tx\t000000000000f03f")
	assert_eq(NeutralFile.line("f", "n", 7), "f\tn\t7")
	assert_eq(NeutralFile.line("f", "b", PackedByteArray()), "f\tb\te3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

extends GutTest
# Bare-logic checks of the geometry samples and camera path writers; no world is booted.

const Camera := preload("res://tools/neutral_camera.gd")
const Geometry := preload("res://tools/neutral_geometry.gd")


func _arrays(n: int) -> Array:
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO])
	a[Mesh.ARRAY_COLOR] = PackedColorArray([Color.WHITE])
	a[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO])
	a[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2.ZERO])
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 0, 0])
	return a


func _header(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	var len := f.get_32()
	return JSON.parse_string(f.get_buffer(len).get_string_from_utf8())


func test_sample_indices_point_into_the_written_lists() -> void:
	var chunks := {"0,0,0,0": [0, Vector2i(0, 0), 4, 0, _arrays(4)], "0,0,0,3": [0, Vector2i(0, 0), 4, 3, _arrays(4)],
		"2,5,5,0": [2, Vector2i(5, 5), 4, 0, _arrays(4)]}  # the last is never named
	var cover := {"1,1,grass,false": [Vector2i(1, 1), "grass", false, PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])]}
	var samples := [{"pos": Vector3(1, 2, 3), "chunks": ["0,0,0,3"], "cover": ["1,1,grass,false"]},
		{"pos": Vector3(4, 5, 6), "chunks": ["0,0,0,0", "0,0,0,3"], "cover": []}]
	var path := "user://test_neutral_geometry.tapn"
	var lines := Geometry._write(path, chunks, cover, {}, samples)
	assert_false(lines.is_empty())
	var h := _header(path)
	assert_eq(h["chunks"].size(), 2, "only the variants a sample names are kept")
	assert_eq(h["samples"].size(), 2)
	for s: Dictionary in h["samples"]:
		for i: float in s["chunks"]:
			assert_between(int(i), 0, h["chunks"].size() - 1)
		for i: float in s["cover"]:
			assert_between(int(i), 0, h["cover"].size() - 1)
	var named: Dictionary = h["chunks"][int(h["samples"][0]["chunks"][0])]
	assert_eq(int(named["mask"]), 3)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_camera_path_header_and_manifest() -> void:
	var path := "user://test_camera_path.tapn"
	var cam := PackedFloat32Array()
	cam.resize(30)
	var car := PackedFloat32Array()
	car.resize(24)
	var lines := Camera.write(path, cam, car, 60, "x")
	var h := _header(path)
	assert_eq(int(h["ticks"]), 2)
	assert_eq(int(h["hz"]), 60)
	assert_true(h["config"].has("horizontal_stretch"))
	assert_true(lines.size() >= 4)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".lines"))

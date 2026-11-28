class_name NeutralCamera
# Docs: features/neutral-format.md — update in the same change as this file.
# Writes camera_path.tapn: the camera and car pose for every tick of the Hafren replay, so the Godot-free viewer flies the same path.
# export() runs the golden replay in a child Godot (benchmark/level_replay.gd --camera-out) and returns its manifest lines.

const FILE := "camera_path.tapn"
const REF_WINDOW := Vector2i(1920, 1080)  # the window the logical size is worked out for; a headless run has none
const CONFIG_FIELDS := ["virtual_resolution", "horizontal_stretch"]


static func export(dir: String) -> PackedStringArray:
	var out := dir.path_join(FILE)
	var cfg := ProjectSettings.globalize_path("res://override.cfg")
	if FileAccess.file_exists(cfg):
		printerr("neutral_camera: override.cfg already exists; move it away first")
		return PackedStringArray()
	# A golden replay needs physics on the main thread, which only an override.cfg can set.
	FileAccess.open(cfg, FileAccess.WRITE).store_string("[physics]\n3d/run_on_separate_thread=false\n")
	var output := []
	var code := OS.execute(OS.get_executable_path(), ["--headless", "--fixed-fps", "60", "--path",
		ProjectSettings.globalize_path("res://"), "res://benchmark/level_replay.tscn", "--", "--golden", "--full",
		"--camera-out=" + out], output, true)
	DirAccess.remove_absolute(cfg)
	if code != 0 or not FileAccess.file_exists(out + ".lines"):
		printerr("neutral_camera: replay failed (exit %d): %s" % [code, "".join(output).right(2000)])
		return PackedStringArray()
	var lines := PackedStringArray(FileAccess.get_file_as_string(out + ".lines").split("\n", false))
	DirAccess.remove_absolute(out + ".lines")
	return lines


# One row per tick: camera (transform 12, fov, near, far) and car (transform 12). Returns the manifest lines.
static func write(path: String, camera: PackedFloat32Array, car: PackedFloat32Array, hz: int, car_id: String) -> PackedStringArray:
	var config := {}
	for f: String in CONFIG_FIELDS:
		var v: Variant = Config.data.get(f)
		config[f] = [v.x, v.y] if v is Vector2 else v
	var stretch: float = Config.data.horizontal_stretch
	var size := DisplayStretch.logical_size(REF_WINDOW, stretch)
	var header := {"kind": "camera_path", "hz": hz, "ticks": int(car.size() / 12.0), "car": car_id,
		"logical_size": [size.x, size.y], "horizontal_stretch": stretch, "config": config}
	var raw := [["camera", camera.to_byte_array()], ["car", car.to_byte_array()]]
	var sections := []
	var lines := PackedStringArray()
	for s: Array in raw:
		sections.append([s[0], NeutralFile.zip(s[1])])
		lines.append(NeutralFile.line(FILE, s[0], s[1]))
	var err := NeutralFile.write(path, header, sections)
	if err != OK:
		printerr("neutral_camera: couldn't write %s (%s)" % [path, error_string(err)])
		return PackedStringArray()
	lines.append(NeutralFile.line(FILE, "ticks", header["ticks"]))
	lines.append(NeutralFile.line(FILE, "hz", hz))
	lines.sort()
	var f := FileAccess.open(path + ".lines", FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("neutral_camera: wrote %s, %d ticks" % [path, header["ticks"]])
	return lines


# A transform as 12 floats: basis x, y, z columns' components in order, then the origin (level_replay's pose layout).
static func flat(t: Transform3D) -> PackedFloat32Array:
	var b := t.basis
	return PackedFloat32Array([b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, t.origin.x, t.origin.y, t.origin.z])

extends Node
# Web/phone probe: does vertex texture fetch work here? Reached with ?vtf=1 (see title_boot.gd); shows PASS or FAIL in big text.
# Under Forward+ the corner reads ~0.59 instead of 0.25: that is linear-to-sRGB on the read-back, not a vertex fetch failure. The game uses Compatibility, where it reads true.

const N := 256
const HIGH := 0.75
const LOW := 0.25
const SHADER := preload("res://benchmark/vtf_probe.gdshader")

var _label := Label.new()
var _results := {}
var _head := ""


func _ready() -> void:
	_label.add_theme_font_size_override("font_size", 36)
	_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	var layer := CanvasLayer.new()
	layer.add_child(_label)
	add_child(layer)
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_head = "%s | %s\n%s\nvertex texture units: %s" % [RenderingServer.get_current_rendering_method(),
		RenderingServer.get_video_adapter_name(), RenderingServer.get_video_adapter_vendor(), _max_vertex_units()]
	_label.text = _head + "\ntesting..."
	await _run("R16F", false)
	await _run("RG8", true)
	_show()


func _max_vertex_units() -> String:
	if not Platform.is_web():
		return "n/a"
	return str(JavaScriptBridge.eval("(function(){var c=document.createElement('canvas').getContext('webgl2');return c?c.getParameter(c.MAX_VERTEX_TEXTURE_IMAGE_UNITS):-1})()", true))


func _texture(two_channel: bool) -> ImageTexture:
	var img := Image.create(N, N, false, Image.FORMAT_RG8 if two_channel else Image.FORMAT_RH)
	var raw := roundi(LOW * 65535.0)
	var raw_high := roundi(HIGH * 65535.0)
	for y in N:
		for x in N:
			var hi := absi(x - 128) <= 1 and absi(y - 128) <= 1
			var v := raw_high if hi else raw
			if two_channel:
				img.set_pixel(x, y, Color((v >> 8) / 255.0, (v & 255) / 255.0, 0))
			else:
				img.set_pixel(x, y, Color(v / 65535.0, 0, 0))
	return ImageTexture.create_from_image(img)


func _run(label: String, two_channel: bool) -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(128, 128)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 256.0
	cam.far = 200.0
	cam.position = Vector3(0, 100, 0)
	cam.rotation_degrees = Vector3(-90, 0, 0)
	vp.add_child(cam)
	var plane := PlaneMesh.new()
	plane.size = Vector2(256, 256)
	plane.subdivide_width = N
	plane.subdivide_depth = N
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("tex", _texture(two_channel))
	mat.set_shader_parameter("two_channel", two_channel)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	mi.extra_cull_margin = 100.0
	vp.add_child(mi)
	add_child(vp)
	for i in 5:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var centre := img.get_pixel(64, 64).r
	var corner := img.get_pixel(2, 2).r
	_results[label] = {"ok": absf(centre - HIGH) < 0.03 and absf(corner - LOW) < 0.03, "centre": centre, "corner": corner}
	vp.queue_free()


func _show() -> void:
	var all_ok := true
	var lines := ""
	for k in _results:
		var r: Dictionary = _results[k]
		all_ok = all_ok and r.ok
		lines += "\n%s: %s (centre %.3f want %.2f, corner %.3f want %.2f)" % [k, "ok" if r.ok else "bad", r.centre, HIGH, r.corner, LOW]
	_label.text = ("PASS" if all_ok else "FAIL") + "\n" + _head + lines
	_label.add_theme_color_override("font_color", Color.GREEN if all_ok else Color.RED)
	print("VTF_PROBE ", _label.text.replace("\n", " | "))


func _process(_delta: float) -> void:
	if not _results.is_empty() and _results.size() == 2:
		_label.text = _label.text.get_slice("\nfps", 0) + "\nfps %d" % Engine.get_frames_per_second()

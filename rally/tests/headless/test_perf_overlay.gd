extends GutTest

# Tests for scripts/perf_overlay.gd — the diagnostic frame-profiler overlay.
# Headless has no GPU, so we don't assert on render-time values; we verify the
# overlay wires up, toggles, samples without error, and correlates with the
# terrain integration counter.

const OverlayScript := preload("res://scripts/perf_overlay.gd")
const ManagerScript := preload("res://scripts/terrain_manager.gd")


func _make_terrain() -> Node3D:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.use_threaded_generation = false
	m.focus_path = NodePath("")
	var layer := TerrainLayer.new()
	layer.wavelength_m = 60.0
	layer.amplitude_m = 1.5
	m.layers = [layer] as Array[TerrainLayer]
	return m


func _make_overlay(terrain: Node3D = null) -> CanvasLayer:
	var o: CanvasLayer = OverlayScript.new(terrain)
	add_child_autofree(o)
	return o


func test_overlay_starts_hidden_and_idle() -> void:
	var o := _make_overlay()
	assert_false(o.visible, "overlay hidden until toggled on")
	assert_eq(o._spikes, 0, "no spikes before activation")


func test_activation_toggles_visibility_and_measurement() -> void:
	var o := _make_overlay()
	o._set_active(true)
	assert_true(o.visible, "active overlay is visible")
	assert_true(o._measure_on, "render-time measurement enabled while active")
	o._set_active(false)
	assert_false(o.visible, "deactivated overlay is hidden")
	assert_false(o._measure_on, "render-time measurement disabled while idle")


func test_sample_and_format_do_not_error() -> void:
	var o := _make_overlay(_make_terrain())
	o._set_active(true)
	var s: Dictionary = o._sample(16.7)
	assert_true(s.has("frame_ms") and s.has("render_gpu_ms"), "sample has expected keys")
	assert_eq(s.frame_ms, 16.7, "frame_ms passed through")
	var text: String = o._format(s)
	assert_true(text.contains("FPS") and text.contains("frame"), "formatted text has a header")


func test_avg_and_max_track_the_window() -> void:
	var o := _make_overlay()
	o._frames = PackedFloat32Array([10.0, 20.0, 60.0, 10.0])
	assert_almost_eq(o._avg(), 25.0, 0.001, "average of the window")
	assert_eq(o._max(), 60.0, "max of the window")


func test_chunks_loaded_reflects_terrain() -> void:
	var terrain := _make_terrain()
	add_child_autofree(terrain)  # _ready builds the ring around origin
	var o := _make_overlay(terrain)
	o._set_active(true)
	var s: Dictionary = o._sample(16.7)
	var ring: int = 2 * ManagerScript.RADIUS + 1
	assert_eq(s.chunks, ring * ring, "overlay reads the loaded chunk count from terrain")

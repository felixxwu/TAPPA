extends Node
# Standalone performance benchmark — NOT part of the test suite. Run on demand:
#
#     ./run_benchmark.sh              # windowed: captures CPU *and* GPU/render
#     ./run_benchmark.sh --headless   # CPU-only (no GPU timing), quick
#     godot --path . res://benchmark/perf_benchmark.tscn -- --tree-mode=2   # GameConfig.tree_cutout_mode
#
# Drives the SAME run as the in-game benchmark (Settings → Benchmark,
# features/benchmark.md): free roam on the fixed benchmark world with the Benchmark
# autoload active, so an AutoDriver drives a route while BenchmarkRunner samples every
# frame. When the runner hands its summary to Benchmark.finish() we print it and quit.
# Loose, machine-dependent numbers — read them, don't gate on them.

# Safety cap on frames to wait for the run to end (it is time-boxed by
# BenchmarkRunner.MAX_RUN_SECONDS, plus the boot and shader warm-up).
const MAX_FRAMES := 60000


func _ready() -> void:
	print("\n=== rally performance benchmark ===")
	print("display: %s   (%s)\n" % [
		DisplayServer.get_name(),
		"windowed — GPU timing available" if not _headless() else "headless — CPU only"])
	print("-- free-roam benchmark run (world seed %d) --" % Benchmark.WORLD_SEED)
	if _headless():
		print("  note: headless — render cpu/gpu and vsync pacing are unavailable;")
		print("        frame interval reflects CPU work only. Run windowed for GPU timing.")

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tree-mode="):
			Benchmark.tree_mode = int(arg.get_slice("=", 1))  # GameConfig.tree_cutout_mode
	Benchmark.begin()
	var scene: Node = load(Scenes.FREE_ROAM).instantiate()
	add_child(scene)

	var frames := 0
	while Benchmark.results.is_empty() and frames < MAX_FRAMES:
		await get_tree().process_frame
		frames += 1

	if Benchmark.results.is_empty():
		print("  TIMED OUT after %d frames — the run never ended." % frames)
	else:
		_report(Benchmark.results)
		print("  terrain: ", Benchmark.results.get("terrain", {}))
		var driver := scene.get_node_or_null("AutoDriver") as AutoDriver
		if driver != null:
			print("  auto drive: ", driver.report())

	Benchmark.end()
	scene.queue_free()
	print("\n=== benchmark complete ===")
	get_tree().quit()


func _headless() -> bool:
	return DisplayServer.get_name() == "headless"


# Print the BenchmarkStats.summarise breakdown Benchmark.finish() stored.
func _report(s: Dictionary) -> void:
	print("  frames %d   duration %.1f s   distance %.0f m" % [
		int(s.get("frames", 0)), float(s.get("duration_s", 0.0)),
		float(s.get("distance_m", 0.0))])
	print("  fps          avg %7.1f    1%% low %7.1f" % [
		float(s.get("fps_avg", 0.0)), float(s.get("fps_1pct_low", 0.0))])
	print("  frame ms     avg %7.2f    p95 %7.2f   p99 %7.2f   max %7.2f" % [
		float(s.get("frame_avg_ms", 0.0)), float(s.get("frame_p95_ms", 0.0)),
		float(s.get("frame_p99_ms", 0.0)), float(s.get("frame_max_ms", 0.0))])
	print("  process ms   avg %7.2f    max %7.2f" % [
		float(s.get("process_ms_avg", 0.0)), float(s.get("process_ms_max", 0.0))])
	print("  physics ms   avg %7.2f    max %7.2f" % [
		float(s.get("physics_ms_avg", 0.0)), float(s.get("physics_ms_max", 0.0))])
	print("  render cpu   avg %7.2f    max %7.2f" % [
		float(s.get("render_cpu_ms_avg", 0.0)), float(s.get("render_cpu_ms_max", 0.0))])
	print("  render gpu   avg %7.2f    max %7.2f" % [
		float(s.get("render_gpu_ms_avg", 0.0)), float(s.get("render_gpu_ms_max", 0.0))])
	print("  draws %d   objects %d   prims %d   spikes>%dms %d" % [
		int(s.get("draws_avg", 0.0)), int(s.get("objects_avg", 0.0)),
		int(s.get("prims_avg", 0.0)), int(BenchmarkStats.SPIKE_MS),
		int(s.get("spikes", 0))])
	var disabled: Array = s.get("disabled", [])
	if not disabled.is_empty():
		print("  disabled: %s" % ", ".join(disabled))
	if float(s.get("render_gpu_ms_avg", 0.0)) <= 0.0 and not _headless():
		print("  note: GPU timer unsupported on this backend (e.g. OpenGL/macOS).")
		print("        With vsync off, frame interval ≈ GPU+present cost.")

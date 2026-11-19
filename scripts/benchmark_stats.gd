class_name BenchmarkStats
extends RefCounted
# Docs: features/benchmark.md — update in the same change as this file.
# Tests: tests/headless/test_benchmark_mode.gd, tests/headless/test_benchmark_report.gd, tests/headless/test_benchmark_ui.gd — extend in the same change.
# Pure math for the benchmark results breakdown (features/benchmark.md): turns
# the per-frame sample streams BenchmarkRunner records into the summary the
# results screen shows. No scene access — everything here is testable headless.

# A frame interval at or over this counts as a dropped-frame spike — the same
# threshold the PerfOverlay's spike log uses.
const SPIKE_MS := 28.0


static func mean(samples: Array) -> float:
	if samples.is_empty():
		return 0.0
	var total := 0.0
	for v in samples:
		total += v
	return total / samples.size()


static func peak(samples: Array) -> float:
	var m := 0.0
	for v in samples:
		m = maxf(m, v)
	return m


# The q-quantile (0..1) of the samples, by nearest-rank on a sorted copy.
static func percentile(samples: Array, q: float) -> float:
	if samples.is_empty():
		return 0.0
	var sorted := samples.duplicate()
	sorted.sort()
	var idx := int(round(clampf(q, 0.0, 1.0) * (sorted.size() - 1)))
	return sorted[idx]


# Summarise a run. `samples` maps stream name -> Array of per-frame values:
#   frame_ms (required), draws, objects, prims,
#   render_cpu_ms, render_gpu_ms, process_ms, physics_ms.
# The spike threshold: a frame this much slower than the target counts as a
# dropped-frame spike. Relative to the frame cap so it's meaningful at any target —
# a hardcoded 28 ms flags EVERY frame of a 30 fps (33 ms) run. `spike_ms` lets the
# caller pass the cap-derived value (see BenchmarkRunner); it defaults to SPIKE_MS
# (≈1.7× a 60 fps frame) so existing callers / uncapped runs are unchanged.
static func spike_threshold_ms(target_fps: int) -> float:
	if target_fps <= 0:
		return SPIKE_MS  # uncapped → the browser rAF-caps at 60; 28 ms ≈ 1.7× 16.6
	return maxf(SPIKE_MS, 1000.0 / float(target_fps) * 1.5)


# Missing / empty streams summarise to zeros, so a backend without GPU timers
# (render_gpu_ms all 0) or a partial capture still produces a full dictionary.
static func summarise(samples: Dictionary, spike_ms := SPIKE_MS) -> Dictionary:
	var frames: Array = samples.get("frame_ms", [])
	var total_ms := 0.0
	var spikes := 0
	for f in frames:
		total_ms += f
		if f >= spike_ms:
			spikes += 1
	var out := {
		"frames": frames.size(),
		"duration_s": total_ms / 1000.0,
		"fps_avg": (frames.size() * 1000.0 / total_ms) if total_ms > 0.0 else 0.0,
		# "1% low": the fps the worst 1% of frames run at — the stutter number.
		"fps_1pct_low": 0.0,
		"frame_avg_ms": mean(frames),
		"frame_p95_ms": percentile(frames, 0.95),
		"frame_p99_ms": percentile(frames, 0.99),
		"frame_max_ms": peak(frames),
		"spikes": spikes,
		"spike_ms": spike_ms,
	}
	var p99: float = out["frame_p99_ms"]
	if p99 > 0.0:
		out["fps_1pct_low"] = 1000.0 / p99
	for stream in ["draws", "objects", "prims", "render_cpu_ms", "render_gpu_ms",
			"process_ms", "physics_ms"]:
		var vals: Array = samples.get(stream, [])
		out[stream + "_avg"] = mean(vals)
		out[stream + "_max"] = peak(vals)
	# Main-thread work per frame before it waits for the screen: unlike frame_ms it isn't pinned to the refresh rate.
	# physics_scripts / physics_step split each frame's physics into _physics_process code and the engine's own step;
	# process_phase runs from the process step to drawing, draw_phase is the drawing; frame_work (web) is the whole browser frame callback, and pre the part of it before Godot's first signal.
	for stream in ["busy", "physics_scripts", "physics_step", "process_phase", "draw_phase", "frame_work", "pre"]:
		var vals: Array = samples.get(stream + "_ms", [])
		if not vals.is_empty():
			out[stream + "_avg_ms"] = mean(vals)
			out[stream + "_p95_ms"] = percentile(vals, 0.95)
			out[stream + "_p99_ms"] = percentile(vals, 0.99)
			out[stream + "_max_ms"] = peak(vals)
	return out


# Prints a summarise() breakdown for the command-line benchmarks (benchmark/).
static func print_summary(s: Dictionary, headless: bool) -> void:
	print("  frames %d   duration %.1f s   distance %.0f m" % [
		int(s.get("frames", 0)), float(s.get("duration_s", 0.0)),
		float(s.get("distance_m", 0.0))])
	print("  fps          avg %7.1f    1%% low %7.1f" % [
		float(s.get("fps_avg", 0.0)), float(s.get("fps_1pct_low", 0.0))])
	print("  frame ms     avg %7.2f    p95 %7.2f   p99 %7.2f   max %7.2f" % [
		float(s.get("frame_avg_ms", 0.0)), float(s.get("frame_p95_ms", 0.0)),
		float(s.get("frame_p99_ms", 0.0)), float(s.get("frame_max_ms", 0.0))])
	for stream in ["busy", "physics_scripts", "physics_step", "process_phase", "draw_phase", "frame_work", "pre"]:
		if s.has(stream + "_avg_ms"):
			print("  %-12s avg %7.2f    p95 %7.2f   p99 %7.2f   max %7.2f" % [stream.replace("physics_", "phys "),
				float(s[stream + "_avg_ms"]), float(s[stream + "_p95_ms"]), float(s[stream + "_p99_ms"]), float(s[stream + "_max_ms"])])
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
		int(s.get("prims_avg", 0.0)), int(SPIKE_MS),
		int(s.get("spikes", 0))])
	var disabled: Array = s.get("disabled", [])
	if not disabled.is_empty():
		print("  disabled: %s" % ", ".join(disabled))
	if float(s.get("render_gpu_ms_avg", 0.0)) <= 0.0 and not headless:
		print("  note: GPU timer unsupported on this backend (e.g. OpenGL/macOS).")
		print("        With vsync off, frame interval ≈ GPU+present cost.")

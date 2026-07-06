class_name BenchmarkStats
extends RefCounted
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
# Missing / empty streams summarise to zeros, so a backend without GPU timers
# (render_gpu_ms all 0) or a partial capture still produces a full dictionary.
static func summarise(samples: Dictionary) -> Dictionary:
	var frames: Array = samples.get("frame_ms", [])
	var total_ms := 0.0
	var spikes := 0
	for f in frames:
		total_ms += f
		if f >= SPIKE_MS:
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
	}
	var p99: float = out["frame_p99_ms"]
	if p99 > 0.0:
		out["fps_1pct_low"] = 1000.0 / p99
	for stream in ["draws", "objects", "prims", "render_cpu_ms", "render_gpu_ms",
			"process_ms", "physics_ms"]:
		var vals: Array = samples.get(stream, [])
		out[stream + "_avg"] = mean(vals)
		out[stream + "_max"] = peak(vals)
	return out

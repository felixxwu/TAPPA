extends GutTest
# Benchmark report builder, stats summariser + PerfLog capture window (features/benchmark.md ->
# feedback loop). Pure logic only: the payload assembly, the frame stats, and that
# PerfLog's benchmark capture accumulates per-script cost and averages it over
# the sampled frame count. No scene / no HTTP.


# --- Report payload ------------------------------------------------------------

func test_build_carries_all_sections() -> void:
	var stats := {"fps_avg": 42.0, "disabled": ["Trees & bushes"]}
	var scripts := {"car": 1.2, "engine_audio": 0.9}
	var device := {"os": "Android", "build_version": "0.5 (abc)"}
	var report := BenchmarkReport.build(stats, scripts, device, "2026-07-17T10:00:00", "run-x")

	assert_eq(report["schema"], BenchmarkReport.SCHEMA, "schema is stamped")
	assert_eq(report["timestamp"], "2026-07-17T10:00:00", "timestamp passed through")
	assert_eq(report["label"], "run-x", "label passed through")
	assert_eq(report["stats"], stats, "stats embedded verbatim")
	assert_eq(report["scripts"], scripts, "scripts embedded verbatim")
	assert_eq(report["device"], device, "device embedded verbatim")
	# disabled_toggles is lifted from the stats so a reader needn't dig for it.
	assert_eq(report["disabled_toggles"], ["Trees & bushes"], "disabled toggles surfaced")


func test_build_disabled_defaults_empty_when_absent() -> void:
	var report := BenchmarkReport.build({}, {}, {}, "t", "l")
	assert_eq(report["disabled_toggles"], [], "no disabled key -> empty list")


func test_to_json_roundtrips() -> void:
	var report := BenchmarkReport.build({"fps_avg": 30.0}, {"car": 1.0}, {"os": "Web"}, "t", "l")
	var parsed = JSON.parse_string(BenchmarkReport.to_json(report))
	assert_eq(typeof(parsed), TYPE_DICTIONARY, "serialises to valid JSON")
	assert_eq(float(parsed["stats"]["fps_avg"]), 30.0, "values survive the round-trip")


func test_capture_averages_over_frame_count() -> void:
	PerfLog.begin_capture()
	# 2000us of "car" cost across the window; averaged over 4 frames = 0.5 ms/frame.
	PerfLog.track(&"car", 1500)
	PerfLog.track(&"car", 500)
	PerfLog.track(&"engine_audio", 4000)  # 1.0 ms/frame over 4 frames
	var out := PerfLog.end_capture(4)
	assert_almost_eq(float(out["car"]), 0.5, 0.0001, "car averaged ms/frame")
	assert_almost_eq(float(out["engine_audio"]), 1.0, 0.0001, "audio averaged ms/frame")


func test_capture_ignores_tracks_outside_the_window() -> void:
	PerfLog.track(&"car", 9999)  # before begin_capture -> must not count
	PerfLog.begin_capture()
	PerfLog.track(&"car", 1000)
	var out := PerfLog.end_capture(1)
	assert_almost_eq(float(out["car"]), 1.0, 0.0001, "only in-window cost counts")


func test_capture_zero_frames_is_empty() -> void:
	PerfLog.begin_capture()
	PerfLog.track(&"car", 1000)
	assert_eq(PerfLog.end_capture(0), {}, "no sampled frames -> empty breakdown")


func test_report_carries_the_load_timings() -> void:
	var r := BenchmarkReport.build({}, {}, {}, "t", "l", {"parse": 5})
	assert_eq(r["load_ms"], {"parse": 5})


# --- Stats summariser (BenchmarkStats) ------------------------------------------

func test_summarise_frame_stats() -> void:
	# 9 smooth frames + 1 spike: avg 12.6ms, max 40, one frame >= 28ms.
	var frames := [10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 40.0]
	var s := BenchmarkStats.summarise({"frame_ms": frames})
	assert_eq(s["frames"], 10, "frame count")
	assert_almost_eq(float(s["duration_s"]), 0.13, 0.0001, "duration is the summed intervals")
	assert_almost_eq(float(s["frame_avg_ms"]), 13.0, 0.0001, "average frame time")
	assert_eq(float(s["frame_max_ms"]), 40.0, "max frame time")
	assert_eq(int(s["spikes"]), 1, "one frame over the spike threshold")
	assert_almost_eq(float(s["fps_avg"]), 10 * 1000.0 / 130.0, 0.01,
		"avg fps is frames over wall time")
	assert_true(float(s["frame_p99_ms"]) >= float(s["frame_p95_ms"]),
		"p99 is at least p95")
	assert_almost_eq(float(s["fps_1pct_low"]), 1000.0 / float(s["frame_p99_ms"]), 0.01,
		"1% low is the inverse of the p99 frame time")


func test_summarise_handles_missing_and_empty_streams() -> void:
	var s := BenchmarkStats.summarise({})
	assert_eq(s["frames"], 0, "no frames")
	assert_eq(float(s["fps_avg"]), 0.0, "no divide-by-zero on an empty run")
	assert_eq(float(s["draws_avg"]), 0.0, "missing streams summarise to zero")


func test_summarise_reports_busy_time_only_when_sampled() -> void:
	assert_false(BenchmarkStats.summarise({"frame_ms": [16.7]}).has("busy_avg_ms"), "no busy stream, no busy stats")
	var s := BenchmarkStats.summarise({"frame_ms": [16.7, 16.7], "busy_ms": [4.0, 8.0]})
	assert_almost_eq(float(s["busy_avg_ms"]), 6.0, 0.001, "busy average")
	assert_eq(float(s["busy_max_ms"]), 8.0, "busy max")


func test_summarise_covers_the_monitor_streams() -> void:
	var s := BenchmarkStats.summarise({
		"frame_ms": [16.0, 16.0],
		"draws": [100.0, 200.0],
		"render_cpu_ms": [2.0, 4.0],
	})
	assert_almost_eq(float(s["draws_avg"]), 150.0, 0.001, "draw calls average")
	assert_eq(float(s["draws_max"]), 200.0, "draw calls max")
	assert_almost_eq(float(s["render_cpu_ms_avg"]), 3.0, 0.001, "render cpu average")


func test_percentile_nearest_rank() -> void:
	var vals := [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
	assert_eq(BenchmarkStats.percentile(vals, 0.0), 1.0, "p0 is the min")
	assert_eq(BenchmarkStats.percentile(vals, 1.0), 10.0, "p100 is the max")
	assert_eq(BenchmarkStats.percentile(vals, 0.5), 6.0, "median by nearest rank")
	assert_eq(BenchmarkStats.percentile([], 0.5), 0.0, "empty input reads 0")

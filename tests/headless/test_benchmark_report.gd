extends GutTest
# Benchmark report builder + PerfLog capture window (features/benchmark.md ->
# feedback loop). Pure logic only: the payload assembly, the run label, and that
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


# --- Run label -----------------------------------------------------------------

func test_label_baseline_when_nothing_disabled() -> void:
	var label := BenchmarkReport.make_label("0.5 (abc)", [])
	assert_string_contains(label, "baseline", "a full run is labelled baseline")
	assert_string_contains(label, "0.5", "version is included")


func test_label_lists_disabled_toggles() -> void:
	var label := BenchmarkReport.make_label("0.5", ["Trees & bushes", "Spectators"])
	assert_string_contains(label, "no-", "disabled toggles are prefixed no-")
	assert_string_contains(label, "Trees", "the disabled feature name appears")


func test_label_is_filesystem_safe() -> void:
	# Spaces / punctuation from toggle names and the version's "(abc)" must not
	# leak into the filename segment — they're mapped to "-".
	var label := BenchmarkReport.make_label("0.5 (abc)", ["Trees & bushes"])
	const SAFE := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
	for i in label.length():
		assert_true(label[i] in SAFE, "char '%s' is filename-safe" % label[i])


# --- PerfLog benchmark capture window ------------------------------------------

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

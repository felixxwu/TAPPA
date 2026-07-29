extends GutTest
# scripts/perf_log.gd — the per-frame script-cost accumulator every _process /
# _physics_process wrapper calls. Its per-second printout only exists in debug
# builds, so in a release build track() must accumulate NOTHING (nothing would
# ever read or clear it) — while the benchmark's explicit capture window has to
# keep recording in ANY build. These cover both halves of that early-out.

var _was_debug: bool


func before_each() -> void:
	_was_debug = PerfLog._debug
	PerfLog.script_totals().clear()
	PerfLog.end_capture(0)  # make sure no capture window is left open


func after_each() -> void:
	PerfLog.set_debug(_was_debug)
	PerfLog.script_totals().clear()


func test_debug_build_accumulates_per_script_cost() -> void:
	PerfLog.set_debug(true)
	PerfLog.track(&"unit_test", 100)
	PerfLog.track(&"unit_test", 50)
	assert_eq(int(PerfLog.script_totals().get(&"unit_test", 0)), 150,
		"the per-second logger accumulates each tracked call in a debug build")


func test_release_build_records_nothing() -> void:
	PerfLog.set_debug(false)
	PerfLog.track(&"unit_test", 100)
	assert_false(PerfLog.script_totals().has(&"unit_test"),
		"with the per-second logger off, track() accumulates nothing at all")


func test_capture_records_in_a_release_build() -> void:
	# The benchmark profiles the RELEASE export, so an open capture window must
	# record regardless of the debug flag.
	PerfLog.set_debug(false)
	PerfLog.begin_capture()
	PerfLog.track(&"unit_test", 1000)
	var out := PerfLog.end_capture(1)
	assert_true(out.has("unit_test"), "a capture window records while the logger is off")
	assert_gt(float(out["unit_test"]), 0.0, "and the recorded cost is non-zero")


func test_capture_is_closed_after_end() -> void:
	PerfLog.set_debug(false)
	PerfLog.begin_capture()
	PerfLog.end_capture(1)
	PerfLog.track(&"unit_test", 1000)
	var out := PerfLog.end_capture(1)
	assert_false(out.has("unit_test"), "nothing is recorded once the window is closed")

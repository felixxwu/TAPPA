class_name BenchmarkResults
extends CanvasLayer
# End-of-benchmark stats breakdown (features/benchmark.md): a full-screen panel
# shown by BenchmarkRunner when the car crosses the finish, laying out the run's
# summary (BenchmarkStats.summarise output) as aligned monospace read-out lines,
# with RUN AGAIN / EXIT actions. Keyboard + gamepad navigable via MenuNav
# (features/menus.md → "Menu navigation"); Esc / B backs out to Exit.

# Above the perf overlay (100) so the breakdown reads cleanly over it.
const _LAYER := 110

# Exposed for tests / hosts.
var again_button: Button
var exit_button: Button
var stat_labels: Array[Label] = []
# A single line the runner patches to show whether the report POST landed
# (features/benchmark.md → feedback loop). Created lazily on first update.
var report_status_label: Label

var _on_exit: Callable
var _col: VBoxContainer


func _init() -> void:
	layer = _LAYER


# Build the panel from a stats summary. `on_again` / `on_exit` are the two
# actions (rerun the scene / leave benchmark mode).
func setup(stats: Dictionary, on_again: Callable, on_exit: Callable) -> void:
	_on_exit = on_exit

	var backdrop := ColorRect.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.color = UITheme.PANEL_DIM
	add_child(backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := UITheme.panel(0.95, 18)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	panel.add_child(col)
	_col = col

	col.add_child(UITheme.title("Benchmark complete"))
	for line in format_lines(stats):
		var l := Label.new()
		l.text = line
		stat_labels.append(l)
		col.add_child(l)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_child(row)
	again_button = UITheme.button("Run again")
	again_button.pressed.connect(on_again)
	row.add_child(again_button)
	exit_button = UITheme.button("Exit benchmark")
	exit_button.pressed.connect(on_exit)
	row.add_child(exit_button)

	UITheme.enforce(self)  # house rules: uppercase + one font size
	# Keyboard/gamepad nav: focus the buttons, seat the cursor, route back to Exit.
	MenuNav.attach(center, {first = again_button, on_back = _back})


func _back() -> void:
	if _on_exit.is_valid():
		_on_exit.call()


# Show / update the report-delivery status line (the runner calls this after the
# results POST resolves). Created lazily; sits as a footer under the buttons.
func set_report_status(text: String) -> void:
	if report_status_label == null:
		report_status_label = Label.new()
		report_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if _col != null:
			_col.add_child(report_status_label)
	report_status_label.text = text.to_upper()


# The read-out lines, split out (static, pure) so tests can check them without a
# scene. Every number comes from the stats dictionary; missing keys read as 0.
static func format_lines(stats: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	lines.append("time %s   distance %d m   frames %d" % [
		UITheme.format_time(int(float(stats.get("duration_s", 0.0)) * 1000.0)),
		int(stats.get("distance_m", 0.0)), int(stats.get("frames", 0))])
	lines.append("avg fps %.0f   1%% low %.0f" % [
		float(stats.get("fps_avg", 0.0)), float(stats.get("fps_1pct_low", 0.0))])
	lines.append("frame  avg %.1f   p95 %.1f   p99 %.1f   max %.1f ms" % [
		float(stats.get("frame_avg_ms", 0.0)), float(stats.get("frame_p95_ms", 0.0)),
		float(stats.get("frame_p99_ms", 0.0)), float(stats.get("frame_max_ms", 0.0))])
	lines.append("spikes >%dms  %d   audio overruns %d" % [
		int(BenchmarkStats.SPIKE_MS), int(stats.get("spikes", 0)), int(stats.get("audio_skips", 0))])
	lines.append("draws  avg %d   max %d" % [
		int(stats.get("draws_avg", 0.0)), int(stats.get("draws_max", 0.0))])
	lines.append("objects avg %d   prims avg %dk" % [
		int(stats.get("objects_avg", 0.0)), int(stats.get("prims_avg", 0.0) / 1000.0)])
	var gpu_avg := float(stats.get("render_gpu_ms_avg", 0.0))
	var gpu_text := "%.1f" % gpu_avg if gpu_avg > 0.0 else "n/a"
	lines.append("render cpu %.1f ms   gpu %s ms" % [
		float(stats.get("render_cpu_ms_avg", 0.0)), gpu_text])
	lines.append("cpu process avg %.1f max %.1f ms   physics avg %.1f max %.1f ms" % [
		float(stats.get("process_ms_avg", 0.0)), float(stats.get("process_ms_max", 0.0)),
		float(stats.get("physics_ms_avg", 0.0)), float(stats.get("physics_ms_max", 0.0))])
	var disabled: Array = stats.get("disabled", [])
	if not disabled.is_empty():
		lines.append("disabled: %s" % ", ".join(disabled))
	return lines

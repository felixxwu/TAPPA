class_name BenchmarkReport
extends RefCounted
# Assembles the machine-readable JSON a benchmark run POSTs back to the dev
# machine (features/benchmark.md → "Feedback loop"). The collector
# (tools/bench_collector.py) writes each report to build/bench-results/ so Claude
# can read it, attribute the bottleneck system, and iterate.
#
# build()/to_json() are PURE (no scene / no engine singletons) so they're tested
# headless; the runtime-only device probing lives in probe_device(), which the
# runner calls and hands to build().

const SCHEMA := "rally-bench/1"


# Assemble the report dictionary. Every input is a plain value so this is pure
# and testable:
#   stats     — BenchmarkStats.summarise output (may carry "distance_m"/"disabled")
#   scripts   — {script_name: ms/frame} from PerfLog.end_capture()
#   device    — probe_device() output (adapter, os, cpu count, resolution, …)
#   timestamp — an ISO-ish string stamped by the caller (Time.get_datetime_*)
#   label     — short run identifier (build version + disabled toggles)
static func build(stats: Dictionary, scripts: Dictionary, device: Dictionary,
		timestamp: String, label: String) -> Dictionary:
	return {
		"schema": SCHEMA,
		"timestamp": timestamp,
		"label": label,
		"device": device,
		"disabled_toggles": stats.get("disabled", []),
		"stats": stats,
		"scripts": scripts,
	}


static func to_json(report: Dictionary) -> String:
	return JSON.stringify(report, "  ")


# A short, filesystem-safe run label the collector uses in the filename and
# Claude uses to tell runs apart: the build version plus which toggles were off
# (so "baseline" vs "trees-off" runs are distinguishable at a glance). Pure.
static func make_label(build_version: String, disabled_toggles: Array) -> String:
	var parts: PackedStringArray = []
	if build_version != "":
		parts.append(build_version)
	if disabled_toggles.is_empty():
		parts.append("baseline")
	else:
		for name in disabled_toggles:
			parts.append("no-" + String(name))
	return _sanitize("_".join(parts))


# Keep only characters safe in a filename segment; everything else becomes "-".
static func _sanitize(s: String) -> String:
	const SAFE := "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
	var out := ""
	for i in s.length():
		out += s[i] if s[i] in SAFE else "-"
	return out


# Runtime device/context probe (NOT pure — reads engine singletons). Kept out of
# build() so the payload assembly stays headless-testable.
static func probe_device() -> Dictionary:
	var d := {
		"os": OS.get_name(),
		"model": OS.get_model_name(),
		"cpu_count": OS.get_processor_count(),
		"web": Platform.is_web(),
		"debug_build": OS.is_debug_build(),
		"build_version": String(ProjectSettings.get_setting("application/config/version", "")),
		"adapter": RenderingServer.get_video_adapter_name(),
		"renderer": String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "")),
	}
	# The actual render resolution (content_scale_size) vs the browser window, so a
	# reader can confirm the run measured a representative landscape frame (see
	# features/benchmark.md → "Representative render resolution") and read the exact
	# horizontal target rather than deriving it.
	var win := DisplayServer.window_get_size()
	d["window_size"] = [win.x, win.y]
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and tree.root != null:
		var cs := tree.root.content_scale_size
		d["render_size"] = [int(cs.x), int(cs.y)]
	if Platform.is_web():
		# The browser UA pins down the actual phone/browser behind a web run.
		var ua = JavaScriptBridge.eval("navigator.userAgent", true)
		if ua != null:
			d["user_agent"] = String(ua)
	return d

extends Node
# Standalone performance benchmark — NOT part of the test suite. Run on demand
# to investigate choppiness:
#
#     ./run_benchmark.sh              # windowed: captures CPU *and* GPU/render
#     ./run_benchmark.sh --headless   # CPU-only (no GPU timing), quick
#
# This drives the SAME run as the in-game benchmark (Settings → Benchmark,
# features/benchmark.md): it loads the real main.tscn with the Benchmark autoload
# active, so world.gd spawns a BenchmarkRunner that auto-pilots the fielded car
# down the fixed seeded stage (Benchmark.TRACK_SEED / TRACK_TURN_COUNT) while
# recording per-frame timing/render samples. When the car crosses the finish the
# runner hands its summary to Benchmark.finish(); we print that BenchmarkStats
# breakdown to stdout and quit. Running the real, shipped game loop (vehicle
# physics, tire model, FX, the full-screen PS1 post-process, per-cell terrain) is
# what makes the numbers reflect actual play. Loose, machine-dependent numbers —
# read them, don't gate on them.

# Safety cap: frames to await before giving up on the run finishing (the car is
# steered by pure-pursuit with an off-track reset, so it should always finish; a
# ~10-turn stage at 50 km/h is well under this budget even uncapped).
const MAX_FRAMES := 60000


func _ready() -> void:
	print("\n=== rally performance benchmark ===")
	print("display: %s   (%s)\n" % [
		DisplayServer.get_name(),
		"windowed — GPU timing available" if not _headless() else "headless — CPU only"])
	print("-- in-game benchmark run (seed %d, %d turns) --" % [
		Benchmark.TRACK_SEED, Benchmark.TRACK_TURN_COUNT])
	if _headless():
		print("  note: headless — render cpu/gpu and vsync pacing are unavailable;")
		print("        frame interval reflects CPU work only. Run windowed for GPU timing.")

	# Frame pacing: uncap fps + vsync off so the run exposes real headroom instead
	# of pinning to the refresh rate (the same thing Benchmark's uncap_fps toggle
	# does). Restored before we quit.
	var prev_max_fps := Engine.max_fps
	var prev_vsync := DisplayServer.VSYNC_ENABLED
	if not _headless():
		prev_vsync = DisplayServer.window_get_vsync_mode(0)
	Engine.max_fps = 0
	if not _headless():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)

	# Configure the Benchmark autoload exactly as start() would, minus its
	# change_scene (we host main.tscn as a child so this harness stays alive to
	# read the result). All toggles keep their defaults (the full game as shipped).
	Benchmark.apply_overrides(Config.data)
	Benchmark.results = {}
	Benchmark.active = true

	var scene: Node = load("res://main.tscn").instantiate()
	add_child(scene)

	# --- Camera-shake probe (temporary diagnostic). Legitimate terrain following is a
	# slow signal (the car climbing a hill over ~seconds); shake is a faster wobble ON
	# TOP of it. To separate them, high-pass each signal: keep a moving average over a
	# ~WIN-frame window and measure the RMS of the residual (value − moving average).
	# The slow ramp lands in the average and cancels; only the wobble survives. Tracked
	# for camera pitch, camera Y, and the car's own Y (its target) — the car bouncing on
	# a bumpy collision surface is the driver of the whole effect.
	const WIN := 24                       # ~0.16 s at ~145 fps
	var buf_pitch := PackedFloat32Array()
	var buf_camy := PackedFloat32Array()
	var buf_cary := PackedFloat32Array()
	var hp_pitch_sq := 0.0
	var hp_camy_sq := 0.0
	var hp_cary_sq := 0.0
	var hp_n := 0
	var series_pitch := PackedFloat32Array()
	var series_camy := PackedFloat32Array()
	var series_cary := PackedFloat32Array()
	var series_fov := PackedFloat32Array()
	var series_speed := PackedFloat32Array()
	# Car body attitude, to characterise the "bumpy road" wobble the car itself shows
	# (distinct from the camera). Pitch = nose up/down, roll = lean L/R, both derived
	# from the body basis so they're yaw-independent; angvel = |angular_velocity|.
	var series_carpitch := PackedFloat32Array()
	var series_carroll := PackedFloat32Array()
	var series_angvel := PackedFloat32Array()

	# Wait for the runner to cross the finish and publish its summary.
	var frames := 0
	while Benchmark.results.is_empty() and frames < MAX_FRAMES:
		await get_tree().process_frame
		frames += 1
		var cam := get_viewport().get_camera_3d()
		if cam != null:
			var fwd := -cam.global_transform.basis.z
			var pitch: float = asin(clampf(fwd.y, -1.0, 1.0))
			var camy := cam.global_position.y
			var cary := camy
			var speed := 0.0
			var tgt: Node = cam.get("target")
			if tgt is Node3D:
				cary = (tgt as Node3D).global_position.y
			var carpitch := 0.0
			var carroll := 0.0
			var angvel := 0.0
			if tgt is Node3D:
				var b := (tgt as Node3D).global_transform.basis.orthonormalized()
				carpitch = asin(clampf(-b.z.y, -1.0, 1.0))  # nose up (+) / down (-)
				carroll = asin(clampf(b.x.y, -1.0, 1.0))     # lean
			if tgt is RigidBody3D:
				var rb := tgt as RigidBody3D
				var hv := rb.linear_velocity
				hv.y = 0.0
				speed = hv.length()
				angvel = rb.angular_velocity.length()
			series_carpitch.append(carpitch); series_carroll.append(carroll); series_angvel.append(angvel)
			series_fov.append(cam.fov); series_speed.append(speed)
			series_pitch.append(pitch); series_camy.append(camy); series_cary.append(cary)
			buf_pitch.append(pitch); buf_camy.append(camy); buf_cary.append(cary)
			if buf_pitch.size() > WIN:
				buf_pitch.remove_at(0); buf_camy.remove_at(0); buf_cary.remove_at(0)
			if buf_pitch.size() == WIN:
				var rp := pitch - _mean(buf_pitch)
				var rc := camy - _mean(buf_camy)
				var rr := cary - _mean(buf_cary)
				hp_pitch_sq += rp * rp
				hp_camy_sq += rc * rc
				hp_cary_sq += rr * rr
				hp_n += 1
	if hp_n > 0:
		print("-- camera shake probe (high-pass residual, %d samples) --" % hp_n)
		print("  cam pitch wobble RMS %.5f rad" % sqrt(hp_pitch_sq / hp_n))
		print("  cam Y     wobble RMS %.5f m" % sqrt(hp_camy_sq / hp_n))
		print("  car Y     wobble RMS %.5f m" % sqrt(hp_cary_sq / hp_n))
	# Dump the raw per-frame time series so the frequency content can be analysed
	# offline (pitch, camera Y, car Y). One row per rendered frame.
	var f := FileAccess.open("user://shake_series.csv", FileAccess.WRITE)
	if f != null:
		f.store_line("i,pitch,camy,cary,fov,speed,carpitch,carroll,angvel")
		for i in series_pitch.size():
			f.store_line("%d,%.6f,%.6f,%.6f,%.4f,%.4f,%.6f,%.6f,%.6f" % [
				i, series_pitch[i], series_camy[i], series_cary[i], series_fov[i], series_speed[i],
				series_carpitch[i], series_carroll[i], series_angvel[i]])
		f.close()
		print("  wrote time series: %s" % ProjectSettings.globalize_path("user://shake_series.csv"))

	if Benchmark.results.is_empty():
		print("  TIMED OUT after %d frames — the run never reached the finish." % frames)
	else:
		_report(Benchmark.results)

	# Restore everything the run touched, then leave.
	Benchmark.active = false
	Benchmark.restore(Config.data)
	Engine.max_fps = prev_max_fps
	if not _headless():
		DisplayServer.window_set_vsync_mode(prev_vsync)
	scene.queue_free()

	print("\n=== benchmark complete ===")
	get_tree().quit()


func _mean(a: PackedFloat32Array) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


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

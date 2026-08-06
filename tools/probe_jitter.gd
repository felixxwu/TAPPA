extends Node
# Measure heading/curvature jitter along a REAL generated centerline, for several probe
# spans. Isolates the geometry reading from GhostCar entirely.
func _ready() -> void:
	var params := TrackGenParams.of(Vector2.ZERO, Vector2(0, 1), 9, 12, 6.0)
	var track: Dictionary = await TrackGenerator.generate(params)
	var curve: Curve2D = track["centerline"]
	print("baked length %.1f m, bake_interval %.2f" % [curve.get_baked_length(), curve.bake_interval])
	var length := curve.get_baked_length()
	var step := 0.33      # ~20 m/s at 60 fps
	print("%-8s %-14s %-14s" % ["probe", "max dHeading(deg)", "kappa sign flips"])
	for probe in [1.5, 6.0, 10.0, 20.0]:
		var prev := 1.0e9
		var worst := 0.0
		var flips := 0
		var prev_sign := 0.0
		var off: float = probe + 1.0
		while off < length - probe - 1.0:
			var here := curve.sample_baked(off)
			var back := curve.sample_baked(off - probe)
			var ahead := curve.sample_baked(off + probe)
			var h := (here - back).angle()
			if prev < 1.0e8:
				worst = maxf(worst, absf(wrapf(h - prev, -PI, PI)))
			prev = h
			var d := wrapf((ahead - here).angle() - (here - back).angle(), -PI, PI)
			var sgn := signf(d)
			if prev_sign != 0.0 and sgn != 0.0 and sgn != prev_sign:
				flips += 1
			if sgn != 0.0:
				prev_sign = sgn
			off += step
		print("%-8.1f %-14.2f %-14d" % [probe, rad_to_deg(worst), flips])
	get_tree().quit()

extends Node2D
# Verification aid: photograph the CornerLibrary shape catalogue so a corner-shape edit
# can actually be EYEBALLED rather than argued about from numbers. Wraps the existing
# corner_catalog.tscn debug viewer (scripts/corner_catalog.gd), waits for it to lay out,
# and saves the frame to tools/corner_catalog.png.
#
# Also prints each corner's MINIMUM RADIUS and the cornering-speed ceiling that radius
# implies, because that number — not the drawing — is what the lap-time model reacts to
# (LapTimeModel pass 1 caps speed at sqrt(mu*g/kappa), so the tightest point of a corner
# sets the braking). A corner can look fine and still spike.
#
# Pure tooling; not shipped. Run windowed (headless renders nothing):
#
#   godot --path . --rendering-driver opengl3 res://tools/corner_capture.tscn
#
# On a headless Linux box wrap it: xvfb-run -a -s "-screen 0 1600x600x24" godot ...

const OUT_PATH := "res://tools/corner_catalog.png"
const REFERENCE_MU := 1.1     # a mid grip, purely so the printed km/h is comparable
# Curve2D bakes at bake_interval (5 m by default) and sample_baked LERPS between those
# baked points. So a curvature probe finer than the bake interval reads zero along each
# chord and then the whole chord's turn in one step, inflating kappa by (chord / step) and
# under-reporting radius by the same factor — the first version of this tool claimed turn 1
# was a 0.39 m radius. Bake finely, then probe at a step comfortably above the bake
# interval. Same quantisation trap as the rival ghost's timed-span resample
# (features/rival-ghost.md).
const BAKE_INTERVAL_M := 0.05
const PROBE_STEP_M := 0.5


func _ready() -> void:
	# Numbers FIRST, and without instantiating anything: they are the useful half and they
	# work headless, where there is no renderer to photograph.
	_print_radii()
	if Platform.is_headless():
		print("corner-capture: headless — numbers only, no PNG. Re-run windowed for the image:")
		print("  godot --path . --rendering-driver opengl3 res://tools/corner_capture.tscn")
		get_tree().quit()
		return

	get_window().size = Vector2i(1600, 600)
	var catalog := (load("res://corner_catalog.tscn") as PackedScene).instantiate()
	add_child(catalog)
	# Let it lay out and draw (it auto-fits the row to the viewport on first frames).
	for _i in 30:
		await get_tree().process_frame
	var tex := get_viewport().get_texture()
	if tex == null:
		print("corner-capture: no viewport texture — nothing saved.")
		get_tree().quit()
		return
	var err := tex.get_image().save_png(OUT_PATH)
	print("corner-capture: saved %s err=%d" % [OUT_PATH, err])
	get_tree().quit()


# Minimum radius per corner, straight off the same Curve2D the generator imprints.
func _print_radii() -> void:
	print("corner       min_radius_m   v_cap_km/h @mu=%.2f" % REFERENCE_MU)
	for entry in CornerLibrary.CORNERS:
		var curve := CornerLibrary.build_curve(entry)
		var r := _min_radius(curve)
		if r >= 1.0e17:
			print("%-12s %-14s %s" % [String(entry["name"]), "straight", "-"])
			continue
		var v := sqrt(REFERENCE_MU * Platform.gravity() * r) * 3.6
		print("%-12s %-14.2f %.1f" % [String(entry["name"]), r, v])


# Tightest radius anywhere along the curve, by sampling curvature off the baked
# polyline. Mirrors what LapTimeModel._curvature_profile does, so the number printed here
# is the one that actually drives the braking.
func _min_radius(curve: Curve2D) -> float:
	curve.bake_interval = BAKE_INTERVAL_M
	var length := curve.get_baked_length()
	if length <= 0.0:
		return 1.0e18
	var best := 1.0e18
	var step := PROBE_STEP_M
	var samples := int(length / step)
	for i in range(1, samples):
		var here := curve.sample_baked(float(i) * step)
		var back := curve.sample_baked(float(i - 1) * step)
		var ahead := curve.sample_baked(minf(float(i + 1) * step, length))
		var v1 := here - back
		var v2 := ahead - here
		if v1.length() < 0.0001 or v2.length() < 0.0001:
			continue
		var dtheta: float = absf(wrapf(v2.angle() - v1.angle(), -PI, PI))
		if dtheta < 0.00001:
			continue
		var kappa := dtheta / step
		best = minf(best, 1.0 / kappa)
	return best

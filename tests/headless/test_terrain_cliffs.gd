extends GutTest

# Tests for the track cliffs & drops terrain feature (features/terrain.md):
# scripts/terrain_manager.gd's cliff bake pass + scripts/terrain_chunk_builder.gd's
# per-vertex offset. Logic/behaviour only — the tunable heights/gains live in
# GameConfig and are never pinned here (CLAUDE.md).

const ManagerScript := preload("res://scripts/terrain_manager.gd")


func _make_layer(wavelength: float, amplitude: float) -> TerrainLayer:
	var layer := TerrainLayer.new()
	layer.wavelength_m = wavelength
	layer.amplitude_m = amplitude
	return layer


# A bare TerrainManager with cliffs configured. Defaults chosen so cliffs are ON,
# with generous run/fade so a 1 m grid lands vertices across the whole profile.
func _make_manager(seed_value: int = 7) -> Node3D:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.noise_seed = seed_value
	m.layers = [_make_layer(60.0, 1.5)] as Array[TerrainLayer]
	m.cliff_enabled = true
	m.cliff_wavelength_m = 40.0
	m.cliff_gain = 5.0                 # saturate often so camber is rarely 0
	m.cliff_max_height_m = 10.0
	m.cliff_run_m = 10.0
	m.cliff_fade_m = 10.0
	m.cliff_pinch_angle_deg = 45.0
	m.cliff_amount = 1.0
	m.cliff_seed = seed_value
	autofree(m)
	return m


func _straight(length: float = 200.0) -> Curve2D:
	var c := Curve2D.new()
	c.add_point(Vector2(0.0, 0.0))
	c.add_point(Vector2(length, 0.0))
	return c


# Offset at grid vertex nearest world (x, z); 0 when absent.
func _offset(m: Node3D, x: float, z: float) -> float:
	return m.cliff_offsets.get(
		Vector2i(roundi(x / ManagerScript.CELL_M), roundi(z / ManagerScript.CELL_M)), 0.0)


func test_disabled_bakes_no_offsets() -> void:
	var m := _make_manager()
	m.cliff_enabled = false
	m.bake_track(_straight(), 8.0, 4.0)
	assert_eq(m.cliff_offsets.size(), 0, "no cliff offsets baked when disabled")


func test_zero_amount_bakes_no_offsets() -> void:
	# cliff_amount 0 ⇒ every offset scales to 0 regardless of cliff_max_height_m.
	var m := _make_manager()
	m.cliff_amount = 0.0
	m.bake_track(_straight(), 8.0, 4.0)
	assert_eq(m.cliff_offsets.size(), 0, "no offsets when the per-event amount is 0")


func test_zero_max_height_bakes_no_offsets() -> void:
	var m := _make_manager()
	m.cliff_max_height_m = 0.0
	m.bake_track(_straight(), 8.0, 4.0)
	assert_eq(m.cliff_offsets.size(), 0, "no offsets when the height ceiling is 0")


func test_offset_zero_across_road_and_transition_band() -> void:
	# The cliff must not begin until the road edge has fully met the grass: offset is
	# 0 for every vertex within width/2 + transition of the centerline (the flat road
	# AND the feathered shoulder). Asserted against the derived band-edge distance.
	var width := 8.0
	var transition := 4.0
	var inner := width / 2.0 + transition
	var m := _make_manager()
	m.bake_track(_straight(), width, transition)
	for v in m.cliff_offsets.keys():
		var d: float = Vector2(v.x * ManagerScript.CELL_M, v.y * ManagerScript.CELL_M).distance_to(
			Vector2(clampf(v.x * ManagerScript.CELL_M, 0.0, 200.0), 0.0))
		assert_true(d >= inner - 1e-3,
			"cliff vertex %s sits at/beyond the band edge (d=%.2f, inner=%.2f)" % [v, d, inner])


func test_offset_antisymmetric_across_centerline() -> void:
	# A cliff is always as tall as the drop is deep: for a straight, the two sides at
	# matching perpendicular distance are exact negatives (same camber, opposite side).
	var m := _make_manager()
	m.bake_track(_straight(), 8.0, 4.0)
	var found_nonzero := false
	for x in [40.0, 60.0, 80.0, 100.0, 120.0, 140.0, 160.0]:
		for d in [12.0, 16.0, 20.0]:
			var pos := _offset(m, x, d)
			var neg := _offset(m, x, -d)
			assert_almost_eq(pos, -neg, 1e-4,
				"offset(+d) = -offset(-d) at x=%.0f d=%.0f" % [x, d])
			if absf(pos) > 0.01:
				found_nonzero = true
	assert_true(found_nonzero, "at least one non-trivial cliff/drop pair exists")


func test_offset_bounded_by_max_height() -> void:
	var m := _make_manager()
	m.bake_track(_straight(), 8.0, 4.0)
	for v in m.cliff_offsets.values():
		assert_true(absf(v) <= m.cliff_max_height_m + 1e-4,
			"|offset| %.3f within the height ceiling %.1f" % [absf(v), m.cliff_max_height_m])


func test_offset_fades_out_beyond_influence_radius() -> void:
	# Past R = inner + run + fade the offset is 0, so height_at matches pure noise
	# (backdrop continuity). No vertex beyond R carries an entry.
	var width := 8.0
	var transition := 4.0
	var m := _make_manager()
	m.bake_track(_straight(), width, transition)
	var R: float = width / 2.0 + transition + float(m.cliff_run_m) + float(m.cliff_fade_m)
	var far := R + 4.0
	# A point well past R, mid-track: cache-free height_at is pure noise there.
	assert_almost_eq(_offset(m, 100.0, far), 0.0, 1e-6, "offset 0 beyond R")
	assert_almost_eq(m.height_at(100.0, far), m._noise_height_at(100.0, far), 1e-6,
		"height past R equals pure noise")


func test_determinism_same_seed_same_offsets() -> void:
	var a := _make_manager(11)
	var b := _make_manager(11)
	a.bake_track(_straight(), 8.0, 4.0)
	b.bake_track(_straight(), 8.0, 4.0)
	assert_eq(a.cliff_offsets.size(), b.cliff_offsets.size(), "same key count")
	for v in a.cliff_offsets.keys():
		assert_almost_eq(float(a.cliff_offsets[v]), float(b.cliff_offsets.get(v, 1e9)), 1e-9,
			"identical offset at %s" % v)


func _hairpin() -> Curve2D:
	# Two arms 8 m apart (x=0 and x=8) joined by a U at y≈48. The inside crook is the
	# pocket around (4, 40) that the road wraps around.
	var c := Curve2D.new()
	for p in [Vector2(0, 0), Vector2(0, 20), Vector2(0, 40), Vector2(2, 46),
			Vector2(4, 48), Vector2(6, 46), Vector2(8, 40), Vector2(8, 20), Vector2(8, 0)]:
		c.add_point(p)
	return c


func test_hairpin_crook_flattens_outside_edge_keeps_cliff() -> void:
	# Narrow band so a vertex between the arms is beyond `inner` of each arm yet still
	# inside R of both — the wrap test then flattens the crook.
	var m := _make_manager()
	m.cliff_run_m = 4.0
	m.cliff_fade_m = 4.0
	m.bake_track(_hairpin(), 2.0, 1.0)   # inner = 2
	# Inside-crook vertices: road wraps around them (arms on both sides + U ahead).
	for z in [36.0, 38.0, 40.0]:
		assert_almost_eq(_offset(m, 4.0, z), 0.0, 0.05,
			"inside-crook vertex (4, %.0f) flattened" % z)
	# The outer flank of the left arm (x<0) sees road on one side only → keeps a cliff.
	var outside_nonzero := false
	for z in range(6, 36, 2):
		if absf(_offset(m, -5.0, float(z))) > 0.05:
			outside_nonzero = true
			break
	assert_true(outside_nonzero, "an outside-edge vertex keeps its cliff/drop")


func test_hairpin_flatten_is_continuous() -> void:
	# Walking from the outer flank toward the crook, the offset must not step: adjacent
	# vertices differ by less than the full ceiling (feathered contested, no hard cut).
	var m := _make_manager()
	m.cliff_run_m = 4.0
	m.cliff_fade_m = 4.0
	m.bake_track(_hairpin(), 2.0, 1.0)
	var prev := _offset(m, -6.0, 30.0)
	for xi in range(-5, 6):
		var cur := _offset(m, float(xi), 30.0)
		assert_true(absf(cur - prev) <= m.cliff_max_height_m,
			"no step across x=%d (Δ=%.2f)" % [xi, absf(cur - prev)])
		prev = cur


func test_chunk_heights_include_cliff_offset() -> void:
	# The bake feeds compute_chunk_data: a vertex with a cliff offset has its rendered
	# and collision height shifted from the pure-noise height by exactly that offset
	# (cliffs are real, drivable geometry). Use an off-road vertex (no road flatten).
	var m := _make_manager()
	m.bake_track(_straight(), 8.0, 4.0)
	# Find a chunk-(0,0) vertex that actually carries an offset.
	var samples: int = ManagerScript.SAMPLES
	var data: Dictionary = m.compute_chunk_data(Vector2i(0, 0))
	var heights: PackedFloat32Array = data["heights"]
	var checked := false
	for zi in samples:
		for xi in samples:
			var v := Vector2i(xi, zi)
			if not m.cliff_offsets.has(v) or m.road_blend.has(v):
				continue
			var expected: float = m._noise_height_at(float(xi), float(zi)) + m.cliff_offsets[v]
			assert_almost_eq(heights[zi * samples + xi], expected, 1e-4,
				"chunk height at %s = noise + cliff offset" % v)
			checked = true
	assert_true(checked, "at least one off-road cliff vertex in chunk (0,0)")


func test_cliff_seam_agrees_across_adjacent_chunks() -> void:
	# cliff_offsets is keyed by GLOBAL vertex index, so adjacent chunks share the same
	# offset on their common edge — heights still agree at the seam with cliffs on.
	var m := _make_manager()
	# A straight running along +Z through the x = CHUNK_M seam so cliff vertices land
	# on the shared edge of chunks (0,0) and (1,0).
	var c := Curve2D.new()
	var seam_x: float = ManagerScript.CHUNK_M
	c.add_point(Vector2(seam_x, 0.0))
	c.add_point(Vector2(seam_x, 200.0))
	m.bake_track(c, 8.0, 4.0)
	var h0: PackedFloat32Array = m.compute_chunk_data(Vector2i(0, 0))["heights"]
	var h1: PackedFloat32Array = m.compute_chunk_data(Vector2i(1, 0))["heights"]
	var samples: int = ManagerScript.SAMPLES
	for zi in samples:
		var right_edge: float = h0[zi * samples + (samples - 1)]
		var left_edge: float = h1[zi * samples + 0]
		assert_almost_eq(left_edge, right_edge, 1e-4, "cliff seam agrees at row %d" % zi)

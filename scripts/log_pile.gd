class_name LogPile
extends RefCounted
# Procedural roadside timber piles (felled, cut logs stacked by a forestry track), built
# as one vertex-coloured mesh so a pile is a single draw call wherever it is placed.
# Tune and preview them in log_pile_lab.tscn.

enum Style { STACK, TAPERED, LOOSE }

const STYLE_NAMES := ["stack", "tapered", "loose"]
const SIDES := 12
const SEGMENTS := 8
const BARK_SHADER := preload("res://shaders/log_pile.gdshader")

const BARK := Color(0.42, 0.36, 0.30)
const SAPWOOD := Color(0.86, 0.62, 0.40)
const HEARTWOOD := Color(0.78, 0.50, 0.30)


# Returns a mesh instance whose origin sits on the ground at the pile's centre, logs along Z.
static func build(seed: int, style: int, rows: int = 6, base_count: int = 9,
		length_m: float = 4.0, radius_m: float = 0.16, sections: int = 1) -> MeshInstance3D:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var logs: Array[Dictionary] = []
	match style:
		Style.LOOSE:
			_loose(rng, logs, base_count, length_m, radius_m)
		_:
			for s in sections:
				var z := (s - (sections - 1) * 0.5) * (length_m + 0.15)
				_stack(rng, logs, style == Style.TAPERED, rows, base_count, length_m, radius_m, z)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for l in logs:
		_add_log(st, rng, l)
	var mat := ShaderMaterial.new()
	mat.shader = BARK_SHADER
	st.set_material(mat)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	return mi


# Hex-packed rows, each row resting in the grooves of the one below. TAPERED drops a log
# per row (the triangular face in the reference photos); STACK keeps the face upright.
static func _stack(rng: RandomNumberGenerator, logs: Array[Dictionary], tapered: bool,
		rows: int, base_count: int, length_m: float, r: float, z0: float) -> void:
	var pitch := r * 2.05
	var count := base_count
	for row in rows:
		if count <= 0:
			break
		for i in count:
			if not tapered and row > 0 and rng.randf() < 0.12 * row / rows:
				continue
			var x := (i - (count - 1) * 0.5) * pitch
			var y := r + row * r * 1.75
			var rr := r * rng.randf_range(0.75, 1.15)
			var len_m := length_m * rng.randf_range(0.97, 1.03)
			# The top row often carries longer, untrimmed stems, as in the photos.
			if row == rows - 1 or count <= 2:
				len_m *= rng.randf_range(1.0, 1.15)
			logs.append({
				"pos": Vector3(x, y, z0 + rng.randf_range(-0.05, 0.05)),
				"basis": Basis.from_euler(Vector3(0.0, rng.randf_range(-0.012, 0.012), 0.0)),
				"r": rr, "len": len_m,
			})
		count += -1 if tapered or row % 2 == 0 else 1


# A few stems dropped on the ground and on each other, roughly parallel.
static func _loose(rng: RandomNumberGenerator, logs: Array[Dictionary], count: int,
		length_m: float, r: float) -> void:
	for i in count:
		var rr := r * rng.randf_range(0.8, 1.3)
		var on_top := i > 2 and rng.randf() < 0.4
		var y := rr + (rr * 1.6 if on_top else 0.0)
		var len_m := length_m * rng.randf_range(0.9, 1.3)
		# Tilted no further than lets the low end touch the ground.
		var tilt := minf(rng.randf_range(0.05, 0.2), asin((y - rr) / (len_m * 0.5))) if on_top else 0.0
		logs.append({
			"pos": Vector3(rng.randf_range(-1.5, 1.5), y, rng.randf_range(-0.8, 0.8)),
			"basis": Basis.from_euler(Vector3(tilt, rng.randf_range(-0.35, 0.35), 0.0)),
			"r": rr, "len": len_m,
		})


# A gently bowed, lumpy, tapering trunk. The bow never points down, so a log resting on
# the ground or on the row below doesn't sink into it.
static func _add_log(st: SurfaceTool, rng: RandomNumberGenerator, l: Dictionary) -> void:
	var xf := Transform3D(l["basis"], l["pos"])
	var r: float = l["r"]
	var length: float = l["len"]
	var half := length * 0.5
	var taper := r * rng.randf_range(0.8, 0.92)
	var bow_angle := rng.randf_range(0.0, PI)
	var bow := Vector3(cos(bow_angle), sin(bow_angle), 0.0) * length * rng.randf_range(0.004, 0.015)
	var wobble := rng.randf_range(0.0, TAU)
	var bark := BARK.lerp(Color(0.50, 0.44, 0.38), rng.randf() * 0.6)
	var wood := SAPWOOD.lerp(Color(0.95, 0.80, 0.60), rng.randf() * 0.5)
	var rings: Array[PackedVector3Array] = []
	var normals: Array[PackedVector3Array] = []
	for j in SEGMENTS + 1:
		var t := float(j) / SEGMENTS
		var centre := bow * sin(PI * t) + Vector3(0.0, 0.0, lerpf(-half, half, t))
		var ring := PackedVector3Array()
		var ns := PackedVector3Array()
		for i in SIDES + 1:
			var a := TAU * i / SIDES
			var d := Vector3(cos(a), sin(a), 0.0)
			var lump := 1.0 + 0.05 * sin(a * 3.0 + wobble + t * 7.0) * sin(PI * t)
			ring.append(centre + d * lerpf(r, taper, t) * lump)
			ns.append(d)
		rings.append(ring)
		normals.append(ns)
	for j in SEGMENTS:
		for i in SIDES:
			var quad := [[j, i], [j, i + 1], [j + 1, i + 1], [j, i], [j + 1, i + 1], [j + 1, i]]
			for q in quad:
				st.set_color(bark)
				st.set_uv(Vector2(float(q[1]) / SIDES, float(q[0]) / SEGMENTS * length))
				st.set_uv2(Vector2(0.0, r))
				st.set_normal(xf.basis * normals[q[0]][q[1]])
				st.add_vertex(xf * rings[q[0]][q[1]])
	for i in SIDES:
		var d0: Vector3 = normals[0][i]
		var d1: Vector3 = normals[0][i + 1]
		_cap_wedge(st, xf, d0, d1, r, -half, -1.0, wood, bark)
		_cap_wedge(st, xf, d0, d1, taper, half, 1.0, wood, bark)


# One wedge of a cut end: pale sapwood, darker heartwood centre, thin bark rim.
static func _cap_wedge(st: SurfaceTool, xf: Transform3D, d0: Vector3, d1: Vector3,
		r: float, z: float, facing: float, wood: Color, bark: Color) -> void:
	var c := Vector3(0, 0, z)
	var bands := [[0.0, HEARTWOOD], [0.45, wood], [0.88, wood], [0.88, bark], [1.0, bark]]
	var normal := xf.basis * Vector3(0, 0, facing)
	for b in bands.size() - 1:
		var ri: float = bands[b][0]
		var ro: float = bands[b + 1][0]
		if ro <= ri:
			continue
		var ci: Color = bands[b][1]
		var co: Color = bands[b + 1][1]
		var tri := [[d0 * ri, ci], [d1 * ri, ci], [d1 * ro, co],
				[d0 * ri, ci], [d1 * ro, co], [d0 * ro, co]]
		for k in 6:
			var v: Vector3 = tri[k][0]
			st.set_color(tri[k][1])
			st.set_uv(Vector2(v.x, v.y) * r)
			st.set_uv2(Vector2(1.0, r))
			st.set_normal(normal)
			st.add_vertex(xf * (c + v * r))

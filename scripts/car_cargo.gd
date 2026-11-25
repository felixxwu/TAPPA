class_name CarCargo
extends MeshInstance3D
# Docs: features/car-cargo.md — update in the same change as this file.
# Tests: tests/headless/test_car_cargo.gd — extend in the same change.

## The delivery boxes and straps a car carries while a delivery's cargo is aboard, built from
## the per-car layout tools/cargo_lab.html saves. The same for every cargo; only the car changes it.

const PATH := "res://models/car_cargo.json"

static var _layouts: Variant = null


static func layouts() -> Dictionary:
	if _layouts == null:
		_layouts = JSON.parse_string(FileAccess.get_file_as_string(PATH)) if FileAccess.file_exists(PATH) else {}
		if not _layouts is Dictionary:
			_layouts = {}
	return _layouts


## A cargo mesh for the car, in car-local space, or null when the lab has no layout for it.
static func build(car_id: String, layout: Variant = null) -> CarCargo:
	if layout == null:
		layout = layouts().get(car_id)
	if not layout is Dictionary:
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in layout.get("boxes", []):
		_box(st, b)
	for s in layout.get("straps", []):
		_strap(st, s)
	var cargo := CarCargo.new()
	cargo.name = "CarCargo"
	cargo.mesh = st.commit()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/ps1_models_lit.gdshader")
	Config.data.apply_car_light(mat)
	cargo.material_override = mat
	return cargo


static func _box(st: SurfaceTool, b: Dictionary) -> void:
	var half := Vector3(float(b["w"]), float(b["h"]), float(b["d"])) * 0.5
	var turn := Basis(Vector3.UP, deg_to_rad(float(b.get("yaw", 0.0))))
	var centre := Vector3(float(b["x"]), float(b["y"]) + half.y, float(b["z"]))
	st.set_color(_color(b, Color(0.62, 0.46, 0.3)))
	for axis in 3:
		for dir in [-1.0, 1.0]:
			var n := Vector3.ZERO
			n[axis] = dir
			var u := Vector3.ZERO
			u[(axis + 1) % 3] = 1.0
			var v := Vector3.ZERO
			v[(axis + 2) % 3] = 1.0
			var c := n * half
			u *= half
			v *= half
			_quad(st, [c - u - v, c + u - v, c + u + v, c - u + v].map(func(p: Vector3) -> Vector3: return centre + turn * p), turn * n)


# A flat ribbon along the draped points; both faces, so it shows from under a box edge too.
static func _strap(st: SurfaceTool, s: Dictionary) -> void:
	var pts: Array = s.get("points", [])
	var side := _vec(s.get("side", [0, 0, 1])) * float(s.get("width", 0.04)) * 0.5
	st.set_color(_color(s, Color(0.95, 0.5, 0.1)))
	for i in pts.size() - 1:
		var a := _vec(pts[i])
		var b := _vec(pts[i + 1])
		var n := side.cross(b - a).normalized()
		var q := [a - side, a + side, b + side, b - side]
		_quad(st, q, n)
		_quad(st, q, -n)


# Winds the quad so its front face looks along n (Godot draws clockwise faces).
static func _quad(st: SurfaceTool, q: Array, n: Vector3) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	if (q[1] - q[0]).cross(q[2] - q[0]).dot(n) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	st.set_normal(n)
	for k in order:
		st.add_vertex(q[k])


static func _vec(a: Variant) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func _color(item: Dictionary, fallback: Color) -> Color:
	var c: Variant = item.get("color")
	return Color(float(c[0]), float(c[1]), float(c[2])) if c is Array and c.size() >= 3 else fallback

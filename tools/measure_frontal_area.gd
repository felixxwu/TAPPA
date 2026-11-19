extends SceneTree
# Prints the head-on silhouette area (m²) of every car model in car.tscn, aero parts excluded —
# the source of each CarLibrary entry's frontal_area. Run: godot --headless --path . -s tools/measure_frontal_area.gd
const RES := 0.01
func _initialize():
	var car: Node3D = load("res://car.tscn").instantiate()
	for body in car.get_children():
		if not String(body.name).ends_with("Body"): continue
		var tris := PackedVector2Array()
		_collect(body, car, tris)
		print("%s\t%.2f m2" % [body.name, _area(tris)])
	quit()

func _to_root(n: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = n
	while cur != root:
		if cur is Node3D: t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t

func _collect(n: Node, root: Node3D, tris: PackedVector2Array) -> void:
	if "_aero" in String(n.name): return
	if n is MeshInstance3D and (n as MeshInstance3D).mesh:
		var xf := _to_root(n, root)
		for v in (n as MeshInstance3D).mesh.get_faces():
			var p: Vector3 = xf * v
			tris.append(Vector2(p.x, p.y))
	for c in n.get_children(): _collect(c, root, tris)

func _area(tris: PackedVector2Array) -> float:
	var lo := Vector2(INF, INF); var hi := -lo
	for p in tris: lo = lo.min(p); hi = hi.max(p)
	var w := int(ceil((hi.x - lo.x) / RES)) + 1
	var h := int(ceil((hi.y - lo.y) / RES)) + 1
	var grid := PackedByteArray(); grid.resize(w * h)
	for i in range(0, tris.size(), 3):
		var a := (tris[i] - lo) / RES; var b := (tris[i+1] - lo) / RES; var c := (tris[i+2] - lo) / RES
		var d := (b - a).cross(c - a)
		if absf(d) < 1e-9: continue
		for y in range(maxi(0, int(minf(a.y, minf(b.y, c.y)))), mini(h - 1, int(maxf(a.y, maxf(b.y, c.y)))) + 1):
			for x in range(maxi(0, int(minf(a.x, minf(b.x, c.x)))), mini(w - 1, int(maxf(a.x, maxf(b.x, c.x)))) + 1):
				var p := Vector2(x + 0.5, y + 0.5)
				var u := (b - p).cross(c - p) / d; var v := (c - p).cross(a - p) / d
				if u >= 0 and v >= 0 and u + v <= 1: grid[y * w + x] = 1
	return grid.count(1) * RES * RES

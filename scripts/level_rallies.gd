class_name LevelRallies
extends Node3D
# Docs: features/rallies.md — update in the same change as this file.
# Tests: tests/headless/test_level_rallies.gd — extend in the same change.
# The level's rallies (the save's `rallies`): only the active one shows, a start line from tools/start_lab.html at its start
# and at its finish with spectators either side. The gravel pads under every line are baked into the ground and always stay.

# The start lines the lab exported (`?seed=<n>&width=7&len=50`); each rally end draws one by a hash of its name.
const MODELS := [
	"res://models/start_lines/start_5.glb",
	"res://models/start_lines/start_8.glb",
	"res://models/start_lines/start_12.glb",
	"res://models/start_lines/start_15.glb",
	"res://models/start_lines/start_21.glb",
]
const AREA_HALF_L := 25.0   # half the exported start area's length along the road
const CROWD_SIDE_M := 5.6   # crowd centre off the road centreline: the lab's tape plus half the strip it leaves for spectators
const CROWD_STEP_M := 7.0
const CROWD_R := 2.2
const CROWD_N := 6
const MIN_SOLID_Y := 0.3  # triangles lower than this (road paint, mats) get no collision
const CONTROL_ZONE := Vector2(-5.0, 13.0)  # along the line, where the lab puts the start control and sponsor fencing: no crowd

static var active := ""  # the shown rally's name, "" for none; kept across level reloads

var rallies: Array = []
var _ground: Callable
var _spectators: LevelSpectators


func setup(list: Array, ground: Callable, spectators: LevelSpectators) -> void:
	rallies = list
	_ground = ground
	_spectators = spectators
	show_active()


func names() -> Array[String]:
	var out: Array[String] = []
	for r: Dictionary in rallies:
		out.append(String(r.get("name", "")))
	return out


# Rebuilds the lines and their crowds for `active`; with no such rally, nothing but the gravel pads is left.
func show_active() -> void:
	for c in get_children():
		c.queue_free()
	var crowd: Array = []
	for r: Dictionary in rallies:
		if String(r.get("name", "")) != active:
			continue
		for end in ["start", "finish"]:
			var e: Dictionary = r[end]
			add_child(line_model(e, model_for(active, end), _ground))
			crowd.append_array(crowd_groups(e))
	if _spectators != null:
		_spectators.set_extra(crowd)


static func model_for(rally: String, end: String) -> String:
	return MODELS[absi(hash(rally + "/" + end)) % MODELS.size()]


# A start line standing on the ground at the rally end, its -z (the way cars leave the line) turned to `yaw`.
static func line_model(e: Dictionary, path: String, ground: Callable) -> Node3D:
	var root := Node3D.new()
	root.name = "Line"
	var x := float(e["x"])
	var z := float(e["z"])
	root.position = Vector3(x, float(ground.call(x, z)) if ground.is_valid() else 0.0, z)
	root.rotation.y = float(e.get("yaw", 0.0))
	var scene := load(path) as PackedScene if ResourceLoader.exists(path) else null
	if scene != null:
		var model := scene.instantiate()
		LevelView._shade_base(model)
		root.add_child(model)
		root.add_child(collider(model))
	return root


# One solid body from every triangle of the line that stands above the road, so flat paint and mats never snag a wheel.
static func collider(model: Node) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "Collider"
	var faces := PackedVector3Array()
	var meshes := model.find_children("*", "MeshInstance3D", true, false)
	if model is MeshInstance3D:
		meshes.append(model)
	for mi: MeshInstance3D in meshes:
		if mi.mesh == null:
			continue
		var xf := _relative_transform(mi, model)
		var tri := mi.mesh.get_faces()
		for i in range(0, tri.size(), 3):
			var a := xf * tri[i]
			var b := xf * tri[i + 1]
			var c := xf * tri[i + 2]
			if maxf(a.y, maxf(b.y, c.y)) > MIN_SOLID_Y:
				faces.append_array([a, b, c])
	if not faces.is_empty():
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
	return body


static func _relative_transform(n: Node3D, top: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	while n != null and n != top:
		xf = n.transform * xf
		n = n.get_parent() as Node3D
	return (top as Node3D).transform * xf if top is Node3D else xf


# Spectator groups ({x, z, r, n}) along both sides of a line, behind its tape, leaving out the start control.
static func crowd_groups(e: Dictionary) -> Array:
	var out: Array = []
	var basis := Basis(Vector3.UP, float(e.get("yaw", 0.0)))
	var origin := Vector3(float(e["x"]), 0.0, float(e["z"]))
	for side in [-1.0, 1.0]:
		var along := -AREA_HALF_L + CROWD_R
		while along <= AREA_HALF_L - CROWD_R:
			if along < CONTROL_ZONE.x or along > CONTROL_ZONE.y:
				var p := origin + basis * Vector3(side * CROWD_SIDE_M, 0.0, along)
				out.append({"x": p.x, "z": p.z, "r": CROWD_R, "n": CROWD_N})
			along += CROWD_STEP_M
	return out

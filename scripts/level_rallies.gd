class_name LevelRallies
extends Node3D
# Docs: features/rallies.md — update in the same change as this file.
# Tests: tests/headless/test_level_rallies.gd — extend in the same change.
# The level's rallies (the save's `rallies`): only the active one shows, a baked start line (LevelBuildings.start_lines) at its start
# and at its finish with spectators either side. The gravel pads under every line are baked into the ground and always stay.

const AREA_HALF_L := 25.0   # half the start area's length along the road
const CROWD_SIDE_M := 5.6   # crowd centre off the road centreline: the lab's tape plus half the strip it leaves for spectators
const CROWD_STEP_M := 7.0
const CROWD_R := 2.2
const CROWD_N := 6
const CONTROL_ZONE := Vector2(-5.0, 13.0)  # along the line, where the lab puts the start control and sponsor fencing: no crowd

static var active := ""  # the shown rally's name, "" for none; kept across level reloads

var rallies: Array = []
var _ground: Callable
var _spectators: LevelSpectators
var _lines: Dictionary = {}


func setup(list: Array, ground: Callable, spectators: LevelSpectators, buildings: LevelBuildings = null) -> void:
	rallies = list
	_ground = ground
	_spectators = spectators
	_lines = buildings.start_lines if buildings != null else {}
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
			var seed := variant_for(active, end, _lines.keys())
			if _lines.has(seed):
				add_child(line_model(e, _lines[seed], _ground))
			crowd.append_array(crowd_groups(e))
	if _spectators != null:
		_spectators.set_extra(crowd)


# The baked variant (by seed) a rally end draws, picked by a hash of its rally and end; -1 with none baked.
static func variant_for(rally: String, end: String, seeds: Array) -> int:
	if seeds.is_empty():
		return -1
	var sorted := seeds.duplicate()
	sorted.sort()
	return sorted[absi(hash(rally + "/" + end)) % sorted.size()]


# A start line standing on the ground at the rally end, its -z (the way cars leave the line) turned to `yaw`: one mesh
# (one draw call), one solid collider, and the sign text as labels.
static func line_model(e: Dictionary, line: Dictionary, ground: Callable) -> Node3D:
	var root := Node3D.new()
	root.name = "Line"
	var x := float(e["x"])
	var z := float(e["z"])
	root.position = Vector3(x, float(ground.call(x, z)) if ground.is_valid() else 0.0, z)
	root.rotation.y = float(e.get("yaw", 0.0))
	var mi := MeshInstance3D.new()
	mi.name = "Mesh"
	mi.mesh = line.mesh
	root.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "Collider"
	var cs := CollisionShape3D.new()
	cs.shape = line.shape
	body.add_child(cs)
	root.add_child(body)
	for t: Dictionary in line.texts:
		root.add_child(LevelBuildings.text_label(t))
	return root


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

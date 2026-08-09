class_name MapHouse
extends RefCounted
# Procedural house prop, built for the middle of the world map table.
#
# CURRENTLY UNUSED. It stood at RallyLibrary.HQ_MAP_POS while HQ lit a circle of its own,
# marking the point every reveal grew out from. HQ lights nothing now — the player starts
# inside their own opening rally (todo/opening-rally.md) — so the middle is ordinary fogged
# ground and a building sitting in it would advertise a centre the map no longer has.
#
# Kept rather than deleted because it is the one thing that would have to be rebuilt if
# `GameConfig.map_hq_reveal_radius` is ever raised above 0 again: put a `MapHouse.build()`
# back at the map centre in `hq.gd::_refresh_map_pins` and HQ is a place again.
#
# A HOUSE rather than another flag or trophy on purpose: the map's other markers all mean
# "an event you can enter", and HQ is not one. A different silhouette keeps the visual
# language honest — flag = rally, trophy = prize event, car = the car you win, house = home.
#
# All geometry is procedural (no .glb) and deliberately cheap — the same rule the flag and
# trophy markers follow, since the table rebuilds every marker on each map refresh.
# `build()` returns a Node3D whose base sits at local y = 0, ready to drop onto the map
# plane exactly like a pin.

# Footprint matched to the pin markers so HQ reads as one of the map's objects rather than
# a model at a different scale. HEIGHT is the ridge — the marker's top.
const BODY_SIZE := Vector3(0.150, 0.105, 0.120)   # walls: width, height, depth
const ROOF_OVERHANG := 0.022                      # eaves past the walls on all sides
const ROOF_HEIGHT := 0.070                        # wall top to ridge
const CHIMNEY_SIZE := Vector3(0.026, 0.055, 0.026)
const CHIMNEY_OFFSET := Vector2(0.040, 0.020)     # from the body centre, x/z
const DOOR_SIZE := Vector3(0.040, 0.058, 0.006)   # a slab proud of the front wall
const HEIGHT := BODY_SIZE.y + ROOF_HEIGHT

# Warm, lit-from-within palette: HQ should read as the one FRIENDLY thing on a map whose
# job is otherwise to be dark and unexplored.
const WALL_COLOR := Color(0.86, 0.82, 0.74)
const ROOF_COLOR := Color(0.52, 0.24, 0.20)
const DOOR_COLOR := Color(0.30, 0.20, 0.14)
const CHIMNEY_COLOR := Color(0.44, 0.40, 0.38)


# Build the house. `facing` (radians) rotates it about Y so the door can be turned toward
# the camera; 0 puts the door on the +Z face.
static func build(facing := 0.0) -> Node3D:
	var root := Node3D.new()
	root.rotation.y = facing

	# Walls — a plain box sitting on the map plane.
	root.add_child(MeshUtil.box(BODY_SIZE, _mat(WALL_COLOR),
		Vector3(0.0, BODY_SIZE.y * 0.5, 0.0)))

	# Roof — a prism built as a triangle mesh rather than a squashed box, because a gable is
	# the single silhouette cue that makes this read as a HOUSE at map scale.
	var roof := MeshInstance3D.new()
	roof.mesh = _roof_mesh()
	roof.material_override = _mat(ROOF_COLOR)
	roof.position = Vector3(0.0, BODY_SIZE.y, 0.0)
	root.add_child(roof)

	# Chimney, offset from centre so the silhouette is not symmetrical — a dead-centre stack
	# reads as a spike on the ridge rather than a chimney.
	root.add_child(MeshUtil.box(CHIMNEY_SIZE, _mat(CHIMNEY_COLOR), Vector3(
		CHIMNEY_OFFSET.x, BODY_SIZE.y + ROOF_HEIGHT * 0.45, CHIMNEY_OFFSET.y)))

	# Door — a thin slab proud of the front wall, so it catches light instead of vanishing
	# into the wall colour the way a texture would at this size.
	root.add_child(MeshUtil.box(DOOR_SIZE, _mat(DOOR_COLOR), Vector3(
		0.0, DOOR_SIZE.y * 0.5, BODY_SIZE.z * 0.5 + DOOR_SIZE.z * 0.5)))
	return root


# The gable roof: two sloped faces meeting at a ridge running along X, with the gable ends
# closed off. Built by hand because Godot has no prism primitive and a rotated box would
# leave the ends open.
static func _roof_mesh() -> ArrayMesh:
	var hx := BODY_SIZE.x * 0.5 + ROOF_OVERHANG
	var hz := BODY_SIZE.z * 0.5 + ROOF_OVERHANG
	var ridge := ROOF_HEIGHT
	# Four eave corners and the two ridge ends.
	var a := Vector3(-hx, 0.0, -hz)
	var b := Vector3(hx, 0.0, -hz)
	var c := Vector3(hx, 0.0, hz)
	var d := Vector3(-hx, 0.0, hz)
	var r0 := Vector3(-hx, ridge, 0.0)
	var r1 := Vector3(hx, ridge, 0.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Two sloping quads (each as a pair of triangles) plus the two triangular gable ends
	# that close the -X and +X sides. Listed counter-clockwise seen from OUTSIDE; `_tri`
	# emits them reversed, because Godot treats CLOCKWISE winding as front-facing.
	_tri(st, a, r0, r1); _tri(st, a, r1, b)   # back slope (-Z)
	_tri(st, d, c, r1); _tri(st, d, r1, r0)   # front slope (+Z)
	_tri(st, a, d, r0)                        # gable end at -X
	_tri(st, b, r1, c)                        # gable end at +X
	st.generate_normals()
	return st.commit()


# Emit one triangle, REVERSING the winding of the three points given.
#
# Callers list their vertices counter-clockwise as seen from outside the mesh — the
# right-hand-rule order that reads naturally when you work the geometry out on paper — but
# Godot's front faces are CLOCKWISE. Flipping here keeps every call site in the readable
# convention and puts the correction in one place; without it the roof renders inside-out
# (its outer faces culled, so the house looks hollow from above).
static func _tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3) -> void:
	st.add_vertex(p0)
	st.add_vertex(p2)
	st.add_vertex(p1)


# Flat lit material in the house style — no texture, since every part is a solid colour at
# this size and a texture would only cost memory per marker.
static func _mat(tint: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = tint
	m.roughness = 0.85
	m.metallic = 0.0
	return m

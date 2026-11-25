extends GutTest
# CarCargo: builds the delivery boxes and straps from a synthetic per-car layout
# (features/car-cargo.md); no shipped layout is relied on.

const LAYOUT := {
	"boxes": [{"x": 0.0, "y": 1.2, "z": 0.3, "w": 0.4, "h": 0.3, "d": 0.5, "yaw": 15.0}],
	"straps": [{"points": [[-0.5, 1.2, 0.3], [-0.2, 1.51, 0.3], [0.2, 1.51, 0.3], [0.5, 1.2, 0.3]], "side": [0, 0, 1], "width": 0.04}],
}


func test_no_layout_builds_nothing() -> void:
	assert_null(CarCargo.build("no_such_car"), "a car without a layout carries no cargo")


func test_box_rests_on_its_y_and_strap_follows_its_points() -> void:
	var cargo := CarCargo.build("synthetic", LAYOUT)
	autofree(cargo)
	var aabb := cargo.mesh.get_aabb()
	assert_almost_eq(aabb.position.y, 1.2, 0.001, "the box's bottom sits at the layout's y")
	assert_almost_eq(aabb.end.y, 1.51, 0.001, "the strap's top point is the highest thing")
	assert_almost_eq(aabb.position.x, -0.5, 0.001, "the strap reaches its first point")


func test_faces_point_outward() -> void:
	var cargo := CarCargo.build("synthetic", {"boxes": [LAYOUT["boxes"][0]]})
	autofree(cargo)
	var arrays := cargo.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var centre := Vector3(0.0, 1.35, 0.3)
	for i in range(0, verts.size(), 3):
		var face := (verts[i + 1] - verts[i]).cross(verts[i + 2] - verts[i])
		assert_lt(face.dot(normals[i]), 0.0, "the triangle at vertex %d winds clockwise seen from outside" % i)
		assert_gt((verts[i] - centre).dot(normals[i]), 0.0, "the normal at vertex %d points away from the box" % i)

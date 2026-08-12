class_name ObstacleBody
# Shared builder for the foliage-field obstacle hitbox: one StaticBody3D carrying a box
# per instance, all sharing a SINGLE BoxShape3D resource instanced via the physics
# server (cheap — one shape, N transforms). The body joins the damage OBSTACLE_GROUP so
# the car's damage model counts hits against it (and not the ground/road). Used by the
# tree fields (TreeMeshField, BillboardField) with upright boxes, and by the corner
# barriers (BarrierField) via build_oriented, which needs each box TURNED to follow the
# road. The ground-cover bushes and scenery rings skip collision entirely, and roadside
# signs use their own per-body RigidBody shape.


# Build the shared-box obstacle body under `parent`. `positions` are Vector3 world
# points at GROUND height; each box is `2*radius` wide/deep and `height` tall, centred
# half its height above its ground point so it rests on the surface. Returns the shared
# BoxShape3D — the caller MUST keep a reference so its RID stays alive for the body's
# lifetime.
static func build(parent: Node, positions: PackedVector3Array, radius: float, height: float) -> BoxShape3D:
	return _build(parent, _upright_boxes(positions, height),
		Vector3(radius * 2.0, height, radius * 2.0), "Collision")


# ORIENTED variant: one box of `size` per full Transform3D, so the boxes can be
# rotated (and not just placed) — what the corner barriers need, since each module
# is turned to follow the road tangent. Each transform is the box's CENTRE pose, not
# a ground point. Same deal as build(): one shared shape, N transforms, the body in
# OBSTACLE_GROUP, and the caller MUST keep the returned shape alive. `body_name`
# keeps sibling bodies distinguishable when a parent builds several.
static func build_oriented(parent: Node, transforms: Array[Transform3D], size: Vector3,
		body_name := "Collision") -> BoxShape3D:
	return _build(parent, transforms, size, body_name)


# Ground points -> upright box centre poses (each raised half its height so the box
# rests on the surface).
static func _upright_boxes(positions: PackedVector3Array, height: float) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	for pos in positions:
		out.append(Transform3D(Basis.IDENTITY, Vector3(pos.x, pos.y + height * 0.5, pos.z)))
	return out


static func _build(parent: Node, transforms: Array[Transform3D], size: Vector3,
		body_name: String) -> BoxShape3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.add_to_group(DamageModel.OBSTACLE_GROUP)
	parent.add_child(body)
	var shape := BoxShape3D.new()
	shape.size = size
	for box_xform in transforms:
		PhysicsServer3D.body_add_shape(body.get_rid(), shape.get_rid(), box_xform)
	return shape

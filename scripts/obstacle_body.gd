class_name ObstacleBody
# Shared builder for the foliage-field obstacle hitbox: one StaticBody3D carrying a box
# per instance, all sharing a SINGLE BoxShape3D resource instanced via the physics
# server (cheap — one shape, N transforms). The body joins the damage OBSTACLE_GROUP so
# the car's damage model counts hits against it (and not the ground/road). Used by the
# tree fields (TreeMeshField, BillboardField); the ground-cover bushes and scenery rings
# skip collision entirely, and roadside signs use their own per-body RigidBody shape.


# Build the shared-box obstacle body under `parent`. `positions` are Vector3 world
# points at GROUND height; each box is `2*radius` wide/deep and `height` tall, centred
# half its height above its ground point so it rests on the surface. Returns the shared
# BoxShape3D — the caller MUST keep a reference so its RID stays alive for the body's
# lifetime.
static func build(parent: Node, positions: PackedVector3Array, radius: float, height: float) -> BoxShape3D:
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.add_to_group(DamageModel.OBSTACLE_GROUP)
	parent.add_child(body)
	var shape := BoxShape3D.new()
	shape.size = Vector3(radius * 2.0, height, radius * 2.0)
	for pos in positions:
		# Box centred half its height above the ground so it rests on it.
		var box_xform := Transform3D(Basis.IDENTITY, Vector3(pos.x, pos.y + height * 0.5, pos.z))
		PhysicsServer3D.body_add_shape(body.get_rid(), shape.get_rid(), box_xform)
	return shape

class_name BarrierField
extends Node3D
# Builds the physical corner barriers from a BarrierLayout plan
# (features/barriers.md). Each placement becomes one 2 m BarrierSection module,
# stitched end to end into a continuous run along the outside of a sharp corner.
#
# RENDERING: modules are identical (both styles are manufactured units, so
# BarrierSection has no per-module jitter), which lets a whole run draw from one
# MultiMesh PER PART — the armco beam, its post, the bolt, etc. — instead of a node
# per module. Batches are anchored at their RUN's centroid rather than at the world
# origin, because the shared world-prop render cull measures camera→node origin: a
# single whole-track batch at the origin would test the wrong distance and pop every
# barrier in at once (the same reasoning SignField documents).
#
# COLLISION: unlike the roadside signs — cosmetic clutter the car ploughs straight
# through — a barrier is SOLID. Each run gets one StaticBody3D carrying a box per
# module, all sharing a single BoxShape3D via the physics server (ObstacleBody), on
# the world layer and in the damage OBSTACLE_GROUP, so clipping one costs HP like a
# tree. Static bodies never fall, so unlike the signs there is nothing to freeze
# against the streamed-in-a-ring terrain collision.

# Number of modules built — a renderer-independent count for headless tests.
var barrier_count := 0

# Every module's world pose, in build order. The modules themselves are not nodes
# (they are MultiMesh instances), so this is how tests and any future debug overlay
# see where a run actually landed.
var module_transforms: Array[Transform3D] = []

# The shared BoxShape3D per style. MUST be held for the bodies' lifetime: the shapes
# are instanced into the bodies by RID, so dropping the last reference frees them.
var _shapes: Array[BoxShape3D] = []

# style -> {"parts": Array (BarrierSection.parts()), "aabb": AABB} — each style's
# prototype geometry, built once and reused by every module of that style.
var _protos := {}


# Build one module per layout entry. `params` is GameConfig.barrier_render_params().
func build(layout: Array, terrain: TerrainManager, params: Dictionary) -> void:
	if layout.is_empty():
		return
	var pitch: float = maxf(float(params.get("section_length_m", 2.0)), 0.1)
	var half_w: float = float(params.get("track_width", 7.0)) * 0.5
	var road_gap: float = float(params.get("road_gap_m", 0.6))
	var sink: float = float(params.get("sink_m", 0.0))

	# Group by (run, style): one batch set per group. A run can hold both styles
	# when the stage's gravel↔tarmac switch falls inside the corner.
	var groups := {}
	for entry in layout:
		var style := int(entry["style"])
		var proto := _prototype(style, pitch, params)
		var xform := _module_transform(entry, terrain, half_w, road_gap,
			float(proto["aabb"].end.x), sink)
		var key := Vector2i(int(entry.get("run", 0)), style)
		if not groups.has(key):
			groups[key] = []
		groups[key].append(xform)
		module_transforms.append(xform)
		barrier_count += 1

	for key: Vector2i in groups:
		_build_group(int(key.y), groups[key], pitch, params)


# Where one module sits in the world: at its road edge, `road_gap` clear of the
# visible road edge (measured to the model's nearest face, which differs per style
# — the jersey rail's foot reaches further toward the road than the armco beam), Z
# along the road tangent and +X turned in toward the racing line.
func _module_transform(entry: Dictionary, terrain: TerrainManager, half_w: float,
		road_gap: float, face_reach: float, sink: float) -> Transform3D:
	var pos: Vector2 = entry["pos"]
	var tangent: Vector2 = (entry["tangent"] as Vector2).normalized()
	var side: int = int(entry["side"])
	var perp := Vector2(-tangent.y, tangent.x)
	var edge := pos + float(side) * perp * (half_w + road_gap + face_reach)
	# Inward normal — from the barrier back toward the road, i.e. where +X must point.
	var inward := -float(side) * perp
	# Ground height AT THE BARRIER, not at the centerline: the run sits outside the
	# flattened road band, so the centerline height (what the signs and arches use,
	# standing on the road itself) would float or bury it on a cambered verge. Sunk a
	# few cm so small unevenness under a rigid 2 m module buries rather than floats.
	var y := -sink   # no terrain (the render harness): flat ground at y = 0
	if terrain != null:
		y = terrain.height_at(edge.x, edge.y) - sink
	# Basis.looking_at(d) puts -Z on d and +X on (-d.z, 0, d.x); solving that for
	# +X == inward gives the look direction below.
	return Transform3D(
		Basis.looking_at(Vector3(inward.y, 0.0, -inward.x), Vector3.UP),
		Vector3(edge.x, y, edge.y))


# One style's geometry, built once: a prototype BarrierSection is created off-tree,
# its parts and AABB harvested, and the node freed. Nothing of it stays in the scene.
func _prototype(style: int, pitch: float, params: Dictionary) -> Dictionary:
	if _protos.has(style):
		return _protos[style]
	var proto := BarrierSection.new()
	proto.style = style
	proto.length = pitch
	if params.has("sun_direction"):
		proto.sun_direction = params["sun_direction"]
	proto.build()  # explicit: never entered the tree, so _ready() has not run
	var entry := {"parts": proto.parts(), "aabb": proto.local_aabb()}
	proto.free()
	_protos[style] = entry
	return entry


# Render + collide one (run, style) group of module transforms.
func _build_group(style: int, xforms: Array, pitch: float, params: Dictionary) -> void:
	var proto: Dictionary = _protos[style]
	var parts: Array = proto["parts"]
	var box: AABB = proto["aabb"]
	# Anchor the batches at the run's centroid so the shared render-distance cull
	# measures camera→run instead of camera→world-origin.
	var centre := Vector3.ZERO
	for x: Transform3D in xforms:
		centre += x.origin
	centre /= float(xforms.size())
	var anchor := Transform3D(Basis.IDENTITY, centre)
	var to_local := anchor.affine_inverse()
	var render_dist := float(params.get("render_distance_m", 0.0))
	var render_fade := float(params.get("render_fade_m", 0.0))

	for part: Dictionary in parts:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = part["mesh"]
		mm.instance_count = xforms.size()
		for i in range(xforms.size()):
			mm.set_instance_transform(i, to_local * (xforms[i] as Transform3D) * part["transform"])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = part["material"]
		mmi.transform = anchor
		MeshUtil.apply_visibility_range(mmi, render_dist, render_fade)
		add_child(mmi)

	# One solid hitbox per module: the model's full silhouette, but exactly `pitch`
	# long so neighbours tile along the run instead of overlapping into wedges that
	# could catch a wheel. Full height even where the model is open underneath (the
	# armco beam) — a car should be stopped by a guardrail, not slide under it.
	var shape_size := Vector3(box.size.x, box.size.y, pitch)
	var shape_offset := Vector3(box.get_center().x, box.size.y * 0.5 + box.position.y, 0.0)
	var shape_xforms: Array[Transform3D] = []
	for x: Transform3D in xforms:
		shape_xforms.append(x * Transform3D(Basis.IDENTITY, shape_offset))
	_shapes.append(ObstacleBody.build_oriented(self, shape_xforms, shape_size,
		"Collision%d" % _shapes.size()))

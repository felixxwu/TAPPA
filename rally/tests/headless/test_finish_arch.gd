extends GutTest
# FinishArch: the procedural inflatable rally finish gate (scripts/finish_arch.gd).
# These are cheap structural checks — the arch builds itself in _ready() from
# primitives with no scene/terrain dependency, so we just instantiate it and
# assert the expected parts exist with sane geometry. No pixel checks (headless
# can't read them back; visual iteration is done via tools/render_model.gd).

const FinishArch = preload("res://scripts/finish_arch.gd")

var _arch: Node3D


func before_each() -> void:
	_arch = FinishArch.new()
	add_child(_arch)  # triggers _ready() -> build()
	await get_tree().process_frame


func after_each() -> void:
	_arch.free()


func _meshes() -> Array:
	var out := []
	for c in _arch.get_children():
		if c is MeshInstance3D:
			out.append(c)
	return out


func test_builds_a_solid_arch_body() -> void:
	var body := _arch.get_node_or_null("ArchBody") as MeshInstance3D
	assert_not_null(body, "arch has an ArchBody mesh")
	assert_not_null(body.mesh, "ArchBody has a mesh")
	assert_gt(body.mesh.get_faces().size(), 0, "arch mesh has geometry")
	assert_true(body.material_override is ShaderMaterial, "arch uses a ShaderMaterial")


func test_arch_spans_its_opening_and_height() -> void:
	var body := _arch.get_node("ArchBody") as MeshInstance3D
	var aabb := body.mesh.get_aabb()
	var expected_w: float = _arch.span + 2.0 * _arch.leg_width
	# The flat front/back caps fix the outer width at opening + two legs; the
	# depth bulge only adds thickness front-to-back, so allow a little slack.
	assert_almost_eq(aabb.size.x, expected_w, _arch.bulge + 0.2,
		"arch width = opening + two legs")
	assert_gt(aabb.size.z, _arch.depth - 0.1, "arch has front-to-back depth")
	assert_almost_eq(aabb.size.y, _arch.height, 0.3, "arch reaches its configured height")
	assert_almost_eq(aabb.position.y, 0.0, 0.1, "arch stands on the ground (y = 0)")


func test_has_banners_ropes_and_anchors() -> void:
	# Top strip (front + back) + two legs = 4 banner quads, plus seams + ropes +
	# the two stakes. We assert the headline parts rather than exact counts.
	var quad_count := 0
	var box_count := 0
	var cyl_count := 0
	for mi in _meshes():
		if mi.mesh is QuadMesh:
			quad_count += 1
		elif mi.mesh is BoxMesh:
			box_count += 1
		elif mi.mesh is CylinderMesh:
			cyl_count += 1
	assert_gte(quad_count, 4, "at least the 3 beam/leg banner quads + seams present")
	assert_eq(box_count, 2, "two ground-anchor stakes")
	assert_eq(cyl_count, 4, "four guy ropes (two per side)")


func test_rebuild_is_idempotent() -> void:
	# build() clears children first, so calling it again must not duplicate parts.
	var before := _arch.get_child_count()
	_arch.build()
	await get_tree().process_frame
	assert_eq(_arch.get_child_count(), before, "rebuild replaces rather than appends")

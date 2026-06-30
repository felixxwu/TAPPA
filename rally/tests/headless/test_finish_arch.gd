extends GutTest
# FinishArch: the procedural inflatable rally finish gate (scripts/finish_arch.gd).
# These are cheap structural checks — the arch builds itself in _ready() from
# primitives with no scene/terrain dependency, so we just instantiate it and
# assert the expected parts exist with sane geometry. No pixel checks (headless
# can't read them back; visual iteration is done via tools/render_model.gd).


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
	# Two cream leg boards plus the leg seams give several quads; the stakes are
	# boxes and the guy ropes cylinders. We assert the headline parts, not exact counts.
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
	assert_gte(quad_count, 4, "leg banner boards + seam quads present")
	assert_eq(box_count, 2, "two ground-anchor stakes")
	assert_eq(cyl_count, 4, "four guy ropes (two per side)")


func _label_texts() -> Array:
	var out := []
	for c in _arch.get_children():
		if c is Label3D:
			out.append((c as Label3D).text)
	return out


func test_banners_show_live_event_info() -> void:
	# The banners render the event's data, not placeholder text: the FINISH/START
	# wordmark + rally name on the beam, and the stage / time-to-beat on the legs. The
	# difficulty tier is a hidden value and must NEVER appear. Rebuild a START gate
	# carrying a sample event and read the Label3D text.
	_arch.is_start = true
	_arch.info = {"rally_name": "Coastal Sprint", "stage_index": 1, "stage_count": 3,
		"target_ms": 83450, "difficulty": 2}
	_arch.build()
	await get_tree().process_frame
	var texts := _label_texts()
	var joined := "\n".join(texts)
	assert_gt(texts.size(), 0, "arch has Label3D banners")
	assert_true(joined.contains("START"), "beam shows the START wordmark")
	assert_true(joined.contains("COASTAL SPRINT"), "beam shows the rally name (upper-cased)")
	assert_true(joined.contains("STAGE"), "leg shows the stage number")
	assert_true(joined.contains("2 / 3"), "leg shows this stage of the total")
	assert_true(joined.contains("1:23.45"), "leg shows the time-to-beat (start gate)")
	assert_false(joined.contains("TIER"), "the hidden difficulty tier is never shown, even when supplied")


func test_banners_fall_back_to_wordmark_without_an_event() -> void:
	# With no active rally (empty info) the gate shows just FINISH/START — no
	# misleading STAGE / TIER / time placeholders.
	_arch.is_start = false
	_arch.info = {}
	_arch.build()
	await get_tree().process_frame
	var joined := "\n".join(_label_texts())
	assert_true(joined.contains("FINISH"), "beam still shows the FINISH wordmark")
	assert_false(joined.contains("STAGE"), "no stage line without an event")
	assert_false(joined.contains("TIER"), "no tier line without an event")


func test_flat_caps_face_outward() -> void:
	# Regression: the flat front (+Z) / back (-Z) caps must be wound so they front-
	# face the outside viewer, not the hollow interior. Godot treats CW (as seen by
	# the viewer) as the front face, so a +Z-facing triangle has an RH cross-product
	# normal pointing -Z and a -Z-facing one points +Z. A backwards cap gets culled
	# and the arch looks see-through / concave (the bug this test guards).
	var body := _arch.get_node("ArchBody") as MeshInstance3D
	var faces: PackedVector3Array = body.mesh.get_faces()
	var hz: float = _arch.depth * 0.5
	var front_caps := 0
	var back_caps := 0
	for i in range(0, faces.size(), 3):
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		var rh := (b - a).cross(c - a)
		if absf(a.z - hz) < 1e-3 and absf(b.z - hz) < 1e-3 and absf(c.z - hz) < 1e-3:
			front_caps += 1
			assert_lt(rh.z, 0.0, "front (+Z) cap triangle front-faces the approach")
		elif absf(a.z + hz) < 1e-3 and absf(b.z + hz) < 1e-3 and absf(c.z + hz) < 1e-3:
			back_caps += 1
			assert_gt(rh.z, 0.0, "back (-Z) cap triangle front-faces down-track")
	assert_gt(front_caps, 0, "arch has flat front-cap triangles")
	assert_gt(back_caps, 0, "arch has flat back-cap triangles")


func test_rebuild_is_idempotent() -> void:
	# build() clears children first, so calling it again must not duplicate parts.
	var before := _arch.get_child_count()
	_arch.build()
	await get_tree().process_frame
	assert_eq(_arch.get_child_count(), before, "rebuild replaces rather than appends")

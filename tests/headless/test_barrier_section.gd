extends GutTest
# BarrierSection: the procedural 2 m corner-barrier module (scripts/barrier_section.gd).
# Cheap structural checks — a section builds itself from primitives in _ready()
# with no scene/terrain/config dependency, so we instantiate one per style and
# assert the contracts that make a run of them work: it stands on the ground, it
# covers its own pitch so stitched modules leave no gap, it stays thin enough to
# sit at a road edge, and it rebuilds rather than accumulating. No pixel checks
# (headless can't read them back — the look is iterated via tools/render_barriers.sh).

var _made: Array[Node] = []


func after_each() -> void:
	for n in _made:
		if is_instance_valid(n):
			n.free()
	_made.clear()


func _section(style: int) -> BarrierSection:
	var s := BarrierSection.new()
	s.style = style
	add_child(s)  # triggers _ready() -> build()
	_made.append(s)
	return s


func _meshes(s: Node) -> Array:
	var out := []
	for c in s.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			out.append(c)
	return out


func test_every_style_builds_real_geometry() -> void:
	for style in BarrierSection.Style.values():
		var s := _section(style)
		var meshes := _meshes(s)
		assert_gt(meshes.size(), 0, "%s builds mesh instances" % BarrierSection.style_name(style))
		var faces := 0
		for mi in meshes:
			faces += mi.mesh.get_faces().size()
			assert_true(mi.material_override is ShaderMaterial,
				"%s parts use the PS1 ShaderMaterial" % BarrierSection.style_name(style))
		assert_gt(faces, 0, "%s has triangles" % BarrierSection.style_name(style))


func test_every_style_stands_on_the_ground() -> void:
	for style in BarrierSection.Style.values():
		var s := _section(style)
		var box := s.local_aabb()
		var label := BarrierSection.style_name(style)
		# Nothing sunk below the ground plane or floating above it: the lowest
		# geometry is at y = 0 (the module is placed at road-surface height).
		assert_almost_eq(box.position.y, 0.0, 0.05, "%s rests on y = 0" % label)
		assert_gt(box.size.y, 0.2, "%s has height" % label)
		assert_lt(box.size.y, 2.0, "%s is not a skyscraper" % label)


func test_every_style_stays_thin_enough_to_line_a_road_edge() -> void:
	# Placement puts the module's local origin on the barrier line, so the model
	# must straddle x = 0 without sprawling into the road or the scenery.
	for style in BarrierSection.Style.values():
		var s := _section(style)
		var box := s.local_aabb()
		var label := BarrierSection.style_name(style)
		assert_lt(box.size.x, 1.0, "%s is a thin barrier, not a building" % label)
		assert_lt(absf(box.get_center().x), 0.3, "%s is centred on the barrier line" % label)


func test_every_style_covers_its_own_pitch_along_the_run() -> void:
	# The stitching contract: a module's geometry reaches its own end faces, so a
	# run laid at `length` pitch has no hole between modules.
	for style in BarrierSection.Style.values():
		var s := _section(style)
		var box := s.local_aabb()
		assert_gte(box.size.z, s.length,
			"%s spans its full 2 m pitch" % BarrierSection.style_name(style))
		assert_lt(box.size.z, s.length * 1.5,
			"%s stays roughly modular (no long overhang)" % BarrierSection.style_name(style))


func test_stitched_modules_overlap_instead_of_leaving_a_gap() -> void:
	# Two neighbours placed one pitch apart: the first module's geometry must reach
	# at least as far as the second module's geometry starts.
	for style in BarrierSection.Style.values():
		var a := _section(style)
		var b := _section(style)
		var a_end: float = a.local_aabb().end.z
		var b_start: float = a.length + b.local_aabb().position.z
		assert_gte(a_end, b_start,
			"%s: module ends meet across the joint" % BarrierSection.style_name(style))


func test_rebuild_replaces_rather_than_accumulates() -> void:
	var s := _section(BarrierSection.Style.ARMCO)
	var before := _meshes(s).size()
	s.build()
	assert_eq(_meshes(s).size(), before, "rebuilding replaces the previous model")
	# Switching style also swaps the model out wholesale.
	s.style = BarrierSection.Style.JERSEY
	s.build()
	assert_gt(_meshes(s).size(), 0, "a restyled section still has a model")


func test_modules_of_a_style_are_identical() -> void:
	# BarrierField draws a whole run from one MultiMesh per part, which only holds if
	# two modules of a style are the same model — i.e. no per-module jitter crept back in.
	for style in BarrierSection.Style.values():
		var a := _meshes(_section(style))
		var b := _meshes(_section(style))
		assert_eq(a.size(), b.size(),
			"%s builds the same part count every time" % BarrierSection.style_name(style))
		for i in range(mini(a.size(), b.size())):
			assert_eq(a[i].transform, b[i].transform,
				"%s part %d is in the same place every time"
					% [BarrierSection.style_name(style), i])


func test_surface_picks_the_style() -> void:
	# The whole selection rule: tarmac gets concrete, gravel gets steel. Uses an
	# explicit threshold rather than the configured one (that value is tunable).
	assert_eq(BarrierSection.style_for_tarmac(1.0, 0.5), BarrierSection.Style.JERSEY,
		"full tarmac gets the concrete jersey rail")
	assert_eq(BarrierSection.style_for_tarmac(0.0, 0.5), BarrierSection.Style.ARMCO,
		"gravel gets the steel armco")
	# Monotonic about the threshold, whatever the threshold is set to.
	assert_eq(BarrierSection.style_for_tarmac(0.79, 0.8), BarrierSection.Style.ARMCO,
		"just below the threshold is still gravel")
	assert_eq(BarrierSection.style_for_tarmac(0.8, 0.8), BarrierSection.Style.JERSEY,
		"at the threshold it switches to tarmac")


func test_parts_expose_the_model_for_instancing() -> void:
	# parts() is what BarrierField batches from, so it must mirror the built children.
	for style in BarrierSection.Style.values():
		var s := _section(style)
		var parts := s.parts()
		assert_eq(parts.size(), _meshes(s).size(), "one part entry per mesh child")
		for part: Dictionary in parts:
			assert_true(part["mesh"] is Mesh, "part carries its mesh")
			assert_true(part["material"] is ShaderMaterial, "part carries its material")
			assert_true(part["transform"] is Transform3D, "part carries its local pose")


func test_length_drives_the_module_footprint() -> void:
	# `length` is the stitch pitch, so the model must actually follow it rather
	# than baking 2 m in.
	var s := _section(BarrierSection.Style.JERSEY)
	var two_m: float = s.local_aabb().size.z
	s.length = 4.0
	s.build()
	assert_gt(s.local_aabb().size.z, two_m + 1.5, "a longer module builds longer geometry")

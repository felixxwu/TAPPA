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


func _section(style: int, seed_i := 0) -> BarrierSection:
	var s := BarrierSection.new()
	s.style = style
	s.variant_seed = seed_i
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
		var a := _section(style, 0)
		var b := _section(style, 1)
		var a_end: float = a.local_aabb().end.z
		var b_start: float = a.length + b.local_aabb().position.z
		assert_gte(a_end, b_start,
			"%s: module ends meet across the joint" % BarrierSection.style_name(style))


func test_rebuild_replaces_rather_than_accumulates() -> void:
	var s := _section(BarrierSection.Style.HAY_BALES)
	var before := _meshes(s).size()
	s.build()
	assert_eq(_meshes(s).size(), before, "rebuilding replaces the previous model")
	# Switching style also swaps the model out wholesale.
	s.style = BarrierSection.Style.JERSEY
	s.build()
	assert_gt(_meshes(s).size(), 0, "a restyled section still has a model")


func test_same_seed_rebuilds_the_same_module() -> void:
	# The per-module jitter must be reproducible, or a cached / re-generated stage
	# would come back looking different.
	var a := _section(BarrierSection.Style.STONE_WALL, 7)
	var b := _section(BarrierSection.Style.STONE_WALL, 7)
	var ma := _meshes(a)
	var mb := _meshes(b)
	assert_eq(ma.size(), mb.size(), "same seed gives the same part count")
	for i in range(mini(ma.size(), mb.size())):
		assert_almost_eq(ma[i].position.z, mb[i].position.z, 0.0001,
			"part %d lands in the same place" % i)


func test_length_drives_the_module_footprint() -> void:
	# `length` is the stitch pitch, so the model must actually follow it rather
	# than baking 2 m in.
	var s := _section(BarrierSection.Style.JERSEY)
	var two_m: float = s.local_aabb().size.z
	s.length = 4.0
	s.build()
	assert_gt(s.local_aabb().size.z, two_m + 1.5, "a longer module builds longer geometry")

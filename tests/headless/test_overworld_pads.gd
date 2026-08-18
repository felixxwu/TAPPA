extends GutTest
# FLAT PADS: the level circle of ground baked under every rally zone and under the garage
# (features/terrain.md -> "Flat pads", features/overworld.md -> "Flat pads"). Two halves:
# OverworldPads itself (pure geometry + queries) and the TerrainManager bake that consumes it.
#
# Every test here is SCENE-FREE — a bare TerrainManager, the cheap seam test_overworld_terrain
# .gd uses. No world.tscn, no track bake, no precompute.
#
# WHY these, and why none of them pins a number: the two radii and the feather are GameConfig
# tunables, so only DIRECTION and CONSISTENCY are testable. What must hold for ANY reasonable
# values is:
#   - the ground at a pad centre is FLAT, and flat AT THE PAD'S OWN TARGET (not some other
#     level) — the whole point of the feature;
#   - the flatten FEATHERS out and the terrain far away is untouched;
#   - with no pad source the terrain is bit-identical (the opt-in guard that keeps every stage,
#     and the golden terrain digest, safe);
#   - the garage pad is LARGER than a rally pad — a relationship, never a value;
#   - pad_at is a pure function of position and survives a rebuild (it has to be, or the
#     flattened ground could not be cached to disk);
#   - the coastline taper still WINS over a pad at the map edge — a pad must not hold land up
#     out of the sea;
#   - a road ARRIVES AT THE PAD'S LEVEL, so the junction where 3-5 edges converge on a pad
#     centre has no step in it.
#
# The roster is RallyFixtures, never the shipped catalogue: the pads are placed from rally
# `map_pos`, and no test here may depend on a named rally existing.

const ManagerScript := preload("res://scripts/terrain_manager.gd")

# A small world, big enough that the centre is well inland of the taper band.
const SIZE_M := 1000.0
const HALF := SIZE_M / 2.0

# Height comparisons. The bake stores heights in a PackedFloat32Array, so "the same height"
# is float32-equal, not float64-equal.
const EPS := 0.001


# A duck-typed stand-in for OverworldRoads: the two methods _apply_road_carve reaches for.
# One dead-straight road along +X through the origin, so a test can drive a road into a pad.
# Deliberately not the real network — this is about the manager's side of the junction.
class FakeRoads extends RefCounted:
	var half_width := 4.0
	var shoulder := 4.0

	func segments_in_rect(_rect: Rect2) -> Array:
		return [{"a": Vector2(-2000.0, 0.0), "b": Vector2(2000.0, 0.0)}]

	# The road runs along z = 0, so the perpendicular foot of (x, z) is (x, 0).
	func road_at(x: float, z: float) -> Dictionary:
		var d := absf(z)
		var w := 0.0
		if d <= half_width:
			w = 1.0
		elif d < half_width + shoulder:
			var t := (d - half_width) / shoulder
			w = 1.0 - t * t * (3.0 - 2.0 * t)
		return {"road_weight": w, "tarmac_weight": 0.0, "foot": Vector2(x, 0.0)}


func before_each() -> void:
	RallyFixtures.install()


func after_each() -> void:
	RallyFixtures.restore()


# A manager in the tree with noise, bounds and the coastline taper — the overworld's shape,
# minus everything that costs time. No focus node, no initial build.
func _manager() -> TerrainManager:
	var m := Node3D.new()
	m.set_script(ManagerScript)
	m.focus_path = NodePath("")
	m.defer_initial_build = true
	m.noise_seed = 4242
	m.light_amount = 1.0
	m.load_radius = 1
	add_child_autofree(m)
	# Waterline BELOW the inland noise so "the interior is land, the perimeter is sea" is a
	# statement about the taper rather than about where the noise happens to sit.
	m.set_bounds(Rect2(-HALF, -HALF, SIZE_M, SIZE_M), 100.0, 20.0, -10.0)
	return m


# The coordinate mapping the pads are given. Centred on the origin so map_pos 0.5, 0.5 (the
# garage) lands at (0, 0) and the test can reason in world metres.
func _to_world(map_pos: Vector2) -> Vector3:
	return Vector3((map_pos.x - 0.5) * SIZE_M, 0.0, (map_pos.y - 0.5) * SIZE_M)


# A manager whose noise layers are spelled out as [wavelength_m, amplitude_m] pairs, so a test
# can choose the SITE it is testing against (dead level, or violently rough).
func _manager_with_relief(pairs: Array) -> TerrainManager:
	var m := _manager()
	var layers: Array[TerrainLayer] = []
	for p in pairs:
		var layer := TerrainLayer.new()
		layer.wavelength_m = p[0]
		layer.amplitude_m = p[1]
		layers.append(layer)
	m.layers = layers
	return m


# Pads built against `m`'s terrain, exactly as Overworld._ready does it: BUILD first (sampling
# the untouched generator), attach second.
func _pads_for(m: TerrainManager) -> OverworldPads:
	var pads := OverworldPads.new()
	pads.build(SIZE_M, Callable(self, "_to_world"), Callable(m, "_noise_height_at"))
	return pads


# The garage pad's world centre — map_pos (0.5, 0.5) under _to_world.
func _garage_xz() -> Vector2:
	return Vector2.ZERO


# --- 1. The pad is FLAT, at its own target ---------------------------------------

func test_ground_at_a_pad_centre_is_flat_at_the_pad_target() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	var c := _garage_xz()
	var target := -1.0
	for i in pads.pad_count():
		if pads.pad_centre(i).is_equal_approx(c):
			target = pads.pad_level(i)
	assert_gt(pads.pad_count(), 0, "the fixture roster places pads")

	m.set_pad_source(pads)
	# Two points either side of the centre, well inside the pad and far enough apart that
	# unflattened noise would differ between them.
	var step: float = pads.pad_radius(0) * 0.5
	var left := m.height_at(c.x - step, c.y)
	var right := m.height_at(c.x + step, c.y)
	assert_almost_eq(left, right, EPS, "the ground across a pad is level")
	assert_almost_eq(left, target, EPS, "and level AT the pad's own target height")


# The flatten really changed something — otherwise "flat" would be vacuously true on ground
# that happened to be level already.
func test_unflattened_ground_across_a_pad_is_not_already_level() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	var c := _garage_xz()
	var step: float = pads.pad_radius(0) * 0.5
	var left := m.height_at(c.x - step, c.y)
	var right := m.height_at(c.x + step, c.y)
	assert_true(absf(left - right) > EPS,
		"without pads the raw noise is NOT level here, so the flatten is doing real work")


# --- 2. The flatten feathers, and dies out --------------------------------------

func test_the_flatten_feathers_out_and_leaves_distant_terrain_alone() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	var c := _garage_xz()
	var r := 0.0
	var level := 0.0
	var feather := pads.feather_m()
	for i in pads.pad_count():
		if pads.pad_centre(i).is_equal_approx(c):
			r = pads.pad_radius(i)
			level = pads.pad_level(i)
			feather = pads.pad_feather(i)

	# Mid-feather: partially pulled toward the level, but not all the way.
	var mid := pads.pad_at(c.x + r + feather * 0.5, c.y)
	assert_gt(mid.x, 0.0, "just outside the pad the flatten still has some influence")
	assert_lt(mid.x, 1.0, "...but it is no longer FULL — this is a feather, not a cliff")
	assert_almost_eq(mid.y, level, EPS, "the feather aims at the same level as the pad")

	# Inside: full.
	assert_almost_eq(pads.pad_at(c.x, c.y).x, 1.0, EPS, "the pad centre is fully flattened")

	# Beyond the feather: nothing at all, and the generated height is the raw noise.
	var far_x := c.x + r + feather + 1.0
	assert_eq(pads.pad_at(far_x, c.y).x, 0.0, "past the feather a pad has no influence")
	var before := m.height_at(far_x, c.y)
	m.set_pad_source(pads)
	assert_eq(m.height_at(far_x, c.y), before,
		"terrain outside every pad's reach is untouched, to the bit")


# --- 2b. The feather stays DRIVABLE, whatever the site ---------------------------

# The bug this guards: on uneven ground a FIXED feather turns into a wall the car cannot climb,
# stranding the player on the lip of the pad they just drove to. Each pad now widens its own
# band until the ramp is under `max_grade()`.
#
# What is asserted is a RELATIONSHIP, not a number: the same pads, on the same terrain, with the
# widening DISABLED (max_feather == feather, so a pad can never grow) produce a steeper worst
# ramp than the adaptive ones do. No width, grade or amplitude is pinned.
func test_widening_the_feather_flattens_the_ramp_out_of_a_pad() -> void:
	# A rough site — the case that used to strand. On level ground both would tie at zero.
	var relief := [[60.0, 40.0], [18.0, 12.0]]
	var adaptive := _worst_ramp_grade(_manager_with_relief(relief), OverworldPads.new())
	var fixed := _worst_ramp_grade(_manager_with_relief(relief),
		OverworldPads.new(OverworldPads.DEFAULT_ZONE_RADIUS_M,
			OverworldPads.DEFAULT_GARAGE_RADIUS_M, OverworldPads.DEFAULT_FEATHER_M,
			OverworldPads.DEFAULT_MAX_GRADE, OverworldPads.DEFAULT_FEATHER_M))
	assert_gt(fixed, 0.0, "the rough site really does put a ramp around the pads")
	assert_lt(adaptive, fixed,
		"widening the band makes the climb out of a pad gentler than a fixed band does")


# The steepest grade anywhere in any pad's feather band, walking radially out from every pad in
# eight directions — the climb the car actually has to make to leave the pad.
func _worst_ramp_grade(m: TerrainManager, pads: OverworldPads) -> float:
	pads.build(SIZE_M, Callable(self, "_to_world"), Callable(m, "_noise_height_at"))
	m.set_pad_source(pads)
	assert_gt(pads.pad_count(), 0, "the fixture roster places pads")
	var step := 1.0
	var worst := 0.0
	for i in pads.pad_count():
		var c := pads.pad_centre(i)
		var r := pads.pad_radius(i)
		var f := pads.pad_feather(i)
		assert_true(f >= pads.feather_m(),
			"a pad's own feather is never NARROWER than the authored minimum")
		for s in 8:
			var a := TAU * float(s) / 8.0
			var dir := Vector2(cos(a), sin(a))
			var d := r
			var prev := m.height_at(c.x + dir.x * d, c.y + dir.y * d)
			while d < r + f:
				d += step
				var h := m.height_at(c.x + dir.x * d, c.y + dir.y * d)
				worst = maxf(worst, absf(h - prev) / step)
				prev = h
	return worst


# Two pads must not hand the ground a STEP where their influences meet. Taking the strongest
# pad's level outright did exactly that; the target is blended instead.
#
# WHAT IS MEASURED, AND WHY IT IS NOT THE TARGET. `pad_at` returns (weight, target), and the
# target ALONE is not a height the ground ever has — it is the level the ground is driven TOWARDS,
# weighted by the accompanying weight. Where no pad reaches, the pair is (0, 0), and that 0 is
# "not applicable", not sea level. Two earlier versions of this test both got this wrong: the
# first folded the not-applicable 0 straight into the walk, and the second skipped those samples
# but left the continuity chain spanning the gap — so the first sample past the gap was compared
# against the last sample before it, reporting a jump of the FULL level difference across ground
# where the pads do nothing at all. That is a measurement artefact, and it fired for real once the
# neighbour cap made touching-but-not-overlapping bands the normal geometry.
#
# So this measures the LIFT: `weight * (target - raw height)`, the metres the flatten actually
# adds to the ground at that point. It is defined everywhere (0 outside every band, approached
# continuously), so there is no domain gap to skip and no chain to break — and it is the quantity
# the player feels. A probe of the touching-bands geometry confirms the distinction: across the
# handover the target swings the whole level difference while the lift moves under 4% of it.
func test_the_flatten_does_not_step_where_two_pads_meet() -> void:
	var m := _manager_with_relief([[60.0, 40.0], [18.0, 12.0]])
	# NOT attached to the manager: `_noise_height_at` must stay the RAW ground here, or the lift
	# would be measured against a height that already has the flatten in it.
	var pads := _pads_for(m)
	var a := pads.pad_centre(0)
	var b := Vector2.ZERO
	var nearest := INF
	# The pad NEAREST pad 0 is the one whose band meets it.
	for i in range(1, pads.pad_count()):
		var d := a.distance_to(pads.pad_centre(i))
		if d < nearest:
			nearest = d
			b = pads.pad_centre(i)
	assert_lt(nearest, INF, "the fixture roster places more than one pad")

	var step := 0.5
	var steps := int(a.distance_to(b) / step)
	var worst := 0.0
	var span := 0.0
	var prev := 0.0
	var have_prev := false
	for s in steps + 1:
		var p := a.lerp(b, float(s) / float(steps))
		var hit := pads.pad_at(p.x, p.y)
		var raw: float = m._noise_height_at(p.x, p.y)
		var lift: float = hit.x * (hit.y - raw)
		if have_prev:
			worst = maxf(worst, absf(lift - prev))
		span = maxf(span, absf(lift))
		prev = lift
		have_prev = true
	assert_gt(span, 0.0, "the walk crossed ground the pads actually move")
	# The lift travels the whole way from one pad's plane to the other's — it just may not do it
	# in one stride. A share of the total travel, never an absolute height.
	assert_lt(worst, span * 0.25,
		"the flatten the pads apply varies smoothly between them, with no step "
		+ "(worst single-sample move %.3f m, largest lift %.3f m)" % [worst, span])


# The widening must be a function of the SITE, not a constant: rough ground gets a wider band
# than flat ground. (No width is pinned — only the ordering.)
func test_rougher_ground_widens_the_feather() -> void:
	var flat_pads := _pads_for(_manager_with_relief([[60.0, 0.0]]))
	var rough_pads := _pads_for(_manager_with_relief([[60.0, 40.0], [18.0, 12.0]]))

	assert_almost_eq(flat_pads.pad_feather(0), flat_pads.feather_m(), EPS,
		"level ground needs no widening — the authored feather is enough")
	assert_gt(rough_pads.pad_feather(0), flat_pads.pad_feather(0),
		"a pad on rough ground widens its band; one on flat ground does not")
	assert_gt(rough_pads.influence_m(), rough_pads.pad_radius(0) + rough_pads.feather_m(),
		"influence_m reports the WIDENED reach, so callers inflate their rects far enough")


# --- 3. The opt-in guard: no source, no change ----------------------------------

# This is the guard that protects every STAGE (which never has a pad source) and the golden
# terrain digest. Bit-identical, not approximately identical.
func test_without_a_pad_source_the_terrain_is_bit_identical() -> void:
	var m := _manager()
	assert_null(m.pad_source, "a fresh manager has no pads — pads are opt-in")
	var before: PackedFloat32Array = m.compute_chunk_data(Vector2i(0, 0))["heights"]
	# Attaching and clearing must leave no residue.
	var pads := _pads_for(m)
	m.set_pad_source(pads)
	m.set_pad_source(null)
	var after: PackedFloat32Array = m.compute_chunk_data(Vector2i(0, 0))["heights"]
	assert_eq(before, after, "no pad source: the generated chunk is byte-for-byte unchanged")


func test_the_bake_actually_moves_the_chunk_the_pad_sits_in() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	var coord := m.chunk_coord_for(Vector3(_garage_xz().x, 0.0, _garage_xz().y))
	var before: PackedFloat32Array = m.compute_chunk_data(coord)["heights"]
	m.set_pad_source(pads)
	var after: PackedFloat32Array = m.compute_chunk_data(coord)["heights"]
	assert_ne(before, after, "the chunk holding a pad is flattened by the bake")
	assert_eq(before.size(), after.size(), "...and only its heights change, not its shape")


# --- 4. The garage pad is the bigger one ----------------------------------------

# A RELATIONSHIP, never a value: the garage is a building with a real footprint plus an
# approach, a rally zone is a marker and a tube. Retuning either radius must not break this.
func test_the_garage_pad_is_larger_than_a_rally_pad() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	var garage_r := 0.0
	var rally_r := 0.0
	for i in pads.pad_count():
		if pads.pad_centre(i).is_equal_approx(_garage_xz()):
			garage_r = pads.pad_radius(i)
		else:
			rally_r = pads.pad_radius(i)
	assert_gt(rally_r, 0.0, "the fixture rallies got pads of their own")
	assert_gt(garage_r, rally_r, "the garage needs the larger pad — it is a building")
	assert_eq(pads.pad_count(), RallyLibrary.all().size() + 1,
		"one pad per rally, plus one for the garage")


# --- 5. Purity ------------------------------------------------------------------

# The flattened ground is written to the on-disk chunk cache, so the query behind it MUST be
# a pure function of position — a pad that answered differently on the second launch would
# hand the player ground that no longer matches the building standing on it.
func test_pad_at_is_pure_and_survives_a_rebuild() -> void:
	var m := _manager()
	var a := _pads_for(m)
	var b := _pads_for(m)
	assert_eq(a.stamp(), b.stamp(), "two builds of the same inputs stamp identically")
	for p in [Vector2(0.0, 0.0), Vector2(7.0, -3.0), Vector2(120.0, 240.0),
			Vector2(-410.0, 88.0)]:
		var first := a.pad_at(p.x, p.y)
		assert_eq(first, a.pad_at(p.x, p.y), "repeated queries agree at %s" % p)
		assert_eq(first, b.pad_at(p.x, p.y), "a rebuilt pad set agrees at %s" % p)


# The stamp is what the chunk cache keys off, so it must MOVE when the ground would.
func test_the_stamp_changes_when_the_pads_change() -> void:
	var m := _manager()
	var base := _pads_for(m)
	var wider := OverworldPads.new(base.pad_radius(0) * 2.0 + 5.0,
		OverworldPads.DEFAULT_GARAGE_RADIUS_M, base.feather_m())
	wider.build(SIZE_M, Callable(self, "_to_world"), Callable(m, "_noise_height_at"))
	assert_ne(base.stamp(), wider.stamp(),
		"retuning a radius must invalidate the cached heights, not reuse them")


# The per-chunk reject: a chunk nowhere near a pad must cost one query and nothing more.
func test_pads_in_rect_rejects_a_chunk_with_no_pad_in_it() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	var far := Rect2(HALF - 60.0, HALF - 60.0, 50.0, 50.0)
	assert_true(pads.pads_in_rect(far).is_empty(), "a far corner holds no pad")
	var here := Rect2(-25.0, -25.0, 50.0, 50.0)
	assert_false(pads.pads_in_rect(here).is_empty(), "the garage's own chunk does hold one")


# --- 6. The coastline still wins ------------------------------------------------

# A pad must never hold land up out of the sea. The taper runs AFTER the pad and re-derives
# the shoreline from scratch, so this holds whatever the pad's level happens to be.
func test_the_coastline_taper_wins_over_a_pad_at_the_map_edge() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	m.set_pad_source(pads)
	# The perimeter is inside the taper band whether or not a pad sits there.
	var edge_x := -HALF + 1.0
	var h := m.height_at(edge_x, 0.0)
	assert_lt(h, m.water_level_m,
		"the map perimeter is below the waterline — the taper wins over anything above it")
	# And the pad-flattened land is still land.
	assert_gt(m.height_at(0.0, 0.0), m.water_level_m, "the inland pad is not drowned")


# The same statement made directly against the two functions, so it cannot be satisfied by
# accident of where the fixture pins happen to sit: whatever height the pad hands over, the
# taper drags it under at the perimeter.
func test_taper_drags_any_pad_level_under_at_the_perimeter() -> void:
	var m := _manager()
	var edge_x := -HALF + 1.0
	assert_lt(m.taper_height(50.0, edge_x, 0.0), m.water_level_m,
		"even ground held at 50 m is pulled below the waterline at the map edge")


# --- 7. The junction: a road arrives at the pad's level -------------------------

# Every pad centre IS a road node, so 3-5 edges converge there. The carve's roadbed target is
# run through pad_height at the foot, which makes the road arrive level instead of leaving a
# step in a ring around the pad. Asserted through pad_height itself (the shared function both
# passes call) rather than by eyeballing the baked grid.
func test_the_roadbed_target_is_pulled_onto_the_pad_inside_it() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	m.set_pad_source(pads)
	var c := _garage_xz()
	var level := 0.0
	for i in pads.pad_count():
		if pads.pad_centre(i).is_equal_approx(c):
			level = pads.pad_level(i)
	# A roadbed height sampled well off the pad's plane, at a point INSIDE the pad: the pad
	# owns it outright, so the road cannot re-tilt the yard.
	assert_almost_eq(m.pad_height(level + 25.0, c.x, c.y), level, EPS,
		"inside a pad the roadbed target IS the pad level")
	# Outside every pad's reach the roadbed is left exactly alone.
	var far_x: float = c.x + pads.influence_m() + 10.0
	assert_eq(m.pad_height(12.5, far_x, c.y), 12.5,
		"away from a pad the roadbed target is untouched")


# End to end: with a road running through the pad, the baked ground across the pad is still
# level — the road does not cut a trench through the forecourt, and there is no step where it
# meets the pad.
func test_a_road_running_into_a_pad_leaves_the_pad_level() -> void:
	var m := _manager()
	var pads := _pads_for(m)
	m.set_road_source(FakeRoads.new())
	m.set_pad_source(pads)
	var c := _garage_xz()
	var level := 0.0
	var r := 0.0
	for i in pads.pad_count():
		if pads.pad_centre(i).is_equal_approx(c):
			level = pads.pad_level(i)
			r = pads.pad_radius(i)

	var coord := m.chunk_coord_for(Vector3(c.x, 0.0, c.y))
	var data := m.compute_chunk_data(coord)
	var heights: PackedFloat32Array = data["heights"]
	var verts: PackedVector3Array = data["vertices"]
	var centre: Vector3 = data["center"]
	# One assertion over the worst vertex rather than a few hundred: the loop is a measurement,
	# not a test case each.
	var checked := 0
	var worst := 0.0
	for i in heights.size():
		var wx: float = centre.x + verts[i].x
		var wz: float = centre.z + verts[i].z
		if Vector2(wx, wz).distance_to(c) > r * 0.6:
			continue
		checked += 1
		worst = maxf(worst, absf(heights[i] - level))
	assert_gt(checked, 0, "the pad really does cover vertices in this chunk")
	# The quantum is off on this manager, so the only thing between the pad and the stored
	# height is the carve — which must not move it.
	assert_lt(worst, EPS, "a road through the pad left the forecourt level")


# THE OVERLAP INVARIANT, and the two tests this replaced.
#
# History, because it explains what is asserted here. The blended pad TARGET (what height to
# flatten towards, as opposed to `best_w`, how much to flatten) used to be weighted by pow(w, 8).
# At the locus equidistant from two pads w1 ~= w2, and a ratio of (w1/w2)^8 swings the target
# almost entirely from one pad's level to the other over a fractional change in position — a hard
# step in the ground halfway between two rallies, scaled by their height difference. Because the
# pad pass runs AFTER the road carve and overwrites it, the symptom was a road that jumped
# mid-span, which pointed at the wrong subsystem.
#
# Two tests were written for that (bounding the worst single-sample jump at 10% and at 25% of the
# level difference). BOTH WERE VACUOUS, in two independent ways, and measurement rather than
# reasoning is what showed it — a throwaway probe comparing the weightings directly, worst
# single-sample jump as a share of the level difference, 400 samples:
#
#   centres apart   feather   old pow(w, 8)   new w/(1-w)
#     80 m          150 m        0.5%            0.7%
#    140 m          150 m        2.0%            0.7%
#    220 m          150 m        7.1%            1.2%
#
# First: at 10% the OLD code passes every row, so the bound never failed against the bug it was
# written for. Second, and more fundamental: pads whose centres are close relative to their bands
# (the first row — and the only regime the fixture roster actually produces) cannot tell the two
# weightings apart at all, because both interiors effectively merge.
#
# And the premise itself is now gone. `_neighbour_cap` limits every band to half the clear gap to
# its nearest neighbour precisely so bands DO NOT deeply overlap, so `build()` can no longer
# produce the geometry those tests sampled. Asserting smoothness across an overlap the code
# prevents would assert nothing.
#
# So this asserts the invariant that replaced it, which is the real guarantee: no two pads' bands
# overlap unless the authored feather floor forced it. That is what keeps the ground between two
# pads the terrain's own — smooth by construction — rather than a blend that has to pay the whole
# level difference somewhere. Pins no tunable: it is a relationship between whatever radii,
# feathers and positions the roster and the config hand it.
func test_pad_bands_do_not_overlap_unless_the_feather_floor_forced_it() -> void:
	var m := _manager_with_relief([[220.0, 45.0]])
	# THE AUTHORED FEATHER MUST BE SMALL, and this is the subtle part. `_neighbour_cap` returns
	# `max(half the clear gap, the authored feather)` — the authored width is a FLOOR the cap can
	# never go under. An earlier version of this test authored 150 m to "guarantee overlap", which
	# made 150 m the floor: every band resolved to exactly 150, every pair overlapped, every pair
	# was classified floor-forced, and all the assertions below passed through the exception branch
	# without ever testing the cap. It was vacuous in precisely the way the comment above describes.
	#
	# With a small floor and rough ground the widening asks for far more than the gaps allow, so
	# the cap is what decides nearly every width — which is the thing under test.
	var pads := OverworldPads.new(OverworldPads.DEFAULT_ZONE_RADIUS_M,
		OverworldPads.DEFAULT_GARAGE_RADIUS_M, OverworldPads.DEFAULT_FEATHER_M,
		OverworldPads.DEFAULT_MAX_GRADE, 300.0)
	pads.build(SIZE_M, Callable(self, "_to_world"), Callable(m, "_noise_height_at"))
	assert_gt(pads.pad_count(), 1, "the fixture roster gives at least two pads")

	var checked := 0
	var tightest := INF
	var widest := 0.0
	for i in pads.pad_count():
		widest = maxf(widest, pads.pad_feather(i))
		for j in range(i + 1, pads.pad_count()):
			checked += 1
			var apart: float = pads.pad_centre(i).distance_to(pads.pad_centre(j))
			var reach: float = (pads.pad_radius(i) + pads.pad_feather(i)
				+ pads.pad_radius(j) + pads.pad_feather(j))
			# How much clear ground is left between the two bands. Zero means they meet exactly,
			# which is what the cap produces for a mutually-nearest pair; negative means overlap.
			tightest = minf(tightest, apart - reach)
			if reach <= apart:
				continue
			# The one licensed exception: pads too close for the authored floor to fit between
			# them. Neither band may be narrower than that floor, so the overlap is unavoidable.
			var clear: float = apart - pads.pad_radius(i) - pads.pad_radius(j)
			assert_lt(clear, 2.0 * pads.feather_m(),
				"pads %d and %d overlap with room to spare between them" % [i, j])
			assert_almost_eq(pads.pad_feather(i), pads.feather_m(), EPS,
				"a pad forced to overlap sits at the authored feather floor, not wider")
	assert_gt(checked, 0, "there are pairs to check at all")

	# NON-VACUITY, two halves — without these the loop above passes on any roster whose pads are
	# simply far apart, which would test nothing.
	#
	# The widening is live: some pad claimed more than the authored floor.
	assert_gt(widest, pads.feather_m(),
		"the grade-driven widening did widen something, so there was width to cap")
	# ...and the cap is what stopped it: a mutually-nearest pair meets EXACTLY, each having taken
	# half the clear gap between them. That equality is the cap's signature — a pair whose widths
	# the widening alone had settled would leave slack here.
	assert_almost_eq(tightest, 0.0, 0.05,
		"some pair's bands meet exactly, i.e. the neighbour cap set their widths")

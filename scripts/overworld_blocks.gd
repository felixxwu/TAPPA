class_name OverworldBlocks
extends Node3D
# ROADBLOCKS: the in-world counterpart of the map's road gate (features/overworld.md).
#
# The map and minimap refuse to draw a road whose far end is still dark
# (`overworld_map.gd::_paint_roads`). The terrain still CARVES and DRAWS that road — you can
# see the tarmac from the driver's seat — so without this the world and the map disagree: the
# map says "no road here", the windscreen says "there is one, drive it".
#
# So every blocked road gets a short run of PRECAST CONCRETE JERSEY RAIL laid ACROSS the
# carriageway, facing the approaching driver, standing at the point where the road leaves the
# revealed frontier. Read from the road it is unmistakable: the way ahead is closed off, not
# merely dark.
#
# DIEGETIC SIGNAGE, NOT A SEAL. The run spans the carriageway and nothing more. The player can
# drive around it on the verge, and that is accepted — containment is the fog frontier's soft
# turn-back (`Overworld._update_fog_boundary`), which already pushes a car that strays past the
# lit region back to the last lit pose. This file deliberately adds NO second push, no invisible
# wall past the modules' own footprint, and no teleport: it says "closed", the frontier enforces
# it. Placing the run AT the frontier crossing is what makes the two read as one mechanism —
# the barrier is where the push begins.
#
# BLOCKED-NESS COMES FROM THE ONE PREDICATE. An endpoint is blocked when
# `RallyLibrary.position_lit_by` says its pin is dark — i.e. exactly
# `RallyLibrary.rally_revealed`, the predicate that gates the HQ's pins, rally entry, the
# overworld markers and the map's own road gate. There is no lookalike distance test here, and
# this file does NOT ask `overworld_map.gd` (the map is a view; the world must not depend on it).
#
# COST. Everything is built once, off the road network, during the world build — there is no
# `_process`, nothing per frame, and nothing hooked into terrain streaming, so a chunk crossing
# cannot spike on this. A whole run is one MultiMesh per barrier part plus one StaticBody
# (BarrierField.build_modules), culled at the shared world-prop render distance.

# Both-ends-dark edges are SKIPPED: a road between two dark pins cannot be reached from lit
# ground in the first place, so a barrier there would be built for nobody to see.
#
# How far back from the frontier crossing the run stands, metres. Positive, so the barrier is
# inside the lit region — a roadblock the player cannot see until he is already in the fog is
# not signage. Not a GameConfig tunable: it is the readable-distance relationship between the
# barrier and the frontier, not a look dial.
const FRONTIER_SETBACK_M := 10.0
# How far past the carriageway edge the run reaches on each side, metres. Enough that the run
# visibly overhangs the tarmac (so it reads as blocking the ROAD rather than sitting on it)
# without pretending to fence the countryside.
const SPAN_MARGIN_M := 1.5
# Bearing sampled this far along the polyline, so a single sampling wobble cannot skew which
# way the run faces. Same reasoning as OverworldRoads.approach_dirs' `min_step_m`.
const BEARING_STEP_M := 12.0

var _roads: OverworldRoads = null
var _ground_at := Callable()
var _params: Dictionary = {}
var _visuals := true
# edge index -> the BarrierField holding that road's run. The keys ARE the blocked set, so
# `refresh` is a diff rather than a rebuild.
var _runs: Dictionary = {}


# `opts`:
#   roads      OverworldRoads (built)                REQUIRED — the network the blocks sit on.
#   ground_at  Callable(Vector3) -> float            optional; without it runs sit at y = 0.
#   params     GameConfig.barrier_render_params()    optional; defaults to the live config.
#   profile    Dictionary                            defaults to Save.profile.
#   visuals    bool                                  false = plan only, build no nodes.
func setup(opts: Dictionary) -> void:
	_roads = opts.get("roads", null) as OverworldRoads
	_ground_at = opts.get("ground_at", Callable())
	_params = opts.get("params", Config.data.barrier_render_params())
	_visuals = bool(opts.get("visuals", true))
	if _roads == null or not _roads.is_built():
		push_error("OverworldBlocks.setup: a built OverworldRoads is required.")
		return
	# A rally completing lights new pins, and the roads they close must open in the same
	# session — the player watches a barrier vanish rather than finding it gone after a reload.
	if Save.has_signal("profile_changed") and not Save.profile_changed.is_connected(_on_profile_changed):
		Save.profile_changed.connect(_on_profile_changed)
	refresh(opts.get("profile", Save.profile))


# Re-evaluate every road against the fog and bring the built runs into line: free the runs
# whose road just opened, build the ones newly closed, leave the rest untouched. Cheap enough
# to call on any progress change — the scan is one lit test per graph node.
func refresh(profile: Dictionary = Save.profile) -> void:
	if _roads == null or not _roads.is_built():
		return
	var wanted := blocked_edges(profile)
	for edge in _runs.keys():
		if not wanted.has(edge):
			var run: Node = _runs[edge]
			_runs.erase(edge)
			if is_instance_valid(run):
				run.queue_free()
	for edge: int in wanted:
		if not _runs.has(edge):
			_build_run(int(edge), wanted[edge] as Dictionary)


# --- Queries (for the world, and for tests) ---------------------------------------------


# The roads that should be blocked right now: edge index -> the placement
# `{ "pos": Vector2 (world XZ), "tangent": Vector2 (unit, pointing INTO the dark) }`.
#
# An edge qualifies when exactly ONE endpoint is dark: that end is unreachable, and the lit
# end is where the player will arrive from. Both ends dark means the road cannot be reached at
# all, so it gets nothing; both lit means it is open. The garage node is never dark (it carries
# no pin, so the roster predicate would answer false for it forever — the same exemption
# `OverworldZone.always_revealed` exists for).
func blocked_edges(profile: Dictionary = Save.profile) -> Dictionary:
	var out: Dictionary = {}
	if _roads == null or not _roads.is_built():
		return out
	var nodes := _roads.nodes()
	# ONE lit-source build for the whole scan, then one containment test per node — the batching
	# seam RallyLibrary.position_lit_by exists for.
	var sources := RallyLibrary.lit_sources(profile)
	var lit := PackedByteArray()
	lit.resize(nodes.size())
	for i in nodes.size():
		var is_hq := bool(nodes[i].get("is_hq", false))
		lit[i] = 1 if is_hq or RallyLibrary.position_lit_by(nodes[i]["map_pos"], sources) else 0
	var edges := _roads.edges()
	for i in edges.size():
		var a := int(edges[i]["a"])
		var b := int(edges[i]["b"])
		var lit_a := lit[a] == 1
		var lit_b := lit[b] == 1
		if lit_a == lit_b:
			continue
		var plan := _placement(edges[i]["points"] as PackedVector2Array, lit_a, sources)
		if not plan.is_empty():
			out[i] = plan
	return out


# How many roads are currently blocked (== how many runs exist).
func run_count() -> int:
	return _runs.size()


# The BarrierField built for edge `index`, or null. The headless seam: a test asserts the run
# exists, spans the road and disappears when the rally lights, without a renderer.
func run_for(index: int) -> Node:
	return _runs.get(index, null) as Node


# --- Placement -------------------------------------------------------------------------


# Where along the edge polyline the run stands, walking from the LIT end toward the dark one:
# the first sample whose map position is no longer lit is the frontier crossing, and the run
# stands FRONTIER_SETBACK_M back from it — on lit ground, where the driver can see it.
#
# Falls back to the crossing itself when the polyline is too short to step back, and gives up
# (empty) only when the walk finds no crossing at all, which means the endpoints disagreed with
# the samples between them; better to draw nothing than to plant a barrier on open road.
func _placement(points: PackedVector2Array, from_a: bool, sources: Array) -> Dictionary:
	if points.size() < 2:
		return {}
	var size := _roads.size_m()
	var last := points.size() - 1
	var cross := -1
	for k in points.size():
		var p: Vector2 = points[k] if from_a else points[last - k]
		if not RallyLibrary.position_lit_by(Overworld.map_pos_of(Vector3(p.x, 0.0, p.y), size), sources):
			cross = k
			break
	if cross <= 0:
		return {}
	# Step back along the walk direction until the setback is used up. Measured on the polyline
	# rather than as a straight line, so a curved road steps back the distance it is driven.
	var idx := cross
	var walked := 0.0
	while idx > 0 and walked < FRONTIER_SETBACK_M:
		var cur: Vector2 = points[idx] if from_a else points[last - idx]
		var prev: Vector2 = points[idx - 1] if from_a else points[last - idx + 1]
		walked += cur.distance_to(prev)
		idx -= 1
	var pos: Vector2 = points[idx] if from_a else points[last - idx]
	return {"pos": pos, "tangent": _bearing(points, idx, from_a)}


# The unit direction the road heads in AT sample `idx`, pointing into the dark — the axis the
# run is laid across. Sampled BEARING_STEP_M ahead where the polyline allows.
func _bearing(points: PackedVector2Array, idx: int, from_a: bool) -> Vector2:
	var last := points.size() - 1
	var origin: Vector2 = points[idx] if from_a else points[last - idx]
	var dir := Vector2.ZERO
	for k in range(idx + 1, points.size()):
		var p: Vector2 = points[k] if from_a else points[last - k]
		var d := p - origin
		var l := d.length()
		if l <= 0.0:
			continue
		dir = d / l
		if l >= BEARING_STEP_M:
			break
	if dir == Vector2.ZERO:
		# Degenerate tail: fall back to the direction we arrived from, reversed.
		var back: Vector2 = points[maxi(idx - 1, 0)] if from_a else points[last - maxi(idx - 1, 0)]
		dir = (origin - back).normalized()
	return dir if dir != Vector2.ZERO else Vector2(0.0, 1.0)


# --- Build -----------------------------------------------------------------------------


# One road's run: enough CONCRETE modules laid side by side to span the carriageway (plus
# SPAN_MARGIN_M of overhang), each turned so its length axis crosses the road and its
# driver-facing +X looks back down the road at the player.
#
# JERSEY, not ARMCO, whatever the road surface is. A stage barrier picks its style from the
# tarmac weight because it is roadside furniture that belongs to the road; a roadblock is
# TEMPORARY WORKS dropped across it, and precast concrete blocks are what that looks like
# everywhere in the world.
func _build_run(index: int, plan: Dictionary) -> void:
	if not _visuals:
		# Still record the road as blocked so the plan is inspectable headless; nothing is built.
		_runs[index] = null
		return
	var style := int(BarrierSection.Style.JERSEY)
	var field := BarrierField.new()
	field.name = "Roadblock%d" % index
	add_child(field)
	var box := field.module_aabb(style, _params)
	var pitch: float = maxf(float(_params.get("section_length_m", 2.0)), 0.1)
	var sink: float = float(_params.get("sink_m", 0.0))
	var pos: Vector2 = plan["pos"]
	var tangent: Vector2 = plan["tangent"]
	# THE LOCAL FRAME, and it is easy to get wrong — see the sunk-barrier bug in
	# features/barriers.md. BarrierSection's contract is "+X the face the driver sees, +Y UP with
	# the model standing on y = 0, +Z the run direction", and the module's geometry lives entirely
	# in +Y (its AABB starts at y = 0), so a basis whose Y column comes out DOWN buries the whole
	# block under the road rather than standing it on top.
	#
	# So: pin the two axes that carry meaning and DERIVE the third, never pick two independently.
	# +X faces back down the road at the approaching driver (the tangent points into the dark), +Y
	# is world up, and the run direction is then x × y — which is the road's perpendicular, but the
	# one that makes the basis right-handed with Y up rather than the other one.
	#
	# (The roadside path, BarrierField._module_transform, derives ITS third axis the same way from
	# a different pair, which is why that one has always stood up.)
	var x_axis := Vector3(-tangent.x, 0.0, -tangent.y).normalized()
	var z_axis := x_axis.cross(Vector3.UP)
	var basis := Basis(x_axis, Vector3.UP, z_axis)
	# The run axis in map space, so module spacing and the transform agree by construction.
	var run := Vector2(z_axis.x, z_axis.z)
	var half_span := _roads.width_m() * 0.5 + SPAN_MARGIN_M
	var count: int = maxi(2, int(ceil(half_span * 2.0 / pitch)))
	# Mass extends toward -X (behind the visible face), so nudge the run so the FACE, not the
	# model's centre, sits on the chosen point.
	var face_offset := -x_axis * box.get_center().x
	# ONE HEIGHT FOR THE WHOLE RUN, SAMPLED ON THE CENTRELINE — not one per module.
	#
	# The carve levels the carriageway ACROSS its width: for every vertex with road weight 1 the
	# terrain height is the ground height at the perpendicular FOOT on the centreline
	# (`TerrainManager._apply_road_carve`). So the road surface under this whole run IS the
	# centreline height, and sampling each module at its own offset position asks for the height of
	# ground the carve replaced — the natural cross-slope — which would sink the downhill half of
	# the run and float the uphill half.
	#
	# Sampling the centreline also makes the answer independent of whether the chunks under the
	# barrier happen to be RESIDENT: `TerrainManager.height_at` falls back to the scalar noise path
	# for a chunk that is not built yet, and that path applies the pad and the coastline taper but
	# NOT the road carve — and these barriers stand on roads, far from the car, at world-build
	# time, so they are the one prop in the game guaranteed to hit that fallback. On the centreline
	# the two pipelines agree by construction (the carve's own roadbed target is the ground height
	# at that same point), so this reads the same number either way.
	var y := _ground(pos) - sink
	var xforms: Array[Transform3D] = []
	for i in count:
		var offset := (float(i) - float(count - 1) * 0.5) * pitch
		var xz := pos + run * offset
		xforms.append(Transform3D(basis, Vector3(xz.x, y, xz.y) + face_offset))
	# Solid — bumping a concrete block should feel like concrete, and that reinforces the
	# signal. Collision is the modules' own boxes and nothing more (BarrierField), so driving
	# around the ends still works, by design. The body joins DamageModel.OBSTACLE_GROUP like
	# every other ObstacleBody, for consistency; damage is switched off in the hub
	# (`Overworld._field_car`), so it costs the player nothing here.
	field.build_modules(style, xforms, _params)
	_runs[index] = field


func _ground(p: Vector2) -> float:
	if not _ground_at.is_valid():
		return 0.0
	var y: float = _ground_at.call(Vector3(p.x, 0.0, p.y))
	return y if is_finite(y) else 0.0


func _on_profile_changed() -> void:
	refresh(Save.profile)

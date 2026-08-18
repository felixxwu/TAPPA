class_name OverworldFogWall
extends Node3D
# THE FRONTIER WALL — a translucent curtain standing on the edge of what the player has revealed,
# so the boundary is something you can SEE coming rather than something you discover by being
# shoved back from it.
#
# WHICH BORDER. The hub keeps two apart (see overworld.gd's header) and this is the FOG FRONTIER —
# the growing union of reveal circles — NOT the coastline. Verified rather than assumed: the only
# code that darkens the screen or moves the car is `Overworld._update_fog_boundary`
# (`FOG_VEIL_ALPHA`, `FOG_PUSH_ACCEL`, `FOG_HARD_MARGIN_M`), and it is keyed on
# `position_revealed(car_map_pos())`. Nothing anywhere pushes, clamps or collides at the map
# bounds; the coastline just tapers into sea. So "the edge, crossing it darkens the screen and
# pushes you back" is unambiguously the frontier.
#
# STILL NOT A COLLIDER. D4's ruling stands: the push stays the mechanism and this is only its
# WARNING. Nothing here has a collision shape, nothing here applies a force, and
# `_update_fog_boundary` remains the only thing that moves the car.
#
# THE LOOK IS THE LIGHT TUBE'S, deliberately (the user asked for "similar to the light tubes"): a
# vertical translucent band, solid at the base and fading out with height, with the fade baked into
# VERTEX COLOURS on the same curve — `OverworldZone.TUBE_FADE_POW` and `TUBE_RINGS` are read from
# there rather than re-authored, so the two can never drift into two different visual languages.

# Perimeter resolution: one segment per this many metres of arc, so a big reveal circle is not
# coarser than a small one. A SHAPE constant (how round the curve looks), not balance.
const ARC_STEP_M := 12.0
# ...clamped, so a huge circle cannot explode the vertex count and a tiny one still reads as round.
const MIN_ARC_SEGMENTS := 12
const MAX_ARC_SEGMENTS := 96
# How far BELOW the sampled ground the curtain starts. The frontier is far from the car, so the
# ground sample there comes from `TerrainManager.height_at`'s scalar fallback, which applies the pad
# and the coastline taper but NOT the road carve (see features/overworld.md → "Roadblocks" for the
# same hazard). For a 15 m curtain a few tens of centimetres of disagreement is invisible — but only
# if it errs DOWNWARD, or the base lifts off the terrain and you can see under the wall.
const BASE_SINK_M := 1.5
# A point on one circle counts as inside another when it is this much further in than its rim.
# Without the slack, two circles that touch produce a hairline of kept points along the seam.
const OVERLAP_EPSILON_M := 0.5

var _size_m := 0.0
var _ground_at := Callable()
var _visuals := true
# One MeshInstance3D PER ARC of the frontier — see `_build_curtains` for why this is not one mesh.
var _curtains: Array[MeshInstance3D] = []
var _material: StandardMaterial3D = null
# The contour the current mesh was built from, in world XZ. Kept for the test seam and for the
# "did anything actually change" comparison in `refresh`.
var _contour: Array = []


# `opts`:
#   size_m     float                      REQUIRED — the map edge length, for map -> world.
#   ground_at  Callable(Vector3) -> float  optional; without it the curtain stands at y = 0.
#   visuals    bool                        false = no mesh at all (headless).
#   profile    Dictionary                  defaults to Save.profile.
func setup(opts: Dictionary) -> void:
	_size_m = float(opts.get("size_m", 0.0))
	_ground_at = opts.get("ground_at", Callable())
	_visuals = bool(opts.get("visuals", true))
	if _size_m <= 0.0:
		push_error("OverworldFogWall.setup: a positive `size_m` is required.")
		return
	# GROWS WITH PROGRESSION on the same signal the zones and the roadblocks refresh on, so a rally
	# completing pushes the wall outward in the same session with no scene reload.
	if Save.has_signal("profile_changed") and not Save.profile_changed.is_connected(_on_profile_changed):
		Save.profile_changed.connect(_on_profile_changed)
	refresh(opts.get("profile", Save.profile))


## Rebuild the curtain for `profile`. Cheap enough for any progress change: the contour is traced
## from `RallyLibrary.lit_sources` — the SAME circles the fog mask is rasterised from and the same
## ones `position_revealed` tests, so the wall cannot stand anywhere but on the real frontier — and
## nothing here runs per frame.
func refresh(profile: Dictionary = Save.profile) -> void:
	if _size_m <= 0.0:
		return
	_contour = contour(RallyLibrary.lit_sources(profile), _size_m)
	if not _visuals or not bool(Config.data.overworld_fog_wall_enabled):
		_clear_mesh()
		return
	_build_curtains()


## The frontier outline as polylines in WORLD XZ — the union of the lit circles' rims with the arcs
## that fall INSIDE another circle dropped, which is exactly the scalloped boundary the map draws.
##
## STATIC and pure (circles in, polylines out), so the geometry is testable with no scene, no
## terrain and no renderer — which is how the "it stands on the frontier" property is asserted
## without sampling a single pixel.
static func contour(sources: Array, size_m: float, arc_step_m := ARC_STEP_M) -> Array:
	var out: Array = []
	if size_m <= 0.0:
		return out
	for i in sources.size():
		var centre: Vector2 = sources[i][0]
		var radius: float = float(sources[i][1])
		if radius <= 0.0:
			continue
		var radius_m := radius * size_m
		var steps: int = clampi(int(ceil(TAU * radius_m / maxf(arc_step_m, 0.5))),
			MIN_ARC_SEGMENTS, MAX_ARC_SEGMENTS)
		# Walk the rim, keeping the runs of points that are on the OUTSIDE of every other circle.
		# A run that breaks starts a new polyline, which is what makes a scalloped union come out as
		# several arcs rather than one wrong loop. `steps + 1` closes a circle nobody else touches.
		var run := PackedVector2Array()
		for k in steps + 1:
			var ang := TAU * float(k % steps) / float(steps)
			var p := centre + Vector2(cos(ang), sin(ang)) * radius
			if _covered(p, sources, i, size_m):
				if run.size() >= 2:
					out.append(run)
				run = PackedVector2Array()
				continue
			var w := Overworld.world_xz(p, size_m)
			run.append(Vector2(w.x, w.z))
		if run.size() >= 2:
			out.append(run)
	return out


# Is this rim point inside some OTHER lit circle — i.e. interior to the union rather than on its
# boundary? Compared in metres so the epsilon means the same thing at any map size.
static func _covered(p: Vector2, sources: Array, skip: int, size_m: float) -> bool:
	for j in sources.size():
		if j == skip:
			continue
		var other: Vector2 = sources[j][0]
		var r: float = float(sources[j][1]) * size_m - OVERLAP_EPSILON_M
		if r <= 0.0:
			continue
		if p.distance_to(other) * size_m < r:
			return true
	return false


## Total contour length in metres — the growth seam. A revealed rally can only ever ADD frontier,
## so a test asserts this rises rather than asserting any particular number.
func contour_length_m() -> float:
	var total := 0.0
	for line: PackedVector2Array in _contour:
		for i in range(1, line.size()):
			total += line[i].distance_to(line[i - 1])
	return total


## The polylines the current mesh stands on. Test seam.
func contour_lines() -> Array:
	return _contour


## Is the curtain actually standing? False headless, false when the feature is switched off, and
## false once the frontier has no sources at all (a profile that has revealed nothing).
func armed() -> bool:
	for c in _curtains:
		if is_instance_valid(c) and c.visible:
			return true
	return false


## How many arc sections are standing. The frontier is a union of circles, so it is drawn as one
## section per ARC rather than one mesh — see `_build_curtains`.
func curtain_count() -> int:
	return _curtains.size()


# --- The mesh --------------------------------------------------------------------------


# ONE MESH PER ARC of the frontier, rebuilt only when progress changes. Per-frame cost is ZERO:
# there is no `_process` here, and nothing about the curtain depends on where the camera is.
#
# Why geometry rather than a shader curtain keyed off `ow_fog_mask`: a terrain fragment shader can
# only paint the GROUND — it has nothing standing in the air to shade — so a curtain needs geometry
# whatever draws it, and the cheap shader-only alternatives (a cylinder that follows the camera)
# put the wall at a fixed distance from the car instead of at the frontier, which reads as a
# curtain chasing you. Tracing the union's rim is a few thousand distance tests on a progression
# event, and it keeps every stage shader untouched — so the "no-op in every other scene" guarantee
# is STRUCTURAL (a node in this scene's tree, freed with it) rather than another global uniform
# somebody has to remember to disarm.
#
# Why PER ARC and not one map-wide mesh: late in the game the frontier is tens of circles, which as
# a single surface is tens of thousands of ALPHA-BLENDED, non-depth-writing triangles — overdraw
# mobile web cannot afford — and a single map-spanning AABB can never be frustum-culled, so all of it
# is submitted every frame however little is on screen. Split per arc, each arc has a tight AABB and
# Godot's own frustum culling drops the ones behind the camera, which is where the saving actually
# comes from.
#
# AND NO DISTANCE CULL — the shared `MeshUtil.apply_visibility_range` this used to apply is WRONG for
# this shape, which is the bug behind "the border disappears when you get close to it":
# `visibility_range_end` measures camera→node ORIGIN, an arc is anchored at its CENTROID, and a lone
# lit circle's arc is a closed loop whose centroid is the circle's CENTRE. At the shipped numbers
# that centre is `map_reveal_radius` x `overworld_size_m` = 0.16 x 1000 = 160 m from every point of
# the rim, against a `tree_render_distance_m` of 120 m — so the ring drew while the player sat in the
# middle of their lit region and vanished as they drove up to it. Exactly inverted.
#
# A distance cull was never right here anyway: the wall's whole job is to be visible BEFORE the veil
# and the push-back explain it, so it has to read from across the valley. Roadside clutter culls;
# a boundary does not.
func _build_curtains() -> void:
	_clear_mesh()
	var height: float = maxf(Config.data.overworld_fog_wall_height_m, 0.0)
	if _contour.is_empty() or height <= 0.0:
		return
	_ensure_material()
	var rings: int = maxi(OverworldZone.TUBE_RINGS, 1)
	for line: PackedVector2Array in _contour:
		if line.size() < 2:
			continue
		var anchor := Vector3.ZERO
		for p in line:
			anchor += Vector3(p.x, 0.0, p.y)
		anchor /= float(line.size())
		var mesh := _arc_mesh(line, anchor, rings, height)
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "FrontierArc%d" % _curtains.size()
		mi.mesh = mesh
		mi.material_override = _material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = anchor
		add_child(mi)
		_curtains.append(mi)
	_apply_look()


# One arc's surface, in the arc's own local space (offset by `anchor`, so the node's origin sits in
# the middle of its geometry and the distance cull measures something meaningful).
func _arc_mesh(line: PackedVector2Array, anchor: Vector3, rings: int, height: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for i in line.size():
		var p: Vector2 = line[i]
		var base := _ground(p) - BASE_SINK_M
		for r in rings + 1:
			var v := float(r) / float(rings)
			# The tube's curve, from the tube's own constant: >1 keeps the base solid and dumps
			# most of the fade into the upper half, so the curtain has a foot.
			var a := 1.0 - pow(v, OverworldZone.TUBE_FADE_POW)
			verts.append(Vector3(p.x, base + v * (height + BASE_SINK_M), p.y) - anchor)
			colors.append(Color(1.0, 1.0, 1.0, a))
	var stride := rings + 1
	for i in range(line.size() - 1):
		for r in rings:
			var i0 := i * stride + r
			var i1 := i0 + 1
			var j0 := (i + 1) * stride + r
			var j1 := j0 + 1
			indices.append_array(PackedInt32Array([i0, j0, j1, i0, j1, i1]))
	if indices.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# The curtain's material, built once. Every choice here is the light tube's, for the same reasons
# (see OverworldZone._tube_material): UNSHADED so it does not go dark under the sky's own lighting,
# alpha-blended, DOUBLE-SIDED so it reads from inside the map as well as outside, shadowless, and it
# does NOT write depth — the car, the terrain and the markers must all stay visible through it. The
# vertical fade rides the mesh's vertex colours via `vertex_color_use_as_albedo`, which leaves
# `albedo_color` free as the single dial the look fields write.
func _ensure_material() -> void:
	if _material != null:
		return
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_material.vertex_color_use_as_albedo = true


# Colour and overall alpha, read live from GameConfig on every rebuild. (The HEIGHT is baked into
# the vertices, so retuning it takes effect on the next rebuild — a progression event or a reload —
# rather than instantly. Called out because the tube's height IS live, and the difference is only
# that a curtain's base follows undulating terrain and so cannot ride a node scale.)
func _apply_look() -> void:
	if _material == null:
		return
	var c: Color = Config.data.overworld_fog_wall_color
	_material.albedo_color = Color(c.r, c.g, c.b,
		clampf(Config.data.overworld_fog_wall_alpha, 0.0, 1.0))


# Drop every arc. Freed rather than hidden: the frontier's SHAPE changes when it grows, so last
# progression's arcs are wrong geometry, not reusable geometry.
func _clear_mesh() -> void:
	for c in _curtains:
		if is_instance_valid(c):
			remove_child(c)
			c.queue_free()
	_curtains.clear()


# Ground height under a contour point, or 0 with no sampler. A non-finite sample is dropped rather
# than written into a vertex — one NAN would take the whole surface's AABB with it.
func _ground(p: Vector2) -> float:
	if not _ground_at.is_valid():
		return 0.0
	var y: float = _ground_at.call(Vector3(p.x, 0.0, p.y))
	return y if is_finite(y) else 0.0


func _on_profile_changed() -> void:
	refresh(Save.profile)

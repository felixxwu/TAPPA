extends Node3D
class_name GhostCar
# Docs: features/rival-ghost.md — update in the same change as this file.
# Tests: tests/headless/test_ghost_car.gd, tests/headless/test_ghost_car_display.gd, tests/headless/test_ghost_wiring.gd, tests/headless/test_rival_pace.gd — extend in the same change.

# The rival ghost's in-world presentation (features/rival-ghost.md): P1's actual car,
# translucent and intangible, driving the stage in exactly the time the standings credit
# them with.
#
# It is posed KINEMATICALLY from a RivalPace profile — no physics, no AI driver. That is
# what lets it be exact about its time, and what lets it exist far up the road where
# terrain collision isn't streamed (a simulated car there would free-fall out of the
# world; the same reason opponent wrecks are placed analytically).
#
# Division of labour: RivalPace owns "how far along at time t" and knows nothing about
# the world; this node owns "where that is in the world and how the car should look
# doing it". Nothing here may feed back into the pace — the cosmetics below change the
# car's pose, never its clock.

# Probe spans, and why they are LONG.
#
# The road curve TrackProgress measures on stores baked points every `bake_interval` (5 m
# by default) and lerps between them (see track_progress.gd), and its 1 m point table is a
# resample of those chords, so it adds no fidelity. The geometry the ghost can see is
# therefore a ~5 m chord polyline: all the turning is concentrated at vertices.
#
# A probe SHORTER than a chord reads inside one straight segment, so it returns a
# piecewise-constant answer that jumps by a whole chord angle every time the ghost crosses
# a vertex. With a 1.5 m heading probe and a 6 m curvature probe the ghost visibly snapped
# its rotation and slid side to side, because the curvature SIGN flipped frame to frame and
# the lateral line offset follows that sign.
#
# So both probes deliberately span several chords, which averages the vertex turning into a
# smooth reading. The temporal smoothing below then handles what is left.
const CURVATURE_PROBE_M := 20.0     # arc distance used to measure local curvature
const HEADING_PROBE_M := 10.0       # arc distance used to derive facing
const KAPPA_REFERENCE := 0.02       # 1/m (~50 m radius) = "fully committed corner"
const NORMAL_PROBE_M := 3.0         # half-span used to read the road slope under the car

var pace: RivalPace = null
var progress: TrackProgress = null  # origin_offset / sample_at / finish_offset
# Duck-typed (has_method("height_at")) rather than a hard TerrainManager, matching
# track_progress.gd. A hard type here meant no test could substitute a stub, which is
# exactly why the wheel-settle callback's arity bug reached the game.
var terrain: Node = null            # anything with height_at(x, z), or null
var elapsed_source := Callable()    # () -> float, normally StageManager.elapsed
var road_half_width := 3.0
var player: Node3D = null           # for the cull distance only

# Variant, not a typed Car: resolving car.tscn's root script type at parse time is
# environment-fragile (see the same note in car_prop.gd), and getting it wrong breaks the
# whole script rather than one line.
var car: Variant = null             # the display car, built via CarProp.spawn
var running := false

var _slip_rad := 0.0                # smoothed, so yaw builds and unwinds
var _kappa := 0.0                   # smoothed curvature, so the lateral side cannot flicker
var _lateral := 0.0                 # smoothed lateral offset (m, +right of travel)
var _basis_smooth := Basis.IDENTITY
var _has_pose := false              # false until the first pose, so it snaps instead of lerping

var _event := {}
var _car_meta := {}                 # P1's effective meta; needed for the tyre grip term
# NOTE: the per-frame tunables below are read LIVE from Config.data in pose_at, not
# cached here. Caching them at setup() meant editing a value while driving did nothing
# until the next stage spawned a fresh ghost — useless for the tune-by-eye loop these
# knobs exist for. Only things that are expensive or structural (materials, the dust
# instance) are still resolved once at setup.
var _wheel_radius := 0.3
var _omega_scratch := {}   # reused per-frame wheel -> omega buffer
var _ghost_materials: Array[StandardMaterial3D] = []
var _dust: Node = null              # the ghost's OWN WheelParticles (see _add_dust)
var _nametag: Label3D = null


# Build the ghost's car. `row` is the snapshotted leaders[0] identity — car_id and
# engine_id must come from the SAME row as the time, or the ghost shows a car the
# standings never mention.
func setup(p_pace: RivalPace, p_progress: TrackProgress, p_terrain: Node,
		row: Dictionary, car_scene: PackedScene, p_event: Dictionary) -> void:
	pace = p_pace
	progress = p_progress
	terrain = p_terrain
	_event = p_event
	_car_meta = row.get("meta", {})
	var cfg: GameConfig = Config.data
	_wheel_radius = maxf(cfg.wheel_radius, 0.05)
	road_half_width = maxf(cfg.track_width * 0.5, 1.0)
	if car_scene != null and not row.is_empty():
		car = _spawn_ghost_car(row, car_scene)
		_add_dust()
		_add_nametag(String(row.get("name", "")))
	visible = false


# The slip angle a tyre is actually AT when it is working at its peak, for this event's
# surface — straight out of the shared tyre model rather than an invented per-surface
# number.
#
# `*_slip_peak` is a NORMALISED slip (the sine of the slip angle laterally), so the angle
# is asin(slip_peak): ~11.5 deg on tarmac at 0.20, ~20.5 deg on gravel at 0.35. That
# relationship is documented on the config fields themselves, and it means the
# gravel-slides-more-than-tarmac difference falls out of the physics for free instead of
# being maintained as a second, unrelated pair of numbers.
#
# NOTE what is deliberately absent: weather. An earlier version divided by the weather grip
# multiplier so a wet stage slid more, which was invented rather than derived. Rain lowers
# mu, and the QSS profile already answers that by cornering SLOWER; the slip angle at which
# a tyre peaks is a property of the rubber and surface, not of how much grip is on offer.
static func _optimum_slip_rad(cfg: GameConfig, event: Dictionary) -> float:
	var tarmac := RallyLibrary.event_tarmac_fraction(event)
	var peak: float = lerpf(cfg.gravel_slip_peak, cfg.tarmac_slip_peak, tarmac)
	return asin(clampf(peak, 0.0, 0.999))


# The lateral grip (m/s^2) available to the ghost right now, mirroring how
# LapTimeModel._surface_grip builds mu for the pace solve — including the driver-skill
# degradation, so the cosmetic agrees with the profile it is drawn from.
func _lateral_grip() -> float:
	var cfg: GameConfig = Config.data
	var base: float = float(_car_meta.get("tire_compound", 1.0))
	var tarmac := RallyLibrary.event_tarmac_fraction(_event)
	var mu := base * ((1.0 - tarmac) * cfg.gravel_grip + tarmac * cfg.tarmac_grip)
	mu *= WeatherLibrary.grip_mult(cfg, RallyLibrary.event_weather(_event))
	if pace != null:
		mu *= pow(maxf(pace.solved_k(), 0.001), cfg.rival_ghost_grip_exponent)
	return maxf(mu, 0.01) * Platform.gravity()


# The display-car recipe. Goes through CarProp.spawn rather than hand-rolling it: that
# is where use_isolated_config() lives (without it this car's apply_car would stomp the
# player's live tuning in the shared Config.data) and where dup_meshes lives (without it
# car.tscn's SHARED body/wheel subresources get resized, so the next prop retro-resizes
# this one).
#
# The wreck preset is the WRONG default here and every override below matters: spawn()
# freezes by default (a frozen body renders at its freeze pose, defeating the pose
# write), and _spawn_wreck_car adds disable_process plus an hp-zeroing configure — reused
# as-is the ghost would be a frozen, process-disabled car smoking like a wreck.
func _spawn_ghost_car(row: Dictionary, car_scene: PackedScene) -> Variant:
	var car_id := String(row.get("car_id", ""))
	var index := CarLibrary.index_of(car_id)
	if index < 0:
		push_warning("GhostCar: unresolved car_id '%s' — no ghost car built." % car_id)
		return null
	return CarProp.spawn(self, car_scene, {
		# REQUIRED alongside engine_id: spawn()'s engine_id branch calls
		# apply_car(opts.index), so omitting index silently builds catalogue car 0.
		"index": index,
		"engine_id": String(row.get("engine_id", "")),
		"freeze": false,
		"silence": true,
		"prune_bodies": true,
		"configure": func(c) -> void:
			# Intangible: the player drives THROUGH the ghost. Explicit because
			# FREEZE_MODE_STATIC deliberately KEEPS its collider (that is how a wreck stays
			# a solid obstacle) and car.tscn sets no layer/mask of its own, so a ghost would
			# otherwise ship on the player's own layer and block him.
			c.collision_layer = 0
			c.collision_mask = 0
			c.kinematic_pose = true
			c.custom_integrator = true
			c.set_physics_process(false)
			_make_translucent(c),
	})


# Give every mesh its own translucent material_override.
#
# Why not GeometryInstance3D.transparency: that only multiplies alpha for a material
# ALREADY in the transparent pass, and the car's shader (ps1_models_lit.gdshader) is
# render_mode unshaded and never writes ALPHA, so it renders opaque and the instance fade
# is a no-op.
#
# Why not add an alpha uniform to that shader: writing ALPHA would move EVERY car into the
# transparent queue. That shader's own comments document how carefully its cost is kept off
# mobile, and the ghost must not tax the player's car.
#
# So: a per-mesh StandardMaterial3D that copies the source material's albedo texture and
# tint, unshaded to keep the flat PS1 look, with alpha from config. The ghost keeps its
# paint and reads as a ghost, and nothing shared is touched.
# Gravel spray for the ghost.
#
# WheelParticles is a SINGLE-CAR system — it holds one `_car` and world.gd wires the only
# instance to the player's car — so the ghost gets nothing from it by default. This was
# briefly documented as coming "for free" because drivetrain.wheel_omega already prefers
# replay_omega; the override is necessary but not sufficient, since no particle system was
# ever looking at the ghost's drivetrain.
#
# Everything else it needs (spin, driven axle, the terrain that classifies gravel vs grass)
# it reads live off the car each tick, so setup(car) is the whole wiring.
func _add_dust() -> void:
	if car == null or not Config.data.rival_ghost_dust_enabled:
		return
	var dust := WheelParticles.new()
	dust.name = "GhostWheelParticles"
	add_child(dust)
	dust.setup(car)
	_dust = dust


# P1's name, floating above the ghost — so the car ahead reads as a rival you are racing
# rather than an anonymous ghost.
#
# Billboarded and parented to the CAR, so it inherits the pose (including the slip yaw and
# the road tilt) without needing its own per-frame update, and disappears with the ghost.
# Depth testing stays ON: a name showing through a hillside would look like UI, not like
# something in the world. Styled after finish_arch.gd's banners — same font-size/pixel-size
# idiom and outline treatment, so the game has one 3D-text look.
func _add_nametag(display_name: String) -> void:
	if car == null or display_name.strip_edges() == "":
		return
	if not Config.data.rival_ghost_nametag_enabled:
		return
	var cfg: GameConfig = Config.data
	var font_size := 96
	var tag := Label3D.new()
	tag.name = "GhostNametag"
	tag.text = display_name
	tag.font_size = font_size
	tag.pixel_size = cfg.rival_ghost_nametag_size_m / float(font_size)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.outline_size = int(font_size * 0.09)
	tag.position = Vector3(0.0, cfg.rival_ghost_nametag_height_m, 0.0)
	car.add_child(tag)
	_nametag = tag


func _make_translucent(c) -> void:
	var alpha: float = clampf(Config.data.rival_ghost_opacity, 0.0, 1.0)
	_ghost_materials.clear()
	for mesh in _mesh_instances(c):
		var mat := _ghost_material(mesh.get_active_material(0), alpha)
		mesh.material_override = mat
		# Retained so the proximity fade can drive alpha per frame without re-walking the
		# mesh tree or rebuilding materials.
		_ghost_materials.append(mat)


func _ghost_material(source: Material, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# WRITE depth, even though this is a blended material.
	#
	# Without it every panel blends against every other, so you see through the near side of
	# the ghost to its own far side — an x-ray look that never reads as a solid car no matter
	# how high the opacity goes. Writing depth makes the body self-occlude properly, so at
	# high rival_ghost_opacity it looks genuinely solid.
	#
	# The trade-off, deliberately taken: at LOW opacity you now see only the nearest surface
	# rather than the whole shell, and separate meshes can sort inconsistently against each
	# other since a blended pass has no per-pixel ordering guarantee. Both are milder than
	# the x-ray, and neither is visible at the opacities this ghost actually runs at.
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	mat.albedo_color = Color(1.0, 1.0, 1.0, alpha)
	if source is ShaderMaterial:
		var sm := source as ShaderMaterial
		var tex = sm.get_shader_parameter("albedo_texture")
		if tex != null:
			mat.albedo_texture = tex
		var tint = sm.get_shader_parameter("albedo_color")
		if tint != null:
			var c3: Color = tint
			mat.albedo_color = Color(c3.r, c3.g, c3.b, alpha)
	elif source is BaseMaterial3D:
		var bm := source as BaseMaterial3D
		mat.albedo_texture = bm.albedo_texture
		mat.albedo_color = Color(bm.albedo_color.r, bm.albedo_color.g, bm.albedo_color.b, alpha)
	# Nearest-neighbour, to match the PS1 look of the source shader.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return mat


func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_mesh_instances(child))
	return out


# Scale every ghost material's alpha by `factor` (0 = invisible, 1 = configured opacity).
func _set_alpha(factor: float) -> void:
	var base: float = clampf(Config.data.rival_ghost_opacity, 0.0, 1.0)
	var a := base * clampf(factor, 0.0, 1.0)
	for mat in _ghost_materials:
		mat.albedo_color.a = a
	if _nametag != null:
		# The tag fades WITH the car. Left opaque it would hang in the air over an
		# invisible ghost as the player overlaps it.
		_nametag.modulate.a = clampf(factor, 0.0, 1.0)
		_nametag.outline_modulate.a = clampf(factor, 0.0, 1.0)


# Exponential smoothing weight for this frame. Framerate-independent: a fixed lerp factor
# would smooth twice as hard at 120 fps as at 60.
func _blend(delta: float, tau: float) -> float:
	if tau <= 0.0 or delta <= 0.0:
		return 1.0
	return clampf(1.0 - exp(-delta / tau), 0.0, 1.0)


func start() -> void:
	running = true

func stop() -> void:
	running = false
	# Next start re-snaps rather than sweeping in from a stale pose.
	_has_pose = false


func _process(delta: float) -> void:
	if not running or pace == null or pace.is_degenerate() or progress == null:
		return
	if not elapsed_source.is_valid():
		return
	pose_at(float(elapsed_source.call()), delta)


# Pose the ghost for a given stage-elapsed time. Split out from _process so the whole
# kinematic chain is testable without a running stage.
func pose_at(elapsed_s: float, delta := 0.0) -> void:
	if car == null or pace == null or progress == null:
		return
	var rendered := rendered_offset_at(elapsed_s)
	var here: Vector2 = progress.sample_at(rendered)
	var forward := _heading_at(rendered)
	var kappa_raw := _signed_curvature_at(rendered)
	var speed := pace.speed_at(elapsed_s)
	# Low-pass the curvature itself. Even with long probes the reading steps as probe points
	# cross chord vertices, and both cosmetics key off it — including its SIGN, which decides
	# which side of the road the ghost sits on.
	# Two independent constants: sideways position wants a heavy hand, rotation a light one.
	# Over-filtering the rotation makes the car turn lazily and lag its own direction of
	# travel, which reads as sliding — the very thing the smoothing is here to remove.
	var cfg: GameConfig = Config.data
	var pos_blend := _blend(delta, cfg.rival_ghost_position_smoothing_s)
	var rot_blend := _blend(delta, cfg.rival_ghost_rotation_smoothing_s)
	# Curvature is filtered on the ROTATION constant (the light one) because slip angle keys
	# off it and should stay responsive; the heavier positional filter is applied to the
	# lateral offset itself, below.
	_kappa = kappa_raw if not _has_pose else lerpf(_kappa, kappa_raw, rot_blend)
	var kappa := _kappa

	# Cosmetics. These move the BODY only; the clock above is already fixed.
	var lateral_load := clampf(absf(kappa) / KAPPA_REFERENCE, 0.0, 1.0)
	var turn_sign := signf(kappa)
	# How hard the tyre is actually working LATERALLY, as a fraction of the lateral grip
	# still available once longitudinal demand has taken its share of the friction circle.
	# When the car is neither braking nor accelerating and is at the cornering limit, that
	# fraction is 1 and the slip angle sits at the surface's optimum — which is the whole
	# point: a tyre at peak lateral force IS at its peak-slip angle. Braking or powering out
	# spends part of the circle longitudinally, the lateral share drops, and so does slip.
	var grip_a := _lateral_grip()
	var a_lat := speed * speed * absf(kappa)
	var a_long := absf(_longitudinal_accel(elapsed_s))
	var lateral_budget_a := sqrt(maxf(grip_a * grip_a - a_long * a_long, 0.0))
	var utilisation := 0.0 if lateral_budget_a <= 0.01 else clampf(a_lat / lateral_budget_a, 0.0, 1.0)
	var max_slip := deg_to_rad(cfg.rival_ghost_max_slip_deg)
	var target_slip := clampf(_optimum_slip_rad(cfg, _event) * utilisation
			* cfg.rival_ghost_slip_scale, 0.0, max_slip) * turn_sign
	# The SECOND rotational filter. Slip is a yaw folded into the basis below, so this lags
	# rotation just as the slerp does — setting rival_ghost_rotation_smoothing_s to 0 while
	# leaving this at its default still leaves the ghost's yaw smoothed in corners. Both
	# have to be zero for genuinely unfiltered rotation.
	var slip_lag: float = cfg.rival_ghost_slip_lag_s
	if delta > 0.0 and slip_lag > 0.0:
		_slip_rad = lerpf(_slip_rad, target_slip, clampf(delta / slip_lag, 0.0, 1.0))
	else:
		_slip_rad = target_slip

	# One shared road-width budget for the line offset AND the slip-swung tail. Two
	# independent clamps would be jointly unsatisfiable: a body centre allowed to sit AT
	# the half-width puts its tail outside the road the moment it yaws at all.
	var margin: float = car.half_width() if car.has_method("half_width") else 0.9
	var tail := _tail_swing(absf(_slip_rad))
	var lateral_budget := maxf(road_half_width - margin - tail, 0.0)
	var lateral_target := -turn_sign * minf(cfg.rival_ghost_line_offset_m * lateral_load, lateral_budget)
	_lateral = lateral_target if not _has_pose else lerpf(_lateral, lateral_target, pos_blend)
	var lateral := _lateral

	var right := Vector2(forward.y, -forward.x)
	var placed := here + right * lateral
	var y := _ground_height(placed.x, placed.y)
	if car.has_method("settled_ride_height"):
		y += car.settled_ride_height()

	# Smooth the ROTATION, never the along-track position: the arc offset is the ghost's
	# clock, and lerping it would make the ghost miss the time the standings report. Lateral
	# offset (above) and orientation are cosmetic, so they are free to be filtered.
	var target_basis := _basis_from(forward, _slip_rad, placed)
	if _has_pose:
		_basis_smooth = Basis(Quaternion(_basis_smooth.get_rotation_quaternion())
				.slerp(Quaternion(target_basis.get_rotation_quaternion()), rot_blend))
	else:
		_basis_smooth = target_basis
	car.global_transform = Transform3D(_basis_smooth, Vector3(placed.x, y, placed.y))
	_has_pose = true

	# Wheels: fill the omega the drivetrain's visual spin reads. car.gd's kinematic_pose
	# _process calls replay_spin off this; without it the ghost slides on dead wheels.
	_drive_wheels(speed)
	if terrain != null and car.has_method("settle_wheels_to_ground"):
		# ONE Vector3 argument: settle_wheels_to_ground calls ground_at.call(
		# wheel.global_position). A two-float lambda parses fine and then fails at runtime
		# the instant the ghost is first posed — which is the countdown hitting zero.
		car.settle_wheels_to_ground(func(p: Vector3) -> float:
			return _ground_height(p.x, p.z))
	_apply_visibility(Vector3(placed.x, y, placed.y))


# Longitudinal acceleration (m/s^2) at this instant, differenced off the pace profile's own
# speeds. Positive under power, negative under braking; only its magnitude matters here,
# since either one spends the same share of the friction circle.
func _longitudinal_accel(elapsed_s: float) -> float:
	if pace == null:
		return 0.0
	var h := 0.05
	return (pace.speed_at(elapsed_s + h) - pace.speed_at(elapsed_s - h)) / (2.0 * h)


# Terrain height under a world XZ, or 0 with no terrain (flat test fixtures). One
# accessor so the body seat and the per-wheel droop below read the same ground.
func _ground_height(x: float, z: float) -> float:
	if terrain != null and terrain.has_method("height_at"):
		return terrain.height_at(x, z)
	return 0.0


# Profile offset mapped into the arc-length space progress is measured in, clamped so
# the ghost PARKS on the finish line rather than sailing into the runoff (and never
# loops, which is what the post-event replay ghost does).
func rendered_offset_at(elapsed_s: float) -> float:
	var origin: float = progress.origin_offset()
	var finish: float = progress.finish_offset()
	return minf(origin + pace.offset_at(elapsed_s), finish)


# Facing, by BACKWARD difference with a forward fallback.
#
# Backward is the primary because once the ghost is clamped at the finish a forward
# sample would cross into the post-finish runoff and snap its heading at the line. But
# backward alone is degenerate at the very start of an unstaged run, where the sample
# clamps onto itself and the difference is the zero vector — so fall back forward, the
# mirror of what track_progress.gd's _reset_xform_at already does.
func _heading_at(rendered: float) -> Vector2:
	var finish: float = progress.finish_offset()
	var half := HEADING_PROBE_M * 0.5
	# CENTRED difference. A purely backward one (what this used to be) makes the facing the
	# chord from HEADING_PROBE_M behind, so the ghost points where the road WAS — a constant
	# ~half-probe lag that reads as the car turning late into every corner, and near a
	# transition it exceeds the slip angle and puts the nose on the wrong side entirely.
	if rendered + half <= finish:
		var ahead: Vector2 = progress.sample_at(rendered + half)
		var behind: Vector2 = progress.sample_at(rendered - half)
		var centred := ahead - behind
		if centred.length() >= 0.001:
			return centred.normalized()
	# Past the finish clamp a forward sample would cross into the post-finish runoff, which
	# bends away from the stage — so there, fall back to looking backward only.
	var here: Vector2 = progress.sample_at(rendered)
	var back: Vector2 = progress.sample_at(rendered - HEADING_PROBE_M)
	var dir := here - back
	if dir.length() < 0.001:
		var fwd_only: Vector2 = progress.sample_at(rendered + HEADING_PROBE_M)
		dir = fwd_only - here
	if dir.length() < 0.001:
		return Vector2(0.0, 1.0)
	return dir.normalized()


# Signed curvature (1/m) from three samples around the point: positive one way, negative
# the other, so the cosmetics know which way to lean and which side the apex is on.
func _signed_curvature_at(rendered: float) -> float:
	var a: Vector2 = progress.sample_at(rendered - CURVATURE_PROBE_M)
	var b: Vector2 = progress.sample_at(rendered)
	var c: Vector2 = progress.sample_at(rendered + CURVATURE_PROBE_M)
	var v1 := b - a
	var v2 := c - b
	if v1.length() < 0.001 or v2.length() < 0.001:
		return 0.0
	var dtheta := wrapf(v2.angle() - v1.angle(), -PI, PI)
	return dtheta / CURVATURE_PROBE_M


# How far the tail swings sideways at a given slip angle — half the wheelbase, so the
# road-width budget accounts for the whole car, not just its centre.
func _tail_swing(slip_rad: float) -> float:
	var half_len := 2.0
	if car != null and car.has_method("half_length"):
		half_len = car.half_length()
	return half_len * sin(slip_rad)


# Aim the car down the road AND lay it on the road surface.
#
# Uses Basis.looking_at, the same construction track_progress.gd's _reset_xform_at uses to
# place the player car, so the ghost and the player agree on which way "forward" is. A
# hand-rolled atan2 here was 180 degrees out — the ghost drove the stage backwards.
#
# The up vector is the TERRAIN normal, not world up: with world up the ghost stands
# perfectly level on every slope, so on a climb or a cambered corner it visibly floats /
# digs in instead of looking like it is driving on the road. The forward vector is likewise
# pitched onto the surface, so the nose rises going uphill.
func _basis_from(forward: Vector2, slip: float, at: Vector2) -> Basis:
	var flat := Vector3(forward.x, 0.0, forward.y)
	if flat.length() < 0.001:
		flat = Vector3(0.0, 0.0, 1.0)
	flat = flat.normalized()
	var up := _surface_normal(at, Vector2(flat.x, flat.z))
	# Project the travel direction onto the surface plane so forward and up stay
	# perpendicular (looking_at would otherwise skew the basis on a steep slope).
	var fwd := (flat - up * flat.dot(up))
	if fwd.length() < 0.001:
		fwd = flat
	var aimed := Basis.looking_at(fwd.normalized(), up)
	# Yaw about the SURFACE normal, not world up, so slip on a cambered corner still keeps
	# the wheels on the road.
	#
	# NEGATED, and this is not a fudge. `slip` is derived from curvature measured in the 2D
	# curve space, which is Vector2(world_x, world_z) — so its angles are atan2(z, x). A
	# rotation of Basis(UP, +a) sends +Z toward +X, which DECREASES that 2D angle. The two
	# conventions therefore run opposite, and feeding the 2D sign straight in yaws the car
	# out of the corner instead of into it: a rally car slides nose-INSIDE, and the ghost was
	# doing the exact opposite at every bend. test_ghost_car_display's
	# test_the_ghost_yaws_INTO_the_corner_not_out_of_it pins the direction against the road's
	# own turn sign, so this cannot silently flip back.
	return Basis(up, -slip) * aimed


# Terrain normal under a point, from finite differences along and across the road. Probe
# span is a car-ish length so it reads the slope the car actually spans rather than a
# single noisy sample.
func _surface_normal(at: Vector2, forward: Vector2) -> Vector3:
	if terrain == null or not terrain.has_method("height_at"):
		return Vector3.UP
	var right := Vector2(forward.y, -forward.x)
	var d := NORMAL_PROBE_M
	var f_ahead := _ground_height(at.x + forward.x * d, at.y + forward.y * d)
	var f_back := _ground_height(at.x - forward.x * d, at.y - forward.y * d)
	var r_pos := _ground_height(at.x + right.x * d, at.y + right.y * d)
	var r_neg := _ground_height(at.x - right.x * d, at.y - right.y * d)
	# Tangents spanning 2d in each direction.
	var t_f := Vector3(forward.x * 2.0 * d, f_ahead - f_back, forward.y * 2.0 * d)
	var t_r := Vector3(right.x * 2.0 * d, r_pos - r_neg, right.y * 2.0 * d)
	var n := t_r.cross(t_f)
	if n.length() < 0.0001:
		return Vector3.UP
	n = n.normalized()
	return n if n.y > 0.0 else -n


# Keyed off drivetrain.visuals - the exact wheel set replay_spin() iterates - rather than
# front_wheels + rear_wheels, so a wheel present in one list and not the other cannot
# silently sit still. Refills a reused scratch dict in place (the same no-allocation
# reasoning as car.gd's _replay_omega_scratch) since this runs every rendered frame.
func _drive_wheels(speed_mps: float) -> void:
	if car == null or car.drivetrain == null:
		return
	var omega := speed_mps / _wheel_radius
	_omega_scratch.clear()
	for w in car.drivetrain.visuals:
		_omega_scratch[w] = omega
	car.drivetrain.replay_omega = _omega_scratch


# Cull by distance. The pose stays valid at any range (it needs no collider), so this is
# purely a rendering budget — a ghost minutes up the road is not worth drawing.
func _apply_visibility(where: Vector3) -> void:
	# Deliberately NOT gated on Platform.is_headless(). An earlier version returned early
	# here, which meant the proximity fade below never ran under the test runner (always
	# headless) and shipped unverified. Both `visible` and the material alpha are plain node
	# state — setting them headless costs nothing and keeps the behaviour assertable, which
	# is what features/testing.md asks for (assert the final visible state, not mere node
	# existence).
	if player == null:
		visible = true
		_set_alpha(1.0)
		return
	var dist := player.global_position.distance_to(where)
	visible = dist <= Config.data.rival_ghost_visible_m
	# Fade OUT as the player closes in: at zero separation the ghost is fully transparent,
	# reaching full opacity at rival_ghost_fade_near_m. A solid-looking car you are
	# overlapping fills the screen and hides the road you are trying to drive.
	var fade_near: float = Config.data.rival_ghost_fade_near_m
	var near := 1.0 if fade_near <= 0.0 else clampf(dist / fade_near, 0.0, 1.0)
	_set_alpha(near)

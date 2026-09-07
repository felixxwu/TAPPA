class_name RivalGhost
extends Node
# Docs: features/rival-ghost.md — update in the same change as this file.
# Tests: tests/headless/test_rival_ghost.gd — extend in the same change.
#
# Makes the run's one fail state — the fixed clock in RegionRunMode.stage_target_ms
# (todo/roguelike-pivot.md decision 4/11) — visible as a "rival": a second, posed-not-
# simulated Car driving the pace-scaled profile RegionRunMode.stage_target_profile()
# produces, wearing a REAL car from the CarLibrary roster (pick_rival) whose benchmark
# pace best matches the target clock — so the start-line reveal names and shows a car
# that plausibly drives that time. The ghost still drives the PROFILE regardless of
# what the car could actually do (the profile IS the fail state; the body is costume).
# See features/rival-ghost.md for the full picture (start-line reveal + live HUD
# delta); this file is the maths, the rival's identity, and the Car it drives.
#
# The maths is two pure inversions of the profile's parallel {"s","t"} arrays (no
# live Car needed, so they're tested without instancing one):
#   distance_at_time(profile, t) -> s   poses the ghost at a race time
#   time_at_distance(profile, s) -> t   the HUD delta: the rival's time AT THE
#                                        PLAYER'S distance, compared to the player's
#                                        actual elapsed time
# Both binary-search the monotonic array and lerp between the bracketing samples.
# profile["t"] is non-decreasing by construction (LapTimeModel's forward solve never
# runs time backwards) and profile["s"] is evenly spaced (LapTimeModel.SAMPLE_STEP_M),
# so a plain lerp between neighbours is exact for "s" and a good approximation for the
# (non-linear) "t" — the same accuracy the profile is sampled at everywhere else.

# How far ahead along the centerline the tangent sample is taken, for facing.
const TANGENT_EPS_M := 0.5

# Half-span of the forward/lateral height probes that read the road slope under
# the ghost (see _surface_normal).
const NORMAL_PROBE_M := 3.0
# Half-span of the tangent samples the slip yaw's curvature is read over.
const SLIP_EPS_M := 4.0

# Driver names for the rival reveal card (start_line.gd), picked deterministically
# per stage. Authored, not generated: the pool is small enough that a fixed cast
# reads as a roster the player recognises, and parody-adjacent to the car names.
const RIVAL_NAMES: Array[String] = [
	"K. Vaati", "R. Ostmeyer", "T. Beaumont", "S. Kervinen",
	"M. Doss", "H. Yagami", "P. Lindqvist", "D. Okonkwo",
	"V. Salteri", "J. Rourke", "A. Petrov", "N. Castellan",
]


# Pick the rival's identity for a stage: a REAL CarLibrary car whose benchmark pace
# best matches the stage's target clock, plus a driver name. Pure + static so tests
# can pin the contract without instancing a Car.
#
# `pace` is RegionRunMode.target_pace(stage_index) — the multiplier from the
# REFERENCE car's optimum to the target time. A car "as fast as the target" is one
# whose own benchmark time sits the same multiplier away from the reference's:
# benchmark_ms(car) / benchmark_ms(reference) ≈ pace. Both are solved on the SAME
# frozen benchmark track (CarPerformance caches each solve), so the ratio carries
# over to a real stage closely enough for a believable body — the ghost drives the
# target profile exactly regardless (see the class header), so the pick is costume,
# not physics. <=0 pace (no target) or an unsolvable roster returns {} — the caller
# spawns no ghost anyway when there is no profile, and the ghost then keeps the
# neutral baseline body.
#
# `name_seed` picks the driver name (posmod, so any int is safe) — world.gd derives it
# from the run's seed + stage index, making the name stable for a given stage of a
# given run while varying across runs and stages.
static func pick_rival(pace: float, name_seed: int) -> Dictionary:
	if pace <= 0.0:
		return {}
	var ref_ms := CarPerformance.benchmark_ms(CarPerformance.REFERENCE_CAR)
	if ref_ms <= 0:
		return {}
	var best_index := -1
	var best_gap := INF
	var cars := CarLibrary.all()
	for i in cars.size():
		# merged_meta({}, entry) resolves the entry's ENGINE id into the torque/redline
		# keys the solver reads — the raw entry carries only the engine's id (see
		# CarLibrary's header). Same shape CarStatBounds rates catalogue cars with.
		var ms := CarPerformance.benchmark_ms(CarPerformance.merged_meta({}, cars[i]))
		if ms <= 0:
			continue  # unsolvable spec — never pick it, however well it would match
		var gap := absf(float(ms) / float(ref_ms) - pace)
		if gap < best_gap:
			best_gap = gap
			best_index = i
	if best_index < 0:
		return {}
	return {"car_index": best_index, "name": RIVAL_NAMES[posmod(name_seed, RIVAL_NAMES.size())]}

var _car: Node3D = null  # a Car (VehicleBody3D + car.gd), Node3D-typed like start_line.gd's _player -- ungualified so script-only members (kinematic_pose, freeze) resolve dynamically
var _car_index := -1     # the CarLibrary entry the rival wears (pick_rival), -1 = neutral baseline
var _rival_name := ""    # the driver name the start-line card shows (pick_rival), "" = unnamed
# TrackProgress — read via origin_offset()/sample_at() only (duck-typed so a bare
# test double works), never written. See features/rival-ghost.md for why the ghost
# is posed in TrackProgress's arc-length space rather than the raw generated
# centerline's.
var _track_progress: Node = null
var _terrain: Node = null
var _profile: Dictionary = {}   # {"s","t"} pace-scaled, from RunSession.stage_target_profile()
# Translucent material overrides for every mesh under the ghost's car — retained so
# the proximity fade can drive alpha per frame without re-walking the mesh tree.
var _ghost_materials: Array[StandardMaterial3D] = []
# The driver-name Label3D floating over the ghost (fades with the car via _set_alpha).
var _nametag: Label3D = null
# The player's car, for the proximity fade/cull (set_player). Null in bare harnesses.
var _player: Node3D = null
# Re-entry gate after the start-line departure: the ghost stays hidden until the
# profile's own distance at the run clock passes this (the player's clock "catches
# up" to where the drive-off left the rival), so it doesn't pop back onto the line.
# <= 0 means no gate (never departed / already re-entered).
var _reentry_s := -1.0


# Point the proximity fade/visibility at the player's car (world.gd wires this after
# setup). Without it the ghost renders at full configured opacity at any range —
# fine for tests and bare harnesses, wrong for a run.
func set_player(player: Node3D) -> void:
	_player = player


# --- Pure profile maths (testable with a synthetic {"s","t"} dict) ----------------

# [lo_index, frac] such that `x` sits `frac` of the way from arr[lo] to arr[lo+1].
# Clamps at both ends (frac 0 at/before the first sample, 1 at/after the last) rather
# than extrapolating, so a `t`/`s` past the profile's range holds at the profile's own
# edge value instead of running off it.
static func _bracket(arr: PackedFloat32Array, x: float) -> Array:
	var n := arr.size()
	if n == 0:
		return [-1, 0.0]
	if n == 1 or x <= arr[0]:
		return [0, 0.0]
	if x >= arr[n - 1]:
		return [n - 2, 1.0]
	var lo := 0
	var hi := n - 1
	while hi - lo > 1:
		var mid := (lo + hi) / 2
		if arr[mid] <= x:
			lo = mid
		else:
			hi = mid
	var span: float = arr[hi] - arr[lo]
	var frac := 0.0 if span <= 0.0 else (x - arr[lo]) / span
	return [lo, frac]


# Distance (m) along the track the rival has covered at race time `t` (s), per
# `profile` ({"s","t"} from RegionRunMode.stage_target_profile). 0.0 for an
# empty/degenerate profile.
static func distance_at_time(profile: Dictionary, t: float) -> float:
	var t_arr: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	var s_arr: PackedFloat32Array = profile.get("s", PackedFloat32Array())
	if t_arr.is_empty() or s_arr.is_empty():
		return 0.0
	var b := _bracket(t_arr, t)
	var lo: int = b[0]
	var frac: float = b[1]
	return lerpf(s_arr[lo], s_arr[lo + 1], frac)


# Race time (s) the rival reaches distance `s_m`, per `profile`. 0.0 for an
# empty/degenerate profile. This is the HUD delta's other half: world.gd/
# stage_manager.gd call this at the PLAYER's live distance and compare the result
# against the player's own elapsed stage time.
static func time_at_distance(profile: Dictionary, s_m: float) -> float:
	var s_arr: PackedFloat32Array = profile.get("s", PackedFloat32Array())
	var t_arr: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	if s_arr.is_empty() or t_arr.is_empty():
		return 0.0
	var b := _bracket(s_arr, s_m)
	var lo: int = b[0]
	var frac: float = b[1]
	return lerpf(t_arr[lo], t_arr[lo + 1], frac)


# Total profile duration (s) — the last sample of profile["t"], or 0.0 for an
# empty/degenerate profile (no target, nothing to show).
static func profile_duration(profile: Dictionary) -> float:
	var t_arr: PackedFloat32Array = profile.get("t", PackedFloat32Array())
	return t_arr[t_arr.size() - 1] if not t_arr.is_empty() else 0.0


# --- Live instance (owns a Car, poses it every frame) -----------------------------

# Build (once) and wire the ghost's Car. `track_progress` supplies the arc-length
# space (origin_offset/sample_at) the ghost is posed in; `terrain` seats it on the
# ground the same way start_line.gd seats the player. `rival` (optional) is
# pick_rival()'s output — the CarLibrary entry the rival wears and the driver name
# the start-line card shows; omitted/empty keeps the neutral baseline body.
# Safe to call again with a new `profile` on a stage change — the Car is reused,
# not rebuilt, and re-wears the new stage's rival car if it differs.
func setup(track_progress: Node, terrain: Node, profile: Dictionary, rival: Dictionary = {}) -> void:
	_track_progress = track_progress
	_terrain = terrain
	_profile = profile
	_reentry_s = -1.0  # a fresh stage's ghost has not departed anywhere yet
	if _car == null:
		_car = Scenes.car_scene().instantiate() as Node3D
		_car.kinematic_pose = true
		# The ghost is never simulated by the physics server: kinematic_pose stops
		# THIS car's own script from stepping its drivetrain/engine, but the body is
		# still a VehicleBody3D the physics server would otherwise integrate gravity
		# and collisions on between our per-frame transform writes below. FREEZE_MODE
		# _KINEMATIC turns it into a driven-by-script body the server never moves on
		# its own, and zeroing the layers/mask means it can never push (or be pushed
		# by) the player's real car. See features/rival-ghost.md.
		_car.freeze = true
		_car.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		_car.collision_layer = 0
		_car.collision_mask = 0
		add_child(_car)
	_apply_rival_car(rival)
	# AFTER _apply_rival_car: apply_car reshapes the meshes, so a translucent pass run
	# before it would leave the new meshes solid.
	_make_translucent(_car)
	_build_nametag()
	_car.visible = true


# Reshape the ghost's body to a real CarLibrary entry (pick_rival's car_index) —
# the same path the old start-line grid props used: isolate the config FIRST (apply_car
# mutates a GameConfig; without isolation it would clobber the player car's engine/
# gearbox in the shared Config.data), snapshot the live config VALUES around it as the
# belt-and-braces net for any path that bypasses isolation, and skip the engine-voice
# rebuild (a kinematic ghost never fires its engine). apply_car also relocates wheels
# and resets the pose — destructive to a LIVE body, harmless here: the body is frozen,
# zero-collision, and _pose_car_at_distance writes its transform every frame anyway.
func _apply_rival_car(rival: Dictionary) -> void:
	_car_index = int(rival.get("car_index", -1))
	_rival_name = String(rival.get("name", ""))
	if _car_index < 0 or not (_car is Node and _car.has_method("apply_car")):
		return
	var snapshot: Dictionary = Config.data.snapshot_values()
	_car.use_isolated_config()
	_car.apply_car(_car_index, false)
	Config.data.restore_values(snapshot)


func has_car() -> bool:
	return is_instance_valid(_car)


func car() -> Node3D:
	return _car


# --- Rival identity (the start-line reveal card reads these) --------------------

# The profile as handed to setup(), for callers that need the target clock itself
# (start_line.gd formats profile_duration as the time to beat).
func profile() -> Dictionary:
	return _profile


# The stage target in whole ms — the profile's own last sample, which by construction
# sits within float rounding of RegionRunMode.stage_target_ms (see its comment for why
# the two are computed separately rather than one chaining the other's rounding).
func target_ms() -> int:
	return int(round(profile_duration(_profile) * 1000.0))


# The rival's driver name from pick_rival, or "" when unnamed (no target / test stub).
func rival_name() -> String:
	return _rival_name


# The CarLibrary entry index the rival wears (-1 = neutral baseline), and its display
# name for the card — resolved fresh from the roster so a renamed entry shows renamed.
func rival_car_index() -> int:
	return _car_index


func rival_car_name() -> String:
	if _car_index < 0 or _car_index >= CarLibrary.all().size():
		return ""
	return String(CarLibrary.all()[_car_index].get("name", ""))


# Whether this ghost has anything to show — an empty profile means the stage's
# track was degenerate (no target, per RegionRunMode.stage_target_ms), so there is
# no rival to pose.
func has_profile() -> bool:
	return not _profile.is_empty() and profile_duration(_profile) > 0.0


# Pose the ghost at a raw track distance (m from the origin sample) instead of a
# profile race time — the start-line grid slot (ON the line, s=0) and the departure
# animation are DISTANCES, not times on the profile. Same posing path and guards as
# pose_at(), but renders SOLID: the start-line park and send-off frame the rival up
# close as the subject of the shot — translucency is the run-time reading aid, and
# a see-through rival on the grid just looks broken.
func pose_at_distance(s_m: float) -> void:
	if not is_instance_valid(_car) or not has_profile() or _track_progress == null:
		return
	_pose_car_at_distance(s_m)
	_car.visible = true
	for mat in _ghost_materials:
		mat.albedo_color.a = 1.0
	if _nametag != null:
		_nametag.modulate.a = 1.0
		_nametag.outline_modulate.a = 1.0


# The ghost's speed (m/s) at a track distance, straight off the profile's own
# derivative — the pace the departure animation drives the car off the line at.
# Falls back to a standing-start crawl pace when the profile is flat around `s_m`.
func departure_speed(s_m: float) -> float:
	var t_a := time_at_distance(_profile, s_m)
	var t_b := time_at_distance(_profile, s_m + 1.0)
	if t_b <= t_a:
		return 5.0
	return 1.0 / (t_b - t_a)


# The start-line drive-off just ended at `s_m`: hide the ghost and arm the re-entry
# gate pose_at() honours through the early run (see _reentry_s).
func mark_departed_at(s_m: float) -> void:
	_reentry_s = maxf(s_m, 0.0)
	if is_instance_valid(_car):
		_car.visible = false
	_set_alpha(0.0)


func hide_ghost() -> void:
	if is_instance_valid(_car):
		_car.visible = false


func free_ghost() -> void:
	if is_instance_valid(_car):
		_car.queue_free()
	_car = null
	_nametag = null  # a child of the car; freed with it
	_ghost_materials.clear()
	_reentry_s = -1.0



# Pose the ghost at an EXTERNAL race time (StageManager.elapsed(), during RUNNING) —
# the counterpart to pose_at_distance()'s raw-distance form (the start-line grid
# slot). No-op with no car, no profile, or no track_progress (a bare test/dev
# harness with no live track). Honours the post-departure re-entry gate: until the
# profile's own distance at `t` passes where the drive-off left it, the ghost stays
# hidden (see _reentry_s).
func pose_at(t: float) -> void:
	if not is_instance_valid(_car) or not has_profile() or _track_progress == null:
		return
	var s := distance_at_time(_profile, t)
	if _reentry_s > 0.0:
		if s < _reentry_s:
			if _car.visible:
				_car.visible = false
				_set_alpha(0.0)
			return
		_reentry_s = -1.0  # caught up — normal posing from here on
	_pose_car_at_distance(s)
	_apply_visibility(_car.global_position)


func _pose_car_at_distance(s: float) -> void:
	if not (_track_progress.has_method("origin_offset") and _track_progress.has_method("sample_at")):
		return
	var origin: float = _track_progress.origin_offset()
	var here: Vector2 = _track_progress.sample_at(origin + s)
	var ahead: Vector2 = _track_progress.sample_at(origin + s + TANGENT_EPS_M)
	var speed := departure_speed(s)
	var basis := _basis_from(ahead - here, _slip_at(s, speed), here)
	var pos := Vector3(here.x, _ground_y(here.x, here.y), here.y)
	_car.global_transform = Transform3D(basis, pos)
	_drive_wheels(speed)
	# Droop the wheel Visuals onto the road the body was just seated against — a
	# frozen body's solver never runs, so without this the wheels sit tucked up in
	# the arches. ONE Vector3 argument: the callable is invoked as ground_at.call(
	# wheel.global_position), and a two-float lambda parses fine and then fails at
	# runtime the instant the ghost is first posed.
	if _car.has_method("settle_wheels_to_ground"):
		_car.settle_wheels_to_ground(func(p: Vector3) -> float:
			return _ground_y(p.x, p.z))


func _ground_y(x: float, z: float) -> float:
	if _terrain != null and _terrain.has_method("height_at"):
		return _terrain.height_at(x, z) + Config.data.start_spawn_clearance
	return Config.data.start_spawn_clearance


# --- Ghost display (transparency, slope, slip, wheels — features/rival-ghost.md) ---

# Give every mesh under the ghost's car a translucent override. The car's own shader
# (ps1_models_lit.gdshader) is unshaded and never writes ALPHA, so
# GeometryInstance3D.transparency is a no-op on it — a real material override is the
# only thing that makes the ghost see-through.
func _make_translucent(c: Node) -> void:
	var alpha: float = clampf(Config.data.rival_ghost_opacity, 0.0, 1.0)
	_ghost_materials.clear()
	for mesh in _mesh_instances(c):
		var mat := _ghost_material(mesh.get_active_material(0), alpha)
		mesh.material_override = mat
		# Retained so the proximity fade can drive alpha per frame without re-walking
		# the mesh tree or rebuilding materials.
		_ghost_materials.append(mat)


func _mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_mesh_instances(child))
	return out


# A translucent, unshaded stand-in for `source`, carrying its texture/tint across.
func _ghost_material(source: Material, alpha: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Don't write depth: overlapping ghost panels (body over wheel arch) otherwise
	# punch holes in each other at the same alpha.
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
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


# Scale every ghost material's alpha by `factor` (0 = invisible, 1 = configured
# opacity).
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


# Cull by distance and fade OUT as the player closes in: at zero separation the
# ghost is fully transparent, reaching full opacity at rival_ghost_fade_near_m — a
# solid-looking car you are overlapping fills the screen and hides the road.
# Deliberately NOT gated on Platform.is_headless(): both `visible` and the material
# alpha are plain node state, so keeping them assertable under the (headless) test
# runner is what features/testing.md asks for.
func _apply_visibility(where: Vector3) -> void:
	if _player == null:
		_car.visible = true
		_set_alpha(1.0)
		return
	var dist: float = _player.global_position.distance_to(where)
	_car.visible = dist <= Config.data.rival_ghost_visible_m
	var fade_near: float = Config.data.rival_ghost_fade_near_m
	var near := 1.0 if fade_near <= 0.0 else clampf(dist / fade_near, 0.0, 1.0)
	_set_alpha(near)


# The ghost's body basis at a track point: forward from the centerline tangent,
# up from the road's own surface normal (so it pitches and rolls with the road —
# a world-up ghost floats nose-level on every climb), plus a slip yaw about the
# SURFACE normal so it slides nose-into corners like a rally car.
func _basis_from(forward: Vector2, slip: float, at: Vector2) -> Basis:
	var flat := Vector3(forward.x, 0.0, forward.y)
	if flat.length() < 0.001:
		flat = -_car.global_transform.basis.z
	flat = flat.normalized()
	var up := _surface_normal(at, Vector2(flat.x, flat.z))
	# Project the travel direction onto the surface plane so forward and up stay
	# perpendicular (looking_at would otherwise skew the basis on a steep slope).
	var fwd := (flat - up * flat.dot(up))
	if fwd.length() < 0.001:
		fwd = flat
	var aimed := Basis.looking_at(fwd.normalized(), up)
	# Yaw about the SURFACE normal, not world up, so slip on a cambered corner still
	# keeps the wheels on the road.
	#
	# NEGATED, and this is not a fudge. `slip` is derived from curvature measured in
	# the 2D curve space, which is Vector2(world_x, world_z) — so its angles are
	# atan2(z, x). A rotation of Basis(UP, +a) sends +Z toward +X, which DECREASES
	# that 2D angle. The two conventions therefore run opposite, and feeding the 2D
	# sign straight in yaws the car out of the corner instead of into it: a rally
	# car slides nose-INSIDE, and the ghost must not do the opposite at every bend.
	return Basis(up, -slip) * aimed


# The road's surface normal at a track point, from forward/lateral height probes.
func _surface_normal(at: Vector2, forward: Vector2) -> Vector3:
	if _terrain == null or not _terrain.has_method("height_at"):
		return Vector3.UP
	var fwd_n := forward.normalized()
	var right := Vector2(fwd_n.y, -fwd_n.x)
	var d := NORMAL_PROBE_M
	var f_ahead: float = _terrain.height_at(at.x + fwd_n.x * d, at.y + fwd_n.y * d)
	var f_back: float = _terrain.height_at(at.x - fwd_n.x * d, at.y - fwd_n.y * d)
	var r_pos: float = _terrain.height_at(at.x + right.x * d, at.y + right.y * d)
	var r_neg: float = _terrain.height_at(at.x - right.x * d, at.y - right.y * d)
	# Tangents spanning 2d in each direction.
	var t_f := Vector3(fwd_n.x * 2.0 * d, f_ahead - f_back, fwd_n.y * 2.0 * d)
	var t_r := Vector3(right.x * 2.0 * d, r_pos - r_neg, right.y * 2.0 * d)
	var n := t_r.cross(t_f)
	if n.length() < 0.0001:
		return Vector3.UP
	n = n.normalized()
	return n if n.y > 0.0 else -n


# The slip yaw (rad) at a track distance: the centripetal demand of the profile's
# own speed through the centerline's curvature there, scaled/clamped by config. A
# physically-motivated stand-in for the deleted pace solver's optimum slip angle:
# lateral demand v²·κ against gravity, atan'd into an angle the body can wear.
func _slip_at(s: float, speed: float) -> float:
	var origin: float = _track_progress.origin_offset()
	var back: Vector2 = _track_progress.sample_at(origin + s - SLIP_EPS_M)
	var here: Vector2 = _track_progress.sample_at(origin + s)
	var ahead: Vector2 = _track_progress.sample_at(origin + s + SLIP_EPS_M)
	var t0 := here - back
	var t1 := ahead - here
	if t0.length() < 0.001 or t1.length() < 0.001:
		return 0.0
	var cross: float = t0.x * t1.y - t0.y * t1.x
	var curvature: float = cross / (t0.length() * t1.length())
	curvature /= maxf((t0.length() + t1.length()) * 0.5, 0.001)
	var demand := speed * speed * absf(curvature) / 9.8
	var slip := atan(demand) * Config.data.rival_ghost_slip_scale
	var max_rad := deg_to_rad(clampf(Config.data.rival_ghost_max_slip_deg, 0.0, 90.0))
	return clampf(slip, 0.0, max_rad) * signf(curvature)


# Fill drivetrain.replay_omega from the profile speed so car.gd's kinematic_pose
# branch spins the wheel Visuals — without it the ghost slides down the road on four
# dead wheels (drivetrain.step() never runs in this mode).
func _drive_wheels(speed: float) -> void:
	if not ("drivetrain" in _car) or _car.drivetrain == null:
		return
	var radius: float = Config.data.wheel_radius
	if "config" in _car and _car.config != null:
		radius = _car.config.wheel_radius
	if radius <= 0.0:
		return
	var omega := speed / radius
	for wheel in _car.drivetrain.visuals:
		_car.drivetrain.replay_omega[wheel] = omega


# The driver-name tag floating over the ghost (rival_ghost_nametag_* keys). A child
# of the car so the per-frame transform write carries it along; billboards so it
# always faces the camera. Rebuilt on setup so a stage's fresh rival renames it.
func _build_nametag() -> void:
	if _nametag != null and is_instance_valid(_nametag):
		_nametag.queue_free()
		_nametag = null
	var cfg := Config.data
	if not cfg.rival_ghost_nametag_enabled or _rival_name == "":
		return
	_nametag = Label3D.new()
	_nametag.text = _rival_name
	_nametag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_nametag.no_depth_test = true
	_nametag.font_size = int(round(cfg.rival_ghost_nametag_size_m * 100.0))
	_nametag.outline_size = 8
	_nametag.position = Vector3(0.0, cfg.rival_ghost_nametag_height_m, 0.0)
	_nametag.modulate = Color(1.0, 1.0, 1.0, 1.0)
	if is_instance_valid(_car):
		_car.add_child(_nametag)

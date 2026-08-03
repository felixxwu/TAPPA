class_name WeatherField
extends GPUParticles3D
# The weather particle field for a WET (rain) or SANDSTORM stage (GameConfig.weather).
# File kept as rain_field.gd (the original name) to avoid churning the res:// path/uid
# rain shipped under; the class itself now covers both conditions — see spawn_rain /
# spawn_sandstorm below.
#
# Parented to the CHASE CAMERA, not the world: the emission box travels with the
# view, so a modest quad count (rain_particle_count / sand_particle_count) covers
# the whole visible field without simulating weather over the kilometres of track
# nobody is looking at.
#
# IMPORTANT: `local_coords = false`. The emitter node follows the camera, but each
# particle's position is simulated in WORLD space once spawned — so driving forward
# actually carries the car THROUGH standing rain/dust rather than dragging every
# drop along for the ride. That is what gives correct parallax/streaming-past-the-
# windscreen at speed, and it comes from the simulation itself: no per-frame car-
# speed reads, no faked tilt, no per-frame resize. (An earlier version used
# local_coords = true and faked the speed response by tilting direction/stretching
# the quad off car.linear_velocity — that only ever looked right at fixed camera
# angles and didn't respond correctly to sliding sideways, so it was removed.)
#
# Cost: ONE draw call of unshaded, non-shadow-casting, non-colliding billboards, and
# zero per-frame script work beyond spawn. Nothing here is constructed unless the
# condition's WeatherLibrary entry names a particle kind — dry names none, so a dry
# stage builds no node and pays exactly zero new per-frame cost. See
# features/rendering.md.

enum Mode { RAIN, SANDSTORM }

# The emission volume around the camera, in metres (half-extents). Generous enough
# that, combined with the lifetime below, drops/dust spawned at the box's leading
# edge are not outrun and culled before they pass the camera even at rally speeds.
const _BOX_EXTENTS := Vector3(20.0, 10.0, 20.0)
# Rain: a thin, tall quad reads as a falling drop; BILLBOARD_PARTICLES (below)
# orients it to its own (world-space) velocity so it reads as a streak while
# falling+carried, for free — a rendering choice, not a simulated-motion fake.
const _RAIN_QUAD_SIZE := Vector2(0.02, 0.45)
const _RAIN_FALL_SPEED := 18.0  # m/s downward
# Dust: squarer, softer quad — reads as a mote/streak blown on the wind rather
# than a falling drop.
const _SAND_QUAD_SIZE := Vector2(0.12, 0.12)
# Fallback drift speed (m/s) for a dust field spawned without a speed — a structural
# default so a caller that names no "particle_speed" field still gets moving dust, NOT
# the authored value (that lives in game_config.tres and reaches here via the table).
const _SAND_DRIFT_SPEED := 10.0
# Lifetime: box depth / travel speed, so particles recycle before drifting far
# outside the emission volume (world-space particles that outlive the box just
# get respawned inside it on the next emission, so a short lifetime also keeps
# the "trailing behind the car" case from lingering).
const _RAIN_LIFETIME := 1.6
const _SAND_LIFETIME := 3.0


# Build the particle field for a weather-table "particles" kind ("rain" / "sand")
# under `parent` (the chase camera). THIS is what world.gd calls: the kind comes
# straight out of WeatherLibrary's entry, so adding a condition that reuses an
# existing particle kind needs no code here at all. An unrecognised kind builds
# nothing and returns null — same tolerance as WeatherLibrary.by_id. `wind_dir_deg`
# is ignored by kinds that have no wind, and `speed_mps` (0.0 = the kind's own built-in
# speed) comes from the field the entry's "particle_speed" names — NOTHING in this file
# reads a condition's GameConfig field itself, which is the whole point of the table.
# See features/weather.md.
static func spawn(parent: Node3D, kind: String, count: int, wind_dir_deg: float,
		speed_mps := 0.0) -> WeatherField:
	match kind:
		"rain":
			return spawn_rain(parent, count)
		"sand":
			return spawn_sandstorm(parent, count, wind_dir_deg, speed_mps)
	return null


# Build a RAIN field under `parent` (the chase camera) with `count` quads alive.
# Returns the node, already added to the tree.
static func spawn_rain(parent: Node3D, count: int) -> WeatherField:
	var field := WeatherField.new()
	field.name = "WeatherField"
	field._configure(Mode.RAIN, count, 0.0)
	parent.add_child(field)
	return field


# Build a SANDSTORM dust field under `parent` (the chase camera) with `count` quads
# alive, blowing toward `wind_dir_deg` (0 = world +X, 90 = world +Z) at a fixed
# speed (GameConfig.sand_wind_speed) — a single constant world-space direction, so
# the wind reads the same regardless of which way the car or camera is facing.
static func spawn_sandstorm(parent: Node3D, count: int, wind_dir_deg: float,
		speed_mps := 0.0) -> WeatherField:
	var field := WeatherField.new()
	field.name = "WeatherField"
	field._configure(Mode.SANDSTORM, count, wind_dir_deg, speed_mps)
	parent.add_child(field)
	return field


func _configure(mode: Mode, count: int, wind_dir_deg: float, speed_mps := 0.0) -> void:
	amount = maxi(1, count)
	lifetime = _RAIN_LIFETIME if mode == Mode.RAIN else _SAND_LIFETIME
	# World-space simulation (see class doc comment): the node still follows the
	# camera so the emission box stays where the player can see it, but once spawned
	# a particle's motion is independent of the emitter's own movement.
	local_coords = false
	# Pure decoration — must never cost a shadow pass.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Start full instead of fading in over the first lifetime.
	preprocess = lifetime

	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = _BOX_EXTENTS
	proc.gravity = Vector3.ZERO  # constant travel speed; no acceleration to tune
	# No particle collision: colliding weather would mean a depth/SDF pass per frame.
	proc.collision_mode = ParticleProcessMaterial.COLLISION_DISABLED

	var quad := QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# BILLBOARD_PARTICLES orients each quad to its own (world-space) velocity, so
	# falling/wind-blown motion reads as a streak with zero extra per-particle work.
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	mat.disable_receive_shadows = true

	if mode == Mode.RAIN:
		proc.direction = Vector3(0.0, -1.0, 0.0)
		proc.spread = 2.0
		proc.initial_velocity_min = _RAIN_FALL_SPEED
		proc.initial_velocity_max = _RAIN_FALL_SPEED * 1.15
		quad.size = _RAIN_QUAD_SIZE
		mat.albedo_color = Color(0.85, 0.87, 0.92, 0.5)
	else:
		var wind := Vector3(cos(deg_to_rad(wind_dir_deg)), 0.0, sin(deg_to_rad(wind_dir_deg)))
		proc.direction = wind
		proc.spread = 8.0  # a little vertical/lateral scatter so dust doesn't read as a laser
		# 0.0 means the caller named no "particle_speed" field; fall back to the
		# kind's own constant rather than to a still dust cloud.
		var speed := speed_mps if speed_mps > 0.0 else _SAND_DRIFT_SPEED
		proc.initial_velocity_min = speed
		proc.initial_velocity_max = speed * 1.15
		quad.size = _SAND_QUAD_SIZE
		mat.albedo_color = Color(0.62, 0.5, 0.32, 0.35)

	process_material = proc
	quad.material = mat
	draw_pass_1 = quad

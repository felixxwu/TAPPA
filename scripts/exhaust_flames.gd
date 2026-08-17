class_name ExhaustFlames
extends Node3D
# Backfire flame drawn at each of the car's exhaust pipes — a visual companion to the
# exhaust crackle pop, plus a continuous flame while nitrous is delivering.
#
# NOT a particle system. Each pipe gets a fixed piece of geometry that is simply shown or
# hidden, with its TEXTURE swapped between a handful of generated flame frames so a
# sustained flame (nitrous) flickers instead of sitting static. A backfire is one shape
# that appears and vanishes, not a spray of debris, so a pool of flying particles was
# both the wrong look and more machinery than the effect needs.
#
# Two triggers, deliberately different in shape:
#   - REV-LIMITER CUT: a short, RETRIGGERABLE hold. EngineSim keeps a monotonic
#     limiter_cut_count, incremented on each cut ONSET; any new cut since last tick
#     re-arms the hold for exhaust_flame_pop_seconds. Reading the counter delta rather
#     than an edge-detected bool means no cut is missed across physics substeps. Bouncing
#     off the limiter therefore reads as rapid flicker, which is what a real backfire
#     looks like. This is the SAME signal the audio crackle burst fires on, so flame and
#     pop land together; a damaged engine's misfire deliberately drives neither (it
#     stumbles, it doesn't bang).
#   - NITROUS: lit continuously while EngineSim.nitrous_delivering — the LATCHED delivery
#     state (held AND charged AND combusting), not "a bottle is fitted", so an empty tank
#     puts the flame out.
#
# Created + wired by world.gd, exactly like WheelParticles / EngineSmoke. The exhaust lab
# (scripts/exhaust_lab.gd) drives it with both triggers forced on.
# See features/exhaust-flames.md.

# --- Geometry ---------------------------------------------------------------
#
# CROSSED QUADS, not a billboard. A flame has a DIRECTION — it shoots out of the pipe,
# rearward along the car's +Z. A camera-facing billboard cannot express that: it would
# keep the flame pointing screen-up however the car was oriented, so a car driving across
# the view would flame sideways. Two perpendicular quads sharing the flame axis read
# correctly from every angle (the standard trick for fire and foliage) and cost two
# triangles each.
#
# A QuadMesh lies in its own XY plane with the texture's +Y up. Rotating +90° about X
# maps that up-axis onto +Z (rearward) and leaves the quad in the XZ plane; rotating that
# a further 90° about Z stands it up into the YZ plane. Both are then pushed forward by
# half their length so the quad's ROOT sits at the pipe rather than its centre.

var _car: Node  # the VehicleBody3D (read for drivetrain.engine)

# One node per pipe, each holding the two crossed quads. Rebuilt whenever the pipe list
# or the flame's look changes.
var _pipes: Array[Node3D] = []
# The generated flame frames, swapped between to animate. Shared by every pipe.
var _frames: Array[ImageTexture] = []
var _material: StandardMaterial3D

# Seconds left on the limiter-bang hold; > 0 means the bang is still showing.
var _burn_timer := 0.0
# Last EngineSim.limiter_cut_count we reacted to — the delta each tick is the new bangs.
var _last_cut_count := 0
# Which frame is showing, and how long until the next swap.
var _frame := 0
var _frame_timer := 0.0
# Deterministic frame generation + frame picking (tests can pin the seed).
var _rng := RandomNumberGenerator.new()
# Forced mode (the exhaust lab): lit continuously regardless of engine state, so the
# pipes can be positioned against a steady flame. Never set in an event.
var _forced := false
# Whether to drive our own transform from the car's each tick. TRUE in an event, where
# world.gd parents us to the world ROOT (reused across regenerations) and the pipe
# offsets are car-LOCAL, so without this the flames would sit at the world origin while
# the car drove away. FALSE in the lab, where we are parented to the car itself and the
# scene tree already composes the transform for us — writing it there would fight the
# parent and stack the offset twice.
var _follow_car := true


func setup(car: Node) -> void:
	_car = car
	_forced = false
	_follow_car = true
	_last_cut_count = _engine_cut_count()
	_burn_timer = 0.0
	_rebuild()


# Set up for the exhaust lab: lit continuously, both triggers ignored.
func setup_forced(car: Node) -> void:
	_car = car
	_forced = true
	_follow_car = false
	_last_cut_count = _engine_cut_count()
	_burn_timer = 0.0
	_rebuild()


func _engine_cut_count() -> int:
	var eng := _engine()
	return eng.limiter_cut_count if eng != null else _last_cut_count


func _engine() -> Object:
	if is_instance_valid(_car) and _car.get("drivetrain") != null:
		return _car.drivetrain.engine
	return null


# --- Build ------------------------------------------------------------------


# Regenerate the frames, the material and one crossed-quad rig per pipe. Called on setup
# and on any hot-reload — everything here is baked from config at build time (texture
# content, quad size), so re-reading the config without rebuilding would silently ignore
# every look change.
func _rebuild() -> void:
	for p in _pipes:
		p.queue_free()
	_pipes.clear()
	var cfg: GameConfig = Config.data
	_frames = build_frames(cfg)
	_material = _build_material(cfg)
	if _frames.is_empty():
		return
	_frame = 0
	_frame_timer = 0.0
	for pipe in pipe_points(_car, cfg):
		_pipes.append(_build_pipe(pipe, cfg))
	_apply_frame()
	_set_lit(_forced)


func _build_material(cfg: GameConfig) -> StandardMaterial3D:
	# ADDITIVE and unshaded: fire is light, so it brightens whatever is behind it rather
	# than painting over it, and nothing about the scene lighting should dim it. Depth
	# write off so the two crossed quads don't fight each other in the depth buffer, and
	# culling off so each quad is visible from both sides.
	var mat := PS1Material.unshaded(_frames[0])
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = cfg.exhaust_flame_tint
	return mat


# One pipe's rig: a holder at the pipe position, YAWED to the pipe's angle, carrying two
# perpendicular quads that run from the pipe out along the holder's +Z.
#
# The yaw lives on the holder rather than on the quads, so both crossed quads turn
# together and the flame axis stays the axis they share. `pipe.w` is degrees about the
# vertical: 0 points straight back, positive turns toward the car's right (+X), which is
# what a right-hand side exit like the Viper's wants.
func _build_pipe(pipe: Vector4, cfg: GameConfig) -> Node3D:
	var holder := Node3D.new()
	holder.position = Vector3(pipe.x, pipe.y, pipe.z)
	holder.rotation = Vector3(0.0, deg_to_rad(pipe.w), 0.0)
	add_child(holder)
	var quad := QuadMesh.new()
	quad.size = Vector2(cfg.exhaust_flame_width_m, cfg.exhaust_flame_length_m)
	# Lay the quad's up-axis along +Z, then push it back so its ROOT is at the pipe.
	var lie_down := Basis(Vector3.RIGHT, PI * 0.5)
	var half := Vector3(0.0, 0.0, cfg.exhaust_flame_length_m * 0.5)
	for turn in [0.0, PI * 0.5]:
		var mesh := MeshInstance3D.new()
		mesh.mesh = quad
		mesh.material_override = _material
		mesh.transform = Transform3D(Basis(Vector3.BACK, turn) * lie_down, half)
		# Never cast or receive shadows — it is emissive geometry, and a flame-shaped
		# shadow under the car would be an obvious artefact.
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mesh)
	return holder


# The car's per-car pipe placements (xyz position + w yaw in degrees), falling back to the
# config-derived pair when the car doesn't expose any (e.g. a bare stub in a test). Static
# so the fallback path is testable without building a rig.
static func pipe_points(car: Node, cfg: GameConfig) -> PackedVector4Array:
	if is_instance_valid(car) and car.get("exhaust_locals") != null:
		var pipes: PackedVector4Array = car.exhaust_locals
		if not pipes.is_empty():
			return pipes
	return cfg.exhaust_locals_for({})


# --- Frame generation -------------------------------------------------------


# Build the flame frames as textures, drawn from the config rather than loaded from disk.
# Generated rather than authored so the shape stays tunable (and F8-reloadable) and
# nothing ships in the PCK; the cost is a handful of small images built once per setup.
#
# Texture space: +V (image top) is the flame TIP, so it maps onto the quad's up-axis and
# therefore onto the car's rearward +Z. Row 0 is the tip, the last row is the pipe mouth.
static func build_frames(cfg: GameConfig) -> Array[ImageTexture]:
	var out: Array[ImageTexture] = []
	var count := maxi(1, cfg.exhaust_flame_frames)
	var size := maxi(8, cfg.exhaust_flame_texture_px)
	for i in count:
		var rng := RandomNumberGenerator.new()
		# Seeded per frame index, so the same config always yields the same frames — the
		# variation between them is authored, not a per-run accident.
		rng.seed = hash("exhaust_flame_%d" % i)
		out.append(ImageTexture.create_from_image(_draw_frame(cfg, size, rng)))
	return out


static func _draw_frame(cfg: GameConfig, size: int, rng: RandomNumberGenerator) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	# Per-frame variation: a slightly different length, a different lateral wander and a
	# different wobble frequency. Without this the "animation" is four identical frames.
	var reach := rng.randf_range(0.82, 1.0)
	var phase := rng.randf_range(0.0, TAU)
	var freq := rng.randf_range(1.6, 3.2)
	var wobble: float = cfg.exhaust_flame_wobble
	var hot: Color = cfg.exhaust_flame_color_hot
	var cool: Color = cfg.exhaust_flame_color_cool
	var core_frac: float = clampf(cfg.exhaust_flame_core_fraction, 0.0, 1.0)
	for y in size:
		# along: 0 at the pipe mouth (bottom row), 1 at the tip (top row).
		var along := 1.0 - float(y) / float(size - 1)
		if along > reach:
			continue  # this frame's flame is shorter than the texture
		var t := along / maxf(reach, 1e-5)  # 0..1 along THIS frame's flame
		# Teardrop profile: a real mouth width at the root, widest a third of the way
		# along, tapering to nothing at the tip.
		var half_w := (0.30 + 0.70 * sin(pow(t, 0.6) * PI)) * (1.0 - pow(t, 2.2)) * 0.5
		if half_w <= 0.0:
			continue
		# The flame wanders more the further it gets from the pipe, which is what sells
		# the flicker between frames — the root stays pinned to the pipe.
		var centre := 0.5 + sin(t * PI * freq + phase) * wobble * t
		for x in size:
			var dx := (float(x) / float(size - 1)) - centre
			var edge := absf(dx) / half_w
			if edge >= 1.0:
				continue
			# Soft edges and a fade toward the tip, so the flame dissolves rather than
			# ending in a hard cut.
			var alpha := pow(1.0 - edge, 1.6) * pow(1.0 - t, 0.55)
			var col := hot.lerp(cool, t)
			# White-hot core near the pipe, where combustion is hottest.
			if edge < core_frac and t < 0.55:
				col = col.lerp(Color.WHITE, (1.0 - edge / maxf(core_frac, 1e-5)) * (1.0 - t / 0.55))
			img.set_pixel(x, y, Color(col.r, col.g, col.b, alpha * col.a))
	return img


# --- Per-frame --------------------------------------------------------------


func _physics_process(delta: float) -> void:
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"exhaust_flames", Time.get_ticks_usec() - __t)


func _timed_physics_process(delta: float) -> void:
	if not Config.data.exhaust_flames_enabled:
		_set_lit(false)
		return
	var cfg: GameConfig = Config.data
	if _follow_car and is_instance_valid(_car):
		global_transform = _car.global_transform
	# Any new limiter cut re-arms the hold; holding the trigger down (a limiter bounce)
	# therefore keeps re-lighting rather than queueing.
	if _consume_new_cuts():
		_burn_timer = cfg.exhaust_flame_pop_seconds
	elif _burn_timer > 0.0:
		_burn_timer = maxf(_burn_timer - delta, 0.0)
	var lit := _forced or _burn_timer > 0.0 or _nitrous_on()
	_set_lit(lit)
	if lit:
		_advance_frame(delta, cfg)


# True if the engine has banged since last tick.
func _consume_new_cuts() -> bool:
	var eng := _engine()
	var count: int = eng.limiter_cut_count if eng != null else _last_cut_count
	var fresh := count > _last_cut_count
	_last_cut_count = count
	return fresh


func _nitrous_on() -> bool:
	var eng := _engine()
	return eng != null and bool(eng.nitrous_delivering)


# Swap to a DIFFERENT frame every exhaust_flame_frame_seconds. Picking a different one
# (rather than cycling in order) keeps a long nitrous flame from reading as a short
# looping animation, which is the whole reason there is more than one frame.
func _advance_frame(delta: float, cfg: GameConfig) -> void:
	if _frames.size() < 2:
		return
	_frame_timer += delta
	if _frame_timer < maxf(cfg.exhaust_flame_frame_seconds, 1e-4):
		return
	_frame_timer = 0.0
	_frame = next_frame(_frame, _frames.size(), _rng)
	_apply_frame()


# Pick a frame index other than the current one. Pure/static so the "never the same twice
# in a row" rule is testable without building any textures.
static func next_frame(current: int, count: int, rng: RandomNumberGenerator) -> int:
	if count < 2:
		return 0
	var step := rng.randi_range(1, count - 1)
	return (current + step) % count


func _apply_frame() -> void:
	if _material != null and _frame >= 0 and _frame < _frames.size():
		_material.albedo_texture = _frames[_frame]


func _set_lit(lit: bool) -> void:
	for p in _pipes:
		p.visible = lit


# --- Warm-up + readouts ------------------------------------------------------


# Force the flame's shader variant to compile NOW (during track generation, behind the
# loading overlay) instead of on the first bang out on the stage. Auto-discovered by
# world.gd's warm-up pass purely by implementing this pair. Same contract as the particle
# pools, even though this is not one — the pass keys on the methods, not the type.
func warm_up(pos: Vector3) -> void:
	global_position = pos
	_set_lit(true)


func clear_warm_up() -> void:
	_set_lit(false)


# --- Readouts (tests) --------------------------------------------------------


func is_lit() -> bool:
	for p in _pipes:
		if p.visible:
			return true
	return false


func pipe_count() -> int:
	return _pipes.size()


# The local transform of pipe `i`'s rig — its position and, in the basis, its yaw. Lets a
# test assert that an authored angle actually reached the geometry rather than only
# surviving config resolution.
func pipe_transform(i: int) -> Transform3D:
	if i < 0 or i >= _pipes.size():
		return Transform3D.IDENTITY
	return _pipes[i].transform


func frame_count() -> int:
	return _frames.size()


func current_frame() -> int:
	return _frame

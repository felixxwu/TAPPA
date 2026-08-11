extends VehicleBody3D

const CAR_SCENE := preload("res://car.tscn")

# Wheel-cap material: each car's Visual/Tire shows its own wheel.png on the cylinder
# caps (ps1_wheel_tire.gdshader), or a blank dark disc for cars without an authored
# wheel. Built lazily and cached per texture path so a lineup of cars sharing a
# texture reuses one material.
const WHEEL_SHADER := preload("res://shaders/ps1_wheel_tire.gdshader")

# Blender wing meshes (spoiler/splitter) authored inside a car body carry this
# substring in their object name; the glb import preserves the name (sanitizing
# `.`→`_`, so authored names must avoid `.`). They are hidden whenever a body is
# revealed and re-shown only when the aero kit is fitted+enabled. See
# features/aero-parts.md.
const AERO_TAG := "_aero"

var _wheel_mats: Dictionary = {}
# Shared 1×1 near-black texture for the blank hubcap (built once, reused).
static var _blank_wheel_tex: ImageTexture

# Roll+pitch damping for the self-righting assist, as a fraction of
# level_assist_torque per rad/s of tilt rate. Scales off the same knob so the
# inspector keeps a single strength control while the aid still settles to level
# instead of oscillating.
const LEVEL_ASSIST_DAMPING := 0.35

# Yaw-rate damping for the spin-protection assist, as a fraction of
# spin_assist_torque per rad/s of yaw. Scales off the same knob so the
# inspector keeps a single strength control while the recovery still settles
# to the travel direction instead of oscillating.
const SPIN_ASSIST_DAMPING := 0.35


# Contacts the chassis reports per physics tick for the damage model. The car only
# ever touches a few obstacles at once; a small cap keeps contact monitoring cheap.
const MAX_CONTACTS_REPORTED := 8

# Re-emitted from the car's DamageModel when working HP hits 0 (a run DNF). A
# fielded car has already been removed from the save by then; the rally/menu layer
# (features/rally-session.md) listens here. See features/damage.md.
signal wrecked()

var _start_transform: Transform3D
# The GameConfig this car's physics reads/writes. DEFAULTS to the global Config.data
# (so the single active/player car stays wired to the HUD, tuning lift, audio synth
# and save system, which all read Config.data). Non-simulating PROP/display cars (HQ
# car-park lineup, start-line queue, podium) are handed an ISOLATED duplicate via
# use_isolated_config() BEFORE apply_car, so their reshape mutates their own copy and
# can't clobber the active car's engine/gearbox in the shared global. car.gd,
# Drivetrain and EngineSim all read THIS, not Config.data directly. Set before _ready
# builds the drivetrain (or before apply_car, which rebuilds it) so the physics
# captures the right config object; apply_car only mutates fields on it, never
# reassigns, so captured references stay valid.
var config: GameConfig
var drivetrain: Drivetrain
# Per-car HP / attrition state + the handling/power degradation maths
# (features/damage.md). Built in _ready, (re)configured per car in apply_car.
var damage: DamageModel
# Travel speed (m/s) captured at the top of each _physics_process, BEFORE the
# solver runs. _integrate_forces uses THIS as the impact speed, not the post-solve
# state.linear_velocity (which a head-on hit has already arrested to ~0). See
# _integrate_forces for the full rationale.
var _approach_speed := 0.0
# Horizontal pre-solve travel direction (unit, or zero when ~stationary), captured
# alongside _approach_speed for the same reason: it's the direction a felled tree
# should topple, and a head-on hit's post-solve velocity is ~0. See knock_down.
var _approach_dir := Vector3.ZERO
# Full pre-solve velocity vector, captured alongside _approach_speed. _integrate_forces
# subtracts the post-solve state.linear_velocity from it to get the velocity SHED this
# tick (dv), which drives the unified deceleration damage (features/damage.md).
var _approach_velocity := Vector3.ZERO
# Physics ticks during which deceleration damage is suppressed. A reset/teleport zeroes
# the velocity discontinuously, which would read as a huge false dv; reset_to sets this
# so the next couple of ticks don't chip HP. Decremented in _integrate_forces.
var _suppress_impact_frames := 0
# Pending teleport (reset_to). Writing global_transform directly on a RigidBody only
# sticks when done inside the physics step; a reset fired from a signal/idle callback
# (the pause-menu "Reset to track") lands outside it and the physics server overwrites
# the pose next frame. So reset_to just QUEUES the pose and _integrate_forces — the
# authoritative physics-write point — applies it via state.transform. The R-key reset
# already ran inside _physics_process, which is why it always worked.
var _pending_reset := false
var _pending_reset_xform := Transform3D.IDENTITY
var _front_axle := Vector3.ZERO  # local midpoints, computed from wheel rest positions
var _rear_axle := Vector3.ZERO
# Car-local point the engine smoke puffs from (read by EngineSmoke). Its longitudinal
# (Z) component is derived from the car's engine position so smoke leaves from where
# the engine actually sits — a rear-engine car (911) smokes from the tail, a front
# engine from the nose. Lateral/height come from GameConfig.engine_smoke_offset;
# recomputed per spec in _apply_physics_spec. See _compute_engine_smoke_local.
var engine_smoke_local := Vector3.ZERO
var downforce_readouts: Array = []  # [global point, force vector] pairs for the debug overlay
# Combined yaw-assist torque applied this tick (steer assist + spin protection),
# as a signed scalar about the car's up axis (positive = turning the nose left).
# Read by the debug overlay to draw a single left/right assist arrow.
var steer_assist_readout: float = 0.0
var _car_index := -1  # selected CarLibrary entry, or -1 for the untouched baseline
# Per-fielding drivetrain override (0/1/2), or -1 = use the spec's stock drive_mode.
# Set by apply_owned before the drivetrain rebuilds; -1 for free-roam apply_car.
var _owned_drive_override := -1
# Per-fielding COSMETIC wheel-texture override, or "" = use the spec's own wheel
# texture. Set by apply_owned before the wheels are built (same pattern as
# _owned_drive_override); free-roam / prop / opponent fielding via apply_car leaves it
# empty, so unowned cars always show stock wheels. Texture ONLY — wheel radius/width
# always come from the car's own spec. See features/wheel-customization.md.
var _owned_wheel_texture := ""
# The last owned dict applied to this car (apply_owned / live re-derive). Empty
# until fielded from an owned car. Used by set_body_hidden(false) to re-derive
# aero-part visibility after the debug overlay restores the body.
var _last_owned: Dictionary = {}
var _wheel_mounts: Dictionary = {}  # wheel -> authored local mount origin (scene rest pose)
var _debug_overlay: WheelForceDebug  # the wheel-force arrow overlay (toggled by H)

# When true, driver input is ignored and the handbrake is forced on, so the car
# physically holds still (e.g. staged at the start line, or after the finish).
# Set by StageManager; the rest of the simulation (drag, suspension, camera) keeps
# running so the car settles naturally. See todo/stage-start-and-end.md §2.
var controls_locked := false

# When true (set by StageManager on crossing the finish, alongside controls_locked),
# the car brakes itself to a stop: full foot brake + the forced handbrake while it's
# still rolling, then the foot brake releases once stopped. The engine clutch stays
# ENGAGED through the stop so the engine winds down with the braking wheels (the
# auto-clutch opens at standstill), instead of free-revving on the handbrake's open
# clutch. Cleared on re-arm (setup / a car swap). See features/stage.md.
var finish_stop := false

# When true, the handbrake is forced on but driver input is otherwise LIVE — the
# player can rev the engine (the held handbrake opens the clutch, so revs climb
# freely) and steer, then launch the instant the brake releases. Used during the
# countdown so the player can pull away at full revs on GO. Set by StageManager.
var handbrake_locked := false

# Scripted ("AI") control for non-player cars — the start-line queue (scripts/
# start_line.gd) drives the leader/trailer with full physics so they pull away and
# roll up with real suspension load. When true the car ignores global Input and
# drives from these values instead (same axes/sign as the player inputs). Use axis
# locks on the body to keep such a car straight; see start_line.gd.
var ai_controlled := false
var ai_throttle := 0.0    # -1..1, forward positive (brake_reverse..accelerate axis)
var ai_steer := 0.0       # -1..1, left positive (steer_right..steer_left axis)
var ai_handbrake := false

# Replay playback (features/event-replay.md): the standings screen drives the
# car along a ReplayRecorder's frames with the rigid-body solver frozen, while
# the suspension raycasts + effect/audio subsystems stay live on recorded
# signals so the run looks filmed. See begin_replay / end_replay.
# Replay process order (see begin_replay): the car must run its _process BEFORE any
# node that reads its transform in _process — the ReplayCamera and the TerrainManager
# chunk-load focus (`../Car`). Lower priority = runs earlier. Keep this below any such
# observer's priority; if a new observer is ever set below this, it would read a stale
# pose (the historic "terrain loads at the finish while the car drives off" bug).
const REPLAY_PROCESS_PRIORITY := -1000

var replay_playback := false
var _replay: ReplayRecorder = null
var _replay_t := 0.0
var _replay_xform := Transform3D()
var _saved_process_priority := 0

# Kinematic posing: this car's transform is written from OUTSIDE, every frame, by an
# owner that knows where it should be (the rival ghost — features/rival-ghost.md).
# Everything a driven car does to itself must therefore stop.
#
# Deliberately NOT replay_playback, for two reasons the ghost can't work around:
# replay_playback needs a ReplayRecorder (_step_replay early-returns without one, so
# nothing would feed the wheel spin), and it is read outside this file by
# track_progress.gd — a second car asserting it risks corrupting player progress.
#
# The setter owns the process_priority swap so a caller can't forget it: like the replay
# path, the posed car must process EARLY so every observer reads the fresh pose. The
# owner writing the transform sets itself lower still, so the write lands before the
# wheel visuals below rebuild off the car's basis.
var kinematic_pose := false:
	set(value):
		if value == kinematic_pose:
			return
		kinematic_pose = value
		if value:
			_saved_process_priority = process_priority
			process_priority = REPLAY_PROCESS_PRIORITY
		else:
			process_priority = _saved_process_priority
			if drivetrain != null:
				drivetrain.replay_omega = {}
# Project gravity, cached once (never changes at runtime) so the parking-hold path
# doesn't do a string-keyed ProjectSettings lookup every physics frame.
var _default_gravity := Platform.gravity()
# Parking-hold anchor: the horizontal spot the car was standing on when the stiction hold
# engaged, and whether it is currently set. The hold is a damped spring back to this point
# (see _apply_parking_hold); it is dropped the moment the hold disengages so the next stop
# anchors where the car actually ends up.
var _hold_anchor := Vector3.ZERO
var _hold_anchor_set := false
# The heading the car was facing when the hold engaged. The positional anchor above
# says nothing about rotation, so before this existed a held car could be turned by a
# kerb, a steering input or an uneven surface and simply STAY turned — measured at
# 16.6 degrees of drift in two seconds from a single nudge, which is how a car ended
# up pointing the wrong way by the time the countdown reached GO.
var _hold_anchor_yaw := 0.0

func replay_cursor() -> float:
	return _replay_t


# The Gearbox setting (SettingsMenu.gearbox_auto()) as last mirrored onto this car's
# engine, as a tri-state int: -1 = not yet seen, 0 = manual, 1 = auto. An int rather than a
# Variant because this is compared every tick. Only CHANGES are pushed, so nothing else that
# writes `engine.auto` gets clobbered every frame — see _physics_process.
var _gearbox_auto_seen := -1


# True when the human driver's live inputs should be read: not locked (staging/finish),
# not scripted (AI / opponent), not a passive replay ghost. One predicate so a future
# non-driving mode is dead to input in ONE place instead of leaking through each input
# site. (Handbrake has its own held-while-locked semantics and is gated separately.)
func _driver_input_live() -> bool:
	return not controls_locked and not ai_controlled and not replay_playback \
			and not kinematic_pose


# Read a continuous control axis: live player input when the driver is in control,
# otherwise the scripted-AI value (and 0 for an idle non-AI car). Covers the two
# axes gated on _driver_input_live() — throttle and steer. NOTE: is_throttling()
# deliberately does NOT use this; it gates on plain `ai_controlled` (a separate
# predicate, see is_held() above), so keep it out.
func _axis_input(neg: String, pos: String, ai_value: float) -> float:
	return Input.get_axis(neg, pos) if _driver_input_live() else (ai_value if ai_controlled else 0.0)


# True when the car is being deliberately held stationary at the start line — by the
# full staging/finish lock (controls_locked) OR the countdown handbrake-only hold
# (handbrake_locked). This says NOTHING about whether driver input is live: during the
# countdown input IS live (the player revs) yet the car is held, which is exactly why
# this is a SEPARATE predicate from _driver_input_live() (that one keys off
# controls_locked alone). Consumers asking "is the car parked on purpose?" — the
# handbrake resolution and the stuck-watchdog's is_throttling() — must route through
# here so no site re-derives the OR and forgets a term (the countdown-rev stuck-reset
# bug was exactly that drift).
func is_held() -> bool:
	return controls_locked or handbrake_locked

func begin_replay(recorder: ReplayRecorder) -> void:
	_replay = recorder
	_replay_t = 0.0
	_replay_xform = global_transform
	replay_playback = true
	# The physics server will NOT reliably move this body from script (setting
	# global_transform is overridden; a frozen body renders at its freeze pose;
	# body_set_state never synced to the node for other nodes' _process reads).
	# So drive the transform in _process instead (see _process) — that DOES reach the
	# render transform and any node reading the car in _process. The catch is _process
	# ORDER: readers earlier in the tree (the terrain's focus) would read the car
	# before we update it. Force this car to process FIRST (lowest priority) so every
	# observer — camera, terrain focus, renderer — reads the fresh pose. custom_integrator
	# stops gravity/forces so the physics body doesn't fall between our _process writes.
	custom_integrator = true
	_saved_process_priority = process_priority
	process_priority = REPLAY_PROCESS_PRIORITY

func end_replay() -> void:
	replay_playback = false
	_replay = null
	custom_integrator = false
	process_priority = _saved_process_priority
	if drivetrain != null:
		drivetrain.replay_omega = {}



func _ready() -> void:
	# Default to the shared global config unless a spawner already handed this
	# instance an isolated one (see `config` above / use_isolated_config).
	if config == null:
		config = Config.data
	var cfg: GameConfig = config
	_default_gravity = Platform.gravity()
	# Spawn the car spawn_clearance metres above the ground at its xz, so the
	# wheels never start clipping under the terrain regardless of how high the
	# surface is there. This transform is also what reset / car swaps restore.
	_start_transform = global_transform
	_start_transform.origin.y = _ground_height_at(_start_transform.origin) + cfg.spawn_clearance
	global_transform = _start_transform
	mass = cfg.mass
	linear_damp = 0.0  # aero drag below is the only speed-dependent loss
	angular_damp = 0.0  # no passive angular decay — the car keeps its spin mid-air
	# (Godot's implicit default is 0.1; force 0 so a launched car isn't slowed in
	# the air). Grounded rotation is governed by the tire model + steer/spin assists.
	for wheel in find_children("*", "VehicleWheel3D", false):
		# All contact friction is handled by the Drivetrain tire model; the
		# built-in solver only does suspension + raycasts.
		wheel.wheel_friction_slip = 0.0
		_apply_suspension(wheel)
		# Godot caps the suspension force at suspension_max_force (default 6000 N),
		# which is far below what a ~1.5 t car needs to arrest a hard landing — the
		# spring would clip and the chassis would bottom out. Lift the cap well
		# above any real spring+damper force so it never limits the suspension.
		wheel.suspension_max_force = 1_000_000.0
		wheel.wheel_radius = cfg.wheel_radius
		# Remember the authored mount BEFORE physics repaints the wheel transform
		# (the body overwrites origin with connection-point + suspension travel),
		# so car swaps relocate from a clean rest pose, not a drifted one.
		_wheel_mounts[wheel] = wheel.position
		var tire := wheel.get_node_or_null("Visual/Tire") as MeshInstance3D
		if tire != null and tire.mesh != null:
			tire.mesh = tire.mesh.duplicate()
	# Chassis/Cabin boxes and each wheel's Tire are authored as shared
	# sub-resources in car.tscn (so apply_car's resize covers, e.g., all four
	# wheels at once) — but that sharing also spans
	# every INSTANCE of car.tscn by default. In an event, start_line.gd spawns
	# extra car instances (queue props) that call apply_car() too; without the
	# per-instance copies above/below, whichever car resizes last corrupts every
	# other instance's chassis/cabin/wheel visuals (size, radius, width) until that
	# instance happens to get
	# its own copy too. Duplicate Chassis/Cabin meshes here as well, once per
	# instance, before anyone can mutate the shared originals.
	var chassis_mesh := $Chassis as MeshInstance3D
	if chassis_mesh.mesh != null:
		chassis_mesh.mesh = chassis_mesh.mesh.duplicate()
	var cabin_mesh := $Cabin as MeshInstance3D
	if cabin_mesh.mesh != null:
		cabin_mesh.mesh = cabin_mesh.mesh.duplicate()
	# The chassis collision BoxShape3D is a shared sub-resource too (car.tscn
	# shape_chassis). _apply_body_meshes now swaps in a per-instance
	# ConvexPolygonShape3D (the chamfered-octagon hull), which is inherently isolated,
	# but a car instance that never gets apply_car'd keeps this scene default — so
	# duplicate it once here too. Without a per-instance copy, a start-line queue
	# prop's apply_car() could otherwise stomp the player's HITBOX (the meshes above
	# are isolated, so the car still LOOKS right but collides at the wrong size).
	var collision := $CollisionShape3D as CollisionShape3D
	if collision.shape != null:
		collision.shape = collision.shape.duplicate()
	drivetrain = Drivetrain.new(self)
	drivetrain.terrain = _resolve_terrain()
	# Read per-contact impulses in _integrate_forces (used by the damage model to
	# turn obstacle hits into HP loss). The chassis hull is the only solid shape —
	# the wheels are raycasts — so this reports chassis-vs-world contacts only.
	contact_monitor = true
	max_contacts_reported = MAX_CONTACTS_REPORTED
	# Damage state: unbound (free-roam) until a car is applied / fielded. apply_car
	# fills in the per-car max HP; this keeps the baseline car sane on its own.
	damage = DamageModel.new()
	damage.field(damage.max_hp, damage.max_hp)
	damage.wrecked.connect(_on_wrecked)
	_debug_overlay = WheelForceDebug.new(self)
	_debug_overlay.visible = cfg.debug_wheel_forces
	add_child(_debug_overlay)
	_recompute_axles()
	# Baseline emit point until a car spec is applied: the raw config offset.
	engine_smoke_local = cfg.engine_smoke_offset




# First sibling exposing `method` (the Floor in the main scene; null on the flat
# test fixtures). Shared by the terrain lookups below.
func _sibling_with_method(method: String) -> Node:
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling != self and sibling.has_method(method):
				return sibling
	return null


# Terrain surface height at a world position, used to seat the spawn above the
# ground. Looks for a sibling that exposes height_at (the hilly Floor in the
# main scene); on the flat test fixtures (a WorldBoundary at y=0) there is none,
# so it falls back to 0.
func _ground_height_at(pos: Vector3) -> float:
	var floor_node := _sibling_with_method("height_at")
	return floor_node.height_at(pos.x, pos.z) if floor_node != null else 0.0


# The terrain that resolves per-wheel surface grip, found as the sibling exposing
# surface_at. Null on the flat test fixtures, where the drivetrain then leaves every
# wheel on the base μ.
func _resolve_terrain() -> Node:
	return _sibling_with_method("surface_at")


# Axle midpoints for the downforce application points, classified the same way
# the drivetrain splits the wheels: use_as_traction = rear. Recomputed after a
# car swap moves the wheels.
func _recompute_axles() -> void:
	_front_axle = Vector3.ZERO
	_rear_axle = Vector3.ZERO
	var fronts: Array[Vector3] = []
	var rears: Array[Vector3] = []
	for wheel in find_children("*", "VehicleWheel3D", false):
		(rears if wheel.use_as_traction else fronts).append(wheel.position)
	for p in fronts:
		_front_axle += p / fronts.size()
	for p in rears:
		_rear_axle += p / rears.size()


func _process(delta: float) -> void:
	# Apply the recorded pose in the RENDER context. This is the one place a script
	# transform write reaches the render transform and every node that reads this car
	# in _process. begin_replay sets process_priority very low so THIS runs before the
	# terrain focus + camera each frame, so they all read the fresh pose (not a stale
	# one from before this update). _step_replay (physics tick) computes _replay_xform.
	if replay_playback:
		global_transform = _replay_xform
		# Spin the wheel meshes from the recorded per-wheel omega. drivetrain.step()
		# (which normally advances the visual spin) does NOT run during replay, so the
		# wheels would sit dead-still without this. Done here, after the transform is
		# applied, so the wheel visuals rebuild off the fresh car basis.
		if drivetrain != null:
			drivetrain.replay_spin(delta)
	elif kinematic_pose:
		# Same wheel-spin problem, different pose source: the owner writes this car's
		# transform (at a lower process_priority, so it has already landed this frame) and
		# fills drivetrain.replay_omega from the pace profile's speed. drivetrain.step()
		# does not run in this mode either, so without this the ghost would slide down the
		# road on four dead wheels.
		if drivetrain != null:
			drivetrain.replay_spin(delta)


# Soft-hazard water predicate, wired by world.gd from the LakeField: takes the
# chassis world position and returns whether it's in a lake. Empty ⇒ no water.
var _water_query: Callable = Callable()

func set_water_query(q: Callable) -> void:
	_water_query = q


func _physics_process(delta: float) -> void:
	if _audio_build_pending:
		# Cleared first so this warns ONCE, not every tick.
		_audio_build_pending = false
		push_warning("car.gd: fielded with apply_car(rebuild_audio=false) and no follow-up "
			+ "_reconfigure_engine_audio() — this car's engine voice was never built. "
			+ "Call fit_engine() (props) or apply_owned() (owned cars).")
	if replay_playback:
		_step_replay(delta)
		return
	if kinematic_pose:
		# Nothing to simulate: position comes from the owner, and running the drivetrain /
		# engine / stuck-and-water watchdogs on a teleported body produces garbage (and, in
		# the watchdogs' case, spurious resets).
		return
	var __t := Time.get_ticks_usec()
	_timed_physics_process(delta)
	PerfLog.track(&"car", Time.get_ticks_usec() - __t)


func _timed_physics_process(delta: float) -> void:
	var cfg: GameConfig = config
	# Capture the pre-solve travel speed for _integrate_forces' damage keying — this
	# runs before the physics solver, so it still holds the true approach speed even
	# on a head-on hit the solver is about to arrest. See _integrate_forces.
	_approach_speed = linear_velocity.length()
	_approach_velocity = linear_velocity
	var horiz := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	_approach_dir = horiz.normalized() if horiz.length_squared() > 0.0001 else Vector3.ZERO
	var engine := drivetrain.engine
	# Discrete gear/mode actions only respond when controls are unlocked, so the
	# player can't shift or change mode mid-countdown. Scripted cars never read them.
	# Hoisted: both the nitrous read below and the discrete-action block need it, and it was
	# being evaluated twice per tick.
	var input_live := _driver_input_live()
	# Nitrous is a HELD input (left Shift / controller X), unlike the discrete gear and
	# mode actions — so it reads is_action_pressed every tick and is cleared whenever the
	# driver isn't live, so a countdown or a scripted car can never be spraying.
	engine.nitrous_active = input_live and Input.is_action_pressed("nitrous")
	if input_live:
		# Transmission mode is a SETTING now (Settings -> Gearbox), not the old
		# `toggle_gearbox` (T) runtime flip — T was unreachable on touch and on a
		# controller. Mirror it onto the engine when it CHANGES (including the first live
		# tick), not every tick: that applies a pause-menu change mid-run while leaving
		# anything else that sets `engine.auto` (a scripted car, a test) alone.
		var want_auto := 1 if SettingsMenu.gearbox_auto() else 0
		if want_auto != _gearbox_auto_seen:
			_gearbox_auto_seen = want_auto
			engine.auto = want_auto == 1
		if not engine.auto:
			if Input.is_action_just_pressed("shift_up"):
				engine.request_shift(1)
			if Input.is_action_just_pressed("shift_down"):
				engine.request_shift(-1)

	var speed := linear_velocity.length()
	# Resolve the continuous driver controls (throttle/brake split, driven
	# direction, foot brake, handbrake, clutch) into the drivetrain step inputs.
	# Read the steering axis before resolving the pedals: longitudinal effort and cornering
	# spend ONE friction budget, so _resolve_drive_inputs needs the steering demand to
	# arbitrate between them (see longitudinal_demand_scale). steer_input keeps the sign.
	var steer_input := _axis_input("steer_right", "steer_left", ai_steer)
	var steer_demand := absf(steer_input)
	var inputs := _resolve_drive_inputs(engine, speed, steer_demand)
	var drive: float = inputs["drive"]
	var brake_input: float = inputs["brake_input"]
	var handbrake: bool = inputs["handbrake"]
	var declutch: bool = inputs["declutch"]

	# Stiction hold: a fully-pinned axle (handbrake or the low-speed parking brake)
	# should stop the car creeping down a slope. Reads `pinned` — the driver's brake demand
	# BEFORE the grip arbitration scaled it — so holding brake AND steering at a standstill
	# still anchors the car. See _resolve_drive_inputs and _apply_parking_hold.
	_apply_parking_hold(handbrake or bool(inputs["pinned"]), speed, delta)
	# Damage misfire: feed the engine its misfire intensity so it cuts fuel in
	# stumbling bursts once HP falls below the health threshold (0 = healthy, never
	# cuts; ramps to 1 at 0 HP). See features/damage.md.
	engine.misfire_level = damage.misfire_level(cfg)
	# The H-key debug-arrow toggle is handled HERE, before the step, rather than in the
	# overlay: the overlay is a child (runs after this parent), so flipping visibility
	# there would lag the drivetrain's readout gate by a frame and the arrows would draw
	# in empty on the frame they're toggled on. Dev-only, so gated to debug builds.
	if _debug_overlay != null and OS.is_debug_build() \
			and Input.is_action_just_pressed("toggle_debug_arrows"):
		_debug_overlay.visible = not _debug_overlay.visible
		# Hide the car body while the overlay is up so the (slightly smaller) hitbox
		# hull isn't obscured; restore it when the overlay is dismissed.
		set_body_hidden(_debug_overlay.visible)
	# Tell the drivetrain whether to build its per-wheel force readouts, decided BEFORE
	# the step so this frame's forces are captured and appear the same frame the overlay
	# turns on.
	drivetrain.publish_readouts = _debug_overlay != null and _debug_overlay.visible
	drivetrain.step(delta, drive, brake_input, handbrake, declutch)

	# Quadratic aero drag + speed-squared per-axle downforce (and the debug readout).
	_apply_aero()

	# Servo the front wheels onto the commanded share of their available grip, then lay
	# the damage toe on top. Runs AFTER drivetrain.step() so it closes its loop on this
	# tick's own tire measurements — see _update_steering.
	_update_steering(delta, steer_input, steer_demand)
	# Slide-recovery aid: pulls the nose back once the car has rotated past
	# spin_assist_angle from its travel direction. Sets the assist readout. Its own 2 m/s
	# forward-motion floor lives in _chassis_slip_angle, which returns 0 below it — that
	# replaces the speed fade the deleted understeer assist used to share.
	_apply_spin_protection(_chassis_slip_angle(), handbrake)
	# Self-righting assist while any wheel is airborne.
	_apply_level_assist()


# Drive the body along the recording (looping) and pin the state the effect +
# audio systems read, so gravel/smoke/engine-note replay in sync. The frozen
# kinematic body ignores forces, so we set its pose directly; wheels keep their
# live suspension raycasts (contact + compression) but read recorded steer/omega.
func _step_replay(delta: float) -> void:
	if _replay == null or _replay.frame_count() == 0:
		return
	var dur := _replay.duration()
	_replay_t += delta
	if dur > 0.0 and _replay_t > dur:
		_replay_t = fmod(_replay_t, dur)   # loop
	var f := _replay.sample_at(_replay_t)
	if f.is_empty():
		return
	# Stash the pose for _process to apply (see _process — the render/_process-order
	# fix). Feed the recorded velocity to the script linear_velocity so effects that
	# read it (tire_marks speed gate) see the real speed.
	_replay_xform = f["xform"]
	linear_velocity = f["velocity"]
	# Pin the engine note + smoke to the recorded engine state. engine.step() does NOT
	# run during replay, so besides rpm/throttle/misfire we must neutralise the ducking
	# state the audio synth reads (fuel_cut, limiting, boost, turbo, shift, blow-off,
	# antilag) — otherwise it stays frozen at whatever the car was doing when it crossed
	# the finish (usually braking / rev-limiting), muffling the note for the whole replay
	# and only sounding right near the end. The result is a clean rev tracking the
	# recorded rpm; turbo whistle/backfire nuance is dropped (acceptable for the replay).
	if drivetrain != null and drivetrain.engine != null:
		var eng: EngineSim = drivetrain.engine
		eng.omega = f["rpm"] * TAU / 60.0
		eng.throttle = f["throttle"]
		eng.misfire_level = f["misfire"]
		eng.fuel_cut = false
		eng.limiting = false
		eng.boost = 0.0
		eng.omega_turbo = 0.0
		eng.bov_event = false
		eng.antilag_active = false
		eng.shift_timer = 0.0
	# Recorded per-wheel steer (incl. damage toe) + omega for visuals + effects.
	# all_wheels is the drivetrain's cached front+rear list (same order the
	# ReplayRecorder samples in), iterated here to avoid allocating a fresh
	# `front_wheels + rear_wheels` Array each replay frame.
	var wheels := drivetrain.all_wheels if drivetrain != null else []
	# Reused scratch dict (cleared + refilled in place) rather than a fresh
	# Dictionary per replay frame — same no-allocation reasoning as all_wheels
	# above. Nothing retains a replay_omega reference across frames: drivetrain
	# only reads it inside the same tick, and end_replay swaps in a fresh {}.
	_replay_omega_scratch.clear()
	for i in wheels.size():
		var w: VehicleWheel3D = wheels[i]
		if i < f["wheel_steer"].size():
			w.steering = f["wheel_steer"][i]
		if i < f["wheel_omega"].size():
			_replay_omega_scratch[w] = f["wheel_omega"][i]
	if drivetrain != null:
		drivetrain.replay_omega = _replay_omega_scratch


# Reusable return buffer for _resolve_drive_inputs — filled and returned every
# physics tick so it allocates no Dictionary. The sole caller unpacks all four
# fields immediately.
var _replay_omega_scratch := {}

var _inputs_scratch := {
	"drive": 0.0, "brake_input": 0.0, "handbrake": false, "declutch": false, "pinned": false,
}

# Resolve the driver's continuous controls into the drivetrain step's inputs: the
# throttle/brake pedal split, the driven direction (drive), foot brake, handbrake
# and clutch (declutch). Handles the automatic vs manual gearbox logic and the
# locked / scripted-AI / finish-stop special cases. Returns
# {drive, brake_input, handbrake, declutch} (a reused buffer; read it immediately).
func _resolve_drive_inputs(engine, speed: float, steer_demand: float) -> Dictionary:
	# Neutralise driver input while locked; the forced handbrake below holds the
	# car on a slope without freezing the whole simulation.
	var throttle := _axis_input("brake_reverse", "accelerate", ai_throttle)
	var fwd_pedal := maxf(throttle, 0.0)  # W
	var rev_pedal := maxf(-throttle, 0.0)  # S
	var moving_forward := linear_velocity.dot(-global_transform.basis.z) > 1.0
	var drive := 0.0
	var brake_input := 0.0
	# Whether the brake below is a synthesized HOLD (parking brake / finish stop) rather than
	# the driver's pedal. Steering must never bleed a hold off — the car would creep down a
	# slope the moment the player turned the wheel.
	var brake_hold := false
	if engine.auto:
		# Automatic: the box picks forward gears; reverse engages from a stop.
		if rev_pedal > 0.0 and moving_forward:
			brake_input = 1.0  # S brakes while rolling forward, reverses otherwise
		elif rev_pedal > 0.0:
			if engine.select_reverse(drivetrain.rear_omega):
				drive = rev_pedal
			else:
				brake_input = 1.0
		elif fwd_pedal > 0.0:
			if engine.select_forward(drivetrain.rear_omega):
				drive = fwd_pedal
			else:
				brake_input = 1.0
		elif speed < 2.0:
			brake_input = 1.0  # parking brake: hold the car on slopes
			brake_hold = true
		# Shift on actual forward ground speed (wheelspin-immune), not revs.
		engine.update_auto(drive, maxf(linear_velocity.dot(-global_transform.basis.z), 0.0))
	else:
		# Manual: the driver selects R/N/1..N with Q/E. In reverse, S drives
		# back and W brakes; otherwise W drives (neutral just revs the engine).
		if engine.gear < 0:
			drive = rev_pedal
			brake_input = fwd_pedal
		else:
			drive = fwd_pedal
			brake_input = rev_pedal
		if drive < 0.01 and brake_input < 0.01 and speed < 2.0:
			brake_input = 1.0  # parking brake: hold the car on slopes
			brake_hold = true
	var handbrake := ai_handbrake if ai_controlled else (is_held() or Input.is_action_pressed("handbrake"))
	# Declutch normally follows the handbrake (a held handbrake opens the clutch so the
	# engine can rev free — used for launches). The finish stop is the exception.
	var declutch := handbrake
	if finish_stop:
		# Brake to a stop with the foot brake + the forced handbrake, but keep the
		# clutch ENGAGED so the engine engine-brakes down with the wheels (the auto-clutch
		# opens at standstill and the engine settles to idle) rather than free-revving on
		# the open handbrake clutch. Release the foot brake once stopped.
		declutch = false
		brake_input = 1.0 if speed > config.finish_stop_speed else 0.0
		brake_hold = true
	_inputs_scratch["handbrake"] = handbrake
	# Longitudinal effort and cornering spend ONE friction budget on the front tires, and on a
	# keyboard or a touch screen every input is 0% or 100% — so the player cannot express the
	# compromise a progressive pedal allows, and a pinned pedal leaves the steering nothing to
	# work with. Scale the longitudinal side to fit. Done HERE, at the one point that owns the
	# final pedal values, so the synthesized holds below can simply opt out locally instead of
	# exporting a flag for the caller to re-check.
	#
	# The BRAKE always counts, because braking always acts on the steered axle. The THROTTLE
	# counts only when that axle is also driven (FWD/AWD) — on RWD the throttle cannot take
	# cornering grip from the front tires, so it is left alone and power-oversteer behaviour is
	# untouched. The handbrake is excluded either way: it wants the rears to break away while
	# the fronts keep full bite.
	# Whether the axle is PINNED, decided from the driver's demand BEFORE the grip
	# arbitration below scales it. The stiction hold asks "should a stationary car be
	# anchored", and the arbitration exists only to free up CORNERING grip on a moving car —
	# it has nothing to say about that. Deciding it here (rather than letting the caller test
	# the post-scale value) is what stops a player who holds brake AND steering at a
	# standstill from silently losing the anchor and creeping down a slope.
	var pinned := brake_input >= 1.0
	if not brake_hold:
		var front_driven := drivetrain.front_axle_driven()
		var long_scale := longitudinal_demand_scale(
			brake_input + (drive if front_driven else 0.0), steer_demand)
		if long_scale < 1.0:
			brake_input *= long_scale
			if front_driven:
				drive *= long_scale
	_inputs_scratch["drive"] = drive
	_inputs_scratch["brake_input"] = brake_input
	_inputs_scratch["declutch"] = declutch
	_inputs_scratch["pinned"] = pinned
	return _inputs_scratch


# True when the driver is asking for forward throttle — read by TrackProgress' stuck
# watchdog to tell "flooring it and going nowhere" from a car parked on purpose. Mirrors
# the throttle source in _resolve_drive_inputs; false while the car is held at the
# line — controls_locked (staging / post-finish) OR handbrake_locked (the 3·2·1
# countdown, where input is live so the player can rev). Either way the car is
# stationary on purpose and must never read as throttling, or holding the gas
# through the countdown would trip the stuck-car reset. Both holds are folded into
# is_held() so this can't drift to the wrong subset of flags.
func is_throttling() -> bool:
	if is_held():
		return false
	var t := ai_throttle if ai_controlled else Input.get_axis("brake_reverse", "accelerate")
	return t > 0.5


# Quadratic aero drag plus speed-squared downforce at each axle, pressing the body
# down so suspension compression raises wheel normal force (and therefore grip).
# With redline-limited gearing, the drag sets how hard the top of each gear pulls.
func _apply_aero() -> void:
	var cfg: GameConfig = config
	apply_central_force(-linear_velocity * linear_velocity.length() * cfg.drag_coefficient)
	# Soft hazard: extra linear drag while in a lake — the car slows but can drive
	# out (no reset). See features/lakes.md.
	if _water_query.is_valid() and _water_query.call(global_position):
		apply_central_force(-linear_velocity * cfg.water_drag)
	var v2 := linear_velocity.length_squared()
	var down := -global_transform.basis.y
	apply_force(down * v2 * cfg.downforce_front, global_transform.basis * _front_axle)
	apply_force(down * v2 * cfg.downforce_rear, global_transform.basis * _rear_axle)
	_apply_crosswind(cfg)
	# Only build the debug-overlay readout array when the overlay is actually
	# visible — it's the sole consumer (WheelForceDebug, toggled at runtime by H),
	# so the shipped game doesn't allocate it every physics tick.
	if _debug_overlay.visible:
		downforce_readouts = [
			[global_position + global_transform.basis * _front_axle, down * v2 * cfg.downforce_front],
			[global_position + global_transform.basis * _rear_axle, down * v2 * cfg.downforce_rear],
		]


# --- Crosswind (storm) -------------------------------------------------------
# Memoised wind for the current condition, resolved the same way Drivetrain memoises
# its weather μ (`_weather_mu`): re-read only when the weather id or the config object
# changes, never per tick. On a condition with no "wind" block — dry, rain, fog, every
# non-storm stage — `_wind_active` stays false and the per-tick cost is two comparisons
# and a bool test: no dictionary lookup, no allocation, no force. That zero-cost
# default is why nothing here ever tests a condition id by name.
var _wind_active := false
var _wind_strength := 0.0
var _wind_gust := 0.0
var _wind_dir := Vector3.ZERO   # unit world heading, trig done once at resolve time
var _wind_id := "￿"        # sentinel: never a real weather id, so the first tick resolves
var _wind_cfg: GameConfig = null
var _progress: Node = null      # the sibling TrackProgress (distance along the stage)


# A lateral force in a FIXED WORLD direction, so the car is blown off line and has to
# be steered against — not a drag term that rotates with the car. Its magnitude is a
# pure function of DISTANCE ALONG THE STAGE and the event seed (scripts/crosswind.gd),
# so every run of a stage meets the same gust in the same place; see that file's header
# for why leaderboard parity depends on it. Applied here, with the other chassis body
# forces, so it composes with the existing physics instead of fighting it.
func _apply_crosswind(cfg: GameConfig) -> void:
	if cfg.weather != _wind_id or cfg != _wind_cfg:
		_resolve_wind(cfg)
	if not _wind_active:
		return
	# Distance comes from the existing TrackProgress odometer rather than a private one,
	# so the wind is keyed to the same along-track metric the HUD and stage gate use.
	# Not permanently cached when absent: TrackProgress is built after the car exists
	# (world.gd._generate_track), and the flat test fixtures never have one.
	if _progress == null:
		_progress = _sibling_with_method("progress_offset")
		if _progress == null:
			return
	var distance: float = _progress.progress_offset()
	var magnitude := Crosswind.magnitude_at(distance, cfg.track_seed,
		_wind_strength, _wind_gust, cfg.crosswind_gust_wavelength_m)
	# Exposure: a broadside car catches more wind than a nose-on one. Deliberately a
	# constant-ish factor, NOT an occlusion/shelter model (see features/car-physics.md).
	var nose_on: float = cfg.crosswind_nose_on_fraction
	var exposure := nose_on + (1.0 - nose_on) * absf(_wind_dir.dot(global_transform.basis.x))
	apply_central_force(_wind_dir * (magnitude * exposure))


func _resolve_wind(cfg: GameConfig) -> void:
	_wind_id = cfg.weather
	_wind_cfg = cfg
	var wind := Crosswind.wind_params(cfg)
	_wind_active = not wind.is_empty()
	_wind_strength = float(wind.get(Crosswind.STRENGTH_KEY, 0.0))
	_wind_gust = float(wind.get(Crosswind.GUST_KEY, 0.0))
	_wind_dir = Crosswind.direction(float(wind.get(Crosswind.DIR_KEY, 0.0)))


# How much to scale the LONGITUDINAL demand (brake, and throttle on a driven front axle) so
# that it and the steering demand together fit ONE friction budget. 1.0 while the pair is
# inside the circle; below 1.0 once they would exceed it.
#
# Both inputs arrive as 0% or 100% on a keyboard and on the touch controls, so the player
# cannot ask for the partial brake or partial throttle a progressive pedal would give — and
# the steering servo measures what longitudinal slip has ALREADY spent, so a pinned pedal
# leaves nothing for cornering and the car simply refuses to turn in. Scaling the
# longitudinal side is the fix, and it needs no tuning knob: a pedal alone is untouched, and
# a pedal pinned WITH full steering scales to 0.71 — not an invented compromise but the
# actual optimum on a friction circle, and what a driver with progressive pedals does.
#
# Only the LONGITUDINAL side is scaled here. The lateral side is normalised by the servo's own
# lateral_grip_share, against the spend it MEASURES rather than the one requested here, so
# scaling the steering demand a second time would double-count. The two agree by construction:
# both are this same circle normalisation, one in input space and one in measured space.
#
# Trail braking and power-out both fall out for free: as steering winds on the pedal bleeds
# off, and as it unwinds the pedal returns.
#
# Pure and static so the arbitration is testable on its own.
static func longitudinal_demand_scale(long_demand: float, steer_demand: float) -> float:
	var mag := Vector2(long_demand, steer_demand).length()
	return 1.0 / mag if mag > 1.0 else 1.0


# The share of peak front grip the steering servo should ask for laterally, given what the
# front tires are ALREADY spending longitudinally (`long_used`, measured — see
# Drivetrain.front_axle_state). 0..1 of peak.
#
# THE LONGITUDINAL SPEND IS NOT A RESERVATION, and that is the whole point of this function.
# The obvious reading — the driver may have whatever the ellipse has left, `steer_demand *
# sqrt(1 - long_used²)` — is right only while something bounds `long_used` below 1. The pedal
# arbitration above bounds the driver's *request*, but not the spend: the longitudinal force
# a tire must produce is set by the WORLD as much as by the pedal. Climbing a slope, a driven
# front axle spends nearly all of its grip just holding the car up the hill, and on a
# low-grip surface it does so at a fraction of the pedal. The remainder then reads ~0, the
# setpoint collapses with it, and the servo — correctly, by its own maths — concludes there
# is no cornering grip to be had and drives the wheels to the null. The car tracks whichever
# way it is already sliding and the player cannot steer out of it, in EITHER direction. That
# is the FWD/AWD-uphill trap this replaced, and note it is a controller artifact, not
# physics: the tire model itself will happily trade longitudinal force for lateral as the
# wheel turns (that is what the ellipse in _tire_force does), so the grip was there all along
# — the servo just never asked for it.
#
# So treat the two as COMPETING for one circle, exactly as longitudinal_demand_scale already
# treats two pedal demands: if (long_used, steer_demand) lies outside the unit circle, scale
# BOTH onto it. It is literally the same normalisation with the measured spend in place of
# the assumed one, which is why it delegates rather than re-deriving — the two mechanisms
# cannot drift apart.
#
# The guarantee that fixes the trap: the result is never below `steer_demand / sqrt(2)`, so
# the driver keeps ~71% of their asked-for cornering share no matter how much longitudinal
# grip is being spent. Full power on a steep climb becomes a real trade — turn and lose drive,
# or hold the throttle and run wide — instead of a one-way ratchet with no way out.
#
# `long_used` is clamped to 1 before the normalisation. Past peak the tire's friction vector
# is saturated, so further slip does not reserve grip that turning could otherwise have used;
# it only rotates the vector. Without the clamp a wildly spinning front axle would drive the
# authority back toward zero — the same trap, one step removed.
static func lateral_grip_share(steer_demand: float, long_used: float) -> float:
	var spent := clampf(absf(long_used), 0.0, 1.0)
	return steer_demand * longitudinal_demand_scale(spent, steer_demand)


# One tick's correction, in RADIANS, for a usage error in fractions-of-peak.
#
# THERE IS NO GAIN TO TUNE, and that is derived rather than chosen. Requiring that one tick's
# movement never exceed the remaining angular error gives E >= steer_speed * delta / slip_peak
# for a gain divisor E; substituting that bound back in collapses the whole term to exactly
# `error * slip_peak` — the usage error converted into radians, a Newton step of gain 1. It
# self-scales with the surface (gravel's larger slip_peak takes proportionally larger steps)
# and with the frame rate, so there is nothing to mis-set.
#
# The small-angle approximation behind it (slip = sin θ ≈ θ) errs SAFELY: at a 30° slip angle
# in a deep slide the step under-corrects by ~13%, converging slower rather than overshooting.
# Do not "correct" that with a 1/cos term without a reason.
#
# Pure and static because the loop's stability lives entirely in this shape — proportional to
# the error (so it cannot dither at the setpoint), zero at zero error, and sign-reversing on
# overshoot — and that is testable without a car or a physics tick.
static func grip_servo_step(usage_error: float, slip_peak: float) -> float:
	return usage_error * slip_peak


# The yaw of the car's TRAVEL direction relative to its nose (radians, positive left), or 0
# when the car is slower than 2 m/s or not travelling nose-forward. Only the spin-protection
# aid reads this — the steering servo uses each front wheel's OWN slip angle instead, which
# is the fix for the chassis-referenced steering this replaced (the front axle's velocity
# direction differs from the centre of mass's by the yaw-rate term).
#
# The 2 m/s floor is what keeps spin protection out of low-speed manoeuvring, replacing the
# speed fade it used to share with the deleted understeer assist.
func _chassis_slip_angle() -> float:
	# transposed(), not inverse(): a rigid body's basis is orthonormal (this node is
	# never scaled), so the transpose IS the inverse — and it skips the determinant
	# + cofactor work inverse() does, every physics tick.
	var local_vel := global_transform.basis.transposed() * linear_velocity
	# length_squared against 2 m/s squared: the threshold does not need the sqrt.
	if Vector2(local_vel.x, local_vel.z).length_squared() <= 4.0 or local_vel.z >= 0.0:
		return 0.0
	return atan2(-local_vel.x, -local_vel.z)


# Steer the front wheels by SERVOING THE MEASURED GRIP the tires are using, rather than
# pointing them at an angle derived from the input. `steer_demand` is the 0..1 share of the
# front tires' available cornering grip the driver is asking for (already through
# share_friction_demand); `steer_input` carries only the direction.
#
# The system this replaced was open-loop and systematically left grip unused: it capped the
# wheel angle at a PREDICTED limit (from cfg.steer_limit and a nominal surface slip_peak),
# referenced the CHASSIS slip angle rather than each front wheel's, and followed only
# steer_travel_alignment (0.8) of the travel direction. Front tires would sit at ~80% of
# peak while the player asked for everything, which reads as understeer with grip in
# reserve. Nothing here predicts the limit; it is measured and converged on.
#
# THE ZERO POINT. There is exactly one wheel angle at which the front tires do no sideways
# work: pointing them along the direction they are already travelling. Every command is
# measured out from there, which is why countersteer needs no rule of its own — releasing
# the wheel targets the null, the tires stop being asked for side force, and the slide
# catches. It also makes the controller STATELESS: the current offset from the null is just
# |slip_angle|, re-measured every tick, so there is no integrator to store or wind up. The
# wheel angle IS the integrator.
#
# THE SETPOINT IS A LATERAL SHARE, not a share of total usage: the wheel angle only moves the
# lateral component, so charging the driver for longitudinal spend would mean a pinned brake
# (or full throttle on a FWD car) turns a request of 60% into negative error and drives the
# wheels straight. It is compared against front_axle_state's measured `lat_used`, which is
# tire-model maths and so lives in the drivetrain.
#
# How much of the circle the lateral side may claim is `lateral_grip_share` — the SAME
# normalisation longitudinal_demand_scale applies to two pedal demands, with the MEASURED
# longitudinal spend standing in for the assumed one. Read it before changing anything here:
# it is what keeps a driven front axle steerable when the world (a climb, a slick surface),
# rather than the pedal, is what is spending the grip.
#
# THE STEP is grip_servo_step(error) — see there for why it carries no gain.
#
# cfg.steer_speed appears exactly once, as the rate limit — the model of how fast
# a hand can turn the wheel, and the only rate in the system. Because it now only has to
# cover the slip angle (~8.6° on tarmac) rather than most of full lock, it is the dominant
# feel parameter; expect to retune it DOWNWARD in config/game_config.tres.
func _update_steering(delta: float, steer_input: float, steer_demand: float) -> void:
	var cfg: GameConfig = config
	var front := drivetrain.front_axle_state(cfg)
	var target := 0.0
	if not bool(front["in_contact"]) or float(front["slip_peak"]) <= 0.0:
		# Nothing to servo on: no front wheel is on the ground. Fall back to mapping the
		# input straight onto the wheel angle — holding the last angle instead would freeze
		# the wheels mid-jump, which players read as a bug.
		target = steer_input * cfg.steer_limit
	else:
		var slip_peak: float = front["slip_peak"]
		var slip_angle: float = front["slip_angle"]
		# The null: point the wheels along their own travel and lateral slip goes to zero.
		var null_angle: float = steering + slip_angle
		if steer_demand <= cfg.steer_deadzone:
			# NOT "minimise usage" — that has no unique solution, since a driven front axle
			# under power never reaches zero COMBINED usage. The null is defined by LATERAL
			# slip alone, which does reach zero at any throttle setting.
			#
			# But "along the direction of travel" is UNDEFINED at rest, and the degenerate
			# answer is a fixed point: atan2(0, 0) is 0, so the null equals the current angle
			# and released wheels would simply stay wherever they were left, cocked. As the
			# reference speed vanishes the travel direction degenerates to the car's own
			# forward axis, so fade the null toward straight ahead. Below the floor the raw
			# angle is also dominated by suspension jitter, and this multiplies that away.
			#
			# The threshold is tire_norm_floor — the SAME speed at which the tire model itself
			# stops treating slip as meaningful (Drivetrain._tire_force) — so this is the
			# existing physical floor applied consistently, not a new steering exception. It is
			# deliberately confined to THIS branch: the demand branch below needs no travel
			# reference to push further from where it already is, and pinning its null would
			# stop it walking out to full lock at a standstill.
			var travel := 1.0
			if cfg.tire_norm_floor > 0.0:
				travel = clampf(absf(float(front["v_long"])) / cfg.tire_norm_floor, 0.0, 1.0)
			target = null_angle * travel
		else:
			# Both sides are fractions of peak grip, and the drivetrain measured them — the
			# lateral budget already accounts for what braking or driving has spent.
			var setpoint: float = lateral_grip_share(steer_demand, float(front["long_used"]))
			var step: float = grip_servo_step(setpoint - float(front["lat_used"]), slip_peak)
			# null_angle anchors this branch too, not just the centring one: the target is the
			# null plus the offset the tires should be at. slip_angle appears twice on purpose —
			# once inside null_angle with its own sign, once as the CURRENT offset magnitude the
			# step adds to — so expanding gives steering + step when the wheel is already on the
			# commanded side, and a jump across the null when it is not (a flick from full right
			# to full left goes the right way immediately instead of crawling).
			target = null_angle + signf(steer_input) * (absf(slip_angle) + step)
	steering = clampf(
		move_toward(steering, target, cfg.steer_speed * delta),
		-cfg.steer_limit, cfg.steer_limit)
	# Damage wheel misalignment: bend each wheel physically by its persisted toe on
	# TOP of the base steer. The pull/crab of a damaged car then comes from the
	# physics alone — the drivetrain tire model reads wheel.steering for the force
	# direction (and the wheel visual off it too). No synthetic steer bias.
	#
	# The toe is INSIDE the servo loop by construction: the drivetrain measures slip in the
	# toed wheel's frame, so the servo sees a bent front axle's lateral slip as error and
	# corrects it — exactly as a real driver holds a correction on a car with bent alignment,
	# which then tracks straight with the wheel visibly off-centre. Of the four wheels
	# DamageModel.nudge_wheels bends (independent random sign each), the servo can only reach
	# the symmetric front component: REAR toe is beyond its authority, and a front pair bent
	# in opposite directions nets out of the load-weighted average. So a damaged car still
	# crabs and scrubs. See features/damage.md.
	_apply_wheel_toe()


# Spin protection: once the car has rotated further than spin_assist_angle away
# from its direction of travel, a corrective yaw torque pulls the nose back toward
# the travel direction. slip_angle's sign points toward the travel direction
# (positive left), so torquing along sign(slip_angle) always rotates the nose back.
# Ramps in linearly from 0 at the threshold to full at twice it, and carries a yaw-rate
# damping term so the slide settles instead of oscillating nose-side-to-side. Suppressed
# while the handbrake is held, so deliberate handbrake drifts stay possible.
#
# OFF BY DEFAULT: spin_assist_torque ships at 0.0, so this whole function is inert unless
# something raises it. That is deliberate — the grip servo, a lowered centre of mass
# (GameConfig.com_height) and the grounded anti-roll bar (level_assist_grounded) keep the car
# recoverable through tyre physics instead of scripted yaw torque. Kept because it is still
# the only thing that addresses the case the servo cannot: a player who holds steering INTO a
# slide until the car rotates past recovery. Do not delete it on the grounds of being unused.
#
# Low-speed manoeuvring is kept clear by _chassis_slip_angle's own 2 m/s forward-motion
# floor — it returns 0 below that, and 0 past 90° / when reversing — which replaces the
# speed fade this used to share with the deleted understeer assist. The aid prevents
# reaching a spin; it doesn't unwind a completed one.
func _apply_spin_protection(slip_angle: float, handbrake: bool) -> void:
	var cfg: GameConfig = config
	# Reset the readout each tick (the deleted steer assist used to own this).
	steer_assist_readout = 0.0
	if cfg.spin_assist_torque > 0.0 and cfg.spin_assist_angle > 0.0 and not handbrake:
		var excess := absf(slip_angle) - cfg.spin_assist_angle
		if excess > 0.0:
			var spin_scale := clampf(excess / cfg.spin_assist_angle, 0.0, 1.0)
			var up := global_transform.basis.y
			var yaw_rate := angular_velocity.dot(up)
			var spin_assist_yaw := spin_scale * cfg.spin_assist_torque \
				* (signf(slip_angle) - yaw_rate * SPIN_ASSIST_DAMPING)
			apply_torque(up * spin_assist_yaw)
			steer_assist_readout += spin_assist_yaw


# Self-righting assist: ease the chassis back toward level. up × reference_up is
# the roll+pitch axis that rotates the car's up toward the reference — it is
# perpendicular to the car's own up, so it adds no yaw — and its length is
# sin(tilt), so the correction grows the further the car is from flat (peaking
# near 90°). A damping term opposing the roll+pitch angular velocity (the yaw
# component, about the car's own up, is left free) keeps it from overshooting
# level and wobbling.
#
# Two regimes, sharing one strength knob:
#
# * AIRBORNE (any wheel off the ground) — full level_assist_torque, referenced to
#   WORLD up. A landing / anti-flip aid: it wants the car flat to the world,
#   because that's the attitude that lands on four wheels.
# * GROUNDED (all four planted) — level_assist_torque × level_assist_grounded,
#   referenced to the average wheel CONTACT NORMAL. Here it behaves like an
#   anti-roll bar: it resists cornering roll and braking dive, and stands the car
#   back up on its springs. Referencing the surface (not world up) is what keeps
#   it from fighting a cambered corner or an off-camber verge, where levelling to
#   the world would mean a permanent torque trying to peel the car off the slope.
#   With level_assist_grounded = 0 (the script default) this regime is inert and
#   the aid is airborne-only, as it originally was.
func _apply_level_assist() -> void:
	var cfg: GameConfig = config
	if cfg.level_assist_torque <= 0.0:
		return
	var strength := cfg.level_assist_torque
	var reference_up := Vector3.UP
	if not _any_wheel_airborne():
		strength *= cfg.level_assist_grounded
		if strength <= 0.0:
			return
		reference_up = _ground_normal()
	var up := global_transform.basis.y
	var roll_pitch_rate := angular_velocity - up * angular_velocity.dot(up)
	apply_torque(
		up.cross(reference_up) * strength
		- roll_pitch_rate * strength * LEVEL_ASSIST_DAMPING
	)


# Average contact normal of the wheels currently touching the ground — the
# "up" of the surface the car is standing on, which the grounded level assist
# levels to instead of world up. Falls back to world up if nothing is in
# contact or the normals cancel out.
func _ground_normal() -> Vector3:
	var sum := Vector3.ZERO
	for wheel in drivetrain.all_wheels:
		if wheel.is_in_contact():
			sum += wheel.get_contact_normal()
	if sum.is_zero_approx():
		return Vector3.UP
	return sum.normalized()


# The unified damage tick + the (decoupled) object-reaction pass. Runs every physics
# frame. contact_monitor + max_contacts_reported are enabled in _ready.
#
# DAMAGE is global and contact-free: HP loss is keyed to how much velocity the body
# shed this tick — `_approach_velocity` (cached at the top of _physics_process, BEFORE
# the solver) minus the post-solve `state.linear_velocity`. Godot resolves collisions
# (and, on a head-on hit, arrests the body) BEFORE _integrate_forces sees the state, so
# that difference IS the impact's velocity loss — a wall, a tree, a cliff face, a
# nose-first drop, or a soft drag impulse, no matter WHAT (if anything) the contact loop
# reports. Everyday driving, braking and clean wheel-landings stay under the
# braking-proof threshold in register_deceleration. See features/damage.md.
#
# REACTIONS (felling / knock-over) still need to know WHICH object was hit, so they
# stay contact-driven here — but on their own speed thresholds; they no longer touch HP.
# They now run BEFORE the damage measurement: felling a small tree restores some of the
# arrested forward momentum (a central, torque-free impulse — the solver's off-center
# spin survives), so the post-restore velocity is what the deceleration damage keys off.
func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	# The replay ghost is positioned via the physics server (see _step_replay); it must
	# take no damage and fell no trees — the per-frame reposition would otherwise read
	# as a huge deceleration and "wreck" it (wreck screen / spurious DNF).
	# A kinematically posed car (the rival ghost) is moved the same way and needs the same
	# immunity — otherwise chasing it would rack up damage on a car that isn't driving.
	if replay_playback or kinematic_pose:
		return
	# Apply a queued reset_to teleport here — the physics-authoritative write point. Setting
	# state.transform makes the pose stick regardless of which frame phase reset_to was
	# called from (a menu/signal callback runs outside the physics step, where a plain
	# global_transform write gets overwritten by the server's ongoing integration). Only
	# the POSE is re-asserted here; reset_to already zeroed the velocities immediately, and
	# re-zeroing them a frame late would clobber any velocity legitimately set after the
	# reset. Impact damage is suppressed for the teleport's discontinuity.
	if _pending_reset:
		_pending_reset = false
		state.transform = _pending_reset_xform
		_suppress_impact_frames = 2
		return
	var cfg: GameConfig = config
	var contacts := state.get_contact_count()
	# Object reactions run FIRST: fell trees on a per-contact, size-scaled speed
	# threshold, and restore a size-scaled slice of the shed FORWARD momentum for
	# felled trees so a small tree lets the car plough on through instead of stopping
	# it dead. The restore is CENTRAL (linear velocity only, via
	# TreeFall.plough_restore_velocity) so the solver's off-center contact response —
	# the spin a rear-quarter clip imparts — is left untouched. Because the threshold
	# is now per-tree (size-dependent), the contacts are walked unconditionally rather
	# than gated once on approach speed.
	var keep := 1.0            # min plough_keep across felled contacts; starts high
	var any_felled := false
	var solid_wall := false    # a reported obstacle contact that did NOT fell
	for i in contacts:
		var collider := state.get_contact_collider_object(i) as Node
		if collider == null or not collider.is_in_group(DamageModel.OBSTACLE_GROUP):
			continue
		var field := collider.get_parent()
		if field == null or not field.has_method("knock_down") or not field.has_method("size_factor"):
			# An obstacle we can't fell (e.g. a wall) — it legitimately stops the car.
			solid_wall = true
			continue
		var shape_idx := state.get_contact_collider_shape(i)
		var size: float = field.size_factor(shape_idx)
		if TreeFall.should_fell_sized(_approach_speed, size, cfg):
			field.knock_down(shape_idx, _approach_dir, cfg.tree_fell_duration_s)
			keep = minf(keep, TreeFall.plough_keep(size, cfg))
			any_felled = true
		else:
			solid_wall = true  # a standing tree below its threshold is still a wall
	# Restore forward momentum only if every obstacle we touched was felled — a still-
	# standing wall (a big tree below its threshold, or a non-tree obstacle) legitimately
	# stops the car, so don't shove it through.
	if any_felled and not solid_wall:
		state.linear_velocity = TreeFall.plough_restore_velocity(
			_approach_velocity, state.linear_velocity, keep, _approach_speed)
	# Unified deceleration damage, computed from the POST-restore velocity so a tree the
	# car ploughs through costs little HP. Skipped for a couple of ticks after a
	# reset/teleport, whose discontinuous velocity zeroing would read as a false dv.
	# NOT gated on is_held(): a held car is now genuinely still (the parking hold is a soft
	# anchored spring, not a velocity cancel, so there is no hold-vs-tire ringing left to
	# misread as deceleration), so the countdown needs no damage exemption. See
	# features/damage.md.
	if _suppress_impact_frames > 0:
		_suppress_impact_frames -= 1
	elif damage != null:
		var dv := (_approach_velocity - state.linear_velocity).length()
		var contact_point := state.get_contact_local_position(0) if contacts > 0 else global_position
		damage.register_deceleration(dv, state.step, contact_point, cfg)


# DamageModel reached 0 HP. Re-emit for the rally/menu layer. In free-roam (an
# UNBOUND model, no OwnedCar) there is no DNF flow yet, so heal to full and drop
# back at the spawn so play continues; a fielded car leaves the consequences to
# its listener (features/rally-session.md).
func _on_wrecked() -> void:
	wrecked.emit()
	if damage.instance_id < 0:
		damage.hp = damage.max_hp
		_reset()


# True when at least one wheel is not touching the ground — the trigger for the
# self-righting assist (drivetrain owns the classified wheel lists).
func _any_wheel_airborne() -> bool:
	# all_wheels is the cached front+rear list; iterating it (rather than
	# `front_wheels + rear_wheels`) avoids a per-tick Array allocation.
	for wheel in drivetrain.all_wheels:
		if not wheel.is_in_contact():
			return true
	return false


# Manual reset (the `R` action): back to the authored spawn pose.
func _reset() -> void:
	reset_to(_start_transform)


# Reset the car to an arbitrary pose with motion zeroed — shared by the manual
# reset and the off-track recovery (TrackProgress). Restores velocities, wheel
# spin and engine state so the car drops in cleanly rather than carrying over
# stale momentum.
# Static-friction hold for a nearly-stopped, fully-braked car so it doesn't slowly creep
# down a slope. The tire model's longitudinal force fades to zero as slip does
# (drivetrain._tire_force caps it at |slip|·m/h), so at creep speed gravity's slope
# component wins and the car dribbles downhill. Rather than freeze the body (which takes
# it out of the sim and snaps on release), the car is tied to an ANCHOR point — the spot
# it was standing on when the hold engaged — by a soft, damped spring, capped at
# `parking_hold_grip · m · g` so it behaves like real stiction: it pins the car on any sane
# grade (a couple of cm of slack at most), but a wall-steep grade overruns the cap and
# still slides.
#
# WHY A SPRING AND NOT A VELOCITY CANCEL (this is the countdown vibration/creep fix — don't
# "simplify" it back): this used to be F = -m·v_h/dt, i.e. "erase the velocity the car had
# last tick", sized off the PRE-solve velocity. Two things are wrong with that. First, it
# has no position feedback at all: nothing ties the car to the ground it is standing on, so
# it only ever chases velocity. Second, it always runs a tick behind the disturbance — it
# wipes last tick's velocity while the grade / drivetrain / a nudge injects a fresh a·dt in
# the same step, so the steady state is not "stopped" but "moving at v ≈ a·dt, every tick,
# forever". Measured on the old code: a held car crept ~3 cm/s under an ~12° grade's worth
# of pull, i.e. the visible countdown shudder and sideways creep. (It also double-counted
# the pinned tires' own friction — both cancel the same velocity in the same step — so the
# body could be pushed back through zero, and the μ·m·g clip rectified that into yet more
# drift. Either way the per-tick velocity swing was big enough for the deceleration-damage
# rule to charge HP for it, which is why that rule was once gated on is_held().)
#
# The anchored spring fixes the cause: it corrects DISPLACEMENT, so the resting offset is
# bounded at ≈ a / parking_hold_stiffness (~1 cm on that same grade) instead of growing
# without limit, and its per-tick authority is k·offset·dt² ≪ offset (k·dt² ≈ 0.08, ζ ≈ 0.6
# at the shipped values) so it converges rather than ringing. Correcting displacement rather
# than velocity also leaves the chassis's own roll/pitch sway to breathe — a velocity cancel
# stiffens the body and kills body roll dead.
func _apply_parking_hold(braked: bool, speed: float, delta: float) -> void:
	# Only hold once the car is actually resting on the ground — a boot-locked car
	# (StageManager forces the handbrake) must be free to drop onto its wheels first.
	if not (braked and speed < config.handbrake_lock_speed and _is_grounded()) or delta <= 0.0:
		_hold_anchor_set = false
		return
	# First engaged tick: anchor on the spot the car is standing (horizontal only —
	# vertical stays the suspension's / gravity's business) AND the direction it is
	# facing, so the hold can put back a heading as well as a position.
	if not _hold_anchor_set:
		_hold_anchor = global_position
		_hold_anchor_yaw = _yaw()
		_hold_anchor_set = true
	_apply_heading_hold(delta)
	var cfg: GameConfig = config
	var offset := global_position - _hold_anchor
	offset.y = 0.0
	var v_h := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	# Damped spring back to the anchor, in acceleration terms (so it is mass-independent).
	var accel := -offset * cfg.parking_hold_stiffness - v_h * cfg.parking_hold_damping
	var hold := accel * mass
	# Clamp to μ·m·g so it acts like static friction, not an infinite clamp.
	var cap := cfg.parking_hold_grip * mass * _default_gravity
	if hold.length() > cap:
		hold = hold.normalized() * cap
		# Cap reached: the grade (or a shove) is beating stiction, so let the anchor be
		# dragged along with the car instead of building unbounded slack it would later
		# snap back across. (offset can be ~0 here when the damping term alone hits the cap;
		# normalized() returns zero then, which simply re-anchors under the car.)
		_hold_anchor = global_position - offset.normalized() * cfg.parking_hold_slack
		_hold_anchor.y = global_position.y
	apply_central_force(hold)


# The car's heading as an angle about the world Y axis.
func _yaw() -> float:
	var fwd := global_transform.basis.z
	return atan2(fwd.x, fwd.z)


# Yaw half of the parking hold: spring the car back to the heading it was placed
# with, and damp the yaw rate so it settles instead of ringing.
#
# CRITICALLY DAMPED BY CONSTRUCTION. The damping is derived from the stiffness
# (2*sqrt(k) is the critical value for this acceleration-form spring) rather than
# authored separately, so this cannot be tuned into an oscillation — a car that
# wobbles on the start line is never what anyone wants, whatever the stiffness is
# set to. Reuses parking_hold_stiffness so the two halves of the hold stay one knob.
func _apply_heading_hold(_delta: float) -> void:
	var cfg: GameConfig = config
	var k: float = cfg.parking_hold_stiffness
	if k <= 0.0:
		return
	var error := wrapf(_hold_anchor_yaw - _yaw(), -PI, PI)
	var rate := angular_velocity.y
	# Torque = I * angular acceleration; yaw_inertia keeps it mass/size independent.
	var accel := error * k - rate * 2.0 * sqrt(k)
	# The inverse inertia tensor is SINGULAR whenever the body has no yaw freedom —
	# `axis_lock_angular_y` zeroes that axis, and a frozen body zeroes the lot. Inverting
	# it then trips Godot's `Condition "det == 0" is true` in Basis::invert and hands back
	# a garbage basis, which `apply_torque` feeds straight into the physics state.
	#
	# That is not theoretical: the start line axis-locks the staged player
	# (start_line.gd::_stage_player sets axis_lock_angular_y while the grid rolls up), so
	# EVERY career start ran this every physics frame. The corrupted transform left the car
	# pinned at the world origin for the whole stage, and the chase camera — which follows
	# it — sat underground rendering a flat grey screen.
	#
	# No yaw freedom means there is no heading to hold, so skipping is also the correct
	# behaviour, not merely the safe one.
	var inv_tensor := get_inverse_inertia_tensor()
	# EXACT zero, deliberately — this mirrors the engine's own `det == 0` condition in
	# Basis::invert, so it fires precisely when inverting would fail and never otherwise.
	# is_zero_approx() is WRONG here and was tried first: its 1e-6 epsilon swallows the
	# legitimately tiny determinant of a real car's INVERSE inertia tensor (entries ~1e-3
	# for a ~1000 kg car, so det ~1e-9), which silently disabled the heading hold for
	# every car — caught by test_countdown_hold.gd's 16.6-degree drift assertion.
	if inv_tensor.determinant() == 0.0:
		return
	var yaw_inertia := inv_tensor.inverse() * Vector3.UP
	apply_torque(yaw_inertia * accel)


# True once the car is settled on its wheels (a solid majority in ground contact),
# so the handbrake lock never engages while it's still dropping in / airborne.
func _is_grounded() -> bool:
	var n := 0
	for wheel in _wheel_mounts:
		if wheel.is_in_contact():
			n += 1
	return n >= 3


# Soft pass-through contact (a brushed bush / mowed spectator): shed a small,
# speed-scaled slice of horizontal momentum so the unified deceleration-damage rule
# (_integrate_forces) deals the minor HP loss — instead of a separate flat-loss path.
# `strength` in [0,1] is the fraction of horizontal speed removed this contact.
func apply_soft_drag(strength: float) -> void:
	if strength <= 0.0:
		return
	var v_h := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	if v_h.length_squared() < 1e-4:
		return
	apply_central_impulse(-v_h * clampf(strength, 0.0, 1.0) * mass)


func reset_to(xform: Transform3D) -> void:
	# Queue the teleport for _integrate_forces (see _pending_reset) rather than trusting a
	# bare global_transform write, which the physics server discards unless it happens
	# inside the physics step. Also wake the body: a stuck car sleeps, and _integrate_forces
	# does not run on a sleeping body, so the queued pose would never be applied.
	sleeping = false
	_pending_reset = true
	_pending_reset_xform = xform
	# Still set the node transform now so same-frame non-physics readers (camera, HUD) see
	# the new pose immediately; _integrate_forces re-applies it authoritatively next step.
	global_transform = xform
	# A reset zeroes the velocity discontinuously; suppress deceleration damage for the
	# next couple of physics ticks so that jump doesn't read as a crash.
	_suppress_impact_frames = 2
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	steering = 0.0
	drivetrain.rear_omega = 0.0
	for wheel in drivetrain.front_omega:
		drivetrain.front_omega[wheel] = 0.0
	drivetrain.engine.reset()


# Replace `old_car` with a FRESH car instance configured to `index`, spawned at
# `spawn_xform`, and return the new node. Swapping cars by re-instantiating
# (rather than repeatedly reshaping one body in place) is what keeps them
# drivable: a VehicleBody3D accumulates stale wheel/suspension state when its
# wheels are relocated again and again, which left some cars spinning in place
# with no traction. A fresh body is configured exactly once, which is reliable.
# Callers must re-point anything holding the old car (camera target, HUD).
static func respawn(old_car: Node, index: int, spawn_xform: Transform3D) -> Node:
	var parent := old_car.get_parent()
	old_car.name = "CarRetired"
	# Stop the retired car simulating: queue_free() is deferred to frame end, so
	# without this it would run one more _physics_process AFTER the fresh car's
	# apply_car() has reshaped the shared Config.data (the active car keeps
	# config == Config.data). Reading the new car's gearbox with its own stale gear
	# state (e.g. a 7-speed still in gear 6, now indexing a 3-speed ratio table)
	# throws an out-of-bounds. A car being replaced must not step again.
	old_car.set_physics_process(false)
	old_car.queue_free()
	var fresh := CAR_SCENE.instantiate()
	fresh.name = "Car"
	fresh.transform = spawn_xform
	parent.add_child(fresh)
	fresh.apply_car(index)
	return fresh


# The next car index after this one, wrapping around.
func next_car_index() -> int:
	return (_car_index + 1) % CarLibrary.all().size()


func current_car_name() -> String:
	if _car_index < 0:
		return "Base"
	return CarLibrary.all()[_car_index]["name"]


# Per-car bonnet-camera position offset (metres, in the car's local space), added
# on top of the shared GameConfig.bonnet_offset so each body's hood cam can be
# nudged to sit at the right spot. Zero (baseline) for the untouched car and for
# any entry that doesn't author one. Read by CameraManager.retarget().
func bonnet_cam_offset() -> Vector3:
	if _car_index < 0:
		return Vector3.ZERO
	return CarLibrary.all()[_car_index].get("bonnet_cam_offset", Vector3.ZERO)


# Half the current body length (metres, along the car's Z / travel axis). The chase
# camera adds this to its follow distance so a longer car gets pushed back enough to
# keep its nose/tail in frame. Zero before a car is fielded.
func half_length() -> float:
	if _car_index < 0:
		return 0.0
	var body: Vector3 = CarLibrary.all()[_car_index]["body"]
	return body.z * 0.5


# Half the current body WIDTH (metres, along the car's local X axis). The replay
# camera's onboard WHEEL shot adds a clearance margin on top of this so its lateral
# mount point never lands inside (or right on the surface of) the car body mesh,
# regardless of how wide the fielded car is. Zero before a car is fielded.
func half_width() -> float:
	if _car_index < 0:
		return 0.0
	var body: Vector3 = CarLibrary.all()[_car_index]["body"]
	return body.x * 0.5


# Give this car its OWN private GameConfig (a deep copy of the current global
# baseline) so its apply_car / apply_owned reshape mutates that copy instead of the
# shared Config.data. Call on a non-simulating PROP/display car BEFORE apply_car so
# it can't clobber the active car's engine/gearbox in the global config. The active
# player car does NOT call this — it keeps config == Config.data so the HUD, tuning
# lift, audio synth and save system (all of which read Config.data) reflect it.
func use_isolated_config() -> void:
	var base: GameConfig = config if config != null else Config.data
	config = base.duplicate(true) if base != null else GameConfig.new()


# Reshape and retune the car to a CarLibrary entry: overlays its dimensions,
# mass, drag, engine character and drive layout onto the live config and scene,
# then rebuilds the drivetrain (fresh hardpoints + shift speeds) and engine
# voice so the new sound and gearing take effect. Returns the car's name.
# Field this car to a CarLibrary entry: overlays the spec onto `config`, RELOCATES the
# wheels (detach/re-attach from the tree) and RESETS the pose (_reset at the end). Those
# last two are destructive to a LIVE, simulating VehicleBody3D — they corrupt its
# suspension contact (wheels drop through the floor). So only field a FRESH/idle body
# (a just-instantiated instance, e.g. Car.respawn), never re-field the live player car
# mid-stage. To change a live car's tuning use retune() (config-only, no reshape); to
# change its car re-instantiate via respawn(). Re-running it purely to re-derive config
# (with no reliance on the body's physics afterward) is fine — the test suite does this.
func apply_car(index: int, rebuild_audio := true) -> String:
	var spec: Dictionary = CarLibrary.all()[index]
	_car_index = index
	# Clear any owned-car state from a prior fielding: a car fielded via apply_car
	# is unowned (free-roam / prop / opponent), so it carries no aero upgrade. This
	# keeps set_body_hidden(false) from re-revealing a wing off a stale _last_owned
	# if this instance is ever re-fielded apply_owned→apply_car. apply_owned sets
	# _last_owned afterwards via _apply_aero_visibility, so this is safe there too.
	_last_owned = {}
	_apply_physics_spec(spec)
	_apply_body_meshes(spec)
	_apply_model_visibility(spec)
	_relocate_wheels(spec)

	# Rebuild the drivetrain so it re-reads the moved hardpoints and recomputes
	# shift speeds for the new redline/gearing, on the spec's driven-axle layout.
	_rebuild_drivetrain(spec["drive_mode"] as Drivetrain.DriveMode)

	# Rebuild the engine voice for the new cylinder count / firing order. Skipped when
	# rebuild_audio is false — apply_owned defers it to a single rebuild at the end of
	# the fielding pipeline (after engine swap + upgrades, which can also change the
	# voicing), instead of rebuilding here and again per later step.
	if rebuild_audio:
		_reconfigure_engine_audio()
	else:
		# Deferring is legitimate, but FORGETTING to follow up leaves the car mute with no
		# error — the config carries the engine either way, so nothing else complains. Arm a
		# flag the first live physics tick checks (see _physics_process) so a third caller
		# that defers and never rebuilds is loud instead of silent. Both current deferrers
		# (apply_owned, fit_engine) clear it, so this never fires today.
		_audio_build_pending = true

	# Per-car HP pool (CarLibrary metadata, mass-keyed). Free-roam fields it unbound
	# at full HP; a future rally layer re-fields it from the OwnedCar (with the
	# stored HP + instance id) when a car is taken to the Start line.
	var max_hp: float = spec.get("max_hp", damage.max_hp)
	damage.field(max_hp, max_hp)

	_reset()
	return spec["name"]


# Overlay a CarLibrary entry's physics/config fields onto the live config (read
# live each physics step): mass, drag, wheel radius, the referenced engine's whole
# profile + transmission, tyre compound + widths, per-axle downforce, per-axle
# suspension, and the mass + custom centre of mass.
func _apply_physics_spec(spec: Dictionary) -> void:
	var cfg: GameConfig = config
	cfg.mass = spec["mass"]
	cfg.drag_coefficient = spec["drag"]
	cfg.wheel_radius = spec["wheel_radius"]
	# All engine data (sound + performance + voicing + the TRANSMISSION it's bolted to:
	# gear_ratios / final_drive / shift_time) comes from the referenced engine in
	# EngineLibrary — the single source of truth. apply() writes every engine_* and
	# gearbox field onto cfg before the drivetrain/audio rebuild below, so an engine
	# swap carries its whole drivetrain (see _apply_engine_swap). EngineSim recomputes
	# its shift speeds for the new gearing on the rebuild.
	EngineLibrary.apply(EngineLibrary.by_id(spec["engine"]), cfg)
	# One tyre compound per car (same rubber both axles); seed BOTH runtime axle μ
	# from it. The grip_balance tuning slider (TuningLibrary.apply, run after) shifts
	# them apart. Front/rear GRIP balance otherwise emerges physically from the widths
	# below + weight_front via the drivetrain's load-sensitivity term.
	cfg.wheel_friction_slip_front = spec["tire_compound"]
	cfg.wheel_friction_slip_rear = spec["tire_compound"]
	cfg.wheel_width_front = spec["wheel_width_front"]
	cfg.wheel_width_rear = spec["wheel_width_rear"]
	# Per-car aero downforce (N per (m/s)² at each axle). SET (not added) so a spec of
	# 0 means 0 — no hidden global baseline — and so re-fielding can't accumulate the
	# value. apply_owned applies the aero_kit upgrade ON TOP of this afterwards.
	cfg.downforce_front = spec.get("downforce_front", 0.0)
	cfg.downforce_rear = spec.get("downforce_rear", 0.0)
	# Per-car steer-assist yaw torque (understeer aid). SET (not added) so a spec of
	# 0 means no assist — no hidden global baseline. Only the focus authors a value.
	# Per-car default brake bias (front share of foot-brake torque). This is the
	# baseline the brake-bias tuning slider re-centres on (TuningLibrary.apply, run
	# after); at neutral the car keeps this default. Omit to inherit the
	# GameConfig.brake_bias default.
	cfg.brake_bias = spec.get("brake_bias", cfg.brake_bias)
	# Per-car suspension: overall spring rate + per-axle travel. The front/rear
	# spring RATES are not authored — they're derived from weight_front by
	# GameConfig.axle_stiffness so the heavier axle gets a stiffer spring and the car
	# sits level (see _apply_suspension). Travel defaults to the single suspension_travel
	# unless a spec sets a front/rear value. Dampers stay derived from the resolved
	# per-axle rate. Pushed onto the wheels in the relocation loop below.
	cfg.suspension_travel = spec.get("suspension_travel", cfg.suspension_travel)
	# Per-axle travel overrides: 0 = inherit suspension_travel (axle_travel resolves).
	cfg.suspension_travel_front = spec.get("suspension_travel_front", 0.0)
	cfg.suspension_travel_rear = spec.get("suspension_travel_rear", 0.0)
	cfg.suspension_stiffness = spec.get("suspension_stiffness", cfg.suspension_stiffness)
	mass = cfg.mass
	# Per-car centre of mass from the real static front-axle weight fraction. Also
	# drives the front/rear spring-rate split (GameConfig.axle_stiffness).
	var front_frac: float = spec.get("weight_front", 0.5)
	cfg.weight_front = front_frac
	_set_center_of_mass(spec["wheelbase"], front_frac)
	_compute_engine_smoke_local(spec)


# Resize the procedural chassis box mesh + cabin box to the spec's dimensions and
# rebuild the collision hull as a chamfered octagon (see _chassis_hull_points).
func _apply_body_meshes(spec: Dictionary) -> void:
	var body: Vector3 = spec["body"]
	var cabin: Vector3 = spec["cabin"]
	(($Chassis as MeshInstance3D).mesh as BoxMesh).size = body
	var hitbox := Vector3(body.x, body.y - 0.3, body.z)
	var chamfer := body.x * config.hitbox_chamfer_fraction
	var collision := $CollisionShape3D as CollisionShape3D
	# The scene authors a BoxShape3D; the first apply swaps in a ConvexPolygonShape3D
	# (and later applies reuse it). Assigning a fresh shape per instance also keeps the
	# hull isolated the same way the _ready duplicate did for the box.
	var hull := collision.shape as ConvexPolygonShape3D
	if hull == null:
		hull = ConvexPolygonShape3D.new()
		collision.shape = hull
	hull.points = _chassis_hull_points(hitbox, chamfer)
	var cabin_mesh := $Cabin as MeshInstance3D
	(cabin_mesh.mesh as BoxMesh).size = cabin
	cabin_mesh.position = Vector3(0.0, body.y * 0.5 + cabin.y * 0.45, spec["cabin_z"])


# The chassis collision hull: a box with its four VERTICAL corners chamfered, so
# top-down it's an elongated octagon. A glancing corner clip on a tree/sign/wall
# then deflects along the obstacle instead of catching the square corner and
# snapping the car. `chamfer` is the absolute inset applied EQUALLY along X (width)
# and Z (length) at each corner — an equal cut makes the corner 45° so the nose and
# tail read as a regular octagon. Clamped so every one of the eight faces keeps a
# positive flat edge even for an extreme body/config. Returns 16 points (the 8
# top-view corners duplicated at +/- half height); the order is [top, bottom] per
# corner, walked clockwise from the front-right — WheelForceDebug's overlay relies
# on that ordering to rebuild the prism it draws.
static func _chassis_hull_points(size: Vector3, chamfer: float) -> PackedVector3Array:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var c := clampf(chamfer, 0.0, minf(hx, hz) * 0.99)
	# Forward is -Z; the 8 corners walk clockwise from the front-right (top view).
	var outline := PackedVector2Array([
		Vector2(hx, -hz + c),   # right side, toward the front
		Vector2(hx - c, -hz),   # front edge, right  (front-right corner cut)
		Vector2(-hx + c, -hz),  # front edge, left   (front-left corner cut)
		Vector2(-hx, -hz + c),  # left side, toward the front
		Vector2(-hx, hz - c),   # left side, toward the rear
		Vector2(-hx + c, hz),   # rear edge, left    (rear-left corner cut)
		Vector2(hx - c, hz),    # rear edge, right   (rear-right corner cut)
		Vector2(hx, hz - c),    # right side, toward the rear
	])
	var pts := PackedVector3Array()
	for p in outline:
		pts.push_back(Vector3(p.x, hy, p.y))
		pts.push_back(Vector3(p.x, -hy, p.y))
	return pts


# Authored-model cars hide the procedural chassis/cabin boxes and show ONE glb body
# (spec["model_node"]); every other body + the boxes are hidden. The collision box
# (set in _apply_body_meshes) is shared by both paths. Wheels stay procedural either way.
func _apply_model_visibility(spec: Dictionary) -> void:
	var use_model: bool = spec.get("use_model", false)
	var active_node := String(spec.get("model_node", ""))
	# Start from every body hidden, then reveal the one this spec wants.
	_hide_all_bodies()
	if use_model:
		var model_body := get_node_or_null(NodePath(active_node)) as Node3D
		if model_body != null:
			model_body.visible = true
			_set_aero_visible(model_body, false)  # wings hidden by default; reveal is opt-in per upgrade
			_apply_model_material(model_body, load(String(spec.get("model_texture", ""))))
	else:
		($Chassis as MeshInstance3D).visible = true
		($Cabin as MeshInstance3D).visible = true


# Free the authored glb body nodes this car will never show — every model body except
# the active one (car.tscn embeds all 9 car glbs, so an un-pruned instance keeps 8 hidden
# bodies alive). DISPLAY / FROZEN PROPS ONLY (see CarProp): a frozen prop never switches
# its model, so freeing the inactive bodies removes ~8/9 of the CarProp.dup_meshes cost
# (and their memory) with no visible change. Immediate free() (not queue_free) so the
# nodes are gone before dup_meshes iterates the tree. Never call on the live player car —
# it can reshape / re-skin its (single) active body at runtime, but must keep the rest.
func prune_inactive_bodies() -> void:
	if _car_index < 0:
		return  # no car applied yet (baseline -1 would negative-index the roster) — nothing to prune
	var active := String(CarLibrary.all()[_car_index].get("model_node", ""))
	for node_name in _model_node_names():
		if node_name == active:
			continue
		var body := get_node_or_null(NodePath(node_name))
		if body != null:
			body.free()


# Hide the procedural chassis/cabin boxes AND every glb model body. Shared by
# set_body_hidden(true) and _apply_model_visibility (which then re-reveals one).
func _hide_all_bodies() -> void:
	($Chassis as MeshInstance3D).visible = false
	($Cabin as MeshInstance3D).visible = false
	for node_name in _model_node_names():
		var model_body := get_node_or_null(NodePath(node_name)) as Node3D
		if model_body != null:
			model_body.visible = false


# Hide (or restore) every body mesh — chassis/cabin boxes AND the glb model bodies —
# so the debug hitbox overlay isn't obscured. Restoring re-runs the normal
# per-spec visibility logic so the right body (procedural vs model) reappears.
func set_body_hidden(hidden: bool) -> void:
	if hidden:
		_hide_all_bodies()
	else:
		_apply_model_visibility(CarLibrary.all()[_car_index])
		_apply_aero_visibility(_last_owned)  # _apply_model_visibility hid the wing; restore its real state


# Silence + stop this car's engine voice — used when the car becomes a static
# prop (HQ lift / parked display, world wreck) that must make no sound. Disables
# the EngineAudio node's processing and hard-mutes any AudioStreamPlayer under it.
func silence_engine_audio() -> void:
	var audio := get_node_or_null("EngineAudio")
	if audio == null:
		return
	audio.process_mode = Node.PROCESS_MODE_DISABLED
	if audio is AudioStreamPlayer:
		audio.playing = false
		audio.volume_db = -80.0


# Reposition + resize each wheel to the spec's track / wheelbase / radius / width
# (relocating from the AUTHORED mount, origin only), push per-axle suspension onto
# it, and re-skin its tyre, then detach and re-attach all wheels so the
# body re-latches the moved suspension connection points.
func _relocate_wheels(spec: Dictionary) -> void:
	# Tyre meshes are duplicated per-instance in _ready() (so multiple
	# car.tscn instances, e.g. the start-line queue props, can't stomp each
	# other's wheel visuals); resize each wheel's own copy here. Reposition each
	# wheel to the new track/wheelbase (origin only, preserving the scene's
	# axle-flip basis) and set its physics radius.
	var radius: float = spec["wheel_radius"]
	var width_front: float = spec["wheel_width_front"]
	var width_rear: float = spec["wheel_width_rear"]
	var half_track: float = spec["track"] * 0.5
	var half_base: float = spec["wheelbase"] * 0.5
	var wheels := find_children("*", "VehicleWheel3D", false)
	for wheel in wheels:
		# Relocate from the AUTHORED mount, not the live transform — the body
		# repaints the wheel's origin with suspension travel each step, so reading
		# it back would let the mount drift (and corrupt contact) on each swap.
		var mount: Vector3 = _wheel_mounts.get(wheel, wheel.position)
		wheel.position = Vector3(signf(mount.x) * half_track, mount.y, signf(mount.z) * half_base)
		wheel.wheel_radius = radius
		# Steering wheels are the front axle; staggered cars get fatter rears.
		var width: float = width_front if wheel.use_as_steering else width_rear
		# Per-car, per-axle suspension (mirrors _ready()'s setup): front/rear rate + travel
		# resolved from weight_front / suspension_travel_{front,rear}, dampers derived per axle.
		_apply_suspension(wheel)
		var tire := wheel.get_node_or_null("Visual/Tire") as MeshInstance3D
		if tire != null:
			var cyl := tire.mesh as CylinderMesh
			cyl.top_radius = radius
			cyl.bottom_radius = radius
			cyl.height = width
			# Per-car wheel cap: the car's own wheel.png, or a blank dark disc — unless a
			# cosmetic wheel style is fitted, which substitutes the DONOR's texture and
			# nothing else (radius/width above stay the car's own; see
			# features/wheel-customization.md).
			tire.set_surface_override_material(0, _wheel_material(_wheel_texture_for(spec)))

	# VehicleWheel3D latches its suspension connection point when it enters the
	# tree and repaints the node transform every physics step, so the position
	# writes above are reverted unless the wheel re-enters the tree. Detach ALL
	# wheels first, then re-attach them: re-adding one at a time while the others
	# are still registered mutates the body's wheel list mid-operation and
	# corrupts contact for the relocated wheels (cars end up spinning in place).
	for wheel in wheels:
		wheel.get_parent().remove_child(wheel)
	for wheel in wheels:
		add_child(wheel)
		wheel.owner = self


# Recreate the drivetrain (fresh hardpoints + shift speeds for the current
# redline/gearing) on the given driven-axle layout, re-resolve the terrain and
# recompute the axle midpoints. Shared by apply_car and _apply_engine_swap; _ready
# builds its own (it interleaves other setup and keeps the config-derived drive_mode).
func _rebuild_drivetrain(drive_mode: Drivetrain.DriveMode) -> void:
	var mode: Drivetrain.DriveMode = (_owned_drive_override as Drivetrain.DriveMode) if _owned_drive_override >= 0 else drive_mode
	drivetrain = Drivetrain.new(self)
	drivetrain.terrain = _resolve_terrain()
	drivetrain.drive_mode = mode
	config.drive_mode = mode
	_recompute_axles()


# Rebuild the EngineAudio voice for the current engine profile / voicing, when the
# node supports it (some headless fixtures swap in a stub without reconfigure()).
# Armed by apply_car(rebuild_audio=false), cleared by _reconfigure_engine_audio: catches a
# caller that defers the engine-voice build and then never triggers it (a silent car).
var _audio_build_pending := false


func _reconfigure_engine_audio() -> void:
	_audio_build_pending = false
	var audio := $EngineAudio as Node
	if audio.has_method("reconfigure"):
		audio.reconfigure()


# Set the custom centre of mass from the static front-axle weight fraction. For
# static balance the CoM sits behind the front axle by wheelbase x rear_fraction, so
# measured from the wheelbase centre (the body origin, where the axles sit at
# +/- half_base along Z; forward is -Z) the offset is wheelbase x (0.5 - weight_front),
# +Z = rearward. Switching to CUSTOM overrides Godot's AUTO (which derives a centred
# CoM from the symmetric collision box). Feeds the static load split onto each axle
# via the settling suspension -> Drivetrain.wheel_normal_force -> tyre grip balance.
# Height comes from GameConfig.com_height (negative = below the body origin): the roll
# lever a tyre force gets is the vertical CoM-to-contact-patch distance, so this sets
# the static rollover threshold track / (2 x CoG height). See features/car-physics.md.
func _set_center_of_mass(wheelbase: float, weight_front: float) -> void:
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector3(0.0, config.com_height, wheelbase * (0.5 - weight_front))


# Car-local emit point for the engine smoke (features/engine-smoke.md), pinned to the
# engine's real longitudinal position. engine_pos is the same normalised front-fraction
# as weight_front (1.0 = fully front, 0.0 = fully rear), so it maps onto the wheelbase
# exactly like the CoM above: z = wheelbase x (0.5 - engine_pos), +Z = rearward (forward
# is -Z). A rear-engine 911 (engine_pos ~0.1) puffs from the tail; a front-engine car
# from the nose. Falls back to weight_front, then 0.5, when a spec omits engine_pos.
# Lateral (X) and height (Y) still come from the global GameConfig.engine_smoke_offset.
func _compute_engine_smoke_local(spec: Dictionary) -> void:
	var base: Vector3 = config.engine_smoke_offset
	var engine_pos: float = spec.get("engine_pos", spec.get("weight_front", 0.5))
	engine_smoke_local = Vector3(base.x, base.y, spec["wheelbase"] * (0.5 - engine_pos))


# Field an OwnedCar (features/rally-session.md fielding pipeline): the CarLibrary
# baseline, then the installed upgrades, then the per-car tuning, then the working
# damage state from the saved HP. Used by world.gd when a RallySession is active;
# free-roam uses apply_car directly (no upgrades/tuning).
func apply_owned(owned: Dictionary) -> String:
	var model_id := String(owned.get("model_id", ""))
	var idx := CarLibrary.index_of(model_id)
	if idx < 0:
		idx = 0
	# Defer the audio rebuild: the engine swap and the upgrades below can both change
	# the audio voicing, so the synth is rebuilt ONCE at the end (see below) rather
	# than by apply_car here and again per step.
	# Resolve the player's chosen drivetrain (gated by the swap kit) so both apply_car's
	# baseline rebuild and the engine-swap rebuild adopt it. -1 = keep the stock layout.
	_owned_drive_override = UpgradeLibrary.resolve_drive_override(owned)
	# Cosmetic wheel style: resolved BEFORE apply_car so _relocate_wheels skins the
	# wheels with the donor's texture in one pass. Texture only — no stat moves.
	_owned_wheel_texture = WheelStyle.texture_for(owned, model_id)
	var car_name := apply_car(idx, false)
	# Step 1b: engine swap — if this car runs a non-stock engine, overwrite the
	# engine profile + recompute mass / weight distribution BEFORE upgrades (so a
	# weight-reduction kit scales the new total) and before the suspension re-sync
	# at the end of this function (so the spring split re-derives from the new
	# weight_front). See features/engine-swap.md.
	_apply_engine_swap(owned)
	# Snapshot the full pre-upgrade, pre-tune baseline (a deep copy of the whole config
	# after apply_car + engine swap) FIRST, so retune() / refit_upgrades() can re-derive
	# a CHANGED upgrade/tuning set on the LIVE config at the start line — restore this
	# baseline, then re-apply upgrades + tuning top-to-bottom — without re-running this
	# whole pipeline (which would relocate the wheels and reset the pose on a live body,
	# corrupting it — see _rederive_live_config()/respawn()).
	_snapshot_live_baseline()
	# Step 2: installed upgrades multiply/extend the live config. apply_car already
	# copied the baseline mass onto the RigidBody, so re-sync after a weight-reduction
	# upgrade mutates cfg.mass (other upgraded fields are read live each physics step).
	UpgradeLibrary.apply(owned, config)
	# Step 3: free, reversible per-car tuning re-balances grip / brake / aero on top
	# of the upgraded baseline (features/tuning.md). Gating (brake/aero) reads the same
	# installed upgrades, so it must run after step 2.
	TuningLibrary.apply(owned, config)
	_apply_aero_visibility(owned)  # reveal the wing iff the aero kit is fitted+enabled
	_sync_suspension_to_wheels()
	mass = config.mass
	# The config is now final (baseline → swap → upgrades → tuning). Rebuild the engine
	# voice ONCE here, so any writer that touched audio voicing is covered — including a
	# turbo fitted as an UPGRADE (whistle/BOV gains + turbo_enabled), not just the
	# engine. The synth caches voicing at build time, so without this a turbo on an NA
	# car would be silent even though its physics reads the config live.
	_reconfigure_engine_audio()
	# The upgrade layer above ran AFTER the drivetrain was constructed, so the engine's
	# config-derived fitment caches are stale — re-derive them now the config is final.
	# (Rally staging would reset the engine anyway; free roam never does.)
	drivetrain.engine.refresh_fitment()
	# Step 4: working HP starts at the saved value; bind to the instance so a wreck
	# removes it from the save.
	var entry := CarLibrary.by_id(model_id)
	var max_hp: float = entry.get("max_hp", damage.max_hp) if not entry.is_empty() else damage.max_hp
	damage.field(max_hp, float(owned.get("hp", max_hp)), int(owned.get("instance_id", -1)),
		owned.get("wheel_toe", []))
	_owned_drive_override = -1
	# Clear the per-fielding wheel override so a later BARE apply_car (free-roam /
	# prop / opponent re-fielding of this same instance) falls back to stock wheels
	# rather than inheriting this owned car's donor style.
	_owned_wheel_texture = ""
	return car_name


# Fit `engine_id` onto a car that has already had apply_car() run, then rebuild the
# engine voice. This is the swap-only counterpart to apply_owned's step 1b, for PROPS —
# the start-line grid spawns the top rivals, and rivals run engine swaps
# (features/rally-roster.md), so without this a "V12 Rondel Twist" would idle and pull
# away sounding like a stock Rondel Twist (layout fixes cylinder count, which fixes the
# firing table, which IS the voice — features/engine-audio.md) on stock gearing and mass.
#
# Deliberately NOT apply_owned: a prop wants none of that path's upgrades, tuning, aero
# visibility, live-baseline snapshot or damage/HP-to-instance binding.
#
# Call with apply_car(index, false) so the voice is built exactly ONCE, here — this
# rebuilds unconditionally, including when `engine_id` is empty or already the stock
# engine, so a stock prop is never left silent.
func fit_engine(engine_id: String) -> void:
	if engine_id != "":
		_apply_engine_swap({"swapped_engine": engine_id})
		# _apply_engine_swap moves cfg.weight_front (the engine is a point mass at
		# engine_pos) and syncs the body mass, but leaves the spring split derived from
		# the OLD distribution — apply_owned re-syncs afterwards for the same reason.
		_sync_suspension_to_wheels()
	_reconfigure_engine_audio()


# The FULL pre-upgrade, pre-tune config snapshot taken at fielding (after apply_car +
# engine swap, before upgrades/tuning), as a { property_name: value } map of EVERY
# GameConfig script variable. retune() and refit_upgrades() re-derive the live config
# from this ONE baseline — restore it, then re-apply upgrades + tuning — so there is a
# single re-derive ordering shared by both and no per-library field list to drift out of
# sync with apply(). Empty until fielded from an owned car (free-roam apply_car never
# snapshots), which disables both re-derives.
#
# A dict (not config.duplicate()) because the LIVE engine fields (peak_torque, redline,
# …) are plain non-@export vars: Resource.duplicate() would reset them to their declared
# defaults, not the fielded values. get()/set() over the property list captures the
# actual runtime values.
var _live_baseline := {}


func _snapshot_live_baseline() -> void:
	_live_baseline = {}
	for prop in config.get_property_list():
		if not (int(prop["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		var value: Variant = config.get(prop["name"])
		if value is Array or value is Dictionary:
			value = value.duplicate(true)
		_live_baseline[prop["name"]] = value


# Copy every captured field back into the LIVE config object in place (never reassign
# `config` — the drivetrain / engine / HUD hold that reference; see the note at the top
# of this file). Arrays/dicts are duplicated so the live config never shares mutable
# state with the baseline.
func _restore_live_baseline() -> void:
	for prop_name in _live_baseline:
		var value: Variant = _live_baseline[prop_name]
		if value is Array or value is Dictionary:
			value = value.duplicate(true)
		config.set(prop_name, value)


# The single live re-derive: restore the full pre-upgrade/pre-tune baseline, then re-apply
# the upgrade and tuning layers top-to-bottom. Because it always starts from the complete
# baseline, no field can carry stale state from a prior upgrade/tuning into the next
# re-derive (the bug this replaced: refit leaving old tuning baked into peak_torque). All
# re-derived fields are read live each physics step, so this takes effect immediately —
# no wheel relocate, no pose reset (unlike apply_owned, which must not run on a live staged
# body; see respawn()). No-op until fielded from an owned car.
func _rederive_live_config(owned: Dictionary) -> void:
	if _live_baseline.is_empty():
		return
	_restore_live_baseline()
	UpgradeLibrary.apply(owned, config)
	TuningLibrary.apply(owned, config)
	_apply_aero_visibility(owned)  # keep the wing in sync when upgrades are re-fitted live
	# Same reason as apply_owned: restoring the baseline zeroes the fitment fields and the
	# upgrade layer re-writes them, so the engine's caches must be re-derived. refit_upgrades
	# rebuilds the drivetrain after this anyway; retune does not, so it has to happen here.
	drivetrain.engine.refresh_fitment()
	# A rebuilt drivetrain re-seeds engine.auto from the config default, so forget the
	# mirrored Gearbox setting and let the next live tick push it again — otherwise the
	# player's choice silently reverts to the default after an upgrade refit.
	_gearbox_auto_seen = -1


# Re-apply a CHANGED tuning to the already-fielded live config, without reshaping the
# body. Used by the start-line Tune Car menu. Tuning touches only config fields read live
# each physics step, so no engine/drivetrain rebuild is needed.
func retune(owned: Dictionary) -> void:
	_rederive_live_config(owned)


# Re-apply a CHANGED upgrade set to the already-fielded live config WITHOUT reshaping the
# body (no apply_car / wheel relocate / pose reset, which would corrupt a live staged
# body — see respawn()). Re-derives from the full baseline, then re-syncs mass / suspension
# / drivetrain / engine audio (a turbo or drivetrain upgrade changes those). Used by the
# start-line Upgrades menu.
func refit_upgrades(owned: Dictionary) -> void:
	if _live_baseline.is_empty():
		return  # not fielded from an owned car — no baseline to restore, nothing to do
	_owned_drive_override = UpgradeLibrary.resolve_drive_override(owned)
	_rederive_live_config(owned)
	_sync_suspension_to_wheels()
	mass = config.mass
	var spec: Dictionary = CarLibrary.all()[_car_index]
	_rebuild_drivetrain(spec["drive_mode"] as Drivetrain.DriveMode)
	_reconfigure_engine_audio()
	_owned_drive_override = -1


# Re-field this owned car's engine when it differs from the CarLibrary stock: writes
# the swapped engine's full profile (torque/redline/firing/voicing AND its bolted-on
# transmission — gear_ratios/final_drive/shift_time) over the config, rebuilds the
# drivetrain (new redline/gearing/shift speeds) and engine voice, and recomputes total
# mass + static weight distribution treating the engine as a point mass at the car's
# engine_pos. No-op for a stock car. See features/engine-swap.md.
func _apply_engine_swap(owned: Dictionary) -> void:
	var spec: Dictionary = CarLibrary.all()[_car_index]
	var stock := String(spec.get("engine", ""))
	var current := EngineSwap.current_engine_id(owned, stock)
	if current == stock:
		return
	var new_eng := EngineLibrary.by_id(current)
	if new_eng.is_empty():
		return
	var cfg: GameConfig = config
	EngineLibrary.apply(new_eng, cfg)

	# Rebuild drivetrain (new redline/shift speeds; gearbox ratios already in cfg). The
	# engine voice is NOT rebuilt here — this is only ever called from apply_owned, which
	# rebuilds the synth once after all config mutation (swap + upgrades + tuning).
	_rebuild_drivetrain(spec["drive_mode"] as Drivetrain.DriveMode)

	# Independent engine weight + position -> new total mass and weight distribution.
	var m0 := float(EngineLibrary.by_id(stock).get("mass", 0.0))
	var m1 := float(new_eng.get("mass", 0.0))
	var spec_mass := float(spec["mass"])
	var spec_wf := float(spec.get("weight_front", 0.5))
	var ef := float(spec.get("engine_pos", spec_wf))
	cfg.mass = EngineSwap.recompute_mass(spec_mass, m0, m1)
	cfg.weight_front = EngineSwap.recompute_weight_front(spec_mass, spec_wf, m0, m1, ef)
	mass = cfg.mass
	_set_center_of_mass(spec["wheelbase"], cfg.weight_front)


# Bend each wheel by its persisted damage toe (radians) via the per-wheel
# VehicleWheel3D.steering — a physical steer angle the drivetrain tire model reads
# for the force direction, so a damaged car pulls/crabs from the physics alone.
# Front (steering) wheels carry the live steer PLUS their toe; rear wheels (which
# the body never steers) carry only their toe. Called every physics frame right
# after the base steering is set, so it also re-asserts over the body's per-frame
# overwrite of the front wheels. The wheel visuals read wheel.steering too, so the
# bend is visible. See DamageModel.nudge_wheels / features/damage.md.
func _apply_wheel_toe() -> void:
	if damage == null:
		return
	for wheel in drivetrain.front_wheels:
		wheel.steering = steering + float(damage.wheel_toe.get(wheel.name, 0.0))
	for wheel in drivetrain.rear_wheels:
		wheel.steering = float(damage.wheel_toe.get(wheel.name, 0.0))


# Whether a wheel sits on the front axle. Front wheels are mounted at negative
# local Z (forward = -Z); read the AUTHORED mount when known so this is stable even
# after physics repaints the live transform (the repaint moves the wheel along the
# suspension axis, not in Z, so the sign holds regardless — but the mount is cleaner).
func _wheel_is_front(wheel: VehicleWheel3D) -> bool:
	return float(_wheel_mounts.get(wheel, wheel.position).z) < 0.0


# Push the resolved per-axle spring rate + travel + derived dampers onto one wheel.
# Front and rear differ: the rate is split from the overall suspension_stiffness by
# weight_front (axle_stiffness) so the heavier axle is stiffer and the car sits level;
# travel comes from suspension_travel_{front,rear}; dampers are critically damped for
# the wheel's OWN rate. The single place all three setup sites funnel through.
func _apply_suspension(wheel: VehicleWheel3D) -> void:
	var cfg: GameConfig = config
	var front := _wheel_is_front(wheel)
	var k: float = cfg.axle_stiffness(front)
	var travel: float = cfg.axle_travel(front)
	wheel.suspension_travel = travel
	wheel.wheel_rest_length = travel
	wheel.suspension_stiffness = k
	wheel.damping_compression = cfg.suspension_damping_compression(k)
	wheel.damping_relaxation = cfg.suspension_damping_relaxation(k)


# Re-push the live per-axle suspension onto all four wheels (apply_car does this
# inline while relocating wheels; this is the standalone version for when an upgrade
# changes cfg.suspension_stiffness after apply_car).
func _sync_suspension_to_wheels() -> void:
	# _wheel_mounts is keyed by the (fixed, authored) wheel nodes — see line ~262. Iterate
	# it rather than re-walking the scene tree (find_children allocates an Array each call).
	for wheel in _wheel_mounts:
		_apply_suspension(wheel)


# --- Analytic rest pose (for static display / prop cars) ---------------------
# The height a settled car's body origin rests above flat ground, computed directly
# instead of by dropping a live physics body and freezing it seconds later (which was
# a recurring bug source — it depends on a collider being present under the car, the
# car not rolling on a slope, not re-wrecking on landing, and the freeze timing). See
# features/opponent-wrecks.md and features/car-physics.md → "Static rest pose".
#
# At rest the body sits at `wheel_radius + suspension_travel - mount_y` (the wheel
# fully drooped) MINUS the suspension compression under the car's own weight. The wheel
# VISUAL never moves with compression (drivetrain._update_visuals only spins/steers it,
# never translates it), so this single body offset fully reproduces the settled look.
#
# The compression term comes from Godot's built-in VehicleWheel3D solver, NOT the game's
# own tire model (they disagree by ~0.1 m). It's MASS-INDEPENDENT (Godot normalises the
# spring by chassis mass) and, per calibration, is `SUSPENSION_COMPRESSION_COEFF · g /
# suspension_stiffness`. The coefficient is calibrated against a real settle and pinned
# by test_rest_pose.gd, which re-derives it and fails loudly if a Godot upgrade shifts
# the solver — so the constant can never silently drift.
const SUSPENSION_COMPRESSION_COEFF := 0.3545

func settled_ride_height() -> float:
	var cfg: GameConfig = config
	var g: float = _default_gravity
	# Representative front wheel; props sit level (front/rear compression is kept equal
	# by the weight-split axle rates), so one axle's geometry defines the offset.
	var front_mount_y := -0.1
	for wheel in _wheel_mounts:
		if _wheel_is_front(wheel):
			front_mount_y = float(_wheel_mounts[wheel].y)
			break
	var geometry: float = cfg.wheel_radius + cfg.axle_travel(true) - front_mount_y
	var compression: float = SUSPENSION_COMPRESSION_COEFF * g / cfg.suspension_stiffness
	return geometry - compression


# The vertical distance a settled prop's wheels can still droop BELOW the analytic rest
# plane before a wheel floats — i.e. the compression baked into settled_ride_height().
# Used by the roadside-wreck site gate to reject verges steeper than the car can follow.
# Front-axle reach, reduced by any rear-axle travel shortfall so the shorter axle governs.
# Static (no instance): uses Platform.gravity() (the same physics/3d/default_gravity the
# car reads at _ready) so callers without a Car instance (world.gd) can compute it.
static func compression_budget(cfg: GameConfig) -> float:
	var front_budget: float = SUSPENSION_COMPRESSION_COEFF * Platform.gravity() / cfg.suspension_stiffness
	return front_budget - maxf(0.0, cfg.axle_travel(true) - cfg.axle_travel(false))


# A STATIC prop is frozen the instant it's placed, so Godot's VehicleWheel3D solver never
# runs and never repositions the wheel nodes — the wheel Visuals stay at their authored
# mount, ~travel above where a driven car's wheels hang. settled_ride_height() puts the
# BODY where a live car settles (which assumes the wheels have drooped down that far), so
# without this the prop's wheels are tucked up into the arches (reads as "over-compressed")
# and the car floats. This droops each Visual to where Godot's live solver renders it, so a
# parked prop matches the driven car. Call it AFTER apply_car/apply_owned (needs the wheels'
# resolved rest length + stiffness) on frozen props ONLY — a live car lets Godot move the
# wheel node and must keep its Visual at the local origin (_update_visuals only re-orients
# the Visual, never translates it, so this offset persists).
#
# droop = wheel_rest_length - WHEEL_DROOP_COEFF · g / suspension_stiffness, per wheel from
# its OWN resolved params. Like SUSPENSION_COMPRESSION_COEFF this comes from Godot's wheel
# solver (not the game's tire model); the coefficient is calibrated against a real settle
# and pinned by test_rest_pose.gd, so a Godot upgrade that shifts the render fails loudly.
const WHEEL_DROOP_COEFF := 0.25

func settle_wheel_visuals() -> void:
	var g: float = _default_gravity
	for wheel in _wheel_mounts:  # cached wheel nodes; avoids a find_children Array alloc
		var visual: Node3D = wheel.get_node_or_null("Visual")
		if visual == null:
			continue
		var droop: float = maxf(
			wheel.wheel_rest_length - WHEEL_DROOP_COEFF * g / wheel.suspension_stiffness, 0.0
		)
		visual.position.y = -droop


# How far above the wheel mount to start the down-ray, and slack added to its length.
const GROUND_RAY_MARGIN := 0.5

# Build a `ground_at` callable for settle_wheels_to_ground that raycasts straight DOWN
# from each wheel against this car's physics space, excluding the car's own body. Returns
# the hit Y, or NAN on a miss (settle_wheels_to_ground then keeps the analytic droop).
# Ray length covers wheel radius + the longer axle's full travel + margin. Reads on
# direct_space_state from idle are valid (space is only locked during the physics step);
# HQ already raycasts this way in _car_index_at.
func ground_raycast() -> Callable:
	var space := get_world_3d().direct_space_state
	var self_rid := get_rid()
	var reach: float = config.wheel_radius + maxf(config.axle_travel(true), config.axle_travel(false)) + GROUND_RAY_MARGIN
	return func(p: Vector3) -> float:
		var q := PhysicsRayQueryParameters3D.create(
			p + Vector3.UP * GROUND_RAY_MARGIN, p + Vector3.DOWN * (reach + GROUND_RAY_MARGIN))
		q.exclude = [self_rid]
		var hit := space.intersect_ray(q)
		return float(hit["position"].y) if not hit.is_empty() else NAN


# Droop each frozen prop's wheel Visual so the tyre bottom rests on the ground under it,
# supplied by `ground_at(world_pos) -> float`. Geometric contact, clamped to the
# suspension's droop range [0, wheel_rest_length]. A NON-FINITE ground value (e.g. a
# raycast miss) leaves that wheel at its analytic rest droop (as settle_wheel_visuals)
# rather than dangling. Frozen props ONLY (a live solver would fight it). The Visual is a
# CHILD of the wheel node, so writing visual.position.y never feeds back into
# wheel.global_position — safe to call every frame (the lift raise/lower).
func settle_wheels_to_ground(ground_at: Callable) -> void:
	var g: float = _default_gravity
	# Called every frame during the lift raise/lower — iterate the cached wheel nodes
	# (_wheel_mounts keys) instead of a per-frame find_children scene walk + Array alloc.
	for wheel in _wheel_mounts:
		var visual: Node3D = wheel.get_node_or_null("Visual")
		if visual == null:
			continue
		var ground: float = ground_at.call(wheel.global_position)
		var droop: float
		if is_finite(ground):
			droop = clampf(wheel.global_position.y - wheel.wheel_radius - ground,
				0.0, wheel.wheel_rest_length)
		else:
			# No ground (miss): analytic rest droop, matching settle_wheel_visuals().
			droop = maxf(wheel.wheel_rest_length - WHEEL_DROOP_COEFF * g / wheel.suspension_stiffness, 0.0)
		visual.position.y = -droop


# Give every MeshInstance3D in the authored body model the lit PS1 material
# (ps1_models_lit.gdshader) carrying the model's baked texture, so the glb stays in
# the same unshaded / quantize / dither / fog pipeline as the rest of the scene
# instead of using its imported Blender material. albedo_color is left white so
# the texture's own colours show through (ALBEDO = texture × albedo_color).
# Idempotent: the material is built once per mesh.
# Names of the authored glb body nodes in car.tscn (hidden unless a spec selects one).
# Derived from the shipped roster so adding a car (its model_node) doesn't also
# require editing a parallel list here; car.tscn's nodes mirror CarLibrary.CARS.
func _model_node_names() -> PackedStringArray:
	var names := PackedStringArray()
	for spec in CarLibrary.CARS:
		if not spec.get("use_model", false):
			continue
		var n := String(spec.get("model_node", ""))
		if not n.is_empty() and not names.has(n):
			names.append(n)
	return names


func _apply_model_material(model: Node3D, texture: Texture2D) -> void:
	var shader: Shader = load("res://shaders/ps1_models_lit.gdshader")
	for mesh in model.find_children("*", "MeshInstance3D", true):
		var mi := mesh as MeshInstance3D
		# Aero parts (spoiler/splitter, tagged *_aero) keep their OWN authored glb
		# material instead of the body's baked texture — they're bolt-on parts with a
		# distinct look (e.g. flat black), and the body texture atlas has no UVs for
		# them. See features/aero-parts.md.
		if AERO_TAG in mi.name:
			continue
		var mat := mi.get_surface_override_material(0) as ShaderMaterial
		if mat == null or mat.shader != shader:
			mat = ShaderMaterial.new()
			mat.shader = shader
			mat.set_shader_parameter("texture_tile", Vector2(1, 1))
			mat.set_shader_parameter("albedo_color", Color.WHITE)
			mat.set_shader_parameter("albedo_texture", texture)
			# Same fake per-vertex lighting as the procedural car meshes (see
			# world.gd) so the authored body gets shape too, not just flat colour.
			config.apply_car_light(mat)
			mi.set_surface_override_material(0, mat)


# Set visibility on every *_aero-tagged MeshInstance3D under `body` (the wing
# meshes). Static + body-parameterised so it is pure and testable; callers pass
# the active glb body. No-op for a null body (a procedural/boxes car has none).
static func _set_aero_visible(body: Node, shown: bool) -> void:
	if body == null:
		return
	for n in body.find_children("*" + AERO_TAG + "*", "MeshInstance3D", true, false):
		(n as MeshInstance3D).visible = shown


# The glb body node currently revealed for this car (from the live _car_index
# spec's model_node), or null for a procedural/boxes car (no wing to toggle).
func _active_body() -> Node:
	var spec: Dictionary = CarLibrary.all()[_car_index]
	if not bool(spec.get("use_model", false)):
		return null
	return get_node_or_null(NodePath(String(spec.get("model_node", ""))))


# Reveal the wing (spoiler/splitter) on the active body iff the aero kit is
# fitted+enabled on `owned`; hide it otherwise. Caches `owned` so set_body_hidden
# can restore the correct state. Call AFTER upgrades are applied.
func _apply_aero_visibility(owned: Dictionary) -> void:
	_last_owned = owned
	_set_aero_visible(_active_body(), UpgradeLibrary.aero_tuning_unlocked(owned))


# The wheel texture this fielding should render: the cosmetic style fitted by
# apply_owned if any, else the car's own authored wheel_texture.
func _wheel_texture_for(spec: Dictionary) -> String:
	if not _owned_wheel_texture.is_empty():
		return _owned_wheel_texture
	return String(spec.get("wheel_texture", ""))


# Re-skin the tire caps in place, WITHOUT touching geometry, physics or the pose — the
# live "try on a wheel" preview used by the HQ wheel-swap view. Pass "" to restore the
# car's own stock wheels. Safe on a frozen display prop and on a live body: nothing but
# the surface override material changes (contrast _relocate_wheels, whose detach /
# re-attach dance exists only to re-latch moved suspension points).
#
# STATELESS BY DESIGN: it deliberately does NOT write _owned_wheel_texture. That field is
# the FIELDING override and belongs to apply_owned alone; a preview stored there would
# outlive the preview on a node that gets reused (HQ props are pooled in _car_cache and
# borrowed by the lift / free-roam prewarm) and leak the wrong wheels into a later bare
# apply_car on that same node.
func reskin_wheels(tex_path: String) -> void:
	var spec: Dictionary = CarLibrary.all()[_car_index] if _car_index >= 0 else {}
	var resolved := tex_path if not tex_path.is_empty() else String(spec.get("wheel_texture", ""))
	var mat := _wheel_material(resolved)
	for wheel in find_children("*", "VehicleWheel3D", false):
		var tire := wheel.get_node_or_null("Visual/Tire") as MeshInstance3D
		if tire != null:
			tire.set_surface_override_material(0, mat)


# A ShaderMaterial for the tire caps using `tex_path` (a wheel.png), or a blank dark
# disc when empty. albedo_color (the rubber tread) is left at the shader default;
# world.gd repaints it live, same as before.
func _wheel_material(tex_path: String) -> ShaderMaterial:
	if _wheel_mats.has(tex_path):
		return _wheel_mats[tex_path]
	var mat := ShaderMaterial.new()
	mat.shader = WHEEL_SHADER
	mat.set_shader_parameter("albedo_texture", _blank_wheel_texture() if tex_path == "" else load(tex_path))
	# The tread colour + PS1 fake lighting that world.gd used to push onto the shared
	# tire material — now carried by each per-car material (world.gd's push lands on the
	# scene's default .tres, which apply_car replaces with this).
	mat.set_shader_parameter("albedo_color", config.wheel_color)
	config.apply_car_light(mat)
	_wheel_mats[tex_path] = mat
	return mat


static func _blank_wheel_texture() -> ImageTexture:
	if _blank_wheel_tex == null:
		var img := Image.create(1, 1, false, Image.FORMAT_RGB8)
		img.set_pixel(0, 0, Color(0.10, 0.10, 0.10))
		_blank_wheel_tex = ImageTexture.create_from_image(img)
	return _blank_wheel_tex

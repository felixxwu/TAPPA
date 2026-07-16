class_name CarProp
extends RefCounted
# Shared recipe for a DISPLAY / FROZEN car prop — the "instantiate car.tscn ->
# use_isolated_config() -> apply_car/apply_owned -> duplicate meshes -> silence engine
# audio -> freeze -> (optional) smoke" sequence that HQ (parked lineup + tuning lift),
# the opponent wrecks (world.gd) and the podium/showroom all re-inlined verbatim.
#
# The recipe is fixed; the parts that differ per caller are parameterised through the
# `opts` dictionary passed to `spawn`:
#   * owned:            OwnedCar dict -> apply_owned(owned).  (mutually exclusive with index)
#   * index:            CarLibrary index -> apply_car(index). (mutually exclusive with owned)
#   * configure:        Callable(car) run AFTER the meshes are duplicated and BEFORE the
#                       freeze/silence tail — the caller does its own positioning here
#                       (seat at a marker, set a transform, settle wheels) plus any
#                       prop-specific state (wreck: controls_locked, damage.hp = 0).
#   * silence:          call silence_engine_audio() (default true).
#   * freeze:           value written to car.freeze (default true; podium's LIVE settle
#                       passes false).
#   * stop_physics:     set_physics_process(false) — the car-park props use this instead
#                       of disabling the whole node so the frozen body stays ray-pickable.
#   * disable_process:  car.process_mode = PROCESS_MODE_DISABLED.
#   * smoke:            Callable(car) that attaches the caller's own synthetic/wreck smoke
#                       (left to the caller so its damage-gating stays put).
#
# car.tscn's body/wheel meshes are shared SubResources, so apply_* sizing one prop would
# resize every other; dup_meshes() gives each instance its own copies (see the callers'
# notes). The mesh scene is passed in (not loaded here) so HQ keeps its cached PackedScene.


# Give a car instance its own copies of every mesh resource: car.tscn's body/wheel
# meshes are SubResources shared across instances, so apply_car/apply_owned resized the
# shared one to THIS car — duplicating now freezes those dimensions before the next
# prop's apply mutates the shared original again.
static func dup_meshes(car: Node) -> void:
	for mi in car.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh != null:
			m.mesh = m.mesh.duplicate()


# Build a display/frozen car prop from `scene` under `parent`, following the shared
# recipe with the per-caller variations in `opts` (see the header). Returns the car node.
static func spawn(parent: Node, scene: PackedScene, opts: Dictionary) -> Node3D:
	# Variant (not :=) so the dynamic car-script calls below (use_isolated_config,
	# apply_*, silence_engine_audio, freeze) don't depend on the analyzer resolving
	# car.tscn's root script type at parse time — that inference is environment-fragile
	# (Godot 4.6 can fail it and break the whole script). Runtime behaviour is unchanged.
	var car: Variant = scene.instantiate()
	parent.add_child(car)
	# Isolated config so this display car's reshape can't clobber the player car's
	# engine/gearbox in the shared global Config.data (see car.gd `config`).
	car.use_isolated_config()
	if opts.has("owned"):
		car.apply_owned(opts["owned"])
	else:
		car.apply_car(int(opts.get("index", 0)))
	dup_meshes(car)
	var configure: Callable = opts.get("configure", Callable())
	if configure.is_valid():
		configure.call(car)
	if bool(opts.get("silence", true)):
		car.silence_engine_audio()
	car.freeze = bool(opts.get("freeze", true))
	if bool(opts.get("stop_physics", false)):
		car.set_physics_process(false)
	if bool(opts.get("disable_process", false)):
		car.process_mode = Node.PROCESS_MODE_DISABLED
	var smoke: Callable = opts.get("smoke", Callable())
	if smoke.is_valid():
		smoke.call(car)
	return car

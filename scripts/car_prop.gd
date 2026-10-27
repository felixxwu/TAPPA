class_name CarProp
extends RefCounted
# Docs: features/card-carousel.md — update in the same change as this file.
# Shared recipe for a DISPLAY / FROZEN car prop — "instantiate car.tscn ->
# use_isolated_config() -> apply_car/apply_owned -> prune unused bodies -> duplicate meshes ->
# silence engine audio -> freeze". Today's caller is the car cards' spinning preview
# (CarCardPreview). `opts`:
#   * owned:            OwnedCar dict -> apply_owned(owned).  (mutually exclusive with index)
#   * index:            CarLibrary index -> apply_car(index). (mutually exclusive with owned)
#   * stop_physics:     set_physics_process(false).
#   * disable_process:  car.process_mode = PROCESS_MODE_DISABLED.
#
# car.tscn's body/wheel meshes are shared SubResources, so apply_* sizing one prop would
# resize every other; dup_meshes() gives each instance its own copies. The scene is passed
# in (not loaded here) so a caller can keep a cached PackedScene.


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
	# Drop the embedded car.tscn bodies this prop won't show BEFORE dup_meshes, or every
	# hidden body's meshes get duplicated too (car.gd:prune_inactive_bodies).
	car.prune_inactive_bodies()
	dup_meshes(car)
	car.silence_engine_audio()
	car.freeze = true
	if bool(opts.get("stop_physics", false)):
		car.set_physics_process(false)
	if bool(opts.get("disable_process", false)):
		car.process_mode = Node.PROCESS_MODE_DISABLED
	return car

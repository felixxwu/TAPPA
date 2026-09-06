class_name CarCardPreview
extends SubViewportContainer
# Docs: features/card-carousel.md — update in the same change as this file.
# Tests: tests/headless/test_car_card_preview.gd, tests/headless/test_card_carousel.gd — extend in the same change.
#
# ONE lightweight SubViewport per car-choice card: a frozen CarProp (see car_prop.gd)
# turntable-rotated by a Node3D pivot, not a whole reinstantiated scene per frame — the
# rotation is the only thing that changes after setup. Low resolution and a plain
# omni/directional light rather than the game's full render pipeline, since this is a
# thumbnail, not a stage.
#
# Usage: CarCardPreview.new(car_index_or_owned_dict) — pass either a CarLibrary index
# (int, for an unowned catalogue car in the Buy list) or an owned-car Dictionary (for a
# car the player already has, so its actual paint/wheels show). ONE instance is meant to
# be kept alive and REUSED across selections — hub_shell.gd reparents it into whichever
# card is currently selected and calls show_car(new_ref) rather than freeing it and
# building a new CarCardPreview per card (see show_car's own comment for why that matters).

const _SIZE := 160

var _pivot: Node3D
var _car_ref
var _spawned := false


func _init(car_ref) -> void:
	_car_ref = car_ref
	stretch = true
	custom_minimum_size = Vector2(_SIZE, _SIZE)
	# `visual` (the card's top-half slot) is a plain Control, not a Container, so a
	# child's size_flags do nothing for it — only anchoring fills the slot.
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var svp := SubViewport.new()
	svp.size = Vector2i(_SIZE, _SIZE)
	svp.own_world_3d = true
	svp.transparent_bg = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(svp)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45.0, -30.0, 0.0)
	svp.add_child(light)

	var cam := Camera3D.new()
	cam.current = true
	cam.fov = 40.0
	svp.add_child(cam)
	# look_at() requires the camera to already be inside the tree; add_child above only
	# enters the tree once this whole container does, so aim it from a plain transform.
	# Targets the ORIGIN, not a guessed car-shaped offset — _center_on_pivot (below) is
	# what makes that correct for every car, by moving the CAR to its own visual centre
	# rather than moving the camera to wherever one particular car's centre happened to be.
	const _EYE := Vector3(3.2, 1.8, 3.6)
	cam.transform = Transform3D().looking_at(-_EYE, Vector3.UP)
	cam.position = _EYE

	_pivot = Node3D.new()
	svp.add_child(_pivot)


# CarProp.spawn expects the parent to already be inside the SceneTree (apply_car reads
# wheel mounts car.gd records in _ready), which _pivot is not yet during _init — the
# whole card subtree is still being assembled off-tree by the caller. Deferring the
# actual spawn to _ready (fired once this node itself enters the tree) is what makes
# that ordering hold regardless of how deep the card nesting is.
func _ready() -> void:
	if _spawned:
		return
	_spawned = true
	_spawn_now()


func _spawn_now() -> void:
	var opts := {"stop_physics": true, "disable_process": true}
	if _car_ref is Dictionary:
		opts["owned"] = _car_ref
	else:
		opts["index"] = int(_car_ref)
	var car := CarProp.spawn(_pivot, Scenes.car_scene(), opts)
	_center_on_pivot(car)


# Cars are authored in car.tscn around whatever origin convention each source model
# happened to use — not necessarily its own visual centre — so aiming the camera at a
# single fixed point (the OLD Vector3(0, 0.6, 0) guess) landed dead-on for some cars and
# "not quite centred" for others. Measuring the ACTUAL spawned mesh geometry and shifting
# the CAR (not the camera or pivot) so that geometry's centre sits at the pivot's own
# local origin fixes it for every car uniformly, and — since the turntable spin rotates
# _pivot around its own origin — also keeps the spin centred on the car's true visual
# middle instead of orbiting off-axis around wherever its unshifted origin was.
func _center_on_pivot(car: Node3D) -> void:
	var aabb := _visible_mesh_aabb(car, _pivot)
	if aabb.size == Vector3.ZERO:
		return
	car.position -= aabb.get_center()


# Union of every VISIBLE MeshInstance3D's AABB under `root`, transformed into
# `relative_to`'s local space. CarProp.spawn already pruned every inactive embedded car
# body (car_prop.gd's prune_bodies) before this runs, so this only ever measures the one
# model actually being shown.
static func _visible_mesh_aabb(root: Node3D, relative_to: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		var xform := relative_to.global_transform.affine_inverse() * mi.global_transform
		var box: AABB = xform * mi.mesh.get_aabb()
		out = box if first else out.merge(box)
		first = false
	return out


# Swap which car this SAME preview shows, reusing its SubViewport/camera/light rather than
# building a whole new CarCardPreview. hub_shell.gd keeps exactly ONE of these alive for
# the CAR page (reparenting it into whichever card is currently selected) instead of
# tearing one down and building a fresh one on every selection change — recreating the
# SubViewport + a full car.tscn instantiation on every swipe is what was reported as the
# carousel freezing the moment a player tried to move the selection. Only the CarProp
# under _pivot is rebuilt here; the expensive viewport/camera/light setup happens once.
func show_car(car_ref) -> void:
	_car_ref = car_ref
	if not _spawned:
		return  # _ready() will call _spawn_now() with the ref already updated above.
	for child in _pivot.get_children():
		_pivot.remove_child(child)
		child.queue_free()
	_spawn_now()


func _process(delta: float) -> void:
	if is_instance_valid(_pivot):
		_pivot.rotate_y(deg_to_rad(Config.data.card_carousel_car_spin_deg_per_s) * delta)

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
# car the player already has, so its actual paint/wheels show). ONE instance PER CAR is
# meant to be built once and kept alive for as long as that car might be shown again —
# hub_shell.gd caches instances by car ref and reparents a cached one back into a card
# rather than rebuilding a CarCardPreview (or re-spawning the CarProp inside an existing
# one) every time a car re-enters view; see show_car's own comment for the narrower case
# it still covers (an existing instance made to show a DIFFERENT car outright).

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
	cam.fov = Config.data.card_carousel_car_preview_fov_deg
	svp.add_child(cam)
	# look_at() requires the camera to already be inside the tree; add_child above only
	# enters the tree once this whole container does, so aim it from a plain transform.
	# Targets the ORIGIN, not a guessed car-shaped offset — _center_on_pivot (below) is
	# what makes that correct for every car, by moving the CAR to its own visual centre
	# rather than moving the camera to wherever one particular car's centre happened to be.
	#
	# _REFERENCE_FOV_DEG/_REFERENCE_EYE describe the ORIGINAL 40°/close-up composition —
	# not the shipped look any more, just the fixed baseline "this framing, at this fov,
	# reads as this apparent car size" is measured against. Apparent size for a fixed
	# subject scales with distance * tan(fov/2), so holding that product constant while
	# card_carousel_car_preview_fov_deg narrows is what moves the camera BACK by exactly
	# enough that a narrower lens still frames the car at roughly its old size — a smaller
	# fov alone (camera left in place) would just make the car look smaller, and picking a
	# new distance by feel would drift every time the fov tunable changes.
	const _REFERENCE_FOV_DEG := 40.0
	const _REFERENCE_EYE := Vector3(3.2, 1.8, 3.6)
	var reference_product := _REFERENCE_EYE.length() * tan(deg_to_rad(_REFERENCE_FOV_DEG * 0.5))
	var distance := reference_product / tan(deg_to_rad(cam.fov * 0.5))
	var eye := _REFERENCE_EYE.normalized() * distance
	cam.transform = Transform3D().looking_at(-eye, Vector3.UP)
	cam.position = eye

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


# Swap which car THIS SAME instance shows outright, reusing its SubViewport/camera/light
# rather than building a whole new CarCardPreview. hub_shell.gd's own CAR page keeps one
# instance PER CAR instead (cached by car ref, reparented between a card and a hidden
# holding pen as it enters/leaves view — see _sync_car_previews) since a cache hit needs
# no respawn at all, but a caller that genuinely wants "this same viewport, a different
# car" — rather than "this same car, wherever it's shown" — still has this. Only the
# CarProp under _pivot is rebuilt; the expensive viewport/camera/light setup stays put.
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

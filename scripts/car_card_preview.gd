class_name CarCardPreview
extends SubViewportContainer
# Docs: features/card-carousel.md — update in the same change as this file.
# Tests: tests/headless/test_card_carousel.gd — extend in the same change.
#
# ONE lightweight SubViewport per car-choice card: a frozen CarProp (see car_prop.gd)
# turntable-rotated by a Node3D pivot, not a whole reinstantiated scene per frame — the
# rotation is the only thing that changes after setup. Low resolution and a plain
# omni/directional light rather than the game's full render pipeline, since this is a
# thumbnail, not a stage.
#
# Usage: CarCardPreview.new(car_index_or_owned_dict) — pass either a CarLibrary index
# (int, for an unowned catalogue car in the Buy list) or an owned-car Dictionary (for a
# car the player already has, so its actual paint/wheels show).

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
	cam.transform = Transform3D().looking_at(Vector3(0.0, 0.6, 0.0) - Vector3(3.2, 1.8, 3.6), Vector3.UP)
	cam.position = Vector3(3.2, 1.8, 3.6)

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
	var opts := {"stop_physics": true, "disable_process": true}
	if _car_ref is Dictionary:
		opts["owned"] = _car_ref
	else:
		opts["index"] = int(_car_ref)
	CarProp.spawn(_pivot, Scenes.car_scene(), opts)


func _process(delta: float) -> void:
	if is_instance_valid(_pivot):
		_pivot.rotate_y(deg_to_rad(Config.data.card_carousel_car_spin_deg_per_s) * delta)

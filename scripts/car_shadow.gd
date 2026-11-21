class_name CarShadow
extends MeshInstance3D
# Docs: features/car-shadow.md — update in the same change as this file.
# Tests: tests/headless/test_car_shadow.gd — extend in the same change.
# A soft dark outline of the player's car body on the ground beneath it. The renderer has no real
# shadows, so this stands in for one: laid on whatever is below the car, fading as the car leaves it.
# Created and wired by free_roam.gd, level_view.gd and world.gd, like CarLamps.

const SHADER := preload("res://shaders/car_shadow.gdshader")
const LIFT_M := 0.04  # sits just above the ground so it never flickers into it

var _car: Node3D


func setup(car: Node3D) -> void:
	_car = car
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	mesh = quad
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	top_level = true
	visible = false


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_car) or not _car.is_inside_tree():
		visible = false
		return
	var cfg: GameConfig = Config.data
	var from := _car.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * cfg.car_shadow_fade_height_m)
	query.exclude = [(_car as CollisionObject3D).get_rid()] if _car is CollisionObject3D else []
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		visible = false
		return
	var up: Vector3 = hit["normal"]
	var fwd := (-_car.global_basis.z).slide(up)
	if fwd.length_squared() < 1e-6:
		fwd = up.cross(Vector3.RIGHT)
	var footprint := Vector2(_car.call("half_width"), _car.call("half_length")) * 2.0
	var quad := footprint + Vector2.ONE * 2.0 * cfg.car_shadow_soft_m
	var b := Basis.looking_at(fwd.normalized(), up)
	b.x *= quad.x
	b.z *= quad.y
	global_transform = Transform3D(b, hit["position"] + up * LIFT_M)
	var fade := 1.0 - from.distance_to(hit["position"]) / cfg.car_shadow_fade_height_m
	var mat := material_override as ShaderMaterial
	mat.set_shader_parameter("footprint_m", footprint)
	mat.set_shader_parameter("soft_m", cfg.car_shadow_soft_m)
	mat.set_shader_parameter("alpha", cfg.car_shadow_alpha * fade)
	visible = footprint.x > 0.0

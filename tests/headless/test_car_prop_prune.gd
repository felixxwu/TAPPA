extends GutTest
# car.tscn embeds ALL of the authored car glb bodies as instanced children (see
# car.tscn / car.gd:_model_node_names), and a car instance reveals ONE of them while
# hiding the rest. A frozen DISPLAY prop never switches its model, so CarProp.spawn
# prunes the bodies it will never show (car.gd:prune_inactive_bodies) BEFORE duplicating
# meshes — that's what keeps entering the car park / Free Roam from instancing + mesh-
# duplicating 9 hidden bodies per prop. These tests pin that LOGIC (the active body
# survives, the inactive ones are freed) against the shipped car.tscn structure — no
# tunable value or specific catalogue entry.

const CarProp = preload("res://scripts/car_prop.gd")

var _car_scene: PackedScene


func before_all() -> void:
	Config.reset()
	_car_scene = load("res://car.tscn")


# The index of the first shipped car that actually shows a glb body (use_model), so the
# test exercises real pruning without hardcoding any particular catalogue entry.
func _first_model_car_index() -> int:
	var cars := CarLibrary.all()
	for i in cars.size():
		if bool(cars[i].get("use_model", false)):
			return i
	return -1


# Names of every embedded glb body node present under a car instance.
func _present_body_nodes(car: Node) -> Array:
	var present: Array = []
	for spec in CarLibrary.all():
		var n := String(spec.get("model_node", ""))
		if n.is_empty() or present.has(n):
			continue
		if car.get_node_or_null(NodePath(n)) != null:
			present.append(n)
	return present


func test_a_display_prop_keeps_only_its_active_body() -> void:
	var index := _first_model_car_index()
	if index < 0:
		pass_test("no model-bodied car in the roster; pruning is a no-op")
		return
	var active := String(CarLibrary.all()[index].get("model_node", ""))

	var car: Node3D = CarProp.spawn(self, _car_scene, {"index": index})
	# Immediate free() inside prune means the inactive bodies are already gone here.
	var present := _present_body_nodes(car)

	assert_eq(present, [active],
		"a pruned display prop keeps ONLY the active body, freeing the other embedded glbs")
	var active_node := car.get_node_or_null(NodePath(active)) as Node3D
	assert_true(is_instance_valid(active_node) and active_node.visible,
		"the active body is still present and visible after pruning")
	car.queue_free()


func test_opting_out_of_pruning_keeps_every_body() -> void:
	var index := _first_model_car_index()
	if index < 0:
		pass_test("no model-bodied car in the roster; pruning is a no-op")
		return

	var kept: Node3D = CarProp.spawn(self, _car_scene, {"index": index, "prune_bodies": false})
	# With prune_bodies=false, every embedded body node stays (hidden but present).
	assert_gt(_present_body_nodes(kept).size(), 1,
		"prune_bodies=false leaves all embedded bodies in place")
	kept.queue_free()

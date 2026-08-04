extends "res://scripts/hq_carpark.gd"
# Test double for the boot-hang regression (features/menus.md → "A car that fails to
# spawn must never hang boot forever"): forces _obtain_parked_car to return null for
# one instance_id, simulating a car whose model/glb-embedded texture failed to load
# (see features/asset-pipeline.md), without needing to actually break a real asset on
# disk. Install it over `hq._carpark_ui` and set `fail_instance_id` before calling
# _build_lineup — it subclasses HqCarpark rather than HqController because the spawn
# seam moved there with the carpark cut (todo/hq-split.md).
var fail_instance_id := -1


func _obtain_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	if int(owned.get("instance_id", -1)) == fail_instance_id:
		return null
	return super._obtain_parked_car(owned, marker)

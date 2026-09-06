extends GutTest
# CarCardPreview (scripts/car_card_preview.gd) — the CAR page's spinning 3D thumbnail.
# Covers _center_on_pivot / _visible_mesh_aabb: the spawned car must be recentred on the
# pivot's own local origin regardless of whatever origin convention car.tscn happened to
# author that particular model around, since a fixed camera-offset guess was "not quite
# centred" for some cars — see features/card-carousel.md.

var _preview: CarCardPreview


func before_all() -> void:
	CarFixtures.install()


func after_all() -> void:
	CarFixtures.restore()


func after_each() -> void:
	if is_instance_valid(_preview):
		_preview.queue_free()


func test_the_spawned_car_is_centred_on_the_pivots_own_origin() -> void:
	_preview = CarCardPreview.new(0)
	add_child_autofree(_preview)
	await get_tree().process_frame

	var pivot: Node3D = _preview._pivot
	var aabb := CarCardPreview._visible_mesh_aabb(pivot, pivot)
	assert_true(aabb.size != Vector3.ZERO, "setup: the spawned car has visible geometry")
	# "Centred on the pivot" means the AABB's centre sits at (or very near) the pivot's own
	# local origin — the point the camera targets and the axis _process spins around.
	assert_almost_eq(aabb.get_center().length(), 0.0, 0.5,
		"the car must be shifted so its visual centre sits at the pivot's own origin")


# Regression: show_car used to just rebuild the CarProp without re-measuring — fine while
# every fixture car happened to share a similar origin, but a real roster with cars built
# around different origin conventions would recentre correctly only for whichever car
# spawned FIRST. Swapping to a different car must recentre it too.
func test_swapping_to_a_different_car_recentres_it_as_well() -> void:
	_preview = CarCardPreview.new(0)
	add_child_autofree(_preview)
	await get_tree().process_frame

	_preview.show_car(1)
	await get_tree().process_frame

	var pivot: Node3D = _preview._pivot
	var aabb := CarCardPreview._visible_mesh_aabb(pivot, pivot)
	assert_true(aabb.size != Vector3.ZERO, "setup: the swapped-to car has visible geometry")
	assert_almost_eq(aabb.get_center().length(), 0.0, 0.5,
		"the newly shown car must also be centred on the pivot's own origin")

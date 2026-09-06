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


# Regression: narrowing card_carousel_car_preview_fov_deg without also moving the camera
# back makes the car look SMALLER, not just "less distorted" — a narrower lens is more
# zoomed out per degree, not less. Camera distance must be derived from the fov so that
# distance * tan(fov/2) — the quantity a fixed subject's apparent size actually scales
# with — stays constant across whatever fov is currently configured, rather than
# hardcoding both independently. Checked as an INVARIANT across two different fov values,
# not against a specific number, so retuning either GameConfig's fov default or the
# script's internal reference composition can't make this test pin a value nobody chose.
func test_camera_distance_compensates_for_the_configured_fov() -> void:
	var original_fov := Config.data.card_carousel_car_preview_fov_deg

	Config.data.card_carousel_car_preview_fov_deg = 20.0
	var wide := CarCardPreview.new(0)
	add_child_autofree(wide)
	await get_tree().process_frame
	var wide_cam: Camera3D = wide.find_children("*", "Camera3D", true, false)[0]

	Config.data.card_carousel_car_preview_fov_deg = 8.0
	var narrow := CarCardPreview.new(1)
	add_child_autofree(narrow)
	await get_tree().process_frame
	var narrow_cam: Camera3D = narrow.find_children("*", "Camera3D", true, false)[0]

	Config.data.card_carousel_car_preview_fov_deg = original_fov

	assert_almost_eq(wide_cam.fov, 20.0, 0.01, "the camera must actually use the configured fov")
	assert_almost_eq(narrow_cam.fov, 8.0, 0.01)
	assert_gt(narrow_cam.position.length(), wide_cam.position.length(),
		"a narrower fov must move the camera further back")

	var wide_product := wide_cam.position.length() * tan(deg_to_rad(wide_cam.fov * 0.5))
	var narrow_product := narrow_cam.position.length() * tan(deg_to_rad(narrow_cam.fov * 0.5))
	assert_almost_eq(wide_product, narrow_product, 0.01,
		"distance * tan(fov/2) must stay constant across fov values, or apparent car size drifts with it")

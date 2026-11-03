extends GutTest
# CarPreviewCache (scripts/car_preview_cache.gd) — the session-lifetime cache of
# CarCardPreview instances keyed by car ref. Covers get_or_build/park (a car's preview is
# built once and reused, not respawned on every re-entry into view) and warm_all
# (background-builds every current car's preview, spread across frames rather than in one
# synchronous burst) — see features/card-carousel.md.

var _added_previews: Array = []


func before_all() -> void:
	CarFixtures.install()


func after_all() -> void:
	CarFixtures.restore()


func before_each() -> void:
	# Save is shared across every test file in this run: start from a clean profile.
	Save.profile = Save._default_profile()


func after_each() -> void:
	# get_or_build/park leave every built preview parented somewhere under the
	# CarPreviewCache autoload (never under this test's own tree, so add_child_autofree
	# doesn't reach it) — free each one explicitly, or it's an orphan GUT flags at the end
	# of the run and a real leak in the running cache besides.
	for key in _added_previews:
		var preview: CarCardPreview = CarPreviewCache._cache.get(key)
		if preview != null and is_instance_valid(preview):
			if preview.get_parent() != null:
				preview.get_parent().remove_child(preview)
			# free(), not queue_free(): these were never added via add_child_autofree (they
			# live under the CarPreviewCache autoload, not this test's own tree), so GUT's
			# orphan monitor snapshots node counts before a deferred queue_free would have
			# actually run — an immediate free is what keeps the count accurate.
			preview.free()
		CarPreviewCache._cache.erase(key)
	_added_previews.clear()


func _track(car_ref) -> void:
	_added_previews.append(CarPreviewCache.key_for(car_ref))


func test_get_or_build_returns_the_same_instance_for_the_same_car_ref() -> void:
	_track(0)
	var first := CarPreviewCache.get_or_build(0)
	var second := CarPreviewCache.get_or_build(0)
	assert_eq(first, second, "the same car ref must reuse the same built preview")


func test_owned_and_catalogue_keys_never_collide() -> void:
	var owned := {"instance_id": 0, "model_id": "fx_light_rwd"}
	assert_ne(CarPreviewCache.key_for(owned), CarPreviewCache.key_for(0),
		"an owned car's instance_id and a catalogue index share the number 0 but must not share a cache key")


# A fitted wing changes the model, so the same car with and without it must not share a preview.
func test_fitting_a_wing_gives_the_car_a_new_preview_key() -> void:
	var bare := {"instance_id": 3, "model_id": "fx_light_rwd", "boosts": []}
	var winged := bare.duplicate(true)
	winged["boosts"] = [{"id": "aero", "effect": {}}]
	assert_true(UpgradeLibrary.aero_fitted(winged), "the fixture really has the wing on")
	assert_ne(CarPreviewCache.key_for(bare), CarPreviewCache.key_for(winged))


func test_park_then_get_or_build_reuses_without_rebuilding() -> void:
	_track(1)
	var preview := CarPreviewCache.get_or_build(1)
	await get_tree().process_frame
	CarPreviewCache.park(preview)
	var reused := CarPreviewCache.get_or_build(1)
	assert_eq(reused, preview, "a parked preview must be reused, not rebuilt, on the next request")
	assert_ne(reused.get_parent(), CarPreviewCache._graveyard,
		"get_or_build must hand back an UNPARENTED preview, not one still sitting in the graveyard")


func test_a_display_car_bakes_no_engine_voice() -> void:
	var parent := Node3D.new()
	add_child_autofree(parent)
	var car: Node = CarProp.spawn(parent, Scenes.car_scene(), {"index": 0, "stop_physics": true})
	assert_null(car.get_node("EngineAudio")._synth)


# A page queue_free()d WITHOUT parking its previews leaves the preview parented under that
# (still-alive-until-end-of-frame) page; the caller's add_child would fail on it.
func test_get_or_build_unparents_a_preview_left_inside_a_dying_page() -> void:
	_track(2)
	var preview := CarPreviewCache.get_or_build(2)
	var page := Control.new()
	add_child_autofree(page)
	page.add_child(preview)
	page.queue_free()
	var again := CarPreviewCache.get_or_build(2)
	assert_eq(again, preview, "the still-valid preview is reused")
	assert_null(again.get_parent(), "and handed back unparented so the caller can add_child it")


# A new world replaces every owned car, so the old world's owned previews are dropped;
# catalogue previews survive.
func test_world_changed_drops_owned_previews_only() -> void:
	var owned := {"instance_id": 4242, "model_id": "zzz_world_drop"}
	_track(owned)
	_track(3)
	var owned_preview := CarPreviewCache.get_or_build(owned)
	var catalogue_preview := CarPreviewCache.get_or_build(3)
	CarPreviewCache.park(owned_preview)
	CarPreviewCache.park(catalogue_preview)

	WorldSession.world_changed.emit()

	assert_false(CarPreviewCache._cache.has(CarPreviewCache.key_for(owned)),
		"the old world's owned preview leaves the cache")
	assert_false(is_instance_valid(owned_preview), "and is freed")
	assert_true(CarPreviewCache._cache.has(CarPreviewCache.key_for(3)),
		"catalogue previews are kept")
	assert_true(is_instance_valid(catalogue_preview))

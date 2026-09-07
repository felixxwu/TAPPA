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
	# CarPreviewCache reads the REAL Save autoload, shared globally across every test file
	# in this run — reset it so warm_all's assertions don't depend on what another test
	# left behind.
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


func test_park_then_get_or_build_reuses_without_rebuilding() -> void:
	_track(1)
	var preview := CarPreviewCache.get_or_build(1)
	await get_tree().process_frame
	CarPreviewCache.park(preview)
	var reused := CarPreviewCache.get_or_build(1)
	assert_eq(reused, preview, "a parked preview must be reused, not rebuilt, on the next request")
	assert_ne(reused.get_parent(), CarPreviewCache._graveyard,
		"get_or_build must hand back an UNPARENTED preview, not one still sitting in the graveyard")


func test_warm_all_builds_a_preview_for_every_owned_and_unowned_car() -> void:
	# A model id that matches nothing in the (fixture) catalogue, so this owned car
	# doesn't make any catalogue entry look "owned" and get skipped by warm_all's own
	# unowned-only filter — the point here is that BOTH lists get warmed, not one at the
	# other's expense.
	var owned := {"instance_id": 999, "model_id": "zzz_not_a_real_model"}
	Save.profile[Save.KEY_CARS] = [owned]
	_track(owned)
	for index in CarLibrary.all().size():
		_track(index)

	await CarPreviewCache.warm_all()

	assert_true(CarPreviewCache._cache.has(CarPreviewCache.key_for(owned)),
		"the owned car must be warmed")
	for index in CarLibrary.all().size():
		assert_true(CarPreviewCache._cache.has(CarPreviewCache.key_for(index)),
			"catalogue car %d must be warmed" % index)

	Save.profile[Save.KEY_CARS] = []


# A second warm_all() must WAIT for a pass that is already running, not return "done"
# while cars are still building — HubShell._ready holds its loading screen until the
# awaited call returns, so an early return would lift the screen with the cache
# half-built and reintroduce exactly the interactive trickle this cache exists to
# remove (features/card-carousel.md → the warming section).
func test_warm_all_awaits_an_inflight_pass() -> void:
	# A not-in-catalogue owned car guarantees the pass has REAL work left no matter what
	# earlier tests left cached, so it deterministically suspends mid-pass with _warming
	# still true. It is first in warm_all's refs (owned cars are collected before
	# catalogue indices), so the fire-and-forget call below always yields inside it.
	var owned := {"instance_id": 777, "model_id": "zzz_warm_wait"}
	Save.profile[Save.KEY_CARS] = [owned]
	_track(owned)
	for index in CarLibrary.all().size():
		_track(index)

	CarPreviewCache.warm_all()  # fire-and-forget: runs to its first yield, then continues alone
	assert_true(CarPreviewCache._warming, "setup: a warming pass is in flight")

	await CarPreviewCache.warm_all()

	assert_false(CarPreviewCache._warming,
		"returning from an awaited warm_all must mean no pass is still running")
	assert_true(CarPreviewCache._cache.has(CarPreviewCache.key_for(owned)),
		"the in-flight pass must have completed, not been abandoned")

	Save.profile[Save.KEY_CARS] = []

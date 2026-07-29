extends GutTest
# The garage parks the owned cars as heavy physics props (hq.gd._spawn_parked_car:
# full car scene + per-instance mesh duplication). To avoid re-instancing them on
# every re-entry, the lineup keeps a reuse cache keyed by instance_id + a deep hash
# of the owned dict (hq.gd._car_cache / _obtain_parked_car). These tests pin the
# CACHE BEHAVIOUR (reuse unchanged / respawn changed / evict sold) — not any tuning
# value — so they survive catalogue/config retuning.

const CarFixtures = preload("res://tests/headless/car_fixtures.gd")
const TEST_PATH := "user://test_lineup_cache_profile.json"

var _save: Node


func before_each() -> void:
	get_viewport().gui_release_focus()
	Config.reset()
	CarFixtures.install()
	_save = get_node("/root/Save")
	_clean()
	_save.profile_path = TEST_PATH
	_save.save_disabled = false
	_save.load_or_new()
	_save.profile["starter_picked"] = true
	_save.grant_car("fx_light_rwd")
	_save.grant_car("fx_light_rwd")
	RallySession.auto_load_scenes = false
	if RallySession.is_active():
		RallySession.abandon()


func after_each() -> void:
	if RallySession.is_active():
		RallySession.abandon()
	RallySession.auto_load_scenes = true
	_clean()
	_save.profile_path = _save.DEFAULT_PROFILE_PATH
	Config.reset()
	CarFixtures.restore()


func _clean() -> void:
	for suffix in ["", ".bak", ".tmp"]:
		if FileAccess.file_exists(TEST_PATH + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH + suffix))


# Boot HQ and park a lineup of the given owned cars, waiting until every prop is in
# AND settled (frozen) — so transform assertions see the final resting pose.
func _build_and_wait(hq: Node3D, cars: Array) -> void:
	hq._build_lineup(cars)
	for _i in 600:
		if hq._cars.size() >= hq._eligible.size():
			break
		await get_tree().process_frame
	# Then wait for the settle-then-freeze to complete on every parked car.
	for _i in 600:
		if _all_frozen(hq):
			break
		await get_tree().process_frame


func _all_frozen(hq: Node3D) -> bool:
	if hq._cars.is_empty():
		return false
	for car in hq._cars:
		if not is_instance_valid(car) or not car.freeze:
			return false
	return true


# The live instance ids of the parked car nodes, in bay order.
func _node_ids(hq: Node3D) -> Array:
	var ids: Array = []
	for car in hq._cars:
		ids.append(car.get_instance_id())
	return ids


func _owned_cars() -> Array:
	return _save.profile.get("cars", []).duplicate(true)


func test_rebuilding_an_unchanged_lineup_reuses_the_cached_cars() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	await _build_and_wait(hq, _owned_cars())
	var first_ids := _node_ids(hq)
	assert_eq(first_ids.size(), 2, "both owned cars park")

	# Capture the settled resting heights before the rebuild.
	var settled_y: Array = []
	for car in hq._cars:
		settled_y.append(car.global_transform.origin.y)

	await _build_and_wait(hq, _owned_cars())
	var second_ids := _node_ids(hq)
	assert_eq(second_ids, first_ids,
		"an unchanged rebuild reuses the exact same car node instances")

	# Reused cars must re-seat ON their suspension, not drop the frozen body to the
	# ground (marker y = 0) and sink — regression guard.
	for i in hq._cars.size():
		assert_almost_eq(hq._cars[i].global_transform.origin.y, float(settled_y[i]), 0.05,
			"a reused car keeps its settled resting height (doesn't sink)")


func test_a_changed_car_respawns_while_the_rest_are_reused() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	var cars := _owned_cars()
	await _build_and_wait(hq, cars)
	var before := _node_ids(hq)

	# Mutate the FIRST car's owned dict (any data change flips its deep hash), leave the
	# second untouched.
	var changed := cars.duplicate(true)
	var tuning: Dictionary = changed[0].get("tuning", {})
	tuning["engine_detune"] = 0.5 if float(tuning.get("engine_detune", 1.0)) != 0.5 else 0.75
	changed[0]["tuning"] = tuning

	await _build_and_wait(hq, changed)
	var after := _node_ids(hq)

	assert_ne(after[0], before[0], "the mutated car is respawned (fresh node)")
	assert_eq(after[1], before[1], "the unchanged car is reused (same node)")


# Whether a display car prop carries live synthetic engine smoke (added by
# hq.gd._add_synthetic_smoke only for a damaged car).
func _has_smoke(car: Node) -> bool:
	if not is_instance_valid(car):
		return false
	return not car.find_children("*", "EngineSmoke", true, false).is_empty()


# Repairing the selected car from the garage Repair button heals it immediately: the
# wrecked prop (which smokes) is rebuilt as a healthy one that does not — the reported
# bug was the stale prop smoking on after a repair.
func test_repairing_from_the_garage_stops_the_smoke() -> void:
	var id := int(_save.profile["cars"][0]["instance_id"])
	_save.set_selected_car(id)
	_save.wreck_car(id)
	_save.add_item(UpgradeLibrary.REPAIR_KIT_ID, 1)

	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._ensure_lift_car()
	assert_true(_has_smoke(hq._lift_car), "precondition: a wrecked selected car smokes")

	hq._repair_selected_car()
	assert_true(is_instance_valid(hq._lift_car), "the prop still holds a car after the repair")
	assert_false(_has_smoke(hq._lift_car), "the repaired car no longer smokes")


# Repairing the wrecked focused car in the car park respawns a healthy prop that no
# longer smokes (same stale-prop bug, other repair entry point).
func test_repairing_in_the_car_park_stops_the_smoke() -> void:
	var id := int(_save.profile["cars"][0]["instance_id"])
	_save.wreck_car(id)
	_save.add_item(UpgradeLibrary.REPAIR_KIT_ID, 1)

	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	await _build_and_wait(hq, _owned_cars_live())
	hq._focus = 0
	var wrecked_car = hq._cars[0]
	assert_true(_has_smoke(wrecked_car), "precondition: the wrecked parked car smokes")

	hq._repair_focused_car()
	await _wait_for_lineup(hq)
	assert_false(_has_smoke(hq._cars[0]), "the repaired parked car no longer smokes")


# The lift prop is a cache of the selected car's owned data, keyed on instance id AND a
# deep hash of the owned dict (hq.gd._ensure_lift_car). An in-place data change to the
# selected car (repair, upgrade toggle, engine swap, ...) flips that hash, so the prop
# auto-respawns on the next _ensure_lift_car — no mutator has to remember to force it.
# This is the invariant that keeps every lift mutator safe; the two repair tests above
# are one visible consequence of it.
func test_lift_prop_respawns_when_the_selected_cars_data_changes() -> void:
	var id := int(_save.profile["cars"][0]["instance_id"])
	_save.set_selected_car(id)

	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._ensure_lift_car()
	var before: int = hq._lift_car.get_instance_id()

	# Any in-place data change flips the owned dict's deep hash.
	var tuning: Dictionary = _save.get_car(id).get("tuning", {})
	tuning["engine_detune"] = 0.5 if float(tuning.get("engine_detune", 1.0)) != 0.5 else 0.75
	_save.set_tuning(id, tuning)

	hq._ensure_lift_car()
	assert_true(is_instance_valid(hq._lift_car), "the lift still holds a car")
	assert_ne(hq._lift_car.get_instance_id(), before,
		"a data change to the selected car respawns the lift prop (fresh node)")


# The tuning lift and the car-park lineup share _car_cache (hq.gd._spawn_lift_car /
# _obtain_parked_car): a car already warmed by one must be reused by the other instead
# of paying CarProp.spawn again (car.tscn embeds every car glb — the "small lag on
# every tuning-lift car swap" this cache-sharing avoids).
func test_ensure_lift_car_reuses_an_already_parked_lineup_node() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	var cars := _owned_cars()
	await _build_and_wait(hq, cars)  # warms _car_cache for both owned cars
	var parked_id: int = hq._cars[0].get_instance_id()

	_save.set_selected_car(int(cars[0].get("instance_id", -1)))
	hq._ensure_lift_car()

	assert_true(is_instance_valid(hq._lift_car), "the lift holds a car")
	assert_eq(hq._lift_car.get_instance_id(), parked_id,
		"the lift reuses the already-warm parked-lineup node instead of re-instancing")


# The flip side of the sharing: releasing the lift car must not free a node the cache
# still tracks, or the cache would hold a dangling reference the next reader crashes on.
func test_clearing_the_lift_car_keeps_a_cached_node_alive_and_hidden() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	var id := int(_save.profile["cars"][0]["instance_id"])
	_save.set_selected_car(id)
	hq._ensure_lift_car()
	var node: Node3D = hq._lift_car

	hq._clear_lift_car()

	assert_true(is_instance_valid(node), "the released lift car node is not freed")
	assert_true(hq._car_cache.has(id), "it stays warm in _car_cache for reuse")
	assert_eq(hq._car_cache[id].get("node"), node,
		"the cache entry still points at the same live node")
	assert_false(node.visible, "the released node is hidden rather than left on show")


# A car built fresh BY the lift (nothing parked yet) still lands in _car_cache, so a
# later car-park lineup build reuses it instead of instancing its own copy.
func test_a_car_spawned_by_the_lift_warms_the_cache_for_the_parked_lineup() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	var id := int(_save.profile["cars"][0]["instance_id"])
	_save.set_selected_car(id)
	hq._ensure_lift_car()
	var lift_node_id: int = hq._lift_car.get_instance_id()
	hq._clear_lift_car()  # leave the lift, as _go_to(CARPARK) would on the way out

	await _build_and_wait(hq, _owned_cars())

	assert_eq(hq._cars[0].get_instance_id(), lift_node_id,
		"the parked lineup reuses the node the lift already built, not a fresh instance")


# Regression: opening the garage picker borrows the lift car's node into the parked
# lineup (_obtain_parked_car, sharing _car_cache with the lift). Reselecting the SAME
# car from the picker used to hit _ensure_lift_car's id/hash "no-op" fast path while
# the node was still hidden + stowed off-screen (_release_page_props, run by
# _clear_lineup on the way back to the lift) — the car vanished from the lift instead
# of staying shown. Reproduces the picker's hide-then-reselect sequence directly.
func test_reselecting_the_same_car_from_the_garage_picker_keeps_it_on_the_lift() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	var id := int(_save.profile["cars"][0]["instance_id"])
	_save.set_selected_car(id)
	hq._ensure_lift_car()
	assert_true(hq._lift_car.visible, "precondition: the selected car is shown on the lift")

	# Open the garage picker: it borrows the SAME cached node into the parked lineup.
	await _build_and_wait(hq, _owned_cars())
	assert_true(hq._car_cache[id]["node"] == hq._lift_car,
		"precondition: the picker borrowed the lift's own node, not a fresh one")

	# Reselect the SAME car (id/hash unchanged) — this is what _select_garage_car does
	# on the way back: hide/stow the parked page, then _ensure_lift_car for the same id.
	hq._release_page_props()
	assert_false(hq._lift_car.visible, "precondition: leaving the picker stowed the shared node")

	hq._ensure_lift_car()

	assert_true(is_instance_valid(hq._lift_car), "the lift still holds a car")
	assert_true(hq._lift_car.visible, "reselecting the same car re-shows it on the lift")


# The flip side: with no data change, _ensure_lift_car reuses the exact same prop node —
# it must not respawn on every call (that's what the hash guard buys over a blind rebuild).
func test_lift_prop_reused_when_the_selected_car_is_unchanged() -> void:
	var id := int(_save.profile["cars"][0]["instance_id"])
	_save.set_selected_car(id)

	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	hq._ensure_lift_car()
	var before: int = hq._lift_car.get_instance_id()

	hq._ensure_lift_car()
	assert_eq(hq._lift_car.get_instance_id(), before,
		"an unchanged selected car reuses the same lift prop node")


# Owned cars as LIVE Save references (not deep copies) — the car-park eligible lineup
# holds live refs, so use_repair_kit's in-place heal flips their deep hash and forces
# a respawn. _owned_cars() (deep copy) would sever that link.
func _owned_cars_live() -> Array:
	return _save.profile.get("cars", [])


func _wait_for_lineup(hq: Node3D) -> void:
	for _i in 600:
		if hq._cars.size() >= hq._eligible.size():
			break
		await get_tree().process_frame


func test_selling_a_car_evicts_its_cached_node() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	var cars := _owned_cars()
	await _build_and_wait(hq, cars)
	var sold_id := int(cars[1].get("instance_id", -1))
	assert_true(hq._car_cache.has(sold_id), "the car is cached after parking")
	var sold_node = hq._car_cache[sold_id]["node"]

	# The player no longer owns the second car; a rebuild should evict + free it.
	_save.profile["cars"] = [cars[0]]
	await _build_and_wait(hq, _owned_cars())

	assert_false(hq._car_cache.has(sold_id), "the sold car's cache entry is dropped")
	await get_tree().process_frame
	assert_false(is_instance_valid(sold_node), "the sold car's node is freed")


# Free Roam previews are pre-warmed ONCE and kept in memory for the session (negative
# instance_id). Building an owned-car lineup must NOT evict them — re-warming them is the
# lag spike the cache exists to avoid. Pins the eviction rule (keep negatives), not a value.
func test_prewarmed_previews_survive_an_owned_lineup_rebuild() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	# Stand in a pre-warmed preview: a cached node under a NEGATIVE instance id.
	var preview := Node3D.new()
	hq.add_child(preview)
	hq._car_cache[-7] = {"hash": 12345, "node": preview}

	# Building the owned lineup runs _evict_unowned_cached_cars; the preview isn't "owned".
	await _build_and_wait(hq, _owned_cars())

	assert_true(hq._car_cache.has(-7), "a pre-warmed preview is kept across an owned rebuild")
	assert_true(is_instance_valid(preview), "the pre-warmed preview node is not freed")


# --- Deferred Free Roam prewarm (todo/mobile-web-performance.md §2.14 / E8) ----------
# The catalogue prewarm used to run synchronously inside HQ's boot, behind the loading
# cover, where it dominated time-to-first-interaction. It now runs one prop per frame
# AFTER the cover lifts (hq.gd._prewarm_free_roam_deferred). These tests pin that the
# deferred work actually COMPLETES and that Free Roam still gets cached props — never a
# timing or a prop count, both of which are measurements / authored data.

# Every catalogue preview id is warm in the cache once the deferred loop returns.
func _all_previews_warm(hq: Node3D) -> bool:
	for preview in hq._all_car_previews():
		var id := int(preview.get("instance_id", -1))
		if not hq._car_cache.has(id):
			return false
		if not is_instance_valid(hq._car_cache[id].get("node")):
			return false
	return true


func test_deferred_prewarm_runs_to_completion() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	assert_false(hq._prewarm_complete, "HQ boot leaves the prewarm still to do")
	await hq._prewarm_free_roam_deferred()

	assert_true(hq._prewarm_complete, "the deferred prewarm reports completion")
	assert_false(hq._prewarm_running, "the deferred prewarm is no longer in flight")
	assert_true(_all_previews_warm(hq), "every catalogue preview is warm in the cache")


func test_deferred_prewarm_is_idempotent() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	await hq._prewarm_free_roam_deferred()
	var first := {}
	for id in hq._car_cache:
		if int(id) < 0:
			first[id] = hq._car_cache[id]["node"].get_instance_id()

	await hq._prewarm_free_roam_deferred()  # a stray second call must be a no-op

	for id in first:
		assert_true(hq._car_cache.has(id), "preview %d is still cached" % int(id))
		assert_eq(hq._car_cache[id]["node"].get_instance_id(), first[id],
			"preview %d kept its warm prop rather than respawning" % int(id))


# The whole point of the prewarm: opening Free Roam parks the ALREADY-WARM props instead
# of instancing fresh ones.
func test_free_roam_entry_reuses_the_prewarmed_props() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame
	await hq._prewarm_free_roam_deferred()

	var warm := {}
	for id in hq._car_cache:
		if int(id) < 0:
			warm[hq._car_cache[id]["node"].get_instance_id()] = true

	hq._enter_free_roam()
	await _wait_for_lineup(hq)

	assert_false(hq._cars.is_empty(), "Free Roam parks a lineup")
	for car in hq._cars:
		assert_true(warm.has(car.get_instance_id()),
			"the parked Free Roam car is a pre-warmed prop, not a fresh instance")


# Entering Free Roam BEFORE the deferred warm finishes must still work: the lineup builds
# its own props (the pre-deferral cost, for the not-yet-warm remainder), those land in the
# same cache, and the deferred loop still runs to completion afterwards without
# respawning or freeing anything the live lineup is using.
func test_free_roam_entered_before_the_prewarm_finishes_still_works() -> void:
	var hq: Node3D = load("res://hq.tscn").instantiate()
	add_child_autofree(hq)
	await get_tree().process_frame

	hq._enter_free_roam()   # immediately — nothing warm yet
	await _wait_for_lineup(hq)
	assert_false(hq._cars.is_empty(), "Free Roam parks a lineup with a cold cache")
	var live := []
	for car in hq._cars:
		live.append(car.get_instance_id())

	await hq._prewarm_free_roam_deferred()

	assert_true(hq._prewarm_complete, "the deferred prewarm still completes")
	assert_true(_all_previews_warm(hq), "every catalogue preview ends up warm")
	for id in live:
		assert_true(is_instance_valid(instance_from_id(id)),
			"the live Free Roam prop was not freed out from under the lineup")

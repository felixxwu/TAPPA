extends GutTest
# The drivable overworld's zone/marker layer: `OverworldZone` (the dwell state machine),
# `OverworldMarker` (which sign a rally wears) and `OverworldZones` (the owner of the set).
# See docs/superpowers/specs/2026-08-17-overworld-hq-design.md, slice 2, and
# features/overworld.md.
#
# Everything here is SCENE-FREE and physics-free by design: `tick` / `update_with` take the
# delta, the car position and the speed as arguments, and `visuals: false` skips every mesh,
# so the whole activation path runs without a world, a car or a renderer.
#
# NOTHING in this file pins a tunable. The dwell duration, the zone radius, the stop-speed
# threshold, the spin rate, the marker height, the draw distance and the ghost cap are all
# GameConfig values a designer retunes freely, so every threshold this file has to cross is
# READ from the subject (`dwell_seconds()`, `radius()`, `stop_kmh()`) or from `Config.data`
# and then overshot by a wide margin.

const SaveTestHelpers = preload("res://tests/headless/save_test_helpers.gd")
const TEST_PATH := "user://test_overworld_zones.json"

# Map->world scale for the manager tests. Arbitrary and local to this file — the real
# conversion belongs to overworld.gd and is injected, which is the seam we exploit here.
const MAP_TO_WORLD := 1000.0


func before_each() -> void:
	# Synthetic rosters only: reveal is geometric and the fixtures' pin positions are
	# load-bearing (fx_open lights a wide circle that reaches every other fixture pin).
	RallyFixtures.install()
	CarFixtures.install()
	UpgradeFixtures.install()
	SaveTestHelpers.redirect(TEST_PATH)


func after_each() -> void:
	SaveTestHelpers.cleanup(TEST_PATH)
	RallyFixtures.restore()
	CarFixtures.restore()
	UpgradeFixtures.restore()


# --- Helpers ------------------------------------------------------------------------------


func _fx(id: String) -> Dictionary:
	for rally in RallyFixtures.rallies():
		if String(rally["id"]) == id:
			return rally
	return {}


func _zone(rally: Dictionary, always_revealed := false) -> OverworldZone:
	var zone := OverworldZone.new()
	# Set before setup(): setup() evaluates the fog gate, and the garage exemption has to be
	# in place by then.
	zone.always_revealed = always_revealed
	add_child_autofree(zone)
	zone.setup(rally, Vector3.ZERO, false)   # visuals off — the state machine only
	# ARM it. A zone will not fire until it has seen the car outside it once (see the
	# arm-on-exit note in OverworldZone.tick), so every dwell test has to start from outside —
	# which is also what really happens: the player drives up to a zone. Done here rather than
	# in each test so no test can silently forget and pass for the wrong reason.
	zone.tick(1.0 / 60.0, _far_from(zone), 0.0)
	return zone


# A position comfortably outside the zone, whatever the radius is tuned to.
func _far_from(zone: OverworldZone) -> Vector3:
	return zone.centre + Vector3(zone.radius() * 4.0 + 50.0, 0.0, 0.0)


# Mark a rally completed in the LIVE profile. `tick` re-checks reveal against Save.profile at
# the moment of activation, so a reveal test has to move the real profile, not a copy.
func _complete(rally_id: String) -> void:
	var rallies: Dictionary = Save.profile[Save.KEY_RALLIES]
	rallies[rally_id] = {"completed": true, "best_placed": 1}


# Enough seconds of ticking that ANY reasonable dwell setting has been exceeded several times
# over — so "it never fired" means the behaviour, not a too-short loop.
func _generous_seconds(zone: OverworldZone) -> float:
	return zone.dwell_seconds() * 4.0 + 1.0


func _drive(zone: OverworldZone, pos: Vector3, speed_kmh: float, seconds: float) -> void:
	var dt := 1.0 / 60.0
	var elapsed := 0.0
	while elapsed < seconds:
		zone.tick(dt, pos, speed_kmh)
		elapsed += dt


# A speed comfortably above the stop threshold, whatever it is tuned to.
func _moving_kmh(zone: OverworldZone) -> float:
	return zone.stop_kmh() + 25.0


# --- The dwell state machine ---------------------------------------------------------------


func test_moving_car_never_completes_a_dwell() -> void:
	# The product rule: the dwell is a PARKING gesture. Sitting in the circle at speed for as
	# long as you like must never drag the player into a rally they were only driving through.
	var zone := _zone(_fx("fx_open"))
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	assert_true(zone.revealed(), "fx_open is revealed once completed (else this test is vacuous)")
	watch_signals(zone)
	_drive(zone, Vector3.ZERO, _moving_kmh(zone), _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 0, "a moving car never activates the zone")
	assert_eq(zone.progress, 0.0, "a moving car accumulates no progress at all")


func test_movement_resets_a_partial_dwell_to_zero() -> void:
	# Driving off is THE cancel gesture — there is no confirm prompt — so a part-accumulated
	# dwell must be gone, not merely paused, the moment the car moves.
	var zone := _zone(_fx("fx_open"))
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	var dwell := zone.dwell_seconds()
	if dwell <= 0.0:
		# An instant-dwell tuning has no "partial" state to cancel; nothing to assert.
		pass_test("dwell is tuned to instant — no partial state exists to reset")
		return
	_drive(zone, Vector3.ZERO, 0.0, dwell * 0.4)
	assert_gt(zone.progress, 0.0, "parking accumulates progress (else the reset case is vacuous)")
	assert_lt(zone.progress, 1.0, "the partial dwell has not completed yet")
	# One long moving tick: the accumulator is logically dropped on ANY movement, and the ring
	# only drains for show, so a tick this long leaves nothing behind either way.
	zone.tick(dwell, Vector3.ZERO, _moving_kmh(zone))
	assert_eq(zone.progress, 0.0, "movement resets the accumulated dwell to zero")


func test_activation_fires_exactly_once_per_dwell() -> void:
	# A car left parked on a zone must not machine-gun the signal — the panel would reopen
	# every frame.
	var zone := _zone(_fx("fx_open"))
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	watch_signals(zone)
	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 1, "a completed dwell activates exactly once")


func test_dwell_outside_the_radius_never_fires() -> void:
	# The dwell gate is a flat-plane containment test, not just "stopped somewhere" — parking
	# next to a zone must do nothing.
	var zone := _zone(_fx("fx_open"))
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	var far := Vector3(zone.radius() * 10.0, 0.0, 0.0)
	assert_false(zone.contains(far), "the far point is outside the zone")
	assert_gt(zone.plane_distance_to(far), zone.radius(), "the far point is beyond the radius")
	watch_signals(zone)
	_drive(zone, far, 0.0, _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 0, "a dwell completed outside the radius never fires")
	assert_eq(zone.progress, 0.0, "no progress accumulates outside the radius")


# --- The fog gate --------------------------------------------------------------------------


func test_unrevealed_zone_refuses_to_activate() -> void:
	# The fog gate is authoritative at the moment of truth, not just at build time: an
	# unrevealed zone must neither accumulate nor fire. fx_gated is pinned outside every lit
	# circle on a fresh profile, which is exactly the dark case.
	var zone := _zone(_fx("fx_gated"))
	assert_false(zone.revealed(), "fx_gated is dark on a fresh profile (no completions)")
	watch_signals(zone)
	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 0, "an unrevealed zone never activates")
	assert_eq(zone.progress, 0.0, "an unrevealed zone advertises no countdown either")


func test_revealing_a_zone_lets_it_activate() -> void:
	# The complement of the case above, so "it never fires" is not just a broken fixture:
	# completing fx_open lights fx_gated (fx_open authors a reveal_radius that reaches it),
	# and the same zone then activates on the same input.
	var zone := _zone(_fx("fx_gated"))
	watch_signals(zone)
	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 0, "dark first")
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	assert_true(zone.revealed(), "completing fx_open lights fx_gated")
	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 1, "a revealed zone activates on a completed dwell")


# A zone the car STARTS inside must not fire until the car has left it once. Two real cases,
# both of which teleported the player somewhere they never asked to go before this latch existed:
# the garage sits at RallyLibrary.HQ_MAP_POS, which is also the default spawn for a profile with
# no completed rally, so a brand-new player was parked in the garage zone from frame one; and a
# player returning from a rally is parked beside the zone they just entered, which re-fired and
# bounced them straight back out.
#
# Note this zone is built WITHOUT the factory helper, because the helper's whole job is to arm it.
func test_a_zone_the_car_starts_inside_does_not_fire_until_it_has_been_left() -> void:
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_open"), Vector3.ZERO, false)
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	var fired: Array[String] = []
	zone.activated.connect(func(id: String) -> void: fired.append(id))

	# Parked at the centre from the very first tick, for far longer than any dwell.
	_drive(zone, zone.centre, 0.0, _generous_seconds(zone))
	assert_eq(fired.size(), 0,
		"a zone the car was already sitting in must not activate on its own")

	# Drive out — that arms it — then come back and park.
	_drive(zone, _far_from(zone), _moving_kmh(zone), 0.5)
	_drive(zone, zone.centre, 0.0, _generous_seconds(zone))
	assert_eq(fired.size(), 1,
		"...and it DOES fire once the car has left and returned (the latch is not a permanent block)")


func test_always_revealed_opens_a_zone_the_roster_does_not_describe() -> void:
	# The GARAGE is a destination, not a roster rally: no reveal predicate describes it, so
	# without the exemption the player could never reach their own garage. Pinned far outside
	# every lit circle so the flag is the ONLY thing that can be opening it.
	var garage := {"id": "fx_garage", "name": "Garage", "map_pos": Vector2(0.99, 0.01)}

	var gated := _zone(garage)
	assert_false(gated.revealed(), "without the flag, a non-roster dict is dark")
	watch_signals(gated)
	_drive(gated, Vector3.ZERO, 0.0, _generous_seconds(gated))
	assert_signal_emit_count(gated, "activated", 0, "the exemption is not the default — a dark dict stays dark")

	var open := _zone(garage, true)
	assert_true(open.revealed(), "always_revealed opens the zone")
	watch_signals(open)
	_drive(open, Vector3.ZERO, 0.0, _generous_seconds(open))
	assert_signal_emit_count(open, "activated", 1, "an always_revealed destination activates")


# --- Marker kinds --------------------------------------------------------------------------


func test_marker_kind_trichotomy_on_synthetic_rallies() -> void:
	# The marker's whole job is to say WHAT KIND of rally is parked here with no text, so the
	# three promises must resolve to three different signs. Asserted on synthetic rallies and
	# on the KIND, never on a texture identity or an authored roster entry.
	var plain := {"id": "fx_plain_rally", "special": false}
	var car := {"id": "fx_car_rally", "special": false, "prize_car": "fx_hatch"}
	# UpgradeFixtures' fx_gated part is gated on FX_GATE_RALLY and sits in a real slot, so a
	# rally with that id is the part-unlock case without inventing a second catalogue.
	var part := {"id": UpgradeFixtures.FX_GATE_RALLY, "special": false}

	assert_eq(OverworldMarker.kind_of(plain), OverworldMarker.Kind.FLAG,
		"an ordinary rally wears the flag")
	assert_eq(OverworldMarker.kind_of(car), OverworldMarker.Kind.CAR,
		"a prize_car rally wears the car")
	assert_eq(OverworldMarker.kind_of(part), OverworldMarker.Kind.PART,
		"a part-unlock rally wears its part's icon")
	assert_ne(OverworldMarker.part_slot_of(part), "",
		"the part case resolves a real slot (else PART above proves nothing)")


func test_part_unlock_with_no_slot_falls_back_to_the_flag() -> void:
	# Load-bearing: UpgradeIcons' fallback is the TUNE wrench, so leaning on it would make
	# every rally with no resolvable part read as a tuning event — and that is most of the
	# roster. "Unlocks something with no slot" must read as an ordinary flag instead.
	var rally_id := "fx_noslot_rally"
	var roster := UpgradeFixtures.upgrades()
	roster.append({
		"id": "fx_slotless_unlock", "name": "Fixture Slotless Unlock", "slot": "",
		"unlocked_by_rally": rally_id, "consumable": false, "effect": {},
	})
	UpgradeLibrary.override_for_test(roster)   # restored by UpgradeFixtures.restore() in teardown

	var rally := {"id": rally_id, "special": false}
	assert_false(UpgradeLibrary.unlocked_by(rally_id).is_empty(),
		"the rally does gate an upgrade (else the fallback below is trivially reached)")
	assert_eq(OverworldMarker.part_slot_of(rally), "", "no slot resolves")
	assert_null(OverworldMarker.part_texture(rally), "and no icon is offered")
	assert_eq(OverworldMarker.kind_of(rally), OverworldMarker.Kind.FLAG,
		"a slotless unlock falls back to the FLAG, not the generic tune icon")


# --- The manager ---------------------------------------------------------------------------


func _manager(visuals := false) -> OverworldZones:
	var mgr := OverworldZones.new()
	add_child_autofree(mgr)
	mgr.setup({
		"to_world": func(mp: Vector2) -> Vector3:
			return Vector3(mp.x * MAP_TO_WORLD, 0.0, mp.y * MAP_TO_WORLD),
		"rallies": RallyFixtures.rallies(),
		"profile": Save.profile,
		"visuals": visuals,
	})
	return mgr


func test_spin_yaw_advances_and_stays_finite() -> void:
	# The shared yaw is the GHOST CARS' turntable now — the icons face the player instead of
	# turning (see the facing tests below). It is still driven from ONE place (38 zones must not
	# mean 38 `_process` callbacks), so it is the thing that has to move — and it wraps rather
	# than growing without bound.
	var mgr := _manager()
	var start := mgr.spin_yaw()
	assert_true(is_finite(start), "the shared yaw starts finite")
	var away := Vector3(1.0e6, 0.0, 1.0e6)   # far from every zone: spin only, no dwell
	for _i in 120:
		mgr.update_with(1.0 / 60.0, away, 0.0)
	assert_true(is_finite(mgr.spin_yaw()), "the shared yaw stays finite")
	assert_between(mgr.spin_yaw(), 0.0, TAU, "the yaw is wrapped into one turn")
	if Config.data.overworld_marker_spin_deg_s > 0.0:
		assert_ne(mgr.spin_yaw(), start, "updates advance the shared yaw")


func test_markers_are_not_built_beyond_the_draw_distance_and_are_pooled() -> void:
	# The budget is the interesting part of the manager: 38 zones must not mean 38 markers.
	# Out of range means NO marker node, and driving back into range must re-dress a pooled
	# marker rather than allocate a second one.
	_complete("fx_open")   # lights every fixture pin, so reveal is not what gates markers here
	var mgr := _manager(true)
	mgr.refresh(Save.profile)
	# Longer than the manager's marker-refresh interval, so each call recomputes the set.
	var dt := OverworldZones.REFRESH_INTERVAL_S * 1.5
	var away := Vector3(1.0e6, 0.0, 1.0e6)
	var here: Vector3 = mgr.zone_for("fx_open").centre

	mgr.update_with(dt, away, 0.0)
	assert_eq(mgr.live_marker_count(), 0, "no marker is instantiated beyond the draw distance")

	mgr.update_with(dt, here, 0.0)
	var first := mgr.live_marker_count()
	assert_gt(first, 0, "standing on a zone grants it a marker (else the pooling case is vacuous)")
	var first_ids := _marker_ids(mgr)
	assert_not_null(mgr.marker_for("fx_open"), "the zone under the car has a marker")

	mgr.update_with(dt, away, 0.0)
	assert_eq(mgr.live_marker_count(), 0, "driving away releases every marker")

	mgr.update_with(dt, here, 0.0)
	assert_eq(mgr.live_marker_count(), first, "coming back grants the same number of markers")
	# Identity, not count: the SAME node objects come back out of the pool. Compared as a set
	# because the pool is LIFO, so which zone gets which marker is not stable (nor should it be).
	assert_eq(_marker_ids(mgr), first_ids, "returning reuses the pooled markers, not new ones")


func test_adopting_a_ghost_keeps_the_body_seated_where_the_manager_put_it() -> void:
	# The regression: car.tscn's body ORIGIN is not the wheel contact plane — the manager lifts a
	# ghost by Car.settled_ride_height() so its wheels rest on the zone's flat pad, and the marker
	# origin IS that ground point. adopt_ghost used to reset the body to Transform3D.IDENTITY,
	# which threw the lift (and the facing) away and buried the car up to its arches. A stub stands
	# in for the CarProp: adopt_ghost only re-parents, so it must not care what the body is.
	var marker := OverworldMarker.new()
	add_child_autofree(marker)
	var body := Node3D.new()
	var lift := 0.42                      # any non-zero seat height; not a tunable
	var facing := 1.1
	body.position = Vector3(0.0, lift, 0.0)
	body.rotation = Vector3(0.0, facing, 0.0)
	marker.adopt_ghost(body)

	assert_true(marker.has_ghost(), "the marker holds the body it was handed")
	assert_almost_eq(body.position.y, lift, 0.0001,
		"adoption preserves the seat height — resetting it sinks the ghost into the ground")
	assert_almost_eq(body.rotation.y, facing, 0.0001, "and the facing it was given")
	# And releasing hands the same node back, un-parented but NOT freed (it is the cache's).
	var released := marker.release_ghost()
	assert_eq(released, body, "release hands the same body back")
	assert_true(is_instance_valid(body), "and does not free it — the manager's cache owns it")
	assert_false(marker.has_ghost(), "the marker no longer holds a ghost")
	body.free()


func _marker_ids(mgr: OverworldZones) -> Array:
	var ids: Array = []
	for zone in mgr.zones():
		var marker := mgr.marker_for(zone.rally_id)
		if marker != null:
			ids.append(marker.get_instance_id())
	ids.sort()
	return ids


# --- What a marker STANDS FOR ---------------------------------------------------------------


# A CAPABILITY-AWARDING RALLY MUST NOT READ AS A GENERIC TROPHY. Engine swapping is gated by an id
# on the library (`RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY`) rather than by a catalogue part, so the
# marker's trichotomy only knew CAR and PART and the one rally that unlocks the garage's most
# interesting mechanic fell through to the same trophy every prize-less special wore.
#
# Built from the CONSTANT, not from the shipped roster: the seam is the named owner, so this depends
# on no catalogue content and cannot break when a rally is retuned or renamed.
func test_a_capability_rally_wears_the_capability_icon_not_a_trophy() -> void:
	var rally := {
		"id": RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY, "name": "Capability", "region": "home",
		"difficulty": 1, "special": true, "map_pos": Vector2(0.5, 0.5),
		"restriction": {}, "events": [],
	}
	assert_eq(OverworldMarker.kind_of(rally), OverworldMarker.Kind.CAPABILITY,
		"the capability rally reads as CAPABILITY")
	assert_ne(OverworldMarker.capability_slot_of(rally), "",
		"...and resolves an icon slot to draw")
	assert_not_null(OverworldMarker.capability_texture(rally), "...with a real texture behind it")
	# A rally awarding nothing but flagged special still gets the trophy — the fallback is intact,
	# it just no longer swallows the capability case.
	var bare := rally.duplicate()
	bare["id"] = "not_a_prize_rally"
	assert_eq(OverworldMarker.kind_of(bare), OverworldMarker.Kind.TROPHY,
		"a special with no resolvable prize still falls back to the trophy")
	# ...and an ordinary rally with nothing to give is still a flag.
	var plain := bare.duplicate()
	plain["special"] = false
	assert_eq(OverworldMarker.kind_of(plain), OverworldMarker.Kind.FLAG,
		"an ordinary prize-less rally is a flag")


# --- Icons face the player, and the star layer ----------------------------------------------


# ICONS FACE THE PLAYER, and the maths is yaw-only so they stay upright. Asserted on the pure
# static helper: whatever direction the camera is in, the yaw turns the marker's +Z toward it, and
# a camera high above or below the marker gives the SAME answer as one at the same height —
# which is what stops an icon tipping over when the player looks down from a rise.
func test_thefacing_yaw_points_at_the_camera_and_ignores_height() -> void:
	var here := Vector3(10.0, 3.0, -20.0)
	for offset in [Vector3(50.0, 0.0, 0.0), Vector3(-13.0, 0.0, 41.0), Vector3(0.0, 0.0, -8.0)]:
		var level := OverworldZones.facing_yaw(here, here + offset)
		# Turning a +Z-forward node by this yaw must land on the direction to the camera.
		var forward := Vector3(sin(level), 0.0, cos(level))
		var want := Vector3(offset.x, 0.0, offset.z).normalized()
		assert_almost_eq(forward.dot(want), 1.0, 0.001, "the icon turns to face %s" % offset)
		# ...and height is ignored, so the icon never tips.
		var high := OverworldZones.facing_yaw(here, here + offset + Vector3(0.0, 400.0, 0.0))
		assert_almost_eq(high, level, 0.0001, "a camera overhead gives the same yaw")
	# Degenerate: a camera exactly on the marker cannot define a direction, and must not produce
	# a NAN that would poison the transform.
	assert_true(is_finite(OverworldZones.facing_yaw(here, here)), "a coincident camera is finite")


# The star layer shows what it was configured with, capped at the rally's own maximum — asserted
# against `RallyLibrary.MAX_STARS_PER_RALLY` rather than a number, since that is a balance value.
func test_the_star_layer_shows_the_configured_count_and_never_more() -> void:
	var marker := OverworldMarker.new()
	add_child_autofree(marker)
	var maxs := RallyLibrary.MAX_STARS_PER_RALLY
	marker.configure(_fx("fx_open"), false, 1, true)
	assert_eq(marker.stars_shown(), 1, "one earned star shows one filled star")
	assert_eq(marker.star_slots(), maxs, "the row always has as many slots as a rally has stars")
	assert_true(marker.stars_visible(), "a revealed rally shows its stars")

	marker.configure(_fx("fx_open"), false, maxs + 7, true)
	assert_eq(marker.stars_shown(), maxs, "a nonsense count is clamped to the maximum")
	marker.configure(_fx("fx_open"), false, -4, true)
	assert_eq(marker.stars_shown(), 0, "...and a negative one to zero")


# ZERO STARS IS THREE EMPTIES, not an absent row: the row is the "N of max available here" signal,
# and a never-attempted rally is the degenerate case of it rather than a special case.
func test_an_unattempted_rally_still_shows_a_full_row_of_empty_slots() -> void:
	var marker := OverworldMarker.new()
	add_child_autofree(marker)
	marker.configure(_fx("fx_open"), false, 0, true)
	assert_true(marker.stars_visible(), "the row is on screen with nothing earned")
	assert_eq(marker.stars_shown(), 0, "...showing no filled stars")
	assert_eq(marker.star_slots(), RallyLibrary.MAX_STARS_PER_RALLY, "...but every slot")


# REVEAL GATING. Stars on a rally the player has not found would leak what the fog exists to
# withhold — the same call the light tube and the map's roads make. `locked` is the manager's
# `not zone.revealed()`.
func test_an_unrevealed_rally_shows_no_stars() -> void:
	var marker := OverworldMarker.new()
	add_child_autofree(marker)
	marker.configure(_fx("fx_gated"), true, RallyLibrary.MAX_STARS_PER_RALLY, true)
	assert_false(marker.stars_visible(), "a locked rally draws no star layer")
	# ...and it comes back when the rally lights, on the same pooled marker.
	marker.configure(_fx("fx_gated"), false, 0, true)
	assert_true(marker.stars_visible(), "revealing it brings the row back")


# POOLING. A marker is re-dressed, never re-allocated, so re-using one from a fully-starred rally
# on an unattempted one must show empties — not the previous zone's score.
func test_a_pooled_marker_re_dressed_for_another_rally_updates_its_stars() -> void:
	var marker := OverworldMarker.new()
	add_child_autofree(marker)
	var maxs := RallyLibrary.MAX_STARS_PER_RALLY
	marker.configure(_fx("fx_open"), false, maxs, true)
	assert_eq(marker.stars_shown(), maxs, "the first rally is fully starred (else vacuous)")
	marker.configure(_fx("fx_rwd_band"), false, 0, true)
	assert_eq(marker.stars_shown(), 0, "the re-dressed marker shows the NEW rally's stars")
	assert_eq(marker.star_slots(), maxs, "and still a full row of slots")


# The row is composed from StarRow's OWN star geometry (one texture per earned/total pair, cached
# for the session), so an icon star and a medal-row star cannot drift apart — and a marker being
# re-dressed does not rasterise anything again.
func test_the_star_row_texture_is_shared_and_sized_by_the_slot_count() -> void:
	var maxs := RallyLibrary.MAX_STARS_PER_RALLY
	var a := OverworldMarker.star_row_texture(0, maxs)
	var b := OverworldMarker.star_row_texture(0, maxs)
	assert_not_null(a, "a row texture is produced")
	assert_same(a, b, "the same row is handed out, not rasterised twice")
	assert_gt(a.get_width(), a.get_height(), "a multi-slot row is wider than it is tall")
	# One slot per star, so the row's width scales with the slot count rather than the earned one.
	if maxs > 1:
		var one := OverworldMarker.star_row_texture(0, 1)
		assert_gt(a.get_width(), one.get_width(), "more slots is a wider row")
	assert_eq(a.get_height(), OverworldMarker.star_row_texture(maxs, maxs).get_height(),
		"earning stars does not change the row's size")


# --- Cancelling (the rally card's Back button) ----------------------------------------------


# BACKING OUT OF THE CARD MUST NOT LOOP, AND MUST NOT KILL THE ZONE.
#
# The dwell latch alone cannot express "cancelled": `_fired` stops re-emitting only while the car
# stays put, and clearing the dwell instead would let it refill and re-fire on the spot with the
# player touching nothing — the open-panel loop. So `cancel_dwell` DISARMS, reusing the
# arm-on-exit rule: no re-fire until the car has been outside the circle again.
func test_cancelling_a_dwell_disarms_the_zone_until_the_car_leaves() -> void:
	var zone := _zone(_fx("fx_open"))
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	watch_signals(zone)
	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 1, "the zone fired once (else vacuous)")

	zone.cancel_dwell()
	assert_eq(zone.progress, 0.0, "cancelling drains the dwell, so the tube visibly collapses")
	assert_false(zone.armed(), "...and disarms the zone")

	# STILL PARKED, STILL STATIONARY, for far longer than any dwell setting: it must not re-fire.
	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone) * 2.0)
	assert_signal_emit_count(zone, "activated", 1, "a cancelled zone does not grab the player again")
	assert_eq(zone.progress, 0.0, "and does not even start counting")

	# ...but driving OUT re-arms it, so cancelling is never permanent.
	zone.tick(1.0 / 60.0, _far_from(zone), 0.0)
	assert_true(zone.armed(), "leaving the circle re-arms the zone")
	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 2, "driving out and back in opens it again")


# The manager's by-id hook, which is what the host calls when the card is dismissed.
func test_the_manager_cancels_one_zone_by_id() -> void:
	var zones := _manager()
	var id := String(_fx("fx_open")["id"])
	var zone := zones.zone_for(id)
	assert_not_null(zone, "the manager built a zone for the fixture rally")
	zone.tick(1.0 / 60.0, _far_from(zone), 0.0)
	assert_true(zone.armed(), "it starts armed once the car has been seen outside (else vacuous)")
	assert_true(zones.cancel_dwell(id), "cancelling a known zone reports success")
	assert_false(zone.armed(), "...and disarms that zone")
	assert_false(zones.cancel_dwell("no_such_rally"), "an unknown id is a no-op, not a crash")


# --- The dwell tube ------------------------------------------------------------------------
#
# The zone's indicator is a transparent light tube standing on the zone (it replaced a flat
# ground ring), and the dwell is shown ON it — see features/overworld.md, "What a zone looks
# like". These assert the SEAMS only: the headless guard, that progress drives the exposed
# visual state, and that the tube is drawn at the same radius the trigger test uses. No colour,
# no alpha, no height and no radius VALUE is pinned — those are all GameConfig tunables.


func test_no_tube_is_built_with_visuals_off() -> void:
	# The headless guard. `visuals: false` is what lets the whole activation path run with no
	# renderer, so it must build no mesh, no material and no node at all.
	var zone := _zone(_fx("fx_open"))
	assert_null(zone.tube_node(), "visuals: false builds no tube node")
	assert_eq(zone.tube_radius(), -1.0, "and there is no drawn radius to report")
	# ...and the state machine still runs, which is the point of the guard.
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	watch_signals(zone)
	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_signal_emit_count(zone, "activated", 1, "the dwell still completes with no visuals")


func test_progress_drives_the_tube_fill_and_a_broken_dwell_collapses_it() -> void:
	# `fill_fraction()` is the normalised height of the lit portion — the one number every
	# colour, alpha and scale decision in `_push_progress` is derived from. It must track the
	# dwell, and driving off must visibly collapse it rather than leave it stranded.
	var zone := _zone(_fx("fx_open"))
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	assert_eq(zone.fill_fraction(), 0.0, "an untouched zone shows no fill")

	var dwell := zone.dwell_seconds()
	_drive(zone, Vector3.ZERO, 0.0, dwell * 0.4)
	var partial := zone.fill_fraction()
	assert_gt(partial, 0.0, "parking raises the fill (else the rest of this test is vacuous)")
	assert_lt(partial, 1.0, "and a partial dwell is a partial fill, not a full one")
	assert_eq(partial, zone.progress, "the fill is the dwell progress, not a second accumulator")

	# Breaking the dwell must read instantly: the drain is faster than the fill, so the same
	# elapsed time that built this fill must more than wipe it.
	_drive(zone, Vector3.ZERO, _moving_kmh(zone), dwell * 0.4)
	assert_eq(zone.fill_fraction(), 0.0, "driving off collapses the fill all the way back")

	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_eq(zone.fill_fraction(), 1.0, "a completed dwell leaves the tube fully lit")
	assert_between(zone.fill_fraction(), 0.0, 1.0, "the fill is normalised")


func test_an_unrevealed_zone_shows_no_tube_until_it_lights() -> void:
	# The tube is the "you can go here" landmark, visible from far further away than anything
	# else about a zone — so a DARK zone must not draw one (the roads to it are barriered off,
	# OverworldBlocks, which would otherwise be a straight contradiction). And it must appear the
	# moment the rally lights, with no scene reload: `refresh_revealed` pushes the gate itself,
	# because a far zone is never ticked.
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_gated"), Vector3.ZERO, true)   # visuals ON: this test is about the tube
	assert_false(zone.revealed(), "fx_gated starts dark (else this test is vacuous)")
	assert_not_null(zone.tube_node(), "the tube node is still built...")
	assert_false(zone.tube_node().visible, "...but a dark zone does not show it")

	_complete("fx_open")            # fx_open's reveal circle reaches fx_gated
	zone.refresh_revealed(Save.profile)
	assert_true(zone.revealed(), "completing fx_open lights fx_gated")
	assert_true(zone.tube_node().visible, "a revealed zone shows its tube again")


func test_the_garage_exemption_shows_its_tube() -> void:
	# The garage carries no pin, so the roster predicate would call it dark forever — it must
	# still be visible, or the player could never find their own garage.
	var zone := OverworldZone.new()
	zone.always_revealed = true
	add_child_autofree(zone)
	zone.setup({}, Vector3.ZERO, true)
	assert_true(zone.tube_node().visible, "an always-revealed destination shows its tube")


func test_the_tube_is_drawn_at_the_live_trigger_radius() -> void:
	# What you see IS what you must park in. The tube's radius and the dwell's containment test
	# must be the SAME live value, so retuning the zone size can never leave the player parking
	# in a circle that is not the one drawn. Asserted as agreement — never as a radius value.
	var original: float = Config.data.overworld_zone_radius_m
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_open"), Vector3.ZERO, true)   # visuals ON: this is the drawn radius
	assert_not_null(zone.tube_node(), "visuals: true does build the tube")
	assert_almost_eq(zone.tube_radius(), zone.radius(), 0.001,
		"the tube is drawn at the trigger radius")

	# Retune it live — the radius is read per call, not cached at build time.
	Config.data.overworld_zone_radius_m = original * 0.5
	zone.tick(1.0 / 60.0, _far_from(zone), 0.0)
	# Everything is READ while the retune is in place, then the tunable is restored before any
	# assertion can fail — a failing assert must not leak a mutated Config into the next test.
	var retuned_drawn := zone.tube_radius()
	var retuned_trigger := zone.radius()
	# The containment test moved with it too, so all three are one number.
	var inside := zone.contains(zone.centre + Vector3(retuned_trigger * 0.99, 0.0, 0.0))
	var outside := zone.contains(zone.centre + Vector3(retuned_trigger * 1.01, 0.0, 0.0))
	Config.data.overworld_zone_radius_m = original

	assert_almost_eq(retuned_drawn, retuned_trigger, 0.001,
		"...and they still agree after a live retune")
	assert_true(inside, "just inside the drawn radius is inside the trigger")
	assert_false(outside, "just outside it is outside")


# --- A rally already completed shows a dimmer idle tube ---------------------------------
#
# `overworld_zone_tube_completed_alpha_scale` is a GameConfig tunable, so — same discipline as
# the rest of this file — nothing here pins an alpha VALUE. What must hold for ANY reasonable
# scale is the RELATIONSHIP: a rally completed on a PREVIOUS visit reads dimmer at rest than an
# otherwise-identical zone that has not been completed, by exactly the configured scale; and a
# fresh dwell on that same completed zone still ramps all the way up to full brightness.

func test_a_completed_rally_shows_a_dimmer_idle_tube_than_an_incomplete_one() -> void:
	var incomplete := OverworldZone.new()
	add_child_autofree(incomplete)
	incomplete.setup(_fx("fx_open"), Vector3.ZERO, true)
	_complete("fx_open")
	incomplete.refresh_revealed(Save.profile)   # reveal only — NOT refresh_completed
	var base_alpha := incomplete.tube_body_alpha()
	assert_gt(base_alpha, 0.0, "the incomplete zone's idle tube is visible at all")

	var completed := OverworldZone.new()
	add_child_autofree(completed)
	completed.setup(_fx("fx_open"), Vector3.ZERO, true)
	completed.refresh_revealed(Save.profile)
	completed.refresh_completed(Save.profile)
	assert_true(completed.completed(), "fx_open really is completed in the profile this reads")
	var dimmed_alpha := completed.tube_body_alpha()

	assert_lt(dimmed_alpha, base_alpha, "a completed rally's idle tube is dimmer, not brighter")
	assert_almost_eq(dimmed_alpha, base_alpha * Config.data.overworld_zone_tube_completed_alpha_scale,
		0.001, "dimmed by exactly the configured scale, not some other amount")


func test_an_incomplete_rally_is_not_dimmed() -> void:
	# Non-vacuity for the test above: the SAME zone, SAME profile call, on a rally that has not
	# been completed, must come back exactly as bright as the undimmed baseline reads elsewhere —
	# i.e. `refresh_completed` on a false profile must be a no-op on the alpha.
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_open"), Vector3.ZERO, true)
	zone.refresh_revealed(Save.profile)
	var before := zone.tube_body_alpha()
	zone.refresh_completed(Save.profile)
	assert_false(zone.completed(), "fx_open is not completed in a fresh profile")
	assert_almost_eq(zone.tube_body_alpha(), before, 0.001,
		"refresh_completed changes nothing when the rally has not been completed")


func test_re_entering_a_completed_zone_still_ramps_up_to_full_brightness() -> void:
	# The idle dimming must not mute the actual dwell feedback — a player re-running a completed
	# rally still needs to see the fill/gold-snap punctuation exactly as before. Built with
	# visuals ON directly (not the `_zone()` helper, which builds visuals off) since this test
	# reads the tube material.
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_open"), Vector3.ZERO, true)
	# ARM it — see `_zone()`'s own comment on why a dwell test must start from outside.
	zone.tick(1.0 / 60.0, _far_from(zone), 0.0)
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	zone.refresh_completed(Save.profile)
	assert_true(zone.completed(), "fx_open really is completed (else this test is vacuous)")

	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_eq(zone.fill_fraction(), 1.0, "the dwell still completes on a re-entered zone")
	assert_almost_eq(zone.tube_body_alpha(),
		clampf(Config.data.overworld_zone_tube_ready_alpha, 0.0, 1.0), 0.001,
		"a completed dwell still snaps the body to full ready alpha, dimming or not")


# --- Tube COLOUR: white incomplete, green completed, muted locked, gold on the snap ---------
#
# Unlike the alpha (a GameConfig tunable), the palette colours ARE fixed identifiers — the
# whole point of this feature is that GREEN specifically means "done", so asserting the exact
# `UITheme` constant is the contract, not a pinned incidental value. Same precedent as
# test_ui_theme.gd / test_hud.gd, which already assert exact UITheme colours.

func test_a_revealed_incomplete_zone_shows_white() -> void:
	# fx_open lights fx_gated's pin once completed, but that only reveals fx_gated — it does not
	# complete IT, which is exactly "revealed, not yet completed" (see `_complete`'s own comment:
	# a rally reveals ITSELF only by being completed, so fx_open cannot show this state on its
	# own roster position — a rally lit by a NEIGHBOUR is the only way to get it).
	_complete("fx_open")
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_gated"), Vector3.ZERO, true)
	zone.refresh_revealed(Save.profile)
	zone.refresh_completed(Save.profile)
	assert_true(zone.revealed(), "fx_open's completion lights fx_gated (else this test is vacuous)")
	assert_false(zone.completed(), "fx_gated itself has not been completed")
	assert_eq(zone.tube_body_color(), Color(UITheme.INK.r, UITheme.INK.g, UITheme.INK.b, 1.0),
		"a revealed, not-yet-completed zone shows the white/off-white body tint")


func test_a_completed_zone_shows_green() -> void:
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_open"), Vector3.ZERO, true)
	_complete("fx_open")
	zone.refresh_revealed(Save.profile)
	zone.refresh_completed(Save.profile)
	assert_true(zone.completed(), "fx_open really is completed (else this test is vacuous)")
	assert_eq(zone.tube_body_color(), Color(UITheme.GREEN.r, UITheme.GREEN.g, UITheme.GREEN.b, 1.0),
		"a completed zone shows the green body tint")


func test_an_unrevealed_zone_stays_muted_regardless_of_completion() -> void:
	# A dark zone must not leak "completed" through its tint just because some OTHER rally that
	# lights it later happens to have been finished before — locked always reads as locked.
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_gated"), Vector3.ZERO, true)
	assert_false(zone.revealed(), "fx_gated starts dark (else this test is vacuous)")
	assert_eq(zone.tube_body_color(), Color(UITheme.MUTED.r, UITheme.MUTED.g, UITheme.MUTED.b, 1.0),
		"an unrevealed zone shows the muted/locked body tint")


func test_the_completion_snap_still_goes_gold_over_the_white_resting_colour() -> void:
	# The gold "it just fired" punctuation must win over the white resting tint — a completely
	# separate concept (this visit's live dwell) from the persisted white/green distinction. Uses
	# fx_gated, lit by completing fx_open first: the dwell state machine only accumulates
	# progress on a REVEALED zone (see `refresh_revealed`'s activation re-check), and fx_gated is
	# revealed-but-not-completed the same way the white-tint test above needs it to be.
	_complete("fx_open")
	var zone := OverworldZone.new()
	add_child_autofree(zone)
	zone.setup(_fx("fx_gated"), Vector3.ZERO, true)
	zone.tick(1.0 / 60.0, _far_from(zone), 0.0)   # arm it
	zone.refresh_revealed(Save.profile)
	assert_true(zone.revealed(), "fx_open's completion lights fx_gated (else this test is vacuous)")
	assert_false(zone.completed(), "fx_gated itself not completed yet (white resting tint)")

	_drive(zone, Vector3.ZERO, 0.0, _generous_seconds(zone))
	assert_eq(zone.fill_fraction(), 1.0, "the dwell completed (else this test is vacuous)")
	assert_eq(zone.tube_body_color(), Color(UITheme.GOLD.r, UITheme.GOLD.g, UITheme.GOLD.b, 1.0),
		"the completion snap goes gold even from the white (not-yet-completed) resting tint")

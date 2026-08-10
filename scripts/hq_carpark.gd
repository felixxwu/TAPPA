class_name HqCarpark
extends RefCounted
# The car park: the eligible-lineup build, the parked-car prop cache, focus
# cycling, the swap/damage readouts and the carpark modals. Split out of hq.gd
# (see todo/hq-split.md) — the FUNCTIONS moved here, every `_carpark_*` / `_lineup`
# / `_car_cache` STATE var stayed on HqController, which this reaches back into
# through `_hq`. Same shape as HqOverlays / HqChallenge / HqTable.

var _hq: HqController


func _init(hq: HqController) -> void:
	_hq = hq


# Release just the CURRENTLY-PARKED page's props + markers, cancelling any in-flight
# settle. Leaves `_lineup` and the detune/drivetrain maps intact — a page flip re-renders
# on top of the same list.
func _release_page_props() -> void:
	_hq._settle_generation += 1  # cancel any pending settle-then-freeze for this lineup
	# Hide the parked cars rather than freeing them, so a re-entry into any lineup can
	# reuse the cached instances (see _car_cache / _build_lineup). Their frozen bodies stay
	# ray-pickable (CarProp.stop_physics), so STOW them off-screen too — otherwise a hidden
	# car left sitting in its bay would intercept a tap-to-focus ray meant for the NEW page's
	# car spawned at the same bay (_car_index_at). Reuse re-seats them via _seat_car_at_marker.
	var stow := _prewarm_stow_marker().global_position
	for car in _hq._cars:
		if is_instance_valid(car):
			car.visible = false
			car.global_position = stow
	for marker in _hq._markers:
		if is_instance_valid(marker):
			marker.queue_free()
	_hq._cars = []
	_hq._markers = []


# Full car-park teardown, used when LEAVING the lot (back / launch): release the page
# props and forget the list + cursor + per-rally detune maps.
func _clear_lineup() -> void:
	_release_page_props()
	_hq._lineup.setup([], max(1, Config.data.carpark_page_size))
	_hq._eligible = []
	_hq._detune_needed = {}
	_hq._drivetrain_needed = {}


# Free every cached (and currently active) parked car outright — used when the cache
# would otherwise leak, e.g. eviction of preview cars no longer offered. Frees the node and drops its entry.
func _free_cached_car(instance_id: int) -> void:
	var entry: Dictionary = _hq._car_cache.get(instance_id, {})
	var node = entry.get("node")
	if is_instance_valid(node):
		node.queue_free()
	_hq._car_cache.erase(instance_id)


# Drop cache entries for cars the player no longer owns, freeing their nodes so the cache
# doesn't outlive the collection. PREVIEW entries (negative instance_id — Free Roam's
# whole-catalogue previews, pre-warmed once and kept in memory for the session) are NEVER
# evicted here: they aren't "owned", but re-warming them is exactly the lag spike we're
# avoiding, so they persist for the HQ's lifetime (freed only with the HQ node). Entries
# in `keep` (the list currently being built) are preserved too.
func _evict_unowned_cached_cars(keep: Array = []) -> void:
	var owned_ids := {}
	for car in Save.profile.get("cars", []):
		owned_ids[int(car.get("instance_id", -1))] = true
	for car in keep:
		owned_ids[int(car.get("instance_id", -1))] = true
	for id in _hq._car_cache.keys():
		if int(id) < 0:
			continue  # a preview / pre-warmed car — keep it warm in memory
		if not owned_ids.has(id):
			_free_cached_car(id)


# Park the owned cars ELIGIBLE for the selected rally (the car-select screen), plus
# any OVER-POWERED car a detune could fit under the rally's pw_max cap — those park
# looking eligible, and pressing Start pops the over-limit prompt routing to the
# upgrades menu (_show_over_limit_prompt / _on_start_pressed).
func _build_eligible_lineup() -> void:
	var rally := RallyLibrary.by_id(_hq._selected_rally_id)
	var eligible: Array = []
	var needs_detune := {}
	var needs_drivetrain := {}
	for car in Save.profile.get("cars", []):
		# NO challenge-lock exclusion (the rationale is spelled out in _swap_targets): a
		# car fielded by an active challenge run can still be entered into a career rally.
		var plan := _hq._entry_plan(rally, car)
		if not bool(plan["eligible"]):
			continue
		eligible.append(car)
		var id := int(car.get("instance_id", -1))
		if int(plan["drivetrain"]) >= 0:
			needs_drivetrain[id] = int(plan["drivetrain"])
		if float(plan["detune"]) > 0.0:
			needs_detune[id] = float(plan["detune"])
	_build_lineup(eligible)  # clears _detune_needed / _drivetrain_needed, then repopulated below
	_hq._detune_needed = needs_detune
	_hq._drivetrain_needed = needs_drivetrain


# The engine-detune fraction that would let `owned` enter `rally`, for the one case
# the car-park prompt covers: the car is TOO POWERFUL (its current p/w sits over the
# rally's pw_max cap) but tuning the engine down would duck it under. -1.0 when the
# car is under the cap (already eligible, or ineligible for a reason detuning can't
# fix — those cars keep today's behaviour) or when no detune qualifies it.
func _qualifying_detune_for(rally: Dictionary, owned: Dictionary, entry: Dictionary, meta: Dictionary, drive_override := -1) -> float:
	var r: Dictionary = rally.get("restriction", {})
	if not r.has("pw_max"):
		return -1.0
	# Compare the ROUNDED hp/tonne (the figure the player actually sees) so this agrees with
	# RallyLibrary.ineligibility_reason — a car already at/under the displayed cap shouldn't
	# be treated as needing a detune.
	if CarLibrary.power_to_weight_hp_tonne(meta) <= roundi(float(r["pw_max"])):
		return -1.0
	var frac := RallyLibrary.qualifying_detune(rally, _full_power_meta(owned, entry, drive_override))
	return frac if frac > 0.0 and frac < 1.0 else -1.0


# The drive mode this car would switch to for `rally` (the rally's required mode), or -1
# when the rally has no drive_mode rule, the car lacks the swap kit, or it's already in
# that mode. Judges ONLY the drive_mode dimension — callers layer detune on top.
func _switch_target_for(rally: Dictionary, owned: Dictionary, meta: Dictionary) -> int:
	var r: Dictionary = rally.get("restriction", {})
	if not r.has("drive_mode"):
		return -1
	if not UpgradeLibrary.drivetrain_swap_unlocked(owned):
		return -1
	var required := int(r["drive_mode"])
	if int(meta.get("drive_mode", -1)) == required:
		return -1
	return required


# The drive mode `owned` must switch to in order to enter `rally`, or -1 when it's
# already compliant OR can't be switched (no swap kit / rally has no drive_mode rule /
# fails for another reason). Accepts a switch that qualifies ALONE, or a switch that
# qualifies when STACKED with an engine detune (see _qualifying_detune_for).
func _qualifying_drivetrain_for(rally: Dictionary, owned: Dictionary, entry: Dictionary, meta: Dictionary) -> int:
	var target := _switch_target_for(rally, owned, meta)
	if target < 0:
		return -1
	var switched := meta.duplicate()
	switched["drive_mode"] = target
	if RallyLibrary.is_eligible(rally, switched):
		return target
	return target if _qualifying_detune_for(rally, owned, entry, switched, target) > 0.0 else -1


# The car's effective stats at FULL engine tune (detune 1.0), whatever the stored
# slider value — the base the qualifying-detune math scales down from, so the prompt
# always proposes an absolute slider setting. `drive_override` stamps a switched
# drive_mode on top, so a switch+detune stack is evaluated on the POST-switch mode.
func _full_power_meta(owned: Dictionary, entry: Dictionary, drive_override := -1) -> Dictionary:
	return _meta_with_drive(_hq._detuned_to_full(owned), entry, drive_override)


# effective_meta for `full`, optionally stamping a switched drive_mode on top (so a
# switch+detune stack is evaluated on the POST-switch mode). Shared meta tail.
func _meta_with_drive(full: Dictionary, entry: Dictionary, drive_override: int) -> Dictionary:
	var out := UpgradeLibrary.effective_meta(full, entry)
	if drive_override >= 0:
		out["drive_mode"] = drive_override
	return out

# Park ALL owned cars for the title screen, so the player's whole collection is on
# show in the car park behind the title overlay (rebuilt on entering EXTERIOR). A
# fresh player (no car owned yet, starter not picked) has an empty lot, so show the
# three starter cars as previews instead — the same set the starter picker offers.
func _build_title_lineup() -> void:
	var owned: Array = Save.profile.get("cars", [])
	if owned.is_empty():
		_build_lineup(_hq._starter_previews())
	else:
		_build_lineup(owned.duplicate())


# Park the given owned cars in the painted bays, laid out as a centred row ALONG X at
# the car-park lot (GameConfig.hq_carpark_origin / menu_car_spacing), each car parked
# nose-out toward the courtyard / menu camera (+Z) so the front-3/4 framing shows its
# face with the garage behind it. Fewer cars than bays are centred within the grid so
# they stay over real bays. The cars are placed resting on their wheels and frozen at
# once (see _spawn_parked_car). Central entry for EVERY car-park screen — rally car-select,
# the garage picker, engine-swap, the starter picker, Free Roam and the title backdrop —
# each of which just hands its full car list here; CarList (_lineup) pages through it.
func _build_lineup(cars: Array, start_global := 0) -> void:
	_release_page_props()  # bumps _settle_generation, cancelling any in-flight spawn
	# A fresh list drops any per-rally over-limit maps from the previous build; the rally
	# car-select repopulates them right after (see _build_eligible_lineup).
	_hq._detune_needed = {}
	_hq._drivetrain_needed = {}
	# Hand the WHOLE list to the paginator and seat the cursor; it hands back one page at
	# a time. `carpark_page_size` bays per page — the list itself is unbounded.
	_hq._lineup.setup(cars, max(1, Config.data.carpark_page_size), start_global)
	_evict_unowned_cached_cars(cars)  # drop cached nodes for cars sold since the last build
	_render_lineup_page()


# Spawn the CURRENT page of the paginator into the painted bays. Called on entry and on
# every page flip (_cycle_focus); rebuilds only the visible page's props, so a 300-car
# collection never parks more than `carpark_page_size` heavy physics props at once.
func _render_lineup_page() -> void:
	_release_page_props()
	_hq._eligible = _hq._lineup.page_items()
	_hq._focus = _hq._lineup.focus
	var cfg: GameConfig = Config.data
	var n := _hq._eligible.size()
	var bays: int = max(1, cfg.carpark_page_size)
	var center := HQEnvironment.carpark_center()
	# Lay out the lot markers up front (cheap Marker3Ds): the camera framing and the
	# focus cursor key off _markers / _eligible, so they work immediately even while the
	# heavy car props are still streaming in below. Centre a short final page within the
	# lot so its cars stay over real bays.
	var start: int = max(0, floori((bays - n) / 2.0))
	for i in n:
		var marker := Marker3D.new()
		marker.position = Vector3(_hq._bay_center_x(start + i, bays), 0.0, center.z)
		# Nose toward +Z (the courtyard / camera), so the menu camera sits in front.
		marker.rotation.y = PI
		_hq.add_child(marker)
		_hq._markers.append(marker)
	# Spawn the heavy car props ONE PER FRAME instead of all at once. Each car is a full
	# physics scene (chassis + wheels + drivetrain + mesh duplication), so building the
	# whole lineup in a single frame hitches; spreading it out keeps each frame cheap and
	# lets a car that takes longer than one frame to instance spill into its own frame
	# without piling onto the others. Guarded by _settle_generation so a rebuild (or a
	# back-out) abandons a half-spawned lineup cleanly.
	_spawn_lineup_progressive(_hq._eligible, _hq._settle_generation)


# Stream the parked car props in across frames (see _build_lineup), then let them
# settle and freeze. Bails the moment a newer lineup supersedes this one.
func _spawn_lineup_progressive(cars: Array, generation: int) -> void:
	for i in cars.size():
		if generation != _hq._settle_generation:
			return  # a rebuild / back-out replaced this lineup mid-stream
		var car := _obtain_parked_car(cars[i], _hq._markers[i])
		# A failed spawn (e.g. a car model/texture that couldn't load) returns null —
		# skip it rather than let the null escape into _cars or the get_meta call below,
		# which would throw and silently abort this coroutine mid-loop, leaving
		# lineup_built never emitted and the boot's `await lineup_built` (see _ready)
		# hung forever behind the loading cover.
		if car == null:
			push_warning("HQ: skipping lineup slot %d — car spawn returned null (bad model/texture?)" % i)
			continue
		_hq._cars.append(car)
		# Both fresh and cached cars are placed frozen at rest (see _spawn_parked_car /
		# _obtain_parked_car), so there's nothing to settle. Only a freshly-instanced car
		# (heavy: physics scene + mesh duplication) is spread across a frame to avoid
		# hitching; a cached car reappears with no per-frame cost.
		if car.get_meta("lineup_fresh", false):
			await _hq.get_tree().process_frame
	if generation != _hq._settle_generation:
		return
	# Refine the analytic seating: droop each parked car's wheels onto the actual lot
	# floor via a downward raycast. Runs after a physics frame so newly-added bodies are
	# visible to the space query; guarded so a rebuild/back-out abandons it cleanly.
	await _hq.get_tree().physics_frame
	if generation != _hq._settle_generation:
		return
	for car in _hq._cars:
		if is_instance_valid(car):
			car.settle_wheels_to_ground(car.ground_raycast())
	# `lineup_built` is declared on HqController (a Node signal that hq.tscn's own boot
	# path and the tests await), so it must be emitted from there, not from this
	# RefCounted — which has no such signal.
	_hq.emit_signal("lineup_built")


# Return a parked car for `owned` at `marker`, reusing the cached instance when this
# car's data is unchanged (deep hash match) or (re)spawning a fresh one otherwise. The
# returned node carries a "lineup_fresh" meta so the caller knows whether it still
# needs to settle. Updates _car_cache in place.
func _obtain_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	var instance_id := int(owned.get("instance_id", -1))
	var owned_hash := owned.hash()
	var cached: Dictionary = _hq._car_cache.get(instance_id, {})
	var node = cached.get("node")
	if is_instance_valid(node) and int(cached.get("hash", 0)) == owned_hash:
		# Reuse: it's already built, sized, and frozen. Re-seat it analytically at the new
		# bay so it sits on its wheels (writing the raw marker transform would drop the
		# body to ground level — marker y = 0 — and sink it). Reset process_mode in case
		# this node was last borrowed by the tuning lift (_spawn_lift_car disables it).
		_seat_car_at_marker(node, marker)
		node.visible = true
		node.process_mode = Node.PROCESS_MODE_INHERIT
		node.set_meta("lineup_fresh", false)
		node.set_meta("owned_instance_id", instance_id)
		return node
	# Stale (data changed) or missing: drop any old node and spawn afresh.
	if is_instance_valid(node):
		node.queue_free()
	var fresh := _spawn_parked_car(owned, marker)
	fresh.set_meta("lineup_fresh", true)
	fresh.set_meta("owned_instance_id", instance_id)
	_hq._car_cache[instance_id] = {"hash": owned_hash, "node": fresh}
	return fresh


# An off-screen stow marker the pre-warmed Free Roam props seat at until Free Roam re-seats
# them at real bays. Sunk far below the lot so the hidden, frozen props never intersect the
# garage / lift cars or get ray-picked. Created lazily and kept for the HQ's lifetime.
func _prewarm_stow_marker() -> Marker3D:
	if not is_instance_valid(_hq._prewarm_marker):
		_hq._prewarm_marker = Marker3D.new()
		_hq._prewarm_marker.position = Vector3(0.0, -1000.0, 0.0)
		_hq.add_child(_hq._prewarm_marker)
	return _hq._prewarm_marker


# Pre-warm the Free Roam picker: spawn each catalogue preview as a HIDDEN, cached parked
# prop so entering Free Roam reuses them via _obtain_parked_car with no fresh instancing —
# that first-entry build (car.tscn embeds all car glbs) is the lag spike. This is the
# SYNCHRONOUS form (one long beat); the shipped boot path uses the frame-spread
# _prewarm_free_roam_deferred instead, off the critical path. The props land in _car_cache keyed by their
# (negative) preview instance_id, exactly where _obtain_parked_car looks, and are kept for
# the session (never evicted — see _evict_unowned_cached_cars). Idempotent: a preview already
# warm (matching hash) is skipped, so a stray re-call is a cheap no-op.
func _prewarm_free_roam() -> void:
	for preview in _hq._all_car_previews():
		_warm_one_preview(preview)
	_hq._prewarm_complete = true


# Spawn ONE catalogue preview into _car_cache as a hidden, stowed prop. Returns true when
# it actually spawned (false = already warm, so the call was a no-op). The unit of work
# shared by _prewarm_free_roam and its deferred, frame-spread twin below.
func _warm_one_preview(preview: Dictionary) -> bool:
	var instance_id := int(preview.get("instance_id", -1))
	var preview_hash: int = preview.hash()
	var cached: Dictionary = _hq._car_cache.get(instance_id, {})
	if is_instance_valid(cached.get("node")) and int(cached.get("hash", 0)) == preview_hash:
		return false  # already warm
	if is_instance_valid(cached.get("node")):
		cached["node"].queue_free()
	var node := _spawn_parked_car(preview, _prewarm_stow_marker())
	node.visible = false
	_hq._car_cache[instance_id] = {"hash": preview_hash, "node": node}
	return true


# The deferred prewarm: the same work as _prewarm_free_roam, but started AFTER the loading
# cover lifts and spread one prop per frame, so HQ is interactive at the end of _build_hq
# instead of one whole prewarm later (§2.14 / E8 — the prewarm measured ~3x the rest of
# HQ boot). Each spawn is still a single indivisible beat, so the trickle isn't free: it's
# a handful of frames of hitch while the player looks at the static title shot, instead of
# a frozen boot. Awaiting a frame BETWEEN spawns also lets input and the reveal tween run.
#
# If the player opens Free Roam before this finishes, nothing breaks and nothing is
# dropped: _build_lineup goes through _obtain_parked_car, which reuses whatever is already
# warm and instances the rest on the spot (the old first-entry cost, but only for the
# not-yet-warmed remainder), and those lineup nodes land in _car_cache under the same
# key + hash, so this loop simply skips them when it resumes on the next frame.
#
# It also spawns only while the player is STILL (_await_prewarm_window below), because a
# ~100 ms frame is invisible on a title shot and a hitch the moment they are navigating.
#
# Idempotent and self-cancelling: re-entrant calls bail, and the loop stops if the HQ
# leaves the tree (exit to a race frees the node and everything it cached).
func _prewarm_free_roam_deferred() -> void:
	if _hq._prewarm_complete or _hq._prewarm_running:
		return
	_hq._prewarm_running = true
	var t0 := Time.get_ticks_msec()
	var spawned := 0
	for preview in _hq._all_car_previews():
		if not _hq.is_inside_tree():
			_hq._prewarm_running = false
			return
		await _await_prewarm_window()
		if not _hq.is_inside_tree():
			_hq._prewarm_running = false
			return
		if _warm_one_preview(preview):
			spawned += 1
			await _hq.get_tree().process_frame
	_hq._prewarm_running = false
	_hq._prewarm_complete = true
	_log_prewarm_cost(Time.get_ticks_msec() - t0, spawned)


# Park until the HQ is idle enough to absorb one car spawn (HqController._prewarm_should_wait
# decides), or until we have waited HqController.PREWARM_MAX_STALL_MS and take the frame
# anyway.
#
# The cap is the point: without it a player who never sits still would leave the catalogue
# half-warm forever, and opening Free Roam would then pay the full cold cost this whole
# mechanism exists to avoid. Waiting is measured, not counted in frames, so it means the same
# thing at 30 and at 60 fps.
func _await_prewarm_window() -> void:
	var waited := 0
	while _hq.is_inside_tree() and _hq._prewarm_should_wait() and waited < HqController.PREWARM_MAX_STALL_MS:
		var t0 := Time.get_ticks_msec()
		await _hq.get_tree().process_frame
		waited += maxi(0, Time.get_ticks_msec() - t0)


# Spawn one owned car as a silent car prop resting at a marker, with its OWN mesh
# copies (see CarProp.dup_meshes) so a mixed lineup shows each at its true size. Placed with
# its wheels on the bay via the analytic rest ride height (car.gd:settled_ride_height)
# and frozen at once — no live physics to settle, so nothing to mistime or drift.
func _spawn_parked_car(owned: Dictionary, marker: Marker3D) -> Node3D:
	# Frozen prop resting at its pose: no body integration and no per-frame car script
	# (drivetrain/steering/aero) cost. We stop physics processing (stop_physics) rather
	# than fully PROCESS_MODE_DISABLE the node so the body stays a normal member of the
	# physics space — it must remain ray-pickable for tap-to-focus (see _car_index_at).
	var configure := func(c) -> void: _seat_car_at_marker(c, marker)
	return CarProp.spawn(_hq, _hq._car_scene_res(), {
		"owned": owned,
		"configure": configure,
		"stop_physics": true,
		"smoke": _add_synthetic_smoke,
	})


# Seat a car on its bay marker with its wheels on the ground: the marker's pose (bay
# position + facing) lifted by the car's analytic resting ride height. Shared by fresh
# spawns and cache reuse so both sit identically on their suspension at any bay.
func _seat_car_at_marker(car: Node, marker: Marker3D) -> void:
	car.global_transform = marker.global_transform
	car.global_position += Vector3.UP * car.settled_ride_height()
	car.settle_wheel_visuals()  # frozen prop: droop the wheels to their live rest pose


# Give a damaged display car (car park / lift) its own synthetic engine smoke — the
# frozen prop's engine never runs, so EngineSmoke self-times puffs from the car's
# damage severity instead of misfire cutouts. Parented to the CAR (so it's freed with
# it) but top_level (world-space render, ignoring the car transform, like the event
# pool at the scene root) and PROCESS_MODE_ALWAYS (keeps puffing though the car is
# frozen / process-disabled). Skipped for a healthy car (severity 0 = no smoke).
func _add_synthetic_smoke(car: Node) -> void:
	# Healthy display cars (no misfire severity) don't smoke; the wreck path has no
	# such gate. The shared attach handles the engine_smoke_enabled check + wiring.
	if car.get("damage") == null or car.damage.misfire_level(Config.data) <= 0.0:
		return
	EngineSmoke.attach_synthetic(car)


# Pan the focus to the prev/next car in the list (wrapping). Delegates to the paginator:
# a move within the page just re-frames; a move across a page boundary flips the page and
# re-spawns its props (snapping the camera, since the whole lineup changed). At the ends
# of the whole list it wraps around (single page → wraps in place). See scripts/car_list.gd.
func _cycle_focus(step: int) -> void:
	# The cosmetic wheel view parks ONE car, so there are no bays to page: the same
	# left/right input (plus the ◄ ► nav-row buttons and the swipe gesture, which both
	# route here) steps the WHEEL list instead. Deliberately bypasses _focus_changed —
	# the focused car never changes, and that path would rev the engine and overwrite the
	# wheel name label on every flick.
	if _hq._carpark_mode == _hq.CarparkMode.WHEELS:
		_hq._cycle_wheel(step)
		return
	if _hq._lineup.is_empty():
		return
	var page_flipped := _hq._lineup.advance(step)
	if page_flipped:
		_render_lineup_page()   # spawn the new page's props; refreshes _eligible / _focus
		_focus_changed(true)    # snap — the whole lineup just swapped out
	else:
		_hq._focus = _hq._lineup.focus
		_focus_changed()


# React to a focus change: make the focused car the selected car, re-aim the camera
# + stats panel at it. No respawn — every eligible car is already parked.
func _focus_changed(snap := false) -> void:
	if _hq._eligible.is_empty():
		return
	var owned: Dictionary = _hq._eligible[_hq._focus]
	_hq._selected_instance_id = int(owned.get("instance_id", -1))
	var entry := CarLibrary.by_id(String(owned.get("model_id", "")))
	# Let the player hear the focused car: rev its (possibly swapped) engine. Fires
	# on every flick and on the initial lineup show; a new rev cancels the previous.
	if not entry.is_empty():
		_preview_rev(EngineSwap.current_engine_id(owned, String(entry.get("engine", ""))), owned)
	var stats := _hq._car_stats_text(owned, entry)
	var display_owned: Dictionary = Save.get_car(_hq._selected_instance_id)
	var display_name: String = (EngineSwap.display_name(entry, display_owned)
		if not display_owned.is_empty() else String(entry.get("name", owned.get("model_id", "?"))))
	# Position across the WHOLE list (all pages), not just the current page.
	_hq._car_name_label.text = "%s  (%d of %d)" % [
		display_name, _hq._lineup.global_index() + 1, _hq._lineup.total()]
	_hq._car_stats_label.text = stats
	_refresh_swap_preview()
	if _hq._carpark_mode == _hq.CarparkMode.SWAP:
		# Picking a swap partner: no car is excluded on health; the token cost is
		# surfaced in the confirm popup, so keep Start enabled and the warning clear.
		_hq._start_button.disabled = false
		_hq._car_warning_label.visible = false
	else:
		# A wrecked focused car gates Start — permanently.
		_refresh_focus_damage(owned)
	_hq._normalize_menus()  # keep house rules on the just-updated car name / stats
	_hq._move_camera_to(_hq._camera_target_xform(), snap)


# Rev the focused car's engine as a short preview (lazily builds the player). The owned
# car goes along so its FITTED upgrades (turbo / supercharger) are heard, not just the
# factory engine — see CarPreviewAudio.rev.
func _preview_rev(engine_id: String, owned_car: Dictionary = {}) -> void:
	if engine_id.is_empty():
		return
	if _hq._preview_audio == null:
		_hq._preview_audio = CarPreviewAudio.new()
		_hq.add_child(_hq._preview_audio)
	_hq._preview_audio.rev(engine_id, owned_car)


# The two-way power-to-weight preview shown only while picking an engine-swap partner.
# A swap EXCHANGES engines, so it shows the resulting hp/tonne for the car on the lift
# (receiving the focused partner's engine) AND the focused partner (receiving the lift
# car's engine). Coloured ↑ gain / ↓ loss / — unchanged. Hidden in every other mode.
func _refresh_swap_preview() -> void:
	if _hq._swap_preview_label == null:
		return
	if _hq._carpark_mode != _hq.CarparkMode.SWAP:
		_hq._swap_preview_label.visible = false
		_hq._swap_preview_label.text = ""
		return
	var lift_owned := Save.get_car(Save.selected_instance_id())
	var partner_owned: Dictionary = _hq._eligible[_hq._focus]
	if lift_owned.is_empty() or partner_owned.is_empty():
		_hq._swap_preview_label.visible = false
		return
	var lift_entry := CarLibrary.by_id(String(lift_owned.get("model_id", "")))
	var partner_entry := CarLibrary.by_id(String(partner_owned.get("model_id", "")))
	var lift_stock := String(lift_entry.get("engine", ""))
	var partner_stock := String(partner_entry.get("engine", ""))
	var lift_engine := EngineSwap.current_engine_id(lift_owned, lift_stock)
	var partner_engine := EngineSwap.current_engine_id(partner_owned, partner_stock)
	var k := CarLibrary.KW_KG_TO_HP_TONNE
	# Lift car receives the partner's engine; partner receives the lift car's engine.
	var lift_before := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(lift_owned, lift_entry)) * k
	var lift_after := EngineSwap.pw_after_swap(lift_owned, lift_entry, partner_engine) * k
	var partner_before := CarLibrary.power_to_weight(UpgradeLibrary.effective_meta(partner_owned, partner_entry)) * k
	var partner_after := EngineSwap.pw_after_swap(partner_owned, partner_entry, lift_engine) * k
	_hq._swap_preview_label.text = "%s\n%s" % [
		_swap_preview_row(String(lift_entry.get("name", "?")), lift_before, lift_after),
		_swap_preview_row(String(partner_entry.get("name", "?")), partner_before, partner_after)]
	_hq._swap_preview_label.visible = true


# One preview row: "Name:  before → after hp/tonne ↑" with a coloured arrow.
func _swap_preview_row(car_name: String, before: float, after: float) -> String:
	# Palette colours, not hand-typed hex: to_html(false) drops the alpha byte, which BBCode's
	# [color=#rrggbb] wants. Keeps the up/down/neutral semantics in one place (UITheme).
	var arrow := "[color=#%s]—[/color]" % UITheme.INK_DIM.to_html(false)
	if after > before + 0.5:
		arrow = "[color=#%s]↑[/color]" % UITheme.GREEN.to_html(false)
	elif after < before - 0.5:
		arrow = "[color=#%s]↓[/color]" % UITheme.RED.to_html(false)
	return "[center]%s:  %.0f → %.0f hp/tonne %s[/center]" % [car_name, before, after, arrow]


# A wrecked focused car can't be entered — ever: disable Start and say so. There is no
# repair to offer any more. A healthy car clears all of this — an
# over-powered car looks eligible here; the over-limit prompt only surfaces as a
# confirm popup on Start (_show_over_limit_prompt).
func _refresh_focus_damage(owned: Dictionary) -> void:
	# Damage NEVER blocks entry any more. A wreck is not terminal (Save.record_wreck hands
	# the car back at part health), so a battered car is a car you can still race — badly.
	# The warning is an INSTRUCTION now, not a verdict: it points at the repair the player
	# can go and buy (features/star-economy.md) rather than telling them the car is dead.
	_hq._start_button.disabled = false
	var id := int(owned.get("instance_id", -1))
	# car_handles_badly, NOT car_needs_repair: the latter is true of any car that is not
	# pristine, so this line used to fire at 98% health and claim the car would handle
	# badly. Repair is still offered for any lost health — that is a different question,
	# asked by the lift's repair button.
	var hurt := _hq._carpark_mode != _hq.CarparkMode.WHEELS and Save.car_handles_badly(id)
	_hq._car_warning_label.visible = hurt
	if hurt:
		_hq._car_warning_label.text = "Damaged — the engine is down on power. Repair it at the lift."


# A full-screen dimmer + centred house panel on the car CanvasLayer, holding `body`
# built by the caller. Used for the detune prompt and the Change-Upgrades popup so both
# read as on-brand modals (black panel, sharp corners) instead of native grey dialogs.
#
# Same scrolled-body / pinned-footer contract as _make_modal_overlay (read its header for
# WHY): the caller's `build_body` fills a VBox that lives inside a TouchScrollContainer,
# and `build_footer` fills the row pinned underneath it, which is where the control that
# closes the modal belongs. The panel is capped to the frame height (not just centred on
# it) so the footer is on screen even when the body is taller than the canvas — which the
# upgrades list, on a short frame, routinely is.
func _make_carpark_modal(build_body: Callable, build_footer := Callable()) -> Control:
	# MenuPage is the shared implementation of this shape. It used to be hand-rolled here
	# because MenuPage had no dim backdrop and this is a true modal — it must read as blocking
	# the car park underneath — but `dim` now covers that, so the bespoke copy is gone.
	#
	# The reason the old version explained at length for NOT using a CenterContainer (a
	# CenterContainer hands its child the child's full MINIMUM size, so a panel taller than the
	# frame overhangs top and bottom and takes the pinned footer off-screen with it) is exactly
	# what MenuPage._sync_body_height solves: it budgets the box against the frame height and
	# lets the scroll inside absorb the overflow, so the action row stays reachable.
	#
	# margin 16 + padding 20 keep the previous geometry; the caller's `chrome` figure for
	# _modal_body_width is derived from them (20 either side + 16 either side = 72).
	var page := MenuPage.new({"dim": true, "margin": 16.0, "padding": 20})
	build_body.call(page.body())
	if build_footer.is_valid():
		# The footer row is now OUTSIDE the box (MenuPage's rule 2), which also means it can no
		# longer be pushed off the bottom by a growing body — the failure the old comment here
		# was guarding against by hand.
		build_footer.call(page.actions())
	_hq._car_layer.add_child(page)
	return page


# An over-powered focused car (parked because a detune would duck it under the rally's
# pw_max cap — _build_eligible_lineup) looks eligible in the car park; pressing Start
# pops this on-brand modal instead. It offers three left/right-navigable choices —
# Change Upgrades (open the gated upgrades menu, where detune / ballast / stripping parts
# brings the car under the cap — the menu won't let them leave until it's eligible) or
# Cancel. No auto-detune button: the player makes the change themselves and re-presses
# Start (the fix persists like any garage edit — see todo/detune-min-pw-interaction.md).
func _show_over_limit_prompt(_owned: Dictionary) -> void:
	_hq._active_carpark_popup = ConfirmPopup.open(_hq, "Too powerful",
		"Change your upgrades to get under the power-to-weight limit.",
		[ {"label": "Cancel", "callback": _close_detune_panel},
		  {"label": "Change Upgrades", "callback": _detune_change_upgrades} ], 1, 0)


# Whether a car-park modal overlay (detune prompt / Change-Upgrades popup) is showing,
# so _unhandled_input hands navigation to its MenuNav instead of the lineup beneath.
func _carpark_modal_open() -> bool:
	return is_instance_valid(_hq._active_carpark_popup) \
		or (_hq._upgrades_popup != null and _hq._upgrades_popup.visible)


func _close_detune_panel() -> void:
	_focus_changed()


# The detune prompt's Change Upgrades choice: close the prompt and open the upgrades
# menu for the focused car so the player can strip / switch parts to duck under the cap.
func _detune_change_upgrades() -> void:
	_show_upgrades_popup(Save.get_car(_hq._selected_instance_id))


# Show the upgrades menu over the car-park car-select for the focused car, as an on-brand
# centred modal. Reuses the UpgradesMenu component with NO engine-swap row (on_swap left
# invalid — the swap flow would change the HQ view). Nav-wired so it's keyboard/gamepad
# navigable; Done / back closes it (see _close_upgrades_popup).
func _show_upgrades_popup(owned: Dictionary) -> void:
	if _hq._upgrades_popup == null:
		_hq._upgrades_popup = _make_carpark_modal(
			func(vbox: VBoxContainer) -> void:
				# 460 was wider than the whole logical canvas on the short web-touch tier
				# (~445 units on a 16:9 phone), so it's now the DESKTOP preference and
				# _modal_body_width clamps it to whatever the frame can actually show;
				# chrome = the panel's 20-unit padding either side plus the modal margin.
				vbox.custom_minimum_size = Vector2(_hq._modal_body_width(460.0, 72.0), 0)
				# No title here: UpgradesSimple draws its own heading, which is what
				# carries the star balance (UpgradesMenu.build_title_row).
				_hq._upgrades_popup_menu = UpgradesSimple.new()
				vbox.add_child(_hq._upgrades_popup_menu),
			func(footer: HBoxContainer) -> void:
				# Done is the gated exit (bind_close_button below blocks it, AND back,
				# while the car is over the p/w cap). It is PINNED outside the scroll:
				# the controls the player needs in order to get under the cap are the very
				# ones that grow this list, so letting them push Done off the bottom would
				# lock a touch player inside a modal they are not allowed to leave.
				_hq._upgrades_popup_done = Button.new()
				_hq._upgrades_popup_done.text = "Done"
				_hq._upgrades_popup_done.focus_mode = Control.FOCUS_ALL
				# NOTE: press is wired by bind_close_button below (gated), not here.
				footer.add_child(_hq._upgrades_popup_done))
	_hq._upgrades_popup_dirty = false
	_hq._upgrades_popup.visible = true
	var pw_limit := -1.0
	if _hq._carpark_mode == _hq.CarparkMode.CHALLENGE:
		pw_limit = ChallengeLibrary.current_ceiling(
			_hq._challenge_kind, int(Time.get_unix_time_from_system()))
	else:
		var rally := RallyLibrary.by_id(_hq._selected_rally_id)
		var restriction: Dictionary = rally.get("restriction", {}) if not rally.is_empty() else {}
		pw_limit = float(restriction.get("pw_max", -1.0))
	_hq._upgrades_popup_menu.setup(owned, _on_popup_upgrade_changed, Callable(), pw_limit)
	# Gate Done + Esc/back on the rally's p/w cap: over the cap, the button goes red and
	# neither it nor MenuNav's on_back closes the popup until the player detunes under it.
	_hq._upgrades_popup_menu.bind_close_button(_hq._upgrades_popup_done, _close_upgrades_popup)
	UITheme.enforce(_hq._upgrades_popup)
	MenuNav.attach(_hq._upgrades_popup, {
		"first": _hq._upgrades_popup_menu.first_control(),
		"on_back": _hq._upgrades_popup_menu.request_close,
	})


# A popup upgrade edit: just flag dirty. The UpgradesMenu already repainted its own detune
# label + gated Done button (the visible feedback); the parked-car prop + lineup are rebuilt
# on close so a live rebuild can't steal focus from the popup mid-edit.
func _on_popup_upgrade_changed() -> void:
	_hq._upgrades_popup_dirty = true


# Close the upgrades popup and return to car-select. If anything changed, rebuild the
# eligible lineup so a now-ineligible car drops out; the player re-presses Start and the
# normal flow recomputes (eligible → launch; still over → detune prompt reappears).
func _close_upgrades_popup() -> void:
	if _hq._upgrades_popup != null:
		_hq._upgrades_popup.visible = false
	if _hq._upgrades_popup_dirty:
		if _hq._carpark_mode == _hq.CarparkMode.CHALLENGE:
			_hq._challenge_ui._build_challenge_lineup(_hq._challenge_kind)
		else:
			_build_eligible_lineup()
		_hq._upgrades_popup_dirty = false
	_focus_changed()


# Rough per-vertex byte cost of an interleaved car vertex (position + normal + tangent +
# UV, packed). Only used to turn vertex/index counts into an order-of-magnitude MB figure
# in the log below — it is an estimate label, never a budget.
const CAR_MESH_VERTEX_BYTES := 32
const CAR_MESH_INDEX_BYTES := 4


# Printed when the deferred Free Roam prewarm finishes (see _prewarm_free_roam_deferred).
# Wall-clock here spans the awaited frames, so it is NOT boot cost — it's how long after
# the reveal the cache took to fill. The resident car-cache figures follow it because the
# cache is only at full size once the warm completes.
func _log_prewarm_cost(elapsed_ms: int, spawned: int) -> void:
	print("hq prewarm (deferred, off boot path): %d props over %d ms wall-clock"
		% [spawned, elapsed_ms])
	var cost := _car_cache_mesh_cost()
	print("hq car cache: %d props (%d preview, %d owned-garage), %d meshes, ~%.2f MB mesh data (est)"
		% [cost["props"], cost["previews"], cost["props"] - cost["previews"],
			cost["meshes"], float(cost["bytes"]) / 1048576.0])


# Resident cost of _car_cache: how many props are held, how many of them are the
# never-evicted Free Roam previews (negative instance_id — see _evict_unowned_cached_cars),
# how many duplicated meshes they own, and an estimate of those meshes' vertex/index bytes.
# Returns {"props", "previews", "meshes", "bytes"}.
func _car_cache_mesh_cost() -> Dictionary:
	var out := {"props": 0, "previews": 0, "meshes": 0, "bytes": 0}
	for id in _hq._car_cache:
		var node = _hq._car_cache[id].get("node")
		if not is_instance_valid(node):
			continue
		out["props"] += 1
		if int(id) < 0:
			out["previews"] += 1
		for child in node.find_children("*", "MeshInstance3D", true, false):
			# ArrayMesh only: the car glbs import as ArrayMesh, and primitives (if any ever
			# appear) carry no surface-array counts to read cheaply, so they're skipped
			# rather than guessed at. That keeps this an under-estimate, never an over-one.
			var mesh := (child as MeshInstance3D).mesh as ArrayMesh
			if mesh == null:
				continue
			out["meshes"] += 1
			for s in mesh.get_surface_count():
				out["bytes"] += (mesh.surface_get_array_len(s) * CAR_MESH_VERTEX_BYTES
					+ mesh.surface_get_array_index_len(s) * CAR_MESH_INDEX_BYTES)
	return out

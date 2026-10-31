extends Node
# Docs: features/world-session.md — update in the same change as this file.
# Tests: tests/headless/test_world_session.gd — extend in the same change.
# THE WORLD (todo/2026-10-19-free-roam-pivot.md, decisions 2 and 26, stage 6): one persistent
# free-roam world per save, which never resets. This autoload owns its state and keeps it in the
# profile under Save.KEY_WORLD. Progress (money, lit stops, coins, cars) is saved and uploaded as it
# happens; where the car is and what it has seen is saved by free roam's periodic save_world.
#
# The world block:
#   seed           — the island's world seed (FreeRoamSettings.world_seed)
#   car            — the active owned car's instance id (Save.KEY_CARS)
#   pose           — [x, y, z, yaw]: where the car is, written every few seconds and on leaving
#   car_state      — {hp, cooling_broken, engine_temp, toe}: its damage, so a reload resumes it
#   lit            — rest stop site ids lit so far (spawn, 0, always)
#   cold_open      — true while a first-time player's cold open is still to be driven (ColdOpen); absent after
#   last_site      — the respawn point
#   driven         — map cells the car has driven through ("x,y" keys of DRIVEN_CELL_M cells)
#   max_ring       — the furthest biome ring reached (the map shows the borders crossed)
#   drive_time     — seconds driven (the weather timeline runs on it)
#   seen           — site ids (rest stops, loot slots, dead ends) the car has come near, for the minimap / map
#   money          — coins picked up and not yet spent (all lost when the car gives up)
#   dropped        — the money left at the last wreck and where, until driven back to (or lost)
#   collected / revealed — coin spots taken, rings whose stock is on sale
#   sites_hash     — which generated site list the site ids above index into (check_sites)
# (A car's parts live on the owned car itself: `parts`, each switched on or off.)
#
# No world yet (a fresh profile) means has_world() is false; the title screen offers New World.

const DRIVEN_CELL_M := 40.0

# Set by the boot scene (title_boot.gd) so the next free-roam load opens the title menu over itself.
var title_pending := false
# The world was made at boot for a first-time player, so New World can pick a car on it instead of
# building another.
var fresh := false

signal world_changed()

# Bumped whenever the world in the profile is replaced (a new world, a cloud download, a wipe, the
# benchmark's throwaway world and back). A scene that captured it can tell its world is gone.
var generation := 0
var _seen_src: Array = []  # the stored "seen" list _seen_set was built from
var _seen_set := {}


func _ready() -> void:
	Save.replaced.connect(invalidate)


func invalidate() -> void:
	generation += 1
	world_changed.emit()


func has_world() -> bool:
	return not _world().is_empty() and _world().has("seed")


func _world() -> Dictionary:
	return Save.profile.get(Save.KEY_WORLD, {})


func _touch() -> void:
	Save.save()


# Start a new world: on `world_seed` (callers pass FreeRoamSettings' fixed island) with a starter car, replacing any world (and its loot)
# in this profile. Owned cars from an old world go with it — a world is the whole save
# (decision 2: "one persistent world per save").
func new_world(world_seed: int, starter_model_id: String) -> void:
	Save.profile[Save.KEY_CARS] = []
	var car := Save.grant_car(starter_model_id)
	Save.profile[Save.KEY_WORLD] = {
		"seed": world_seed,
		"car": int(car["instance_id"]),
		"pose": [],
		"car_state": {},
		"lit": [0],
		"last_site": 0,
		"driven": {},
		"max_ring": 0,
		"drive_time": 0.0,
		"seen": [0],
		"money": 0,
		"dropped": {},
		"collected": [],
		"revealed": [],
	}
	_touch()
	invalidate()


func world_seed() -> int:
	return int(_world().get("seed", 1))


func active_car() -> Dictionary:
	return Save.get_car(int(_world().get("car", -1)))


func set_active_car(instance_id: int) -> void:
	if Save.get_car(instance_id).is_empty() or not has_world():
		return
	_world()["car"] = instance_id
	_world()["car_state"] = {}
	_touch()


# --- the car's place and condition ------------------------------------------------------------

func pose() -> Array:
	return _world().get("pose", [])


func save_pose(xform: Transform3D) -> void:
	if not has_world():
		return
	var fwd := -xform.basis.z
	_world()["pose"] = [xform.origin.x, xform.origin.y, xform.origin.z, atan2(fwd.x, fwd.z)]


# The saved pose as a transform (upright, facing the saved yaw), or null when there is none.
func pose_transform() -> Variant:
	var p := pose()
	if p.size() < 4:
		return null
	var yaw := float(p[3])
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), Vector3(float(p[0]), float(p[1]), float(p[2])))


func save_car_state(dmg: DamageModel) -> void:
	if not has_world() or dmg == null:
		return
	_world()["car_state"] = {"hp": dmg.hp, "cooling_broken": dmg.cooling_broken,
		"engine_temp": dmg.engine_temp, "toe": dmg.toe_array()}


# Put the saved damage back onto a freshly fielded car. Nothing saved: leave it as fielded.
func restore_car_state(dmg: DamageModel) -> void:
	var st: Dictionary = _world().get("car_state", {})
	if st.is_empty() or dmg == null:
		return
	dmg.hp = clampf(float(st.get("hp", dmg.max_hp)), 0.0, dmg.max_hp)
	dmg.cooling_broken = bool(st.get("cooling_broken", false))
	dmg.engine_temp = float(st.get("engine_temp", dmg.engine_temp))
	dmg.set_toe_from_array(st.get("toe", []))


# --- rest stops -----------------------------------------------------------------------------------

# As ints: JSON hands numbers back as floats, and a float id would never match (has()) the int.
func lit_sites() -> Array:
	var out: Array = []
	for v in _world().get("lit", [0]):
		out.append(int(v))
	return out


func light(site: int) -> void:
	if not has_world():
		return
	var lit := lit_sites()
	if not lit.has(site):
		lit.append(site)
		_world()["lit"] = lit
		Save.add_lifetime_stat(LifetimeStats.REST_STOPS_LIT)
		_touch()


func last_site() -> int:
	return int(_world().get("last_site", 0))


func set_last_site(site: int) -> void:
	if not has_world() or last_site() == site:
		return
	_world()["last_site"] = site


# --- the map ------------------------------------------------------------------------------------

static func cell_key(x: float, z: float) -> String:
	return "%d,%d" % [floori(x / DRIVEN_CELL_M), floori(z / DRIVEN_CELL_M)]


# Record the car's position for the map. Returns true when it was a new cell.
func mark_driven(x: float, z: float) -> bool:
	if not has_world():
		return false
	var driven: Dictionary = _world().get("driven", {})
	var key := cell_key(x, z)
	if driven.has(key):
		return false
	driven[key] = true
	_world()["driven"] = driven
	return true


func has_driven(x: float, z: float) -> bool:
	return (_world().get("driven", {}) as Dictionary).has(cell_key(x, z))


func max_ring() -> int:
	return int(_world().get("max_ring", 0))


# True when `r` is a ring never reached before in this world (the region banner's cue).
func reach_ring(r: int) -> bool:
	if has_world() and r > max_ring():
		_world()["max_ring"] = r
		return true
	return false


func drive_time() -> float:
	return float(_world().get("drive_time", 0.0))


func set_drive_time(t: float) -> void:
	if has_world():
		_world()["drive_time"] = t


# --- sites seen (the minimap and the map show rest stops and loot once you've come across them) ---

# As ints, like lit_sites (JSON floats). An older save with no "seen" key reads as only spawn.
func seen_sites() -> Array:
	var out: Array = []
	for v in _world().get("seen", [0]):
		out.append(int(v))
	return out


func is_seen(site: int) -> bool:
	return _seen().has(site)


# Record that the car has come across `site`. Returns true when it is newly seen.
func see(site: int) -> bool:
	if not has_world() or _seen().has(site):
		return false
	if not _world().has("seen"):
		_world()["seen"] = [0]
		_seen()
	(_world()["seen"] as Array).append(site)
	_seen_set[site] = true
	return true


# The seen ids as a set, rebuilt only when the stored list is a different one (another world).
func _seen() -> Dictionary:
	var stored: Array = _world().get("seen", [0])
	if not is_same(stored, _seen_src):
		_seen_src = stored
		_seen_set = {}
		for v in stored:
			_seen_set[int(v)] = true
	return _seen_set


# --- generated sites ------------------------------------------------------------------------------

# Site ids index into the list the streamer generates at every boot. When that list is not the
# one this world was saved against (a retune), the site-keyed progress is dropped, not misread.
func check_sites(fingerprint: int) -> void:
	if not has_world():
		return
	var w := _world()
	if w.has("sites_hash") and int(w["sites_hash"]) != fingerprint:
		push_warning("WorldSession: the island's sites changed since this world was saved; resetting site progress")
		w["lit"] = [0]
		w["last_site"] = 0
		w["seen"] = [0]
		w["collected"] = []
		w["revealed"] = []
		w["pose"] = []
	w["sites_hash"] = fingerprint
	Save.save(false)


func sites_fingerprint(sites: RoadSites) -> int:
	return hash(sites.kind)


# --- the coin economy (LootDirector reads and writes these) ----------------------------------------

# Older saves kept bought parts in one shared world `stash`. Parts now belong to one car, so
# those are unlocked for the car being driven, switched off, once.
func adopt_old_stash() -> void:
	if not has_world() or not _world().has("stash"):
		return
	var car := active_car()
	if not car.is_empty():
		var parts: Array = car.get("parts", []).duplicate(true)
		var have := {}
		for p: Dictionary in parts:
			have[String(p["id"])] = true
		for p: Dictionary in _world()["stash"]:
			if not have.has(String(p["id"])):
				have[String(p["id"])] = true
				var off := p.duplicate()
				off["on"] = false
				parts.append(off)
		Save.set_car_parts(int(car["instance_id"]), parts)
	_world().erase("stash")
	_touch()


# A first-time player's world: the cold open (ColdOpen) is still to be driven. Set by the boot scene
# when it makes the world, cleared once the car reaches the spawn cabin. A quit midway drives it again.
func cold_open_pending() -> bool:
	return has_world() and bool(_world().get("cold_open", false))


func set_cold_open_pending(on: bool) -> void:
	if not has_world():
		return
	if on:
		_world()["cold_open"] = true
	else:
		_world().erase("cold_open")
	_touch()


func list(key: String) -> Array:
	return _world().get(key, [])


func set_list(key: String, value: Array) -> void:
	if has_world():
		_world()[key] = value
		_touch()


# The money left at the last wreck, {"pos": [x, y, z], "money": n}, or {}.
func dropped() -> Dictionary:
	return _world().get("dropped", {})


func set_dropped(d: Dictionary) -> void:
	if has_world():
		_world()["dropped"] = d
		_touch()


func money() -> int:
	return int(_world().get("money", 0))


func set_money(value: int) -> void:
	if has_world():
		_world()["money"] = value
		_touch()

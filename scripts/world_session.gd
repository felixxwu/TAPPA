extends Node
# Docs: features/world-session.md — update in the same change as this file.
# Tests: tests/headless/test_world_session.gd — extend in the same change.
# THE WORLD (todo/2026-10-19-free-roam-pivot.md, decisions 2 and 26, stage 6): one persistent
# free-roam world per save, which never resets. This autoload owns its state and keeps it in the
# profile under Save.KEY_WORLD, saved continuously (debounced by Save). Free roam reads it at boot
# and writes it as you play.
#
# The world block:
#   seed           — the island's world seed (FreeRoamSettings.world_seed)
#   car            — the active owned car's instance id (Save.KEY_CARS)
#   pose           — [x, y, z, yaw]: where the car is, written every few seconds and on leaving
#   car_state      — {hp, cooling_broken, engine_temp, toe}: its damage, so a reload resumes it
#   lit            — rest stop site ids lit so far (spawn, 0, always)
#   last_site      — the respawn point
#   driven         — map cells the car has driven through ("x,y" keys of DRIVEN_CELL_M cells)
#   max_ring       — the furthest biome ring reached (the map shows the borders crossed)
#   drive_time     — seconds driven (the weather timeline runs on it)
#   seen           — site ids (rest stops, loot slots, dead ends) the car has come near, for the minimap / map
#   carried / stash / dropped / collected / revealed — the loot keys (stage 7)
#
# No world yet (a fresh profile) means has_world() is false; the title screen offers New World.

const DRIVEN_CELL_M := 40.0

signal world_changed()


func has_world() -> bool:
	return not _world().is_empty() and _world().has("seed")


func _world() -> Dictionary:
	return Save.profile.get(Save.KEY_WORLD, {})


func _touch() -> void:
	Save.save()


# Start a new world: a fresh island seed and a starter car, replacing any world (and its loot)
# in this profile. Owned cars from an old world go with it — a world is the whole save
# (decision 2: "one persistent world per save").
func new_world(world_seed: int, starter_model_id: String) -> void:
	Save.profile[Save.KEY_CARS] = []
	var car := Save.grant_car(starter_model_id)
	Save.profile["starter_picked"] = true
	Save.profile["starter_model_id"] = starter_model_id
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
		"carried": [],
		"stash": [],
		"dropped": {},
		"collected": [],
		"revealed": [],
	}
	_touch()
	world_changed.emit()


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
	_touch()


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
	_touch()


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
	_touch()


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
	_touch()
	return true


func has_driven(x: float, z: float) -> bool:
	return (_world().get("driven", {}) as Dictionary).has(cell_key(x, z))


func max_ring() -> int:
	return int(_world().get("max_ring", 0))


func reach_ring(r: int) -> void:
	if has_world() and r > max_ring():
		_world()["max_ring"] = r
		_touch()


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
	return seen_sites().has(site)


# Record that the car has come across `site`. Returns true when it is newly seen.
func see(site: int) -> bool:
	if not has_world():
		return false
	var seen := seen_sites()
	if seen.has(site):
		return false
	seen.append(site)
	_world()["seen"] = seen
	_touch()
	return true


# --- loot (stage 7 reads and writes these) ---------------------------------------------------------

func list(key: String) -> Array:
	return _world().get(key, [])


func set_list(key: String, value: Array) -> void:
	if has_world():
		_world()[key] = value
		_touch()


func dropped() -> Dictionary:
	return _world().get("dropped", {})


func set_dropped(d: Dictionary) -> void:
	if has_world():
		_world()["dropped"] = d
		_touch()

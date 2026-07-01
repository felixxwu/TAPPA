extends Node
# Autoload "Save": the single source of truth for everything the meta-game
# mutates — owned cars (each with its own HP / installed upgrades / tuning),
# the uninstalled-item inventory, and rally completion — persisted as JSON at
# user://profile.json so progress survives a restart on both desktop and the
# web build (see todo/save-persistence.md).
#
# It is deliberately SEPARATE from the `Config` autoload: `Config` holds the
# authored car/world tuning baseline (a duplicate of game_config.tres), while
# this profile is per-player mutable progress. Save stores tuning numbers but
# never touches GameConfig — the car-fielding code reads the stored tuning and
# writes the live Config.data (mirroring how car.gd's apply_car reshapes it).
#
# Ownership is INSTANCE-BASED: each owned car is a unique instance (instance_id)
# that references a CarLibrary model id, so two cars of the same model can
# diverge in HP / upgrades / tuning (the random-car reward can grant a model you
# already own). Max-HP is CarLibrary metadata, derived not stored.

# Bump on any breaking shape change to PlayerProfile; older files are migrated
# forward on load (see _migrate), newer files are refused rather than truncated.
const SCHEMA_VERSION := 1

# Default profile location. Kept as a settable property (not a hard const) so
# named save slots can be layered on later without reworking the API, and so
# headless tests can redirect to a throwaway file.
const DEFAULT_PROFILE_PATH := "user://profile.json"

# Coalesce bursts of mutations into one disk write ~1s after the last change, so
# a flurry of autosave triggers (e.g. an event resolving several rewards) costs
# one atomic write rather than many.
const SAVE_DEBOUNCE_SEC := 1.0

# The loaded profile (a plain Dictionary mirroring the JSON shape — keeps load /
# save / migration as pure dict transforms with no engine-class coupling).
var profile: Dictionary = {}

# Where the active profile is read from / written to. Tests override this before
# calling load_or_new().
var profile_path: String = DEFAULT_PROFILE_PATH

# True when a degraded environment (blocked storage / read-only fs) forces an
# in-memory-only profile — the UI surfaces a "progress won't be saved" notice.
var save_disabled := false

var _debounce: Timer


func _ready() -> void:
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = SAVE_DEBOUNCE_SEC
	_debounce.timeout.connect(save_now)
	add_child(_debounce)
	load_or_new()


# Persist on the way out, including when a mobile/web tab is backgrounded — on
# the HTML5 export user:// is IndexedDB, which may not flush before the tab
# closes, so we force a synchronous write on these notifications.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		save_now()


# --- Load --------------------------------------------------------------------

# Populate `profile` from disk, falling back to .bak then to a fresh default.
# Never overwrites a file it could not read (the player may want to recover it).
func load_or_new() -> void:
	save_disabled = false
	var loaded := _read_file(profile_path)
	if loaded.is_empty():
		loaded = _read_file(profile_path + ".bak")
	if loaded.is_empty():
		profile = _default_profile()
		return
	var migrated := _migrate(loaded)
	if migrated.is_empty():
		# A newer-than-known or unmigratable file: keep it untouched on disk and
		# run on a fresh in-memory profile rather than clobbering it.
		push_warning("Save: profile at %s is unreadable/newer than v%d — starting fresh, file kept"
			% [profile_path, SCHEMA_VERSION])
		profile = _default_profile()
		save_disabled = true
		return
	profile = _sanitise(migrated)
	# Recover a wrecked-out player: a free repair kit when every owned car is
	# wrecked and none is held (also checked on garage view). See features/damage.md.
	ensure_repair_safety_net()


# Read + JSON-parse a profile file. Returns {} on any failure (missing,
# unopenable, garbage) so callers can fall through to the next source.
func _read_file(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	# Use the JSON instance API (not JSON.parse_string) so malformed input is
	# reported via a returned error code instead of an engine-level error macro.
	var json := JSON.new()
	if json.parse(text) != OK:
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		return {}
	return json.data


# Drop entries that no longer resolve against the current roster (a car removed
# from CarLibrary) so old saves stay loadable as the roster evolves.
func _sanitise(p: Dictionary) -> Dictionary:
	var kept: Array = []
	for car in p.get("cars", []):
		if CarLibrary.index_of(car.get("model_id", "")) >= 0:
			kept.append(car)
		else:
			push_warning("Save: dropping owned car with unknown model_id '%s'" % car.get("model_id", ""))
	p["cars"] = kept
	return p


func has_save() -> bool:
	return FileAccess.file_exists(profile_path)


# --- Save --------------------------------------------------------------------

# Mark the profile dirty and (re)arm the debounce timer. Call this from mutators
# / call sites after a change; the actual disk write happens once the burst
# settles. No-op when storage is disabled.
func save() -> void:
	if save_disabled:
		return
	profile["updated_utc"] = ""  # caller may stamp; cosmetic, see Notes in spec
	_debounce.start()


# Force an immediate atomic write (bypassing the debounce). Writes to a .tmp
# then renames over the real file so a crash mid-write can't corrupt the only
# profile, and keeps the prior file as .bak for one generation.
func save_now() -> void:
	if save_disabled:
		return
	_debounce.stop()
	var tmp := profile_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("Save: cannot open %s for writing — progress will not be saved" % tmp)
		save_disabled = true
		return
	f.store_string(JSON.stringify(profile, "\t"))
	f.close()
	var dir := DirAccess.open(profile_path.get_base_dir())
	if dir != null:
		if FileAccess.file_exists(profile_path):
			dir.rename(profile_path, profile_path + ".bak")
		dir.rename(tmp, profile_path)


# Overwrite the current profile with a fresh one (after a ConfirmModal in the
# menus). Writes immediately so "New game" is durable at once.
func reset_new_game() -> void:
	profile = _default_profile()
	save_disabled = false
	save_now()


func _default_profile() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"created_utc": "",
		"updated_utc": "",
		"starter_picked": false,
		"starter_model_id": "",
		"next_instance_id": 1,
		"cars": [],
		"selected_instance_id": -1,
		"inventory": {},
		"rallies": {},
		"showdown_unlocked": false,
		"showdown_completed": false,
		"reward_history": [],
		"settings": {},
	}


# --- Migration ---------------------------------------------------------------
# Migrations are pure Dictionary -> Dictionary transforms keyed by the version
# they upgrade FROM, so they're unit-testable without disk I/O. Returns {} to
# signal "refuse to load" (newer-than-known, or a step is missing).

func _migrate(p: Dictionary) -> Dictionary:
	var v: int = int(p.get("schema_version", 0))
	if v > SCHEMA_VERSION:
		return {}  # downgrade: refuse
	while v < SCHEMA_VERSION:
		if not _MIGRATIONS.has(v):
			return {}  # gap in the migration chain: refuse rather than guess
		p = _MIGRATIONS[v].call(p)
		v = int(p.get("schema_version", v + 1))
	# Backfill any keys a (correctly-versioned but partial) file is missing.
	var base := _default_profile()
	for k in base:
		if not p.has(k):
			p[k] = base[k]
	return p

# version N -> N+1 transforms. Empty until the first breaking change ships;
# e.g. `0: func(p): p["schema_version"] = 1; ...; return p`.
const _MIGRATIONS := {}


# --- Owned-car mutators ------------------------------------------------------

# Grant a new owned-car instance referencing a CarLibrary model id. Returns the
# new OwnedCar dict.
func grant_car(model_id: String) -> Dictionary:
	var entry := CarLibrary.by_id(model_id)
	var max_hp: float = entry.get("max_hp", 1000.0) if not entry.is_empty() else 1000.0
	var car := {
		"instance_id": int(profile["next_instance_id"]),
		"model_id": model_id,
		"hp": max_hp,
		"installed_upgrades": [],
		"tuning": {},
	}
	profile["next_instance_id"] = int(profile["next_instance_id"]) + 1
	profile["cars"].append(car)
	if not profile.get("reward_history", []).has(model_id):
		profile["reward_history"].append(model_id)
	save()
	return car


# The OwnedCar dict for an instance id, or {} if not owned.
func get_car(instance_id: int) -> Dictionary:
	for car in profile["cars"]:
		if int(car["instance_id"]) == instance_id:
			return car
	return {}


# Apply impact damage. Clamps HP at 0; reaching 0 wrecks the car.
func apply_damage(instance_id: int, amount: float) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	var hp := float(car["hp"]) - amount
	if hp <= 0.0:
		wreck_car(instance_id)
		return
	car["hp"] = hp
	save()


# Wreck a car: leave it OWNED but at 0 HP — too damaged to enter a rally until a
# Repair Kit restores it (use_repair_kit). The car is NOT deleted; its installed
# upgrades stay fitted (parts are consumed on fit, so they're never returned).
func wreck_car(instance_id: int) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	car["hp"] = 0.0
	save()


# Whether an owned car is wrecked: a car sitting at 0 HP. A wrecked car stays in
# the garage but can't be fielded until a Repair Kit restores it.
func car_is_wrecked(car: Dictionary) -> bool:
	return not car.is_empty() and float(car.get("hp", 0.0)) <= 0.0


# Anti-soft-lock safety net: if the player owns cars, EVERY owned car is wrecked,
# and no Repair Kit is held, grant one free kit so a wrecked-out player can always
# bring a car back into service. Returns true if a kit was granted. Call this on
# save load and whenever the garage is shown.
func ensure_repair_safety_net() -> bool:
	var cars: Array = profile.get("cars", [])
	if cars.is_empty():
		return false
	for car in cars:
		if not car_is_wrecked(car):
			return false
	var inv: Dictionary = profile.get("inventory", {})
	if int(inv.get(UpgradeLibrary.REPAIR_KIT_ID, 0)) > 0:
		return false
	add_item(UpgradeLibrary.REPAIR_KIT_ID, 1)
	return true


# Permanently scrap an owned car the player chose to remove (e.g. to make room
# under max_owned_cars). A deliberate player action: the instance is erased and its
# installed upgrades are NOT returned — upgrades are consumed for good when applied
# (see install_upgrade), so they're lost with the car. The player's LAST owned car
# can never be scrapped — always keep at least one car so the repair-kit safety
# net (ensure_repair_safety_net) always has something to bring back. Returns true
# if a car was actually removed.
func scrap_car(instance_id: int) -> bool:
	var car := get_car(instance_id)
	if car.is_empty() or profile.get("cars", []).size() <= 1:
		return false
	profile["cars"].erase(car)
	save()
	return true


func set_tuning(instance_id: int, tuning: Dictionary) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	car["tuning"] = tuning.duplicate(true)
	save()


# --- Selected car ------------------------------------------------------------
# The player always has one owned car "selected" — the one raised on the garage
# tuning lift (todo/menus.md). It's the default car the lift tunes/upgrades, and
# (unless a rally car-select overrides it) the one fielded. Stored as an instance
# id, resolved lazily so it always points at a still-owned car.

# The selected OwnedCar, or {} if the player owns nothing. Falls back to (and
# records) the first owned car when the stored id is unset or no longer owned —
# so the selection self-heals after a wreck removes the selected instance.
func selected_car() -> Dictionary:
	var cars: Array = profile.get("cars", [])
	if cars.is_empty():
		return {}
	var id := int(profile.get("selected_instance_id", -1))
	var car := get_car(id)
	if car.is_empty():
		car = cars[0]
		set_selected_car(int(car.get("instance_id", -1)))
	return car


func selected_instance_id() -> int:
	var car := selected_car()
	return int(car.get("instance_id", -1)) if not car.is_empty() else -1


func set_selected_car(instance_id: int) -> void:
	profile["selected_instance_id"] = instance_id
	save()


# --- Player settings (device/UI preferences, not progress) -------------------
# A flat key->value bag under profile["settings"] for preferences like the chosen
# mobile control scheme. Old profiles missing the key are backfilled on load
# (_migrate), so callers can read freely.

func get_setting(key: String, default_value = null) -> Variant:
	var settings: Dictionary = profile.get("settings", {})
	return settings.get(key, default_value)


func set_setting(key: String, value: Variant) -> void:
	var settings: Dictionary = profile.get("settings", {})
	settings[key] = value
	profile["settings"] = settings
	save()


# --- Inventory + upgrade install --------------------------------------------

func add_item(item_id: String, n := 1, do_save := true) -> void:
	var inv: Dictionary = profile["inventory"]
	inv[item_id] = int(inv.get(item_id, 0)) + n
	if not profile.get("reward_history", []).has(item_id):
		profile["reward_history"].append(item_id)
	if do_save:
		save()


# Remove n of an item from inventory if available. Returns true on success.
func consume_item(item_id: String, n := 1) -> bool:
	var inv: Dictionary = profile["inventory"]
	var have := int(inv.get(item_id, 0))
	if have < n:
		return false
	if have == n:
		inv.erase(item_id)
	else:
		inv[item_id] = have - n
	save()
	return true


# Pull one item from inventory and fit it to a car. The part is FULLY CONSUMED on
# apply — it leaves inventory for good and never returns (not on swap, and not when
# the car is wrecked). Enforces one-upgrade-per-slot (UpgradeLibrary): installing
# into an occupied slot replaces the incumbent, which is scrapped (NOT refunded).
# Consumables (the repair kit) and unknown ids can't be slotted — use
# use_repair_kit() for those. Returns true on success.
func install_upgrade(instance_id: int, item_id: String) -> bool:
	var car := get_car(instance_id)
	if car.is_empty():
		return false
	var slot := UpgradeLibrary.slot_of(item_id)
	if slot.is_empty() or UpgradeLibrary.is_consumable(item_id):
		return false  # not a slottable upgrade
	if int(profile["inventory"].get(item_id, 0)) < 1:
		return false  # nothing to install; don't disturb the incumbent
	# Replace any incumbent occupying the same slot (scrapped, not refunded —
	# the previously-fitted part was already consumed when it was applied).
	for existing in car["installed_upgrades"].duplicate():
		if UpgradeLibrary.slot_of(existing) == slot:
			car["installed_upgrades"].erase(existing)
	consume_item(item_id, 1)
	car["installed_upgrades"].append(item_id)
	save()
	return true


# Spend one repair kit to FULLY restore a car's HP to its CarLibrary max_hp — the
# only way HP climbs back, and what brings a wrecked (0 HP) car back into service.
# Returns true if a kit was consumed and applied; false if none were owned.
func use_repair_kit(instance_id: int) -> bool:
	var car := get_car(instance_id)
	if car.is_empty():
		return false
	if not consume_item(UpgradeLibrary.REPAIR_KIT_ID, 1):
		return false
	var entry := CarLibrary.by_id(car["model_id"])
	var max_hp: float = entry.get("max_hp", float(car["hp"])) if not entry.is_empty() else float(car["hp"])
	car["hp"] = max_hp
	save()
	return true


# --- Rally completion --------------------------------------------------------

# Record a top-3 rally finish. Idempotent for the `completed` flag; updates the
# best combined time when a faster one comes in. The CAR reward is NOT granted
# here (re-wins are farmable — see reward-system.md); this only records progress
# and re-derives the showdown unlock.
func complete_rally(rally_id: String, combined_ms: int, placed: int = 0) -> void:
	var rallies: Dictionary = profile["rallies"]
	var rec: Dictionary = rallies.get(rally_id, {"completed": false, "best_combined_ms": 0, "best_placed": 0})
	rec["completed"] = true
	if int(rec.get("best_combined_ms", 0)) <= 0 or combined_ms < int(rec["best_combined_ms"]):
		rec["best_combined_ms"] = combined_ms
	# Track the BEST (lowest) finishing position ever achieved here — it drives the
	# map's star rating. Lower placement is better; 0 means "never placed".
	if placed > 0 and (int(rec.get("best_placed", 0)) <= 0 or placed < int(rec["best_placed"])):
		rec["best_placed"] = placed
	rallies[rally_id] = rec
	_recompute_showdown()
	save()


func rally_completed(rally_id: String) -> bool:
	return profile["rallies"].get(rally_id, {}).get("completed", false)


# Best (lowest) finishing position ever achieved in a rally, or 0 if never placed.
# Drives the world-map star rating (1st → 3 stars, 2nd → 2, 3rd → 1, else 0).
func best_placement(rally_id: String) -> int:
	return int(profile["rallies"].get(rally_id, {}).get("best_placed", 0))


# Number of rallies top-3'd — the single progression metric driving the
# reward-tier ceiling and the showdown unlock.
func completed_rally_count() -> int:
	var n := 0
	for rally_id in profile["rallies"]:
		if profile["rallies"][rally_id].get("completed", false):
			n += 1
	return n


# Showdown unlock is gated on rally completion. The exact threshold belongs to
# the rally roster (todo/rally-roster.md), which isn't implemented yet — when it
# lands, wire its "all rallies complete" query in here. Until then this is a
# conservative no-op so the flag is only ever set deliberately.
func _recompute_showdown() -> void:
	pass

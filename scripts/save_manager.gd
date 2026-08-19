extends Node
# Docs: features/engine-swap.md, features/save-persistence.md — update in the same change as this file.
# Tests: tests/headless/test_cloud_sync.gd, tests/headless/test_engine_swap.gd, tests/headless/test_save_manager.gd — extend in the same change. These are the PRIMARY ones, not all of them: before you change behaviour here, `grep -rn 'save_manager' tests/headless/` and read the assertions that pin what you are about to change (6 test files touch this script).
# Autoload "Save": the single source of truth for everything the meta-game
# mutates — owned cars (each with its own HP / car-bound installed upgrades /
# tuning), the shared item inventory, and rally completion — JSON at
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

# Emitted after any mutation marks the profile dirty. The optional cloud-save
# layer (the `Cloud` autoload) subscribes to this to schedule an upload.
#
# The dependency runs ONE WAY: Cloud knows about Save, Save knows nothing about
# Cloud. That keeps this autoload — and its tests — working identically whether
# or not cloud save is present or signed in.
signal profile_changed()

# Emitted by flush_and_sync(), the single "we are about to go away" entry point
# (desktop close / app pause / browser visibilitychange + pagehide). Cloud uses
# it to attempt a last upload.
signal flushed()

# Bump on any breaking shape change to PlayerProfile; older files are migrated
# forward on load (see _migrate), newer files are refused rather than truncated.
const SCHEMA_VERSION := 6

# The two profile keys the REST of the codebase reads (the owned-car array and the
# per-rally record map) — named here because SaveManager owns the save schema, and a
# ~50-site spread of the bare literals made a rename a silent cross-device data bug
# (scripts/cloud/cloud_sync.gd keys off the same strings). These are ON-DISK key
# STRINGS: changing either VALUE breaks every existing profile, so they are frozen
# unless a SCHEMA_VERSION bump plus a _migrate_step comes with the change.
const KEY_CARS := "cars"
const KEY_RALLIES := "rallies"

# Consumables that no longer exist, erased from `inventory` on load (see _sanitise).
# A LIST rather than a branch per id, because retiring a consumable is a recurring event
# and three copies of the same two lines is how one of them ends up forgotten:
#   repair_kit          — repair kits are gone; between-event field repair is free.
#   mystery_box         — parts are bought with stars at any time, so a random box that
#                         opens onto a part had nothing left to offer.
#   engine_swap_token   — engine swapping is unlimited once its rally unlocks it, so
#                         there is no per-swap cost left to hold.
# The ids are LITERALS, deliberately: the catalogue entries they name have been deleted,
# so there is no constant left to reference, and an old profile still spells them this way.
const RETIRED_ITEM_IDS := ["repair_kit", "mystery_box", "engine_swap_token"]
# Upgrade ids granted DIRECTLY, bypassing their unlocked_by_rally gate. Written only by
# migration, when a part's unlock rally MOVES: a player who won the part where it used
# to live must not lose it because the catalogue re-sited it. See features/snow-region.md
# and UpgradeLibrary.rally_gate_met.
const KEY_LEGACY_PART_UNLOCKS := "legacy_part_unlocks"
# The engine-swap CAPABILITY granted directly, bypassing its unlock rally. Written only by
# the 5 -> 6 migration, when that unlock moved off The Foothills Trial (which now awards
# Snow Tires) onto the Proving Ground. Same rule as the part key above: a player who already
# won the capability where it used to live must not lose it. Read by
# RallyLibrary.engine_swaps_unlocked.
const KEY_LEGACY_ENGINE_SWAP := "legacy_engine_swap"

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

# --- Undeclared-persisted-key tripwire (runtime half of the _default_profile() rule) ------
#
# Every top-level profile key must be declared in _default_profile(), because _migrate()
# backfills existing profiles from that dict ALONE — an undeclared key is therefore absent
# from every fresh and every migrated profile until something happens to write it, and a
# `.get(key, 0)` reader hides that completely.
#
# `test_every_persisted_key_written_is_declared_in_the_default_profile` catches this in CI,
# but a small model (or anyone) adding a counter does not run the suite; this makes the same
# mistake announce itself the first time the new code path saves, in the editor, with no test
# run. Two independent probes of this codebase made exactly this mistake, so the static check
# alone has been shown not to be enough.
#
# WHY "known" is declared-keys UNION keys-as-loaded, rather than declared keys alone: an old
# profile on disk can legitimately carry a top-level key that has since been retired (load
# backfills missing keys but never prunes extra ones), and shouting about those would be a
# false alarm on a real player's save. Anything appearing in `profile` that was neither
# declared NOR present in the file is, by elimination, a key CODE wrote this session.
var _known_profile_keys: Dictionary = {}
var _reported_undeclared_keys: Dictionary = {}


# Snapshot what counts as an already-known key. Call after every `profile = ...` assignment.
func _note_known_profile_keys() -> void:
	_known_profile_keys = {}
	for k in profile:
		_known_profile_keys[k] = true
	for k in _default_profile():
		_known_profile_keys[k] = true


# The top-level keys code has written this session that _default_profile() does not declare.
# Pure and side-effect free, so a test can exercise the detection without provoking an error.
func _undeclared_profile_keys() -> Array[String]:
	var out: Array[String] = []
	if _known_profile_keys.is_empty():
		return out  # no snapshot yet (profile not adopted); nothing to compare against
	for k in profile:
		if not _known_profile_keys.has(k):
			out.append(String(k))
	return out


# Announce a top-level key that code wrote without declaring it in _default_profile().
# Once per key per session — save() runs on a debounce and this must not become a spam loop.
func _warn_undeclared_profile_keys() -> void:
	for k in _undeclared_profile_keys():
		if _reported_undeclared_keys.has(k):
			continue
		_reported_undeclared_keys[k] = true
		push_error(("Save: profile key '%s' is written but not declared in " % k)
			+ "_default_profile(). _migrate() backfills existing profiles from that dict "
			+ "alone, so this key is missing from every fresh and every migrated profile "
			+ "until this write happens — and a `.get(key, default)` reader hides it. "
			+ "Add it to _default_profile() with its default value (see the `stars_earned` "
			+ "/ `cloud_revision` entries for the shape); no SCHEMA_VERSION bump is needed, "
			+ "the key backfill handles it.")


# TEST-RUN SANDBOX. Empty in every real build — the ONLY writer is the headless
# suite's GUT pre-run hook (tests/headless/save_sandbox_pre_hook.gd). While it holds
# a path, profile_path's setter below remaps any attempt to use
# DEFAULT_PROFILE_PATH onto it, so a test that forgets to redirect (or "restores"
# the real path in its teardown) can never write the player's own profile.json.
#
# This exists because a headless run DID overwrite a developer's real profile with a
# blank default carrying fixture cars. Per-test redirects were the only defence and
# any one file forgetting was enough to lose a career.
var test_sandbox_path := ""

# Where the active profile is read from / written to. Tests override this before
# calling load_or_new().
var profile_path: String = DEFAULT_PROFILE_PATH:
	set(value):
		# Assigning the backing variable inside its own setter does NOT re-enter it.
		if value == DEFAULT_PROFILE_PATH and not test_sandbox_path.is_empty():
			profile_path = test_sandbox_path
		else:
			profile_path = value

# True when a degraded environment (blocked storage / read-only fs) forces an
# in-memory-only profile — the UI surfaces a "progress won't be saved" notice.
var save_disabled := false

var _debounce: Timer

# Kept alive for the lifetime of the autoload: JavaScriptBridge callbacks are
# only valid while the JavaScriptObject wrapper is referenced from GDScript, so
# dropping this would silently detach the browser lifecycle listeners.
var _web_lifecycle_cb: JavaScriptObject = null


func _ready() -> void:
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = SAVE_DEBOUNCE_SEC
	_debounce.timeout.connect(save_now)
	add_child(_debounce)
	load_or_new()
	install_web_lifecycle()


# Persist on the way out, including when a mobile/web tab is backgrounded — on
# the HTML5 export user:// is IndexedDB, which may not flush before the tab
# closes, so we force a synchronous write on these notifications.
#
# NOTE these are DESKTOP/native signals: browsers never send
# NOTIFICATION_WM_CLOSE_REQUEST, so the web build reaches the same flush entry
# point (flush_and_sync) through the browser lifecycle listeners installed by
# install_web_lifecycle() instead.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		flush_and_sync()


# --- Web lifecycle -----------------------------------------------------------
# On the HTML5 export user:// is IndexedDB (Emscripten IDBFS): FileAccess writes
# land in an in-memory FS that is flushed to IndexedDB ASYNCHRONOUSLY. Two things
# have to happen before the page goes away:
#   1. the debounced write must actually run (flush), and
#   2. the resulting FS state must be pushed to IndexedDB (sync).
# The only page-teardown signals mobile browsers fire reliably are
# `visibilitychange`→hidden and `pagehide`, so we hook both. The export is
# SINGLE-THREADED (`variant/thread_support=false` in export_presets.cfg), so the
# write itself is cheap and synchronous on the main thread — the risk being
# mitigated here is the async IDB sync not landing, not write cost.

# The single flush entry point used by BOTH the desktop close notification and
# the web lifecycle listeners: write immediately, then ask the browser FS to push
# the result to IndexedDB (a no-op off the web build).
func flush_and_sync() -> void:
	save_now()
	request_web_sync()
	# Give the optional cloud layer its chance to upload too. It is fire-and-
	# forget: a browser tab can die before an HTTP request completes, which is
	# why the local file — already written above — stays the source of truth.
	flushed.emit()


# Register the browser lifecycle listeners. Returns true if they were installed
# (web only); a harmless no-op everywhere else, so it can be called
# unconditionally. Idempotent — a second call does nothing.
func install_web_lifecycle() -> bool:
	if not Platform.is_web():
		return false
	if _web_lifecycle_cb != null:
		return true
	_web_lifecycle_cb = JavaScriptBridge.create_callback(_on_web_lifecycle)
	var window := JavaScriptBridge.get_interface("window")
	if window == null:
		_web_lifecycle_cb = null
		return false
	# Stash the callback on window so plain JS can wire it to the events. Both
	# listeners are registered: visibilitychange→hidden is the reliable mobile
	# "page is going away" signal, pagehide covers navigation/tab close.
	window.rallySaveFlush = _web_lifecycle_cb
	JavaScriptBridge.eval("""
		document.addEventListener('visibilitychange', function () {
			if (document.visibilityState === 'hidden' && window.rallySaveFlush) {
				window.rallySaveFlush();
			}
		});
		window.addEventListener('pagehide', function () {
			if (window.rallySaveFlush) { window.rallySaveFlush(); }
		});
	""", true)
	return true


# Invoked from JS when the page is hidden / unloading.
func _on_web_lifecycle(_args: Array) -> void:
	flush_and_sync()


# Ask the Emscripten filesystem to push its in-memory state to IndexedDB. Godot
# schedules its own sync after writes, but it is async and may not land before a
# tab close, so we request one explicitly at the lifecycle boundary. Defensive by
# design: FS is not guaranteed to be exposed on the JS globals, and a failure
# here must never take the game down — worst case we fall back to the engine's
# own sync. No-op off the web build.
func request_web_sync() -> void:
	if not Platform.is_web():
		return
	JavaScriptBridge.eval("""
		(function () {
			try {
				var fs = window.FS || (window.Module && window.Module.FS);
				if (fs && fs.syncfs) { fs.syncfs(false, function () {}); }
			} catch (e) { console.warn('[rally] IDB sync failed', e); }
		})();
	""", true)


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
		_note_known_profile_keys()
		return
	var migrated := _migrate(loaded)
	if migrated.is_empty():
		# A newer-than-known or unmigratable file: keep it untouched on disk and
		# run on a fresh in-memory profile rather than clobbering it.
		push_warning("Save: profile at %s is unreadable/newer than v%d — starting fresh, file kept"
			% [profile_path, SCHEMA_VERSION])
		profile = _default_profile()
		_note_known_profile_keys()
		save_disabled = true
		return
	profile = _sanitise(migrated)
	_note_known_profile_keys()
	# Backfill the new-rally reveal's `revealed` flags on a profile that predates the
	# feature (see _seed_reveals_if_needed). Runs HERE — the moment a profile becomes
	# live — rather than being left to whoever happens to reach the map/HQ, so a future
	# entry point can never forget to seat it.
	_seed_reveals_if_needed()


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


# Drop entries that no longer resolve against the current catalogues (a car removed
# from CarLibrary, a part removed from UpgradeLibrary) so old saves stay loadable as
# the content evolves.
func _sanitise(p: Dictionary) -> Dictionary:
	var kept: Array = []
	for car in p.get(KEY_CARS, []):
		if CarLibrary.index_of(car.get("model_id", "")) >= 0:
			# Backfill per-wheel damage misalignment on saves that predate it (straight).
			if not car.has("wheel_toe"):
				car["wheel_toe"] = [0.0, 0.0, 0.0, 0.0]
			_prune_unknown_upgrades(car)
			_revive_orphaned_nitrous(car)
			_grandfather_drive_mode(car)
			kept.append(car)
		else:
			push_warning("Save: dropping owned car with unknown model_id '%s'" % car.get("model_id", ""))
	p[KEY_CARS] = kept
	# Drop RETIRED consumables from older profiles. Done HERE, in the tolerant sanitise
	# pass, rather than as a schema migration: the key is inert once nothing reads it, and
	# a SCHEMA_VERSION bump would make every older build refuse the profile outright — too
	# high a price for cleaning up a dead key, especially with cloud save moving profiles
	# between devices on different builds.
	var inv: Dictionary = p.get("inventory", {})
	for dead_id in RETIRED_ITEM_IDS:
		if inv.has(dead_id):
			inv.erase(dead_id)
			p["inventory"] = inv
	return p


# Drop fitted / toggled-off part ids that no longer exist in UpgradeLibrary (a part
# retired from the catalogue). An unknown id is already inert everywhere — by_id
# returns {} so it has no effect and no slot — but leaving it on the car would let it
# occupy a phantom slot in the upgrades menu, so clear it out on load.
func _prune_unknown_upgrades(car: Dictionary) -> void:
	for key in ["installed_upgrades", "disabled_upgrades"]:
		var kept: Array = []
		for item_id in car.get(key, []):
			if UpgradeLibrary.index_of(String(item_id)) >= 0:
				kept.append(item_id)
			else:
				push_warning("Save: dropping unknown upgrade '%s'" % item_id)
		car[key] = kept


# Backfill the paid-for drive-mode list, and GRANDFATHER whatever a car is already
# converted to.
#
# Drivetrain conversion used to be a per-car PART: winning the special fitted the kit to one
# car, and that car could then switch layout freely. It is now a global unlock with a
# per-mode star price (features/upgrade-catalogue.md). A car carrying an override from the
# old rules has therefore already "bought" that mode as far as the player is concerned, and
# silently reverting it to stock on load — which is what resolve_drive_override would do
# with an empty list — would take away a conversion they earned.
#
# Done in the tolerant sanitise pass rather than as a schema migration, for the same reason
# the retired-consumable cleanup is: a SCHEMA_VERSION bump makes every older build refuse
# the profile, which is far too high a price with cloud save moving profiles between builds.
func _grandfather_drive_mode(car: Dictionary) -> void:
	if not car.has("drivetrain_modes_bought"):
		car["drivetrain_modes_bought"] = []
	var override := int(car.get("drivetrain_override", -1))
	if override >= 0 and not (car["drivetrain_modes_bought"] as Array).has(override):
		(car["drivetrain_modes_bought"] as Array).append(override)


# Re-enable a nitrous part that the NOS ladder's retirement left parked.
#
# NOS used to be four chained rungs sharing one slot, and only the HIGHEST was ever enabled
# — the lower ones sat in `disabled_upgrades` (one enabled part per slot,
# _enable_exclusive). Collapsing the ladder to a single part deletes those higher rungs, so
# _prune_unknown_upgrades above drops them and leaves the survivor — plain `nitrous` —
# disabled. A player past stage 1 would load in with NOS owned, fitted and switched OFF,
# with no clue it happened.
#
# Only ever re-enables: it never installs a part the car did not have, and it does nothing
# to a car that has nitrous enabled already or has none at all. So it is safe to run on
# every load, which is why it lives here rather than behind a SCHEMA_VERSION bump — the
# rung ids are gone from the catalogue, so there is no version to key off.
func _revive_orphaned_nitrous(car: Dictionary) -> void:
	var disabled: Array = car.get("disabled_upgrades", [])
	var installed: Array = car.get("installed_upgrades", [])
	for item_id in disabled.duplicate():
		if UpgradeLibrary.slot_of(String(item_id)) != "nitrous":
			continue
		# Another nitrous part is already live — leave the player's own choice alone.
		if _has_enabled_in_slot(car, "nitrous"):
			return
		disabled.erase(item_id)
		if not installed.has(item_id):
			installed.append(item_id)
	car["disabled_upgrades"] = disabled
	car["installed_upgrades"] = installed


# Is any installed-and-enabled part occupying `slot` on this car?
func _has_enabled_in_slot(car: Dictionary, slot: String) -> bool:
	for item_id in car.get("installed_upgrades", []):
		if UpgradeLibrary.slot_of(String(item_id)) == slot \
				and not (car.get("disabled_upgrades", []) as Array).has(item_id):
			return true
	return false


func has_save() -> bool:
	return FileAccess.file_exists(profile_path)


# --- Save --------------------------------------------------------------------

# Mark the profile dirty and (re)arm the debounce timer. Call this from mutators
# / call sites after a change; the actual disk write happens once the burst
# settles. No-op when storage is disabled.
func save() -> void:
	# Mark unsynced + notify BEFORE the save_disabled bail-out: blocked local
	# storage (private browsing, read-only fs) is exactly the situation where a
	# cloud copy is most valuable, so it must not also switch off cloud sync.
	profile["updated_utc"] = Time.get_datetime_string_from_system(true)
	profile["unsynced"] = true
	_warn_undeclared_profile_keys()
	profile_changed.emit()
	if save_disabled:
		return
	_debounce.start()


# Force an immediate atomic write (bypassing the debounce). Writes to a .tmp
# then renames over the real file so a crash mid-write can't corrupt the only
# profile, and keeps the prior file as .bak for one generation.
func save_now() -> void:
	if save_disabled:
		return
	# HEADLESS BACKSTOP. A test run must never write the developer's real profile — that once
	# wiped a real career, which is why the run-scoped sandbox (save_sandbox_pre_hook.gd) exists.
	# The sandbox remaps DEFAULT_PROFILE_PATH, but a test that legitimately CLEARS
	# `test_sandbox_path` (test_save_sandbox.gd has to, to prove the setter is the identity
	# without one) reopens the window, and anything writing inside it lands on the real file.
	#
	# The post-run guard catches that, but only at the END of the run and only by mtime — it says
	# a write happened, never who. So refuse the write here and name the caller: a stack trace
	# points straight at the offender instead of costing a bisect across ~195 test files.
	#
	# Refusing rather than redirecting is deliberate. A silent redirect would let the offending
	# test keep passing while the seam it depends on quietly stopped meaning anything.
	if Platform.is_headless() and profile_path == DEFAULT_PROFILE_PATH:
		var msg := ("PROFILE SANDBOX VIOLATION (refused): a headless run tried to write the real "
			+ "profile at %s. Redirect it (tests/headless/save_test_helpers.gd) or restore "
			+ "Save.test_sandbox_path. Stack:\n%s")
		push_error(msg % [DEFAULT_PROFILE_PATH, _caller_trace()])
		refused_real_writes += 1
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


## How many times the refusal above fired this process. Read by the post-run hook to tell an
## ACTUAL test violation apart from an mtime change caused by something outside the run — see
## that hook for why the distinction matters. Static so it survives whatever frees the autoload.
static var refused_real_writes := 0


# A readable GDScript stack for the refusal above. Debug-only in the engine, which is exactly
# where a test run lives; returns a placeholder in a release build so the message still reads.
func _caller_trace() -> String:
	var lines := PackedStringArray()
	for frame in get_stack():
		lines.append("    %s:%s in %s" % [frame.get("source", "?"), frame.get("line", 0),
			frame.get("function", "?")])
	return "\n".join(lines) if not lines.is_empty() else "    (no stack available)"


# Overwrite the current profile with a fresh one (after a ConfirmModal in the
# menus). Writes immediately so "New game" is durable at once.
func reset_new_game() -> void:
	profile = _default_profile()
	_note_known_profile_keys()
	save_disabled = false
	save_now()


# --- Cloud-save support ------------------------------------------------------
# These exist for the optional `Cloud` autoload. They live here, rather than in
# the cloud layer, so that the ONE profile-validation path (migrate + sanitise)
# is shared: a downloaded profile is checked exactly as strictly as a file on
# disk, and there is no second implementation to drift out of step with the
# schema.

# Does this device hold changes the cloud has not accepted yet?
func has_unsynced() -> bool:
	return bool(profile.get("unsynced", false))


# Record that the current profile state has been accepted by the cloud. Writes
# immediately (not via save(), which would just mark it unsynced again).
func mark_synced() -> void:
	profile["unsynced"] = false
	save_now()


# Replace the in-memory profile with one received from the cloud, running it
# through the SAME migrate + sanitise pipeline as a local file. Returns false —
# leaving the current profile untouched — when the incoming profile is newer
# than this build understands, which is the one case where overwriting would
# lose data we cannot even read.
func adopt_profile(incoming: Dictionary) -> bool:
	var migrated := _migrate(incoming.duplicate(true))
	if migrated.is_empty():
		return false
	# Settings stay DEVICE-LOCAL and survive the swap. They describe the hardware
	# in the player's hands — touch control scheme, frame cap, key bindings — not
	# their career, so letting a phone's settings ride down onto a desktop (or the
	# reverse) would be a downgrade, not a restore.
	var device_settings: Variant = profile.get("settings", {})
	profile = _sanitise(migrated)
	_note_known_profile_keys()
	profile["settings"] = device_settings
	# A restored career lands with no reveal flags on it, so without this the next map
	# open would parade the whole roster at somebody who has already played it (see
	# _seed_reveals_if_needed). Idempotent: a career that already carries flags is left
	# alone (needs_reveal_seeding() is false).
	_seed_reveals_if_needed()
	return true


# Snapshot the profile before a cloud copy replaces it, so "Use cloud" chosen by
# mistake is recoverable. Deliberately a SEPARATE filename from the rolling .bak
# (which the next ordinary write would consume within seconds).
func write_conflict_backup() -> void:
	var f := FileAccess.open(profile_path + ".conflict.bak", FileAccess.WRITE)
	if f == null:
		push_warning("Save: could not write a conflict backup before replacing the profile")
		return
	f.store_string(JSON.stringify(profile, "\t"))
	f.close()


func _default_profile() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"created_utc": "",
		"updated_utc": "",
		"starter_picked": false,
		"starter_model_id": "",
		"next_instance_id": 1,
		KEY_CARS: [],
		"selected_instance_id": -1,
		"inventory": {},
		KEY_RALLIES: {},
		# Empty for every new career: nothing has been re-sited under this player, so
		# every part is gated purely by the CURRENT unlocked_by_rally mapping.
		KEY_LEGACY_PART_UNLOCKS: [],
		KEY_LEGACY_ENGINE_SWAP: false,
		# Adaptive difficulty (features/adaptive-difficulty.md). Zero is "field matched to
		# the player", i.e. the behaviour before the system existed.
		AiDifficulty.KEY_STEPS: 0,
		AiDifficulty.KEY_WIN_STREAK: 0,
		AiDifficulty.KEY_LOSS_STREAK: 0,
		"reward_history": [],
		"settings": {},
		# --- Star ledger (see todo/star-economy.md) ---
		# Stars are a PERSISTED LEDGER, not a derived total. `stars_earned` only ever
		# grows — record_podium_rally credits what THIS finish's placement is worth, so a rally
		# can be re-driven for stars (the old "delta over the previous best" anti-grind
		# rule was deliberately removed) — and `stars_spent` grows as cars are bought.
		# The spendable figure is stars_available().
		#
		# Persisted rather than derived (the old RallyLibrary.total_stars summed
		# best_placed over RALLIES) for two reasons: challenge stars are unrecoverable
		# from `challenge_results`, which stores no rank and is pruned to live periods;
		# and a derived total SHRINKS when a rally is renamed or removed, which could
		# drop it below stars_spent and produce a negative balance.
		#
		# Backfilled by _migrate's key backfill like cloud_revision/username above, so
		# no SCHEMA_VERSION bump. Existing profiles therefore start at 0 rather than
		# being seeded from their old derived total — deliberate, since those profiles
		# already hold cars granted free under the old reward rules.
		"stars_earned": 0,
		"stars_spent": 0,
		# --- Optional cloud save (see features/cloud-save.md) ---
		# The Firestore document revision this profile last agreed with. 0 means
		# "never synced". Both fields are backfilled by _migrate's key backfill,
		# so no SCHEMA_VERSION bump was needed.
		"cloud_revision": 0,
		# Which account this profile's cloud_revision refers to. A revision number
		# is only meaningful relative to ONE Firestore document, so signing into a
		# different account must not compare against the previous account's count.
		"cloud_uid": "",
		# Does this device hold changes the cloud has not accepted? PERSISTED on
		# purpose: progress made offline must still be recognised as unsynced
		# after a restart, otherwise the next pull would see "cloud is ahead,
		# local is clean" and quietly discard a whole offline session.
		"unsynced": false,
		# Display name posted with a global stage-leaderboard entry (see
		# features/global-leaderboards.md). "" until the player names themselves on
		# first post. Backfilled by _migrate's key backfill like cloud_revision/
		# unsynced above, so no SCHEMA_VERSION bump — and it rides the existing
		# cloud-save sync to the player's other devices for free.
		"username": "",
		# The in-progress Daily/Weekly/Monthly challenge run, if any (see
		# features/rally-challenge.md). {} means no run active. When non-empty:
		# {period_key, kind, car_instance_id, stage_index, stage_times_ms: [...],
		# dnf: bool}. Backfilled by _migrate's key backfill like cloud_revision/
		# unsynced/username above, so no SCHEMA_VERSION bump.
		"challenge_run": {},
		# Terminal outcomes per challenge period, keyed by period_key:
		# {kind, dnf: bool, cumulative_ms: int}. A period present here is FINISHED —
		# completed or DNF'd — and cannot be started again for the rest of that
		# period (a challenge is one attempt; abandoning ends the run with no retry).
		# Separate from challenge_run rather than folded into it because
		# ChallengeSession.resumable_run keys on challenge_run being non-empty, so a
		# terminal record stored there would make the game try to RESUME a finished
		# run. Pruned to live periods on every write, so it can't grow without bound.
		# Backfilled by _migrate's key backfill, so no SCHEMA_VERSION bump.
		"challenge_results": {},
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
		if not _MIGRATABLE_FROM.has(v):
			return {}  # gap in the migration chain: refuse rather than guess
		p = _migrate_step(v, p)
		v = int(p.get("schema_version", v + 1))
	# Backfill any keys a (correctly-versioned but partial) file is missing.
	var base := _default_profile()
	for k in base:
		if not p.has(k):
			p[k] = base[k]
	return p

# Versions we know how to step FROM (each _migrate_step(v, p) bumps schema_version
# to v+1). Kept as a plain const list (a const dict of Callables isn't a constant
# expression in GDScript, and would null this autoload at parse time).
const _MIGRATABLE_FROM := [1, 2, 3, 4, 5]

# The rally that used to unlock engine swapping before it moved to
# RallyLibrary.ENGINE_SWAP_UNLOCK_RALLY. Read ONLY by the 5 -> 6 migration.
const OLD_ENGINE_SWAP_UNLOCK_RALLY := "sp_woodland_trial"

# Parts whose unlocked_by_rally moved, as [old_rally_id, upgrade_id]. Read ONLY by the
# 4 -> 5 migration. Kept as data next to that step so a future move adds a row and an
# arm rather than another bespoke block.
const MOVED_PART_UNLOCKS := [
	["gr_showdown", "race_tires"],
	["hc_showdown", "sequential_gearbox"],
]

# Apply the single version N -> N+1 transform.
#   1 -> 2: upgrades became CAR-BOUND. The old shared `inventory` pool of
#           slottable parts is gone (parts now live on the OwnedCar they were won
#           for), so strip EVERY entry from `inventory` — those unbound parts were
#           never applied and have no car to belong to, and the repair kit that used
#           to be kept here no longer exists as an item at all.
#   3 -> 4: adaptive difficulty gained its offset + streak counters (all zero, which is
#           the pre-adaptive "matched field" behaviour).
#   4 -> 5: two part unlocks MOVED to the new Alps rallies (Race Tires gr_showdown ->
#           sn_showdown, Sequential Gearbox hc_showdown -> sp_summit_trial). A player who
#           already won the old rally keeps the part, via KEY_LEGACY_PART_UNLOCKS.
#   5 -> 6: the ENGINE SWAP unlock moved (sp_woodland_trial -> front_runners) so the old
#           rally could carry Snow Tires instead. A player who already won it keeps the
#           capability, via KEY_LEGACY_ENGINE_SWAP.
#   2 -> 3: rally entry stopped gating on power-to-weight, so a saved
#           `tuning.engine_detune` set purely to duck under a rally ceiling now has
#           nothing to duck under — and the detune slider that set it is gone with the
#           ceiling. Left alone, that car would be permanently and INVISIBLY down on
#           power with no player-reachable way to restore it. Reset every car to full
#           power. This is one-way and deliberate: the handful of players who detuned
#           for feel lose that setting, which is a far smaller harm than a silently
#           crippled car nobody can diagnose.
func _migrate_step(from_version: int, p: Dictionary) -> Dictionary:
	match from_version:
		1:
			var inv: Dictionary = p.get("inventory", {})
			for item_id in inv.keys():
				inv.erase(item_id)
			p["inventory"] = inv
			p["schema_version"] = 2
		2:
			for car in p.get(KEY_CARS, []):
				var tuning: Dictionary = (car as Dictionary).get("tuning", {})
				if tuning.has("engine_detune"):
					tuning["engine_detune"] = 1.0
			p["schema_version"] = 3
		3:
			# Adaptive difficulty. All three start at zero, and zero means "field matched
			# to the player exactly", which IS the pre-adaptive behaviour — so a migrated
			# career resumes at parity and only diverges once it produces results.
			p[AiDifficulty.KEY_STEPS] = 0
			p[AiDifficulty.KEY_WIN_STREAK] = 0
			p[AiDifficulty.KEY_LOSS_STREAK] = 0
			p["schema_version"] = 4
		4:
			# Two parts were re-sited into the Alps to give that corner something worth
			# working toward. Grant them directly to anyone who already won them where
			# they used to be.
			#
			# Deliberately NOT done by marking the new rally completed: that would also
			# light its map-reveal circle and pay its placement stars, handing the player
			# progress and currency they never earned. The legacy set grants the PART and
			# nothing else.
			var legacy: Array = p.get(KEY_LEGACY_PART_UNLOCKS, [])
			var rallies: Dictionary = p.get(KEY_RALLIES, {})
			for moved in MOVED_PART_UNLOCKS:
				var old_rally: String = moved[0]
				var item_id: String = moved[1]
				if bool((rallies.get(old_rally, {}) as Dictionary).get("completed", false)) \
						and not legacy.has(item_id):
					legacy.append(item_id)
			p[KEY_LEGACY_PART_UNLOCKS] = legacy
			p["schema_version"] = 5
		5:
			# The engine-swap unlock moved off The Foothills Trial (now the Snow Tires
			# special) onto the Proving Ground beside HQ. Anyone who already won the old
			# rally keeps the capability outright — and, as with the 4 -> 5 part moves, this
			# grants the CAPABILITY only: marking the new rally completed would also light
			# its reveal circle and pay stars the player never earned.
			p[KEY_LEGACY_ENGINE_SWAP] = bool((p.get(KEY_RALLIES, {}) as Dictionary)
				.get(OLD_ENGINE_SWAP_UNLOCK_RALLY, {}).get("completed", false))
			p["schema_version"] = 6
	return p


# --- Owned-car mutators ------------------------------------------------------

# Grant a new owned-car instance referencing a CarLibrary model id. Returns the
# new OwnedCar dict.
# Does the garage already hold a car of this catalogue model? Used to keep a prize rally
# from minting a duplicate (rally_session), and deliberately model-keyed rather than
# instance-keyed: two of the same car is the thing worth preventing, not two instance ids.
#
# HEALTH IS IGNORED on purpose — a battered car is still a car the player owns, and under
# the current damage model any car can be repaired back to full.
func owns_model(model_id: String) -> bool:
	for car in profile.get(KEY_CARS, []):
		if String((car as Dictionary).get("model_id", "")) == model_id:
			return true
	return false


func grant_car(model_id: String) -> Dictionary:
	var entry := CarLibrary.by_id(model_id)
	var max_hp: float = entry.get("max_hp", 1000.0) if not entry.is_empty() else 1000.0
	var car := {
		"instance_id": int(profile["next_instance_id"]),
		"model_id": model_id,
		"hp": max_hp,
		"installed_upgrades": [],
		"disabled_upgrades": [],
		"tuning": {},
		"wheel_toe": [0.0, 0.0, 0.0, 0.0],
		"drivetrain_override": -1,
		# Drive modes this car has PAID for (ints, CarLibrary.RWD/AWD/FWD). Its authored
		# stock mode is never in here — reverting to stock is always free. See
		# buy_drive_mode and features/upgrade-catalogue.md.
		"drivetrain_modes_bought": [],
	}
	profile["next_instance_id"] = int(profile["next_instance_id"]) + 1
	profile[KEY_CARS].append(car)
	if not profile.get("reward_history", []).has(model_id):
		profile["reward_history"].append(model_id)
	save()
	return car


# The OwnedCar dict for an instance id, or {} if not owned.
#
# Reads `instance_id` with a DEFAULT rather than indexing it: a hand-rolled car dict that
# omits the key (test fixtures, a partially-migrated save) would otherwise crash the lookup
# rather than simply not matching. -1 can never be a real instance id (they count up from
# 1), so a keyless entry is skipped, which is the only sensible reading of it.
func get_car(instance_id: int) -> Dictionary:
	for car in profile[KEY_CARS]:
		if int((car as Dictionary).get("instance_id", -1)) == instance_id:
			return car
	return {}


# Apply impact damage. HP bottoms out at 0 and STAYS there — a car at 0 HP is still an
# ownable, drivable car, just a badly weakened one (features/damage.md). There is no
# write-off, no wreck record and no state a repair can't undo.
func apply_damage(instance_id: int, amount: float) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	car["hp"] = maxf(0.0, float(car["hp"]) - amount)
	save()


# Persist a car's per-wheel damage misalignment (radians, ordered like
# DamageModel.WHEEL_NAMES). Written at each event boundary alongside apply_damage so
# a car carries its bent wheels between events (features/damage.md).
func set_wheel_toe(instance_id: int, toe: Array) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	car["wheel_toe"] = toe.duplicate()
	save()


func set_tuning(instance_id: int, tuning: Dictionary) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	car["tuning"] = tuning.duplicate(true)
	save()


# Fit a COSMETIC wheel style — a donor car's stable CarLibrary id — to an owned car
# (features/wheel-customization.md). Free, ungated and reversible: no token, no
# consumable, no eligibility rules, and it changes NOTHING but the wheel texture.
# "Stock" is canonically represented as the key being ABSENT (an empty id, or the
# car's own model_id, erases it), which keeps the owned dict's hash — the key the HQ
# car-prop caches use — stable across a revert. No schema migration is needed: an
# absent per-car key already means stock, exactly as swapped_engine does.
func set_wheels(instance_id: int, wheel_id: String) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	if wheel_id.is_empty() or wheel_id == String(car.get("model_id", "")):
		car.erase("wheels")
	else:
		car["wheels"] = wheel_id
	save()


# Exchange the CURRENT engines of two owned cars (features/engine-swap.md).
#
# FREE AND UNLIMITED once the capability is unlocked by its special rally. Each swap used
# to spend an engine swap token, including reverting to stock — that consumable is gone,
# so the rally unlock is now the whole gate and a player can rearrange their garage as
# often as they like. Health is irrelevant and a damaged car keeps its HP.
#
# Each car's swapped_engine is set to the OTHER's current engine, then cleared to "" when
# the result equals that car's own stock engine (so "stock" is canonical and the name
# reverts). Returns false (no change) when the swap is not allowed or would be a no-op.
func swap_engines(id_a: int, id_b: int) -> bool:
	if id_a == id_b:
		return false
	var a := get_car(id_a)
	var b := get_car(id_b)
	if not EngineSwap.can_swap(a, b):
		return false
	var stock_a := String(CarLibrary.by_id(String(a["model_id"])).get("engine", ""))
	var stock_b := String(CarLibrary.by_id(String(b["model_id"])).get("engine", ""))
	var cur_a := EngineSwap.current_engine_id(a, stock_a)
	var cur_b := EngineSwap.current_engine_id(b, stock_b)
	if cur_a == cur_b:
		return false  # nothing to exchange
	_set_engine(a, stock_a, cur_b)
	_set_engine(b, stock_b, cur_a)
	save()
	return true


# --- Challenge run car lock ---------------------------------------------------
# Whether an active challenge run is COMMITTED to `instance_id`. The STORAGE-LEVEL
# predicate; UI asks it through DrivingContext.is_car_locked.
#
# Scope is deliberately narrow: a challenge locks the RUN to a car, it does NOT
# reserve the car. The car stays fully usable in career rallies, free roam, the
# garage, engine swaps and upgrades while the run is in progress. An earlier
# design did use this to exclude the car from the rally picker, the garage/lift
# picker and the engine-swap partner list; all were REMOVED — they made an owned
# car unusable across the whole game, which was never the intent. The free
# between-event field repair applying mid-run is an accepted consequence (a
# challenge is a time competition, not a survival one).
#
# It has never disabled the detune slider either — the challenge's performance ceiling
# is enforced by the close-button gate (UpgradesGrid.over_rating_limit).
# See features/rally-challenge.md → "Car lock".
func is_challenge_locked(instance_id: int) -> bool:
	var run: Dictionary = profile.get("challenge_run", {})
	return not run.is_empty() and int(run.get("car_instance_id", -1)) == instance_id


# Persist `run` as the in-progress challenge_run (ChallengeSession._persist /
# pause_run), replacing whatever was there. The one writer of this key's shape —
# ChallengeSession no longer reaches into profile["challenge_run"] directly.
func set_challenge_run(run: Dictionary) -> void:
	profile["challenge_run"] = run
	save()


# Clear the stored challenge_run (ChallengeSession.discard_stale_run /
# _clear_persisted on finish/DNF) — no run stored, nothing to resume.
func clear_challenge_run() -> void:
	profile["challenge_run"] = {}
	save()


# Replace the challenge_results map (ChallengeSession._record_outcome, already
# pruned to the live period keys by the caller).
func set_challenge_results(results: Dictionary) -> void:
	profile["challenge_results"] = results
	save()


# Set a car's engine to engine_id, clearing the swap field when it matches stock.
func _set_engine(car: Dictionary, stock_id: String, engine_id: String) -> void:
	if engine_id == stock_id or engine_id.is_empty():
		car.erase("swapped_engine")
	else:
		car["swapped_engine"] = engine_id


# Set a car's engine detune (0..1 torque scale) — a tuning-lift value stored in the
# per-car tuning bag. Clamped to [0,1]. 1.0 = full power (the default everywhere).
func set_engine_detune(instance_id: int, frac: float) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	var tuning: Dictionary = car.get("tuning", {})
	tuning["engine_detune"] = clampf(frac, 0.0, 1.0)
	car["tuning"] = tuning
	save()


# Set a car's chosen drivetrain (0/1/2), or -1 to revert to the car's stock layout.
# Stored per car; inert unless the drivetrain-swap kit is fitted+enabled (the gate lives
# in UpgradeLibrary.resolve_drive_override, read by car.gd and effective_meta).
func set_drivetrain_override(instance_id: int, mode: int) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	car["drivetrain_override"] = mode
	save()


# --- Selected car ------------------------------------------------------------
# The player always has one owned car "selected" — the one raised on the garage
# tuning lift (todo/menus.md). It's the default car the lift tunes/upgrades, and
# (unless a rally car-select overrides it) the one fielded. Stored as an instance
# id, resolved lazily so it always points at a still-owned car.

# The selected OwnedCar, or {} if the player owns nothing. Falls back to (and
# records) the first owned car when the stored id is unset or no longer owned —
# so the selection self-heals if the stored instance is no longer in the garage.
func selected_car() -> Dictionary:
	var cars: Array = profile.get(KEY_CARS, [])
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
	# Promote the selected car to the front of the lineup so the most recently
	# selected car appears first — persisted via the cars array, so it survives
	# a relaunch. Car park lineups iterate profile["cars"], so reordering here is
	# all it takes. No-op for unowned/-1 ids (e.g. starter previews).
	var cars: Array = profile.get(KEY_CARS, [])
	for i in cars.size():
		if int(cars[i].get("instance_id", -1)) == instance_id:
			if i > 0:
				var car: Dictionary = cars[i]
				cars.remove_at(i)
				cars.insert(0, car)
			break
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
func consume_item(item_id: String, n := 1, do_save := true) -> bool:
	var inv: Dictionary = profile["inventory"]
	var have := int(inv.get(item_id, 0))
	if have < n:
		return false
	if have == n:
		inv.erase(item_id)
	else:
		inv[item_id] = have - n
	if do_save:
		save()
	return true


# Fit a won part to a car. Upgrades are CAR-BOUND: a part belongs to the car it
# was won for (rally_session installs it on the driven car) and never moves to
# another car or into a shared pool — so this takes no inventory, it just records
# the fit on the OwnedCar. It STAYS ON THE CAR permanently and can be
# enabled/disabled from the upgrades menu (set_upgrade_enabled). A car holds any
# number of fitted parts but at most one ENABLED per slot. `enabled` controls the
# freshly-fitted state: true -> enabled, switching off any same-slot incumbent
# (used for a direct fit); false -> parked disabled (the reward loop fits every
# won part disabled, then the podium's Apply enables the player's pick). Fitting
# the same part to the same car twice is rejected (per-car dedup). Consumables
# and unknown ids can't be slotted — use add_item() for those. Returns true on success.
func install_upgrade(instance_id: int, item_id: String, enabled := true) -> bool:
	var car := get_car(instance_id)
	if car.is_empty():
		return false
	var slot := UpgradeLibrary.slot_of(item_id)
	if slot.is_empty() or UpgradeLibrary.is_consumable(item_id):
		return false  # not a slottable upgrade
	if (car["installed_upgrades"] as Array).has(item_id):
		return false  # already fitted to this car (per-car dedup)
	car["installed_upgrades"].append(item_id)
	# A part in a HIDDEN slot is always fitted enabled, whatever the caller asked for: it has
	# no garage row, so installing it disabled would leave it permanently dead AND block the
	# slot from ever being re-awarded (the dedup above). Enforced here so it holds for every
	# route a part arrives by — winning it at its prize rally, or buying a copy with stars.
	if enabled or UpgradeLibrary.installs_enabled(item_id):
		_enable_exclusive(car, item_id, slot)
	else:
		_disable(car, item_id)
	save()
	return true


# Toggle an applied upgrade on/off (the upgrades-menu switch). Enabling a part
# disables any same-slot enabled sibling (one enabled per slot); disabling just
# parks it — the part stays fitted either way. Returns false for a car/part that
# isn't there.
func set_upgrade_enabled(instance_id: int, item_id: String, enabled: bool) -> bool:
	var car := get_car(instance_id)
	if car.is_empty() or not (car.get("installed_upgrades", []) as Array).has(item_id):
		return false
	if enabled:
		_enable_exclusive(car, item_id, UpgradeLibrary.slot_of(item_id))
	else:
		_disable(car, item_id)
	save()
	return true


# Mark `item_id` enabled on `car` and every other applied part in `slot` disabled.
func _enable_exclusive(car: Dictionary, item_id: String, slot: String) -> void:
	var disabled: Array = car.get("disabled_upgrades", [])
	for existing in car.get("installed_upgrades", []):
		if existing != item_id and UpgradeLibrary.slot_of(existing) == slot and not disabled.has(existing):
			disabled.append(existing)
	disabled.erase(item_id)
	car["disabled_upgrades"] = disabled


# Park `item_id` in the car's disabled list (the part stays fitted, just off).
func _disable(car: Dictionary, item_id: String) -> void:
	var disabled: Array = car.get("disabled_upgrades", [])
	if not disabled.has(item_id):
		disabled.append(item_id)
	car["disabled_upgrades"] = disabled


# In-run HP is one-way: nothing here restores it mid-run. It climbs back only between
# runs — the free between-event patch-up below, and the paid repair at the lift
# (features/star-economy.md). See features/damage.md.


# A partial, between-event pit repair (RallySession._enter_event): restore
# `hp_fraction` of the HP LOST so far and bend each wheel `toe_fraction` back toward
# straight. This is the ONLY way HP ever climbs back, and it is free and
# incremental — the engineers patch the car up a bit before each event after the
# first. Returns a summary the repair popup renders:
#   {repaired:bool, hp_before, hp_after, max_hp, hp_gained}
# `repaired` is false (and nothing is written) when the car is already pristine
# (full HP and straight wheels) so a spotless car shows no popup.
func field_repair(instance_id: int, hp_fraction: float, toe_fraction: float) -> Dictionary:
	var none := {"repaired": false}
	var car := get_car(instance_id)
	if car.is_empty():
		return none
	var entry := CarLibrary.by_id(car["model_id"])
	var hp_before := float(car["hp"])
	var max_hp: float = entry.get("max_hp", hp_before) if not entry.is_empty() else hp_before
	var lost := maxf(0.0, max_hp - hp_before)
	var hp_after := minf(max_hp, hp_before + lost * hp_fraction)
	var toe: Array = car.get("wheel_toe", [0.0, 0.0, 0.0, 0.0])
	var new_toe: Array = []
	var toe_changed := false
	for v in toe:
		var straightened := float(v) * (1.0 - toe_fraction)
		if not is_equal_approx(straightened, float(v)):
			toe_changed = true
		new_toe.append(straightened)
	if hp_after <= hp_before and not toe_changed:
		return none
	car["hp"] = hp_after
	car["wheel_toe"] = new_toe
	save()
	return {
		"repaired": true,
		"hp_before": hp_before,
		"hp_after": hp_after,
		"max_hp": max_hp,
		"hp_gained": hp_after - hp_before,
	}


# --- Rally completion --------------------------------------------------------

# Record a top-3 rally finish. Idempotent for the `completed` flag; updates the
# best combined time when a faster one comes in. The CAR reward is NOT granted
# here (re-wins are farmable — see reward-system.md); this only records progress.
#
# RETURNS the stars this finish added to the ledger, which is simply what THIS finish's
# placement is worth: rallies are RE-WINNABLE for stars, so replaying one pays again every
# time. It used to credit only the delta over the rally's previous best, so a replay at an
# equal or worse placement paid nothing — a deliberate anti-grind guard, now deliberately
# removed. Consequence to keep in mind when tuning prices: stars are farmable by replaying
# any rally the player finds easy, so the ceiling on income is the player's patience, and
# repair/part costs are the only thing holding the economy up. See todo/star-economy.md.
#
# `best_placed` is still tracked (it drives the map's star rating) — it just no longer gates
# what gets paid.
# NAMED FOR ITS GATE, AND THE NAME IS THE WARNING. Was `complete_rally()` until round 016,
# which is a name that lied: this function has exactly ONE caller — `rally_session.gd`, inside
# `_award_podium_rewards`, which runs only `if podium_or_opening` — so it does not run when the
# player merely FINISHES. It runs on a podium, or on the opening rally's first attempt.
#
# THEREFORE: ANYTHING YOU INCREMENT OR WRITE IN HERE IS PODIUM-GATED, including a brand-new
# profile key of your own. A "rallies finished" counter incremented in this function counts
# PODIUMS and will read as a wrong number to the player, however honestly you named the key.
# For a reward or a counter that should fire on ANY finish, the seam is
# `rally_session.gd::_award_any_finish_bonus_stars` (stars) or the `var finished := not _dnf`
# gate beside it (everything else) — a different file, deliberately, because the gate lives at
# the call site.
#
# Written HERE, at the site where the mistake is made, rather than only on the reading side
# (`podium_count`, `rally_podiumed`): round 016 measured a probe that never opened either of
# those and incremented a new key in this function instead.
func record_podium_rally(rally_id: String, combined_ms: int, placed: int = 0) -> int:
	var rallies: Dictionary = profile[KEY_RALLIES]
	var rec: Dictionary = rallies.get(rally_id, {"completed": false, "best_combined_ms": 0, "best_placed": 0})
	rec["completed"] = true
	# Only a REAL time can become the best time. A DNF arrives as combined_ms <= 0, and
	# without this guard it would sail through the "faster than the record" test — every
	# negative is less than every positive — and install itself as an unbeatable best.
	# Only the opening rally can complete on a DNF (todo/opening-rally.md), so this is the
	# one caller that can reach here without a time; the guard lives with the field it
	# protects rather than at that call site, since nothing downstream wants a negative
	# best_combined_ms regardless of who wrote it.
	if combined_ms > 0 and (int(rec.get("best_combined_ms", 0)) <= 0
			or combined_ms < int(rec["best_combined_ms"])):
		rec["best_combined_ms"] = combined_ms
	# Track the BEST (lowest) finishing position ever achieved here — it drives the
	# map's star rating. Lower placement is better; 0 means "never placed".
	if placed > 0 and (int(rec.get("best_placed", 0)) <= 0 or placed < int(rec["best_placed"])):
		rec["best_placed"] = placed
	rallies[rally_id] = rec
	# Credit what THIS finish placed, not the improvement on the record: every finish pays,
	# so a rally can be re-driven for stars. Read off `placed` rather than the stored
	# `best_placed` for exactly that reason — the record only ever improves, so paying off it
	# would silently reinstate the old no-pay-on-a-worse-replay rule.
	var gained := RallyLibrary.stars_for_placement(placed)
	if gained > 0:
		profile["stars_earned"] = int(profile.get("stars_earned", 0)) + gained
	save()
	return maxi(0, gained)


# --- Star ledger -------------------------------------------------------------
# See todo/star-economy.md. Career stars arrive through record_podium_rally (which pays every
# finish); everything else — currently the Rally Challenge — credits via award_stars.

# Stars the player can still spend. Clamped at 0 defensively: the ledger cannot go
# negative through this API, but a hand-edited or corrupted profile should read as
# broke rather than as a negative balance that breaks arithmetic downstream.
func stars_available() -> int:
	return maxi(0, int(profile.get("stars_earned", 0)) - int(profile.get("stars_spent", 0)))


# Credit stars from a NON-rally source (the Rally Challenge). Rally finishes must go through
# record_podium_rally instead — it is the one place that records the finish AND pays for it, so
# calling this for a rally as well would double-credit it.
func award_stars(count: int, do_save := true) -> void:
	if count <= 0:
		return
	profile["stars_earned"] = int(profile.get("stars_earned", 0)) + count
	if do_save:
		save()


# Debit `count` stars, or change nothing and return false when the balance is short.
# Refusing rather than clamping is deliberate: a caller that cannot afford something
# must not half-complete the transaction.
func spend_stars(count: int, do_save := true) -> bool:
	if count < 0 or count > stars_available():
		return false
	if count > 0:
		profile["stars_spent"] = int(profile.get("stars_spent", 0)) + count
		if do_save:
			save()
	return true


# --- Spending stars ----------------------------------------------------------
# Two sinks, both demand-driven and both renewable, which is what a currency needs if the
# balance is not to become dead weight. See features/star-economy.md.
#
# Cars are NOT one of them: a car is won at the rally that advertises it
# (features/prize-rallies.md).


# What repairing `instance_id` costs right now: the flat price, or 0 when the car needs
# nothing. Quoted by the garage so the button can price itself and disable when the balance
# is short, and read by repair_car so a quote and a charge can never disagree.
func repair_price(instance_id: int) -> int:
	return int(Config.data.star_cost_per_repair) if car_needs_repair(instance_id) else 0


# Is this car's damage ACTUALLY COSTING IT PERFORMANCE — the question the car park's red
# warning asks.
#
# Deliberately NOT car_needs_repair. That one is "is this car less than pristine", which is
# the right question for offering a repair (any lost health can be bought back) and the
# wrong one for a warning: it is true at 99% health, and it also counts bent alignment, so
# the player was told in red that an undamaged car was damaged. A warning that fires when
# nothing is wrong is one they learn to ignore, which costs them the time it matters.
#
# The threshold is GameConfig.damage_misfire_health_threshold — the SAME number that
# decides when the engine starts misfiring, i.e. the exact point damage stops being
# cosmetic and starts costing power. Reusing it rather than authoring a second "warn below
# this" value is what stops the warning and the simulation disagreeing about whether the
# car is hurt.
func car_handles_badly(instance_id: int) -> bool:
	var car := get_car(instance_id)
	if car.is_empty():
		return false
	var entry := CarLibrary.for_owned(car)
	var max_hp := float(entry.get("max_hp", 1000.0))
	if max_hp <= 0.0:
		return false
	return float(car.get("hp", max_hp)) / max_hp < Config.data.damage_misfire_health_threshold


# Does this car have anything a repair would actually fix — lost health or bent wheels?
# Both matter: a car at full HP with dog-legged toe still drives badly, and charging for a
# repair that changes nothing is the one thing a flat price must never do.
#
# NOT the warning predicate — that is car_handles_badly above, which asks the narrower
# question "is the damage costing performance". A car can want repairing without being hurt.
func car_needs_repair(instance_id: int) -> bool:
	var car := get_car(instance_id)
	if car.is_empty():
		return false
	var entry := CarLibrary.for_owned(car)
	if float(car.get("hp", 0.0)) < float(entry.get("max_hp", 1000.0)):
		return true
	for toe in car.get("wheel_toe", []):
		if not is_zero_approx(float(toe)):
			return true
	return false


# Spend stars to return a car to full health with straight wheels. Returns true when the
# repair happened.
#
# NOTHING TO FIX = NOTHING SPENT, and the charge is resolved BEFORE the car is touched, so
# a short balance leaves both the ledger and the car exactly as they were. Same rule the
# whole codebase applies to a transaction it cannot complete.
func repair_car(instance_id: int) -> bool:
	if not car_needs_repair(instance_id):
		return false
	var car := get_car(instance_id)
	if car.is_empty():
		return false
	if not spend_stars(repair_price(instance_id), false):
		return false
	var entry := CarLibrary.for_owned(car)
	car["hp"] = float(entry.get("max_hp", 1000.0))
	car["wheel_toe"] = [0.0, 0.0, 0.0, 0.0]
	save()
	return true


# Can this car be sold a copy of `item_id` right now? Every condition the shop button and
# the purchase itself both have to agree on, in one predicate so the two cannot diverge.
#
# The part must be DISCOVERED — its part-unlock rally won (UpgradeLibrary.rally_gate_met) —
# because the shop sells what the player has proven they can earn, never a shortcut past
# the exploration that reveals it. The per-car prerequisite ladder still applies: upgrades
# are car-bound, so every car climbs its own chain and buying cannot skip a rung.
func can_buy_part(instance_id: int, item_id: String) -> bool:
	if UpgradeLibrary.by_id(item_id).is_empty():
		return false
	var car := get_car(instance_id)
	if car.is_empty():
		return false
	if car.get("installed_upgrades", []).has(item_id):
		return false  # per-car dedup: a car can never hold the same part twice
	if not UpgradeLibrary.rally_gate_met(item_id, profile):
		return false  # not discovered yet — go and win it
	if not UpgradeLibrary.prerequisite_met(item_id, car):
		return false  # this car has not earned its way up the ladder
	return stars_available() >= part_price(item_id)


# What a copy of `item_id` costs. Flat per part today; a function so rarity pricing can
# land later without every caller changing.
func part_price(_item_id: String) -> int:
	return int(Config.data.star_cost_per_part)


# Buy a copy of an already-discovered part and fit it to `instance_id`. Returns true when
# the part was bought. Fitted DISABLED, like every other award: which part runs in a slot
# is the player's choice, made in the upgrades menu.
func buy_part(instance_id: int, item_id: String) -> bool:
	if not can_buy_part(instance_id, item_id):
		return false
	if not spend_stars(part_price(item_id), false):
		return false
	var car := get_car(instance_id)
	(car["installed_upgrades"] as Array).append(item_id)
	if not (car["disabled_upgrades"] as Array).has(item_id):
		(car["disabled_upgrades"] as Array).append(item_id)
	save()
	return true


# --- Drivetrain conversion ----------------------------------------------------
#
# Unlike a part, a drive mode is not something a car HOLDS — it is one of three layouts the
# car can be set to. So the purchase records the MODE, per car, and switching between modes
# the car has already paid for is free thereafter (exactly as toggling a bought part between
# Stock and fitted is free). Reverting to the car's authored stock layout is always free and
# never recorded.
#
# The capability itself is GLOBAL: won once, on the rally that gates `drivetrain_swap`, and
# available to every car in the garage from then on. What is per-car is the bill.


# What converting one car to one non-stock layout costs.
func drive_mode_price() -> int:
	return int(Config.data.star_cost_per_drive_mode)


# Whether `mode` could be bought for this car right now: the conversion capability is
# unlocked garage-wide, this car has not already paid for that mode, it is not the car's
# own stock layout (free), and the stars are there.
func can_buy_drive_mode(instance_id: int, mode: int) -> bool:
	var car := get_car(instance_id)
	if car.is_empty():
		return false
	if not UpgradeLibrary.drivetrain_swap_unlocked(profile):
		return false
	if mode == UpgradeLibrary.stock_drive_mode(car):
		return false  # stock is free; there is nothing to sell
	if (car.get("drivetrain_modes_bought", []) as Array).has(mode):
		return false  # already paid for on this car
	return stars_available() >= drive_mode_price()


# Buy `mode` for this car. Records the mode; does NOT select it — the caller sets the
# override, exactly as buy_part leaves a bought part parked for the caller to enable.
func buy_drive_mode(instance_id: int, mode: int) -> bool:
	if not can_buy_drive_mode(instance_id, mode):
		return false
	if not spend_stars(drive_mode_price(), false):
		return false
	var car := get_car(instance_id)
	(car["drivetrain_modes_bought"] as Array).append(mode)
	save()
	return true


# Whether this car may currently be SET to `mode` without paying: its own stock layout, or
# one it has already bought. The single rule shared by the picker, the apply path and
# resolve_drive_override.
func drive_mode_available(car: Dictionary, mode: int) -> bool:
	if car.is_empty():
		return false
	if mode == UpgradeLibrary.stock_drive_mode(car):
		return true
	if not UpgradeLibrary.drivetrain_swap_unlocked(profile):
		return false
	return (car.get("drivetrain_modes_bought", []) as Array).has(mode)


# --- Auto-Upgrade plans -------------------------------------------------------
#
# Commit a plan from UpgradeLibrary.auto_build_plan to a car: buy, switch on, park,
# then write the detune and any drivetrain override. The solver decides WHAT, this
# decides nothing — which is what lets the Auto-Upgrade button, the free restore at
# the Start gate and the tests all share one rule.
#
# Order matters: buys land before enables (a bought part arrives parked, like every
# other award), and strips run last so a slot's outgoing part cannot re-park the
# incoming one through _enable_exclusive. Returns false when nothing was applied.
func apply_build_plan(instance_id: int, plan: Dictionary) -> bool:
	if get_car(instance_id).is_empty() or not bool(plan.get("changed", false)):
		return false
	for item_id in plan.get("buy", []):
		if buy_part(instance_id, item_id):
			set_upgrade_enabled(instance_id, item_id, true)
	for item_id in plan.get("enable", []):
		set_upgrade_enabled(instance_id, item_id, true)
	for item_id in plan.get("strip", []):
		set_upgrade_enabled(instance_id, item_id, false)
	if int(plan.get("drivetrain", -1)) >= 0:
		# Buy the layout first if this car has not already paid for it — the plan quoted the
		# cost, so committing has to actually spend it rather than handing over a free
		# conversion the picker charges for.
		#
		# Committed BEFORE the part buys would be wrong too (parts are the plan's main
		# purpose), so instead the failure is REPORTED: the part buys above may have
		# consumed a balance the plan budgeted for both, and silently skipping the
		# conversion would return `true` having produced a car that does not satisfy the
		# restriction the plan cleared. The caller gets false and can re-plan against the
		# real balance.
		var want_mode := int(plan["drivetrain"])
		if not drive_mode_available(get_car(instance_id), want_mode) \
				and not buy_drive_mode(instance_id, want_mode):
			set_engine_detune(instance_id, float(plan.get("detune", 1.0)))
			return false
		set_drivetrain_override(instance_id, want_mode)
	set_engine_detune(instance_id, float(plan.get("detune", 1.0)))
	return true


# Fold one stage result into the adaptive-difficulty offset and persist it.
#
# Called once per finished stage from RallySession. The RULE lives in AiDifficulty; this
# only stores the answer, so the difficulty logic stays testable without a save.
func record_stage_result(won: bool) -> void:
	var out := AiDifficulty.apply_stage_result(profile, won)
	for k in out:
		profile[k] = out[k]
	save()


# Did this rally's record get written at all — i.e. did the player PODIUM it (or was it
# the opening rally's first attempt)? NOT "did the player finish it".
#
# THE GATE IS ON THE WRITE, NOT ON ANY ONE FIELD. `Save.record_podium_rally` has exactly one
# caller (`rally_session.gd`, inside `_award_podium_rewards`, which runs only
# `if podium_or_opening`), so a 5th-place finish writes NOTHING into the rally's record.
# That makes EVERY field of the record podium-gated — `completed`, `best_placed` and
# `best_combined_ms` alike. Deriving a "rallies finished" count from `best_placed > 0`
# instead of from `completed` therefore gets you the SAME podium number under a different
# name; there is no untainted sibling field to escape through.
#
# Was named `rally_completed()` until round 015, which is the lie this comment replaces.
func rally_podiumed(rally_id: String) -> bool:
	return profile[KEY_RALLIES].get(rally_id, {}).get("completed", false)


# --- New-rally reveal acknowledgement ----------------------------------------
#
# Whether the player has been SHOWN that this rally opened up (the map-table reveal
# sequence — hq_table.gd `_run_reveal_sequence`). Stored per rally, beside `completed`, so
# everything known about a rally lives in one record and a rally id that stops existing
# takes its flag with it instead of orphaning an entry in a parallel list.
#
# Only the ACKNOWLEDGEMENT is persisted, never the unlock itself: whether a rally is
# available is always derived from the profile (RallyLibrary.rally_revealed + an owned
# eligible car). A missing key reads false through the normal .get default, so no
# SCHEMA_VERSION bump was needed. See features/save-persistence.md.
func rally_revealed_seen(rally_id: String) -> bool:
	return bool(profile[KEY_RALLIES].get(rally_id, {}).get("revealed", false))


func mark_rally_revealed(rally_id: String, save_now := true) -> void:
	var rallies: Dictionary = profile[KEY_RALLIES]
	var rec: Dictionary = rallies.get(rally_id, {"completed": false, "best_combined_ms": 0, "best_placed": 0})
	rec["revealed"] = true
	rallies[rally_id] = rec
	if save_now:
		save()


# True when this profile predates the reveal feature (or was just restored from the
# cloud onto a device that has never run the sequence): it has career progress, yet not
# one rally carries a `revealed` flag. `false` is exactly the WRONG default for such a
# save — a player with a dozen open rallies would get a dozen-pin parade on next
# launch — so the caller seeds what is already open as already-seen instead of
# playing it. See hq.gd `_seed_reveals_if_needed`.
func needs_reveal_seeding() -> bool:
	# "Career progress" is read straight off the profile rather than through
	# RallyLibrary.podium_count, so the backfill decision doesn't depend on the
	# shipped roster still containing the rallies this save finished.
	var progressed := false
	for rec in profile[KEY_RALLIES].values():
		var r: Dictionary = rec
		if bool(r.get("revealed", false)):
			return false
		if bool(r.get("completed", false)):
			progressed = true
	return progressed  # a brand-new career has nothing to backfill; its first reveals are real


# THE BACKFILL ITSELF — moved here (rather than left as a call hq.gd makes on entering
# the map) so it runs at the points a profile actually BECOMES LIVE (load_or_new,
# adopt_profile) and can never be forgotten by a future scene/entry point that also
# reaches the map or replaces the profile. A caller reaching the map through some path
# nobody has written yet still gets the seeded profile, because the seeding already
# happened when that profile was loaded/adopted — there is nothing left for hq.gd to do.
#
# Seeds every rally that is UNLOCKED (RallyLibrary.rally_revealed) or already COMPLETED,
# deliberately WITHOUT the eligible-owned-car clause hq.gd's `_pending_reveals` applies:
# seeding's job is "anything already open should already read as seen", not "anything the
# player could currently enter" — and it keeps this autoload independent of hq's
# `_entry_plan` (owned cars, engine/tune headroom, etc). Completed rallies are seeded
# alongside unlocked-but-not-yet-completed ones purely so the "no flags at all" state
# can't survive the pass — otherwise a progressed profile with nothing currently open
# would re-seed (and so swallow) its next real reveal.
func _seed_reveals_if_needed() -> void:
	if not needs_reveal_seeding():
		return
	for rally in RallyLibrary.all():
		var rid := String(rally["id"])
		if rally_podiumed(rid) or RallyLibrary.rally_revealed(rally, profile):
			mark_rally_revealed(rid, false)
	save()


# Dev cheat (Settings → Dev): mark EVERY rally 3-starred (1st place) so the whole map is
# lit at once (RallyLibrary.rally_revealed) and any part of the game can be reached
# without grinding to it.
func dev_three_star_all_rallies() -> void:
	for rally in RallyLibrary.all():
		dev_three_star_rally(String(rally["id"]), false)
	save()


# The combined time a dev win records. A plausible-but-unremarkable figure rather than 0,
# which would read as an impossible world record on every leaderboard the rally feeds.
const DEV_WIN_TIME_MS := 300_000


# Dev cheat (the rally-detail panel's dev button): mark ONE rally 3-starred, as though the
# player had just won it outright. The per-rally counterpart to the mass cheat above, and
# the one that matters for map exploration: reveal is geometric, so completing a single
# rally lights the circle around THAT pin and opens whatever it neighbours — which is
# exactly the step-by-step progression a designer wants to walk without driving 17 waves of
# rallies. Doing it one pin at a time is what the mass cheat cannot show, since that lights
# the entire map in one go.
#
# `persist` is false when a caller is looping (one disk write at the end instead of N).
func dev_three_star_rally(rally_id: String, persist := true) -> int:
	# Goes through record_podium_rally rather than writing the record by hand, so the cheat pays
	# STARS — and, via _grant_rally_prizes below, the CAR or PART — exactly as a real 1st
	# place would — including the delta rule, which credits only
	# the improvement over this rally's previous best and so cannot be farmed by pressing the
	# button twice. Hand-writing the record left the ledger untouched, which made every
	# dev-completed career star-broke and useless for testing anything the balance gates.
	#
	# Reusing the real path is also what stops the two drifting: whatever record_podium_rally
	# starts recording next lands here for free.
	# Captured BEFORE record_podium_rally, which is what sets `completed` — afterwards there is no
	# way to tell a first win from a re-win, and the prizes are first-win-only.
	var first_win := not rally_podiumed(rally_id)
	var gained := record_podium_rally(rally_id, DEV_WIN_TIME_MS, 1)
	if first_win:
		_grant_rally_prizes(rally_id)
	if persist:
		save()
	return gained


# Hand over whatever a rally awards, exactly as finishing it would (features/prize-rallies.md).
#
# The cheat used to record the completion and pay the stars but hand over NOTHING — so a
# dev-completed career had every rally ticked off and an empty garage, which is useless for
# testing anything downstream of owning the car or part a rally exists to give.
#
# Mirrors rally_session's award path rather than inventing a second one: same first-win-only
# rule, same duplicate guard, same cascade for a part's missing prerequisites. It cannot
# simply CALL that path, which is wound through a live session's result handling.
func _grant_rally_prizes(rally_id: String) -> void:
	var rally := RallyLibrary.by_id(rally_id)
	if rally.is_empty():
		return
	var prize_car := RallyLibrary.prize_car_id(rally)
	if prize_car != "" and not owns_model(prize_car):
		grant_car(prize_car)
	# A part goes to the SELECTED car — the dev button is pressed from the map with no rally
	# being driven, so there is no "car you just drove" to fit it to.
	var recipient := selected_instance_id()
	if recipient < 0:
		return
	var unlocked := UpgradeLibrary.unlocked_by(rally_id)
	if not unlocked.is_empty():
		RewardSystem.grant_special_unlock(recipient, String(unlocked.get("id", "")))
	# The engine-swap capability special needs nothing handed over: winning it unlocks
	# swapping outright, and swaps are free and unlimited from then on.
	return


# Best (lowest) finishing position ever achieved in a rally, or 0 if never placed.
# Drives the world-map star rating via RallyLibrary.stars_for_placement (1st = the most).
#
# 0 DOES NOT MEAN "NEVER FINISHED", and a consumer that reads it that way is wrong. This field
# is only ever written by record_podium_rally, whose single caller is podium-gated (see its
# comment), so a player who FINISHED 5th has 0 here just as one who never entered does. `> 0`
# therefore means PODIUMED, not completed — label any UI off it accordingly, and if you need
# "did they finish", there is no such counter in the save schema (add persistence for one).
# Written down because a map readout guarded itself with `if placement > 0:  # only show if the
# rally has been completed` — correct code, wrong reason, which is how the next edit goes wrong.
func best_placement(rally_id: String) -> int:
	return int(profile[KEY_RALLIES].get(rally_id, {}).get("best_placed", 0))


# Number of rallies PODIUMED (top-3) — the progression metric driving the CAR reward-tier
# ceiling. (Map REVEAL keys off nothing of the sort any more: a rally opens when the player
# has lit the map out to it, see RallyLibrary.rally_revealed.)
#
# WHAT THIS IS NOT: it is not "rallies the player has finished". The gate is on the
# WRITE, not on any one field — `record_podium_rally` is called from exactly one site
# (rally_session.gd, inside `_award_podium_rewards`, gated on
# `var podium_or_opening := top3 or opening_first`), so finishing 5th writes nothing into
# the record and EVERY field of it is podium-gated: `completed`, `best_placed` and
# `best_combined_ms` alike. Counting `best_placed > 0` is the same podium number wearing a
# better name — there is no untainted sibling field to escape through.
#
# NO counter of finishes-in-any-position exists anywhere in the save schema — if you need
# one, add persistence for it (declared in `_default_profile()`) rather than deriving it
# from this record, and never label UI "RALLIES FINISHED: N" off this value.
# Delegates to RallyLibrary so the metric has one definition.
func podium_rally_count() -> int:
	return RallyLibrary.podium_count(profile)


# DEPRECATED — use podium_rally_count(). Counts PODIUM (top-3) finishes, not finishes.
func completed_rally_count() -> int:
	return podium_rally_count()

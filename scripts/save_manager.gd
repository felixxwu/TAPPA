extends Node
# Docs: features/engine-swap.md, features/save-persistence.md, features/lifetime-stats.md, features/perks.md — update in the same change as this file.
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

# Bump on any breaking shape change to PlayerProfile. NO LONGER MIGRATED FORWARD
# (todo/roguelike-pivot.md decision 20 / decision 34): the old `_migrate_step` ladder
# (schemas 1-6) is deleted along with the legacy backfill keys it wrote. A profile whose
# `schema_version` does not match exactly — older OR newer — is refused by `_migrate()`
# and `load_or_new()` falls back to a fresh default, exactly as it already does for an
# unreadable file: the ON-DISK FILE IS KEPT, UNTOUCHED (never overwritten by the fresh
# session), only the LIVE session starts clean. That is deliberate, not an oversight:
#
#   - Decision 34 says "a pre-pivot profile resets whatever its version" — the pivot
#     replaces the whole economy (stars -> money) and the whole reward model (prize
#     rallies -> a shop), so a v6 profile's `stars_earned`, its legacy part-unlock /
#     engine-swap backfill keys (all now gone) and its rally-completion-as-currency shape
#     do not describe anything this build still understands well enough to interpret safely.
#   - Writing a transform between two economies that never coexist (decision 20's "no
#     dual code paths") is the thing decision 20 explicitly rejects as not worth the
#     complexity, so there is no migration to write even for the parts of the schema
#     (owned cars, tuning) that DID survive this particular wave unchanged.
#   - This wave (the save/economy demolition) is where SCHEMA_VERSION bumps for the pivot:
#     it is the one wave that owns this file, and it is what makes "a pre-pivot profile"
#     concrete rather than aspirational — an old profile stops parsing as current from
#     this change forward, even though later pivot waves (regions_cleared, money, boost
#     levels, …) have not landed yet. Bumping later, per-wave, would mean multiple
#     schema bumps for one demolition and no single point where "old" became well-defined.
#   - `_migrate()` still backfills any KEY MISSING off a correctly-versioned (current
#     SCHEMA_VERSION) profile from `_default_profile()` — that half is unrelated to
#     migration and stays exactly as it works for `cloud_revision` / `username` today.
const SCHEMA_VERSION := 7

# The two profile keys the REST of the codebase reads (the owned-car array and the
# per-rally record map) — named here because SaveManager owns the save schema, and a
# ~50-site spread of the bare literals made a rename a silent cross-device data bug
# (scripts/cloud/cloud_sync.gd keys off the same strings). These are ON-DISK key
# STRINGS: changing either VALUE breaks every existing profile, so they are frozen
# unless a SCHEMA_VERSION bump comes with the change (there is no migration to pair it
# with any more — see that const's own comment).
const KEY_CARS := "cars"
const KEY_RALLIES := "rallies"

# --- Roguelike run-meta keys (todo/roguelike-pivot.md) -------------------------
# Everything a failed run must NOT touch. Soft permadeath destroys the run -- stage
# progress, the boosts picked during it, the car's accrued damage -- and nothing here.
# That asymmetry is the whole progression design, so these live on the PROFILE and are
# written outside the run, never inside it.
const KEY_MONEY := "money"                    # the single currency (decision 21)
# THE ONE RUN SLOT (decision 27). Holds an in-progress run of EITHER kind — the
# roguelike region run or the Daily/Weekly/Monthly challenge — so starting one
# discards a paused run of the other. Was `challenge_run` before RunSession was
# generalised; renamed with the SCHEMA_VERSION 7 reset, which costs nothing because
# every pre-pivot profile is refused rather than migrated.
const KEY_RUN := "run"
const KEY_REGIONS_CLEARED := "regions_cleared" # ids of regions whose 8 stages are done
const KEY_BOOST_LEVELS := "boost_levels"      # boost id -> purchased level (meta tier)
const KEY_BOUGHT_PERKS := "bought_perks"      # perk ids owned
const KEY_EQUIPPED_PERKS := "equipped_perks"  # perk ids currently slotted (capped)
const KEY_LIFETIME := "lifetime"              # stat id -> running total, never reset
# The Engine Swap capability's purchased-unlock flag (todo/roguelike-pivot.md decision 17 —
# re-gated as a meta shop purchase). Read by RallyLibrary.engine_swaps_unlocked, which used
# to read a rally-completion flag; see that function's own comment.
const KEY_ENGINE_SWAP_UNLOCKED := "engine_swap_unlocked"

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
			+ "Add it to _default_profile() with its default value (see the `schema_version` "
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


# Drop entries that no longer resolve against the current catalogues (a car removed from
# CarLibrary) so old saves stay loadable as the content evolves.
func _sanitise(p: Dictionary) -> Dictionary:
	var kept: Array = []
	for car in p.get(KEY_CARS, []):
		if CarLibrary.index_of(car.get("model_id", "")) >= 0:
			# Backfill per-wheel damage misalignment on saves that predate it (straight).
			if not car.has("wheel_toe"):
				car["wheel_toe"] = [0.0, 0.0, 0.0, 0.0]
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
		"reward_history": [],
		# The run-meta block. Declared here because the ratchet test below requires every
		# persisted key to be DECLARED rather than conjured at the write site.
		#
		# MONEY IS SEEDED FROM GameConfig.run_starting_money, NOT 0 (todo/roguelike-pivot.md
		# decision 28 — "a new player starts with money and buys from the shop", replacing the
		# old three-car starter picker outright). Config is the autoload loaded immediately
		# before this one (project.godot), so its data is ready by the time any profile —
		# fresh or migrated — is built. A profile with money but zero cars must still be able
		# to reach the shop; see HubShell's CAR page.
		KEY_MONEY: int(Config.data.run_starting_money),
		KEY_REGIONS_CLEARED: [],
		KEY_BOOST_LEVELS: {},
		KEY_BOUGHT_PERKS: [],
		KEY_EQUIPPED_PERKS: [],
		KEY_LIFETIME: {},
		KEY_ENGINE_SWAP_UNLOCKED: false,
		"settings": {},
		# --- Star ledger: DELETED (todo/roguelike-pivot.md decision 21) ---
		# `stars_earned` / `stars_spent` are gone outright, not migrated: the pivot replaced
		# stars wholesale with RR-style money (KEY_MONEY above -- per-stage payout, a
		# fast-completion bonus and mid-stage coins; see the pivot doc's Economy section).
		# Do NOT reintroduce a "stars_earned"/"stars_spent" pair.
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
		# THE ONE RUN SLOT (decision 27) — the in-progress run, of either kind, or {}
		# when none is active. Always: {mode, car_instance_id, stage_index,
		# stage_times_ms: [...], dnf, money_earned}, plus the mode's own half —
		# {period_key, kind} for a challenge (features/rally-challenge.md),
		# {region_id, run_seed, stage_count} for a region run
		# (features/region-runs.md). RunSession._persist is its only writer.
		KEY_RUN: {},
		# Terminal outcomes per challenge period, keyed by period_key:
		# {kind, dnf: bool, cumulative_ms: int}. A period present here is FINISHED —
		# completed or DNF'd — and cannot be started again for the rest of that
		# period (a challenge is one attempt; abandoning ends the run with no retry).
		# Separate from the run slot rather than folded into it because
		# RunSession.resumable_run keys on that slot being non-empty, so a
		# terminal record stored there would make the game try to RESUME a finished
		# run. Pruned to live periods on every write, so it can't grow without bound.
		# Backfilled by _migrate's key backfill, so no SCHEMA_VERSION bump.
		"challenge_results": {},
	}


# --- Migration ---------------------------------------------------------------
# NO LONGER A LADDER (todo/roguelike-pivot.md decisions 20 & 34): `_migrate_step` and
# `_MIGRATABLE_FROM` (which used to step a profile forward one schema version at a time,
# versions 1 through 6) are deleted along with their legacy backfill data
# (`MOVED_PART_UNLOCKS`, `OLD_ENGINE_SWAP_UNLOCK_RALLY`) — see SCHEMA_VERSION's own
# comment for why a bump with no migration is the correct call here, not an oversight.
# `_migrate` now does exactly two things: refuse anything that is not EXACTLY the current
# schema (older or newer — both are "not what this build understands"), and backfill any
# key a correctly-versioned but partial file is missing, which is unrelated to migration
# and works exactly as it always has for `cloud_revision` / `username` / any other key
# added without a version bump.
func _migrate(p: Dictionary) -> Dictionary:
	if int(p.get("schema_version", 0)) != SCHEMA_VERSION:
		return {}  # pre-pivot (or newer-than-known) profile: refuse rather than guess
	var base := _default_profile()
	for k in base:
		if not p.has(k):
			p[k] = base[k]
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
		"tuning": {},
		"wheel_toe": [0.0, 0.0, 0.0, 0.0],
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


# The inverse of apply_damage: give `amount` HP back, capped at the car's authored
# max_hp. Used by RunSession.report_event_result when a stage ends with a NET heal (the
# "self_healing" perk, todo/roguelike-pivot.md decision 51) — without it the trickle
# would be silently discarded at every stage boundary.
#
# Deliberately NOT a repair: it moves HP only, leaving `wheel_toe` bent. Straightening
# wheels stays field_repair's job (the between-stage pick), so a self-healing car still
# has a reason to take the repair.
func heal_car(instance_id: int, amount: float) -> void:
	if amount <= 0.0:
		return
	var car := get_car(instance_id)
	if car.is_empty():
		return
	var entry := CarLibrary.by_id(String(car.get("model_id", "")))
	var max_hp := float(entry.get("max_hp", car["hp"])) if not entry.is_empty() else float(car["hp"])
	car["hp"] = minf(max_hp, float(car["hp"]) + amount)
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


# --- Run car lock -------------------------------------------------------------
# Whether the active run (of EITHER kind) is COMMITTED to `instance_id`. The STORAGE-LEVEL
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
	var run: Dictionary = profile.get(KEY_RUN, {})
	return not run.is_empty() and int(run.get("car_instance_id", -1)) == instance_id


# Persist `run` into the ONE run slot (RunSession._persist / pause_run), replacing
# whatever was there — including a paused run of the other kind (decision 27). The
# one writer of this key's shape; RunSession never reaches into profile[KEY_RUN].
func set_run(run: Dictionary) -> void:
	profile[KEY_RUN] = run
	save()


# Clear the stored run (RunSession.discard_stale_run / _clear_persisted on finish) —
# no run stored, nothing to resume.
func clear_run() -> void:
	profile[KEY_RUN] = {}
	save()


# Replace the challenge_results map (ChallengeRunMode.record_outcome, already
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


# --- Selected car ------------------------------------------------------------
# The player always has one owned car "selected" — the one raised on the garage
# tuning lift. It's the default car the lift tunes/upgrades, and
# (unless a rally car-select overrides it) the one fielded. Stored as an instance
# id, resolved lazily so it always points at a still-owned car.
# (todo/menus.md, cited here, is deleted — todo/roguelike-pivot.md decision 44.)

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


# THE PERSISTENT PARTS MODEL IS DELETED (todo/roguelike-pivot.md -> "What gets deleted").
# `install_upgrade` / `set_upgrade_enabled` and their `_enable_exclusive` / `_disable`
# helpers lived here, alongside `installed_upgrades` / `disabled_upgrades` on each OwnedCar.
# Nothing is fitted to a car any more: upgrades are RR-style boosts, temporary and
# run-scoped, picked between stages and wiped on run end (decision 8, and the pivot doc's
# "Upgrades -- RR's two-tier model"). They reach the live config through the surviving
# effects funnel, UpgradeLibrary.apply -- see that file's `active_effects` seam, which is
# the ONE place stage 5 has to fill in.



# In-run HP is one-way: nothing here restores it mid-run. It climbs back only between
# runs — the free between-event patch-up below. The paid repair at the lift is retired
# (todo/roguelike-pivot.md decision 21 — see the "Spending stars: DELETED" note above).
# See features/damage.md.


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


# field_repair with THE fractions — the ones every stage-to-stage transition uses
# (GameConfig's field_repair_hp_fraction / field_repair_toe_fraction). Every
# between-stage and final-stage repair in the game goes through this one entry
# point, so no caller can drift on which fractions it applies; the raw
# field_repair above stays available for a caller that genuinely needs its own.
#
# Folded here from RallySession, whose four lines already did nothing but read
# those two config fields and delegate. Callers: RallySession._apply_field_repair
# (stage-to-stage + the silent final-event repair) and
# RunSession.report_event_result (the same two beats for every kind of run).
# `instance_id` < 0 (nothing fielded) is a no-op, not an error.
func apply_field_repair_to(instance_id: int) -> Dictionary:
	if instance_id < 0:
		return {"repaired": false}
	var cfg := Config.data
	return field_repair(instance_id,
		cfg.field_repair_hp_fraction, cfg.field_repair_toe_fraction)


# --- Money (todo/roguelike-pivot.md decision 21) ------------------------------
#
# The single currency, and the whole of it: earned per stage CLEARED (decision 36 —
# banked at the clear, never at run end, so a failed run keeps everything it made)
# plus the challenge's placement lump sum, and spent in the meta shop. A failed run
# never takes any of it back (decision 14), which is why there is no `lose_money`.

func money() -> int:
	return int(profile.get(KEY_MONEY, 0))


# Bank `amount` (clamped at 0 — this only ever adds). Returns the new balance.
#
# THE ONE FUNNEL every money source goes through, which is why LifetimeStats.MONEY_EARNED
# is written HERE rather than at each payout site: a stage clear, a fast-completion
# bonus and a future challenge reward all land here, so the lifetime counter can never
# miss one without a second call site to keep in sync.
func add_money(amount: int) -> int:
	if amount <= 0:
		return money()
	profile[KEY_MONEY] = money() + amount
	add_lifetime_stat(LifetimeStats.MONEY_EARNED, amount)
	save()
	return money()


# Deduct `amount` if the player can afford it, else leave the balance untouched.
# Returns whether the purchase went through, so a caller can never half-spend.
#
# THE ONE FUNNEL every purchase goes through (buy_car, buy_boost_level,
# buy_engine_swap_unlock, buy_perk) — LifetimeStats.MONEY_SPENT is written HERE so it
# covers every sink automatically, the same reasoning as add_money's own comment.
# Never called on a refused purchase (every buy_* checks its own precondition first),
# so a rejected buy never inflates this counter.
func spend_money(amount: int) -> bool:
	if amount <= 0 or money() < amount:
		return amount <= 0
	profile[KEY_MONEY] = money() - amount
	add_lifetime_stat(LifetimeStats.MONEY_SPENT, amount)
	save()
	return true


# --- The meta shop (todo/roguelike-pivot.md "Upgrades — RR's two-tier model" +
# "Car acquisition — RR's shop", stage 6 of todo/roguelike-pivot-plan.md) -------------
#
# Three sinks, each a thin wrapper over spend_money so every refusal path shares its one
# rule: a purchase that cannot be afforded (or is otherwise invalid — an unknown id, a car
# already owned, a boost already at its cap, the unlock already bought) leaves the profile
# BYTE-IDENTICAL. `spend_money` already refuses without mutating; every function below
# checks its OWN precondition (ownership / cap / already-unlocked) BEFORE calling it, so a
# caller never spends into a purchase that was going to be rejected anyway.

# Buy an unowned car outright (decision 28). Refuses (no mutation) if `model_id` is not a
# real CarLibrary entry, is already owned, or the player cannot afford its `cost`.
func buy_car(model_id: String) -> bool:
	if owns_model(model_id):
		return false
	var entry := CarLibrary.by_id(model_id)
	if entry.is_empty():
		return false
	if not spend_money(int(entry.get("cost", 0))):
		return false
	grant_car(model_id)
	return true


# The purchased level of one BoostLibrary boost id (0 if never bought). This is what
# BoostLibrary.effect_for reads to scale a future in-run pick's magnitude — see that
# file's own header for the scaling relationship.
func boost_level(id: String) -> int:
	return int((profile.get(KEY_BOOST_LEVELS, {}) as Dictionary).get(id, 0))


# The cost of this boost's NEXT level, given the level already owned — RR's
# `basePrice * priceMultiplierPerLevel ** currentLevel`, both GameConfig tunables
# (@export_group("Roguelike Meta Shop")).
func boost_level_price(id: String) -> int:
	var cfg: GameConfig = Config.data
	return int(round(cfg.boost_level_price_base
		* pow(cfg.boost_level_price_growth, float(boost_level(id)))))


# Buy the next level of boost `id`. Refuses (no mutation) for an id BoostLibrary does not
# catalogue, a level already at GameConfig.boost_level_max, or an unaffordable price.
func buy_boost_level(id: String) -> bool:
	if not BoostLibrary.CATALOGUE.has(id):
		return false
	var level := boost_level(id)
	if level >= int(Config.data.boost_level_max):
		return false
	if not spend_money(boost_level_price(id)):
		return false
	var levels: Dictionary = profile.get(KEY_BOOST_LEVELS, {})
	levels[id] = level + 1
	profile[KEY_BOOST_LEVELS] = levels
	save()
	return true


# Whether the Engine Swap capability has been purchased — what
# RallyLibrary.engine_swaps_unlocked reads (that function takes an explicit profile
# Dictionary rather than calling here, so synthetic-profile tests keep working; this is the
# convenience reader for live callers that already have `Save.profile`).
func engine_swap_unlocked() -> bool:
	return bool(profile.get(KEY_ENGINE_SWAP_UNLOCKED, false))


func engine_swap_unlock_price() -> int:
	return int(round(Config.data.engine_swap_unlock_price))


# Buy the Engine Swap unlock — a ONE-TIME purchase (decision 17), never sold twice. Refuses
# (no mutation) if already unlocked or unaffordable.
func buy_engine_swap_unlock() -> bool:
	if engine_swap_unlocked():
		return false
	if not spend_money(engine_swap_unlock_price()):
		return false
	profile[KEY_ENGINE_SWAP_UNLOCKED] = true
	save()
	return true


# --- Lifetime stats (todo/roguelike-pivot.md "Lifetime global stats") -----------
#
# The registry itself — which ids exist, their labels, which call site writes each —
# lives in LifetimeStats (scripts/lifetime_stats.gd); this is only the persistence,
# exactly the CarLibrary/Save split every other authored table already follows.
#
# ONLY EVER GROWS, and SURVIVES A FAILED RUN — soft permadeath destroys the run
# (stage progress, this run's boosts, the car's accrued damage) and never touches
# this ledger, the same asymmetry the run-meta block comment above states for money.
# Two mutators because not every stat is a running sum: a plain counter (stages
# cleared, money earned) adds; a high-water mark (the deepest region reached) must
# ratchet up to a maximum without a repeat visit double-counting it.

func lifetime_stat(id: String) -> int:
	return int((profile.get(KEY_LIFETIME, {}) as Dictionary).get(id, 0))


# Add `amount` (default 1) to stat `id`'s running total. A non-positive amount is a
# no-op — this only ever adds, mirroring add_money's own guard.
func add_lifetime_stat(id: String, amount: int = 1) -> void:
	if amount <= 0:
		return
	var stats: Dictionary = profile.get(KEY_LIFETIME, {})
	stats[id] = int(stats.get(id, 0)) + amount
	profile[KEY_LIFETIME] = stats
	save()


# Ratchet stat `id` up to max(current, value) — for a high-water-mark counter
# (BEST_REGION_ORDER) rather than a running sum. A no-op when `value` would not
# raise the stored value, so a repeat of an earlier achievement never regresses it
# and never fires an unnecessary write.
func raise_lifetime_stat(id: String, value: int) -> void:
	var stats: Dictionary = profile.get(KEY_LIFETIME, {})
	if value <= int(stats.get(id, 0)):
		return
	stats[id] = value
	profile[KEY_LIFETIME] = stats
	save()


# --- Perks (todo/roguelike-pivot.md "Perks — a straight lift from RR") -----------
#
# Three states, kept apart by PerkLibrary.is_unlocked / is_purchasable (both pure,
# reading a profile dict) and owns_perk below: LOCKED (unlock stat below its
# threshold), PURCHASABLE (threshold crossed, not yet bought), OWNED (bought).
# Equipping is a SEPARATE step from owning — perk_equipped / equip_perk /
# unequip_perk — capped at GameConfig.perk_max_equipped (RR's PERK_MAX_EQUIPPED = 3).
#
# NO GAMEPLAY EFFECT YET (see PerkLibrary's own header) — buy_perk/equip_perk only
# move an id between these three lists; nothing currently reads KEY_EQUIPPED_PERKS
# for anything but display.

func owns_perk(id: String) -> bool:
	return (profile.get(KEY_BOUGHT_PERKS, []) as Array).has(id)


func equipped_perks() -> Array:
	return (profile.get(KEY_EQUIPPED_PERKS, []) as Array).duplicate()


func perk_equipped(id: String) -> bool:
	return equipped_perks().has(id)


# Buy `id` outright. Refuses (no mutation) for an id PerkLibrary does not catalogue,
# one already owned, one not yet PURCHASABLE (its unlock stat hasn't crossed its
# threshold — PerkLibrary.is_purchasable), or one the player cannot afford. Same
# "byte-identical on refusal" rule as buy_car / buy_boost_level: every precondition
# is checked BEFORE spend_money, so a caller never half-spends into a purchase that
# was going to be rejected anyway.
func buy_perk(id: String) -> bool:
	if owns_perk(id):
		return false
	if not PerkLibrary.is_purchasable(id, profile):
		return false
	if not spend_money(PerkLibrary.price_of(id)):
		return false
	var bought: Array = profile.get(KEY_BOUGHT_PERKS, [])
	bought.append(id)
	profile[KEY_BOUGHT_PERKS] = bought
	save()
	return true


# Equip an OWNED perk. Refuses (no mutation) if not owned, already equipped, or the
# cap (GameConfig.perk_max_equipped) is already full.
func equip_perk(id: String) -> bool:
	if not owns_perk(id) or perk_equipped(id):
		return false
	var equipped: Array = profile.get(KEY_EQUIPPED_PERKS, [])
	if equipped.size() >= int(Config.data.perk_max_equipped):
		return false
	equipped.append(id)
	profile[KEY_EQUIPPED_PERKS] = equipped
	save()
	return true


# Unequip a perk. Refuses (no mutation) if it wasn't equipped — still owned either
# way, this only ever changes which SLOTTED perks are in force.
func unequip_perk(id: String) -> bool:
	var equipped: Array = profile.get(KEY_EQUIPPED_PERKS, [])
	if not equipped.has(id):
		return false
	equipped.erase(id)
	profile[KEY_EQUIPPED_PERKS] = equipped
	save()
	return true


# --- Rally completion --------------------------------------------------------

# Record a top-3 rally finish. Idempotent for the `completed` flag; updates the
# best combined time when a faster one comes in. The CAR reward is NOT granted
# here (re-wins are farmable -- see reward-system.md); this only records progress.
#
# STAR CREDITING IS GONE (todo/roguelike-pivot.md decision 21). This function used to
# also pay stars for the placement via RallyLibrary.stars_for_placement and write them
# into profile["stars_earned"] -- that whole ledger is deleted (see the "Star ledger:
# DELETED" note on _default_profile()) and this now does ONLY the completion/placement
# bookkeeping below. That bookkeeping is NOT part of the star economy and stays: it is
# what everything that reads a rally's `completed` / `best_placed` / `best_combined_ms`
# depends on. (The parts model's `rally_gate_met` was its last real consumer and is deleted
# too, so this is now bookkeeping ahead of stage 3's RunSession.) Returns nothing any
# more -- it used to return the stars gained.
#
# NAMED FOR ITS GATE, AND THE NAME IS THE WARNING. Was `complete_rally()` until round 016,
# which is a name that lied: with `RallySession` deleted, the only caller left is the dev
# cheat (`dev_three_star_rally`) -- the real gameplay caller returns with `RunSession` in
# the pivot's stage 3, and it must call this ONLY on a podium (or the opening rally's first
# attempt), never on every finish, for the same reason the old rally_session.gd call site
# was gated on `podium_or_opening`.
#
# THEREFORE: ANYTHING YOU INCREMENT OR WRITE IN HERE IS PODIUM-GATED, including a brand-new
# profile key of your own. A "rallies finished" counter incremented in this function counts
# PODIUMS and will read as a wrong number to the player, however honestly you named the key.
#
# Written HERE, at the site where the mistake is made, rather than only on the reading side
# (`podium_count`, `rally_podiumed`): round 016 measured a probe that never opened either of
# those and incremented a new key in this function instead.
func record_podium_rally(rally_id: String, combined_ms: int, placed: int = 0) -> void:
	var rallies: Dictionary = profile[KEY_RALLIES]
	var rec: Dictionary = rallies.get(rally_id, {"completed": false, "best_combined_ms": 0, "best_placed": 0})
	rec["completed"] = true
	# Only a REAL time can become the best time. A DNF arrives as combined_ms <= 0, and
	# without this guard it would sail through the "faster than the record" test -- every
	# negative is less than every positive -- and install itself as an unbeatable best.
	# Only the opening rally can complete on a DNF (todo/opening-rally.md), so this is the
	# one caller that can reach here without a time; the guard lives with the field it
	# protects rather than at that call site, since nothing downstream wants a negative
	# best_combined_ms regardless of who wrote it.
	if combined_ms > 0 and (int(rec.get("best_combined_ms", 0)) <= 0
			or combined_ms < int(rec["best_combined_ms"])):
		rec["best_combined_ms"] = combined_ms
	# Track the BEST (lowest) finishing position ever achieved here. Placement rating used
	# to drive the map's star display; that display is gone with the ledger, but the field
	# itself still answers "how well has this rally ever gone", so it stays. Lower placement
	# is better; 0 means "never placed".
	if placed > 0 and (int(rec.get("best_placed", 0)) <= 0 or placed < int(rec["best_placed"])):
		rec["best_placed"] = placed
	rallies[rally_id] = rec
	save()


# --- Spending stars: DELETED (todo/roguelike-pivot.md decision 21) ---------------
#
# Save.stars_available / award_stars / spend_stars are gone outright -- the ledger they
# read and write no longer exists (see the "Star ledger: DELETED" note on
# _default_profile()).
#
# THE PAID GARAGE REPAIR IS RETIRED, NOT STUBBED. repair_car / repair_price and their
# car_needs_repair / car_handles_badly predicates are deleted entirely (per
# todo/roguelike-pivot.md's "What gets deleted": between-run resets leave a paid repair
# nothing to do once the run loop lands, and a between-stage repair PICK replaces it --
# see the pivot doc's Repair section). They had no callers left in the parts model, so
# there is nothing to strand.
#
# BUYING A PART IS GONE WITH THE PARTS MODEL. part_price / can_buy_part / buy_part were
# left refusing by the star-economy wave purely so upgrade_options.gd and upgrades_grid.gd
# kept compiling; both files are now deleted, so all three are deleted too rather than
# stubbed. Same for apply_build_plan (UpgradeLibrary.auto_build_plan, the solver it
# committed, is deleted).
#
# DRIVETRAIN CONVERSION IS NO LONGER A MONEY SINK. Decision 52 made it the sixth money
# sink (a per-car purchase, drive_mode_price / buy_drive_mode / drive_mode_available), but
# that is superseded: a conversion is now a run-scoped mid-run upgrade, picked between
# stages exactly like a boost (RunSession.choose_drivetrain / drivetrain_override) — it
# dies with the run like everything else in the boost tier, so there is nothing to buy or
# persist here. See features/region-runs.md -> "Between-stage pick: repair, boost, or
# drivetrain conversion".


# record_stage_result (adaptive difficulty) used to live here. Its only caller was
# RallySession, deleted with the rival field it adapted (todo/roguelike-pivot.md
# decision 5); AiDifficulty is deleted too, so this seam is gone rather than
# left calling into a class that no longer exists.


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
func dev_three_star_rally(rally_id: String, persist := true) -> void:
	# Goes through record_podium_rally rather than writing the record by hand, so the cheat
	# marks `completed` / `best_placed` exactly as a real 1st place would. It used to also pay
	# STARS this way; that ledger is gone (todo/roguelike-pivot.md decision 21), so this cheat
	# no longer pays anything — it only marks the completion and grants whatever
	# _grant_rally_prizes below still hands over.
	#
	# Reusing the real path is also what stops the two drifting: whatever record_podium_rally
	# starts recording next lands here for free.
	# Captured BEFORE record_podium_rally, which is what sets `completed` — afterwards there is no
	# way to tell a first win from a re-win, and the prizes are first-win-only.
	var first_win := not rally_podiumed(rally_id)
	record_podium_rally(rally_id, DEV_WIN_TIME_MS, 1)
	if first_win:
		_grant_rally_prizes(rally_id)
	if persist:
		save()


# Hand over whatever a rally awards, exactly as finishing it would (features/prize-rallies.md).
#
# The cheat used to record the completion and pay the stars but hand over NOTHING — so a
# dev-completed career had every rally ticked off and an empty garage, which is useless for
# testing anything downstream of owning the car or part a rally exists to give.
#
# THE PART HALF IS GONE. This used to also hand over the part a special's unlock gated,
# through RewardSystem.grant_special_unlock and UpgradeLibrary.unlocked_by — both deleted
# with the persistent parts model (todo/roguelike-pivot.md -> "What gets deleted"). There is
# no part to grant any more, so only the prize car is left, and RallyLibrary.prize_car_id is
# itself a stub returning "" (see the prize-rally deletion), which makes this whole dev
# helper a no-op until the money shop lands in stage 6.
func _grant_rally_prizes(rally_id: String) -> void:
	var rally := RallyLibrary.by_id(rally_id)
	if rally.is_empty():
		return
	var prize_car := RallyLibrary.prize_car_id(rally)
	if prize_car != "" and not owns_model(prize_car):
		grant_car(prize_car)


# Best (lowest) finishing position ever achieved in a rally, or 0 if never placed.
# Used to drive the world-map star rating via RallyLibrary.stars_for_placement; that
# ledger is deleted (todo/roguelike-pivot.md decision 21), so this is now pure bookkeeping
# with no reader of its own yet.
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

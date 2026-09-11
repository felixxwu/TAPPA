extends Node
# Docs: features/engine-swap.md, features/save-persistence.md, features/lifetime-stats.md, features/skills.md — update in the same change as this file.
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
# Persisted key STRINGS keep their historical "perks" names on purpose: they are what
# existing saves carry on disk, and this save format refuses (rather than migrates) any
# profile whose schema_version doesn't match exactly — renaming them would brick every
# current save for a cosmetic code rename. The constants say "skills"; the disk says
# "perks". A future SCHEMA_VERSION reset is the moment to align them.
const KEY_BOUGHT_SKILLS := "bought_perks"      # skill ids owned
const KEY_EQUIPPED_SKILLS := "equipped_perks"  # skill ids currently slotted (capped)
const KEY_LIFETIME := "lifetime"              # stat id -> running total, never reset

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
		KEY_BOUGHT_SKILLS: [],
		KEY_EQUIPPED_SKILLS: [],
		KEY_LIFETIME: {},
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
# "self_healing" skill, todo/roguelike-pivot.md decision 51) — without it the trickle
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


# Full restore to max_hp — the ONLY writer besides grant_car (a brand-new car) that
# sets hp to full. Used by RunSession.begin() so a new run always starts at 100%
# health regardless of what a previous run left the car at (repairs should only ever
# happen via a repair pick or a fresh run — never silently). No-op if the car can't be
# found. Resolves max_hp the same way heal_car / apply_field_repair_to do.
func restore_car_to_full(instance_id: int) -> void:
	var car := get_car(instance_id)
	if car.is_empty():
		return
	var entry := CarLibrary.by_id(String(car.get("model_id", "")))
	var max_hp := float(entry.get("max_hp", car["hp"])) if not entry.is_empty() else float(car["hp"])
	car["hp"] = max_hp
	save()


# Fraction of max_hp the car currently has (1.0 = full, 0.0 = empty). Used by
# RunSession.report_event_result to decide whether the run's car qualifies for the
# undamaged-arrival reward (no repair row on the pick screen). Resolves max_hp the
# same way heal_car / apply_field_repair_to do. Returns 1.0 (treated as full/healthy)
# if the car can't be found — nothing to underperform against.
func car_health_fraction(instance_id: int) -> float:
	var car := get_car(instance_id)
	if car.is_empty():
		return 1.0
	var entry := CarLibrary.by_id(String(car.get("model_id", "")))
	var max_hp := float(entry.get("max_hp", car["hp"])) if not entry.is_empty() else float(car["hp"])
	if max_hp <= 0.0:
		return 1.0
	return clampf(float(car["hp"]) / max_hp, 0.0, 1.0)


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


# set_wheels is DELETED (its TuningPanel host route is gone — no caller passes an
# on_wheels callback, so the write path was unreachable). The per-car "wheels" key
# READ path stays: car.gd still resolves a saved style for cars in existing profiles.

# swap_engines / set_engine_detune are DELETED: the Engine Swap is a mid-run boost
# (BoostLibrary "engine_swap") now, and the garage-lift UI that wrote these keys is gone
# with the HQ. The per-car "swapped_engine" / "tuning.engine_detune" READ paths stay
# (CarLibrary.apply_owned) so cars in existing profiles still resolve their engines.


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


# Clear the stored run (RunSession.discard_run / _clear_persisted on finish) —
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


# A FULL field repair: 100% of the HP lost so far and every wheel straightened
# completely (fractions of 1.0). This is what RunSession.choose_repair() applies when
# the player explicitly picks "Repair the car" over an upgrade at the between-stage
# pick (todo/mid-run-upgrade-menu.md) — choosing repair is meant to fully undo the
# damage taken so far, not the smaller automatic patch-up every other stage
# transition gets via apply_field_repair_to. `instance_id` < 0 (nothing fielded) is a
# no-op, not an error.
func apply_full_field_repair_to(instance_id: int) -> Dictionary:
	if instance_id < 0:
		return {"repaired": false}
	return field_repair(instance_id, 1.0, 1.0)


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
# buy_skill) — LifetimeStats.MONEY_SPENT is written HERE so it
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


# --- Skills (todo/roguelike-pivot.md "Skills — a straight lift from RR") -----------
#
# Three states, kept apart by SkillLibrary.is_unlocked / is_purchasable (both pure,
# reading a profile dict) and owns_skill below: LOCKED (unlock stat below its
# threshold), PURCHASABLE (threshold crossed, not yet bought), OWNED (bought).
# Equipping is a SEPARATE step from owning — skill_equipped / equip_skill /
# unequip_skill — capped at GameConfig.skill_max_equipped (RR's PERK_MAX_EQUIPPED = 3).
#
# THE MUTATORS ARE BOOKKEEPING ONLY: buy_skill/equip_skill just move an id between these
# three lists. The gameplay effect is applied elsewhere, at fielding time —
# SkillLibrary.equipped_effects reads KEY_EQUIPPED_SKILLS and rides the same
# UpgradeLibrary.EFFECTS + car `boosts` seam a run's boosts do (decision 51), merged by
# world.gd::_owned_with_run_effects. So do not read "nothing here applies a skill" as
# "skills do nothing".

func owns_skill(id: String) -> bool:
	return (profile.get(KEY_BOUGHT_SKILLS, []) as Array).has(id)


func equipped_skills() -> Array:
	return (profile.get(KEY_EQUIPPED_SKILLS, []) as Array).duplicate()


func skill_equipped(id: String) -> bool:
	return equipped_skills().has(id)


# Buy `id` outright. Refuses (no mutation) for an id SkillLibrary does not catalogue,
# one already owned, one not yet PURCHASABLE (its unlock stat hasn't crossed its
# threshold — SkillLibrary.is_purchasable), or one the player cannot afford. Same
# "byte-identical on refusal" rule as buy_car / buy_boost_level: every precondition
# is checked BEFORE spend_money, so a caller never half-spends into a purchase that
# was going to be rejected anyway.
func buy_skill(id: String) -> bool:
	if owns_skill(id):
		return false
	if not SkillLibrary.is_purchasable(id, profile):
		return false
	if not spend_money(SkillLibrary.price_of(id)):
		return false
	var bought: Array = profile.get(KEY_BOUGHT_SKILLS, [])
	bought.append(id)
	profile[KEY_BOUGHT_SKILLS] = bought
	save()
	return true


# Equip an OWNED skill. Refuses (no mutation) if not owned, already equipped, or the
# cap (GameConfig.skill_max_equipped) is already full.
func equip_skill(id: String) -> bool:
	if not owns_skill(id) or skill_equipped(id):
		return false
	var equipped: Array = profile.get(KEY_EQUIPPED_SKILLS, [])
	if equipped.size() >= int(Config.data.skill_max_equipped):
		return false
	equipped.append(id)
	profile[KEY_EQUIPPED_SKILLS] = equipped
	save()
	return true


# Unequip a skill. Refuses (no mutation) if it wasn't equipped — still owned either
# way, this only ever changes which SLOTTED skills are in force.
func unequip_skill(id: String) -> bool:
	var equipped: Array = profile.get(KEY_EQUIPPED_SKILLS, [])
	if not equipped.has(id):
		return false
	equipped.erase(id)
	profile[KEY_EQUIPPED_SKILLS] = equipped
	save()
	return true


# Dev cheat (Settings → Dev → "Unlock all skills"): grant OWNERSHIP of every
# SkillLibrary catalogue entry at once, bypassing the unlock thresholds and prices
# buy_skill enforces, so the Skills page can equip any of them. Returns how many
# ids were newly granted; a call that grants nothing writes nothing. Deliberately
# touches NOTHING else — no money moves (that's "Add money"'s job) and the
# EQUIPPED list is left alone: owning a skill is not slotting it, and equipping
# stays the Skills page's own capped step (equip_skill).
func dev_grant_all_skills() -> int:
	var bought: Array = profile.get(KEY_BOUGHT_SKILLS, [])
	var granted := 0
	for entry in SkillLibrary.all():
		var id := String(entry["id"])
		if bought.has(id):
			continue
		bought.append(id)
		granted += 1
	if granted > 0:
		profile[KEY_BOUGHT_SKILLS] = bought
		save()
	return granted


# --- Rally economy: DELETED with the star ledger (todo/roguelike-pivot.md decision 21) --
#
# Save.stars_available / award_stars / spend_stars are gone outright -- the ledger they
# read and write no longer exists (see the "Star ledger: DELETED" note on
# _default_profile()).
#
# THE PAID GARAGE REPAIR IS RETIRED, NOT STUBBED. repair_car / repair_price and their
# car_needs_repair / car_handles_badly predicates are deleted entirely -- a between-stage
# repair PICK replaces it (see the pivot doc's Repair section).
#
# BUYING A PART IS GONE WITH THE PARTS MODEL. part_price / can_buy_part / buy_part and
# apply_build_plan are deleted (their UI hosts went first).
#
# DRIVETRAIN CONVERSION IS NO LONGER A MONEY SINK. Decision 52's per-car purchase is
# superseded: a conversion is a run-scoped mid-run upgrade (RunSession.choose_drivetrain),
# so there is nothing left to buy here.
#
# record_podium_rally / rally_podiumed / best_placement / podium_rally_count / the reveal
# seeding and the dev 3-star cheats that topped this ledger up are DELETED with the HQ
# map: no live caller writes or reads a rally record any more (region runs track their
# own KEY_REGIONS_CLEARED ledger). Old profiles keep their "rallies" dict on disk,
# unread and undeclared. The dev page's one Save-side mutator now is
# dev_grant_all_skills above (skills), plus plain add_money for its "Add money".
#
# record_stage_result (adaptive difficulty) used to live here too -- its only caller was
# RallySession, deleted with the rival field it adapted (decision 5).



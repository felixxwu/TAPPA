class_name CloudSync
extends Node
# Synchronises the local profile with a single Firestore document per user.
#
# The local file stays the SOURCE OF TRUTH for the running session — this class
# copies it up and, when the player agrees, copies a newer copy down. A sync
# failure of any kind degrades to "not synced" and never blocks, stalls or
# damages local play.
#
# WHY REVISION COUNTERS, NOT TIMESTAMPS. "Newest wins" needs an ordering, and
# wall-clock time is not one: a phone and a desktop routinely disagree, and a
# device with a wrong clock would silently eat the other device's career. The
# document carries a `revision` that only ever increments on a successful push;
# the local profile remembers the revision it last agreed with (`cloud_revision`).
# Divergence is then an exact statement — "the cloud moved on AND so did we" —
# rather than a guess about whose clock to believe. updated_utc is stored purely
# so the conflict prompt can say "2 hours ago"; nothing branches on it.

signal state_changed()
# Emitted when a pull REPLACED the local profile with the cloud's copy. Distinct
# from state_changed (which is about sync status): this says "the career you are
# looking at is not the one you were looking at a moment ago", so any live UI
# showing owned cars has to rebuild or the player sees a stale garage.
signal profile_replaced()
# Emitted when a pull finds that both sides moved on independently. The UI turns
# this into a player choice; sync stays paused until one is made.
signal conflict_detected(summary: Dictionary)

enum Status { IDLE, WORKING, SYNCED, OFFLINE, ERROR, CONFLICT }

# Longer than Save's ~1s local debounce on purpose: a disk write is free, a
# network round trip is not. Bursty progress (a rally payout granting a car, an
# upgrade and a rally record) collapses into one upload.
const PUSH_DEBOUNCE_SEC := 8.0

const BACKOFF_START_SEC := 2.0
const BACKOFF_MAX_SEC := 60.0

# Injected by Cloud.
var rest = null
var auth: AuthService = null

var status: int = Status.IDLE
var status_message := ""
var last_sync_utc := ""
# True when local changes exist that the cloud has not accepted yet.
var pending := false
# Set while a conflict is unresolved; blocks pushes so neither side is clobbered
# before the player decides.
var blocked_by_conflict := false

var _debounce: Timer
var _retry: Timer
var _backoff := BACKOFF_START_SEC
var _busy := false
var _conflict: Dictionary = {}


func _ready() -> void:
	_debounce = Timer.new()
	_debounce.one_shot = true
	_debounce.wait_time = PUSH_DEBOUNCE_SEC
	_debounce.timeout.connect(_on_debounce)
	add_child(_debounce)

	_retry = Timer.new()
	_retry.one_shot = true
	_retry.timeout.connect(_on_retry)
	add_child(_retry)


# --- Public API --------------------------------------------------------------

# Note that the profile changed. Cheap and safe to call on every local save.
func request_push() -> void:
	if not _can_sync():
		return
	pending = true
	_debounce.start()


# Push right now, skipping the debounce (app close, sign-in, "Sync now").
func flush() -> void:
	if not _can_sync() or not pending:
		return
	_debounce.stop()
	push()


# Read the cloud document and reconcile it with the local profile. Returns
# {ok, state, error} where `state` is one of:
#   "no_cloud"     — nothing stored yet; local was pushed up
#   "up_to_date"   — both sides agree
#   "pushed"       — local had unsynced work at the agreed revision; uploaded
#   "applied"      — cloud was ahead and local was clean; downloaded
#   "conflict"     — both moved on; conflict_detected was emitted
#   "newer_schema" — the cloud was written by a newer build; refused
func pull() -> Dictionary:
	if not _can_sync():
		return {"ok": false, "state": "offline", "error": "Not signed in."}
	_set_status(Status.WORKING, "Checking…")
	var fresh := await auth.ensure_fresh_token()
	if not fresh.ok:
		return _fail_from_auth(fresh)

	var response = await rest.request_json(
		HTTPClient.METHOD_GET, FirebaseConfig.user_doc(auth.uid),
		RestClient.json_headers(auth.id_token))

	# 404 is the expected "this player has never synced" answer, not an error.
	if response.status == 404:
		var pushed := await push(true)
		return {"ok": pushed.ok, "state": "no_cloud", "error": pushed.get("error", "")}
	if not response.ok:
		return _fail_from_response(response)

	var remote := from_document(response.json)
	if remote.is_empty():
		# Present but unreadable. Do NOT overwrite it — a player with a corrupt
		# cloud doc still has their local career, and silently replacing the
		# remote copy would destroy whatever could have been recovered from it.
		_set_status(Status.ERROR, "Cloud save is unreadable.")
		return {"ok": false, "state": "unreadable", "error": "Cloud save is unreadable."}

	if int(remote.get("schema_version", 0)) > Save.SCHEMA_VERSION:
		_set_status(Status.ERROR, "Cloud save needs a newer version of the game.")
		return {"ok": false, "state": "newer_schema",
			"error": "Cloud save needs a newer version of the game."}

	var remote_revision := int(remote.get("revision", 0))
	var agreed_revision := _agreed_revision()
	var local_moved := Save.has_unsynced()

	if remote_revision <= agreed_revision:
		# We are level with, or ahead of, what the cloud has.
		if local_moved or pending:
			var pushed := await push(true)
			return {"ok": pushed.ok, "state": "pushed", "error": pushed.get("error", "")}
		_set_status(Status.SYNCED, "Up to date")
		return {"ok": true, "state": "up_to_date", "error": ""}

	if not local_moved:
		# Cloud is ahead and we have nothing to lose — take it.
		var applied := apply_remote(remote)
		if not applied.ok:
			_set_status(Status.ERROR, applied.error)
			return {"ok": false, "state": "apply_failed", "error": applied.error}
		_set_status(Status.SYNCED, "Up to date")
		return {"ok": true, "state": "applied", "error": ""}

	# Both sides moved on — but ONE case is not a real dilemma. If this device has no
	# cars at all, the local "progress" is a wiped save: something was reset, cleared
	# or reinstalled, and the only thing that would be lost by taking the cloud is an
	# empty garage. Asking there is worse than useless — it presents a fresh blank
	# profile as an equal alternative to the player's real career, and one mis-tap on
	# "keep this device" uploads the blank over it. So take the cloud, provided the
	# cloud actually HAS something (a wiped local against a wiped cloud is a genuine
	# nothing-to-choose-between, and apply_remote's backup still covers the player if
	# this ever fires when they did not expect it).
	if _local_is_wiped() and _remote_has_progress(remote):
		var recovered := apply_remote(remote, true)
		if recovered.ok:
			_set_status(Status.SYNCED, "Up to date")
			return {"ok": true, "state": "applied", "error": ""}
		# Fall through to the prompt: if the restore failed, the player still needs
		# to be told their progress differs rather than left silently blocked.

	# Both sides moved on. Ask; do not guess.
	_conflict = remote
	blocked_by_conflict = true
	_set_status(Status.CONFLICT, "Your progress differs from the cloud.")
	conflict_detected.emit(conflict_summary())
	return {"ok": false, "state": "conflict", "error": ""}


# Upload the local profile. `force` bypasses the "nothing pending" shortcut.
func push(force := false) -> Dictionary:
	if not _can_sync():
		return {"ok": false, "error": "Not signed in."}
	if blocked_by_conflict and not force:
		return {"ok": false, "error": "Resolve the sync conflict first."}
	if _busy:
		# A push is already in flight; it will upload the current profile anyway
		# (the payload is always the whole thing), so this one is redundant.
		return {"ok": true, "error": ""}
	if not pending and not force:
		return {"ok": true, "error": ""}

	_busy = true
	var result := await _push_inner()
	_busy = false
	return result


func _push_inner() -> Dictionary:
	_set_status(Status.WORKING, "Saving to cloud…")
	var fresh := await auth.ensure_fresh_token()
	if not fresh.ok:
		return _fail_from_auth(fresh)

	var revision := _agreed_revision() + 1
	var stamp := Time.get_datetime_string_from_system(true)
	# Upload a copy with the sync bookkeeping normalised: those two fields
	# describe THIS device's relationship with the cloud, and shipping them as-is
	# would tell the next device that a freshly-downloaded profile already has
	# unsynced work.
	var blob: Dictionary = Save.profile.duplicate(true)
	blob["unsynced"] = false
	blob["cloud_revision"] = revision
	blob["cloud_uid"] = auth.uid
	# Settings are device-local and deliberately NOT published: the frame cap and
	# touch scheme that suit a phone are wrong for a desktop, and vice versa.
	blob.erase("settings")
	var payload := to_document(JSON.stringify(blob), Save.SCHEMA_VERSION,
		revision, stamp, FirebaseConfig.device_tag())

	var response = await rest.request_json(
		HTTPClient.METHOD_PATCH, _patch_url(),
		RestClient.json_headers(auth.id_token), JSON.stringify(payload))
	if not response.ok:
		return _fail_from_response(response)

	# Only now is the local profile allowed to claim it agrees with this revision.
	Save.profile["cloud_revision"] = revision
	Save.profile["cloud_uid"] = auth.uid
	Save.mark_synced()
	pending = false
	last_sync_utc = stamp
	_backoff = BACKOFF_START_SEC
	_set_status(Status.SYNCED, "Up to date")
	return {"ok": true, "error": ""}


# Publish the CURRENT (just-wiped) local profile over the cloud copy.
#
# WHY A DEV WIPE HAS TO REACH THE CLOUD. `Save.reset_new_game()` only clears this
# device. Leave the remote copy alone and the very next pull sees "cloud is ahead,
# local is clean" and restores everything — and with the wiped-local auto-restore
# above it does so without even asking. The wipe would appear to work and then
# silently undo itself, which is worse than not offering it. So the wipe is pushed:
# after this, the cloud holds the blank profile too.
#
# Also DISCARDS any pending conflict: the local side of that decision no longer
# exists, so keeping the prompt alive would offer the player a choice between the
# cloud and a save they just deleted on purpose.
func push_wipe() -> Dictionary:
	_conflict = {}
	blocked_by_conflict = false
	pending = true
	return await push(true)


# --- Conflict resolution -----------------------------------------------------

# A player-legible description of both sides, for the prompt.
# "This device has nothing to lose." CARS, not any other counter: a car is the one
# thing a career cannot exist without (the starter pick grants one before anything
# else can happen), so an empty garage means the save is blank no matter what else
# is set. Deliberately NOT keyed on `starter_picked` — a wiped profile that somehow
# kept that flag would still be empty, and a player mid-starter-pick has no cars
# either, which is exactly the case reported: signed in, progress gone, happily
# offered a starter car while a real career sat in the cloud.
func _local_is_wiped() -> bool:
	return Array(Save.profile.get(Save.KEY_CARS, [])).is_empty()


# The cloud copy has a career worth restoring. Guards the auto-take: replacing an
# empty local with an equally empty remote is not a recovery, and doing it silently
# would hide a genuine "both sides are blank" state behind a fake success.
func _remote_has_progress(remote: Dictionary) -> bool:
	var parsed: Variant = _parse_profile(String(remote.get("profile", "")))
	if typeof(parsed) != TYPE_DICTIONARY:
		return false
	return not Array((parsed as Dictionary).get(Save.KEY_CARS, [])).is_empty()


func conflict_summary() -> Dictionary:
	if _conflict.is_empty():
		return {}
	var remote_profile: Variant = _parse_profile(String(_conflict.get("profile", "")))
	return {
		"local": describe_profile(Save.profile),
		"cloud": describe_profile(remote_profile if typeof(remote_profile) == TYPE_DICTIONARY else {}),
		"cloud_device": String(_conflict.get("device", "another device")),
		"cloud_updated_utc": String(_conflict.get("updated_utc", "")),
	}


# Keep this device's career: push over the cloud at a revision above the remote
# one, so the other device sees a clean "cloud is ahead" next time.
func resolve_keep_local() -> Dictionary:
	if _conflict.is_empty():
		return {"ok": false, "error": "No conflict to resolve."}
	Save.profile["cloud_revision"] = int(_conflict.get("revision", 0))
	_conflict = {}
	blocked_by_conflict = false
	pending = true
	return await push(true)


# Take the cloud copy, keeping a one-shot backup of what was replaced. A
# mis-tapped choice here would otherwise be unrecoverable.
func resolve_use_cloud() -> Dictionary:
	if _conflict.is_empty():
		return {"ok": false, "error": "No conflict to resolve."}
	var remote := _conflict
	_conflict = {}
	blocked_by_conflict = false
	var applied := apply_remote(remote, true)
	if not applied.ok:
		_set_status(Status.ERROR, applied.error)
		return applied
	_set_status(Status.SYNCED, "Up to date")
	return {"ok": true, "error": ""}


# Leave the conflict unresolved. Sync stays paused and the Account page keeps
# warning — deliberately NOT a silent pick of either side.
func resolve_later() -> void:
	blocked_by_conflict = true
	_set_status(Status.CONFLICT, "Sync paused — your progress differs from the cloud.")


# --- Applying a downloaded profile -------------------------------------------

# Replace the local profile with a downloaded one. The blob goes through the
# SAME load path as a local file (parse -> migrate -> sanitise), so cloud data
# gets identical validation, migration and catalogue pruning; there is no second
# implementation to keep in step with the schema.
func apply_remote(remote: Dictionary, backup := false) -> Dictionary:
	var parsed: Variant = _parse_profile(String(remote.get("profile", "")))
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "error": "Cloud save is unreadable."}
	if backup:
		Save.write_conflict_backup()
	var accepted := Save.adopt_profile(parsed)
	if not accepted:
		return {"ok": false, "error": "Cloud save needs a newer version of the game."}
	Save.profile["cloud_revision"] = int(remote.get("revision", 0))
	Save.profile["cloud_uid"] = auth.uid
	pending = false
	last_sync_utc = String(remote.get("updated_utc", ""))
	Save.mark_synced()
	profile_replaced.emit()
	return {"ok": true, "error": ""}


# --- Firestore document encoding ---------------------------------------------
# The value-level encoding (type tags, the integer-as-string trap) lives in
# FirestoreCodec, shared with Leaderboard. What stays here is only the SHAPE of
# the user document — which fields it has and what they mean.

const DOC_FIELDS := ["profile", "schema_version", "revision", "updated_utc", "device"]


static func to_document(profile_json: String, schema_version: int, revision: int,
		updated_utc: String, device: String) -> Dictionary:
	return FirestoreCodec.document({
		"profile": profile_json,
		"schema_version": schema_version,
		"revision": revision,
		"updated_utc": updated_utc,
		"device": device,
	})


# Inverse of to_document. Returns {} when the document is missing the fields we
# require, which the caller treats as "unreadable" rather than "empty".
static func from_document(doc: Variant) -> Dictionary:
	if typeof(doc) != TYPE_DICTIONARY:
		return {}
	var f := FirestoreCodec.fields_of(doc)
	if not f.has("profile"):
		return {}
	return {
		"profile": FirestoreCodec.string_field(f, "profile"),
		"schema_version": FirestoreCodec.int_field(f, "schema_version"),
		"revision": FirestoreCodec.int_field(f, "revision"),
		"updated_utc": FirestoreCodec.string_field(f, "updated_utc"),
		"device": FirestoreCodec.string_field(f, "device"),
	}


# A short human summary of a profile, for the conflict prompt. Counting is done
# here rather than in the UI so the prompt cannot drift from what is compared.
static func describe_profile(p: Dictionary) -> String:
	var cars: int = (p.get(Save.KEY_CARS, []) as Array).size()
	var done := 0
	var rallies: Variant = p.get(Save.KEY_RALLIES, {})
	if typeof(rallies) == TYPE_DICTIONARY:
		for key in rallies as Dictionary:
			var entry: Variant = (rallies as Dictionary)[key]
			if typeof(entry) == TYPE_DICTIONARY and bool((entry as Dictionary).get("completed", false)):
				done += 1
	var car_word := "car" if cars == 1 else "cars"
	var rally_word := "rally" if done == 1 else "rallies"
	return "%d %s, %d %s completed" % [cars, car_word, done, rally_word]


# --- Internals ---------------------------------------------------------------

# An explicit updateMask keeps the PATCH from deleting fields we did not send —
# without it, Firestore treats the request as a full replace, which would drop
# any field added by a newer build of the game.
func _patch_url() -> String:
	return FirebaseConfig.user_doc(auth.uid) + FirestoreCodec.update_mask(DOC_FIELDS)


# The revision this device can legitimately claim to have agreed with.
#
# ZERO when the stored profile belongs to a DIFFERENT account. Without this,
# signing out of account A (revision 7) and into account B (revision 3) reads as
# "we are ahead of the cloud" and pushes A's career straight over B's document.
# Resetting to 0 makes any existing remote document look newer, which routes the
# situation into the normal matrix: adopt it if this device has nothing
# unsynced, otherwise raise the divergence prompt and let the player choose.
func _agreed_revision() -> int:
	if String(Save.profile.get("cloud_uid", "")) != auth.uid:
		return 0
	return int(Save.profile.get("cloud_revision", 0))


func _parse_profile(blob: String) -> Variant:
	if blob == "":
		return null
	var json := JSON.new()
	if json.parse(blob) != OK:
		return null
	return json.data


func _can_sync() -> bool:
	return auth != null and rest != null and auth.is_signed_in()


func _on_debounce() -> void:
	push()


func _on_retry() -> void:
	if pending:
		push()


func _fail_from_auth(result: Dictionary) -> Dictionary:
	if result.get("network", false):
		_go_offline(String(result.get("error", "")))
		return {"ok": false, "state": "offline", "error": String(result.get("error", ""))}
	_set_status(Status.ERROR, String(result.get("error", "")))
	return {"ok": false, "state": "auth", "error": String(result.get("error", ""))}


func _fail_from_response(response: Dictionary) -> Dictionary:
	var status_code := int(response.get("status", 0))
	# Transport failures and the server's own "try later" answers are the same
	# situation from here: come back shortly, keep the local profile untouched.
	if response.get("network", false) or status_code == 429 or status_code >= 500:
		_go_offline("No connection — will retry.")
		return {"ok": false, "state": "offline", "error": "No connection — will retry."}
	if status_code == 401 or status_code == 403:
		# 403 is almost always a security-rules misconfiguration rather than
		# anything the player did, so say so plainly with the code attached.
		var message := "Cloud sync was refused (%d). Check the Firestore rules." % status_code
		_set_status(Status.ERROR, message)
		return {"ok": false, "state": "denied", "error": message}
	var generic := "Cloud sync failed (%s)." % String(response.get("error", "unknown"))
	_set_status(Status.ERROR, generic)
	return {"ok": false, "state": "error", "error": generic}


func _go_offline(message: String) -> void:
	_set_status(Status.OFFLINE, message)
	if pending:
		_retry.wait_time = _backoff * randf_range(0.8, 1.2)
		_retry.start()
		_backoff = minf(_backoff * 2.0, BACKOFF_MAX_SEC)


func _set_status(new_status: int, message: String) -> void:
	status = new_status
	status_message = message
	state_changed.emit()
